@tool
extends VBoxContainer

## "Step N of M", with a fill that catches up rather than jumping.
##
## THE DISCRETE VALUE AND THE DRAWN ONE ARE DIFFERENT NUMBERS, and keeping them
## apart is the whole design. `current` is what the learner is on and what the
## label says; `displayed_ratio` is where the bar has got to. Advancing sets the
## first immediately and lets the second travel, so the label is never a frame
## behind the truth while the bar still animates.
##
## PORTED FROM THE SHARED ONE, INCLUDING ITS RATE. A step of 1/30 per tick over
## ticks of 10 ms is roughly a third of a second end to end; the same authored
## walkthrough should feel the same on three engines, so the number is copied
## rather than chosen.
##
## NO SCENE FILE. Built in code, like the rest of this addon's components. A
## hand-editable .tscn for something this small is a second place for the layout
## to drift, and a sub-resource id lost in a merge produces a scene that loads
## with the node missing and a test that fails nowhere near the cause.

## How much of the remaining distance the fill covers per tick.
const LERP_STEP := 1.0 / 30.0

## How often the fill advances, in seconds.
const LERP_INTERVAL := 0.01

var _label: Label = null
var _bar: ProgressBar = null
var _timer: Timer = null

var _current := 0
var _total := 0
var _displayed_ratio := 0.0


func _init() -> void:
	name = "StepProgressBar"
	add_theme_constant_override("separation", 4)

	_label = Label.new()
	_label.name = "StepLabel"
	add_child(_label)

	_bar = ProgressBar.new()
	_bar.name = "StepFill"
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.value = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 6)
	add_child(_bar)

	_refresh()


func _ready() -> void:
	# THE TIMER IS CREATED HERE, NOT IN _init. A Timer added before the node is
	# in the tree never starts, and the symptom is a bar that is simply always
	# at zero -- which reads as a layout problem.
	if _timer != null:
		return
	_timer = Timer.new()
	_timer.name = "LerpTimer"
	_timer.wait_time = LERP_INTERVAL
	_timer.one_shot = false
	_timer.timeout.connect(_advance)
	add_child(_timer)
	if not is_equal_approx(_displayed_ratio, target_ratio()):
		_timer.start()


## Which step the learner is on.
func current() -> int:
	return _current


## How many there are.
func total() -> int:
	return _total


## Where the bar has actually got to, 0 to 1.
func displayed_ratio() -> float:
	return _displayed_ratio


## Where the bar is heading.
##
## ZERO WHEN THERE ARE NO STEPS, rather than a division by zero. A walkthrough
## with no steps is a real thing -- an author mid-edit -- and it must render as
## an empty bar rather than take the dock down.
func target_ratio() -> float:
	if _total <= 0:
		return 0.0
	return clampf(float(_current) / float(_total), 0.0, 1.0)


## Move to a step.
##
## `snap` puts the fill there immediately, which is what a jump to a resumed
## step wants: travelling across six steps of somebody else's progress is an
## animation of something that did not happen.
func set_step(current_step: int, total_steps: int, snap := false) -> void:
	_total = maxi(0, total_steps)
	_current = clampi(current_step, 0, _total)
	if snap:
		_displayed_ratio = target_ratio()
	_refresh()
	if _timer != null and not is_equal_approx(_displayed_ratio, target_ratio()):
		_timer.start()


## One tick of the fill. Public so a test can drive it without waiting.
func advance_for_test() -> void:
	_advance()


func _advance() -> void:
	var target := target_ratio()
	if absf(_displayed_ratio - target) < LERP_STEP:
		# CLOSE ENOUGH IS ARRIVED. Without this the fill creeps toward the
		# target forever in ever-smaller steps and the timer never stops, which
		# costs a wake-up every ten milliseconds for the life of the editor.
		_displayed_ratio = target
		if _timer != null:
			_timer.stop()
	else:
		_displayed_ratio = move_toward(_displayed_ratio, target, LERP_STEP)
	_refresh_bar()


func _refresh() -> void:
	_label.text = "Step %d of %d" % [_current, _total]
	_refresh_bar()


func _refresh_bar() -> void:
	_bar.value = clampf(_displayed_ratio, 0.0, 1.0) * 100.0
