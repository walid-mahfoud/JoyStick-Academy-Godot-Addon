@tool
extends HBoxContainer

## What the checks under a walkthrough step currently say.
##
## Three states, one line of text and a coloured dot. It is the only thing on
## the step that changes while the learner works in the editor, so it is also
## the only thing telling them the plugin is watching at all.
##
## IDLE IS NOT A FAILURE, AND THE COPY CARRIES THAT. Before the first poll fires
## every check is unevaluated, and a strip that opened on "Nothing passes yet"
## would greet a learner with a red verdict on work they have not started. It
## opens on "Get started!" -- the same words the other two engines use, because
## a learner moving between them should not meet a different tone.
##
## THE DOT IS A CHARACTER, NOT A TEXTURE. An emoji needs no asset, no import
## step and no theme entry, and it is what the shared implementation uses. The
## colour is carried by the character itself, so a theme that changes the label
## colour cannot accidentally make the verdict unreadable.

signal state_changed(state: int)

enum State {
	## No check has been evaluated yet.
	IDLE,
	## Some pass, some do not.
	PROGRESS,
	## Everything the step asks for is satisfied.
	PASS,
}

const IDLE_COPY := "Get started!"
const PASS_COPY := "Looks good!"

const IDLE_DOT := "🔴"
const PROGRESS_DOT := "🟡"
const PASS_DOT := "🟢"

var _dot: Label = null
var _label: Label = null
var _state: int = State.IDLE


func _init() -> void:
	name = "VerifierStrip"
	add_theme_constant_override("separation", 6)

	_dot = Label.new()
	_dot.name = "Dot"
	add_child(_dot)

	_label = Label.new()
	_label.name = "Verdict"
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_label)

	_refresh()


func state() -> int:
	return _state


func text() -> String:
	return _label.text


## Report how many of the step's checks are satisfied.
##
## `note` is what the PROGRESS state says -- typically "2 of 5 checks pass" --
## and is ignored in the other two, which have fixed copy. A caller that has no
## note gets a count instead.
func report(passing: int, total: int, note := "") -> void:
	if total <= 0:
		# A STEP WITH NO CHECKS IS NOT A STEP THAT PASSED. It advances freely --
		# that is the decided behaviour the player implements -- but the strip
		# must not claim a verdict nobody reached.
		_set_state(State.IDLE)
		return
	if passing >= total:
		_set_state(State.PASS)
		return
	_set_state(State.PROGRESS, note if note != "" else "%d of %d checks pass" % [
		clampi(passing, 0, total), total])


## Back to the opening state, for a step the learner has just arrived on.
func reset() -> void:
	_set_state(State.IDLE)


func _set_state(next: int, note := "") -> void:
	var changed := next != _state
	_state = next
	match _state:
		State.PASS:
			_dot.text = PASS_DOT
			_label.text = PASS_COPY
		State.PROGRESS:
			_dot.text = PROGRESS_DOT
			_label.text = note
		_:
			_dot.text = IDLE_DOT
			_label.text = IDLE_COPY
	if changed:
		state_changed.emit(_state)


func _refresh() -> void:
	_set_state(_state)
