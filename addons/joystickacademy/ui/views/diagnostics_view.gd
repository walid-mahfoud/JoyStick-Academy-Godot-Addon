@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 37. One page that says whether any of this is working.
##
## WHAT IT IS FOR, AND WHY IT IS NOT AN AFTERTHOUGHT. A learner reporting "the
## plugin does not work" has told nobody anything, and the four things that
## could be wrong -- the helper is not running, it is running but they are not
## signed in, they are signed in but offline, or the editor and the helper
## cannot talk -- look identical from every other view in the panel. This is the
## one line that separates them.
##
## EVERY ROW IS A FACT, NOT A VERDICT. It shows what it found: the version, the
## path, whether a probe round-tripped. A single green tick summarising four
## facts is the thing that gets reported as "it says it is fine" while
## something is plainly not.
##
## COPY IS FOR PASTING. The whole report goes to the clipboard in one press,
## because the alternative is somebody transcribing a version string into a
## support message and getting a digit wrong.

const Header := preload("res://addons/joystickacademy/ui/components/header.gd")

const COMMAND_RUN := "diagnostics.run"
const COMMAND_COPY := "diagnostics.copy"

## What a row's state may be. Unknown reads as UNKNOWN rather than as a failure:
## a check that has not run has not failed.
const STATE_OK := "ok"
const STATE_BAD := "bad"
const STATE_UNKNOWN := "unknown"

const MARKS := {
	STATE_OK: "✓",
	STATE_BAD: "✕",
	STATE_UNKNOWN: "?",
}

var _header: Control = null
var _rows: VBoxContainer = null
var _run: Button = null
var _copy: Button = null


func _init() -> void:
	name = "DiagnosticsView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)
	_header.set_title("Diagnostics")
	_header.set_subtitle("What the plugin can and cannot reach right now.")

	_rows = VBoxContainer.new()
	_rows.name = "Rows"
	add_child(_rows)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)
	add_child(actions)

	_run = Button.new()
	_run.name = "Run"
	_run.text = "Run checks"
	actions.add_child(_run)

	_copy = Button.new()
	_copy.name = "Copy"
	_copy.text = "Copy report"
	actions.add_child(_copy)

	_run.pressed.connect(func(): send(COMMAND_RUN))
	_copy.pressed.connect(_on_copy)


## Every row, as {"label", "state", "detail"}.
func rows() -> Array:
	var out: Array = []
	for row in _rows.get_children():
		out.append({
			"label": (row.get_node("Label") as Label).text,
			"mark": (row.get_node("Mark") as Label).text,
			"detail": (row.get_node("Detail") as Label).text,
		})
	return out


## The whole report as one block of text, which is what Copy puts on the
## clipboard and what a support message should carry.
func report_text() -> String:
	var lines: Array = []
	for row in rows():
		var line: String = "%s %s" % [row["mark"], row["label"]]
		if row["detail"] != "":
			line += ": %s" % row["detail"]
		lines.append(line)
	return "\n".join(lines)


func _render(payload: Dictionary) -> void:
	for child in _rows.get_children():
		child.free()

	var checks := rows_at(payload, "checks")
	if checks.is_empty():
		# NOT AN ERROR, AND NOT SILENCE EITHER. A diagnostics page showing
		# nothing is the one thing more confusing than the problem it was
		# opened to explain.
		_add_row("Checks have not run yet", STATE_UNKNOWN, "Press Run checks.")
		_copy.disabled = true
		return

	for check in checks:
		_add_row(
			text_at(check, "label", "(unnamed check)"),
			text_at(check, "state", STATE_UNKNOWN),
			text_at(check, "detail"))
	_copy.disabled = false

	_run.text = "Running…" if flag_at(payload, "running") else "Run checks"
	_run.disabled = flag_at(payload, "running")


func _add_row(label: String, state: String, detail: String) -> void:
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 6)

	var mark := Label.new()
	mark.name = "Mark"
	mark.text = str(MARKS.get(state, MARKS[STATE_UNKNOWN]))
	row.add_child(mark)

	var text := Label.new()
	text.name = "Label"
	text.text = label
	row.add_child(text)

	var detail_label := Label.new()
	detail_label.name = "Detail"
	detail_label.text = detail
	detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(detail_label)

	_rows.add_child(row)


func _on_copy() -> void:
	# THE TEXT TRAVELS WITH THE COMMAND. Putting it on the clipboard means
	# reaching DisplayServer, which is a thing a headless test has not got --
	# and the shell has to log what was copied anyway.
	send(COMMAND_COPY, {"text": report_text()})
