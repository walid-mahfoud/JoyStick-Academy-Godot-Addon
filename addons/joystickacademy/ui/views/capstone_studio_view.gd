@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 31. A capstone's milestones, and what they add up to.
##
## TWO SCOPES WITH TWO DIFFERENT GATES, and getting them the same way round is
## the only thing in this view that can pay out money it should not.
##
##   COURSE minis are 100% machine-checked and claim instantly. Every milestone
##   must PASS, and a milestone that is human-graded or has never been evaluated
##   BLOCKS -- because a claim is XP and gems, and paying for an unevaluated
##   milestone is paying for nothing built. The Unreal plugin shipped the
##   opposite of this once and four mini-projects paid out on open.
##
##   PATH capstones carry a human craft layer, so their gate is the AUTO ones.
##   A human milestone that nobody has graded yet does NOT block submitting --
##   it cannot, because submitting is what causes it to be graded.
##
## THE TWO RULES ARE STATIC AND PURE, side by side, so the difference between
## them is one screenful and is tested directly rather than through a button.
##
## A MILESTONE WITH NO VERIFIERS IS HUMAN, NOT PASSING. The parser's default is
## `human` for exactly this reason: an author who wrote no verifiers has not
## written a milestone that everybody passes.

const PhaseStepper := preload("res://addons/joystickacademy/ui/components/phase_stepper.gd")
const Header := preload("res://addons/joystickacademy/ui/components/header.gd")
const RichMarkdownBlock := preload("res://addons/joystickacademy/ui/components/rich_markdown_block.gd")

const COMMAND_RECHECK := "capstone.recheck"
const COMMAND_CLAIM := "capstone.claim"
const COMMAND_SUBMIT := "capstone.submit"
const COMMAND_OPEN_MILESTONE := "capstone.open_milestone"

const SCOPE_COURSE := "course"
const SCOPE_PATH := "path"

## How a milestone is judged.
const MODE_AUTO := "auto"
const MODE_HUMAN := "human"
const MODE_BOTH := "both"

const MARK_PASS := "●"
const MARK_FAIL := "○"
const MARK_HUMAN := "◐"

var _header: Control = null
var _brief: Control = null
var _milestones: VBoxContainer = null
var _status: Label = null
var _recheck: Button = null
var _action: Button = null


func _init() -> void:
	name = "CapstoneStudioView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)

	_brief = RichMarkdownBlock.new()
	column.add_child(_brief)

	_milestones = VBoxContainer.new()
	_milestones.name = "Milestones"
	_milestones.add_theme_constant_override("separation", 4)
	column.add_child(_milestones)

	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.visible = false
	add_child(_status)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)
	add_child(actions)

	_recheck = Button.new()
	_recheck.name = "Recheck"
	_recheck.text = "Re-check"
	actions.add_child(_recheck)

	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)

	_action = Button.new()
	_action.name = "Action"
	actions.add_child(_action)

	_recheck.pressed.connect(func(): send(COMMAND_RECHECK))
	_action.pressed.connect(_on_action)


## How a milestone is judged. Absent or unrecognised is HUMAN, not auto: an
## author who wrote no verifiers has not written a milestone everybody passes.
static func mode_of(milestone: Dictionary) -> String:
	var mode := str(milestone.get("mode", MODE_HUMAN))
	return mode if mode in [MODE_AUTO, MODE_HUMAN, MODE_BOTH] else MODE_HUMAN


## COURSE SCOPE: every milestone must have passed.
##
## A human or never-evaluated milestone BLOCKS, because claiming pays XP and
## gems and an unevaluated milestone is nothing built.
static func can_claim(milestones: Array) -> bool:
	if milestones.is_empty():
		return false
	for milestone in milestones:
		if not (milestone is Dictionary):
			return false
		if milestone.get("passed", null) != true:
			return false
	return true


## PATH SCOPE: the auto-checked ones must pass; the human ones cannot yet.
##
## A human milestone nobody has graded does not block, because submitting is
## what causes it to be graded.
static func can_submit(milestones: Array) -> bool:
	if milestones.is_empty():
		return false
	var gating := 0
	for milestone in milestones:
		if not (milestone is Dictionary):
			return false
		if mode_of(milestone) == MODE_HUMAN:
			continue
		gating += 1
		if milestone.get("passed", null) != true:
			return false
	# EVERY MILESTONE BEING HUMAN IS NOT A CAPSTONE READY TO SUBMIT. It is an
	# authoring mistake, and letting it through would submit unverified work.
	return gating > 0


func scope() -> String:
	return text_at(_payload, "scope", SCOPE_COURSE)


func milestones() -> Array:
	return rows_at(_payload, "milestones")


func is_action_enabled() -> bool:
	return not _action.disabled


func action_text() -> String:
	return _action.text


func status_text() -> String:
	return _status.text


## The rows built for each milestone, in order.
##
## An accessor rather than a tree path, because the list is nested inside a
## scroll container and a test spelling that path out would break the day
## somebody wraps it in one more thing.
func milestone_rows() -> Array:
	return _milestones.get_children()


## The mark shown against each milestone, in order.
func marks() -> Array:
	var out: Array = []
	for row in _milestones.get_children():
		out.append((row.get_node("Line/Mark") as Label).text)
	return out


func _render(payload: Dictionary) -> void:
	_header.set_title(text_at(payload, "title"))
	_header.set_subtitle(text_at(payload, "subtitle"))
	_brief.set_markdown(text_at(payload, "brief"))

	for child in _milestones.get_children():
		child.free()
	var rows := milestones()
	for milestone in rows:
		_add_milestone(milestone)

	if scope() == SCOPE_PATH:
		_action.text = "Submit for grading"
		_action.disabled = not can_submit(rows)
	else:
		_action.text = "Claim reward"
		_action.disabled = not can_claim(rows)

	_render_status(rows)


func _add_milestone(milestone: Dictionary) -> void:
	var row := Button.new()
	row.name = "Milestone"
	row.text = ""
	row.custom_minimum_size = Vector2(0, 28)

	var line := HBoxContainer.new()
	line.name = "Line"
	line.set_anchors_preset(Control.PRESET_FULL_RECT)
	line.add_theme_constant_override("separation", 6)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)

	var mark := Label.new()
	mark.name = "Mark"
	mark.text = _mark_for(milestone)
	line.add_child(mark)

	var title := Label.new()
	title.name = "Title"
	title.text = text_at(milestone, "title", text_at(milestone, "id", "(untitled)"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(title)

	_milestones.add_child(row)
	row.pressed.connect(_on_milestone.bind(text_at(milestone, "id")))


static func _mark_for(milestone: Dictionary) -> String:
	if milestone.get("passed", null) == true:
		return MARK_PASS
	# A HUMAN MILESTONE IS NOT A FAILURE, and marking it with the same symbol as
	# one the learner has not finished tells them to go and fix something a
	# grader has simply not looked at yet.
	if mode_of(milestone) == MODE_HUMAN:
		return MARK_HUMAN
	return MARK_FAIL


func _render_status(rows: Array) -> void:
	if rows.is_empty():
		_status.text = "This capstone has no milestones yet."
		_status.visible = true
		return
	if not _action.disabled:
		_status.visible = false
		return

	var outstanding := 0
	for milestone in rows:
		if scope() == SCOPE_PATH and mode_of(milestone) == MODE_HUMAN:
			continue
		if milestone.get("passed", null) != true:
			outstanding += 1

	if outstanding == 0:
		# Path scope with nothing but human milestones: the gate refused for a
		# reason the count cannot show.
		_status.text = "This capstone has nothing a machine can check yet."
	elif outstanding == 1:
		_status.text = "1 milestone still to go."
	else:
		_status.text = "%d milestones still to go." % outstanding
	_status.visible = true


func _on_action() -> void:
	var rows := milestones()
	if scope() == SCOPE_PATH:
		if not can_submit(rows):
			return
		send(COMMAND_SUBMIT, {"projectId": text_at(_payload, "projectId")})
		return
	if not can_claim(rows):
		return
	send(COMMAND_CLAIM, {"projectId": text_at(_payload, "projectId")})


func _on_milestone(milestone_id: String) -> void:
	if milestone_id == "":
		return
	send(COMMAND_OPEN_MILESTONE, {"milestoneId": milestone_id})
