extends RefCounted

## Accumulates bytes off the pipe and hands back whole frames.
##
## A pipe read returns what has ARRIVED, not what was asked for: it may be
## nothing, part of a header, or two frames at once. Assuming a frame arrives in
## one piece works for every small message in testing and then truncates the
## first one that spans a buffer boundary, after which the stream is permanently
## misaligned.

const Codec := preload("res://addons/joystickacademy/protocol/frame_codec.gd")

var _buffer := PackedByteArray()
var _desync_reason := ""
var _ended := false


## Feed whatever just came off the pipe.
func feed(bytes: PackedByteArray) -> void:
	if bytes.size() > 0:
		_buffer.append_array(bytes)


## The sidecar is gone; nothing more will arrive.
##
## WITHOUT THIS THE ADDON WAITS FOREVER. A partial frame is normally just a
## frame mid-delivery, so the reader's correct response is to wait. If the
## sidecar dies halfway through writing one, that same partial frame is instead
## a truncation that will never complete -- and the reader has no way to tell
## the two apart from the bytes alone.
##
## The addon learns the process is gone from OS.is_process_running, which it
## already has to check first anyway because touching a dead pipe prints a red
## engine error every tick. It then says so here, and a buffered partial frame
## becomes the desync it actually is.
func mark_end_of_stream() -> void:
	_ended = true


## Why the stream is unusable, or "" while it is fine.
func desync_reason() -> String:
	return _desync_reason


func buffered_bytes() -> int:
	return _buffer.size()


## Take the next whole frame.
##
## Returns {"status": Codec.Status, "frame": Dictionary, "reason": String}.
##
## A DESYNC is FATAL and deliberately unrecoverable. Once alignment is lost,
## every subsequent "length" is four arbitrary bytes of somebody's payload, so
## resynchronising would turn a clean failure into corrupted state. The caller
## kills the sidecar and says so.
func next() -> Dictionary:
	if _desync_reason != "":
		return {"status": Codec.Status.DESYNC, "frame": {}, "reason": _desync_reason}
	if _buffer.size() < Codec.HEADER_BYTES:
		if _ended and _buffer.size() > 0:
			# Bytes arrived and then the sender died. Distinct from a clean
			# close, which leaves nothing buffered at all and is entirely
			# normal -- the editor shutting down must never be reported as a
			# protocol failure.
			return _fail("the sidecar ended after %d of %d header bytes"
				% [_buffer.size(), Codec.HEADER_BYTES])
		return {"status": Codec.Status.EMPTY, "frame": {}, "reason": ""}

	var length := Codec.read_be32(_buffer, 0)

	if length <= 0:
		return _fail("zero-length frame: a frame cannot be an empty payload, so alignment is lost")
	if length > Codec.MAX_FRAME_BYTES:
		# Refused BEFORE allocating. The whole point of the cap is that the
		# number is not trustworthy, so trusting it enough to allocate defeats
		# it.
		return _fail("declared length %d exceeds the %d byte cap; this is misalignment, not a large message"
			% [length, Codec.MAX_FRAME_BYTES])

	if _buffer.size() < Codec.HEADER_BYTES + length:
		if _ended:
			# The header promised more than ever arrived. Only a failure once
			# the stream has ENDED -- see mark_end_of_stream.
			return _fail("the sidecar ended after %d of %d payload bytes"
				% [_buffer.size() - Codec.HEADER_BYTES, length])
		# A PARTIAL FRAME IS NOT A DESYNC. It is the normal state of a pipe
		# mid-delivery, and treating it as a failure would kill the sidecar
		# every time a message happened to span two reads.
		return {"status": Codec.Status.EMPTY, "frame": {}, "reason": ""}

	var payload := _buffer.slice(Codec.HEADER_BYTES, Codec.HEADER_BYTES + length)
	_buffer = _buffer.slice(Codec.HEADER_BYTES + length)

	var text := payload.get_string_from_utf8()
	if text == "":
		return _fail("payload was not valid UTF-8")

	# JSON.new().parse() rather than JSON.parse_string(), and the difference is
	# visible to the learner. parse_string PUSHES AN ENGINE ERROR on malformed
	# input, so a desync would paint a red "Parse JSON failed" into the Output
	# panel on top of whatever the addon itself reports -- the plugin's own
	# clear message buried under an engine one that names neither the addon nor
	# the cause. The instance form returns a code and stays quiet.
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		# A stray print in the host lands here. It must fail loudly rather than
		# be skipped, because the bytes after it are no longer frame-aligned.
		return _fail("payload is not a JSON object")

	var frame: Dictionary = json.data
	if not frame.has("k") or str(frame.get("k")) == "":
		return _fail("frame has no kind, so nothing can route it")
	if int(frame.get("v", -1)) != Codec.PROTOCOL_VERSION:
		# Refused rather than best-effort parsed. A partial understanding of a
		# newer frame is worse than none: it may use a kind name this version
		# happens to recognise while meaning something else by it.
		return _fail_with(Codec.E_PROTOCOL_VERSION,
			"frame declares protocol %s, this addon speaks %d"
			% [str(frame.get("v", "none")), Codec.PROTOCOL_VERSION])

	return {"status": Codec.Status.OK, "frame": frame, "reason": ""}


func _fail(reason: String) -> Dictionary:
	return _fail_with(Codec.E_PROTOCOL_DESYNC, reason)


func _fail_with(code: String, reason: String) -> Dictionary:
	_desync_reason = reason
	_desync_code = code
	# Drop the buffer. Holding bytes that can never be interpreted just keeps
	# memory alive for a connection that is already over.
	_buffer = PackedByteArray()
	return {"status": Codec.Status.DESYNC, "frame": {}, "reason": reason}


var _desync_code := ""


## Which coded failure this was: E_PROTOCOL_DESYNC or E_PROTOCOL_VERSION.
func desync_code() -> String:
	return _desync_code
