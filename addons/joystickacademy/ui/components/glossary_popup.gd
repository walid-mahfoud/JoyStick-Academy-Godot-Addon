@tool
extends PanelContainer

## One term, its definition, and the terms it leads to.
##
## THE CLOSE IS REPORTED, NOT PERFORMED. Whether this is dismissed by its own ✕,
## by a click outside it, or by the view navigating away is the view's business
## -- it owns the overlay and knows what else is on screen. A popup that removed
## itself would fight whatever put it there.
##
## RELATED TERMS REPLACE RATHER THAN STACK. Following three terms in a row
## leaves three popups on top of each other, and closing them one at a time to
## get back to the step is nobody's idea of reading. Each chip reports the term
## and the caller re-binds this same popup.
##
## A TERM WITH NO DEFINITION STILL OPENS. The dictionary is seeded separately
## from the content, so a term an author tagged before it was seeded is an
## ordinary state -- and a tap that does nothing at all reads as a broken plugin
## rather than as a gap in the glossary.

signal dismissed()
signal related_term_clicked(term: String)

const RichMarkdownBlock := preload("res://addons/joystickacademy/ui/components/rich_markdown_block.gd")

const MISSING_COPY := "No definition yet for this term."

var _term := ""

var _title: Label = null
var _definition: Control = null
var _related: HFlowContainer = null
var _close: Button = null


func _init() -> void:
	name = "GlossaryPopup"

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 6)
	add_child(column)

	var head := HBoxContainer.new()
	head.name = "Head"
	column.add_child(head)

	_title = Label.new()
	_title.name = "Term"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)

	_close = Button.new()
	_close.name = "Close"
	_close.text = "✕"
	_close.flat = true
	head.add_child(_close)

	_definition = RichMarkdownBlock.new()
	_definition.name = "Definition"
	column.add_child(_definition)

	_related = HFlowContainer.new()
	_related.name = "Related"
	column.add_child(_related)

	_close.pressed.connect(func(): dismissed.emit())


func term() -> String:
	return _term


func definition_markdown() -> String:
	return _definition.markdown()


## The related terms currently offered, in order.
func related_terms() -> Array:
	var out: Array = []
	for child in _related.get_children():
		out.append((child as Button).text)
	return out


## `entry` is {"term": String, "definition": String, "related": Array}. An empty
## or absent entry is the not-yet-seeded case, not an error.
func bind(entry: Dictionary) -> void:
	var safe: Dictionary = entry if entry != null else {}
	_term = str(safe.get("term", ""))
	_title.text = _term

	var definition := str(safe.get("definition", ""))
	_definition.set_markdown(definition if definition != "" else MISSING_COPY)

	for child in _related.get_children():
		child.free()
	var related = safe.get("related", [])
	if not (related is Array):
		return
	for related_name in related:
		if not (related_name is String) or related_name == "":
			continue
		if related_name == _term:
			# A TERM RELATED TO ITSELF is a seeding mistake that would otherwise
			# render a chip re-opening what is already open.
			continue
		var chip := Button.new()
		chip.name = "Related"
		chip.text = related_name
		chip.flat = true
		chip.pressed.connect(_on_related.bind(related_name))
		_related.add_child(chip)


## Close as though the ✕ had been pressed. For a view closing it from outside.
func dismiss() -> void:
	dismissed.emit()


func _on_related(related_name: String) -> void:
	related_term_clicked.emit(related_name)
