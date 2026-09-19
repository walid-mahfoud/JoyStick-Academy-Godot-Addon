@tool
extends RefCounted

## The line format the running game reports observations in.
##
## THE CHANNEL IS SHARED WITH THE LEARNER, and that is the whole reason this
## file is careful. Godot runs the game as a separate process; the addon
## launches it and drains its stdout. That stdout carries the learner's own
## `print()` output AND our observations, mixed, in whatever order they happen.
##
## So a learner's print can LOOK like an observation. That matters more here
## than it would in most places: these observations decide whether a graded
## check goes green. A walkthrough step routinely says "print something when the
## player lands", so a learner printing a line that happens to match our format
## is not a contrived scenario -- it is a Tuesday.
##
## THE NONCE IS WHAT MAKES ACCIDENTAL FORGERY HARD, and it is worth being exact
## about which threat that is. Every run generates a random token, hands it to
## the observer through the game's own command line, and stamps it into every
## framed line. It is never shown in the editor and never written to the
## learner's project, so a print that collides with our format by accident, or
## an observer from a previous run still writing into this pipe, cannot be
## mistaken for an observation.
##
## IT IS NOT A SECRET FROM THE LEARNER'S OWN CODE. Their script can call
## OS.get_cmdline_user_args() exactly as the observer does and read the token
## straight out of it. Anyone describing this as tamper-proof would be wrong.
##
## What actually stands between that and a forged observation is the STREAM: the
## observer prints to stdout, and the runner refuses framed lines arriving on
## stderr outright. A learner who wants to cheat a check can still do it -- they
## could print to stdout with the token -- and that is a deliberate boundary:
## this is a learning tool, not an exam invigilator, and the graded artefact is
## the project they submit. What the token and the stream split BUY is that
## nobody does it by accident, which is the failure that would actually happen.
##
## A LINE THAT LOOKS FRAMED AND IS NOT IS COUNTED, NOT DROPPED. Silently
## discarding is how a real transport bug -- a mismatched nonce, a truncated
## write -- becomes invisible, and how a forgery attempt goes unnoticed. The
## reader keeps a tally and the runner reports it.

## The marker. Includes a format version, because this crosses a process
## boundary between two things that can be upgraded separately: a learner with a
## half-updated install runs an old observer under a new addon.
const PREFIX := "JSA-OBS/1 "

## What a parsed line turned out to be.
enum Line {
	## The learner's own output. Kept: log_contains reads it.
	LOG,
	## One of ours, verified by the nonce.
	RECORD,
	## Framed like ours and carrying the wrong token. Counted, never trusted.
	FOREIGN,
	## Ours by the token and unreadable after it.
	MALFORMED,
}

## The record kinds an observer can report. Named rather than free-form so a
## typo in the observer is a rejected record instead of an observation that
## silently never arrives.
const KIND_READY := "ready"
const KIND_TRANSFORM := "transform"
const KIND_AUDIO := "audio"
const KIND_ANIM_STATE := "anim_state"
const KIND_CONTACT := "contact"
const KIND_FIELD := "field"
const KIND_BYE := "bye"

const KINDS := [
	KIND_READY, KIND_TRANSFORM, KIND_AUDIO, KIND_ANIM_STATE,
	KIND_CONTACT, KIND_FIELD, KIND_BYE,
]


## Encode one record as a line the observer prints.
##
## Returns "" when the record could not be encoded, which is a bug in the
## caller rather than something to put on the wire.
static func encode(nonce: String, record: Dictionary) -> String:
	if nonce == "":
		return ""
	var kind := str(record.get("k", ""))
	if not KINDS.has(kind):
		return ""
	# Sorted keys and no whitespace, the same canonical form the wire protocol
	# uses. It costs nothing and makes two runs of the same observation
	# byte-identical, which is what lets a test compare them.
	return PREFIX + nonce + " " + JSON.stringify(record, "", true, true)


## Decode one line of the game's output.
##
## Returns {"line": Line, "record": Dictionary, "text": String}. `text` carries
## the original for LOG lines, because that is what log_contains matches on.
static func decode(raw: String, nonce: String) -> Dictionary:
	var line := raw.strip_edges()

	if not line.begins_with(PREFIX):
		# The learner's own output, and it is kept verbatim -- including
		# leading whitespace they chose, which strip_edges above has removed
		# from the copy used for the prefix test only.
		return {"line": Line.LOG, "record": {}, "text": raw}

	var rest := line.substr(PREFIX.length())
	var space := rest.find(" ")
	if space <= 0:
		return {"line": Line.MALFORMED, "record": {}, "text": raw}

	var stamped := rest.substr(0, space)
	if nonce == "" or stamped != nonce:
		# Framed like ours, not ours. Either the learner printed something that
		# happens to match, or an observer from a previous run is still writing
		# into this pipe. Both are worth counting and neither is worth trusting.
		return {"line": Line.FOREIGN, "record": {}, "text": raw}

	var parser := JSON.new()
	# JSON.new().parse rather than JSON.parse_string: the static one pushes an
	# engine error into the Output panel on bad input, and bad input here is
	# something we handle rather than something a learner should see in red.
	if parser.parse(rest.substr(space + 1)) != OK:
		return {"line": Line.MALFORMED, "record": {}, "text": raw}

	var data = parser.data
	if typeof(data) != TYPE_DICTIONARY:
		return {"line": Line.MALFORMED, "record": {}, "text": raw}
	if not KINDS.has(str(data.get("k", ""))):
		# A record kind nobody implements is not a record. Accepting it would
		# let an observer typo produce an observation that is silently never
		# read by any check.
		return {"line": Line.MALFORMED, "record": {}, "text": raw}

	return {"line": Line.RECORD, "record": data, "text": raw}


## How the observer is told about the run, on the game's own command line.
##
## HERE RATHER THAN IN EITHER SIDE. The runner writes these and the observer
## reads them, in different processes, and they are the kind of string that
## gets retyped with a hyphen in the wrong place. One definition, preloaded by
## both, is the only arrangement where a rename cannot half-land.
const ARG_NONCE_PREFIX := "--jsa-nonce="

## What to watch, as base64 JSON. See observation_config.gd for why the whole
## configuration is ONE argument rather than one per kind -- briefly, a comma is
## a legal character in a Godot node name, so every list-shaped argument this
## could have had is misread on some learner's project.
const ARG_CONFIG_PREFIX := "--jsa-config="


## A fresh token for one run.
##
## 32 hex characters from the OS's generator. Not Time-seeded and not
## incrementing: a predictable token is a token a learner's print can carry.
static func new_nonce() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()
