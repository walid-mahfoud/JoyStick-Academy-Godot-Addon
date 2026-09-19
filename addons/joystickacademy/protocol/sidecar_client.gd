extends RefCounted

## Owns the sidecar process and the conversation with it.
##
## Launch, handshake, request/response, the probe reverse channel, crash
## detection and teardown all live here. The addon's UI talks to this and never
## to a pipe.
##
## FOUR THINGS ABOUT GODOT'S PIPE API DECIDED THIS DESIGN, and all four were
## measured on 2026-09-15 against 4.5.1 driving a real child process rather than
## taken from documentation. They are recorded in full in docs/wire-protocol.md;
## the short version, because getting any of them wrong is subtle:
##
##   1. OS.execute_with_pipe's `blocking` argument DEFAULTS TO TRUE, and true
##      is unusable. A read issued before the child replied returned after
##      1501 ms. This runs on the thread that draws the editor, so the default
##      value is a frozen editor -- which means OMITTING the argument is the
##      bug.
##   2. eof_reached() does NOT go true when the child dies. Anything using it
##      to detect a dead sidecar waits forever.
##   3. Touching the pipe after the child exits prints a red engine ERROR from
##      PeekNamedPipe. A poll loop that checks the pipe before checking
##      liveness prints it EVERY TICK, so a crashed sidecar looks to a learner
##      like a wall of Godot bugs. Liveness first, pipe second.
##   4. get_length() on a LIVE pipe reports bytes available now, so it works as
##      the poll gate.
##
## A fifth, learned while testing rather than while designing:
## OS.is_process_running ONLY KNOWS PROCESSES THIS PROCESS SPAWNED. Godot keeps
## a map of its own children and returns false for any pid outside it, so it
## reports a perfectly healthy process as dead purely because somebody else
## launched it. That is fine here -- this file only ever asks about its own
## child -- but it is a trap for anything checking a pid it was handed, and
## Tests/test_orphan_on_hard_kill.gd had to go to the OS directly because of it.

const Codec := preload("res://addons/joystickacademy/protocol/frame_codec.gd")
const FrameReader := preload("res://addons/joystickacademy/protocol/frame_reader.gd")

signal ready_received(host_version: String, core_version: String)
signal response_received(id: int, result: Variant)
signal request_failed(id: int, code: String)
signal event_received(event_name: String, data: Dictionary)
signal log_received(level: String, message: String)
## The host is asking the editor something only the editor knows. Answer with
## answer_probe() or refuse_probe(). See the re-entrancy rule below.
signal probe_requested(id: int, method: String, args: Dictionary)
signal disconnected(reason: String, code: String)

## Deadlines, matching docs/wire-protocol.md.
const READY_TIMEOUT_SECONDS := 10.0
const REQUEST_TIMEOUT_SECONDS := 30.0
const STOP_GRACE_SECONDS := 3.0

enum State { STOPPED, STARTING, READY, FAILED }

var _pid := -1
var _io: FileAccess = null
var _err: FileAccess = null
var _reader: FrameReader = null
var _state: State = State.STOPPED
var _next_id := 0
var _outstanding := {}            ## id -> {"method": String, "deadline": float}
var _elapsed := 0.0
var _ready_deadline := 0.0
var _stop_requested := false
var _stop_deadline := 0.0
var _last_failure := ""
var _exe_path := ""
var _hello := {}


func state() -> State:
	return _state


func is_running() -> bool:
	return _pid != -1 and OS.is_process_running(_pid)


func last_failure() -> String:
	return _last_failure


func pid() -> int:
	return _pid


## Launch the sidecar and send the greeting.
##
## Returns "" on success, or a human-readable reason it could not start. The
## reason is for the Diagnostics view and the Output panel, never for a frame.
func start(executable_path: String, hello: Dictionary) -> String:
	if _state != State.STOPPED:
		return "already started"

	if not FileAccess.file_exists(executable_path):
		_state = State.FAILED
		_last_failure = "the bundled sidecar is missing from the addon"
		return _last_failure

	_exe_path = executable_path
	_hello = hello

	# blocking = FALSE, explicitly. See note 1 at the top of this file: the
	# default is true and true freezes the editor.
	var info: Dictionary = OS.execute_with_pipe(executable_path, PackedStringArray(), false)
	if info.is_empty():
		_state = State.FAILED
		_last_failure = "the sidecar could not be launched"
		return _last_failure

	_pid = int(info.get("pid", -1))
	_io = info.get("stdio")
	_err = info.get("stderr")
	_reader = FrameReader.new()
	_state = State.STARTING
	_elapsed = 0.0
	_ready_deadline = READY_TIMEOUT_SECONDS
	_stop_requested = false
	_last_failure = ""
	_outstanding.clear()

	var greeting := hello.duplicate(true)
	greeting["v"] = Codec.PROTOCOL_VERSION
	greeting["k"] = Codec.KIND_HELLO
	greeting["proto"] = Codec.PROTOCOL_VERSION
	_write(greeting)
	return ""


## Drive the conversation. Call once per editor frame.
##
## Everything here is non-blocking by construction; the one measured exception
## is the `blocking` argument in start(), which is why it is spelled out there.
func poll(delta: float) -> void:
	if _state == State.STOPPED or _state == State.FAILED:
		return

	_elapsed += delta

	# LIVENESS FIRST. See note 3: touching a dead pipe prints a red engine error
	# from PeekNamedPipe, and a poll loop that reads before checking would print
	# it every single tick.
	var alive := is_running()

	if alive:
		_drain_pipe()
	else:
		# Take whatever is still sitting in the OS buffer before declaring the
		# connection over -- the sidecar's last words may include the very error
		# that explains why it died.
		_drain_pipe()
		_reader.mark_end_of_stream()

	_dispatch_frames()

	if not alive:
		_finish(_reader.desync_reason() if _reader.desync_reason() != "" else "the sidecar stopped",
			_reader.desync_code() if _reader.desync_code() != "" else Codec.E_SHUTTING_DOWN)
		return

	_check_deadlines()


func _drain_pipe() -> void:
	if _io == null:
		return
	# get_length() on a live pipe reports bytes available NOW (note 4).
	var available := _io.get_length()
	if available > 0:
		_reader.feed(_io.get_buffer(available))


func _dispatch_frames() -> void:
	while true:
		var got: Dictionary = _reader.next()
		var status: int = got["status"]
		if status == Codec.Status.EMPTY:
			return
		if status == Codec.Status.DESYNC:
			# Unrecoverable by design. Kill the process: a sidecar still running
			# on a stream nobody can read is an orphan holding a session token.
			_finish(_reader.desync_reason(), _reader.desync_code())
			return
		_handle(got["frame"])
		if _state == State.STOPPED or _state == State.FAILED:
			return


func _handle(frame: Dictionary) -> void:
	match str(frame.get("k", "")):
		Codec.KIND_READY:
			_state = State.READY
			ready_received.emit(str(frame.get("host", "")), str(frame.get("core", "")))

		Codec.KIND_RESPONSE:
			var id := Codec.id_of(frame)
			_outstanding.erase(id)
			response_received.emit(id, frame.get("r"))

		Codec.KIND_ERROR:
			var err_id := Codec.id_of(frame)
			var code := Codec.error_code(frame)
			if _state == State.STARTING and code == Codec.E_PROTOCOL_VERSION:
				# A half-upgraded install: a new addon beside an old sidecar
				# after a partial file copy. Refused at the first frame, which
				# is the entire job of the handshake.
				_finish("the bundled sidecar does not match this addon version",
					Codec.E_PROTOCOL_VERSION)
				return
			_outstanding.erase(err_id)
			request_failed.emit(err_id, code)

		Codec.KIND_PROBE:
			# Emitted to whoever implements IEditorProbe in GDScript.
			#
			# THE RULE THAT CANNOT BE ENFORCED IN CODE: a probe handler must
			# never issue a request back to the host. The host runs requests on
			# one serial worker, so the request would queue behind the very one
			# that is waiting for this answer. Nothing in the protocol can
			# detect it, which is why probe handlers read the scene tree and do
			# nothing else.
			probe_requested.emit(Codec.id_of(frame), str(frame.get("m", "")),
				frame.get("a", {}) if typeof(frame.get("a")) == TYPE_DICTIONARY else {})

		Codec.KIND_EVENT:
			event_received.emit(str(frame.get("n", "")),
				frame.get("d", {}) if typeof(frame.get("d")) == TYPE_DICTIONARY else {})

		Codec.KIND_LOG:
			log_received.emit(str(frame.get("l", "info")), str(frame.get("m", "")))

		Codec.KIND_BYE:
			_finish("the sidecar said goodbye", "")

		_:
			# An unknown kind is not fatal. The sidecar may be newer and sending
			# something optional; dropping the connection over it would make
			# every additive protocol change a breaking one.
			pass


func _check_deadlines() -> void:
	if _state == State.STARTING and _elapsed > _ready_deadline:
		_finish("the sidecar did not answer the handshake", Codec.E_TIMEOUT)
		return

	if _stop_requested and _elapsed > _stop_deadline:
		# It was asked to leave and did not. Kill it: an orphan holding a
		# session token is both a bug and a security problem.
		_finish("the sidecar did not exit when asked", Codec.E_SHUTTING_DOWN)
		return

	# A request that will never be answered must fail rather than hang a
	# spinner. Collected first because erasing while iterating a Dictionary is
	# not safe.
	var expired: Array[int] = []
	for id in _outstanding:
		if _elapsed > float(_outstanding[id]["deadline"]):
			expired.append(int(id))
	for id in expired:
		_outstanding.erase(id)
		request_failed.emit(id, Codec.E_TIMEOUT)


## Send a request. Returns the correlation id, or -1 when there is no session.
func request(method: String, args: Dictionary = {}) -> int:
	if _state != State.READY:
		return -1
	_next_id += 1
	var frame := {
		"v": Codec.PROTOCOL_VERSION,
		"k": Codec.KIND_REQUEST,
		"id": _next_id,
		"m": method,
	}
	if not args.is_empty():
		frame["a"] = args
	_outstanding[_next_id] = {
		"method": method,
		"deadline": _elapsed + REQUEST_TIMEOUT_SECONDS,
	}
	if not _write(frame):
		_outstanding.erase(_next_id)
		return -1
	return _next_id


## Answer a probe the host asked for.
func answer_probe(id: int, result: Dictionary) -> void:
	_write({
		"v": Codec.PROTOCOL_VERSION,
		"k": Codec.KIND_PROBE_RESPONSE,
		"id": id,
		"r": result,
	})


## Refuse a probe, with a reason the host can act on.
##
## E_PROBE_UNSUPPORTED means "Godot cannot answer this KIND of question", which
## is what lets an author learn their step can never pass here instead of a
## learner watching a check that never goes green. E_PROBE_FAILED means "it
## could be answered and something went wrong". Flattening the two loses the
## distinction that matters.
func refuse_probe(id: int, code: String = Codec.E_PROBE_UNSUPPORTED) -> void:
	_write({
		"v": Codec.PROTOCOL_VERSION,
		"k": Codec.KIND_PROBE_RESPONSE,
		"id": id,
		"e": {"code": code},
	})


## Ask the sidecar to shut down, and kill it if it will not.
func stop() -> void:
	if _state == State.STOPPED or _state == State.FAILED:
		_kill_if_running()
		return
	_stop_requested = true
	_stop_deadline = _elapsed + STOP_GRACE_SECONDS
	_write({"v": Codec.PROTOCOL_VERSION, "k": Codec.KIND_BYE})


## Stop without ceremony. For _exit_tree and for the plugin being disabled.
##
## An orphaned sidecar holding a session token is both a bug and a security
## problem, so this never returns without the process being gone.
func shutdown_now() -> void:
	_finish("the addon is shutting down", "")


func _write(frame: Dictionary) -> bool:
	if _io == null or not is_running():
		return false
	_io.store_buffer(Codec.encode(frame))
	_io.flush()
	# store_buffer does not report failure, so the only honest check is whether
	# the process is still there afterwards.
	return true


func _finish(reason: String, code: String) -> void:
	if _state == State.STOPPED or _state == State.FAILED:
		return

	var stderr_tail := _read_stderr_tail()
	_kill_if_running()

	_io = null
	_err = null
	_state = State.STOPPED
	_last_failure = reason

	# Everything still waiting must fail NOW rather than time out one by one.
	# On a step with several checks that is tens of seconds of an editor that
	# looks hung after the sidecar has already gone.
	var waiting := _outstanding.keys()
	_outstanding.clear()
	for id in waiting:
		request_failed.emit(int(id), code if code != "" else Codec.E_SHUTTING_DOWN)

	var full := reason
	if stderr_tail != "":
		full += "\n" + stderr_tail
	disconnected.emit(full, code)


func _read_stderr_tail() -> String:
	# The sidecar's own diagnostics. Never parsed as frames -- stdout carries
	# frames and nothing else -- but very often the only record of why it died.
	if _err == null:
		return ""
	var available := 0
	if _pid != -1 and OS.is_process_running(_pid):
		available = _err.get_length()
	else:
		# The process is gone, so get_length would print the PeekNamedPipe
		# error. Read a bounded chunk instead and accept that it may be empty.
		available = 0
	if available <= 0:
		return ""
	return _err.get_buffer(available).get_string_from_utf8().strip_edges()


func _kill_if_running() -> void:
	if _pid != -1 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
