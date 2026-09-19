@tool
extends VBoxContainer

## The four places the panel can be, down the left-hand side.
##
## FOUR, FIXED, AND NAMED HERE. They are the product's shape rather than a
## configuration, and a sidebar that took its tabs as an argument would let a
## view add a fifth nobody designed a home for.
##
## A DISABLED TAB IS STILL VISIBLE, and that is the difference between this and
## hiding it. A learner who is signed out should see that Submit exists and is
## not available yet; a Submit that vanishes reads as a feature the plugin does
## not have. Pressing a disabled tab reports nothing, so the caller cannot be
## surprised by a selection it refused to allow.
##
## SELECTING THE TAB ALREADY SELECTED REPORTS NOTHING. The view above rebuilds
## on selection, and a second report would throw away whatever the learner had
## typed into it.

signal tab_selected(tab: int)

enum Tab { LIBRARY, PRACTICE, SUBMIT, ACCOUNT }

## In display order, which is also the order a learner meets them.
const ORDER := [Tab.LIBRARY, Tab.PRACTICE, Tab.SUBMIT, Tab.ACCOUNT]

const LABELS := {
	Tab.LIBRARY: "Library",
	Tab.PRACTICE: "Practice",
	Tab.SUBMIT: "Submit",
	Tab.ACCOUNT: "Account",
}

var _buttons := {}
var _enabled := {}
var _active := -1


func _init() -> void:
	name = "Sidebar"
	add_theme_constant_override("separation", 2)

	for tab in ORDER:
		var button := Button.new()
		button.name = str(LABELS[tab])
		button.text = str(LABELS[tab])
		button.toggle_mode = true
		button.pressed.connect(_on_pressed.bind(tab))
		add_child(button)
		_buttons[tab] = button
		_enabled[tab] = true

	_refresh()


## Which tab is showing, or -1 before anything has been selected.
func active_tab() -> int:
	return _active


func is_tab_enabled(tab: int) -> bool:
	return bool(_enabled.get(tab, false))


func button_for(tab: int) -> Button:
	return _buttons.get(tab, null)


## Select a tab as though it had been pressed. Refused when disabled.
func select(tab: int) -> void:
	_on_pressed(tab)


## Turn a tab on or off.
##
## DISABLING THE ACTIVE TAB DOES NOT CLEAR THE SELECTION. The learner is looking
## at that view; taking the highlight off it while it is still on screen would
## leave the sidebar showing nothing selected and the panel showing something.
## The caller navigates away first if it wants that.
func set_tab_enabled(tab: int, enabled: bool) -> void:
	if not _buttons.has(tab):
		return
	_enabled[tab] = enabled
	_refresh()


func _on_pressed(tab: int) -> void:
	if not is_tab_enabled(tab):
		_refresh()
		return
	if tab == _active:
		_refresh()
		return
	_active = tab
	_refresh()
	tab_selected.emit(tab)


func _refresh() -> void:
	for tab in ORDER:
		var button: Button = _buttons[tab]
		button.disabled = not is_tab_enabled(tab)
		button.button_pressed = tab == _active
