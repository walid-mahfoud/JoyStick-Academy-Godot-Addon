@tool
extends EditorPlugin

## The addon's entry point.
##
## Owns exactly three things: the sidecar's lifetime, the dock, and the bridge
## between them. Everything else lives behind one of those.

const SidecarClient := preload("res://addons/joystickacademy/protocol/sidecar_client.gd")
const SidecarLocator := preload("res://addons/joystickacademy/sidecar_locator.gd")
const Dock := preload("res://addons/joystickacademy/ui/dock.gd")

## The restart decision lives in its own file so it can be tested without a
## running editor. THIS FILE MUST NOT REIMPLEMENT IT: a second copy of the rule
## here would let the tested one and the running one drift, and the tests would
## keep passing while the addon retried forever.
const RestartPolicy := preload("res://addons/joystickacademy/restart_policy.gd")
const EditorProbe := preload("res://addons/joystickacademy/probe/editor_probe.gd")
const LogRouter := preload("res://addons/joystickacademy/log_router.gd")
const StartupDecision := preload("res://addons/joystickacademy/startup_decision.gd")
const PlayModeRunner := preload("res://addons/joystickacademy/observe/play_mode_runner.gd")
const ObservationConfig := preload("res://addons/joystickacademy/observe/observation_config.gd")

## The panel's routing. It turns a press into a request and an answer into a
## rendered view, and it is the only thing here that knows both halves.
const Shell := preload("res://addons/joystickacademy/ui/shell.gd")

## What the EDITOR has to do for the three commands a sidecar cannot. Pure and
## tested; this file only carries the plans out.
const LocalCommands := preload("res://addons/joystickacademy/ui/local_commands.gd")

var _client: SidecarClient = null
var _probe: RefCounted = EditorProbe.new()
var _dock: Control = null
var _shell: RefCounted = null
## The one file dialog, and which picker its answer belongs to.
##
## ONE DIALOG, NOT ONE PER PICKER. An EditorFileDialog is a Window; two of them
## parented to the editor is two windows to remember to free, and the editor
## itself only ever shows one at a time. The slot is what keeps the answer
## going to the right place -- see local_commands.gd.
var _dialog: EditorFileDialog = null
var _dialog_slot := ""

## The play-mode window that is open, or null when none is.
##
## ONE AT A TIME, DELIBERATELY. The runner refuses a second start while one is
## running, and two games watching the same project with the same nonce would
## interleave their records into one buffer that describes neither run.
var _runner: RefCounted = null
## Which lesson and step the open window was launched for.
##
## THE GAME OUTLIVES THE STEP. A learner can press Back, switch tabs or open
## another lesson while their game runs, and a report with no identity on it is
## credited to wherever they ended up -- which passes a step they never ran.
var _run_for := {}
var _restarts := 0
var _restart_at := -1.0
var _clock := 0.0
var _last_reason := ""


func _enter_tree() -> void:
	# BEFORE ANYTHING ELSE: take out an observer autoload left behind by a
	# session that died with a play-mode window open. It points at a script in
	# this addon, so a learner who then deletes the addon folder finds their
	# game will not start, over an entry they never added.
	#
	# Measured twice while building item 26, both times from a killed process.
	# It is cheap -- one file read that usually finds nothing -- and the failure
	# it prevents is the addon breaking a project it was a guest in.
	if PlayModeRunner.clean_up_stale_observer():
		push_warning("[JoyStick Academy] Removed a leftover play-mode observer from "
			+ "project.godot, left by a session that did not shut down cleanly.")

	_dock = Dock.new()
	_dock.name = "JoyStick Academy"
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)

	# BUILT BEFORE THE CLIENT AND OUTLIVING IT. The sidecar is started below,
	# replaced on every restart and absent in between; the shell is pointed at
	# whichever one exists through set_client, so a restart does not take the
	# panel's routing with it.
	_shell = Shell.new(_dock)

	set_process(true)
	_start_sidecar()


func _exit_tree() -> void:
	# THE PLAY WINDOW GOES FIRST, because it is the only thing here that owns a
	# line in the LEARNER'S OWN project file as well as a process.
	#
	# `install_observer`'s docstring already names this caller -- "the plugin
	# removes it on disable too, in case a window was open when the editor
	# closed" -- and the wiring was missing, so the contract was written down
	# and not kept. Without it, disabling the addon or closing the editor with a
	# window open leaves `JoyStickAcademyObserver` in their `project.godot` and
	# the game still running. Plan item 26 names the consequence exactly: when
	# they later delete the addon folder, THEIR GAME STOPS STARTING, over an
	# entry they never added and cannot place.
	#
	# `stop()` drains, kills, and removes the autoload, and is safe to call on a
	# runner that has already finished.
	if _runner != null:
		_runner.stop()
		_runner = null

	# ORDER MATTERS. Stop the process before tearing down the UI: an orphaned
	# sidecar holds a session token with no editor left to own it, and a half
	# removed dock is merely ugly.
	if _client != null:
		_client.shutdown_now()
		_client = null

	if _shell != null:
		_shell.set_client(null)
		_shell = null

	if _dialog != null:
		# Parented to the editor's own control, so it does not go with the dock.
		_dialog.queue_free()
		_dialog = null

	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _process(delta: float) -> void:
	_clock += delta

	if _client != null:
		_client.poll(delta)

	# AFTER THE POLL, NOT BEFORE. Polling is what delivers the answers, so
	# draining the views first would leave every press a frame behind the
	# response that was already sitting in the pipe.
	if _shell != null:
		_shell.pump()
		_shell.tick(delta)
		for command in _shell.take_local():
			_run_locally(command)

	# EVERY FRAME WHILE ONE IS OPEN, and that cadence is measured rather than
	# chosen: draining the game's pipe at 100 ms delivered 296 of 400 printed
	# lines, at 500 ms it delivered 58, and a child never drained at all stalls
	# outright when the pipe fills. See play_mode_runner.gd's header.
	_poll_play_window()

	if _restart_at >= 0.0 and _clock >= _restart_at:
		_restart_at = -1.0
		_start_sidecar()


## Carry out one command the sidecar cannot. The DECISION is not here -- see
## local_commands.gd -- because everything below this line needs a live editor
## and therefore cannot be tested.
func _run_locally(command: Dictionary) -> void:
	var plan := LocalCommands.plan(command)
	match str(plan.get("do", LocalCommands.DO_NOTHING)):
		LocalCommands.DO_CLIPBOARD:
			DisplayServer.clipboard_set(str(plan["text"]))

		LocalCommands.DO_OPEN_URL:
			OS.shell_open(str(plan["url"]))

		LocalCommands.DO_PICK_FILES:
			_pick_files(plan)

		LocalCommands.DO_PLAY_RUN:
			_run_play_window(plan)

		_:
			# LOUD, for the same reason a missing route is: the alternative is a
			# button that does nothing, which gives a learner nothing to search
			# for and nothing to tell support.
			push_error("[JoyStick Academy] " + str(plan.get("reason", "nothing to do")))


## Launch the learner's game with the observer in it.
##
## THE SCENE IS THE ONE THEY HAVE OPEN, not the project's main scene. Launching
## with `--path` alone runs the main scene, which is measured to be the wrong
## one: every check then evaluates a scene the learner was not working in and
## reports their work missing. `play_mode_runner` takes the path explicitly for
## exactly this reason.
func _run_play_window(plan: Dictionary) -> void:
	if _runner != null and _runner.state() == PlayModeRunner.State.RUNNING:
		# Not an error. The button is disabled while one is open; this is the
		# race where a second press got in first.
		return

	var interface := get_editor_interface()
	if interface == null:
		_report_window_problem("The editor is not ready yet. Try again in a moment.")
		return

	var root := interface.get_edited_scene_root()
	if root == null:
		_report_window_problem("Open the scene you are working in, then press Run.")
		return

	# NEVER SAVED IS ITS OWN PROBLEM, with its own words. A scene that has never
	# been written has no path to launch, and the old message told them to open a
	# scene they already had open -- which is unanswerable advice.
	if root.get_scene_file_path() == "":
		_report_window_problem("Save this scene first (Ctrl+S). The game runs "
			+ "from the file on disk, so a scene with no file cannot be run.")
		return

	# SAVE BEFORE LAUNCHING, because the game is a SECOND PROCESS reading the
	# file off disk -- it cannot see an edit that is still only in this editor's
	# memory. Without this, a learner makes exactly the change the step asked
	# for, presses Run, and every check reads the scene as it was before they
	# touched it and reports their work missing. Godot's own Play button saves
	# first for the same reason.
	#
	# A FAILED SAVE IS NOT A REASON TO RUN ANYWAY: it would run the stale file
	# and blame the learner for the result.
	var saved := interface.save_scene()
	if saved != OK:
		_report_window_problem("Could not save this scene, so the game would "
			+ "have run the older version of it. Save it yourself and try again.")
		return

	var scene := root.get_scene_file_path()

	_runner = PlayModeRunner.new()
	# REMEMBERED AT LAUNCH, sent back at close. See the sidecar's `Observed`.
	_run_for = {
		"lessonId": str(plan.get("lessonId", "")),
		"stepIndex": int(plan.get("stepIndex", 0)),
	}
	var problem := str(_runner.start(scene,
		ObservationConfig.from_watch(plan.get("watch", {}))))
	if problem != "":
		_runner = null
		_report_window_problem(problem)


## Drive an open window, and report it the moment it closes.
func _poll_play_window() -> void:
	if _runner == null:
		return
	_runner.poll()

	var state = _runner.state()
	if state == PlayModeRunner.State.RUNNING:
		return

	# FINISHED AND FAILED BOTH REPORT. A run that went wrong is an observation
	# and `ran_without_errors` is the check that wants it; only a run that never
	# started has nothing to say.
	var payload := {
		"records": _runner.records(),
		"logs": _runner.logs(),
		"engineErrors": _runner.engine_errors(),
		# WHICH RUN THIS WAS. The game outlives the step it was launched for, so
		# the sidecar checks these against what is in front of the learner now
		# and drops a report that is no longer theirs.
		"lessonId": str(_run_for.get("lessonId", "")),
		"stepIndex": int(_run_for.get("stepIndex", -1)),
		"started": true,
	}
	var reason := str(_runner.reason())
	_runner = null
	_run_for = {}

	if state == PlayModeRunner.State.FAILED and reason != "":
		# The engine's own words, in the learner's Output panel. The panel gets
		# the records regardless, so the check still speaks for itself.
		push_warning("[JoyStick Academy] the play window ended: " + reason)

	if _shell != null:
		_shell.report_window(payload)


## Say why no window opened, where the learner is looking.
func _report_window_problem(reason: String) -> void:
	push_warning("[JoyStick Academy] could not run your game: " + reason)
	# AND AN EMPTY WINDOW UP THE WIRE, so the panel stops showing "running" --
	# without it a failed launch leaves the button disabled forever and the
	# learner has nothing to press.
	# `started: false` -- A LAUNCH THAT NEVER HAPPENED IS NOT A WINDOW. The panel
	# still needs to hear, so it can stop saying "Running..." and give the button
	# back; but ingesting this as a window would build an empty-but-non-null
	# observation buffer, which every check reads as "it ran and saw nothing" and
	# `ran_without_errors` reads as a PASS. The sidecar drops it on that flag.
	if _shell != null:
		_shell.report_window({
			"records": [],
			"logs": [],
			"engineErrors": ["could not run your game: " + reason],
			"lessonId": str(_run_for.get("lessonId", "")),
			"stepIndex": int(_run_for.get("stepIndex", -1)),
			"started": false,
		})
	_run_for = {}


func _pick_files(plan: Dictionary) -> void:
	if _dialog == null:
		_dialog = EditorFileDialog.new()
		_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_dialog.files_selected.connect(_on_files_chosen)
		_dialog.file_selected.connect(func(path): _on_files_chosen(
			PackedStringArray([path])))
		# PARENTED TO THE EDITOR, NOT TO THE DOCK. A dock can be moved to
		# another slot or floated, which reparents everything under it; a modal
		# window that travels with it ends up owned by whatever it landed in.
		EditorInterface.get_base_control().add_child(_dialog)

	_dialog_slot = str(plan.get("slot", ""))
	_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILES 		if bool(plan.get("multiple", false)) 		else EditorFileDialog.FILE_MODE_OPEN_FILE
	_dialog.title = str(plan.get("title", "Choose a file"))
	_dialog.clear_filters()
	for filter in plan.get("filters", []):
		_dialog.add_filter(str(filter))
	_dialog.popup_file_dialog()


func _on_files_chosen(paths: PackedStringArray) -> void:
	if _shell == null:
		return
	_shell.apply_local_result(_dialog_slot, paths)


func _start_sidecar() -> void:
	# THE DECISION IS NOT HERE. StartupDecision.decide() owns whether to launch
	# and what to say when not, because this file needs a running editor to
	# instantiate and a rule that can only be read is a rule that drifts. What
	# is left here is display, and stopping.
	var decision := StartupDecision.decide(SidecarLocator.locate_with_source())

	if decision["action"] == StartupDecision.Action.STOP:
		# The addon LOADS and explains itself rather than erroring on every
		# frame. A plugin that spams the Output panel is worse than one that is
		# honestly unavailable, because it buries whatever the learner was
		# actually doing -- and set_process(false) is what makes "one message"
		# literal rather than aspirational.
		_announce(decision)
		_last_reason = str(decision["reason"])
		_dock.show_unavailable(_last_reason)

		# THE WINDOW GOES WITH THE PROCESSING, because `_process` is the only
		# thing that drains it. This branch is reachable with a game already
		# running -- the sidecar dies, a restart is scheduled, and by the time it
		# runs the binary is gone -- and stopping `_process` without stopping the
		# window leaves that game running forever, its pipe never drained, and
		# the observer autoload still written into the learner's project.
		if _runner != null:
			_runner.stop()
			_runner = null
			_run_for = {}

		set_process(false)
		return

	if not decision["verified"]:
		_announce(decision)

	var exe: String = decision["path"]
	_client = SidecarClient.new()
	_client.ready_received.connect(_on_ready)
	_client.disconnected.connect(_on_disconnected)
	_client.log_received.connect(_on_log)
	_client.event_received.connect(_on_event)
	_client.request_failed.connect(_on_request_failed)
	_client.probe_requested.connect(_on_probe_requested)

	_dock.show_connecting()

	var problem := _client.start(exe, _greeting())
	if problem != "":
		_client = null
		_on_disconnected(problem, "")
		return

	if _shell != null:
		_shell.set_client(_client)


## Put a startup decision's detail where its severity says it belongs.
##
## Through the SAME router the sidecar's own log lines use, so there is one
## mapping from a level to a place rather than two that can drift.
func _announce(decision: Dictionary) -> void:
	var detail := str(decision.get("detail", ""))
	if detail == "":
		return
	var line := "[JoyStick Academy] " + detail
	match LogRouter.route(str(decision.get("severity", ""))):
		LogRouter.Sink.ERROR:
			push_error(line)
		LogRouter.Sink.WARNING:
			push_warning(line)
		_:
			print(line)


func _greeting() -> Dictionary:
	return {
		"addon": _addon_version(),
		"engine": {
			"name": "godot",
			# The sidecar genuinely cannot know which Godot launched it. This is
			# the only place it finds out.
			"version": Engine.get_version_info()["string"],
		},
		"project": ProjectSettings.globalize_path("res://"),
		"device": OS.get_unique_id(),
	}


func _addon_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/joystickacademy/plugin.cfg") == OK:
		return str(cfg.get_value("plugin", "version", "0.0.0"))
	return "0.0.0"


func _on_ready(host_version: String, core_version: String) -> void:
	_restarts = RestartPolicy.on_connected()
	_last_reason = ""
	_dock.show_connected(host_version, core_version)


func _on_disconnected(reason: String, code: String) -> void:
	_client = null
	_last_reason = reason

	# EVERY VIEW THAT WAS WAITING IS TOLD. A request that will never be answered
	# leaves its view spinning, which reads as the editor having hung -- and the
	# status strip that would explain it is at the bottom of the panel, below
	# the view that is lying to them.
	if _shell != null:
		_shell.set_client(null)

	var decision := RestartPolicy.decide(code, _restarts)
	match decision["action"]:
		RestartPolicy.Action.BROKEN:
			_dock.show_unavailable(
				"JoyStick Academy could not start because its two halves do not match. "
				+ "Reinstalling the plugin should fix it.")

		RestartPolicy.Action.GIVE_UP:
			_dock.show_unavailable(
				"JoyStick Academy stopped working and could not be restarted.\n" + reason)

		RestartPolicy.Action.RETRY:
			_restarts += 1
			_restart_at = _clock + float(decision["wait"])
			_dock.show_reconnecting(int(decision["attempt"]), int(decision["of"]),
				float(decision["wait"]), reason)


func _on_log(level: String, message: String) -> void:
	# Core's own logging, surfaced where a Godot user already looks. Levels are
	# preserved: pushing everything through print() would make every warning
	# invisible among ordinary output.
	#
	# THE ROUTING DECISION IS NOT HERE. It is in log_router.gd, because this
	# file needs a running editor to instantiate and a rule that can only be
	# read is a rule that drifts -- and the drift this one invites is silent,
	# every warning becoming ordinary output with nothing failing.
	match LogRouter.route(level):
		LogRouter.Sink.ERROR:
			push_error("[JoyStick Academy] " + message)
		LogRouter.Sink.WARNING:
			push_warning("[JoyStick Academy] " + message)
		_:
			print("[JoyStick Academy] " + message)


## Core is asking the editor something only the editor knows.
##
## THIS HANDLER MUST NOT ISSUE A REQUEST. The host runs requests on one serial
## worker, so a request from here would queue behind the very one waiting for
## this answer, and nothing in the protocol could detect it. Read the scene tree
## and answer; that is all.
##
## It runs on the editor's main thread, inside _process, so it must also be
## quick: the host gives a probe five seconds before giving up on that check.
func _on_probe_requested(id: int, method: String, args: Dictionary) -> void:
	if _client == null:
		return

	var result: Variant = _probe.handle(method, args)
	if result == null:
		# UNSUPPORTED rather than failed, and the distinction is the author's.
		# "Godot cannot answer this KIND of question" is something they need to
		# learn at authoring time; "it tried and something went wrong" is a
		# fault that may not recur. Flattening them loses the one that matters.
		_client.refuse_probe(id)
		return

	_client.answer_probe(id, result)


func _on_event(event_name: String, data: Dictionary) -> void:
	# BOTH, and they want different things from it. The dock keeps the name for
	# the Diagnostics view; the shell renders the ones it recognises into the
	# view they belong to.
	if _dock != null:
		_dock.on_event(event_name, data)
	if _shell != null:
		_shell.on_event(event_name, data)


func _on_request_failed(id: int, code: String) -> void:
	if _dock != null:
		_dock.on_request_failed(id, code)


## For the diagnostics view and for tests.
func connection_state() -> String:
	if _client == null:
		return "stopped"
	match _client.state():
		SidecarClient.State.STARTING:
			return "starting"
		SidecarClient.State.READY:
			return "ready"
		SidecarClient.State.FAILED:
			return "failed"
		_:
			return "stopped"


func last_reason() -> String:
	return _last_reason
