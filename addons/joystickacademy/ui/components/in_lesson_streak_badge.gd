@tool
extends HBoxContainer

## 🔥 N, while a run of consecutive passes is going.
##
## HIDDEN BELOW THREE, which is the mobile app's threshold and is copied rather
## than chosen. A badge that appears on the first correct answer is a badge that
## is always there, and a thing that is always there stops being a reward; three
## is the point at which the learner has done something a little unusual.
##
## THE CALLER OWNS THE COUNT. This does not watch checks, does not know what a
## pass is, and has no timer. It is told a number and decides whether to be
## visible -- which is the whole of it, and is why it can be tested without an
## editor.

const VISIBILITY_THRESHOLD := 3

var _flame: Label = null
var _count_label: Label = null
var _count := 0


func _init() -> void:
	name = "InLessonStreakBadge"
	add_theme_constant_override("separation", 2)

	_flame = Label.new()
	_flame.name = "Flame"
	_flame.text = "🔥"
	add_child(_flame)

	_count_label = Label.new()
	_count_label.name = "Count"
	add_child(_count_label)

	_refresh()


func count() -> int:
	return _count


## Whether the badge is showing. Read rather than inferred from `visible`, so a
## test does not have to know which node carries the visibility.
func is_showing() -> bool:
	return _count >= VISIBILITY_THRESHOLD


func set_count(value: int) -> void:
	# NEGATIVE IS ZERO, not a hidden badge with a negative label. A caller
	# resetting a streak with -1 is a caller with a bug, and clamping keeps that
	# bug out of what the learner sees.
	_count = maxi(0, value)
	_refresh()


func _refresh() -> void:
	_count_label.text = str(_count)
	visible = is_showing()
