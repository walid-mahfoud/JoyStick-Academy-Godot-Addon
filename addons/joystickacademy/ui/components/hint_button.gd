@tool
extends Button

## "💎 5" — the gem-cost hint button.
##
## THE COST IS SET BY THE CALLER, NOT DECIDED HERE, and that is the important
## boundary. Who is premium, how many free hints they have had this walkthrough,
## and what a hint costs today are all questions the session answers; this
## renders a number and reports a press. Deciding any of it here would put the
## economy in a widget, where nothing can see it.
##
## FREE IS A WORD, NOT A ZERO. A button reading "💎 0" looks broken -- the
## learner reads it as having no gems rather than as owing none -- so a cost of
## zero shows "FREE". That is the mobile app's wording and the other engines'.
##
## WHAT IT REPORTS IS THE COST AT THE MOMENT OF THE PRESS. The signal carries it
## rather than leaving the handler to read it back, because between the press
## and the handler the caller may already have changed it -- premium's one free
## hint is consumed by the very press being reported.

signal hint_requested(gem_cost: int)

const DEFAULT_GEM_COST := 5
const FREE_COPY := "FREE"

var _cost := DEFAULT_GEM_COST


func _init() -> void:
	name = "HintButton"
	_refresh()
	pressed.connect(_on_pressed)


func cost() -> int:
	return _cost


## Set what the next hint costs. Negative is treated as free.
func set_cost(gem_cost: int) -> void:
	_cost = maxi(0, gem_cost)
	_refresh()


func _on_pressed() -> void:
	hint_requested.emit(_cost)


func _refresh() -> void:
	text = FREE_COPY if _cost <= 0 else "💎 %d" % _cost
