@tool
extends VBoxContainer

## Pick several files. Screenshots, mostly.
##
## IT ASKS FOR THE DIALOG, like its single-file sibling and for the same reason:
## opening one means reaching `EditorInterface`, which exists only inside a
## running editor, and everything worth testing here is around the dialog rather
## than in it.
##
## DUPLICATES ARE DROPPED SILENTLY. Somebody adding files in two goes will pick
## the same screenshot twice, and a submission carrying it twice is a grader
## looking at the same picture and wondering what they missed. Dropping it is
## what they meant; saying so would be a complaint about nothing.
##
## ORDER IS PRESERVED, AND THAT IS NOT INCIDENTAL. Screenshots tell a sequence
## -- before, during, after -- and a set that reordered them would tell a
## different story. Additions go on the end, removals close the gap.
##
## A CAP, BECAUSE THE OTHER END HAS ONE. The submission API takes a bounded
## number of files, and finding that out after an upload has run is a learner
## who waited for nothing. Refusing the extra pick is the earliest honest place.

signal browse_requested(filters: PackedStringArray, title: String)
signal paths_changed(paths: PackedStringArray)

## How many files a submission may carry. Matches what the API accepts.
const MAX_FILES := 10

const EMPTY_COPY := "No files chosen"

var _label: Label = null
var _list: VBoxContainer = null
var _summary: Label = null
var _browse: Button = null

var _paths: PackedStringArray = []
var _filters := PackedStringArray()
var _title := "Choose files"


func _init() -> void:
	name = "MultiFilePicker"
	add_theme_constant_override("separation", 4)

	_label = Label.new()
	_label.name = "Label"
	_label.visible = false
	add_child(_label)

	_list = VBoxContainer.new()
	_list.name = "Files"
	add_child(_list)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_summary = Label.new()
	_summary.name = "Summary"
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_summary)

	_browse = Button.new()
	_browse.name = "Browse"
	_browse.text = "Add…"
	row.add_child(_browse)

	_browse.pressed.connect(func(): browse_requested.emit(_filters, _title))
	_refresh()


func paths() -> PackedStringArray:
	return _paths.duplicate()


func count() -> int:
	return _paths.size()


func is_full() -> bool:
	return _paths.size() >= MAX_FILES


func summary_text() -> String:
	return _summary.text


func set_label(text: String) -> void:
	_label.text = text
	_label.visible = text != ""


func set_filters(filters: PackedStringArray) -> void:
	_filters = filters


func set_dialog_title(text: String) -> void:
	_title = text


## Replace the whole list. Reports once, and only if something changed.
func set_paths(values: PackedStringArray) -> void:
	var next := PackedStringArray()
	for value in values:
		var trimmed: String = value.strip_edges()
		if trimmed == "" or next.has(trimmed) or next.size() >= MAX_FILES:
			continue
		next.append(trimmed)
	if next == _paths:
		return
	_paths = next
	_refresh()
	paths_changed.emit(paths())


## Add files to what is already there. What the dialog's answer goes through.
func add_paths(values: PackedStringArray) -> void:
	var next := _paths.duplicate()
	for value in values:
		var trimmed: String = value.strip_edges()
		if trimmed == "" or next.has(trimmed) or next.size() >= MAX_FILES:
			continue
		next.append(trimmed)
	if next == _paths:
		return
	_paths = next
	_refresh()
	paths_changed.emit(paths())


func remove_path(value: String) -> void:
	var index := _paths.find(value)
	if index < 0:
		return
	_paths.remove_at(index)
	_refresh()
	paths_changed.emit(paths())


func _refresh() -> void:
	for child in _list.get_children():
		child.free()
	for value in _paths:
		var row := HBoxContainer.new()
		row.name = "File"
		row.add_theme_constant_override("separation", 4)

		var label := Label.new()
		label.name = "Name"
		# The file name, not the path: an absolute path is longer than the panel
		# and its useful end is the last segment.
		label.text = value.get_file()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var remove := Button.new()
		remove.name = "Remove"
		remove.text = "✕"
		remove.flat = true
		remove.pressed.connect(remove_path.bind(value))
		row.add_child(remove)

		_list.add_child(row)

	if _paths.is_empty():
		_summary.text = EMPTY_COPY
	elif _paths.size() == 1:
		_summary.text = "1 file"
	else:
		_summary.text = "%d files" % _paths.size()
	_browse.disabled = is_full()
