@tool
extends PanelContainer

## A message that says its piece and goes away.
##
## THREE KINDS, AND THE DIFFERENCE IS NOT DECORATION. An error that looks like
## an info line is an error nobody reads; a success that looks like an error is
## a learner who thinks they broke something. The kind is carried as data so a
## caller cannot forget to say which it is.
##
## IT HIDES ITSELF, AND THAT IS THE PART WITH A TRAP IN IT. A Timer added to a
## node that is not in the tree never fires, so a toast built and shown in the
## same breath as its parent would stay on screen forever. The timer is created
## on entering the tree and a show requested before that is remembered and
## started when it can be.
##
## A SECOND SHOW REPLACES THE FIRST rather than queueing. Two messages a tenth
## of a second apart are one event as far as the learner is concerned, and a
## queue would leave the second still on screen long after its moment.

signal dismissed()

enum Kind { INFO, SUCCESS, ERROR }

const DEFAULT_SECONDS := 4.0

## The marks that carry the kind. Characters rather than textures: no asset, no
## import step, no theme entry, and the same three the other engines use.
const MARKS := {
	Kind.INFO: "•",
	Kind.SUCCESS: "✓",
	Kind.ERROR: "✕",
}

var _mark: Label = null
var _label: Label = null
var _timer: Timer = null

var _kind: int = Kind.INFO
## A show asked for before this was in the tree, waiting for a timer to exist.
var _pending_seconds := 0.0


func _init() -> void:
	name = "Toast"
	visible = false

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_mark = Label.new()
	_mark.name = "Mark"
	row.add_child(_mark)

	_label = Label.new()
	_label.name = "Message"
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_label)


func _ready() -> void:
	if _timer == null:
		_timer = Timer.new()
		_timer.name = "DismissTimer"
		_timer.one_shot = true
		_timer.timeout.connect(hide_toast)
		add_child(_timer)
	if _pending_seconds > 0.0:
		_start(_pending_seconds)
		_pending_seconds = 0.0


func message() -> String:
	return _label.text


func kind() -> int:
	return _kind


func is_showing() -> bool:
	return visible


## Show `text`. A duration of zero or less stays until something hides it.
func show_toast(text: String, toast_kind: int = Kind.INFO,
		seconds := DEFAULT_SECONDS) -> void:
	_kind = toast_kind if MARKS.has(toast_kind) else Kind.INFO
	_mark.text = MARKS[_kind]
	_label.text = text
	visible = true

	if seconds <= 0.0:
		if _timer != null:
			_timer.stop()
		return

	if _timer == null:
		# Not in the tree yet. Remember it; _ready will start it.
		_pending_seconds = seconds
		return
	_start(seconds)


func hide_toast() -> void:
	if not visible:
		return
	visible = false
	if _timer != null:
		_timer.stop()
	dismissed.emit()


## Fire the dismissal now, for a test that will not wait four seconds.
func dismiss_for_test() -> void:
	hide_toast()


func _start(seconds: float) -> void:
	_timer.stop()
	_timer.wait_time = seconds
	_timer.start()
