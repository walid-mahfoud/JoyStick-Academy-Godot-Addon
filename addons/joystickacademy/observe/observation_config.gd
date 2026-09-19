extends RefCounted

## What the observer is asked to watch, for one run.
##
## ONE ARGUMENT, NOT SIX. The observer is configured through the game's own
## command line, and the obvious shape -- `--jsa-watch=a,b --jsa-audio=c,d` --
## has a collision that only shows up on a learner's project: A COMMA IS A LEGAL
## CHARACTER IN A GODOT NODE NAME. The engine's name setter strips `.`, `:`,
## `@`, `/`, `"` and `%`, and lets a comma through. So `Crates,Large` is a name a
## learner can type, and a comma-split configuration reads it as two objects
## that do not exist and reports both absent.
##
## Every separator this needs has the same problem somewhere. Property paths
## already use `:` because that is Godot's own `get_indexed` separator, so `:`
## is spoken for; `/` is a NodePath separator; `=` ends the argument itself.
## Rather than pick the least-bad character and document a footgun, the whole
## configuration travels as ONE base64 argument carrying JSON, which has no
## reserved character because the values are quoted strings.
##
## WHAT IT CARRIES. Five lists, each of which may be absent or empty:
##
##     watch    ["Player"]                       positions, sampled at both ends
##     audio    ["Player"]                       did anything under here play
##     anim     ["Player"]                       AnimationTree state changes
##     field    [{"n": "Player", "p": "health"}] one property, read live
##     contact  [{"a": "Player", "b": "Ground"}] did these two overlap
##
## EVERY TARGET IS A NODE *NAME*, NOT A PATH, and the same name resolves the
## same way for all five: the first node with that name anywhere under the
## scene root. That is the vocabulary the rest of the probe already uses, and a
## check author writing one step should not have to know that two of the five
## kinds wanted a path instead.
##
## FOR `audio` AND `anim` THE NAME IS AN ANCESTOR, NOT THE PLAYER ITSELF.
## Measured against how learners actually build: the `AudioStreamPlayer` lives
## UNDER the thing that makes the noise, and the `AnimationTree` lives under the
## character it animates. A node-only reading of `audio: ["Player"]` returns
## false for every learner who did the ordinary thing. So the target means "this
## node, or any player of that class at any depth beneath it".
##
## WHAT THAT CANNOT COVER, stated because it is a real gap and not an oversight:
## audio played by a central `SfxManager` autoload has no tree relationship to
## the object that asked for it, so it cannot be attributed to that object. A
## check on such a project has to name the manager.

## The argument's own size limit, in characters of base64.
##
## Windows' command line stops at 32767 characters for the WHOLE line, which
## also has to carry the executable, the scene path and the nonce. Eight
## thousand is a configuration of a few hundred targets -- far past anything a
## lesson step describes -- and leaves the rest of the line untouched. Refusing
## here is better than the alternative: an over-long line fails at spawn time
## with an operating-system error that names nothing useful.
const MAX_ENCODED := 8192

var watch: Array[String] = []
var audio: Array[String] = []
var anim: Array[String] = []
## Each entry is {"n": node name, "p": property path}.
var field: Array[Dictionary] = []
## Each entry is {"a": node name, "b": node name}.
var contact: Array[Dictionary] = []

## Why parsing failed, or "" when it did not. A configuration that cannot be
## read is not an empty configuration: one means "watch nothing", the other
## means "the two processes disagree", and reporting the second as the first
## makes every check silently pass for nothing.
var error := ""


## Build a configuration from the watch list the panel sent.
##
## HERE RATHER THAN IN plugin.gd, WHERE IT WAS. This is pure -- a dictionary in,
## a configuration out -- and it was sitting in the one file in this addon that
## needs a running editor, so no test in the suite could reach it. The split
## every other decision in this addon follows (startup_decision, restart_policy,
## log_router, local_commands) is that the RULE is pure and tested and the DOING
## is as small as it can be; this was the exception and it cost a real defect.
##
## THE RETURN TYPES ARE THE DEFECT. The helpers below build `Array[String]` and
## `Array[Dictionary]`, not bare `Array`, because assigning an untyped array
## into one of these typed properties is refused AT RUNTIME -- which aborts the
## enclosing function without raising, so the press of Run would have done
## nothing whatever and said nothing about it.
##
## RETURNS NULL for a watch list that names nothing, so the caller passes NO
## argument rather than an argument meaning nothing. See `encode`.
##
## DEFENSIVE ABOUT EVERY FIELD, because this came off a wire. A malformed entry
## costs the learner the one observation it names, never the whole window.
static func from_watch(watch_list: Dictionary) -> RefCounted:
	if watch_list.is_empty():
		return null

	var config = load("res://addons/joystickacademy/observe/observation_config.gd").new()
	# THE SAME HELPERS `parse` USES, deliberately. The wire form and the panel's
	# watch list are two spellings of one thing, so a list the observer would
	# reject on the way in must be rejected here on the way out; two readers
	# with two ideas of what a valid target is would disagree silently.
	config.watch = _string_list(watch_list, "watch")
	config.audio = _string_list(watch_list, "audio")
	config.anim = _string_list(watch_list, "anim")
	config.field = _pair_list(watch_list, "field", "n", "p")
	config.contact = _pair_list(watch_list, "contact", "a", "b")

	if config.is_empty():
		return null
	return config


func is_empty() -> bool:
	return (watch.is_empty() and audio.is_empty() and anim.is_empty()
		and field.is_empty() and contact.is_empty())


## The wire form: base64 of canonical JSON.
##
## Returns "" when the configuration is empty, so a run that watches nothing
## passes no argument at all rather than an argument meaning nothing.
func encode() -> String:
	if is_empty():
		return ""
	var data := {}
	if not watch.is_empty():
		data["watch"] = watch
	if not audio.is_empty():
		data["audio"] = audio
	if not anim.is_empty():
		data["anim"] = anim
	if not field.is_empty():
		data["field"] = field
	if not contact.is_empty():
		data["contact"] = contact
	# Sorted keys, no whitespace: the same canonical form the wire protocol and
	# the record codec use, so two identical configurations encode identically
	# and a test can compare them.
	return Marshalls.utf8_to_base64(JSON.stringify(data, "", true, true))


## Read the wire form into this object. Returns false and sets `error` when the
## argument could not be read.
##
## AN INSTANCE METHOD RATHER THAN A STATIC `decode`. A static one would have to
## construct this class from inside itself, which GDScript can only do by
## loading its own path by string -- a reflection trick that survives a rename
## of the file and silently stops working. `Config.new().parse(text)` cannot.
func parse(encoded: String) -> bool:
	error = ""
	watch = []
	audio = []
	anim = []
	field = []
	contact = []

	if encoded == "":
		return true
	if encoded.length() > MAX_ENCODED:
		error = "configuration is %d characters, over the %d limit" % [
			encoded.length(), MAX_ENCODED]
		return false

	var json := Marshalls.base64_to_utf8(encoded)
	if json == "":
		error = "configuration is not valid base64"
		return false

	var parser := JSON.new()
	# JSON.new().parse, not JSON.parse_string: the static one pushes an engine
	# error into the Output panel, and this runs inside the LEARNER'S game,
	# where the Output panel is the one place they read their own prints.
	if parser.parse(json) != OK:
		error = "configuration is not valid JSON"
		return false
	if typeof(parser.data) != TYPE_DICTIONARY:
		error = "configuration is not a JSON object"
		return false

	var data: Dictionary = parser.data
	watch = _string_list(data, "watch")
	audio = _string_list(data, "audio")
	anim = _string_list(data, "anim")
	field = _pair_list(data, "field", "n", "p")
	contact = _pair_list(data, "contact", "a", "b")
	return true


## Every entry that is a non-empty string. Anything else is dropped rather than
## carried as a target that can never resolve -- a null in the list would be
## reported as an object the learner is missing, which is a lie about their
## project rather than about the configuration.
static func _string_list(data: Dictionary, key: String) -> Array[String]:
	var out: Array[String] = []
	var raw = data.get(key, null)
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in raw:
		# WHITESPACE IS NOT A NAME EITHER. The docstring above says a target that
		# can never resolve is dropped rather than carried, and `"   "` is one:
		# Godot's own name setter would never produce it, so it can only be
		# authoring noise, and carrying it reports an object the learner is
		# missing -- a lie about their project rather than about the list.
		if typeof(item) == TYPE_STRING and item.strip_edges() != "":
			out.append(item)
	return out


static func _pair_list(data: Dictionary, key: String, first: String,
		second: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw = data.get(key, null)
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var a = item.get(first, null)
		var b = item.get(second, null)
		if typeof(a) != TYPE_STRING or typeof(b) != TYPE_STRING:
			continue
		if a == "" or b == "":
			continue
		out.append({first: a, second: b})
	return out
