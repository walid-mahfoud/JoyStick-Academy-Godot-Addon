@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 35. The terms, searchable, and whatever the learner last tapped.
##
## IT IS A VIEW AND NOT ONLY A POPUP BECAUSE OF THE SECOND USE. Tapping a term
## in a step wants the popup: small, over the thing you were reading, gone in a
## second. Wanting to know what a term means when you are NOT mid-step wants a
## page you can search -- and building only the popup means the second learner
## has nowhere to go.
##
## SEARCH FILTERS WHAT IS ALREADY HERE. The dictionary is a few hundred entries
## and arrives whole, so filtering is a string match over a list rather than a
## request; a view that asked the sidecar per keystroke would be slower and
## would stop working the moment the helper did.
##
## NO RESULTS IS NOT AN ERROR, AND SAYS WHAT WAS SEARCHED FOR. A learner who
## mistypes a term needs to see their own spelling back.

const GlossaryPopup := preload("res://addons/joystickacademy/ui/components/glossary_popup.gd")
const Header := preload("res://addons/joystickacademy/ui/components/header.gd")

const COMMAND_OPEN_TERM := "glossary.open_term"

var _header: Control = null
var _search: LineEdit = null
var _results: VBoxContainer = null
var _empty: Label = null
var _detail: Control = null

var _query := ""


func _init() -> void:
	name = "GlossaryView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)
	_header.set_title("Glossary")

	_search = LineEdit.new()
	_search.name = "Search"
	_search.placeholder_text = "Search terms"
	_search.clear_button_enabled = true
	add_child(_search)

	_detail = GlossaryPopup.new()
	_detail.visible = false
	add_child(_detail)

	_empty = Label.new()
	_empty.name = "Empty"
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.visible = false
	add_child(_empty)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_results = VBoxContainer.new()
	_results.name = "Results"
	_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_results)

	_search.text_changed.connect(_on_search)
	_detail.dismissed.connect(_close_detail)
	_detail.related_term_clicked.connect(select_term)


## The term names currently listed, in order.
func visible_terms() -> Array:
	var out: Array = []
	for child in _results.get_children():
		out.append((child as Button).text)
	return out


func query() -> String:
	return _query


func selected_term() -> String:
	return _detail.term() if _detail.visible else ""


## Match rule, on its own so it can be tested without a view.
##
## CASE-INSENSITIVE SUBSTRING, over the term AND its definition. A learner
## searching "gravity" should find `RigidBody2D` even though the word is only in
## the body: they are describing what they want, not naming it.
static func matches(entry: Dictionary, query: String) -> bool:
	if query == "":
		return true
	var needle := query.strip_edges().to_lower()
	if needle == "":
		return true
	if str(entry.get("term", "")).to_lower().contains(needle):
		return true
	return str(entry.get("definition", "")).to_lower().contains(needle)


## Open a term's definition. Also what a related chip calls.
func select_term(term: String) -> void:
	for entry in rows_at(_payload, "terms"):
		if str(entry.get("term", "")) == term:
			_detail.bind(entry)
			_detail.visible = true
			send(COMMAND_OPEN_TERM, {"term": term})
			return
	# A term that is not in the dictionary still opens, saying so. See
	# glossary_popup.gd: a tap that does nothing reads as a broken plugin.
	_detail.bind({"term": term})
	_detail.visible = true
	send(COMMAND_OPEN_TERM, {"term": term})


func _render(payload: Dictionary) -> void:
	var terms := rows_at(payload, "terms")
	_header.set_subtitle("%d term" % terms.size() if terms.size() == 1
		else "%d terms" % terms.size())

	for child in _results.get_children():
		child.free()

	var shown := 0
	for entry in terms:
		if not matches(entry, _query):
			continue
		shown += 1
		var button := Button.new()
		button.name = "Term"
		button.text = str(entry.get("term", ""))
		button.flat = true
		button.pressed.connect(select_term.bind(button.text))
		_results.add_child(button)

	if shown > 0:
		_empty.visible = false
		return

	_empty.visible = true
	if terms.is_empty():
		_empty.text = "The glossary has not arrived yet."
	else:
		# THEIR OWN SPELLING BACK, because a mistype is the commonest reason to
		# find nothing and the learner cannot see it otherwise.
		_empty.text = "No term matches \"%s\"." % _query

	# A detail sheet left open over a list that no longer contains it is a
	# a learner reading about something they have filtered away.
	if _detail.visible and _query != "" and shown == 0:
		_close_detail()


func _on_search(text: String) -> void:
	_query = text
	_render(_payload)


func _close_detail() -> void:
	_detail.visible = false
