@tool
extends RefCounted

## What turns a learner's press into a sidecar request, and the answer into a
## rendered view.
##
## Plan items 39 to 49 are each a route through here. The views neither fetch
## nor send -- see `view_base.gd` -- and the dock only collects; this is the one
## place that knows there is a sidecar at all, which is what makes the other
## twenty-odd files testable without one.
##
## A REQUEST IS PAIRED WITH THE VIEW THAT ASKED, and that pairing is the whole
## reason this is a class rather than a function. The sidecar answers by id, out
## of order, possibly after the learner has navigated somewhere else -- so an
## answer has to find its way back to a view that may no longer be on screen, or
## be dropped if the thing that asked is gone.
##
## NOTHING IS SENT WHEN THE SIDECAR IS NOT READY. Queueing would be worse than
## refusing: a learner who pressed Sign in while the helper was starting would
## get an answer minutes later, over whatever they were doing by then. The press
## is refused with a reason the view can show, which is the honest outcome.
##
## AND A REFUSAL IS RENDERED, NOT LOGGED. The failure this plugin most needs to
## avoid is "nothing happens" -- a press that produces no visible result gives a
## learner nothing to search for and nothing to tell support.

const Codec := preload("res://addons/joystickacademy/protocol/frame_codec.gd")
const Dock := preload("res://addons/joystickacademy/ui/dock.gd")
const LocalCommands := preload("res://addons/joystickacademy/ui/local_commands.gd")

## How a view is told a request could not even be attempted.
const OFFLINE_ERROR := "The JoyStick Academy helper is not running."

## How a view is told the helper went away with its request still open.
const DROPPED_ERROR := "The helper stopped before answering. Try again."

## How often the player asks for its checks again while it is on screen.
##
## THE CADENCE IS THE POINT OF THE PLAYER (plan item 40): a learner edits the
## scene in the editor and the strip underneath the step follows along without
## them pressing anything. Two seconds is slow enough that a probe sweep is not
## competing with the editor for the main thread, and fast enough that dragging
## a node into place and looking down feels like it answered.
const RECHECK_SECONDS := 2.0

## How often the panel asks whether the phone has handed a lesson over.
##
## TEN SECONDS, NOT TWO. Nobody is waiting on this: a learner who pressed
## "Practise in Godot" on their phone is picking the editor up, and the few
## seconds between are spent moving a chair. Polling it at the player's cadence
## would put a network round trip behind every idle editor in the world for a
## feature most of them are not using that minute.
const HANDOFF_SECONDS := 10.0

## The views that are PART of the walkthrough rather than somewhere else.
##
## Opening a hint or a definition is not leaving the lesson, and treating it as
## leaving destroyed the run on the sidecar -- see `_watch_navigation`.
const PLAYER_SUBVIEWS := [Dock.VIEW_HINTS, Dock.VIEW_GLOSSARY]

## Events the sidecar pushes without being asked.
const EVENT_SESSION_CHANGED := "session.changed"
const EVENT_HANDOFF_OFFERED := "handoff.offered"
const EVENT_WALKTHROUGH_PROGRESS := "walkthrough.progress"
const EVENT_STANDING_CHANGED := "standing.changed"

## A pairing ended without signing anybody in.
##
## ITS OWN EVENT RATHER THAN `session.changed`, because that one renders into
## the ACCOUNT view: a refusal sent there would leave the sign-in page showing
## its last payload, which is the dead code the learner is already staring at.
const EVENT_PAIRING_CHANGED := "pairing.changed"

## Which view each answer renders into, what to ask the sidecar for, and where
## the learner goes.
##
## ONE TABLE RATHER THAN A SWITCH, because the routes are data: a method, the
## view it belongs to, and whether the answer replaces that view's payload or
## sends the learner somewhere else. A switch would put thirty routes in thirty
## places and make "which view does this answer belong to" unanswerable without
## reading all of them.
##
## THE KEYS ARE WHAT A VIEW REPORTS; `as` IS WHAT GOES ON THE WIRE. They are
## usually the same and deliberately allowed to differ: a view names the thing
## the LEARNER did, and two views doing the same thing to the sidecar -- the
## player and the hints page both opening a definition -- should not oblige the
## sidecar to grow two methods for it.
##
##   into    the view the answer renders into, and where a failure is shown
##   as      the sidecar method, when it differs from the key
##   open    show this view immediately, before the answer arrives
##   then    show this view when the answer arrives, and only on success
##   silent  a background report: no error is shown if it cannot be sent
##   local   the shell cannot do this without the editor; collect it instead
##   nav     navigation only. Nothing is sent, and nothing is waited for.
##   when    render the answer only when it carries this key as true
##   once    navigate only when this key's value has changed since last time
##   release the answer ends the player's wait for a play-mode window
const ROUTES := {
	# Item 39. Sign in by pairing this editor to a phone.
	#
	# NO `then`. Signing in finishes when the PHONE claims the code, which the
	# sidecar reports as a `session.changed` event -- not when this request
	# answers, because this request answers as soon as there is a code to show.
	"auth.begin": {"into": Dock.VIEW_SIGN_IN},
	"auth.cancel": {"into": Dock.VIEW_SIGN_IN},
	"auth.copy_code": {"into": Dock.VIEW_SIGN_IN, "local": true},
	"account.sign_out": {"into": Dock.VIEW_ACCOUNT},
	# Two views offer a way in to the same page and neither asks the sidecar
	# anything. Fetching a code on arrival would burn one for somebody who
	# opened the page to look; the page says what to press.
	"account.sign_in": {"into": Dock.VIEW_SIGN_IN, "open": Dock.VIEW_SIGN_IN, "nav": true},
	"library.sign_in": {"into": Dock.VIEW_SIGN_IN, "open": Dock.VIEW_SIGN_IN, "nav": true},

	# Items 40 and 42. The player, and resuming into the saved step.
	"library.open_lesson": {"into": Dock.VIEW_PLAYER, "as": "walkthrough.open",
		"open": Dock.VIEW_PLAYER},
	"library.resume": {"into": Dock.VIEW_PLAYER, "as": "walkthrough.resume",
		"open": Dock.VIEW_PLAYER},
	"library.refresh": {"into": Dock.VIEW_LIBRARY},
	"library.dismiss_resume": {"into": Dock.VIEW_LIBRARY},

	# Item 43. The phone said "practise this in Godot".
	#
	# MOST ANSWERS TO THIS ARE "NOTHING", which is why it carries `when`:
	# rendering every poll would redraw the library ten times a minute and
	# scroll a learner back to the top each time. `silent` is not the same
	# thing and would be wrong here -- it draws nothing ever.
	"handoff.poll": {"into": Dock.VIEW_LIBRARY, "then": Dock.VIEW_LIBRARY,
		"when": "offered", "once": "sessionId"},
	"walkthrough.next": {"into": Dock.VIEW_PLAYER},
	"walkthrough.back": {"into": Dock.VIEW_PLAYER},
	"walkthrough.recheck": {"into": Dock.VIEW_PLAYER},
	# Leaving reports itself so the sidecar can stop the run and the phone's
	# watching screen can stop following. Telling a learner their DEPARTURE
	# failed would be noise about nothing, so it is silent.
	"walkthrough.leave": {"into": Dock.VIEW_PLAYER, "silent": true},

	# Item 44. Gem-cost hints.
	"walkthrough.hint": {"into": Dock.VIEW_HINTS, "as": "hint.open",
		"open": Dock.VIEW_HINTS},
	"hints.reveal": {"into": Dock.VIEW_HINTS, "as": "hint.reveal"},
	"hints.buy_gems": {"into": Dock.VIEW_HINTS, "as": "hint.buy_gems"},

	# Item 45. Glossary definitions. Three ways in, one method.
	"walkthrough.glossary": {"into": Dock.VIEW_GLOSSARY, "as": "glossary.open_term",
		"open": Dock.VIEW_GLOSSARY},
	"hints.glossary": {"into": Dock.VIEW_GLOSSARY, "as": "glossary.open_term",
		"open": Dock.VIEW_GLOSSARY},
	"glossary.open_term": {"into": Dock.VIEW_GLOSSARY},

	# Item 46. Capstone studio and submission.
	"capstone.recheck": {"into": Dock.VIEW_CAPSTONE},
	"capstone.claim": {"into": Dock.VIEW_CAPSTONE},
	"capstone.open_milestone": {"into": Dock.VIEW_CAPSTONE},
	"capstone.submit": {"into": Dock.VIEW_SUBMISSION, "as": "submission.begin",
		"open": Dock.VIEW_SUBMISSION},
	"submission.submit": {"into": Dock.VIEW_SUBMISSION},
	"submission.cancel": {"into": Dock.VIEW_SUBMISSION},
	"submission.save_notes": {"into": Dock.VIEW_SUBMISSION, "silent": true},
	"submission.browse_archive": {"into": Dock.VIEW_SUBMISSION, "local": true},
	"submission.browse_screenshots": {"into": Dock.VIEW_SUBMISSION, "local": true},

	# Play-mode observation. `player.run` is LOCAL: the sidecar cannot launch a
	# game, and in Godot neither can it watch one -- the game is a third process
	# that only the editor can start. `walkthrough.observed` is the answer
	# coming back, and it re-renders the player because the whole point of it is
	# that the checks have changed.
	"player.run": {"into": Dock.VIEW_PLAYER, "local": true},
	"walkthrough.observed": {"into": Dock.VIEW_PLAYER, "release": true},

	# Item 47. The learner's standing.
	"standing.refresh": {"into": Dock.VIEW_STANDING},

	# What a tab asks for when it opens its view. See ON_OPEN.
	"account.describe": {"into": Dock.VIEW_ACCOUNT},
	"capstone.open": {"into": Dock.VIEW_CAPSTONE},

	# Item 48. Diagnostics.
	"diagnostics.run": {"into": Dock.VIEW_DIAGNOSTICS},
	"diagnostics.copy": {"into": Dock.VIEW_DIAGNOSTICS, "local": true},
	"account.diagnostics": {"into": Dock.VIEW_DIAGNOSTICS,
		"open": Dock.VIEW_DIAGNOSTICS, "nav": true},
	"account.support": {"into": Dock.VIEW_ACCOUNT, "local": true},
}

## What a view asks for when a tab opens it.
##
## A TAB IS THE ONE WAY INTO A VIEW THAT IS NOT A BUTTON, so it is the one that
## would otherwise show whatever was last rendered -- which on a fresh session
## is nothing, and an empty page with no error on it is the failure this whole
## design is arranged against. The dock reports the open; this says what to ask
## for.
##
## A VIEW WITH NO ENTRY HERE IS FINE and means "nothing to fetch": the sign-in
## page has nothing to ask for until the learner presses Sign in, and fetching a
## pairing code for somebody who opened the page to look would burn one.
const ON_OPEN := {
	Dock.VIEW_LIBRARY: "library.refresh",
	Dock.VIEW_PLAYER: "walkthrough.recheck",
	Dock.VIEW_CAPSTONE: "capstone.open",
	Dock.VIEW_ACCOUNT: "account.describe",
	Dock.VIEW_STANDING: "standing.refresh",
}

## What to show a learner for each wire error code.
##
## THE CODE IS NOT THE MESSAGE. `E_NOT_SIGNED_IN` tells somebody who reads the
## protocol what happened and tells everybody else nothing; and a raw code in a
## panel is the thing that gets screenshotted into a support message with no
## other context. The code is appended to the words, because support needs it.
##
## EVERY CODE THE CODEC DECLARES IS IN HERE, and a test walks the codec to say
## so. A code added on the wire and missed here does not break anything -- it
## falls through to "Something went wrong", which is exactly how a specific,
## actionable failure becomes an unactionable one without a single test going
## red.
const EXPLANATIONS := {
	Codec.E_PROTOCOL_VERSION: "The plugin and its helper do not match. "
		+ "Reinstalling the plugin should fix it.",
	Codec.E_PROTOCOL_DESYNC: "The plugin lost track of its helper and restarted it.",
	Codec.E_UNKNOWN_METHOD: "This version of the helper cannot do that yet. "
		+ "Reinstalling the plugin should fix it.",
	Codec.E_BAD_ARGS: "The helper refused that request.",
	Codec.E_NOT_SIGNED_IN: "You are signed out. Sign in from the Account tab.",
	Codec.E_OFFLINE: "No connection. Check your network and try again.",
	Codec.E_SERVER: "JoyStick Academy is having trouble. Try again shortly.",
	Codec.E_TIMEOUT: "That took too long. Try again.",
	Codec.E_PROBE_UNSUPPORTED: "Godot cannot answer that kind of check.",
	Codec.E_PROBE_FAILED: "A check could not be run against your scene.",
	Codec.E_SHUTTING_DOWN: "The helper is stopping.",
	Codec.E_INTERNAL: "Something went wrong inside the helper.",
}

## What is said when the code is not one of the above.
const UNEXPLAINED := "Something went wrong."

var _dock: Node = null
var _client: RefCounted = null

## Request id to the route it came from, so an answer can find its view.
var _pending := {}
## Commands a route marks `local`: the shell handles them without the sidecar.
var _local: Array = []
## Seconds until the player asks for its checks again. Negative means idle.
var _recheck_in := -1.0
## Seconds until the panel next asks whether a hand-off is waiting.
var _handoff_in := HANDOFF_SECONDS
## The id of the hand-off poll in flight, so the cadence never stacks.
var _handoff_id := 0
## Which hand-off the learner has already been shown.
##
## OFFERED ONCE, NOT EVERY TEN SECONDS. The sidecar answers `offered` for as
## long as the session is open, so somebody who ignores a hand-off and goes on
## reading was dragged back to the library on every poll -- which is the same
## interruption the `when` flag exists to prevent, arriving from the other side.
var _offered_session := ""
## Which view was showing last time anything looked. See `_watch_navigation`.
var _showing := ""
## Whether the learner is inside the walkthrough -- the player OR its subviews.
##
## A SET, NOT A VIEW. The hints and the glossary hide the player and are part of
## the same run; comparing against the player alone misses every departure made
## from one of them.
var _inside_walkthrough := false
## Whether the last `session.changed` said they were signed in.
##
## SO A RECONNECT IS NOT A SIGN-OUT. The event carries a state and the panel
## needs the transition; without this every sidecar restart looked like the
## learner had just signed out.
var _signed_in := false
## The id of the re-check in flight, so the cadence never stacks requests.
var _recheck_id := 0


func _init(dock: Node, client: RefCounted = null) -> void:
	_dock = dock
	if _dock != null:
		_showing = _dock.current_view()
	set_client(client)


## Point the shell at a sidecar, or at none.
##
## THE SHELL OUTLIVES THE CONNECTION, which is why this exists at all. The dock
## is built when the addon is enabled and the client is built after it, replaced
## on every restart, and null in between; a shell tied to one client would have
## to be rebuilt each time, taking with it the local commands nobody has read
## yet and the knowledge of what was waiting.
##
## SWAPPING DROPS WHAT WAS IN FLIGHT, and says so. Those ids belong to a
## conversation that has ended -- a new sidecar starts its numbering again, so
## keeping them would eventually match somebody else's answer to them.
func set_client(client: RefCounted) -> void:
	if client == _client:
		return
	if _client != null:
		if _client.response_received.is_connected(_on_response):
			_client.response_received.disconnect(_on_response)
		if _client.request_failed.is_connected(_on_failed):
			_client.request_failed.disconnect(_on_failed)
		on_disconnected()
	_client = client
	if _client == null:
		return
	_client.response_received.connect(_on_response)
	_client.request_failed.connect(_on_failed)
	# A HELPER ARRIVING IS THE FIRST MOMENT ANYTHING CAN BE FETCHED. The dock is
	# built when the addon is enabled and the sidecar connects a second or two
	# later; without this the panel shows an empty library until the learner
	# happens to press a tab it is already on, which is not a press anybody makes.
	if _dock != null:
		_on_view_opened(_dock.current_view())


## Requests still waiting for an answer.
func pending_count() -> int:
	return _pending.size()


## Commands the shell handled itself, cleared by reading. Opening a file dialog
## and putting text on a clipboard both need the editor, which this class does
## not have and a test has not got either -- so they are collected for whoever
## does.
func take_local() -> Array:
	var out := _local
	_local = []
	return out


## Drain whatever the views have asked for. Called from the plugin's poll.
func pump() -> void:
	if _dock == null:
		return
	for command in _dock.take_commands():
		_dispatch(command)
	_watch_navigation()


## Notice where the learner has gone, and report leaving a walkthrough.
##
## BY WATCHING THE ROUTER, NOT THE CALL SITES. Navigation happens from four
## places -- a route's `open`, a route's `then`, an event, and a SIDEBAR TAB,
## which the dock performs itself -- and a check at each of them is four places
## to forget. The router knows which view is showing; the difference between two
## readings of it is a navigation, whoever caused it.
##
## LEAVING IS NOT THE SAME AS BEING HIDDEN. The hints and the glossary hide the
## player and are part of the same walkthrough; the library and the account page
## are not. The player used to decide this itself, from `on_hidden`, and could
## not tell the two apart -- so opening a hint told the sidecar to forget the
## run the hint belonged to.
func _watch_navigation() -> void:
	var now: String = _dock.current_view()
	if now == _showing:
		return
	_showing = now

	# THE WALKTHROUGH IS A SET OF VIEWS, NOT ONE VIEW, and the first version of
	# this compared against the player alone. A learner who opened a hint and
	# then went to the Library left FROM THE HINTS PAGE, so `was` was not the
	# player and the sidecar was never told -- the run stayed open, its gems
	# still spendable, and the phone still showed them practising.
	#
	# Tracking membership of the set rather than the last view is what makes
	# every way out report: player, hints or glossary, to anywhere else.
	var inside := now == Dock.VIEW_PLAYER or PLAYER_SUBVIEWS.has(now)
	var was_inside := _inside_walkthrough
	_inside_walkthrough = inside
	if not was_inside or inside:
		return

	# Silent by its route: a learner who walked away is not told their
	# departure failed.
	_send("walkthrough.leave", ROUTES["walkthrough.leave"], {})


## Advance the player's re-check cadence. Called from the plugin's poll.
##
## ONLY WHILE THE PLAYER IS SHOWING. A sweep of scene probes for a walkthrough
## nobody is looking at is work the editor pays for and the learner never sees,
## and the probes run on the thread that draws the editor.
func tick(delta: float) -> void:
	if _dock == null:
		return
	_tick_handoff(delta)

	_watch_navigation()

	if _dock.current_view() != Dock.VIEW_PLAYER:
		_recheck_in = -1.0
		return

	if _recheck_in < 0.0:
		_recheck_in = RECHECK_SECONDS
		return

	_recheck_in -= delta
	if _recheck_in > 0.0:
		return
	_recheck_in = RECHECK_SECONDS

	# NEVER TWO AT ONCE. A sweep that takes longer than the cadence would
	# otherwise queue a second behind it and a third behind that, and the
	# editor would get slower the slower it already was.
	if _recheck_id != 0 and _pending.has(_recheck_id):
		return
	_recheck_id = _send("walkthrough.recheck", ROUTES["walkthrough.recheck"], {})


## Put the files a learner chose into the picker that asked for them.
##
## THE SLOT TRAVELS OUT WITH THE PLAN AND BACK WITH THE ANSWER, so the dialog's
## callback does not have to remember which button opened it -- which matters
## because there is ONE dialog and two buttons, and an editor file dialog
## outlives the press that opened it.
##
## AN EMPTY ANSWER IS A CANCELLED DIALOG and clears nothing. Somebody who opened
## the picker to look, and closed it, still has the file they chose before.
func apply_local_result(slot: String, paths: PackedStringArray) -> void:
	if _dock == null or paths.size() == 0:
		return
	var view = _dock.view(Dock.VIEW_SUBMISSION)
	if view == null:
		return
	match slot:
		LocalCommands.SLOT_ARCHIVE:
			view.archive_picker().set_path(paths[0])
		LocalCommands.SLOT_SCREENSHOTS:
			# ADDED, NOT REPLACED. Choosing three screenshots in one pass and
			# two in another is the ordinary way somebody assembles five, and a
			# dialog that replaced the list would make the second pass undo the
			# first.
			view.screenshot_picker().add_paths(paths)
		_:
			push_error("[JoyStick Academy] no picker called '%s'" % slot)


## Give the Run button back, if the player is built.
func _release_run() -> void:
	if _dock == null:
		return
	var view = _dock.view(Dock.VIEW_PLAYER)
	if view != null and view.has_method("release_run"):
		view.release_run()


## A play-mode window finished. Tell the sidecar what it saw.
##
## THE RECORDS GO UP EVEN WHEN THE RUN WENT WRONG. A game that threw is a real
## observation and `ran_without_errors` is the check that wants it; dropping it
## would render as "no window ran", which sends the learner to press Run again
## instead of to read their own error.
##
## Called by the plugin, which owns the runner because the runner needs an
## editor. Everything above this line stays testable without one.
func report_window(payload: Dictionary) -> void:
	var id := _send("walkthrough.observed", ROUTES["walkthrough.observed"], payload)
	if id > 0:
		return

	# NO HELPER TO TELL. Every other press in this file renders OFFLINE_ERROR on
	# exactly this condition and this one returned silently, so a window the
	# learner had just sat through was discarded with the button still greyed
	# and nothing on screen to explain it.
	#
	# The run itself is gone either way -- the records live in the addon and the
	# buffer is a C# type -- so the honest thing is to say so and give the
	# button back, rather than to leave them waiting on an answer that is not
	# coming.
	_release_run()
	_render_error(Dock.VIEW_PLAYER, OFFLINE_ERROR)


## Ask, now and then, whether the phone has handed a lesson over.
##
## NOT WHILE THE PLAYER IS OPEN. Somebody working through a walkthrough is not
## interrupted by an offer to start one -- and the sidecar refuses on the same
## grounds, so this is the cheaper half of one rule rather than a second rule.
func _tick_handoff(delta: float) -> void:
	if _dock.current_view() == Dock.VIEW_PLAYER:
		return
	_handoff_in -= delta
	if _handoff_in > 0.0:
		return
	_handoff_in = HANDOFF_SECONDS
	if _handoff_id != 0 and _pending.has(_handoff_id):
		return
	_handoff_id = _send("handoff.poll", ROUTES["handoff.poll"], {})


## Something the sidecar said without being asked.
func on_event(event_name: String, data: Dictionary) -> void:
	if _dock == null:
		return
	match event_name:
		EVENT_SESSION_CHANGED:
			_render(Dock.VIEW_ACCOUNT, data)
			# A TRANSITION, NOT A STATE. This event also arrives whenever the
			# sidecar connects -- at startup, and after every restart -- and the
			# signed-out branch had none of the guard the signed-in branch has,
			# so a learner who was signed out and reading the Diagnostics page
			# was dragged to the sign-in page by each reconnect. Diagnostics is
			# exactly where somebody goes when the helper keeps restarting, so
			# the interruption landed hardest where it was least wanted.
			var signed_in := bool(data.get("signedIn", false))
			var was_signed_in := _signed_in
			_signed_in = signed_in

			if not signed_in:
				# Signing out anywhere takes the learner off whatever they were
				# doing: every other view is about an account that is now gone.
				# Only on the way OUT, though -- see above.
				if was_signed_in:
					_dock.show_view(Dock.VIEW_SIGN_IN)
			elif _dock.current_view() == Dock.VIEW_SIGN_IN:
				# AND FETCHED, not merely shown. The library on screen was drawn
				# for somebody signed OUT -- "Sign in to see your courses" and a
				# Sign in button -- so navigating alone lands the learner, just
				# after pairing, on a page telling them to sign in, whose only
				# button sends them back for a code they no longer need. The lit
				# tab is already Library, so pressing it emits nothing.
				# THIS EVENT IS WHAT FINISHES A SIGN-IN. The request that asked
				# for a code answered the moment there was one to show; the
				# learner is signed in when their PHONE claims it, which reaches
				# the panel here and nowhere else.
				#
				# Only from the sign-in page, though. The same event arrives
				# when a session is restored at startup or refreshed in the
				# background, and dragging somebody off the page they were
				# reading for that would be an interruption with no cause.
				_dock.show_view(Dock.VIEW_LIBRARY)
				_on_view_opened(Dock.VIEW_LIBRARY)
		EVENT_HANDOFF_OFFERED:
			# Item 43. The phone said "practise this in Godot". It arrives as
			# the library's existing resume banner rather than as a new kind of
			# interruption: the learner is being offered a lesson to open,
			# which is what that banner already means.
			_render(Dock.VIEW_LIBRARY, data)
			_dock.show_view(Dock.VIEW_LIBRARY)
		EVENT_WALKTHROUGH_PROGRESS:
			_render(Dock.VIEW_PLAYER, data)
		EVENT_PAIRING_CHANGED:
			# THE PAGE THEY ARE LOOKING AT, and only if they still are. A code
			# that expired while somebody was reading the library is not worth
			# dragging them back for.
			_render(Dock.VIEW_SIGN_IN, data)
		EVENT_STANDING_CHANGED:
			_render(Dock.VIEW_STANDING, data)
		_:
			# AN UNKNOWN EVENT IS ORDINARY, not an error: a newer helper beside
			# an older addon is exactly what a half-finished upgrade looks like,
			# and a red line per event would bury whatever the learner was
			# doing. The dock keeps the name for the Diagnostics view.
			pass


## The helper went away. Anything still waiting will never be answered.
##
## TOLD, NOT LEFT. A view that asked for something and is never answered shows
## its spinner until the learner navigates away, which reads as the editor
## having hung -- and the connection banner they would need to see instead is
## at the bottom of the panel, below the view that is lying to them.
func on_disconnected() -> void:
	var routes: Array = _pending.values()
	_pending.clear()
	_recheck_id = 0
	# AND THIS ONE TOO. It was forgotten, and the asymmetry is the bug: a new
	# sidecar starts its numbering again, so a stale id here can match a live
	# request from the new one and the guard in `_tick_handoff` then skips a
	# cycle for no reason.
	_handoff_id = 0
	_recheck_in = -1.0
	for route in routes:
		if route.get("silent", false):
			continue
		_render_error(route["into"], DROPPED_ERROR)

	# AND THE PAIRING, WHICH HAS NO REQUEST IN FLIGHT TO REPORT THROUGH. The
	# poll runs inside the HOST, so the loop above never touches the sign-in
	# page -- and a code belongs to the sidecar that issued it, so the one on
	# screen means nothing to whatever starts next. Without this the panel went
	# on showing it under "the page changes by itself when it lands", and the
	# learner typed a dead code into their phone until they gave up.
	_render(Dock.VIEW_SIGN_IN, {
		"status": "failed",
		"error": "The helper restarted, so that code is no longer good. "
			+ "Press Sign in for a new one.",
	})


func _dispatch(command: Dictionary) -> void:
	var method := str(command.get("method", ""))
	if method == Dock.COMMAND_VIEW_OPENED:
		_on_view_opened(str(command.get("args", {}).get("view", "")))
		return

	var route: Dictionary = ROUTES.get(method, {})
	if route.is_empty():
		# A METHOD WITH NO ROUTE IS A BUG IN THIS FILE, not in the view, and it
		# must be loud: the alternative is a button that silently does nothing,
		# which is the failure this whole design is arranged against.
		push_error("[JoyStick Academy] no route for '%s'" % method)
		return

	# Navigation happens FIRST, before the request. A learner who pressed
	# "open lesson" should see the player with its spinner, not stay on the
	# library until the answer arrives -- the wait is the part that needs
	# somewhere to happen.
	if route.has("open"):
		_dock.show_view(route["open"])

	if route.get("nav", false):
		return

	if route.get("local", false):
		_local.append(command)
		return

	var id := _send(method, route, command.get("args", {}))
	if id <= 0 and not route.get("silent", false):
		_render_error(route["into"], OFFLINE_ERROR)


## A tab opened a view. Fetch whatever it draws from.
##
## SILENT WHEN THERE IS NO HELPER, unlike a press. Nobody asked for this; a
## learner switching tabs while the sidecar starts would otherwise meet an error
## on every tab they touched, and the status strip at the bottom of the panel
## already says what is wrong.
func _on_view_opened(view_name: String) -> void:
	var method: String = ON_OPEN.get(view_name, "")
	if method == "":
		return
	var route: Dictionary = ROUTES.get(method, {})
	if route.is_empty():
		push_error("[JoyStick Academy] no route for '%s'" % method)
		return
	_send(method, route, {})


## Send one request, or return 0 when there is nothing to send it to.
func _send(method: String, route: Dictionary, args: Dictionary) -> int:
	if _client == null or not _client.is_running():
		return 0
	var id: int = _client.request(str(route.get("as", method)), args)
	if id <= 0:
		return 0
	_pending[id] = route
	return id


func _on_response(id: int, result: Variant) -> void:
	var route: Dictionary = _pending.get(id, {})
	if route.is_empty():
		# NOT AN ERROR. A response whose request this shell has forgotten is
		# what a reconnect leaves behind, and complaining about it would put a
		# red line in a learner's Output panel for something that went right.
		return
	_pending.erase(id)

	# THE WAIT ENDS ON THE ANSWER, NOT ON A RENDER. Every payload re-renders the
	# player -- including the recheck that runs every two seconds while it is
	# showing -- so clearing the wait there gave the button back about two
	# seconds after launch, while Godot was still opening the game.
	#
	# Before the `silent` and `when` guards below, because a dropped or
	# uninteresting answer still means the window is no longer pending.
	if route.get("release", false):
		_release_run()

	if route.get("silent", false):
		return

	var payload: Dictionary = result if result is Dictionary else {}

	# `when` NAMES A KEY THAT HAS TO BE TRUE for the answer to be worth drawing.
	# The hand-off poll is the case it exists for: most answers are "nothing",
	# and redrawing the library for each of them would scroll a learner back to
	# the top ten times a minute.
	if route.has("when") and payload.get(route["when"], false) != true:
		return

	# THE SAME HAND-OFF IS NOT NEWS TWICE. Rendered again so the banner stays
	# accurate, but the learner is not taken back to it.
	var once := str(route.get("once", ""))
	var marker := str(payload.get(once, "")) if once != "" else ""
	# AN ABSENT MARKER IS NOT A REPEAT. A helper too old to send one, or a
	# payload that simply has no id, must still be shown -- the first version of
	# this compared "" to "" and swallowed every hand-off.
	var already := marker != "" and marker == _offered_session
	if marker != "":
		_offered_session = marker

	_render(route["into"], payload)

	# A route that names a destination moves there ON SUCCESS only. A hand-off
	# that arrived should be looked at; a poll that found nothing should not
	# take somebody off the page they were reading.
	if route.has("then") and not already:
		_dock.show_view(route["then"])


func _on_failed(id: int, code: String) -> void:
	var route: Dictionary = _pending.get(id, {})
	if route.is_empty():
		return
	_pending.erase(id)
	if route.get("silent", false):
		return
	# A ROUTE WITH `when` IS ONE NOBODY PRESSED FOR, so its failures are not
	# shown either. A learner whose network is down should meet that on the
	# thing they pressed, not on a poll running behind them ten times a minute.
	if route.has("when"):
		return
	_render_error(route["into"], explain(code))


## What to show a learner for a wire error code. See EXPLANATIONS.
static func explain(code: String) -> String:
	return "%s (%s)" % [EXPLANATIONS.get(code, UNEXPLAINED), code]


func _render(view_name: String, payload: Dictionary) -> void:
	var view = _dock.view(view_name)
	if view == null:
		return
	view.render(payload)


func _render_error(view_name: String, message: String) -> void:
	var view = _dock.view(view_name)
	if view == null:
		return
	# THE EXISTING PAYLOAD IS KEPT AND THE ERROR ADDED TO IT. Rendering an error
	# alone would blank the view -- a failed re-check would wipe the step the
	# learner is reading, which is a worse outcome than the failure itself.
	# `var payload =`, NOT `:=`. The view is held as an untyped Control here, so
	# GDScript cannot infer a return type from it and the walrus is a PARSE
	# ERROR -- which takes down every script that preloads this one, and reads
	# in the test output as "Nonexistent function 'new' in base 'GDScript'".
	var payload = view.payload()
	payload["error"] = message
	payload["status"] = "failed"
	view.render(payload)
