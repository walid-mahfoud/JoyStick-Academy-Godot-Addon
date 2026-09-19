@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 36. The hints for this step, and what the next one costs.
##
## HINTS ARE REVEALED IN ORDER AND STAY REVEALED. A learner who paid for one and
## then navigated away has paid; hiding it again would either charge them twice
## or make them think they lost it. The payload carries how many are open, which
## is the sidecar's record rather than this view's memory.
##
## THE COST IS SHOWN BEFORE THE PRESS, NOT AFTER. Gems are real -- they are
## bought -- and a button that spends them without saying how many is the kind
## of thing that gets a plugin uninstalled. The next hint's price is on the
## button itself.
##
## RUNNING OUT IS A STATE WITH ITS OWN COPY. "No more hints" is different from
## "this step has no hints", and different again from "you cannot afford the
## next one". Collapsing them tells a learner who is short of gems that the
## author wrote nothing.

const HintButton := preload("res://addons/joystickacademy/ui/components/hint_button.gd")
const RichMarkdownBlock := preload("res://addons/joystickacademy/ui/components/rich_markdown_block.gd")
const Header := preload("res://addons/joystickacademy/ui/components/header.gd")

const COMMAND_REVEAL := "hints.reveal"
const COMMAND_BUY_GEMS := "hints.buy_gems"
const COMMAND_GLOSSARY := "hints.glossary"

const NONE_AUTHORED_COPY := "This step has no hints. The check strip says what " \
	+ "is still outstanding."
const ALL_REVEALED_COPY := "That is every hint for this step."

var _header: Control = null
var _revealed: VBoxContainer = null
var _status: Label = null
var _button: Control = null
var _buy: Button = null


func _init() -> void:
	name = "HintsView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)
	_header.set_title("Hints")

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_revealed = VBoxContainer.new()
	_revealed.name = "Revealed"
	_revealed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_revealed.add_theme_constant_override("separation", 8)
	scroll.add_child(_revealed)

	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.visible = false
	add_child(_status)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)
	add_child(actions)

	_button = HintButton.new()
	actions.add_child(_button)

	_buy = Button.new()
	_buy.name = "BuyGems"
	_buy.text = "Get gems"
	_buy.visible = false
	actions.add_child(_buy)

	_button.hint_requested.connect(_on_reveal)
	_buy.pressed.connect(func(): send(COMMAND_BUY_GEMS))


## How many hints are open, and how many there are.
func revealed_count() -> int:
	return _revealed.get_child_count()


func hint_count() -> int:
	return rows_at(_payload, "hints").size()


func status_text() -> String:
	return _status.text


func can_reveal() -> bool:
	return _button.visible and not _button.disabled


func _render(payload: Dictionary) -> void:
	var hints := rows_at(payload, "hints")
	var revealed := number_at(payload, "revealedCount", 0)
	var gems := number_at(payload, "gems", 0)
	var cost := number_at(payload, "nextCost", HintButton.DEFAULT_GEM_COST)

	_header.set_subtitle(text_at(payload, "stepTitle"))

	for child in _revealed.get_children():
		child.free()
	for i in mini(revealed, hints.size()):
		var block = RichMarkdownBlock.new()
		_revealed.add_child(block)
		block.set_markdown(text_at(hints[i], "body"))
		block.glossary_term_clicked.connect(_on_term)

	_button.set_cost(cost)
	_render_status(hints.size(), revealed, gems, cost)


func _render_status(total: int, revealed: int, gems: int, cost: int) -> void:
	# THREE DIFFERENT RUNNING-OUTS, and collapsing them tells a learner who is
	# short of gems that the author wrote nothing.
	if total == 0:
		_status.text = NONE_AUTHORED_COPY
		_status.visible = true
		_button.visible = false
		_buy.visible = false
		return

	if revealed >= total:
		_status.text = ALL_REVEALED_COPY
		_status.visible = true
		_button.visible = false
		_buy.visible = false
		return

	_button.visible = true
	if cost > gems:
		_status.text = "The next hint costs %d gems and you have %d." % [cost, gems]
		_status.visible = true
		_button.disabled = true
		_buy.visible = true
		return

	_status.visible = false
	_button.disabled = false
	_buy.visible = false


func _on_reveal(gem_cost: int) -> void:
	send(COMMAND_REVEAL, {
		"stepIndex": number_at(_payload, "stepIndex", 0),
		"index": number_at(_payload, "revealedCount", 0),
		"gemCost": gem_cost,
	})


func _on_term(term: String) -> void:
	send(COMMAND_GLOSSARY, {"term": term})
