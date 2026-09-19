@tool
extends VBoxContainer

## The addon's dock.
##
## Four parts, and the split is the point. A title, a SIDEBAR, a ROUTED BODY,
## and a status strip.
##
## THE SIDEBAR HAS FOUR TABS AND THE ROUTER HOLDS TEN VIEWS, which is not a
## mismatch. A tab is a PLACE a learner returns to; the other six views are
## reached from inside one -- the player from the library, the hints from the
## player, the glossary from wherever a term was tapped. Ten tabs would be a
## strip nobody could navigate.
##
## NOTHING HERE SENDS ANYTHING. Views report commands, the dock collects them,
## and the shell drains them: what to do about a command depends on whether the
## sidecar is connected, whether the learner is signed in and what the protocol
## supports, none of which the dock knows. It also means one place to look when
## a button appears to do nothing.
##
## The status strip is deliberately OUTSIDE the router. It reports the sidecar,
## which is a fact about the whole dock rather than about whichever view is
## showing -- and it is most needed exactly when no view can work.
##
## WHY THE STATUS IS VISIBLE AT ALL, rather than hidden until something breaks.
## The sidecar is a process the learner never installed and does not know
## exists. When it is not working, "nothing happens" is the worst possible
## symptom: there is nothing to search for and nothing to tell support. One line
## saying what state it is in costs almost no space and turns an invisible
## failure into a reportable one.

const _PAD := 8

const ViewRouter := preload("res://addons/joystickacademy/ui/view_router.gd")
const Sidebar := preload("res://addons/joystickacademy/ui/components/sidebar.gd")

const SignInView := preload("res://addons/joystickacademy/ui/views/sign_in_view.gd")
const LibraryView := preload("res://addons/joystickacademy/ui/views/library_view.gd")
const WalkthroughPlayerView := preload("res://addons/joystickacademy/ui/views/walkthrough_player_view.gd")
const CapstoneStudioView := preload("res://addons/joystickacademy/ui/views/capstone_studio_view.gd")
const SubmissionView := preload("res://addons/joystickacademy/ui/views/submission_view.gd")
const AccountView := preload("res://addons/joystickacademy/ui/views/account_view.gd")
const StandingView := preload("res://addons/joystickacademy/ui/views/standing_view.gd")
const GlossaryView := preload("res://addons/joystickacademy/ui/views/glossary_view.gd")
const HintsView := preload("res://addons/joystickacademy/ui/views/hints_view.gd")
const DiagnosticsView := preload("res://addons/joystickacademy/ui/views/diagnostics_view.gd")

## The ten views. The names are the router's keys and the only thing a caller
## needs to know.
const VIEW_SIGN_IN := "sign_in"
const VIEW_LIBRARY := "library"
const VIEW_PLAYER := "player"
const VIEW_CAPSTONE := "capstone"
const VIEW_SUBMISSION := "submission"
const VIEW_ACCOUNT := "account"
const VIEW_STANDING := "standing"
const VIEW_GLOSSARY := "glossary"
const VIEW_HINTS := "hints"
const VIEW_DIAGNOSTICS := "diagnostics"

## Which view each sidebar tab opens on.
##
## THE SIDEBAR IS FOUR TABS AND THERE ARE TEN VIEWS, which is not a mismatch. A
## tab is a PLACE; the other six views are reached from inside one -- the player
## from the library, the hints from the player, the glossary from anywhere a
## term is tapped. Giving each view a tab would be ten tabs nobody could
## navigate, and the four are the ones a learner returns to.
const TAB_VIEWS := {
	Sidebar.Tab.LIBRARY: VIEW_LIBRARY,
	Sidebar.Tab.PRACTICE: VIEW_PLAYER,
	Sidebar.Tab.SUBMIT: VIEW_CAPSTONE,
	Sidebar.Tab.ACCOUNT: VIEW_ACCOUNT,
}

var _title: Label
var _status: RichTextLabel
var _body: VBoxContainer
var _sidebar: Control
var _router: ViewRouter
var _last_event := ""
## Every (view, method, args) the dock has been asked for. The shell drains it;
## nothing here sends anything, because what to do about a command depends on
## whether the sidecar is even up.
var _commands: Array = []
## Whether a tab selection is reported. False while the dock is being built.
var _report_tabs := false


func _init() -> void:
	custom_minimum_size = Vector2(240, 160)
	add_theme_constant_override("separation", _PAD)

	_title = Label.new()
	_title.text = "JoyStick Academy"
	_title.add_theme_font_size_override("font_size", 16)
	add_child(_title)

	var middle := HBoxContainer.new()
	middle.name = "Middle"
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", _PAD)
	add_child(middle)

	_sidebar = Sidebar.new()
	middle.add_child(_sidebar)

	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_child(_body)

	_router = ViewRouter.new()
	_add_view(VIEW_SIGN_IN, SignInView.new())
	_add_view(VIEW_LIBRARY, LibraryView.new())
	_add_view(VIEW_PLAYER, WalkthroughPlayerView.new())
	_add_view(VIEW_CAPSTONE, CapstoneStudioView.new())
	_add_view(VIEW_SUBMISSION, SubmissionView.new())
	_add_view(VIEW_ACCOUNT, AccountView.new())
	_add_view(VIEW_STANDING, StandingView.new())
	_add_view(VIEW_GLOSSARY, GlossaryView.new())
	_add_view(VIEW_HINTS, HintsView.new())
	_add_view(VIEW_DIAGNOSTICS, DiagnosticsView.new())

	_sidebar.tab_selected.connect(_on_tab)
	# THE SIDEBAR IS TOLD, NOT ASKED. Selecting the tab makes it report, which
	# routes -- so the opening view and the lit tab cannot start out disagreeing.
	_sidebar.select(Sidebar.Tab.LIBRARY)
	# AND THIS ONE IS NOT REPORTED. A dock being built is not a learner opening a
	# tab, and there is no sidecar to ask yet -- the shell fetches for the
	# opening view when a helper actually connects, which is the moment the
	# answer could arrive. Reporting here would queue a request nothing could
	# send and leave every test's first pump carrying one.
	_report_tabs = true

	_status = RichTextLabel.new()
	_status.bbcode_enabled = true
	_status.fit_content = true
	_status.custom_minimum_size = Vector2(0, 48)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Selectable so a learner can copy the reason into a bug report. An error
	# nobody can quote is an error nobody can help with.
	_status.selection_enabled = true
	add_child(_status)

	show_connecting()


func show_connecting() -> void:
	_set_status("Starting…", "Connecting to the JoyStick Academy helper.")


func show_connected(host_version: String, core_version: String) -> void:
	_set_status("Connected", "Helper %s, core %s." % [host_version, core_version])


func show_reconnecting(attempt: int, of: int, wait_seconds: float, reason: String) -> void:
	# The attempt count is shown deliberately. "Reconnecting…" forever is
	# indistinguishable from a hang; "attempt 2 of 3" tells the learner this
	# will end, and roughly when.
	_set_status("Reconnecting (%d of %d)" % [attempt, of],
		"The helper stopped. Trying again in %ds.\n%s" % [int(wait_seconds), reason])


func show_unavailable(reason: String) -> void:
	_set_status("Not available", reason)


func on_event(event_name: String, _data: Dictionary) -> void:
	_last_event = event_name


func on_request_failed(_id: int, _code: String) -> void:
	# Individual failures belong to the view that made the request; the dock
	# only reports the connection. Swallowing them here would be wrong, so the
	# hook exists and does nothing until item 48's Diagnostics view owns it.
	pass


func last_event() -> String:
	return _last_event


## Switch the body to a named view.
##
## Returns "" or a reason. A caller asking for a view that does not exist is a
## bug in the caller, and it must not be silent: the dock would simply keep
## showing the previous view and the learner would press a button that appears
## to do nothing.
func show_view(view_name: String) -> String:
	var problem := _router.show_view(view_name)
	if problem != "":
		push_error("[JoyStick Academy] " + problem)
	return problem


## Everything the views have asked for, oldest first, and CLEARED BY READING.
##
## THE DOCK COLLECTS AND DOES NOT SEND. What to do about a command depends on
## whether the sidecar is connected, whether the learner is signed in, and what
## the protocol version supports -- three things the dock does not know and the
## shell does. Collecting them here rather than wiring each view to the client
## also means one place to look when a button appears to do nothing.
func take_commands() -> Array:
	var out := _commands
	_commands = []
	return out


## A view by name, for the shell to render into.
func view(view_name: String) -> Control:
	return _router.get_view(view_name)


## The sidebar, for tests and for a shell that disables tabs while signed out.
func sidebar() -> Control:
	return _sidebar


## The router, for the views that register themselves into it and for tests.
func router() -> ViewRouter:
	return _router


## Which view is showing. For tests and for the Diagnostics view.
func current_view() -> String:
	return _router.current() if _router != null else ""


## The status text, without markup. For tests and for the Diagnostics view.
func status_text() -> String:
	return _status.get_parsed_text() if _status != null else ""


## Register a view and put it in the body.
##
## A refusal is pushed as an error rather than swallowed: the router only
## refuses things that are bugs -- a duplicate name, a misspelled lifecycle
## hook -- and a dock that quietly loses a view shows a learner an empty panel
## with nothing to search for.
func _add_view(view_name: String, view: Control) -> void:
	var problem := _router.register(view_name, view)
	if problem != "":
		push_error("[JoyStick Academy] " + problem)
		return
	_body.add_child(view)
	if view.has_signal("command"):
		# The view's NAME travels with the command. Two views can ask for the
		# same method -- the library and the account page both offer a sign-in
		# -- and the shell needs to know which one to render the answer into.
		view.command.connect(_on_command.bind(view_name))


func _on_command(method: String, args: Dictionary, view_name: String) -> void:
	_commands.append({"view": view_name, "method": method, "args": args})


## A tab was chosen. Show its view, and REPORT IT.
##
## THE REPORT IS WHAT MAKES A TAB FETCH ANYTHING. Without it, opening the
## Submit tab shows whatever the capstone page was last rendered with -- which
## on a fresh session is nothing at all, and an empty page with no error on it
## is the exact failure this design is arranged against. Every other way into a
## view goes through a button, and a button reports; a tab was the one that did
## not.
const COMMAND_VIEW_OPENED := "view.opened"


func _on_tab(tab: int) -> void:
	var view_name: String = TAB_VIEWS.get(tab, "")
	if view_name == "":
		return
	show_view(view_name)
	if not _report_tabs:
		return
	_commands.append({
		"view": view_name,
		"method": COMMAND_VIEW_OPENED,
		"args": {"view": view_name},
	})


func _set_status(headline: String, detail: String) -> void:
	if _status == null:
		return
	_status.clear()
	_status.append_text("[b]%s[/b]\n%s" % [headline, detail])
