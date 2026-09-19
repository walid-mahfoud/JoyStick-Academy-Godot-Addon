@tool
extends PanelContainer

## "Pick up where you left off", above the library.
##
## TWO COPY VARIANTS, AND THE ONE IT PICKS IS THE WHOLE POINT. A learner who
## just opened a lesson on their phone and walked to their desk is in a
## different moment from one returning to their own half-finished work, and the
## banner that greets both the same way is a banner neither of them reads.
##
## THE HAND-OFF IS DETECTED, NOT FLAGGED, and the predicate is a port. The phone
## writes the row with `openedInMobileAt` set, `stepId` at the schema default
## and no recorded attempts; any advance made in the editor moves the step
## forward or records an attempt, and either one breaks the predicate naturally.
## Nothing has to remember to clear a flag -- which is the version of this that
## would go wrong, because the clearing happens on the editor side and the
## setting happens on the phone.

signal resume_requested(lesson_id: String)
signal dismissed()

## What the phone writes as the step. A row still sitting on it has not been
## advanced by anybody.
const FRESH_STEP := "step-001"

var _lesson_id := ""

var _title: Label = null
var _subtitle: Label = null
var _resume: Button = null
var _dismiss: Button = null


func _init() -> void:
	name = "ResumeBanner"

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 8)
	add_child(row)

	var text_column := VBoxContainer.new()
	text_column.name = "Text"
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_column)

	_title = Label.new()
	_title.name = "Title"
	text_column.add_child(_title)

	_subtitle = Label.new()
	_subtitle.name = "Subtitle"
	text_column.add_child(_subtitle)

	_resume = Button.new()
	_resume.name = "Resume"
	_resume.text = "RESUME"
	row.add_child(_resume)

	_dismiss = Button.new()
	_dismiss.name = "Dismiss"
	_dismiss.text = "✕"
	row.add_child(_dismiss)

	_resume.pressed.connect(_on_resume)
	_dismiss.pressed.connect(func(): dismissed.emit())


func lesson_id() -> String:
	return _lesson_id


func title() -> String:
	return _title.text


func subtitle() -> String:
	return _subtitle.text


## Is this row a learner who has just walked over from their phone?
##
## STATIC AND PURE, so the rule can be tested without a banner. It is the part
## that decides which of two things a learner is told, and it is the part most
## likely to be got subtly wrong.
static func is_fresh_mobile_handoff(row: Dictionary) -> bool:
	if row == null:
		return false
	if str(row.get("openedInMobileAt", "")) == "":
		return false
	if str(row.get("stepId", "")) != FRESH_STEP:
		return false
	var attempts = row.get("attemptsByStep", {})
	if attempts is Dictionary and not attempts.is_empty():
		return false
	return true


## Show a resume row. Either argument being empty clears the banner.
func bind(row: Dictionary, lesson: Dictionary) -> void:
	if row == null or lesson == null or row.is_empty() or lesson.is_empty():
		_lesson_id = ""
		_title.text = ""
		_subtitle.text = ""
		return

	_lesson_id = str(row.get("lessonId", ""))
	var lesson_title := str(lesson.get("title", ""))
	if lesson_title == "":
		lesson_title = str(lesson.get("lessonId", ""))

	if is_fresh_mobile_handoff(row):
		_title.text = "🎮 Resume %s from mobile →" % lesson_title
		_subtitle.text = "Picked up from your phone, start here"
		return

	var step := str(row.get("stepId", ""))
	if step == "":
		step = FRESH_STEP
	_title.text = "Resume %s: Step %s" % [lesson_title, step]
	_subtitle.text = "Pick up where you left off"


func _on_resume() -> void:
	if _lesson_id == "":
		return
	resume_requested.emit(_lesson_id)
