@tool
extends VBoxContainer

## The pairing code this panel SHOWS, for the learner to type into their phone.
##
## THE DIRECTION IS THE WHOLE POINT AND IT WAS BACKWARDS HERE FOR A WHILE. This
## component started as a text FIELD, on the reading that the phone shows a code
## and the panel takes it. It is the other way round, in Core and on the phone
## both: `PairingClient.StartPairingAsync` returns a `UserCode` for the editor
## to display and a `DeviceCode` to poll with, and the phone's own screen says
## "Generate a new one in the Editor plugin." Nothing typed into an editor panel
## was ever going to sign anybody in.
##
## It was found by building the sidecar side, not by testing this: a view tested
## against a fixture payload renders a beautiful form for a flow that does not
## exist, and every assertion passes.
##
## IT IS SHOWN EXACTLY AS ISSUED, AND THE FIRST VERSION GROUPED IT. That is the
## second thing about this component that was built on an assumption and
## measured false, and it would have shipped as a sign-in that never works.
##
## The grouping came from the flow that never existed: when the panel TOOK a
## typed code it could strip its own dashes before sending, so 2-4-4 was free
## readability. Displaying one is the opposite situation -- whatever is on this
## screen is what somebody types into their phone.
##
## MEASURED against production on 2026-09-18: a real code is EIGHT characters
## (`XDR9AGEE`), not ten, and `joystick_api/app/auth/pairing.py` matches it with
## `user_code.strip().upper()` and nothing else. No dash removal, no space
## removal beyond the ends. The phone sends what was typed, verbatim. So
## `XD-R9AG-EE` on this screen is a code the server has never heard of, and the
## learner is told their code is invalid for doing exactly as they were shown.
##
## A separator is not a formatting choice here; it is a character somebody has
## to type. The alphabet already excludes I, O, 0 and 1 for the same reason --
## transcription -- so readability is bought with letter SPACING, which is a
## theme property and not part of the string.
##
## THERE IS NO QR HERE. Core hands back a `QrPng` and the phone HAS a scanner,
## so showing it would remove the typing altogether -- but plan item 39 decided
## against it to match what the Unreal plugin ships, and a panel that shows a
## code while the phone expects to scan one is worse than either. Recorded
## rather than quietly improved, because it is a cheap change if the decision
## is revisited.

## The learner wants this code on their clipboard. The panel cannot reach one --
## see local_commands.gd -- so it is reported like everything else.
signal copy_requested(code: String)

## The countdown reached zero. The code the server issued is no longer good for
## anything, which the shell turns into a fresh one.
signal expired()

## The longest code this will show. The server's own schema accepts 4 to 16, so
## this is a guard against a nonsense payload rather than a format.
const MAX_CODE_LENGTH := 16

## What is shown before a code has been asked for.
const NO_CODE := "— — — —"

var _code: Label = null
var _expiry: Label = null
var _error: Label = null
var _copy: Button = null
var _timer: Timer = null

var _value := ""
var _seconds_left := 0
## Whether the page holding this is off screen.
##
## THE VIEW KNOWS AND THIS DOES NOT. A Control that is merely in the tree may be
## behind another page, and headlessly a mounted one reports not visible at all,
## so the answer has to be told rather than inferred.
var _paused := false


func _init() -> void:
	name = "PairingCode"
	add_theme_constant_override("separation", 4)

	_code = Label.new()
	_code.name = "Code"
	_code.text = NO_CODE
	_code.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# BIG, because it is read off one screen and typed into another. The default
	# editor font size is chosen for dense tool panels and is the wrong size for
	# the one thing here somebody has to transcribe.
	_code.add_theme_font_size_override("font_size", 24)
	# AND SPACED, which is how this buys back the readability the dashes used to
	# provide -- without putting a character on screen that somebody would type.
	_code.add_theme_constant_override("extra_spacing_glyph", 4)
	add_child(_code)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_copy = Button.new()
	_copy.name = "Copy"
	_copy.text = "Copy"
	_copy.flat = true
	_copy.visible = false
	row.add_child(_copy)

	_expiry = Label.new()
	_expiry.name = "Expiry"
	_expiry.visible = false
	row.add_child(_expiry)

	_error = Label.new()
	_error.name = "Error"
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# HIDDEN WHEN EMPTY, not blank-but-present: an empty Label still takes its
	# line, so the block would jump the first time it complained.
	_error.visible = false
	add_child(_error)

	_timer = Timer.new()
	_timer.name = "Tick"
	_timer.wait_time = 1.0
	# A COUNTDOWN THAT ONLY MOVES WHEN SOMETHING ELSE REDRAWS IS A STOPPED
	# CLOCK. The shell re-renders this view when an answer arrives and not
	# otherwise, and "expires in 9:58" sitting at 9:58 for ten minutes is worse
	# than no countdown at all.
	_timer.autostart = false
	add_child(_timer)
	_timer.timeout.connect(_on_tick)

	_copy.pressed.connect(func(): copy_requested.emit(_value))


## The code as shown, which is the code as issued.
func value() -> String:
	return _code.text if _value != "" else ""


## The same string. Kept as its own name because the caller asking for "the
## thing to put on a clipboard" should not have to know that it is the same as
## the thing on screen -- it was not, once.
func raw_value() -> String:
	return _value


func has_code() -> bool:
	return _value != ""


func seconds_left() -> int:
	return _seconds_left


func error() -> String:
	return _error.text


func set_error(message: String) -> void:
	_error.text = message
	_error.visible = message != ""


## Show a code, or "" to clear one.
func set_value(text: String) -> void:
	_value = _strip(text)
	if _value == "":
		_code.text = NO_CODE
		_copy.visible = false
		set_expires_in(0)
		return
	_code.text = _value
	_copy.visible = true


## Start the countdown. Zero or less stops it and says the code is done.
func set_expires_in(seconds: int) -> void:
	_seconds_left = maxi(seconds, 0)
	if _seconds_left <= 0:
		_timer.stop()
		_expiry.visible = false
		return
	_expiry.visible = true
	_expiry.text = expiry_text(_seconds_left)
	# NOT WHILE PAUSED, and that is the whole point of `pause_countdown`. A
	# render into a page nobody is looking at -- an error replayed into the
	# sign-in view, a `pairing.changed` arriving while they read the Library --
	# re-armed the clock that being hidden had just stopped, and a countdown
	# reaching zero off-screen asks the server for a fresh code for somebody who
	# is not there. That is the every-five-minutes code mill this component was
	# fixed for once already, reached from another direction.
	#
	# ASKED OF THE PAUSE FLAG RATHER THAN OF `is_visible_in_tree`, because the
	# view is what knows: headlessly a mounted Control reports not visible, so
	# a visibility test would stop the clock in every test and prove nothing.
	if is_inside_tree() and not _paused:
		_timer.start()


## Stop counting without forgetting how long was left.
##
## FOR A PAGE THAT IS NO LONGER ON SCREEN. A Godot Timer keeps running when its
## node is hidden -- visibility is a draw property, not a lifecycle one -- so a
## countdown left alone reaches zero for a learner who is not there and fires
## whatever hangs off it.
func pause_countdown() -> void:
	_paused = true
	_timer.stop()


## Count again, if there is still something to count.
func resume_countdown() -> void:
	_paused = false
	if _seconds_left > 0 and is_inside_tree():
		_timer.start()


## How long is left, in words.
##
## MINUTES AND SECONDS, not "600 seconds". The number a learner cares about is
## whether they have time to walk to their phone, and a two-digit minute figure
## answers that at a glance where a three-digit second figure does not.
static func expiry_text(seconds: int) -> String:
	if seconds <= 0:
		return "This code has expired."
	if seconds < 60:
		return "Expires in %ds" % seconds
	return "Expires in %d:%02d" % [seconds / 60, seconds % 60]


## Upper-case, letters and digits only, and no longer than the server issues.
##
## DEFENSIVE RATHER THAN DECORATIVE. The server sends a clean code; this drops
## anything else so that a payload from a future version cannot put a character
## on screen that the claim endpoint would then refuse.
static func clean_code(raw: String) -> String:
	return _strip(raw)


static func _strip(raw: String) -> String:
	if raw == "":
		return ""
	var clean := ""
	for character in raw.to_upper():
		if clean.length() >= MAX_CODE_LENGTH:
			break
		if _is_alphanumeric(character):
			clean += character
	return clean


static func _is_alphanumeric(character: String) -> bool:
	# `is_valid_identifier` and friends answer about whole strings, and there is
	# no per-character predicate in GDScript, so this is spelled out.
	return (character >= "A" and character <= "Z") \
		or (character >= "a" and character <= "z") \
		or (character >= "0" and character <= "9")


func _on_tick() -> void:
	if _seconds_left <= 0:
		return
	_seconds_left -= 1
	if _seconds_left > 0:
		_expiry.text = expiry_text(_seconds_left)
		return
	_timer.stop()
	_expiry.text = expiry_text(0)
	_expiry.visible = true
	expired.emit()
