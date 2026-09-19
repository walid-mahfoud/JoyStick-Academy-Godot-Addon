extends RefCounted

## IEditorProbe, in the editor, in GDScript.
##
## Core drives the walkthrough checks from the sidecar and every answer lives
## here, because only the editor can see the scene tree. The host calls in over
## the reverse channel; this file turns each call into Godot API reads and hands
## back a plain Dictionary.
##
## THE ONE RULE THAT CANNOT BE ENFORCED IN CODE: nothing in this file may issue
## a request back to the host. The host runs requests on a single serial worker,
## so a request from here would queue behind the very one waiting for this
## answer, and the protocol has no way to detect it. Probe handlers read the
## scene tree and do nothing else.
##
## Every verdict below is grounded in docs/verifier-kinds.md, where the traps
## are measured rather than assumed.

const Codec := preload("res://addons/joystickacademy/protocol/frame_codec.gd")

## Handles the host holds. Rebuilt per scan rather than kept forever: a node the
## learner deleted must resolve to nothing, and `is_instance_valid` alone does
## not cover a freed-then-reallocated object.
var _handles: Dictionary = {}
var _next_handle := 0

## A scene root supplied directly, instead of asking the editor for the open one.
##
## THE ONLY TEST SEAM IN THIS FILE, and it exists because the alternative is no
## tests at all: EditorInterface is absent outside a running editor, so every
## scene-reading method would be unreachable headlessly. A test builds a tree in
## code and sets this; production never touches it.
##
## Deliberately NOT a general "which scene" setting. It is the edited scene or a
## fixture, nothing else, so it cannot grow into a way for the addon to look at
## a scene the learner is not working in.
var root_override: Node = null


## Route one probe call. Returns the result dictionary, or null to refuse.
##
## Refusing is done by returning null and letting the caller send
## E_PROBE_UNSUPPORTED, so the unsupported-versus-failed distinction stays in
## one place.
func handle(method: String, args: Dictionary) -> Variant:
	match method:
		"getSceneStatus": return get_scene_status()
		"findObjects": return find_objects(args)
		"findComponent": return find_component(args)
		"readMember": return read_member(args)
		"readAnimationGraph": return read_animation_graph(args)
		"readParticleEmitter": return read_particle_emitter(args)
		"readAsset": return read_asset(args)
		"countThings": return count_things(args)
		"readText": return read_text(args)
		"listScripts": return list_scripts(args)
		_:
			return null


# ------------------------------------------------------------------------------
# Scene
# ------------------------------------------------------------------------------

func get_scene_status() -> Dictionary:
	var root := _edited_root()
	if root == null:
		# A distinct, honest answer: checks render "No active scene loaded"
		# rather than "your object is missing".
		return {"open": false}
	var scene_path := root.get_scene_file_path()
	return {
		"open": true,
		"name": scene_path.get_file() if scene_path != "" else String(root.name),
	}


## Find nodes by name, group or path.
##
## A HAND-WRITTEN PRE-ORDER WALK, not Node.find_children, for the NAME filter.
## find_children's `pattern` is a String.match glob, and `*` and `?` are legal
## in Godot node names -- only . : @ " % are rejected -- so a literal name
## containing one would silently become a wildcard query. The contract is an
## exact, ordinal, case-sensitive match.
##
## include_internal is false: engine-private children, such as a
## ScrollContainer's scrollbars, have no counterpart in the authored content and
## would pad every count.
func find_objects(args: Dictionary) -> Dictionary:
	var root := _edited_root()
	if root == null:
		return {"objects": []}

	# The host refuses a layer-filtered query before it reaches the wire, so
	# arriving here with one means the two sides disagree. Answer nothing rather
	# than answer on the remaining filters, which would be the false green the
	# host-side rule exists to prevent.
	if args.has("layer") and args["layer"] != null:
		return {"objects": []}

	var want_name := str(args.get("name", ""))
	var want_tag := str(args.get("tag", ""))
	var want_path := str(args.get("path", ""))
	var limit := int(args.get("limit", 50))

	var out: Array = []

	if want_path != "":
		# A hierarchy path is a single lookup, not a search.
		var found := _by_hierarchy_path(root, want_path)
		if found != null:
			out.append(_describe(found))
		return {"objects": out}

	for node in _walk(root):
		if want_name != "" and String(node.name) != want_name:
			continue
		if want_tag != "" and not node.is_in_group(StringName(want_tag)):
			continue
		out.append(_describe(node))
		if limit > 0 and out.size() >= limit:
			break

	return {"objects": out}


## Is a component of this type attached?
##
## GODOT HAS NO COMPONENTS, so `Present` is redefined rather than translated,
## and the redefinition is declared in docs/verifier-kinds.md. Unity puts in one
## place what Godot spreads across three:
##
##   * the node itself IS-A T      (Unity Rigidbody -> Godot RigidBody3D)
##   * a DIRECT CHILD is-a T       (the Godot idiom: CollisionShape3D under a body)
##   * the node carries a SCRIPT whose class_name is T
##
## The tri-state survives, and it is what catches an author's mistake: a type
## that resolves to nothing is TypeUnknown, and one that resolves to something
## that cannot be a node is TypeNotComponent -- exactly Unity's failure shape for
## an author writing "Resource" or "Vector3".
func find_component(args: Dictionary) -> Dictionary:
	var node := _resolve(str(args.get("obj", "")))
	if node == null:
		return {"presence": "ObjectStale"}

	var type_name := str(args.get("type", ""))
	if type_name == "":
		return {"presence": "TypeUnknown"}

	var is_engine_class := ClassDB.class_exists(type_name)
	var is_script_class := _script_class_exists(type_name)
	if not is_engine_class and not is_script_class:
		return {"presence": "TypeUnknown"}

	if is_engine_class and not ClassDB.is_parent_class(type_name, "Node"):
		# Resolves, but can never be attached to anything. Unity reports the
		# same shape for a non-Component type, and it is an AUTHOR error rather
		# than a learner one.
		return {"presence": "TypeNotComponent"}

	if is_engine_class and node.is_class(type_name):
		return {"presence": "Present"}

	if _script_class_of(node) == type_name:
		return {"presence": "Present"}

	for child in node.get_children(false):
		if is_engine_class and child.is_class(type_name):
			return {"presence": "Present"}
		if _script_class_of(child) == type_name:
			return {"presence": "Present"}

	return {"presence": "NotAttached"}


## Read a property.
##
## THE SEPARATOR IS ':', NOT '.'. Measured: get_indexed("position:y") -> 2.0,
## get_indexed("position.y") -> null, and get_indexed("transform.position.y") --
## the exact string in the manifest's own authoring skeleton -- -> null.
##
## So authored content written in Unity's vocabulary resolves to nothing on
## every step until it is translated. Translating here rather than failing is
## the difference between the existing catalogue working and none of it working.
func read_member(args: Dictionary) -> Dictionary:
	var node := _resolve(str(args.get("obj", "")))
	if node == null:
		return {"status": "ObjectStale"}

	var member := str(args.get("member", ""))
	if member == "":
		return {"status": "PathUnresolved"}

	var path := _translate_member_path(member)
	var value: Variant = node.get_indexed(NodePath(path))
	if value == null:
		# One retry on the untranslated spelling, in case an author wrote a
		# Godot path that the translation mangled. Cheap, and it makes the
		# translation additive rather than a new way to fail.
		value = node.get_indexed(NodePath(member))
	if value == null:
		return {"status": "PathUnresolved"}

	return {"status": "Ok", "value": _describe_value(value)}


## Unity's field vocabulary, mapped onto Godot property paths.
##
## Node3D has no `transform.position` at all -- the equivalent is
## `transform:origin` -- so this is a vocabulary map rather than a character
## substitution.
static func _translate_member_path(member: String) -> String:
	var known := {
		"transform.position": "position",
		"transform.localPosition": "position",
		"transform.rotation": "rotation",
		"transform.localRotation": "rotation",
		"transform.eulerAngles": "rotation",
		"transform.localScale": "scale",
		"transform.scale": "scale",
	}
	var translated := member
	for unity_name in known:
		if translated == unity_name or translated.begins_with(unity_name + "."):
			translated = known[unity_name] + translated.substr(unity_name.length())
			break
	# Whatever remains is a dotted path in Unity's spelling; Godot separates
	# sub-properties with a colon.
	return translated.replace(".", ":")


# ------------------------------------------------------------------------------
# Animation
# ------------------------------------------------------------------------------

## Godot has TWO animation models and only one can answer the question.
##
## AnimationTree with a state machine is the true analogue of Unity's Animator.
## A bare AnimationPlayer has no states at all, only named animations -- and
## there "the state has a clip assigned" is VACUOUS, because the animation name
## IS the clip. Reporting that as introspectable would be a check that always
## passes once a name exists, so it reports NOT introspectable, which routes to
## the existing "this editor cannot inspect that controller" branch. That branch
## fails rather than falsely passing, which is the right direction.
##
## The impedance mismatch: in Unity the Animator is a COMPONENT on the target;
## in Godot AnimationPlayer and AnimationTree are CHILD NODES.
func read_animation_graph(args: Dictionary) -> Dictionary:
	var node := _resolve(str(args.get("obj", "")))
	if node == null:
		return {"supported": true, "objectResolved": false}

	var tree: Node = _self_or_child(node, "AnimationTree")
	var player: Node = _self_or_child(node, "AnimationPlayer")

	if tree == null and player == null:
		return {"supported": true, "objectResolved": true, "hasPlayer": false}

	if tree == null:
		# Path B: a bare AnimationPlayer. See the note above.
		return {
			"supported": true,
			"objectResolved": true,
			"hasPlayer": true,
			"hasGraph": true,
			"introspectable": false,
			"layers": 1,
			"stateMachine": false,
			"states": [],
		}

	var root_node: Variant = tree.tree_root
	if root_node == null:
		return {
			"supported": true, "objectResolved": true, "hasPlayer": true,
			"hasGraph": false, "introspectable": false, "layers": 0,
			"stateMachine": false, "states": [],
		}

	var is_state_machine := root_node is AnimationNodeStateMachine
	var states: Array = []
	if is_state_machine:
		for state_name in root_node.get_node_list():
			var label := String(state_name)
			# Start and End are implicit entries every machine reports. They are
			# not states a learner assigned a clip to, and surfacing them makes a
			# learner who names a state "Start" meet a permanently confusing note.
			if label == "Start" or label == "End":
				continue
			states.append({
				"name": label,
				"hasMotion": _state_has_motion(root_node.get_node(state_name)),
			})

	return {
		"supported": true,
		"objectResolved": true,
		"hasPlayer": true,
		"hasGraph": true,
		"introspectable": is_state_machine,
		# Godot has no layer concept; the single root IS the base layer, which
		# makes the check's "base layer" wording exact rather than approximate.
		"layers": 1,
		"stateMachine": is_state_machine,
		"states": states,
	}


## Does this state carry motion?
##
## ProbeTypes documents HasMotion as "True for a blend tree too; false for a
## broken/missing asset", so a blend space or blend tree counts. Reporting only
## AnimationNodeAnimation would mark every Godot blend setup as broken.
##
## AnimationNodeStartState and AnimationNodeEndState are deliberately NOT named
## as types here: measured, they are not usable as GDScript type identifiers and
## the parse error takes the whole file down. They are filtered by NAME above.
func _state_has_motion(state: Variant) -> bool:
	if state == null:
		return false
	if state is AnimationNodeAnimation:
		return String(state.animation) != ""
	if state is AnimationNodeBlendSpace1D or state is AnimationNodeBlendSpace2D:
		return true
	if state is AnimationNodeBlendTree:
		return true
	# Anything else that exists is a node the learner placed; treat its presence
	# as motion rather than calling their work broken.
	return true


## The four particle classes, and the two booleans that collapse into one.
##
## GPUParticles3D and CPUParticles3D inherit GeometryInstance3D while the 2D
## pair inherit Node2D, so there is no common ancestor to search for.
##
## EmissionEnabled and PlaysAutomatically are independent facts in Unity
## (emission.enabled and main.playOnAwake) and the SAME fact in Godot
## (`emitting`). Mapping both to it is honest -- in Godot "emitting is on"
## genuinely IS "it plays automatically" -- but it means an author's
## require_play_on_awake asserts nothing extra, which belongs in the content
## guide. The obvious escape does not work: `amount` is range-hinted from 1 and
## the setter clamps, so `amount > 0` is always true.
func read_particle_emitter(args: Dictionary) -> Dictionary:
	var node := _resolve(str(args.get("obj", "")))
	if node == null:
		return {"supported": true, "objectResolved": false}

	var emitter: Node = null
	for cls in ["GPUParticles3D", "GPUParticles2D", "CPUParticles3D", "CPUParticles2D"]:
		emitter = _self_or_child(node, cls)
		if emitter != null:
			break

	if emitter == null:
		return {"supported": true, "objectResolved": true, "hasEmitter": false}

	var emitting: bool = bool(emitter.get("emitting"))
	return {
		"supported": true,
		"objectResolved": true,
		"hasEmitter": true,
		"emitting": emitting,
		"loops": not bool(emitter.get("one_shot")),
		"playsAutomatically": emitting,
	}


# ------------------------------------------------------------------------------
# Assets and text
# ------------------------------------------------------------------------------

func read_asset(args: Dictionary) -> Dictionary:
	var path := _normalise_res_path(str(args.get("path", "")))
	if path == "":
		return {"exists": false}
	if not ResourceLoader.exists(path):
		return {"exists": false}

	# THE CONCRETE TYPE COMES FROM THE LOADED RESOURCE.
	#
	# There is no ResourceLoader.get_resource_type() in Godot 4.5 -- the first
	# version of this file called one and the whole script failed to compile,
	# which the suite then reported as 32 passing tests. Loading and asking the
	# object is the only way to get the real class rather than an extension's
	# best guess.
	var resource: Variant = ResourceLoader.load(path)
	if resource == null:
		# Recognised as a resource path but not loadable. "Does not exist" is the
		# honest answer to a check asking whether the learner made the asset.
		return {"exists": false}

	var concrete: String = resource.get_class()
	var wanted := str(args.get("type", ""))
	if wanted == "":
		return {"exists": true, "type": concrete}

	# "Known" means the engine recognises the type NAME at all -- distinct from
	# "the asset is that type". An author's typo should read as a bad argument,
	# not as a learner's missing asset.
	var known := ClassDB.class_exists(wanted)
	var conforms := known and concrete != "" \
		and (concrete == wanted or ClassDB.is_parent_class(wanted, concrete))

	return {
		"exists": true,
		"type": concrete,
		"typeKnown": known,
		"conforms": conforms,
	}


## Read a file, distinguishing the three outcomes Core renders differently.
##
## THE ERROR CODE IS CONSULTED, NOT THE EMPTINESS OF THE RETURN.
## get_file_as_string() returns "" both for a zero-byte file and for a failed
## open, and Core treats the first as a legitimate Ok -- so branching on the
## text would report a read failure to the learner as "Found 0 matches".
## Measured: a good file gave len=75 err=0; a missing one len=0 err=7.
func read_text(args: Dictionary) -> Dictionary:
	var path := _normalise_res_path(str(args.get("path", "")))
	if path == "":
		return {"status": "NotFound"}
	if not FileAccess.file_exists(path):
		return {"status": "NotFound"}

	var text := FileAccess.get_file_as_string(path)
	var err := FileAccess.get_open_error()
	if err != OK:
		# error_string() returns one of a closed set of fixed engine strings
		# ("File not found.", "Permission denied.") chosen from an enum. It
		# cannot quote a header, a token or a path, which is what makes a .NET
		# exception message dangerous. And a read failure has to be
		# distinguishable from an empty file HERE rather than three layers
		# later: see the note above this function for what branching on the
		# emptiness of the text does instead.
		# exception-message-ok: a closed set of engine strings, no secrets possible
		return {"status": "Error", "error": error_string(err)}
	return {"status": "Ok", "text": text}


## Every GDScript file under a folder.
func list_scripts(args: Dictionary) -> Dictionary:
	var scope := _normalise_res_path(str(args.get("folder", "")))
	if scope == "":
		scope = "res://"
	if not DirAccess.dir_exists_absolute(scope):
		return {"error": "no folder at %s" % scope, "scope": scope, "paths": []}

	var paths: Array = []
	_collect_scripts(scope, paths)
	return {"scope": scope, "paths": paths}


func _collect_scripts(dir_path: String, into: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full := dir_path.path_join(entry)
			if dir.current_is_dir():
				# The addon's OWN scripts are skipped. Measured: the shipped
				# has_win_condition pattern matches sidecar_locator.gd's
				# "win-x64", so scanning ourselves would find a win condition in
				# the plugin rather than in the learner's game.
				if not full.begins_with("res://addons/joystickacademy"):
					_collect_scripts(full, into)
			elif entry.ends_with(".gd"):
				into.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


## Count things, by resource TYPE rather than by file extension.
##
## Filtering on type also catches binary .scn, which an extension filter misses.
func count_things(args: Dictionary) -> Dictionary:
	var thing := str(args.get("thing", ""))
	var scope := _normalise_res_path(str(args.get("scope", "")))

	match thing:
		"ReusableObjectAssets":
			# EVERY GODOT SCENE IS A PackedScene. Unscoped, this counts the
			# learner's levels and passes a check about reusable objects they
			# never made -- a false green on a graded milestone. So an unscoped
			# query is REFUSED rather than answered, and refused through
			# !supported, which reaches the AUTHOR. An errorMessage would route
			# to Fail, which is the learner's channel.
			if scope == "" or scope == "res://":
				return {"supported": false}
			return _count_by_type(scope, "PackedScene")

		"ScriptAssets":
			return _count_by_type(scope if scope != "" else "res://", "GDScript")

		"BakedLightingArtifacts":
			return _count_baked_lightmaps()

		_:
			# SurfaceResourceLayers never reaches here: the host refuses it
			# without a round trip, because stock Godot has no terrain at all.
			return {"supported": false}


func _count_by_type(scope: String, resource_type: String) -> Dictionary:
	if not DirAccess.dir_exists_absolute(scope):
		# The author's typo, not the learner's shortfall. Unity has the same
		# pre-check for the same reason.
		return {"supported": true, "error": "no folder at %s" % scope, "scope": scope, "counts": []}
	var found := [0]
	_count_recursive(scope, _extensions_for(resource_type), found)
	return {"supported": true, "scope": scope, "counts": found}


## Which file extensions mean this resource type.
##
## ASKED OF THE ENGINE rather than hardcoded, so a format Godot adds later is
## counted without an edit here.
##
## The generic container extensions are dropped: `res` and `tres` can hold ANY
## resource, so counting them would inflate a PackedScene count with every
## unrelated .tres in the project -- and this count decides whether a milestone
## passes.
static func _extensions_for(resource_type: String) -> PackedStringArray:
	var out := PackedStringArray()
	for ext in ResourceLoader.get_recognized_extensions_for_type(resource_type):
		if ext == "res" or ext == "tres":
			continue
		out.append(ext)
	return out


func _count_recursive(dir_path: String, extensions: PackedStringArray, found: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full := dir_path.path_join(entry)
			if dir.current_is_dir():
				if not full.begins_with("res://addons/joystickacademy"):
					_count_recursive(full, extensions, found)
			elif extensions.has(entry.get_extension()):
				found[0] += 1
		entry = dir.get_next()
	dir.list_dir_end()


## Baked lighting, counted in LAYERS rather than in texture objects.
##
## MEASURED: a Godot bake emits ONE TextureLayered whose LAYERS are the atlas
## pages. Summing get_lightmap_textures().size() is near-always 1 regardless of
## page count, so any authored min_count > 1 would fail a correctly baked scene.
func _count_baked_lightmaps() -> Dictionary:
	var root := _edited_root()
	if root == null:
		return {"supported": true, "counts": [0]}

	var total := 0
	for node in _walk(root):
		if not node is LightmapGI:
			continue
		var data: Variant = node.light_data
		if data == null:
			continue
		for texture in data.get_lightmap_textures():
			if texture == null:
				continue
			total += texture.get_layers() if texture.has_method("get_layers") else 1

	# ONE entry, never an empty array. "No LightmapGI in the scene" and
	# "LightmapGI present but never baked" are the same instruction to the
	# learner -- go and bake -- so they must not render differently.
	return {"supported": true, "counts": [total]}


# ------------------------------------------------------------------------------
# Internals
# ------------------------------------------------------------------------------

func _edited_root() -> Node:
	if root_override != null:
		return root_override
	# EditorInterface is an editor-only singleton. Asking for it by name rather
	# than referencing the type keeps this file loadable outside the editor,
	# where the tests run.
	if not Engine.has_singleton("EditorInterface"):
		return null
	var editor: Object = Engine.get_singleton("EditorInterface")
	if editor == null or not editor.has_method("get_edited_scene_root"):
		return null
	return editor.get_edited_scene_root()


## Pre-order depth-first, node before children, siblings in declaration order.
## That is exactly the contract's ordering, and it is what makes "the first
## match" mean the same thing on every engine.
func _walk(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		out.append(node)
		var children := node.get_children(false)
		# Pushed in reverse so they pop in declaration order.
		for i in range(children.size() - 1, -1, -1):
			stack.append(children[i])
	return out


func _by_hierarchy_path(root: Node, path: String) -> Node:
	var trimmed := path.strip_edges().trim_prefix("/")
	if trimmed == "":
		return root
	var parts := trimmed.split("/", false)
	# The path may or may not repeat the scene root's own name; accept both,
	# because authored content is written by hand.
	var start := 0
	if parts.size() > 0 and String(root.name) == parts[0]:
		start = 1
	var current := root
	for i in range(start, parts.size()):
		var next: Node = null
		for child in current.get_children(false):
			if String(child.name) == parts[i]:
				next = child
				break
		if next == null:
			return null
		current = next
	return current


func _describe(node: Node) -> Dictionary:
	_next_handle += 1
	var id := str(_next_handle)
	_handles[id] = node
	var groups := node.get_groups()
	return {
		"id": id,
		"name": String(node.name),
		# Godot's nearest analogue of a tag. Reported for the note only; the
		# filter above matches on membership rather than on this one value.
		"tag": String(groups[0]) if groups.size() > 0 else "",
	}


func _resolve(id: String) -> Node:
	if id == "" or not _handles.has(id):
		return null
	var node: Variant = _handles[id]
	if not is_instance_valid(node):
		# The learner deleted it between the scan and the read. Stale, not
		# missing, and the two read differently to a check.
		_handles.erase(id)
		return null
	return node


## Clear the handle table. Called between polls so a deleted node cannot be
## resolved through a stale id.
func reset_handles() -> void:
	_handles.clear()


func _self_or_child(node: Node, class_name_wanted: String) -> Node:
	if node.is_class(class_name_wanted):
		return node
	# Class filters are the ONE case find_children is right for, and owned=false
	# is load-bearing: the default only returns nodes owned by the caller, which
	# skips the interior of instanced sub-scenes.
	var found := node.find_children("*", class_name_wanted, true, false)
	return found[0] if found.size() > 0 else null


func _script_class_of(node: Node) -> String:
	var script: Variant = node.get_script()
	if script == null:
		return ""
	return str(script.get_global_name()) if script.has_method("get_global_name") else ""


func _script_class_exists(type_name: String) -> bool:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == type_name:
			return true
	return false


func _describe_value(value: Variant) -> Dictionary:
	match typeof(value):
		TYPE_BOOL:
			return {"kind": "bool", "bool": value, "display": "true" if value else "false"}
		TYPE_INT:
			return {"kind": "number", "number": float(value), "display": str(value)}
		TYPE_FLOAT:
			return {"kind": "number", "number": value, "display": str(value)}
		TYPE_STRING, TYPE_STRING_NAME:
			return {"kind": "string", "string": String(value)}
		TYPE_NIL:
			return {"kind": "null", "display": "null"}
		_:
			# Vectors, colours, resources: shown rather than compared. Core
			# renders Display and does not pretend to understand the type.
			return {"kind": "opaque", "display": str(value)}


## res:// paths, normalised, with a refusal for anything outside the project.
##
## A path is authored content, so it must not be able to reach outside the
## project. The allowlist is the res:// prefix itself rather than a blocklist of
## traversal spellings.
static func _normalise_res_path(path: String) -> String:
	var trimmed := path.strip_edges()
	if trimmed == "":
		return ""
	if trimmed.begins_with("res://"):
		return trimmed if not trimmed.contains("..") else ""
	if trimmed.begins_with("/") or trimmed.contains(":"):
		# An absolute or drive-qualified path is not authored content we can
		# honour; refusing is safer than resolving it.
		return ""
	if trimmed.contains(".."):
		return ""
	return "res://" + trimmed
