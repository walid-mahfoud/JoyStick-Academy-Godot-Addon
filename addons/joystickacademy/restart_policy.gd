extends RefCounted

## What to do when the sidecar stops.
##
## Pulled out of plugin.gd so it can be tested. EditorPlugin needs a running
## editor, and "we retry three times with backoff" is the kind of claim that
## quietly becomes "we retry forever" during a refactor nobody tested.

const Codec := preload("res://addons/joystickacademy/protocol/frame_codec.gd")

## Seconds between attempts, and BOUNDED.
##
## A sidecar that cannot start will not start on the fifth try either. A plugin
## that relaunches a failing process forever is worse than one that stops and
## says so: it burns the machine and buries the reason under its own noise.
const BACKOFF := [1.0, 3.0, 10.0]

enum Action {
	RETRY,       ## Wait, then start again.
	GIVE_UP,     ## Stop, and explain.
	BROKEN,      ## Stop, and explain differently: retrying cannot possibly help.
}


## Decide, given how the connection ended and how many restarts have been used.
##
## Returns {"action": Action, "wait": float, "attempt": int, "of": int}.
static func decide(code: String, restarts_used: int) -> Dictionary:
	if code == Codec.E_PROTOCOL_VERSION:
		# The two halves disagree about the protocol, and they will disagree
		# again in one second. This is a broken install, not a crash, and
		# retrying it produces three identical failures and a worse message.
		return {"action": Action.BROKEN, "wait": 0.0, "attempt": 0, "of": BACKOFF.size()}

	if restarts_used >= BACKOFF.size():
		return {"action": Action.GIVE_UP, "wait": 0.0,
			"attempt": restarts_used, "of": BACKOFF.size()}

	return {
		"action": Action.RETRY,
		"wait": BACKOFF[restarts_used],
		"attempt": restarts_used + 1,
		"of": BACKOFF.size(),
	}


## How many restarts remain after a SUCCESSFUL connection.
##
## Zero, always. Counting restarts for the life of the editor would punish a
## long healthy session for one bad moment: a plugin that ran happily for an
## hour and then crashed once would find it had already spent its budget hours
## earlier, and refuse to come back.
static func on_connected() -> int:
	return 0
