@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 33. Who is signed in, and how to stop being.
##
## SIGNED OUT IS NOT AN ERROR STATE. Most learners open the panel for the first
## time signed out, and a page that greets them with a warning colour and the
## word "not" has told them they did something wrong on their first visit. It is
## an invitation with a button.
##
## SIGN OUT ASKS FIRST, AND SAYS WHAT IS LOST. Signing out of a plugin that
## holds a session is easy to press by accident and annoying to undo -- the code
## is on a phone that may be in another room. The confirmation names the cost:
## the pairing code has to be read again.
##
## THE VERSION IS HERE BECAUSE OF WHAT SUPPORT COSTS WITHOUT IT. The first
## question about any plugin problem is which version, and a learner who has to
## go and find out often does not come back.

const Header := preload("res://addons/joystickacademy/ui/components/header.gd")
const Footer := preload("res://addons/joystickacademy/ui/components/footer.gd")

const COMMAND_SIGN_IN := "account.sign_in"
const COMMAND_SIGN_OUT := "account.sign_out"
const COMMAND_SUPPORT := "account.support"
const COMMAND_OPEN_DIAGNOSTICS := "account.diagnostics"

const SIGNED_OUT_COPY := "Sign in to carry your progress between here and your " \
	+ "phone. The pairing code is under Account in the app."
const CONFIRM_COPY := "Sign out? You will need the pairing code from your phone " \
	+ "to sign back in."

var _header: Control = null
var _signed_out: Label = null
var _details: VBoxContainer = null
var _name: Label = null
var _email: Label = null
var _sign_in: Button = null
var _sign_out: Button = null
var _confirm: Label = null
var _confirm_yes: Button = null
var _confirm_no: Button = null
var _diagnostics: Button = null
var _footer: Control = null

var _confirming := false


func _init() -> void:
	name = "AccountView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)
	_header.set_title("Account")

	_signed_out = Label.new()
	_signed_out.name = "SignedOut"
	_signed_out.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_signed_out.text = SIGNED_OUT_COPY
	add_child(_signed_out)

	_details = VBoxContainer.new()
	_details.name = "Details"
	_details.visible = false
	add_child(_details)

	_name = Label.new()
	_name.name = "Name"
	_details.add_child(_name)

	_email = Label.new()
	_email.name = "Email"
	_details.add_child(_email)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)
	add_child(actions)

	_sign_in = Button.new()
	_sign_in.name = "SignIn"
	_sign_in.text = "Sign in"
	actions.add_child(_sign_in)

	_sign_out = Button.new()
	_sign_out.name = "SignOut"
	_sign_out.text = "Sign out"
	_sign_out.visible = false
	actions.add_child(_sign_out)

	_diagnostics = Button.new()
	_diagnostics.name = "Diagnostics"
	_diagnostics.text = "Diagnostics"
	_diagnostics.flat = true
	actions.add_child(_diagnostics)

	_confirm = Label.new()
	_confirm.name = "Confirm"
	_confirm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm.text = CONFIRM_COPY
	_confirm.visible = false
	add_child(_confirm)

	var confirm_row := HBoxContainer.new()
	confirm_row.name = "ConfirmActions"
	confirm_row.add_theme_constant_override("separation", 6)
	confirm_row.visible = false
	add_child(confirm_row)

	_confirm_no = Button.new()
	_confirm_no.name = "Keep"
	_confirm_no.text = "Stay signed in"
	confirm_row.add_child(_confirm_no)

	_confirm_yes = Button.new()
	_confirm_yes.name = "Confirm"
	_confirm_yes.text = "Sign out"
	confirm_row.add_child(_confirm_yes)

	_footer = Footer.new()
	add_child(_footer)

	_sign_in.pressed.connect(func(): send(COMMAND_SIGN_IN))
	_sign_out.pressed.connect(_begin_confirm)
	_confirm_no.pressed.connect(_cancel_confirm)
	_confirm_yes.pressed.connect(_do_sign_out)
	_diagnostics.pressed.connect(func(): send(COMMAND_OPEN_DIAGNOSTICS))
	_footer.support_requested.connect(func(): send(COMMAND_SUPPORT))

	_refresh()


func is_signed_in() -> bool:
	return flag_at(_payload, "signedIn")


func is_confirming() -> bool:
	return _confirming


func display_name() -> String:
	return _name.text


func _render(payload: Dictionary) -> void:
	_footer.set_version(text_at(payload, "version"))
	if not is_signed_in():
		# A session that went away takes a half-finished confirmation with it,
		# rather than leaving a "Sign out?" over a signed-out page.
		_confirming = false
	_name.text = text_at(payload, "displayName")
	_email.text = text_at(payload, "email")
	# An account with no display name shows the email alone rather than an empty
	# line above it.
	_name.visible = _name.text != ""
	_email.visible = _email.text != ""
	_refresh()


func _begin_confirm() -> void:
	_confirming = true
	_refresh()


func _cancel_confirm() -> void:
	_confirming = false
	_refresh()


func _do_sign_out() -> void:
	_confirming = false
	_refresh()
	send(COMMAND_SIGN_OUT)


func _refresh() -> void:
	var signed_in := is_signed_in()
	_signed_out.visible = not signed_in
	_details.visible = signed_in
	_sign_in.visible = not signed_in
	_sign_out.visible = signed_in and not _confirming

	_confirm.visible = _confirming
	get_node("ConfirmActions").visible = _confirming
