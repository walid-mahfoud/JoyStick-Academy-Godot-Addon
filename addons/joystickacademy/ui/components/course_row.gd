@tool
extends VBoxContainer

## One course in the library: a header you can tap, and lessons underneath.
##
## COLLAPSED BY DEFAULT, and that is a decision about the first thing a learner
## sees rather than about chrome. A path holds dozens of courses and hundreds of
## lessons; opening every one of them presents a wall nobody reads. The header
## carries the count so the shape of the thing is visible without expanding it.
##
## THE BODY IS BUILT ON EVERY BIND, NOT KEPT AND UPDATED. A course's lesson list
## changes when the catalog syncs, and reconciling two lists in place is the
## kind of code that leaves a stale tile behind exactly once, on the rebuild
## nobody tested. Rebuilding is cheap at this size and cannot go stale.
##
## LOCKING IS ASKED, NOT STORED. Which lessons are locked depends on progress
## that changes while the row is on screen, so the caller passes a Callable and
## it is consulted at bind time. A row that cached it would show yesterday's
## locks after a lesson was finished.

signal lesson_selected(lesson_id: String)
signal expanded_changed(expanded: bool)

const LessonTile := preload("res://addons/joystickacademy/ui/components/lesson_tile.gd")

const CHEVRON_COLLAPSED := "▶"
const CHEVRON_EXPANDED := "▼"

var _course := {}
var _expanded := false
## Takes a lesson id, returns whether it is locked. Null means nothing is.
var _is_locked: Callable = Callable()

var _header: Button = null
var _chevron: Label = null
var _title: Label = null
var _count: Label = null
var _body: VBoxContainer = null


func _init() -> void:
	name = "CourseRow"
	add_theme_constant_override("separation", 2)

	_header = Button.new()
	_header.name = "Header"
	_header.text = ""
	_header.custom_minimum_size = Vector2(0, 32)
	add_child(_header)

	var row := HBoxContainer.new()
	row.name = "HeaderRow"
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_child(row)

	_chevron = Label.new()
	_chevron.name = "Chevron"
	row.add_child(_chevron)

	_title = Label.new()
	_title.name = "Title"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_title)

	_count = Label.new()
	_count.name = "Count"
	row.add_child(_count)

	_body = VBoxContainer.new()
	_body.name = "Lessons"
	_body.visible = false
	add_child(_body)

	_header.pressed.connect(toggle)
	_refresh_header()


func course_id() -> String:
	return str(_course.get("courseId", ""))


func is_expanded() -> bool:
	return _expanded


func lesson_count() -> int:
	var lessons = _course.get("lessons", [])
	return lessons.size() if lessons is Array else 0


## The tiles currently built. Empty until the row is expanded at least once.
func tiles() -> Array:
	return _body.get_children()


func bind(course: Dictionary, is_locked := Callable()) -> void:
	_course = course if course != null else {}
	_is_locked = is_locked
	_refresh_header()
	_rebuild_body()


func toggle() -> void:
	set_expanded(not _expanded)


func set_expanded(expanded: bool) -> void:
	if expanded == _expanded:
		return
	_expanded = expanded
	_body.visible = _expanded
	_refresh_header()
	if _expanded:
		# BUILT ON EXPAND, not on bind. A collapsed course nobody opens costs
		# nothing, and a path of forty courses would otherwise build several
		# hundred tiles to show a list of forty titles.
		_rebuild_body()
	expanded_changed.emit(_expanded)


func _refresh_header() -> void:
	_chevron.text = CHEVRON_EXPANDED if _expanded else CHEVRON_COLLAPSED
	var title := str(_course.get("title", ""))
	_title.text = title if title != "" else course_id()
	var count := lesson_count()
	# "1 lesson", not "1 lessons". A plural nobody checked is the kind of thing
	# that makes a product feel unfinished for no functional reason.
	_count.text = "%d lesson" % count if count == 1 else "%d lessons" % count


func _rebuild_body() -> void:
	for child in _body.get_children():
		child.free()
	if not _expanded:
		return

	var lessons = _course.get("lessons", [])
	if not (lessons is Array):
		# BELT AND BRACES, AND SAYING SO BECAUSE A MUTATION PROVED IT. Removing
		# this changes no outcome: GDScript will happily iterate a String, one
		# character at a time, and every character falls to the per-entry check
		# below. What it saves is iterating a ten-thousand-character field
		# somebody mis-authored, which is worth the line but is not a behaviour
		# any test can distinguish. `lesson_count` carries the version of this
		# guard that IS observable.
		return
	for entry in lessons:
		# THIS ONE IS OBSERVABLE. An author writing a list of lesson IDS rather
		# than a list of lesson objects -- which is what the path YAML looks
		# like, so it is an easy mistake -- would otherwise build a tile per
		# string, each bound to nothing and showing an empty title.
		if not (entry is Dictionary):
			continue
		var tile = LessonTile.new()
		var locked := false
		if _is_locked.is_valid():
			locked = bool(_is_locked.call(str(entry.get("lessonId", ""))))
		_body.add_child(tile)
		tile.bind(entry, locked)
		tile.selected.connect(_on_lesson_selected)


func _on_lesson_selected(lesson_id: String) -> void:
	lesson_selected.emit(lesson_id)
