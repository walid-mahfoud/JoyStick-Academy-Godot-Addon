extends Node

## Watches the learner's game while it runs, from inside it.
##
## THIS SCRIPT RUNS IN A DIFFERENT PROCESS FROM EVERYTHING ELSE IN THE ADDON.
## Godot launches the game as its own process; the addon adds this as an
## autoload, launches the game, and reads what this prints from the game's
## stdout. Nothing here can call into the addon, the sidecar or Core -- the only
## channel is print().
##
## NOT @tool, DELIBERATELY. An autoload marked @tool also runs inside the
## EDITOR, where there is no window to observe and no nonce on the command line;
## it would attach itself to the editor's own tree and print into the editor's
## Output panel on every project open.
##
## HOW IT IS CONFIGURED. Through the game's own command line, after `--`:
##
##     --jsa-nonce=<32 hex>      the run's token; without it this does nothing
##     --jsa-config=<base64>     what to watch; see observation_config.gd
##
## A run with no token is a game the learner started themselves -- pressing F5
## with the addon installed -- and this must be silent then. Printing
## observations into a session nobody is observing is noise in the one place a
## learner reads their own output.
##
## WHAT IT SAMPLES, AND WHEN. Once after the first frame -- the first moment the
## scene is what the learner built -- then a tick every tenth of a second, then
## a closing record on the way out. Contact is the exception and runs on the
## PHYSICS frame, because that is the only clock on which an overlap is a fact.
##
## THE TICKS ARE NOT REDUNDANCE. THE LAST ONE IS THE END. Measured, on this
## engine: by the time an autoload receives NOTIFICATION_EXIT_TREE, the scene is
## ALREADY GONE -- get_tree().current_scene is null and the watched nodes cannot
## be read. The bye record carries the scene name for exactly this reason, and
## it comes back empty every time.
##
## So a live end sample is not something this can take. What it can do is
## remember the last position it genuinely read and report THAT as the end,
## marked stale so nothing downstream mistakes it for a reading taken at the
## final instant. The guarantee is precise and worth stating as such: the end
## position is a live reading from no more than TICK_SECONDS before the process
## stopped.
##
## That also covers the harder case the ticks were written for -- a process
## killed, crashed, or closed by the window manager, which does not reliably get
## its last print() through the pipe at all. Without ticks those runs would
## report a start and no end, and "did it move" would be unanswerable for a game
## that ran perfectly and was simply stopped.
##
## A TENTH OF A SECOND, NOT A FRAME, and the arithmetic is the argument. Ten
## lines per watched object per second, against a transport measured to carry
## 400 lines comfortably when drained every 16-50 ms. Sixty per second per
## object would put a learner's game through a pipe; one per second would make
## the end up to a second stale on a fast-moving object.
##
## EVERY LATCHING KIND EMITS ON THE EDGE, NOT ONLY AT THE END. Audio, animation
## states and contact all answer "did this ever happen", and all three would be
## lost entirely if they were only reported in the closing record -- which is
## exactly the record a killed process does not get to print. Each one emits the
## moment it becomes true, and repeats itself in the end record.

const Codec := preload("res://addons/joystickacademy/observe/observation_codec.gd")
const Config := preload("res://addons/joystickacademy/observe/observation_config.gd")

## How often to sample, in seconds. See the header: this is the WORST-CASE AGE
## of the end position, because the last tick is what the end record reports.
const TICK_SECONDS := 0.1

## The three classes that make a noise.
##
## ALL THREE BY NAME, because they are not one family. MEASURED on 4.5.1:
## `AudioStreamPlayer2D.is_class("AudioStreamPlayer")` is FALSE -- the 2D and 3D
## players descend from Node2D and Node3D, not from the plain one. A check
## written against the base name alone finds nothing in a 2D game, which is most
## beginner games.
const AUDIO_CLASSES := [
	"AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D",
]

## The engine's own resting gap, per dimension, in that dimension's units.
##
## MEASURED, and these are the numbers the contact margin is derived from:
## CharacterBody3D.safe_margin is 0.001 and CharacterBody2D.safe_margin is 0.08.
## A character standing on a floor is held exactly that far OFF it, so a query
## with no margin reports the single commonest check in any beginner game --
## "did the player land on the ground" -- as no contact at all.
const SAFE_MARGIN_3D := 0.001
const SAFE_MARGIN_2D := 0.08

## How much of the engine's own gap to allow for, and how much of an object's
## own size to allow at most.
##
## THE MARGIN IS A TRADE WITH NO FREE SIDE, and both halves are here because
## either alone is wrong. A fixed margin large enough to catch a resting
## character makes two SMALL objects read as touching half a diameter apart --
## measured at 39 mm in 3D at a margin of 0.04. A margin scaled purely to the
## object shrinks below the engine's own resting gap for anything small, and
## then a small character never lands on anything.
##
## So: ten times the engine's gap, or a twentieth of the object's own radius,
## WHICHEVER IS SMALLER. A 0.5-radius 3D character gets 0.01 -- ten times the
## gap it actually leaves. A 0.01-radius pebble gets 0.0005, a twentieth of its
## own size rather than half of it.
##
## WHAT THIS CANNOT DO, said plainly rather than left to be discovered: an
## object smaller than about twice the engine's safe margin -- under 2 px in 2D
## -- gets a margin below the resting gap, and its landings are missed. That is
## a genuine floor, not a tuning choice, and a check on objects that small
## should not be written.
const MARGIN_SAFE_MULTIPLE := 10.0
const MARGIN_RADIUS_FRACTION := 0.05

## Variant types a field check can compare, reported natively on the wire.
const COMPARABLE_NATIVE := [
	TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME,
]

## Variant types a field check can compare, reported as a canonical string.
##
## var_to_str gives a stable, round-trippable spelling -- "Vector3(1, 2, 3)" --
## which is what a `field_equals` step is written against anyway. Sending the
## raw value would not survive JSON.
const COMPARABLE_AS_TEXT := [
	TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4,
	TYPE_VECTOR4I, TYPE_COLOR, TYPE_RECT2, TYPE_RECT2I, TYPE_QUATERNION,
	TYPE_PLANE, TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_AABB,
	TYPE_NODE_PATH,
]

var _nonce := ""
var _config: RefCounted = null
var _sampled_start := false
var _since_tick := 0.0

## The last position genuinely read for each watched name. This is what the end
## record reports, because by the time the end arrives the scene is gone.
var _last_seen := {}

## Per audio target: {"started": bool, "seen": {player_path: was_playing},
## "count": int, "edge_emitted": bool}.
var _audio := {}

## Per animation target: {"state": String, "end_state": String,
## "entered": PackedStringArray, "note": String}.
var _anim := {}

## Per contact pair key: {"touching": bool, "latched": bool, "margin": float,
## "edge_emitted": bool, "note": String}.
var _contact := {}

## The last record that genuinely read a value, per field. THE SAME CACHE THE
## POSITIONS KEEP, and for the same reason, which is worth stating because
## building this without one produced a working check that could never pass.
##
## MEASURED: every field at `end` reported "absent: no node named Stats",
## because at NOTIFICATION_EXIT_TREE the scene is already gone. A kind whose
## entire question is "was it different at the end than at the start" then has
## no end to compare, on every run, forever -- and it fails as an absent node
## rather than as a broken check, which is the worst way to fail.
var _last_field := {}


func _ready() -> void:
	_read_arguments()
	if _nonce == "":
		# Not our run. Say nothing at all.
		set_process(false)
		set_physics_process(false)
		return

	_emit({"k": Codec.KIND_READY, "scene": _scene_name()})

	if _config.error != "":
		# A configuration that could not be read is NOT an empty one. Reporting
		# it as "watching nothing" would make every check on this run pass for
		# no reason; reporting it as a ready record with a reason lets the
		# runner refuse the window instead.
		_emit({"k": Codec.KIND_READY, "scene": _scene_name(),
			"config_error": _config.error})

	set_physics_process(not _config.contact.is_empty())

	# The tree is not finished at _ready: nodes added by other autoloads and by
	# the scene's own _ready have not all arrived. One deferred frame later is
	# the first moment the scene is what the learner built.
	call_deferred("_sample_start")


func _read_arguments() -> void:
	var encoded := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(Codec.ARG_NONCE_PREFIX):
			_nonce = arg.substr(Codec.ARG_NONCE_PREFIX.length())
		elif arg.begins_with(Codec.ARG_CONFIG_PREFIX):
			encoded = arg.substr(Codec.ARG_CONFIG_PREFIX.length())
	_config = Config.new()
	_config.parse(encoded)


func _sample_start() -> void:
	if _sampled_start:
		return
	_sampled_start = true
	_arm_audio()
	_arm_anim()
	_arm_contact()
	_sample_all("start")


func _process(delta: float) -> void:
	_since_tick += delta
	if _since_tick < TICK_SECONDS:
		return
	_since_tick = 0.0
	_sample_all("tick")


## The end of the window.
##
## NOTIFICATION_EXIT_TREE, not SceneTree.tree_exiting -- THERE IS NO SUCH
## SIGNAL. tree_exiting belongs to Node; SceneTree does not have it, and
## connecting to it fails at runtime inside the game where nobody sees the
## error. Measured: the first version of this file did exactly that, and the
## only symptom was that no end sample and no bye record ever arrived.
func _notification(what: int) -> void:
	if what != NOTIFICATION_EXIT_TREE:
		return
	if _nonce == "":
		return
	# If the game closed before the deferred start sample ran -- a scene that
	# quits in _ready, which a learner writes more often than you would think --
	# take it now, so the pair is complete rather than half missing.
	_sample_start()
	_emit_end()
	# The scene name at the moment of exit. Diagnostic rather than decorative:
	# measured, it is EMPTY every time, which is the fact that makes _emit_end
	# report from cache rather than from the tree.
	_emit({"k": Codec.KIND_BYE, "scene": _scene_name()})


## The closing record for everything being watched.
##
## For positions a live read is attempted first and is expected to fail -- see
## the header. Any name it cannot read live is reported from the last live
## reading instead, with `stale` set so a check can tell the two apart. A name
## never seen at all is reported as nothing, because "absent" and "at the
## origin" are different answers and only one of them is true.
##
## The LATCHING kinds -- audio, animation, contact -- report from their own
## accumulated state, which needs no tree at all and is therefore the one part
## of the end record that is always complete.
func _emit_end() -> void:
	for name in _config.watch:
		var live := _read(name)
		if live != null:
			_last_seen[name] = live
			_emit(_transform_record(name, "end", live, false))
		elif _last_seen.has(name):
			_emit(_transform_record(name, "end", _last_seen[name], true))

	for name in _config.audio:
		_emit_audio(name, "end")
	for name in _config.anim:
		_emit_anim(name, "end")
	for spec in _config.field:
		_emit_field(spec, "end")
	for spec in _config.contact:
		_emit_contact(spec, "end")


static func _field_key(spec: Dictionary) -> String:
	return JSON.stringify([spec["n"], spec["p"]])


static func _transform_record(name: String, at: String, position: Vector3,
		stale: bool) -> Dictionary:
	return {
		"k": Codec.KIND_TRANSFORM,
		"n": name,
		"at": at,
		"x": position.x,
		"y": position.y,
		"z": position.z,
		# Present on every transform so a reader never has to distinguish
		# "false" from "the field is missing because this observer is older".
		"stale": stale,
	}


func _sample_all(at: String) -> void:
	for name in _config.watch:
		var position := _read(name)
		if position == null:
			# Absent is not zero. A check that cannot find the object at one end
			# of the window must be able to say so rather than reporting a
			# position of (0,0,0), which is a real place a thing can be.
			continue
		_last_seen[name] = position
		_emit(_transform_record(name, at, position, false))

	_poll_audio(at)
	_poll_anim(at)
	for spec in _config.field:
		_emit_field(spec, at)


# -------------------------------------------------------------------- audio

## Record what was ALREADY playing before the window is credited with anything.
##
## THIS IS THE WHOLE DIFFERENCE BETWEEN A CHECK AND A FALSE GREEN. Measured:
## with no baseline, a scene holding an AudioStreamPlayer with autoplay set --
## background music, which is the single commonest audio in a beginner project
## -- reports "audio played" in a run where the learner's code never fired. The
## poll below is RISING-EDGE against this baseline, so "was playing" and
## "started playing" stop being the same observation.
func _arm_audio() -> void:
	for name in _config.audio:
		var players := _find_audio_players(name)
		var seen := {}
		for player in players:
			seen[player.get_instance_id()] = bool(player.get("playing"))
			# The signal half of the pair. MEASURED, 20 trials each: the
			# `finished` signal catches 20/20 one-shot sounds and 0/20 loops,
			# while polling catches 9-14/20 one-shots and 20/20 loops. A
			# one-shot shorter than the poll interval starts and ends between
			# two samples; a loop never finishes. Neither detector alone is a
			# check, and together they are 20/20 on both.
			if not player.is_connected("finished", _on_audio_finished):
				player.connect("finished", _on_audio_finished.bind(name))
		_audio[name] = {
			"started": false, "seen": seen, "count": players.size(),
			"edge_emitted": false,
		}


func _on_audio_finished(name: String) -> void:
	if not _audio.has(name):
		return
	# A sound that finished during the window started during the window, unless
	# it was already playing when we armed -- and a sound that was already
	# playing and then finished DID play during the window, which is the
	# question. Either way this is a true edge.
	_latch_audio(name)


func _latch_audio(name: String) -> void:
	var state: Dictionary = _audio[name]
	if state["started"]:
		return
	state["started"] = true
	if not state["edge_emitted"]:
		state["edge_emitted"] = true
		# Emit the moment it becomes true. A killed process never prints its end
		# record, and this is the only kind where that would lose the answer
		# entirely rather than making it stale.
		_emit_audio(name, "tick")


func _poll_audio(_at: String) -> void:
	for name in _config.audio:
		if not _audio.has(name):
			continue
		var state: Dictionary = _audio[name]
		if state["started"]:
			continue
		var seen: Dictionary = state["seen"]
		var players := _find_audio_players(name)
		state["count"] = players.size()
		for player in players:
			var id := player.get_instance_id()
			var now := bool(player.get("playing"))
			var before: bool = seen.get(id, false)
			seen[id] = now
			# RISING EDGE ONLY. `now and not before` is the entire correction;
			# `now` alone is the false green the baseline exists to prevent.
			# A player that appeared mid-window has no `before`, and defaulting
			# it to false is right: it was not playing a moment ago because it
			# was not there.
			if now and not before:
				_latch_audio(name)
				break


func _emit_audio(name: String, at: String) -> void:
	var state: Dictionary = _audio.get(name, {})
	_emit({
		"k": Codec.KIND_AUDIO,
		"n": name,
		"at": at,
		"started": bool(state.get("started", false)),
		# How many players were found at all. A check that never goes green
		# because the target has no audio under it is a different problem from
		# one that never goes green because the sound did not fire, and a count
		# of zero is what tells them apart.
		"players": int(state.get("count", 0)),
	})


## Every audio player at or under this name, at any depth.
##
## THE TARGET IS AN ANCESTOR, NOT THE PLAYER. A learner parents the
## AudioStreamPlayer under the thing that makes the noise, so a node-only
## reading of `audio: ["Player"]` is false for the ordinary arrangement.
func _find_audio_players(name: String) -> Array[Node]:
	var out: Array[Node] = []
	var root := _find(name)
	if root == null:
		return out
	_collect_by_class(root, AUDIO_CLASSES, out)
	return out


static func _collect_by_class(node: Node, classes: Array, out: Array[Node]) -> void:
	for class_named in classes:
		if node.is_class(class_named):
			out.append(node)
			break
	for child in node.get_children():
		_collect_by_class(child, classes, out)


# ---------------------------------------------------------------- animation

func _arm_anim() -> void:
	for name in _config.anim:
		_anim[name] = {
			"state": "", "end_state": "", "entered": PackedStringArray(),
			"note": "",
		}
		var found := _find_animation_trees(name)
		if found.size() > 1:
			# AMBIGUOUS, NOT RESOLVED BY TREE ORDER. Picking the first match
			# makes the answer depend on the order the learner happened to add
			# their nodes, which is the kind of check that passes on one machine
			# and fails on another for no visible reason.
			_anim[name]["note"] = "ambiguous: %d AnimationTree nodes under %s" % [
				found.size(), name]
		elif found.is_empty():
			_anim[name]["note"] = _no_tree_reason(name)


## Why there is no AnimationTree here, in the learner's terms.
##
## AnimatedSprite2D IS THE DEFAULT BEGINNER 2D PATH and it has no state machine
## at all -- no AnimationTree, no named states, nothing get_current_node() could
## answer. Left unsaid it is a silent false: a check that can never pass against
## a project that is not doing anything wrong. Named here, the runner can report
## it as unsupported for this project rather than as a failure.
func _no_tree_reason(name: String) -> String:
	var root := _find(name)
	if root == null:
		return "absent: no node named %s" % name
	var sprites: Array[Node] = []
	_collect_by_class(root, ["AnimatedSprite2D", "AnimatedSprite3D"], sprites)
	if not sprites.is_empty():
		return ("unsupported: %s animates with AnimatedSprite, which has no "
			+ "state machine to enter") % name
	return "absent: no AnimationTree under %s" % name


func _poll_anim(at: String) -> void:
	for name in _config.anim:
		if not _anim.has(name):
			continue
		var state: Dictionary = _anim[name]
		if state["note"] != "":
			continue
		var reading := _read_anim_state(name)
		if reading.is_empty():
			continue
		var current: String = reading["state"]
		if current == "" or current == state["state"]:
			continue
		state["state"] = current
		if not reading["entered"]:
			continue
		var entered: PackedStringArray = state["entered"]
		if entered.has(current):
			continue
		entered.append(current)
		state["entered"] = entered
		# THE STATE THE RUN ENDS IN, which is a DIFFERENT question from the last
		# state the machine reported and the difference is a false green.
		#
		# A state whose clip is missing still becomes `state` -- the machine
		# really did travel to it -- and handing THAT to a check asking "did it
		# end in Phantom" answers yes for an animation that never played a
		# frame. Only a state that passed the clip-length gate is recorded here,
		# so the two can never be confused downstream.
		state["end_state"] = current
		_emit_anim_change(name, at, reading)


## One live reading of the state machine, or {} when there is nothing to read.
##
## `entered` IS GATED ON CLIP LENGTH, and that gate is the correction that makes
## this a check. MEASURED: a state whose clip is missing, and a tree with no
## AnimationPlayer attached, both report `playing = true` with a current node
## name -- so "the state machine says it is in Run" is true for an animation
## that does not exist and never played a frame. The same reading reports
## `get_current_length() == 0.0`, while a genuinely entered state reports its
## real clip length on the very first sample.
func _read_anim_state(name: String) -> Dictionary:
	var trees := _find_animation_trees(name)
	if trees.size() != 1:
		return {}
	var playback = trees[0].get("parameters/playback")
	if playback == null or not playback.has_method("get_current_node"):
		return {}
	var length := 0.0
	if playback.has_method("get_current_length"):
		length = float(playback.get_current_length())
	var playing := true
	if playback.has_method("is_playing"):
		playing = bool(playback.is_playing())
	return {
		"state": str(playback.get_current_node()),
		"len": length,
		"entered": playing and length > 0.0,
	}


func _emit_anim_change(name: String, at: String, reading: Dictionary) -> void:
	_emit({
		"k": Codec.KIND_ANIM_STATE,
		"n": name,
		"at": at,
		# NESTED STATES ARE REPORTED AS "Container/State", verbatim, because
		# that is what the engine calls them. Rewriting it to the bare authored
		# name here would make a check asking for the qualified form impossible;
		# leaving it means a check asking for the bare name must say so. The
		# authoring guide owns that choice -- this reports what was read.
		"state": reading["state"],
		"len": reading["len"],
		"entered": reading["entered"],
		"note": "",
	})


func _emit_anim(name: String, at: String) -> void:
	var state: Dictionary = _anim.get(name, {})
	var entered: PackedStringArray = state.get("entered", PackedStringArray())
	_emit({
		"k": Codec.KIND_ANIM_STATE,
		"n": name,
		"at": at,
		"state": str(state.get("state", "")),
		# What the SEAM to Core reads. Core asks "did this object end in state
		# X" and compares against one token, so it needs the last GENUINELY
		# entered state rather than the last state reported.
		"end_state": str(state.get("end_state", "")),
		"len": 0.0,
		"entered": entered.size() > 0,
		# Every state this run genuinely entered, in order. The end record is
		# the complete answer; the per-change records above are what survives a
		# process that is killed before it can print this one.
		"states": Array(entered),
		"note": str(state.get("note", "")),
	})


func _find_animation_trees(name: String) -> Array[Node]:
	var out: Array[Node] = []
	var root := _find(name)
	if root == null:
		return out
	_collect_by_class(root, ["AnimationTree"], out)
	return out


# -------------------------------------------------------------------- field

## One property, read live.
##
## THE READER IS NOT THE HARD PART -- get_indexed covers built-in properties,
## nested struct components and the learner's own script variables identically,
## headless or not, at about 10 microseconds a read. Two things around it are:
##
## 1. ARRAYS AND DICTIONARIES COME BACK AS LIVE REFERENCES. A start snapshot of
##    a learner's inventory is the SAME OBJECT as the end snapshot, so a change
##    they demonstrably made compares equal to itself and the check reports no
##    change. Measured: [999,20,30,40] appended to, and the "snapshot" grew with
##    it. Everything read here is deep-duplicated at sample time.
## 2. "I READ SOMETHING" IS NOT "I READ A VALUE". `queue_free` reads
##    successfully and returns a Callable; measured, typeof 25. A path that
##    resolves to something with no comparison is reported ok = false WITH THE
##    TYPE NAME, so an author sees why their step can never pass.
func _emit_field(spec: Dictionary, at: String) -> void:
	var name: String = spec["n"]
	var path: String = spec["p"]
	var record := {
		"k": Codec.KIND_FIELD,
		"n": name,
		"p": path,
		"at": at,
		"ok": false,
		"t": "",
		"v": null,
		"why": "",
		# Present on every field record so a reader never has to tell "false"
		# from "this observer predates the field cache".
		"stale": false,
	}

	var node := _find(name)
	if node == null:
		# THE SCENE IS GONE AT THE END OF THE WINDOW, always -- so at `end` this
		# branch is the normal path rather than the error path, and answering it
		# with "absent" would make field_changed_during_play unanswerable on
		# every run. Report the last value genuinely read, marked stale, exactly
		# as the positions do.
		var cached = _last_field.get(_field_key(spec), null)
		if at == "end" and cached != null:
			var carried: Dictionary = cached.duplicate()
			carried["at"] = "end"
			carried["stale"] = true
			_emit(carried)
			return
		record["why"] = "absent: no node named %s" % name
		_emit(record)
		return

	var raw = node.get_indexed(NodePath(path))
	var type := typeof(raw)
	record["t"] = type_string(type)

	if type == TYPE_NIL:
		# MEASURED: get_indexed on a property that is not there returns null
		# and pushes no error. A property legitimately holding null is reported
		# the same way, which is a known and documented conflation -- the
		# alternative is walking get_property_list on every sample.
		record["why"] = "no property %s on %s, or its value is null" % [path, name]
		_emit(record)
		return

	if COMPARABLE_NATIVE.has(type):
		record["ok"] = true
		record["v"] = str(raw) if type == TYPE_STRING_NAME else raw
	elif COMPARABLE_AS_TEXT.has(type):
		record["ok"] = true
		record["v"] = var_to_str(raw)
	elif type == TYPE_DICTIONARY:
		# A DICTIONARY IS REACHABLE ONE ENTRY AT A TIME, and the advice names
		# the syntax that works. MEASURED on 4.5.1: `bag:coins` returns the
		# entry as an int, so a check on one key lands in the native branch
		# above and passes normally.
		record["why"] = ("%s is a Dictionary; name one entry instead, as "
			+ "%s:<key>") % [path, path]
		record["v"] = var_to_str(raw.duplicate(true))
	elif type == TYPE_ARRAY:
		# AN ARRAY IS NOT REACHABLE AT ALL, and this is the correction that the
		# Dictionary advice above would otherwise have papered over. MEASURED:
		# `inventory:0` and `inventory:1` BOTH return null, and `inventory:size`
		# returns the method as a Callable rather than the count. There is no
		# path to an element and no path to a length, so the only honest advice
		# is to expose what the check needs as its own variable.
		record["why"] = ("%s is an Array, which has no readable element or "
			+ "length path; expose what the check needs as its own variable, "
			+ "such as item_count") % path
		record["v"] = var_to_str(raw.duplicate(true))
	else:
		record["why"] = "%s reads as %s, which has no comparison" % [
			path, type_string(type)]

	if record["ok"]:
		# Cached ONLY when it genuinely read a comparable value. Caching the
		# refusals would make the end record repeat a complaint as though it
		# were a reading.
		_last_field[_field_key(spec)] = record.duplicate()

	_emit(record)


# ------------------------------------------------------------------ contact

## Arm one query per pair, and work out the margin from the shapes.
##
## PER-PHYSICS-FRAME SHAPE QUERY, NOT SIGNALS, and the reason is measured: a
## signal-only implementation is silent for CharacterBody against StaticBody --
## the commonest pairing in any beginner game, a player on a floor -- and silent
## by default for RigidBody too, because `contact_monitor` is false and
## `max_contacts_reported` is 0 out of the box and no learner changes either.
func _arm_contact() -> void:
	for spec in _config.contact:
		var key := _contact_key(spec)
		var a := _find(spec["a"])
		var b := _find(spec["b"])
		var note := ""
		if a == null:
			note = "absent: no node named %s" % spec["a"]
		elif b == null:
			note = "absent: no node named %s" % spec["b"]
		elif not _is_collision_object(a):
			note = "%s is a %s, which has no collision shape" % [
				spec["a"], a.get_class()]
		elif not _is_collision_object(b):
			note = "%s is a %s, which has no collision shape" % [
				spec["b"], b.get_class()]
		elif _is_2d(a) != _is_2d(b):
			note = "%s and %s are in different dimensions" % [spec["a"], spec["b"]]
		_contact[key] = {
			"touching": false, "latched": false, "edge_emitted": false,
			"margin": 0.0 if a == null else _margin_for(a), "note": note,
		}


func _physics_process(_delta: float) -> void:
	if not _sampled_start:
		return
	for spec in _config.contact:
		var key := _contact_key(spec)
		var state: Dictionary = _contact.get(key, {})
		if state.is_empty() or state["note"] != "":
			continue
		var touching := _query_overlap(spec["a"], spec["b"], state["margin"])
		state["touching"] = touching
		if touching and not state["latched"]:
			state["latched"] = true
			if not state["edge_emitted"]:
				state["edge_emitted"] = true
				_emit_contact(spec, "tick")


## Do these two overlap right now?
##
## TWO CORRECTIONS ARE LOAD-BEARING HERE.
##
## The MASK IS LEFT AT ITS DEFAULT of 0xFFFFFFFF. Setting it from the querying
## object's own collision_mask -- the obvious thing -- silently loses the case
## where B scans A but A does not scan B, which is an ordinary arrangement and
## the commonest learner check among them. The layer question is answered AFTER
## the query, on the union of both directions, so a pair that genuinely cannot
## interact still reports nothing.
##
## `collide_with_areas` IS TURNED ON, and the direction it matters in is worth
## being exact about, because the first version of this comment had it backwards
## and a mutation test caught that rather than a reading.
##
## It governs what the query FINDS, not what does the finding. The shapes come
## from the first object, so an Area as the FIRST object is queried normally
## whatever this is set to. It is an Area as the SECOND object -- "did the
## player reach the checkpoint", "did the coin get collected", "did anything
## enter the damage zone" -- that the default of FALSE makes invisible. That is
## also the commoner spelling of the two, since the trigger is usually the thing
## being reached.
func _query_overlap(a_name: String, b_name: String, margin: float) -> bool:
	var a := _find(a_name)
	var b := _find(b_name)
	if a == null or b == null:
		return false

	var space = _space_state(a)
	if space == null:
		return false

	# The layer question, answered once for the pair rather than inside the
	# query. Either direction is enough: physics responds if EITHER object
	# scans the other's layer.
	var a_layer := int(a.get("collision_layer"))
	var a_mask := int(a.get("collision_mask"))
	var b_layer := int(b.get("collision_layer"))
	var b_mask := int(b.get("collision_mask"))
	if (a_layer & b_mask) == 0 and (b_layer & a_mask) == 0:
		return false

	var b_id := b.get_instance_id()
	for entry in _shapes_of(a):
		var params = (PhysicsShapeQueryParameters2D.new() if _is_2d(a)
			else PhysicsShapeQueryParameters3D.new())
		params.shape = entry["shape"]
		params.transform = entry["transform"]
		params.margin = margin
		params.collide_with_bodies = true
		params.collide_with_areas = true
		params.exclude = [a.get_rid()]
		for hit in space.intersect_shape(params, 32):
			var collider = hit.get("collider")
			if collider != null and collider.get_instance_id() == b_id:
				return true
	return false


func _emit_contact(spec: Dictionary, at: String) -> void:
	var state: Dictionary = _contact.get(_contact_key(spec), {})
	_emit({
		"k": Codec.KIND_CONTACT,
		"a": spec["a"],
		"b": spec["b"],
		"at": at,
		# OVERLAP, NOT CONTACT, and the name is the honest one on the wire even
		# though the verifier kind is called contact. Two shapes that pass
		# through each other overlap; a one-way platform crossed from beneath
		# reports touching at every margin including zero, measured. A check
		# author reading this record should see what was actually measured.
		"touching": bool(state.get("latched", false)),
		"now": bool(state.get("touching", false)),
		"margin": float(state.get("margin", 0.0)),
		"note": str(state.get("note", "")),
	})


## A key for one ordered pair.
##
## JSON RATHER THAN A SEPARATOR CHARACTER, and the first attempt here is why:
## it joined the two names with a NUL, on the reasoning that a NUL cannot
## occur in a node name. It cannot -- but GDSCRIPT ENDS THE STRING LITERAL
## THERE, so the file failed to compile with "Unterminated string", and
## because this file is an AUTOLOAD INSIDE THE LEARNER'S GAME the only
## symptom was that every record for the whole run was missing. A dead
## observer and an observer with nothing to say look identical from the
## other end of the pipe.
##
## Every other separator has the ordinary problem instead: Node.name strips
## only a dot, a colon, an at-sign, a slash, a quote and a percent, so a
## comma, a pipe, a newline and a tab are all characters a learner can put
## in a name. Quoting sidesteps the question rather than answering it.
##
## The pair is ORDERED, because a check names one object and then the other,
## and reporting A-touched-B under the key B-touched-A would cross two
## different steps that happen to involve the same two objects.
static func _contact_key(spec: Dictionary) -> String:
	return JSON.stringify([spec["a"], spec["b"]])


## The margin for this object, from its own size. See MARGIN_SAFE_MULTIPLE.
func _margin_for(node: Node) -> float:
	var safe := SAFE_MARGIN_2D if _is_2d(node) else SAFE_MARGIN_3D
	var cap := safe * MARGIN_SAFE_MULTIPLE
	var radius := _radius_of(node)
	if radius <= 0.0:
		return cap
	return minf(cap, radius * MARGIN_RADIUS_FRACTION)


## The largest INSCRIBED radius among this object's shapes, in its own units.
##
## INSCRIBED, NOT CIRCUMSCRIBED, and the difference is a factor of root two that
## a test caught rather than a reading did. The first version took half the
## bounding box's DIAGONAL, which for a circle of radius 2 answers 2.83 -- so
## the margin came out 41 per cent too generous for every round shape, in the
## direction that reports objects as touching when they are not.
##
## The bug hid behind the cap: the 16 px ball in the fixture was clamped to the
## absolute bound either way, and the assertion on it passed by coincidence. It
## took a SECOND, much smaller shape in the same run -- small enough to sit
## under the cap -- for the two margins to disagree with the arithmetic.
##
## Half the smallest extent is the conservative reading: for a circle it is the
## true radius, and for a long thin wall it is the thickness rather than the
## length, which is the dimension a contact with it actually turns on.
##
## Computed ONCE, at arm time, and cached with the pair. Shape2D.get_rect() and
## Shape3D.get_debug_mesh().get_aabb() both exist and both were measured on
## 4.5.1; the 3D one builds a mesh, which is not something to do sixty times a
## second.
func _radius_of(node: Node) -> float:
	var best := 0.0
	for entry in _shapes_of(node):
		var shape = entry["shape"]
		var radius := 0.0
		if shape is Shape2D:
			var size := (shape as Shape2D).get_rect().size
			radius = minf(size.x, size.y) * 0.5
		elif shape is Shape3D:
			var mesh := (shape as Shape3D).get_debug_mesh()
			if mesh != null:
				var extent := mesh.get_aabb().size
				radius = minf(extent.x, minf(extent.y, extent.z)) * 0.5
		best = maxf(best, radius)
	return best


## Every shape this collision object owns, with its transform in world space.
func _shapes_of(node: Node) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _is_collision_object(node):
		return out
	for owner_id in node.get_shape_owners():
		var local = node.shape_owner_get_transform(owner_id)
		var world = node.get("global_transform") * local
		for i in node.shape_owner_get_shape_count(owner_id):
			var shape = node.shape_owner_get_shape(owner_id, i)
			if shape != null:
				out.append({"shape": shape, "transform": world})
	return out


static func _is_collision_object(node: Node) -> bool:
	return node is CollisionObject2D or node is CollisionObject3D


static func _is_2d(node: Node) -> bool:
	return node is CollisionObject2D


func _space_state(node: Node):
	if node is CollisionObject2D:
		var world2 := (node as Node2D).get_world_2d()
		return world2.direct_space_state if world2 != null else null
	if node is CollisionObject3D:
		var world3 := (node as Node3D).get_world_3d()
		return world3.direct_space_state if world3 != null else null
	return null


# ------------------------------------------------------------------- shared

## One live position reading, or null when the node is not there to read.
func _read(name: String) -> Variant:
	var node := _find(name)
	if node == null:
		return null
	return _position_of(node)


## The first node with this name, anywhere under the scene root.
func _find(name: String) -> Node:
	var root := get_tree().current_scene
	if root == null:
		return null
	if root.name == name:
		return root
	return _search(root, name)


func _search(node: Node, name: String) -> Node:
	for child in node.get_children():
		if child.name == name:
			return child
		var found := _search(child, name)
		if found != null:
			return found
	return null


## A node's position as a Vector3, or null when it has none.
##
## 2D AND 3D ARE BOTH REPORTED AS THREE NUMBERS, with z = 0 for 2D. The
## alternative is two record shapes and a check that has to know which engine
## dimension the learner chose. What a check DOES need to know is that GODOT'S
## 2D Y AXIS POINTS DOWN: a Unity-authored "moved up" passes here when the
## object falls. That belongs in the authoring guide rather than in a silent
## sign flip, which would make every honestly-authored Godot step wrong instead.
func _position_of(node: Node) -> Variant:
	if node is Node3D:
		var p: Vector3 = (node as Node3D).global_position
		return p
	if node is Node2D:
		var p2: Vector2 = (node as Node2D).global_position
		return Vector3(p2.x, p2.y, 0.0)
	if node is Control:
		var p3: Vector2 = (node as Control).global_position
		return Vector3(p3.x, p3.y, 0.0)
	return null


func _scene_name() -> String:
	var root := get_tree().current_scene
	return root.name if root != null else ""


func _emit(record: Dictionary) -> void:
	var line := Codec.encode(_nonce, record)
	if line == "":
		return
	# print() rather than printerr(): stdout is the channel the runner drains,
	# and stderr is where the ENGINE writes, which the runner keeps separate so
	# an engine error is distinguishable from the learner's own output.
	print(line)
