@tool
extends VBoxContainer

## Pick one file. The picker itself is somebody else's job.
##
## IT DOES NOT OPEN A DIALOG, AND THAT IS THE WHOLE DESIGN DECISION. Opening one
## means reaching `EditorInterface`, which exists only inside a running editor --
## so a component that opened its own dialog could not be tested at all, and the
## thing worth testing here is everything around the dialog: what a chosen path
## does to the label, what happens when somebody clears it, and whether a path
## the learner cannot see is reported as chosen.
##
## SO IT ASKS. `browse_requested` carries the filters and the title; the view
## opens the dialog it already owns and calls `set_path` with the answer. One
## dialog per panel rather than one per picker is also what the editor expects.
##
## THE PATH IS SHOWN SHORT AND REPORTED WHOLE. An absolute path is longer than
## the panel is wide and its useful end is the last segment, so the label shows
## the file name; every signal carries the path as given.

signal browse_requested(filters: PackedStringArray, title: String)
signal path_changed(path: String)

const EMPTY_COPY := "No file chosen"

var _label: Label = null
var _value: Label = null
var _browse: Button = null
var _clear: Button = null

var _path := ""
var _filters := PackedStringArray()
var _title := "Choose a file"


func _init() -> void:
	name = "FilePicker"
	add_theme_constant_override("separation", 4)

	_label = Label.new()
	_label.name = "Label"
	_label.visible = false
	add_child(_label)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_value = Label.new()
	_value.name = "Value"
	_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_value.text = EMPTY_COPY
	row.add_child(_value)

	_browse = Button.new()
	_browse.name = "Browse"
	_browse.text = "Browse…"
	row.add_child(_browse)

	_clear = Button.new()
	_clear.name = "Clear"
	_clear.text = "✕"
	_clear.visible = false
	row.add_child(_clear)

	_browse.pressed.connect(_on_browse)
	_clear.pressed.connect(func(): set_path(""))


func path() -> String:
	return _path


func has_path() -> bool:
	return _path != ""


func displayed_text() -> String:
	return _value.text


func set_label(text: String) -> void:
	_label.text = text
	_label.visible = text != ""


func set_filters(filters: PackedStringArray) -> void:
	_filters = filters


func set_dialog_title(text: String) -> void:
	_title = text


## Take a path, or "" to clear. Reports only when it actually changes, because
## the view calls this from a dialog that may return the same file twice.
func set_path(value: String) -> void:
	var trimmed := value.strip_edges()
	if trimmed == _path:
		return
	_path = trimmed
	_value.text = _path.get_file() if _path != "" else EMPTY_COPY
	_clear.visible = _path != ""
	path_changed.emit(_path)


func _on_browse() -> void:
	browse_requested.emit(_filters, _title)
