@tool
extends VBoxContainer

## The panel's title, and a line under it when there is one to say.
##
## THE SUBTITLE HIDES WHEN EMPTY rather than rendering a blank Label. An empty
## Label still takes its line height, so a header with nothing to add sits
## taller than one with something -- and every view in the panel would be
## vertically offset from every other by whether its subtitle happened to be
## set.

var _title: Label = null
var _subtitle: Label = null


func _init() -> void:
	name = "Header"
	add_theme_constant_override("separation", 2)

	_title = Label.new()
	_title.name = "Title"
	add_child(_title)

	_subtitle = Label.new()
	_subtitle.name = "Subtitle"
	_subtitle.visible = false
	add_child(_subtitle)


func title() -> String:
	return _title.text


func subtitle() -> String:
	return _subtitle.text


func set_title(value: String) -> void:
	_title.text = value


func set_subtitle(value: String) -> void:
	_subtitle.text = value
	_subtitle.visible = value != ""
