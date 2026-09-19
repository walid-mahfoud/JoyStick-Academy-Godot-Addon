@tool
extends RefCounted

## Runs the learner's game and watches it.
##
## THREE PROCESSES, WHICH NO OTHER ENGINE HERE HAS. Unity and Unreal observe
## play mode inside the editor's own process. Godot runs the game as a separate
## process, and this addon's Core runs as a separate process too, so an
## observation crosses two boundaries before a check can read it: game ->
## editor (this file, over stdout) -> sidecar (the wire protocol).
##
## This file owns the first of those. It launches the game, drains its output,
## and turns the lines back into records.
##
## THE FOUR THINGS THIS HAS TO GET RIGHT, all of them measured rather than read:
##
## 1. **`--path <project>` alone runs the project's MAIN scene**, not the one the
##    learner just built -- and a project with no main scene set does not launch
##    at all. A walkthrough step is almost always "make a scene, add a body,
##    press play", so the obvious command evaluates a different scene from the
##    one being checked. The scene is passed explicitly.
##
## 2. **Drain every frame.** A child printing 400 lines completed when drained
##    at 16 ms or 50 ms; at 100 ms only 296 of 400 arrived and it was still
##    running at 30 s; at 500 ms, 58 of 400. A child nobody drains simply
##    stalls.
##
## 3. **Liveness before the pipe, and NEVER after death.** Touching a pipe after
##    the child exits fails PeekNamedPipe and prints a red engine ERROR on every
##    call, so a crashed game looks to a learner like a wall of Godot bugs.
##    is_process_running first, always. And eof_reached() never goes true when a
##    child dies, so nothing here may wait for it.
##
##    The tempting exception -- one last read to catch what the child wrote on
##    its way out -- was written, measured, and removed: over five runs it
##    gained zero records while the alive drains had already collected all
##    eight. What it did produce was the red errors.
##
##    The honest consequence: output written in the last ~16 ms before the
##    process dies can be lost, and no amount of care recovers it. That is
##    precisely why the observer ticks every 100 ms and marks the end sample
##    stale rather than pretending to read the final instant.
##
## 4. **Put the learner's project back, BYTE FOR BYTE.** The autoload this
##    needs is written into THEIR project.godot, and that file is theirs.
##
##    The documented approach -- set the setting, ProjectSettings.save() -- is
##    worse than it sounds, and this was measured on this repository's own
##    project file rather than reasoned about. save() does not edit the file, it
##    REWRITES it: the six lines of comments at the top explaining what this
##    project is were replaced with Godot's stock "It's best edited using the
##    editor UI" boilerplate, and `run/main_scene=""` disappeared entirely. A
##    learner would press play on a walkthrough step and find their project file
##    rewritten and their own comments gone.
##
##    So this does not go through ProjectSettings at all. It snapshots the file,
##    edits the text surgically, and restores the snapshot afterwards -- which
##    makes byte-identity true by construction rather than by hoping the
##    serialiser is stable. The surgical removal is kept as the fallback for the
##    case the snapshot cannot cover: an editor that died with a window open.

const Codec := preload("res://addons/joystickacademy/observe/observation_codec.gd")
const Config := preload("res://addons/joystickacademy/observe/observation_config.gd")

## The autoload name written into the learner's project while a window is open.
## Distinctive on purpose: it appears in their project.godot, briefly, and has
## to be recognisable as ours if anything ever goes wrong and it is left there.
const AUTOLOAD_NAME := "JoyStickAcademyObserver"
const OBSERVER_PATH := "*res://addons/joystickacademy/observe/observer_probe.gd"

## Godot's own setting path for an autoload. Kept for callers that want to ask
## the engine; this file writes the FILE, for the reason in note 4.
const AUTOLOAD_SETTING := "autoload/" + AUTOLOAD_NAME

## The exact line written into project.godot, and the exact line taken back out.
const AUTOLOAD_LINE := AUTOLOAD_NAME + '="' + OBSERVER_PATH + '"'

const PROJECT_FILE := "res://project.godot"

enum State { IDLE, RUNNING, FINISHED, FAILED }

var _state := State.IDLE
var _pid := -1
var _io: FileAccess = null
var _err: FileAccess = null
var _nonce := ""
var _partial := ""
## Its own buffer: see _read_from. One shared buffer splices half a line of
## engine output onto half a line of the learner's.
var _partial_err := ""
var _reason := ""

## The learner's project file as it was before this window opened. Restoring it
## is what makes "byte-identical afterwards" true by construction.
var _snapshot := PackedByteArray()

## What the last launch was actually told to do. See launch_arguments().
var _last_args := PackedStringArray()

var _logs: Array[String] = []
## What the ENGINE said, kept apart from what the learner printed.
var _engine_output: Array[String] = []
var _records: Array[Dictionary] = []
var _foreign := 0
var _malformed := 0


## Open a window on `scene_path`, watching whatever `config` names.
##
## `config` is an `observation_config.gd`, or null to watch nothing. It carries
## every kind in ONE argument; see that file for why a list per kind does not
## survive contact with a learner's node names.
##
## Returns "" on success, or a reason it could not start. `godot_executable`
## defaults to the running editor, which is the same binary a learner presses
## play with.
##
## `headless` RUNS THE GAME WITH NO WINDOW, and it is a per-caller choice rather
## than a setting because the two callers want opposite things:
##
##   * A learner pressing play MUST see their game. That is the entire point of
##     the window, and a check that watched an invisible game would be watching
##     something the learner cannot.
##   * A test suite must NOT. Seven tests opening a real game window each is a
##     second of flashing windows on somebody's desktop -- and on a CI runner
##     with no display server a windowed child cannot start at all, so the
##     play-mode tests would pass only on a developer's machine.
##
## Found because the windows were visible on screen, which is the only symptom
## either failure mode has until CI runs on Linux.
func start(scene_path: String, config: RefCounted = null,
		godot_executable := "", headless := false) -> String:
	if _state == State.RUNNING:
		return "a play-mode window is already open"
	if scene_path == "":
		return "no scene to run"

	var executable := godot_executable if godot_executable != "" else OS.get_executable_path()
	if executable == "":
		return "could not work out which Godot to run"

	_reset()
	_nonce = Codec.new_nonce()

	var installed := install_observer()
	if installed != "":
		return installed

	var project := ProjectSettings.globalize_path("res://")
	var args := PackedStringArray(["--path", project])
	if headless:
		# Before the scene path: Godot reads engine flags in order and the
		# positional scene argument ends the engine's own options.
		args.append("--headless")
	args.append_array(PackedStringArray([
		scene_path,
		# EVERYTHING AFTER `--` IS THE GAME'S, not the engine's. Godot hands it
		# to OS.get_cmdline_user_args(), which is how the observer is told the
		# run's token without writing it anywhere the learner can read.
		"--",
		Codec.ARG_NONCE_PREFIX + _nonce,
	]))
	# Only when there is something to say. An empty configuration passes NO
	# argument rather than an argument meaning nothing, so a run that watches
	# nothing is byte-identical on the command line to one from before any of
	# this existed.
	var encoded := "" if config == null else str(config.encode())
	if encoded != "":
		args.append(Codec.ARG_CONFIG_PREFIX + encoded)

	_last_args = args

	# blocking = FALSE, explicitly. The default is true, and true blocks the
	# thread that draws the editor.
	var info: Dictionary = OS.execute_with_pipe(executable, args, false)
	if info.is_empty():
		remove_observer()
		_state = State.FAILED
		_reason = "the game could not be launched"
		return _reason

	_pid = int(info.get("pid", -1))
	_io = info.get("stdio")
	_err = info.get("stderr")
	_state = State.RUNNING
	return ""


## Drive the window. Call once per editor frame -- see note 2 in the header.
func poll() -> void:
	if _state != State.RUNNING:
		return

	# LIVENESS FIRST. See note 3: reading a dead child's pipe prints a red
	# engine error every time it is touched.
	var alive := OS.is_process_running(_pid)
	if alive:
		_drain()
		return

	# NO DRAIN HERE, AND THAT IS THE CORRECTION. The obvious thing is one last
	# read -- "the child has exited but what it wrote before dying is still in
	# the buffer" -- and it is wrong twice over.
	#
	# It prints a red engine ERROR on every call, because a dead pipe fails
	# PeekNamedPipe, which is trap 3 in this file's own header. And it buys
	# NOTHING: measured over five runs, the post-death drain gained zero records
	# each time while the alive drains had already collected all eight. The
	# child's output reaches the pipe before the process finishes exiting, so a
	# 16 ms poll has already taken it.
	#
	# _finish_partial touches no pipe -- it flushes the text already received,
	# which is where a crashing process's last unterminated line sits.
	_finish_partial()
	_state = State.FINISHED
	remove_observer()


## End the window early, as a learner pressing Stop does.
func stop() -> void:
	# Drain BEFORE the kill, not after: afterwards the pipe is dead and reading
	# it only produces engine errors. This is the last chance to take whatever
	# the game has already written.
	if _state == State.RUNNING:
		_drain()

	if _state == State.RUNNING and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)

	if _state == State.RUNNING:
		_finish_partial()
		_state = State.FINISHED
	remove_observer()


## Write the autoload into the project. Returns "" or a reason.
##
## PER WINDOW, NOT PER ENABLE, and the alternative was considered. Installing it
## when the addon is enabled would write to the learner's project.godot the
## moment they tick a checkbox, leave it there for as long as the addon is
## installed, and load our code into every game they run themselves. Installing
## per window costs two ProjectSettings.save() calls next to launching a whole
## game process, and in exchange their project file is untouched except during a
## run they asked for.
##
## Public because the window is not the only caller: the plugin removes it on
## disable too, in case a window was open when the editor closed.
func install_observer() -> String:
	var text := FileAccess.get_file_as_string(PROJECT_FILE)
	if text == "":
		return "could not read the project file"
	if text.contains(AUTOLOAD_LINE):
		return ""

	_snapshot = FileAccess.get_file_as_bytes(PROJECT_FILE)
	if not _write(PROJECT_FILE, _with_autoload(text)):
		_snapshot = PackedByteArray()
		return "could not write to the project file"
	return ""


## Take the autoload back out, ON DISK.
##
## THE SAVE IS THE WHOLE POINT. Clearing the setting in memory leaves the entry
## in project.godot; the learner then deletes the addon folder and their game
## stops starting, over an autoload they never added.
func remove_observer() -> void:
	if not _snapshot.is_empty():
		# The byte-exact path, and the one that runs in practice.
		_write_bytes(PROJECT_FILE, _snapshot)
		_snapshot = PackedByteArray()
		return

	# No snapshot: the editor died with a window open and this is a later
	# session cleaning up.
	clean_up_stale_observer()


## Take a LEFTOVER observer out of the project file. Returns true if there was
## one.
##
## THIS IS NOT HYPOTHETICAL, AND IT IS NOT RARE. It happened twice while this
## file was being written, both times because a process was killed while a
## window was open -- once by a stray Stop-Process, once by a session ending.
## Each time the project file was left holding the autoload.
##
## For a learner that is not an inconvenience. The entry points at a script
## inside the addon, so if they then delete the addon folder -- which is exactly
## what somebody does after uninstalling -- THEIR GAME STOPS STARTING, with an
## error naming an autoload they never added and cannot find.
##
## Surgical, and it cannot be byte-exact: the bytes a snapshot would restore are
## gone with the process that held them. It removes our one line and touches
## nothing else.
static func clean_up_stale_observer() -> bool:
	var text := FileAccess.get_file_as_string(PROJECT_FILE)
	if text == "" or not text.contains(AUTOLOAD_LINE):
		return false
	_write(PROJECT_FILE, _without_autoload(text))
	return true


## Is the observer currently written into the project file?
##
## Reads the FILE rather than ProjectSettings. The editor's in-memory settings
## are not reloaded when the file changes underneath them, so asking the engine
## would answer a question about the editor's memory rather than about the
## learner's project.
static func observer_is_installed() -> bool:
	return FileAccess.get_file_as_string(PROJECT_FILE).contains(AUTOLOAD_LINE)


## Add our line to the [autoload] section, creating the section if it has none.
static func _with_autoload(text: String) -> String:
	var body := text
	if not body.ends_with("\n"):
		body += "\n"

	var section := body.find("[autoload]")
	if section < 0:
		return body + "\n[autoload]\n\n" + AUTOLOAD_LINE + "\n"

	# Insert immediately after the section header, which keeps whatever the
	# learner had in there and wherever they had it.
	var after_header := body.find("\n", section)
	if after_header < 0:
		return body + AUTOLOAD_LINE + "\n"
	return body.substr(0, after_header + 1) + AUTOLOAD_LINE + "\n" \
		+ body.substr(after_header + 1)


## Take our line back out, and nothing else.
static func _without_autoload(text: String) -> String:
	var kept := PackedStringArray()
	for line in text.split("\n"):
		if line.strip_edges() == AUTOLOAD_LINE:
			continue
		kept.append(line)
	return "\n".join(kept)


static func _write(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


static func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	file.close()
	return true


func state() -> State:
	return _state


func reason() -> String:
	return _reason


## Everything the LEARNER printed, in order. Their stdout, minus our records.
##
## This is what behaviour.log_matches searches, and it deliberately excludes the
## engine's own output: a check looking for "the player landed" must not be
## satisfied by an error message that happens to contain it.
func logs() -> Array[String]:
	return _logs


## Everything the ENGINE wrote: script errors, warnings, assertion failures.
##
## behaviour.ran_without_errors is entirely this list being empty. Kept separate
## from logs() because the two questions are different and merging them makes
## both unanswerable.
func engine_output() -> Array[String]:
	return _engine_output


## The engine's output, ERRORS ONLY, with the warnings dropped.
##
## THE DISTINCTION IS NOT PEDANTRY, and it was found by chasing a leak rather
## than reasoned about in advance. Headless Godot reports "ObjectDB instances
## leaked at exit" for ANY game that plays a sound -- measured, one variable at
## a time, and not fixable from the game's side. A `ran_without_errors` written
## as "engine_output is empty" therefore fails for every learner who added
## audio, which is most of them, for something they did not do.
##
## Godot warns routinely in healthy projects: a deprecated property, a missing
## optional resource, a node configuration it would prefer otherwise. None of
## those is a game that did not run.
##
## SO THE CHECK KEYS ON THIS LIST, and engine_output() stays available whole for
## anything that wants to show a learner what the engine said.
func engine_errors() -> Array[String]:
	var out: Array[String] = []
	var keeping := false
	for line in _engine_output:
		var trimmed := line.strip_edges()
		if trimmed.begins_with("ERROR:") or trimmed.begins_with("SCRIPT ERROR:") \
				or trimmed.begins_with("USER ERROR:") \
				or trimmed.begins_with("FATAL:"):
			keeping = true
			out.append(line)
			continue
		# Godot writes the source location on its own following line, indented
		# and beginning "at:". It belongs to whichever message came before it,
		# so it is kept only when that message was kept -- otherwise a warning's
		# location would be filed as an error with no error above it.
		if keeping and trimmed.begins_with("at:"):
			out.append(line)
			continue
		keeping = false
	return out


## Every observation the game reported, in order.
func records() -> Array[Dictionary]:
	return _records


## Lines that were framed like ours and carried the wrong token.
##
## REPORTED RATHER THAN DISCARDED. A non-zero count is either a learner whose
## print collides with our format -- harmless, and worth knowing -- or an
## observer from a previous run still writing into this pipe, which is a bug
## that would otherwise be invisible.
func foreign_line_count() -> int:
	return _foreign


## Lines that carried our token and could not be read afterwards.
func malformed_line_count() -> int:
	return _malformed


func pid() -> int:
	return _pid


## The exact arguments the game was launched with.
##
## For diagnostics, and for the one thing a test cannot otherwise see: WHETHER
## THE CHILD WAS HEADLESS. A learner's play-mode window is a real window on
## purpose, so nothing in the runner prevents a test from inheriting that and
## flashing game windows across somebody's desktop -- or failing outright on a
## CI runner with no display server.
##
## Checked through this rather than by scanning the test file's source, because
## the scanner kept matching ITSELF: a guard looking for a literal has that
## literal in it. Asking what actually happened cannot go wrong that way.
func launch_arguments() -> PackedStringArray:
	return _last_args


func _reset() -> void:
	_logs = []
	_engine_output = []
	_records = []
	_foreign = 0
	_malformed = 0
	_partial = ""
	_partial_err = ""
	_reason = ""
	_pid = -1
	_io = null
	_err = null


## Read both pipes.
##
## THE TWO STREAMS ARE KEPT APART, and merging them was a real defect in the
## first version of this file. They answer different questions:
##
##   * stdout is the LEARNER'S -- their print() calls, which is what
##     behaviour.log_matches searches. It also carries our framed records.
##   * stderr is the ENGINE'S -- script errors, warnings, assertion failures,
##     which is the entire substance of behaviour.ran_without_errors.
##
## Merged, neither check can work: ran_without_errors has nothing to look at
## that is distinguishable from the learner's own text, and log_matches can
## match an engine error and report that the learner printed it.
func _drain() -> void:
	_read_from(_io, true)
	_read_from(_err, false)


## `is_stdout` decides both which list a line joins and whether it may carry a
## record. The observer prints to stdout, so a framed line arriving on stderr is
## not ours by construction -- counting it as foreign rather than parsing it
## means a learner's printerr() cannot reach a graded check.
func _read_from(pipe: FileAccess, is_stdout: bool) -> void:
	if pipe == null:
		return
	var available := pipe.get_length() - pipe.get_position()
	if available <= 0:
		return
	var chunk := pipe.get_buffer(available).get_string_from_utf8()
	if chunk == "":
		return

	# ONE BUFFER PER STREAM. Sharing it interleaves two independent writers and
	# splices half a line of engine output onto half a line of the learner's.
	if is_stdout:
		_partial += chunk
	else:
		_partial_err += chunk

	# COMPLETE LINES ONLY. A read can land mid-line, and parsing half a framed
	# record reports a malformed line that was merely early -- a real bug this
	# repo has already been bitten by once, in the orphan test.
	while true:
		var buffered := _partial if is_stdout else _partial_err
		var newline := buffered.find("\n")
		if newline < 0:
			break
		var line := buffered.substr(0, newline)
		if is_stdout:
			_partial = buffered.substr(newline + 1)
		else:
			_partial_err = buffered.substr(newline + 1)
		_accept(line.trim_suffix("\r"), is_stdout)


## Whatever was left without a trailing newline when the game died.
##
## A crashing process's last words usually have no newline after them, and they
## are the ones worth having.
func _finish_partial() -> void:
	if _partial != "":
		_accept(_partial, true)
		_partial = ""
	if _partial_err != "":
		_accept(_partial_err, false)
		_partial_err = ""


func _accept(line: String, is_stdout: bool) -> void:
	if not is_stdout:
		# The engine's. It cannot carry a record: the observer prints to stdout.
		# A framed line here is somebody's printerr(), and treating it as an
		# observation is exactly the forgery the token exists to prevent.
		if Codec.decode(line, _nonce)["line"] != Codec.Line.LOG:
			_foreign += 1
		else:
			_engine_output.append(line)
		return

	var out := Codec.decode(line, _nonce)
	match out["line"]:
		Codec.Line.RECORD:
			_records.append(out["record"])
		Codec.Line.LOG:
			_logs.append(str(out["text"]))
		Codec.Line.FOREIGN:
			_foreign += 1
		_:
			_malformed += 1
