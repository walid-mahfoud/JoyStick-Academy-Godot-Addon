extends RefCounted

## Where a log line from the sidecar goes in the editor.
##
## Core logs at three levels and the editor has three places to put them:
## push_error, push_warning and print. Mapping them is four lines, which is
## exactly why it is worth extracting: plugin.gd needs a running editor to
## instantiate, so a rule living there can only ever be read.
##
## AND THE DRIFT THIS INVITES IS SILENT. The mapping falls through to print()
## for anything it does not recognise, so a host that one day emits "warning"
## instead of "warn" does not error. Every warning a learner should see becomes
## ordinary output, buried among it, and nothing anywhere fails -- no exception,
## no red line, no failing test. The only thing that catches it is a test
## asserting the addon handles exactly the levels the host can send, which is
## what Tests/test_log_channel.gd does against Codec.LOG_LEVELS.

const Codec := preload("res://addons/joystickacademy/protocol/frame_codec.gd")


## The three places the editor can put a line.
enum Sink { PRINT, WARNING, ERROR }


## Route a level to a sink.
##
## An unknown level goes to PRINT rather than being dropped: a line from the
## sidecar is worth showing even when its level makes no sense, and losing it
## would be the worse failure. What must not happen is a KNOWN level landing
## here by accident, which is the test's job to prevent.
static func route(level: String) -> Sink:
	match level:
		Codec.LEVEL_ERROR:
			return Sink.ERROR
		Codec.LEVEL_WARN:
			return Sink.WARNING
		_:
			return Sink.PRINT
