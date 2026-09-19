@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan items 28 and 39. Sign in by pairing this editor to a phone.
##
## THE PANEL SHOWS THE CODE AND THE PHONE TAKES IT. That direction is the whole
## flow and this view had it backwards until the sidecar side was built: it used
## to offer a field for a code read off the phone, which nothing on either side
## has ever produced. `PairingClient.StartPairingAsync` returns a `UserCode` for
## the editor to DISPLAY and a `DeviceCode` to poll with, and the phone's own
## pairing screen says "Generate a new one in the Editor plugin."
##
## It is worth saying how that survived. The view was tested against fixture
## payloads and every assertion passed, because a view tested in isolation is
## tested against the flow its author imagined. Nothing but the other half of
## the conversation could have caught it.
##
## NO QR, AND THE COPY SAYS SO. Core hands back a `QrPng` and the phone HAS a
## scanner, so showing it would remove the typing altogether -- but plan item 39
## decided against it to match the Unreal plugin, and somebody who expects a
## scanner and does not find one goes looking for it. The absence has to be
## stated rather than merely being true.
##
## IT SHOWS A STATE RATHER THAN A SEQUENCE. `status` says whether this is a
## fresh page, a code being fetched, a code waiting to be typed, or a refusal.
## The shell owns the transitions, because the shell is what knows whether the
## sidecar answered.

const PairingCode := preload("res://addons/joystickacademy/ui/components/pairing_code.gd")
const Header := preload("res://addons/joystickacademy/ui/components/header.gd")

## The methods the shell turns into sidecar requests.
const COMMAND_BEGIN := "auth.begin"
const COMMAND_CANCEL := "auth.cancel"
## Handled by the editor rather than the sidecar -- see local_commands.gd.
const COMMAND_COPY := "auth.copy_code"

## Status values the payload may carry.
const STATUS_IDLE := "idle"
const STATUS_WORKING := "working"
const STATUS_AWAITING := "awaiting"
const STATUS_FAILED := "failed"

const IDLE_COPY := "Pairing this editor with your JoyStick Academy account " \
	+ "takes about fifteen seconds. Press Sign in and a code appears here."
const WORKING_COPY := "Asking for a code…"
const AWAITING_COPY := "On your phone, open JoyStick Academy, go to Account, " \
	+ "and choose Pair a plugin. Type this code in -- there is no scanner on " \
	+ "this side. The page changes by itself when it lands."
const FAILED_COPY := "That did not work. Try again and a fresh code appears."

var _header: Control = null
var _instruction: Label = null
var _code: Control = null
var _begin: Button = null
var _cancel: Button = null
## The code whose countdown is already running.
##
## SO A REDRAW DOES NOT RESTART IT. `expiresInSeconds` is fixed at issue and the
## shell replays the last payload to render an error without blanking the page,
## so re-reading it puts the original duration back on a code that has been
## decaying for minutes.
var _counting_for := ""


func _init() -> void:
	name = "SignInView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)
	_header.set_title("Sign in")

	_instruction = Label.new()
	_instruction.name = "Instruction"
	_instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_instruction.text = IDLE_COPY
	add_child(_instruction)

	_code = PairingCode.new()
	_code.visible = false
	add_child(_code)

	var row := HBoxContainer.new()
	row.name = "Actions"
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_cancel = Button.new()
	_cancel.name = "Cancel"
	_cancel.text = "Cancel"
	_cancel.visible = false
	row.add_child(_cancel)

	_begin = Button.new()
	_begin.name = "Begin"
	_begin.text = "Sign in"
	row.add_child(_begin)

	_begin.pressed.connect(func(): send(COMMAND_BEGIN))
	_cancel.pressed.connect(func(): send(COMMAND_CANCEL))
	_code.copy_requested.connect(func(code): send(COMMAND_COPY, {"text": code}))
	# AN EXPIRED CODE ASKS FOR A NEW ONE RATHER THAN SITTING THERE. A learner who
	# walked away and came back to a dead code has done nothing wrong, and making
	# them notice the small print before pressing a button is a worse page than
	# one that has already fetched the next code.
	_code.expired.connect(func(): send(COMMAND_BEGIN))

	_render({})


## The code as shown, grouped.
func code() -> String:
	return _code.value()


func status() -> String:
	return text_at(_payload, "status", STATUS_IDLE)


func is_waiting() -> bool:
	return status() in [STATUS_WORKING, STATUS_AWAITING]


## A HIDDEN PAGE'S CLOCK KEEPS RUNNING, and this pair is what stops it.
##
## `ViewRouter._hide` calls `set_process(false)`, and its own header says hidden
## views stop processing. That is not true of the one view here with a Timer:
## `set_process` is not recursive and does not touch a Timer's internal
## processing either way. So the countdown on a page nobody was looking at
## reached zero, asked for a fresh code, and reset itself -- forever. Measured
## against production, a code lasts 299 seconds, so a signed-in editor left open
## would mint about twelve unused pairing codes an hour and poll the pairing
## endpoint every two seconds for each.
func on_hidden() -> void:
	_code.pause_countdown()


func on_shown() -> void:
	_code.resume_countdown()


func _render(payload: Dictionary) -> void:
	var state := text_at(payload, "status", STATUS_IDLE)

	var code := text_at(payload, "code")
	var same_code := code != "" and code == _counting_for

	_code.set_value(code)
	_code.set_error(text_at(payload, "error"))

	# NOT AGAIN FOR A CODE ALREADY BEING COUNTED. `expiresInSeconds` is fixed
	# when the code is issued and never resent as it decays, and the shell
	# deliberately REPLAYS the last payload when it renders an error so the page
	# is not blanked -- so a dropped request two minutes in put "5:00" back on
	# screen for a code that dies in three. Every later render of the same code
	# would do it again.
	#
	# ZERO STILL STOPS THE COUNTDOWN, which is what an absent field should do: a
	# helper too old to send the expiry must not leave a clock ticking towards
	# an expiry it never described.
	if not same_code:
		_counting_for = code
		_code.set_expires_in(number_at(payload, "expiresInSeconds", 0))
	_code.visible = _code.has_code() or _code.error() != ""

	match state:
		STATUS_WORKING:
			_instruction.text = WORKING_COPY
		STATUS_AWAITING:
			_instruction.text = AWAITING_COPY
		STATUS_FAILED:
			_instruction.text = FAILED_COPY
		_:
			_instruction.text = IDLE_COPY

	# CANCEL ONLY EXISTS WHILE THERE IS SOMETHING TO CANCEL. A permanent Cancel
	# on a page with nothing in flight invites somebody to press it and wonder
	# what they undid.
	_cancel.visible = state in [STATUS_WORKING, STATUS_AWAITING]

	# THE BUTTON SAYS WHICH PRESS THIS IS. "Sign in" on a page already showing a
	# code reads as "I have not started yet", and somebody presses it and
	# invalidates the code they were halfway through typing.
	_begin.text = "Get a new code" if _code.has_code() or state == STATUS_FAILED \
		else "Sign in"
	_begin.disabled = state == STATUS_WORKING
