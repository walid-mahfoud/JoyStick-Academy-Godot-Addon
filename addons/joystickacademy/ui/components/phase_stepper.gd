@tool
extends HBoxContainer

## Where the learner is in a sequence of named phases.
##
## THE POINT IS WHAT IS BEHIND AND AHEAD, not just where they are. A submission
## goes package, upload, grade, certificate, and somebody waiting on the third
## needs to see that two are done and one is left. A bare "Grading" says nothing
## about how much is over.
##
## AN INDEX OUTSIDE THE PHASES SELECTS NOTHING rather than clamping to an end.
## Clamping means a caller with an off-by-one lights the last phase and the
## learner is told the work finished. Nothing lit is visibly wrong, which is
## what a bug should look like.

const DONE_MARK := "●"
const CURRENT_MARK := "◉"
const TODO_MARK := "○"

var _labels: Array = []
var _active := -1


func _init() -> void:
	name = "PhaseStepper"
	add_theme_constant_override("separation", 10)


func phases() -> Array:
	return _labels.duplicate()


func active_index() -> int:
	return _active


## The marks currently shown, in order. For tests, and for a caller checking its
## own arithmetic against what a learner can see.
func marks() -> Array:
	var out: Array = []
	for child in get_children():
		out.append((child.get_node("Mark") as Label).text)
	return out


func set_phases(labels: Array) -> void:
	_labels = []
	for label in labels:
		# An unnamed phase is a gap in the sequence a learner cannot read, so it
		# is dropped rather than rendered as a mark with nothing beside it.
		if label is String and label != "":
			_labels.append(label)

	for child in get_children():
		child.free()
	for label in _labels:
		var item := HBoxContainer.new()
		item.name = "Phase"
		item.add_theme_constant_override("separation", 4)

		var mark := Label.new()
		mark.name = "Mark"
		item.add_child(mark)

		var text := Label.new()
		text.name = "Label"
		text.text = label
		item.add_child(text)

		add_child(item)
	_refresh()


func set_active_index(index: int) -> void:
	_active = index
	_refresh()


func _refresh() -> void:
	var children := get_children()
	var valid := _active >= 0 and _active < _labels.size()
	for i in children.size():
		var mark := children[i].get_node("Mark") as Label
		if not valid:
			mark.text = TODO_MARK
		elif i < _active:
			mark.text = DONE_MARK
		elif i == _active:
			mark.text = CURRENT_MARK
		else:
			mark.text = TODO_MARK
