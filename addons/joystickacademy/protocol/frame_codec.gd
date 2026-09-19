extends RefCounted

## Length-prefixed JSON frames, the addon's half: constants and encoding.
## Decoding lives in frame_reader.gd, which needs state.
##
## The protocol is specified in docs/wire-protocol.md and pinned by
## Tests/vectors/wire-protocol-vectors.json, which BOTH this and the .NET host
## are tested against. Two hand-maintained notions of a protocol drift, and the
## drift shows up as a field that is silently absent on one side rather than as
## a failing test.
##
## NO class_name ON PURPOSE. class_name registers a global identifier in the
## learner's project, and an addon that teaches beginners should not be adding
## names to a namespace they are still learning to navigate. Everything here is
## reached through preload(), which costs one const and collides with nothing.

## 4-byte big-endian length, then that many bytes of UTF-8 JSON.
const HEADER_BYTES := 4

## 16 MiB. A declared length above this is not a big message; it is four bytes
## of somebody's payload being read as a header. Allocating for it is how a
## desync becomes an out-of-memory crash.
const MAX_FRAME_BYTES := 16777216

const PROTOCOL_VERSION := 1

## Frame kinds. See docs/wire-protocol.md.
const KIND_HELLO := "hello"
const KIND_READY := "ready"
const KIND_REQUEST := "req"
const KIND_RESPONSE := "res"
const KIND_ERROR := "err"
const KIND_PROBE := "probe"
const KIND_PROBE_RESPONSE := "probe_res"
const KIND_EVENT := "event"
const KIND_LOG := "log"
const KIND_BYE := "bye"

## The levels a log frame can carry, and the ONLY ones.
##
## Three strings agreed across two languages, and a drift between them is
## SILENT. plugin.gd maps "error" to push_error and "warn" to push_warning, and
## everything else falls through to print() -- so a host that one day emits
## "warning" instead of "warn" does not fail, it quietly turns every warning a
## learner should see into ordinary output. Named here so the addon's handler
## can be checked against the list rather than against itself; the host's half
## is Protocol/WireCodes.cs's WireLevels.
const LEVEL_INFO := "info"
const LEVEL_WARN := "warn"
const LEVEL_ERROR := "error"
const LOG_LEVELS := [LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR]

## Error codes. A closed set, so the addon can branch on them.
const E_PROTOCOL_VERSION := "E_PROTOCOL_VERSION"
const E_PROTOCOL_DESYNC := "E_PROTOCOL_DESYNC"
const E_UNKNOWN_METHOD := "E_UNKNOWN_METHOD"
const E_BAD_ARGS := "E_BAD_ARGS"
const E_NOT_SIGNED_IN := "E_NOT_SIGNED_IN"
const E_OFFLINE := "E_OFFLINE"
const E_SERVER := "E_SERVER"
const E_TIMEOUT := "E_TIMEOUT"
const E_PROBE_UNSUPPORTED := "E_PROBE_UNSUPPORTED"
const E_PROBE_FAILED := "E_PROBE_FAILED"
const E_SHUTTING_DOWN := "E_SHUTTING_DOWN"
const E_INTERNAL := "E_INTERNAL"

enum Status {
	OK,          ## A whole frame came out.
	EMPTY,       ## Nothing yet. Not an error; try again later.
	DESYNC,      ## Alignment is lost. Fatal by design.
}


## Encode one frame.
##
## JSON.stringify's defaults ARE the canonical encoding: keys sorted, no
## whitespace, non-ASCII emitted as raw UTF-8. That was verified byte-for-byte
## against all 20 accept vectors on 2026-09-15 rather than assumed. It is worth
## knowing why the verification mattered: the host originally used a
## general-purpose .NET serialiser, which escapes characters outside the Basic
## Multilingual Plane where Godot does not -- a 16-byte divergence on the one
## property the shared vectors rest on, caught by a test rather than a learner.
static func encode(frame: Dictionary) -> PackedByteArray:
	var payload := JSON.stringify(frame).to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(HEADER_BYTES)
	out[0] = (payload.size() >> 24) & 0xFF
	out[1] = (payload.size() >> 16) & 0xFF
	out[2] = (payload.size() >> 8) & 0xFF
	out[3] = payload.size() & 0xFF
	out.append_array(payload)
	return out


static func read_be32(bytes: PackedByteArray, offset: int = 0) -> int:
	return ((bytes[offset] << 24) | (bytes[offset + 1] << 16)
		| (bytes[offset + 2] << 8) | bytes[offset + 3])


## Read a correlation id.
##
## NOT defensive padding -- required. GDScript's JSON parser turns every number
## into a float, so an id the host sent as 7 arrives here as 7.0. Comparing it
## as an int without this would fail to match a reply to its own request.
static func id_of(frame: Dictionary) -> int:
	return int(frame.get("id", -1))


## The error code on an err or probe_res frame, or "" when there is none.
static func error_code(frame: Dictionary) -> String:
	var e: Variant = frame.get("e")
	if typeof(e) != TYPE_DICTIONARY:
		return ""
	return str(e.get("code", ""))
