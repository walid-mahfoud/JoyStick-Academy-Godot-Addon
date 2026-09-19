@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 32. Package the project, say something about it, send it.
##
## THE PHASE STRIP IS NOT DECORATION. An upload of a project archive takes long
## enough that somebody watching a spinner assumes it has hung; showing that
## packaging is done and uploading is running says the wait is normal and how
## much of it is left.
##
## SUBMIT IS REFUSED UNTIL THE REQUIRED THINGS ARE THERE, and refused HERE. The
## API refuses too, but its refusal arrives after a large upload -- so a learner
## who forgot the archive waits for a failure they could have been told about
## before they started.
##
## WHAT IS REQUIRED COMES FROM THE PAYLOAD, not from this view. The capstone's
## own submissionRequirements say whether it wants a video or screenshots, and a
## view with its own idea would refuse a submission the server would accept.
##
## THE NOTES ARE OPTIONAL AND THE HINT SAYS WHAT THEY ARE FOR. "Tell the grader
## what you found hard" is not something anybody guesses, and a blank box gets
## blank answers.

const PhaseStepper := preload("res://addons/joystickacademy/ui/components/phase_stepper.gd")
const FilePicker := preload("res://addons/joystickacademy/ui/components/file_picker.gd")
const MultiFilePicker := preload("res://addons/joystickacademy/ui/components/multi_file_picker.gd")
const NotesField := preload("res://addons/joystickacademy/ui/components/notes_field.gd")
const Header := preload("res://addons/joystickacademy/ui/components/header.gd")

const COMMAND_SUBMIT := "submission.submit"
const COMMAND_BROWSE_ARCHIVE := "submission.browse_archive"
const COMMAND_BROWSE_SHOTS := "submission.browse_screenshots"
const COMMAND_CANCEL := "submission.cancel"
const COMMAND_SAVE_NOTES := "submission.save_notes"

## The phases, in the order they happen.
const PHASES := ["Package", "Upload", "Grade", "Certificate"]

## Requirement names the payload may ask for.
const REQUIRE_ARCHIVE := "source_zip"
const REQUIRE_SCREENSHOTS := "screenshots"

var _header: Control = null
var _phases: Control = null
var _archive: Control = null
var _shots: Control = null
var _notes: Control = null
var _status: Label = null
var _submit: Button = null
var _cancel: Button = null


func _init() -> void:
	name = "SubmissionView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)
	_header.set_title("Submit")

	_phases = PhaseStepper.new()
	add_child(_phases)
	_phases.set_phases(PHASES)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)

	_archive = FilePicker.new()
	column.add_child(_archive)
	_archive.set_label("Project archive")
	_archive.set_filters(PackedStringArray(["*.zip"]))
	_archive.set_dialog_title("Choose your project archive")

	_shots = MultiFilePicker.new()
	column.add_child(_shots)
	_shots.set_label("Screenshots")
	_shots.set_filters(PackedStringArray(["*.png", "*.jpg", "*.jpeg"]))
	_shots.set_dialog_title("Choose screenshots")

	_notes = NotesField.new()
	column.add_child(_notes)
	_notes.set_hint("Tell the grader what you found hard, or what you are "
		+ "proudest of. Optional.")

	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.visible = false
	add_child(_status)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)
	add_child(actions)

	_cancel = Button.new()
	_cancel.name = "Cancel"
	_cancel.text = "Cancel"
	_cancel.visible = false
	actions.add_child(_cancel)

	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)

	_submit = Button.new()
	_submit.name = "Submit"
	_submit.text = "Submit"
	actions.add_child(_submit)

	_archive.browse_requested.connect(
		func(filters, title): send(COMMAND_BROWSE_ARCHIVE,
			{"filters": filters, "title": title}))
	_shots.browse_requested.connect(
		func(filters, title): send(COMMAND_BROWSE_SHOTS,
			{"filters": filters, "title": title}))
	_archive.path_changed.connect(func(_p): _refresh_submit())
	_shots.paths_changed.connect(func(_p): _refresh_submit())
	_notes.value_changed.connect(_on_notes)
	_submit.pressed.connect(_on_submit)
	_cancel.pressed.connect(func(): send(COMMAND_CANCEL))

	_refresh_submit()


## What this capstone insists on, from the payload.
func required() -> Array:
	var out: Array = []
	for name in _payload.get("required", [REQUIRE_ARCHIVE]):
		if name is String:
			out.append(name)
	return out


func is_working() -> bool:
	return number_at(_payload, "phase", -1) >= 0


func missing() -> Array:
	var out: Array = []
	var want := required()
	if want.has(REQUIRE_ARCHIVE) and not _archive.has_path():
		out.append("a project archive")
	if want.has(REQUIRE_SCREENSHOTS) and _shots.count() == 0:
		out.append("at least one screenshot")
	return out


func can_submit() -> bool:
	return missing().is_empty() and not is_working()


func status_text() -> String:
	return _status.text


func archive_picker() -> Control:
	return _archive


func screenshot_picker() -> Control:
	return _shots


func _render(payload: Dictionary) -> void:
	_header.set_subtitle(text_at(payload, "capstoneTitle"))

	var path := text_at(payload, "archivePath")
	if path != "":
		_archive.set_path(path)
	var shots = payload.get("screenshotPaths", null)
	if shots is Array:
		var typed := PackedStringArray()
		for shot in shots:
			if shot is String:
				typed.append(shot)
		_shots.set_paths(typed)

	var notes := text_at(payload, "notes")
	if notes != "":
		_notes.set_value(notes)

	# A PHASE BELOW ZERO IS "NOT STARTED", which is different from being on the
	# first phase. Phase 0 is packaging, and showing it before the learner has
	# pressed anything says work is happening that is not.
	_phases.set_active_index(number_at(payload, "phase", -1))

	# Screenshots are only shown when asked for: an optional picker that is
	# never used is a field somebody wonders whether they have missed.
	_shots.visible = required().has(REQUIRE_SCREENSHOTS)

	_cancel.visible = is_working()
	_refresh_submit()


func _refresh_submit() -> void:
	var gaps := missing()
	_submit.disabled = not can_submit()
	_submit.text = "Submitting…" if is_working() else "Submit"

	var error := text_at(_payload, "error")
	if error != "":
		_status.text = error
		_status.visible = true
		return
	if gaps.is_empty():
		_status.visible = false
		return
	# NAMED, NOT COUNTED. "Two things missing" makes somebody hunt for them.
	_status.text = "Still needed: %s." % ", ".join(gaps)
	_status.visible = true


func _on_submit() -> void:
	if not can_submit():
		return
	send(COMMAND_SUBMIT, {
		"projectId": text_at(_payload, "projectId"),
		"archivePath": _archive.path(),
		"screenshotPaths": _shots.paths(),
		"notes": _notes.value(),
	})


func _on_notes(value: String) -> void:
	# Saved as they type: a draft kept until submit is a draft lost when the
	# editor crashes, and a capstone's notes are not a sentence.
	send(COMMAND_SAVE_NOTES, {"notes": value})
