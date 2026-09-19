@tool
extends VBoxContainer

## What every view in the panel has in common.
##
## TWO THINGS ONLY: it renders from a payload, and it reports commands. Both
## halves are deliberate boundaries rather than convenience.
##
## IT RENDERS FROM A PAYLOAD IT IS GIVEN, and never fetches. A view that called
## the sidecar would need a live sidecar to test, which means a live editor, a
## published binary and a network -- so the ten views would be the ten least
## tested things in the plugin, which is the wrong way round for the ten things
## a learner actually looks at. The shell fetches; this draws what came back.
##
## IT REPORTS COMMANDS AS (method, args), which is the shape of a sidecar
## request. A view that knew how to send one would have to know the client, the
## protocol version and what to do when it is not connected -- three things that
## belong in one place and are currently in none of the views. A signal carrying
## a method name maps straight onto `req`, and the shell decides whether the
## sidecar is even up.
##
## A PAYLOAD THAT IS MISSING FIELDS IS ORDINARY. It arrives as JSON from another
## process which may be a different version, so every view has to draw something
## reasonable from a dictionary it does not fully recognise. That is not
## defensive programming; it is the normal case during an upgrade.

## Something the learner asked for. `method` is a sidecar method name.
signal command(method: String, args: Dictionary)

## What this view is currently drawing.
var _payload := {}


## Draw from `payload`. Safe to call repeatedly; the last one wins.
func render(payload: Dictionary) -> void:
	_payload = payload if payload != null else {}
	_render(_payload)


## What the view is drawing. For tests and for a shell re-rendering after a
## command without re-fetching.
func payload() -> Dictionary:
	return _payload.duplicate(true)


## Override this. The base does nothing, which is what an unimplemented view
## should do -- rather than pushing an error into a learner's Output panel every
## time the router shows it.
func _render(_payload: Dictionary) -> void:
	pass


## Ask the shell for something.
func send(method: String, args := {}) -> void:
	command.emit(method, args)


# --------------------------------------------------------------------------
# The router's lifecycle. Duck-typed, and the spelling is checked at
# registration -- see view_router.gd -- so a near miss is refused rather than
# silently never called.
# --------------------------------------------------------------------------

func on_shown() -> void:
	pass


func on_hidden() -> void:
	pass


# --------------------------------------------------------------------------
# Reading a payload, in the shapes the wire actually produces.
# --------------------------------------------------------------------------

## A string, whatever the field turned out to be. Missing reads as "".
static func text_at(payload: Dictionary, key: String, fallback := "") -> String:
	if payload == null or not payload.has(key):
		return fallback
	var value = payload[key]
	return fallback if value == null else str(value)


## A bool. Anything that is not one reads as `fallback` rather than as truthy:
## JSON sends `null` for an unset field, and `null` is not `false`.
static func flag_at(payload: Dictionary, key: String, fallback := false) -> bool:
	if payload == null or not payload.has(key):
		return fallback
	var value = payload[key]
	return value if value is bool else fallback


## An int. GDSCRIPT'S JSON PARSES EVERY NUMBER TO A FLOAT, so a count that left
## the other side as 3 arrives as 3.0 and `is int` is false for it. Rounding is
## the correct read, not a tolerance.
static func number_at(payload: Dictionary, key: String, fallback := 0) -> int:
	if payload == null or not payload.has(key):
		return fallback
	var value = payload[key]
	if value is int:
		return value
	if value is float:
		return int(round(value))
	return fallback


## A list of dictionaries, with anything else in it dropped. What every list of
## rows on the wire is.
static func rows_at(payload: Dictionary, key: String) -> Array:
	var out: Array = []
	if payload == null or not payload.has(key):
		return out
	var value = payload[key]
	if not (value is Array):
		return out
	for entry in value:
		if entry is Dictionary:
			out.append(entry)
	return out
