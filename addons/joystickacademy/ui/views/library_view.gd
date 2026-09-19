@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 29. The courses and lessons, and what to pick up.
##
## THE RESUME BANNER IS ABOVE THE LIST BECAUSE IT IS USUALLY THE ANSWER.
## Somebody opening the panel has almost always come back to something rather
## than to start something, and making them find it among forty courses is
## making them do the plugin's job.
##
## EMPTY IS THREE DIFFERENT STATES AND THEY DO NOT SHARE COPY. A learner who is
## signed out, one whose catalog has not arrived yet, and one whose path
## genuinely has no courses need three different things said to them, and a
## single "Nothing here" tells all three of them nothing. The payload says
## which; the view does not guess.
##
## THE LOCK PREDICATE IS THE PAYLOAD'S, NOT THIS VIEW'S. Which lessons are open
## depends on progress the sidecar holds, so the payload carries the ids and the
## view asks a closure over that set. Working it out here would mean the library
## and the walkthrough player could disagree about the same lesson.

const CourseRow := preload("res://addons/joystickacademy/ui/components/course_row.gd")
const ResumeBanner := preload("res://addons/joystickacademy/ui/components/resume_banner.gd")
const Header := preload("res://addons/joystickacademy/ui/components/header.gd")

const COMMAND_OPEN_LESSON := "library.open_lesson"
const COMMAND_RESUME := "library.resume"
const COMMAND_DISMISS_RESUME := "library.dismiss_resume"
const COMMAND_SIGN_IN := "library.sign_in"
const COMMAND_REFRESH := "library.refresh"

## What an empty library means, when it is empty.
const EMPTY_SIGNED_OUT := "signed_out"
const EMPTY_LOADING := "loading"
const EMPTY_NO_COURSES := "no_courses"

var _header: Control = null
var _banner: Control = null
var _empty: Label = null
var _empty_action: Button = null
var _scroll: ScrollContainer = null
var _list: VBoxContainer = null


func _init() -> void:
	name = "LibraryView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)
	_header.set_title("Library")

	_banner = ResumeBanner.new()
	_banner.visible = false
	add_child(_banner)

	_empty = Label.new()
	_empty.name = "Empty"
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.visible = false
	add_child(_empty)

	_empty_action = Button.new()
	_empty_action.name = "EmptyAction"
	_empty_action.visible = false
	add_child(_empty_action)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_scroll)

	_list = VBoxContainer.new()
	_list.name = "Courses"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)

	_banner.resume_requested.connect(_on_resume)
	# WHICH LESSON, because the sidecar deletes a bookmark by id and skips the
	# delete entirely when it is missing. Without this the button redrew the
	# library with the identical banner still on it, said nothing, and could be
	# pressed forever.
	_banner.dismissed.connect(func(): send(COMMAND_DISMISS_RESUME,
		{"lessonId": _banner.lesson_id()}))
	_empty_action.pressed.connect(_on_empty_action)


## The course rows currently built.
func course_rows() -> Array:
	return _list.get_children()


func is_empty_shown() -> bool:
	return _empty.visible


func empty_text() -> String:
	return _empty.text


func is_banner_shown() -> bool:
	return _banner.visible


func _render(payload: Dictionary) -> void:
	_header.set_subtitle(text_at(payload, "pathTitle"))

	var courses := rows_at(payload, "courses")
	_render_banner(payload)
	_render_courses(payload, courses)
	_render_empty(payload, courses)


func _render_banner(payload: Dictionary) -> void:
	var resume = payload.get("resume", null)
	var lesson = payload.get("resumeLesson", null)
	if not (resume is Dictionary) or not (lesson is Dictionary):
		_banner.visible = false
		return
	_banner.bind(resume, lesson)
	# A banner with nothing to resume is worse than no banner: it takes the top
	# of the view and does nothing when pressed.
	_banner.visible = _banner.lesson_id() != ""


func _render_courses(payload: Dictionary, courses: Array) -> void:
	for child in _list.get_children():
		child.free()

	var locked := {}
	for id in payload.get("lockedLessonIds", []):
		if id is String:
			locked[id] = true

	for course in courses:
		var row = CourseRow.new()
		_list.add_child(row)
		row.bind(course, func(lesson_id): return locked.has(lesson_id))
		row.lesson_selected.connect(_on_lesson_selected)


func _render_empty(payload: Dictionary, courses: Array) -> void:
	if not courses.is_empty():
		_empty.visible = false
		_empty_action.visible = false
		_scroll.visible = true
		return

	_scroll.visible = false
	_empty.visible = true

	# THREE STATES, THREE THINGS TO SAY. "Nothing here" would be true for all of
	# them and useful for none.
	match text_at(payload, "emptyReason", EMPTY_LOADING):
		EMPTY_SIGNED_OUT:
			_empty.text = "Sign in to see your courses. The pairing code is on " \
				+ "your phone, under Account."
			_empty_action.text = "Sign in"
			_empty_action.visible = true
		EMPTY_NO_COURSES:
			_empty.text = "There are no courses on this path yet. Your phone " \
				+ "has the full catalog."
			_empty_action.visible = false
		_:
			_empty.text = "Loading your courses…"
			_empty_action.text = "Try again"
			_empty_action.visible = true


func _on_lesson_selected(lesson_id: String) -> void:
	send(COMMAND_OPEN_LESSON, {"lessonId": lesson_id})


func _on_resume(lesson_id: String) -> void:
	send(COMMAND_RESUME, {"lessonId": lesson_id})


func _on_empty_action() -> void:
	# The button means different things in the two states that show it, and
	# deciding here keeps the caller from having to know which is on screen.
	if text_at(_payload, "emptyReason", EMPTY_LOADING) == EMPTY_SIGNED_OUT:
		send(COMMAND_SIGN_IN)
		return
	send(COMMAND_REFRESH)
