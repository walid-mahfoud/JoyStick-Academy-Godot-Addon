@tool
extends Button

## One lesson in the library: title and subtitle, with pills on the right.
##
## IT TAKES A DICTIONARY, NOT A TYPED MODEL, and that is the boundary this whole
## addon sits on. The catalog is Core's, it arrives over a pipe as JSON, and
## GDScript has no way to hold a `LessonSummary`. Inventing a parallel class here
## would mean a second definition of the same shape, kept in step by hand, in a
## language that cannot check it.
##
## SO A MISSING KEY MUST BE ORDINARY. A tile built from a row that has no
## subtitle, no minutes and no difficulty renders the title alone rather than
## the words "null" or an empty pill -- because a half-populated catalog row is
## what an author mid-edit produces, and the library has to keep working while
## they work.
##
## LOCKED IS NOT DISABLED. A disabled button says nothing and cannot be pressed,
## so a learner tapping a locked lesson learns nothing about why. This stays
## pressable and reports itself as locked, and the view above decides what to
## say -- which is where the reason lives.

signal selected(lesson_id: String)

## Shown on a lesson the plugin cannot run, so a learner does not start it in
## the editor and find nothing there.
const MOBILE_ONLY_PILL := "mobile only"
const LOCKED_MARK := "🔒"

var _lesson := {}
var _locked := false

var _title: Label = null
var _subtitle: Label = null
var _pills: HBoxContainer = null


func _init() -> void:
	name = "LessonTile"
	# A Button laid out as a row. Godot's Button draws its own text, which is
	# no use for two lines and a pill strip, so the text is empty and the
	# content is children.
	text = ""
	custom_minimum_size = Vector2(0, 44)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)

	var text_column := VBoxContainer.new()
	text_column.name = "Text"
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text_column)

	_title = Label.new()
	_title.name = "Title"
	text_column.add_child(_title)

	_subtitle = Label.new()
	_subtitle.name = "Subtitle"
	_subtitle.visible = false
	text_column.add_child(_subtitle)

	_pills = HBoxContainer.new()
	_pills.name = "Pills"
	_pills.add_theme_constant_override("separation", 6)
	_pills.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_pills)

	pressed.connect(_on_pressed)


func lesson_id() -> String:
	return str(_lesson.get("lessonId", ""))


func is_locked() -> bool:
	return _locked


func has_walkthrough() -> bool:
	return bool(_lesson.get("hasWalkthrough", false))


## Every pill currently shown, in order. For tests and for the view's own
## layout decisions.
func pill_texts() -> Array:
	var out: Array = []
	for pill in _pills.get_children():
		out.append((pill as Label).text)
	return out


func bind(lesson: Dictionary, locked := false) -> void:
	_lesson = lesson if lesson != null else {}
	_locked = locked
	_refresh()


func _on_pressed() -> void:
	var id := lesson_id()
	if id == "":
		# A row with no id cannot be opened, and reporting an empty one would
		# send the view looking for a lesson that does not exist.
		return
	selected.emit(id)


func _refresh() -> void:
	var title := str(_lesson.get("title", ""))
	if title == "":
		# THE ID IS A WORSE TITLE THAN A TITLE AND A BETTER ONE THAN NOTHING.
		# An untitled row still has to be distinguishable from the row above it.
		title = lesson_id()
	_title.text = ("%s %s" % [LOCKED_MARK, title]) if _locked else title

	var subtitle := str(_lesson.get("subtitle", ""))
	_subtitle.text = subtitle
	_subtitle.visible = subtitle != ""

	for pill in _pills.get_children():
		pill.free()

	var minutes := int(_lesson.get("estimatedMinutes", 0))
	if minutes > 0:
		# Zero is ABSENT, not a lesson that takes no time. The wire sends 0 for
		# a field an author has not filled in, and "0 min" is a claim about the
		# lesson rather than about the catalog.
		_add_pill("%d min" % minutes)

	var difficulty := str(_lesson.get("difficulty", ""))
	if difficulty != "":
		_add_pill(difficulty)

	if not has_walkthrough():
		_add_pill(MOBILE_ONLY_PILL)


func _add_pill(pill_text: String) -> void:
	var pill := Label.new()
	pill.name = "Pill"
	pill.text = pill_text
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pills.add_child(pill)
