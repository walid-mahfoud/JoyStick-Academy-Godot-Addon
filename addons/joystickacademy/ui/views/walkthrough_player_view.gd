@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 30. One step at a time, with the checks live underneath.
##
## A STEP WITH CHECKS GATES NEXT AND SAYS WHY. A step with none advances freely.
## That is the decided behaviour, matched across the three engines, and the
## second half matters as much as the first: an author writing a purely
## explanatory step should not have to invent a check to let the learner past it.
##
## THE GATE IS A REASON, NOT A DISABLED BUTTON. A greyed-out Next with nothing
## beside it is the most common way a tutorial loses somebody -- they cannot
## tell whether they have done it wrong or whether the plugin has stopped
## working. The strip underneath says what is still outstanding, and Next says
## it too.
##
## THE COMBO IS THE PAYLOAD'S, NOT COUNTED HERE. A run of consecutive passing
## steps is progress the sidecar owns and the phone shares; a view counting its
## own would disagree with both the moment somebody navigates away and back.
##
## RE-RENDERING IS THE WHOLE UPDATE PATH. The checks re-run on a cadence and the
## shell hands back a new payload each time; there is no partial update here,
## because a partial update is where a strip and a button come to disagree.

const RichMarkdownBlock := preload("res://addons/joystickacademy/ui/components/rich_markdown_block.gd")
const StepProgressBar := preload("res://addons/joystickacademy/ui/components/step_progress_bar.gd")
const VerifierStrip := preload("res://addons/joystickacademy/ui/components/verifier_strip.gd")
const HintButton := preload("res://addons/joystickacademy/ui/components/hint_button.gd")
const StreakBadge := preload("res://addons/joystickacademy/ui/components/in_lesson_streak_badge.gd")
const Header := preload("res://addons/joystickacademy/ui/components/header.gd")

const COMMAND_NEXT := "walkthrough.next"
const COMMAND_BACK := "walkthrough.back"
const COMMAND_HINT := "walkthrough.hint"
const COMMAND_GLOSSARY := "walkthrough.glossary"
const COMMAND_RECHECK := "walkthrough.recheck"
const COMMAND_LEAVE := "walkthrough.leave"
## Launch the learner's game with our observer in it. LOCAL -- see
## local_commands.gd: the sidecar cannot start a game and, on Godot, neither can
## it watch one.
const COMMAND_RUN := "player.run"

## What Next says when it cannot be pressed. Not a bare disabled button: see the
## header.
const BLOCKED_COPY := "Finish the step to continue"
const LAST_STEP_COPY := "Finish"

var _header: Control = null
var _badge: Control = null
var _progress: Control = null
var _body: Control = null
var _strip: Control = null
var _hint: Control = null
var _back: Button = null
var _next: Button = null
var _run: Button = null
var _blocked: Label = null


func _init() -> void:
	name = "WalkthroughPlayerView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	var top := HBoxContainer.new()
	top.name = "Top"
	top.add_theme_constant_override("separation", 6)
	add_child(top)

	_header = Header.new()
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_header)

	_badge = StreakBadge.new()
	top.add_child(_badge)

	_progress = StepProgressBar.new()
	add_child(_progress)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_body = RichMarkdownBlock.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body)

	_strip = VerifierStrip.new()
	add_child(_strip)

	_blocked = Label.new()
	_blocked.name = "Blocked"
	_blocked.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_blocked.visible = false
	add_child(_blocked)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)
	add_child(actions)

	_back = Button.new()
	_back.name = "Back"
	_back.text = "Back"
	actions.add_child(_back)

	_hint = HintButton.new()
	actions.add_child(_hint)

	# A BUTTON OF OUR OWN, NOT AN INSTRUCTION TO PRESS GODOT'S. A game the
	# learner starts themselves carries no observer, so nothing is recorded and
	# the check goes on reading "no play run happened" -- which looks like the
	# panel is broken, to somebody who just did exactly what it asked.
	_run = Button.new()
	_run.name = "Run"
	_run.text = "Run your game"
	_run.tooltip_text = ("Runs the scene you have open, watches what happens, "
		+ "and checks this step against it.")
	actions.add_child(_run)

	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)

	_next = Button.new()
	_next.name = "Next"
	_next.text = "Next"
	actions.add_child(_next)

	_back.pressed.connect(func(): send(COMMAND_BACK))
	_run.pressed.connect(_on_run)
	_next.pressed.connect(_on_next)
	_hint.hint_requested.connect(_on_hint)
	_body.glossary_term_clicked.connect(_on_term)

	_render({})


## How many of this step's checks are satisfied, and out of how many.
func check_counts() -> Array:
	var checks := rows_at(_payload, "checks")
	var passing := 0
	for check in checks:
		if flag_at(check, "passing"):
			passing += 1
	return [passing, checks.size()]


## Can the learner move on?
##
## A STEP WITH NO CHECKS ADVANCES FREELY -- that is the decided behaviour, and
## an author writing a purely explanatory step should not have to invent a check
## to let somebody past it.
func can_advance() -> bool:
	var counts := check_counts()
	return counts[1] == 0 or counts[0] >= counts[1]


func is_last_step() -> bool:
	return number_at(_payload, "stepIndex", 0) >= number_at(_payload, "stepCount", 0) - 1


func blocked_reason() -> String:
	return _blocked.text


func _render(payload: Dictionary) -> void:
	_header.set_title(text_at(payload, "lessonTitle"))
	_header.set_subtitle(text_at(payload, "stepTitle"))
	_body.set_markdown(text_at(payload, "body"))

	var index := number_at(payload, "stepIndex", 0)
	var count := number_at(payload, "stepCount", 0)
	# The step the learner is ON is one-based to them and zero-based on the
	# wire. Showing "Step 0 of 6" is the classic way to look broken.
	_progress.set_step(index + 1 if count > 0 else 0, count,
		flag_at(payload, "snapProgress"))

	_badge.set_count(number_at(payload, "comboCount", 0))

	var counts := check_counts()
	if counts[1] == 0:
		_strip.reset()
	else:
		_strip.report(counts[0], counts[1], _first_outstanding())

	_hint.set_cost(number_at(payload, "hintCost", HintButton.DEFAULT_GEM_COST))
	_hint.visible = flag_at(payload, "hasHints")

	# ONLY WHERE IT MEANS SOMETHING. A Run button on a step that reads the
	# project rather than a run is an offer to do something that cannot help,
	# and the learner who takes it up concludes the panel ignored them.
	_run.visible = flag_at(payload, "needsPlayRun")
	# THE WAIT IS NOT ENDED BY A RENDER, and it used to be. Every answer
	# re-renders this view -- including the recheck the shell runs every two
	# seconds while the player is showing -- so the button came back about two
	# seconds after launch, while Godot was still opening the game. Pressing it
	# again is refused by the runner through a return value nothing surfaces, so
	# the second press does nothing and says nothing.
	#
	# The shell releases it when the window actually reports, or when the report
	# could not be sent. See `release_run`.

	_back.disabled = index <= 0
	_render_next(counts)


func _render_next(counts: Array) -> void:
	var advance := can_advance()
	_next.disabled = not advance
	_next.text = LAST_STEP_COPY if is_last_step() else "Next"

	# THE REASON, NOT JUST THE GREY. A disabled Next with nothing beside it is
	# the most common way a tutorial loses somebody: they cannot tell whether
	# they did it wrong or whether the plugin stopped working.
	if advance:
		_blocked.visible = false
		_blocked.text = ""
		return
	var outstanding := _first_outstanding()
	_blocked.text = outstanding if outstanding != "" else BLOCKED_COPY
	_blocked.visible = true


## What to tell somebody who cannot move on: the first check that is not
## satisfied, in the author's own words.
func _first_outstanding() -> String:
	for check in rows_at(_payload, "checks"):
		if flag_at(check, "passing"):
			continue
		var note := text_at(check, "note")
		if note != "":
			return note
		var label := text_at(check, "label")
		if label != "":
			return label
	return ""


## Start a window, and say so until one comes back.
##
## DISABLED WHILE IT RUNS, because a second press would be refused by the runner
## with a message the learner never sees -- one game at a time, since two
## watching the same project share a nonce and interleave into one buffer that
## describes neither run.
func _on_run() -> void:
	_set_running(true)
	# WHAT TO WATCH TRAVELS WITH THE PRESS. The observer only watches objects it
	# was asked about, and the names live in the step's verifier arguments --
	# which are Core's, on the far side of the wire. A window opened without
	# them answers "not observed" for a game that did exactly the right thing,
	# which reads to a learner as being ignored.
	var raw = _payload.get("playWatch", {})
	# WHICH RUN THIS IS, captured at the press. The game may outlive the step:
	# the learner can press Back, switch tabs, or open another lesson while it
	# runs, and a report with no identity is credited to wherever they ended up.
	send(COMMAND_RUN, {
		"watch": raw if raw is Dictionary else {},
		"lessonId": text_at(_payload, "lessonId"),
		"stepIndex": number_at(_payload, "stepIndex", 0),
	})


## The window has reported, or cannot. Give the button back.
##
## CALLED BY THE SHELL, not by a render: only the shell knows whether an arriving
## payload is this window's answer or the two-second recheck passing through.
func release_run() -> void:
	_set_running(false)


func _set_running(running: bool) -> void:
	if _run == null:
		return
	_run.disabled = running
	# THE COPY IS THE ONLY FEEDBACK THERE IS. Launching Godot takes seconds, and
	# a button that greys with no explanation is indistinguishable from one that
	# failed.
	_run.text = "Running..." if running else "Run your game"


## Whether the panel is waiting on a window. For tests.
func is_running_window() -> bool:
	return _run != null and _run.disabled


func _on_next() -> void:
	if not can_advance():
		# A PRESS THAT CANNOT SUCCEED STILL MEANS SOMETHING: they are trying, so
		# ask for a re-check rather than doing nothing. The checks run on a
		# cadence, and the press is a learner saying "look now".
		send(COMMAND_RECHECK)
		return
	send(COMMAND_NEXT, {"stepIndex": number_at(_payload, "stepIndex", 0)})


func _on_hint(gem_cost: int) -> void:
	send(COMMAND_HINT, {
		"stepIndex": number_at(_payload, "stepIndex", 0),
		"gemCost": gem_cost,
	})


func _on_term(term: String) -> void:
	send(COMMAND_GLOSSARY, {"term": term})


# THERE IS NO `on_hidden` HERE, AND ITS ABSENCE IS THE FIX.
#
# It used to send COMMAND_LEAVE, on the reading that being hidden means the
# learner has gone. It does not: the router hides this view for the HINTS and
# the GLOSSARY too, and both of those are part of the walkthrough. The sidecar
# answers `walkthrough.leave` by forgetting the run, so opening a hint threw
# away the walkthrough the hint belonged to -- the reveal then returned an empty
# page, no gems were spent, nothing was said, and coming back to the player
# reported "nothing open".
#
# A view cannot tell where it is going. The shell can, because it is what
# decided, so `shell.gd` sends the leave on the transitions that really are one.
