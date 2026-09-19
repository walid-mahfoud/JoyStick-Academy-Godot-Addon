@tool
extends VBoxContainer

## A box for what the learner wants to say about their submission.
##
## THE HINT IS A SEPARATE LABEL, NOT PLACEHOLDER TEXT. Placeholder text vanishes
## the moment somebody types, taking with it the one explanation of what the
## field is for -- and what it is for here is "tell the grader what you found
## hard", which nobody guesses. The hint stays.
##
## IT REPORTS EVERY CHANGE rather than waiting for focus to leave. The caller
## saves drafts, and a draft saved on blur is a draft lost when the editor
## crashes or the learner closes the panel from the keyboard.
##
## THE LIMIT IS ENFORCED AS THEY TYPE. Letting the text grow and refusing it on
## submit means somebody writes four hundred more characters and is told
## afterwards that none of them counted.
##
## THERE IS NO RE-ENTRY GUARD HERE, AND ITS ABSENCE IS MEASURED. The first
## version carried a `_rewriting` flag around every programmatic assignment, on
## the reasoning that rewriting the text would come back round as another edit
## and recurse. MEASURED on 4.5.1: NEITHER LineEdit NOR TextEdit EMITS
## `text_changed` WHEN `text` IS ASSIGNED FROM CODE -- only typing emits -- so
## the flag was never once set to any purpose. A mutation harness found it by
## removing it and watching nothing change.
##
## If that ever stops being true the guard comes back, and the tests that
## pin the one-report-per-edit behaviour are what would fail.

signal value_changed(value: String)

## Long enough to say something useful, short enough that a grader reads it.
## The same limit the mobile app uses for lesson notes.
const MAX_LENGTH := 500

var _hint: Label = null
var _input: TextEdit = null
var _counter: Label = null


func _init() -> void:
	name = "NotesField"
	add_theme_constant_override("separation", 4)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.visible = false
	add_child(_hint)

	_input = TextEdit.new()
	_input.name = "Input"
	_input.custom_minimum_size = Vector2(0, 96)
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(_input)

	_counter = Label.new()
	_counter.name = "Counter"
	add_child(_counter)

	_input.text_changed.connect(_on_text_changed)
	_refresh_counter()


func value() -> String:
	return _input.text


func hint() -> String:
	return _hint.text


func remaining() -> int:
	return MAX_LENGTH - _input.text.length()


func set_hint(text: String) -> void:
	_hint.text = text
	# Hidden when empty: an empty Label still takes its line, so the box would
	# sit lower in the view that set a hint than in the one that did not.
	_hint.visible = text != ""


func set_value(text: String) -> void:
	var trimmed := _truncate(text)
	if trimmed == _input.text:
		return
	_input.text = trimmed
	_refresh_counter()


func _on_text_changed() -> void:
	var trimmed := _truncate(_input.text)
	if trimmed != _input.text:
		_input.text = trimmed
		# The caret goes to the end of what survived. Rewriting the text resets
		# it to the start, and the next character typed would land in front of
		# everything they had written.
		_input.set_caret_line(maxi(0, _input.get_line_count() - 1))
		_input.set_caret_column(_input.get_line(_input.get_caret_line()).length())
	_refresh_counter()
	value_changed.emit(_input.text)


func _truncate(text: String) -> String:
	return text if text.length() <= MAX_LENGTH else text.substr(0, MAX_LENGTH)


func _refresh_counter() -> void:
	_counter.text = "%d / %d" % [_input.text.length(), MAX_LENGTH]
