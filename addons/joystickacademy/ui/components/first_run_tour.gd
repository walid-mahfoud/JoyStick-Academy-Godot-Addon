@tool
extends PanelContainer

## Five cards, once, the first time somebody opens the panel.
##
## WHAT IT IS FOR. The panel has four tabs and none of them explains the others.
## Somebody opening it cold sees a library and has no reason to think Practice
## runs inside their editor or that Submit needs a capstone first. Five sentences
## fixes that; a manual does not, because nobody reads one.
##
## SEEN-NESS IS THE CALLER'S, NOT THIS COMPONENT'S. Whether the tour has run
## before is a fact about the install, stored in editor settings that exist only
## inside a running editor -- so a component that read it could not be tested,
## and the part worth testing is the sequence: that Back stops at the first card,
## that Next finishes on the last, and that finishing reports exactly once.
##
## SKIP AND FINISH ARE THE SAME OUTCOME AND DIFFERENT SIGNALS. Both close the
## tour and both mark it seen -- somebody who skipped does not want it tomorrow
## either -- but a caller counting how many people read it needs to know which
## happened, and merging them would throw that away at the only place it exists.

signal finished()
signal skipped()

## The five cards, in order. Their text is the product's, so it lives here
## rather than being passed in: a caller that supplied its own could show a
## different tour in a different view, which is the opposite of the point.
const STEPS := [
	{
		"title": "Welcome to JoyStick Academy",
		"body": "This panel is where you practise inside your own project. "
			+ "Five quick cards and you are done.",
	},
	{
		"title": "Library",
		"body": "Your courses and lessons, the same ones as on your phone. "
			+ "Anything marked mobile only is read there instead.",
	},
	{
		"title": "Practice",
		"body": "A walkthrough runs here, in this editor, against the project "
			+ "you have open. The checks under each step watch your work.",
	},
	{
		"title": "Submit",
		"body": "When a capstone is finished, this is where it goes for "
			+ "grading. You will need a project to submit first.",
	},
	{
		"title": "Account",
		"body": "Sign in with the code from your phone. Progress you make here "
			+ "counts there, and the other way round.",
	},
]

var _title: Label = null
var _body: Label = null
var _progress: Label = null
var _back: Button = null
var _next: Button = null
var _skip: Button = null

var _index := 0
## Set once the tour is over, so a second Finish cannot report twice.
var _closed := false


func _init() -> void:
	name = "FirstRunTour"

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 8)
	add_child(column)

	_title = Label.new()
	_title.name = "Title"
	column.add_child(_title)

	_body = Label.new()
	_body.name = "Body"
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_body)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 6)
	column.add_child(row)

	_progress = Label.new()
	_progress.name = "Progress"
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_progress)

	_skip = Button.new()
	_skip.name = "Skip"
	_skip.text = "Skip"
	_skip.flat = true
	row.add_child(_skip)

	_back = Button.new()
	_back.name = "Back"
	_back.text = "Back"
	row.add_child(_back)

	_next = Button.new()
	_next.name = "Next"
	row.add_child(_next)

	_back.pressed.connect(back)
	_next.pressed.connect(next)
	_skip.pressed.connect(skip)

	_refresh()


func index() -> int:
	return _index


func step_count() -> int:
	return STEPS.size()


func is_closed() -> bool:
	return _closed


func title() -> String:
	return _title.text


func body() -> String:
	return _body.text


func next_text() -> String:
	return _next.text


func back() -> void:
	if _closed or _index <= 0:
		return
	_index -= 1
	_refresh()


func next() -> void:
	if _closed:
		return
	if _index >= STEPS.size() - 1:
		_closed = true
		finished.emit()
		return
	_index += 1
	_refresh()


func skip() -> void:
	if _closed:
		return
	_closed = true
	skipped.emit()


func _refresh() -> void:
	var step: Dictionary = STEPS[_index]
	_title.text = str(step["title"])
	_body.text = str(step["body"])
	_progress.text = "%d of %d" % [_index + 1, STEPS.size()]

	# BACK IS DISABLED ON THE FIRST CARD, not hidden. A button that comes and
	# goes moves Next under the cursor between cards, so the second click of a
	# fast reader lands on something they did not aim at.
	_back.disabled = _index == 0
	_next.text = "Done" if _index == STEPS.size() - 1 else "Next"
	# Skip is pointless on the last card, where Next does the same thing and
	# says it better.
	_skip.visible = _index < STEPS.size() - 1
