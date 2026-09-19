@tool
extends VBoxContainer

## Renders a step body: paragraphs, code blocks, bullets and tappable terms.
##
## IT OWNS NO RULES. Every decision about what the markdown MEANS lives in
## `markdown_tokenizer.gd`, which is pure and tested without a Control; this
## turns what that returns into nodes and BBCode and does nothing else. The
## split is what makes the rules testable at all.
##
## ONE RichTextLabel PER PARAGRAPH, AND THE FIRST VERSION OF THIS FILE HAD A
## FLOW OF PLAIN LABELS INSTEAD. That version's header said a click on a
## rich-text label "reports a position, not a run", so a glossary term had to be
## its own Button and a paragraph had to be a flow of pieces. MEASURED ON 4.5.1:
## that is false. `RichTextLabel.meta_clicked` carries the `[url=X]` payload
## verbatim -- `["Rigidbody", "Node"]` came back from a two-term paragraph -- so
## a term can be a tappable run inside ordinary wrapping text.
##
## THE COST OF BELIEVING IT WAS WORSE THAN A CLUMSY TAP. `Label.autowrap_mode`
## defaults to AUTOWRAP_OFF, and a paragraph with no inline markup is ONE label,
## so it had no piece boundaries to wrap at and simply ran off the side of a
## 240px dock. The old header called the wrapping a known cost of the tap; it
## was a defect the tap did not require.
##
## SO: one wrapping label per paragraph, terms as `[url]`, and the tap reports
## which term by name rather than by where it landed.
##
## A CODE BLOCK SCROLLS SIDEWAYS RATHER THAN WIDENING THE STEP. Its Label is
## deliberately not wrapped, so its minimum width is its longest line; a
## container takes its children's minimum as its own, and one long line
## therefore handed EVERY paragraph in the step a rect wider than the dock.
## MEASURED at a 240px dock: 441px and three lines with a code block against
## 240px and four lines without one. The paragraphs never stopped wrapping --
## they wrapped to a width nobody could see.
##
## BULLETS ARE DRAWN, NOT PARSED. The shared tokenizer has no list block -- two
## kinds, text and code -- and adding one here would be a rule this engine has
## and the other two do not, which a content author meets as "it looks wrong on
## one engine". A `- ` at the start of a line is left as plain text by the
## tokenizer and given a bullet glyph and an indent HERE, which changes how it
## looks and not what it means.

signal glossary_term_clicked(term: String)

const Tokenizer := preload("res://addons/joystickacademy/ui/components/markdown_tokenizer.gd")

## What each child is, independent of its node name.
##
## GODOT UNIQUIFIES DUPLICATE SIBLING NAMES -- a second child called "Paragraph"
## becomes "Paragraph2" -- so anything identifying nodes by name works for the
## first one and silently stops at the second.
const KIND_META := "jsa_kind"
const KIND_PARAGRAPH := "paragraph"
const KIND_CODE_BLOCK := "code_block"

## What a bullet line is replaced with. Two spaces in front so the glyph sits
## off the margin, two behind so the text does not touch it.
const BULLET := "  •  "

## A line that opens a bullet. `-` or `*`, then whitespace.
const _BULLET_LINE := "(^|\\n)[ \\t]*[-*][ \\t]+"

var _markdown := ""
var _terms: Array = []


func _init() -> void:
	name = "RichMarkdownBlock"
	add_theme_constant_override("separation", 8)


func markdown() -> String:
	return _markdown


## What this block rendered, in order: KIND_PARAGRAPH or KIND_CODE_BLOCK.
func block_kinds() -> Array:
	var out: Array = []
	for child in get_children():
		out.append(str(child.get_meta(KIND_META, "")))
	return out


## Every glossary term rendered, in source order. For tests, and for a caller
## that wants to pre-fetch definitions.
func glossary_terms() -> Array:
	return _terms.duplicate()


## The paragraph labels, in order.
##
## FOR TESTS, WHICH HAVE NO MOUSE. A term is tapped in production by Godot
## emitting `meta_clicked` on the label the click landed in; a test emits the
## same signal with the same payload, which is the honest simulation of it.
func paragraphs() -> Array:
	var out: Array = []
	for child in get_children():
		if str(child.get_meta(KIND_META, "")) == KIND_PARAGRAPH:
			out.append(child)
	return out


## The BBCode of one paragraph, for tests.
func bbcode_at(index: int) -> String:
	var found := paragraphs()
	if index < 0 or index >= found.size():
		return ""
	return (found[index] as RichTextLabel).text


func set_markdown(text: String) -> void:
	_markdown = text
	_terms = []
	for child in get_children():
		child.free()

	for block in Tokenizer.split_blocks(text):
		if block["kind"] == Tokenizer.KIND_CODE:
			_add_code(block["text"])
			continue
		for paragraph in Tokenizer.split_paragraphs(block["text"]):
			_add_paragraph(paragraph)


## Turn one paragraph's inline runs into BBCode.
##
## PURE AND STATIC, so the conversion can be tested without a Control -- which
## matters because this is where the escaping lives and escaping is where this
## kind of code goes wrong.
##
## EVERY PIECE OF AUTHORED TEXT IS ESCAPED. A `[` in prose or, far more often,
## in a code span -- `get_node("[Player]")`, an array index, a Godot annotation
## -- would otherwise open a BBCode tag and swallow the rest of the line. That
## is the exact failure Unreal's lesson describes: a tagging syntax arriving in
## prose before the renderer handles it corrupts the line it is in.
static func to_bbcode(runs: Array) -> String:
	var out := ""
	for run in runs:
		var text := str(run.get("text", ""))
		match str(run.get("kind", Tokenizer.RUN_PLAIN)):
			Tokenizer.RUN_GLOSSARY:
				# THE TERM IS THE PAYLOAD, so a tap reports which word was
				# tapped rather than where the click landed.
				out += "[url=%s][b]%s[/b][/url]" % [_escape(text), _escape(text)]
			Tokenizer.RUN_CODE:
				out += "[code]%s[/code]" % _escape(text)
			Tokenizer.RUN_BOLD:
				out += "[b]%s[/b]" % _escape(text)
			Tokenizer.RUN_ITALIC:
				out += "[i]%s[/i]" % _escape(text)
			_:
				out += _bullets(_escape(text))
	return out


## A `[` that is not ours has to stop being a tag opener.
static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")


## Give any line that starts with `-` or `*` a bullet and an indent.
##
## ONLY IN PLAIN RUNS. A hyphen inside a code span is a minus sign, and one
## inside an emphasised run is part of what the author emphasised.
static func _bullets(text: String) -> String:
	var line := RegEx.create_from_string(_BULLET_LINE)
	return line.sub(text, "$1" + BULLET, true)


func _add_code(source: String) -> void:
	var panel := PanelContainer.new()
	panel.name = "CodeBlock"
	panel.set_meta(KIND_META, KIND_CODE_BLOCK)

	# THE SCROLLER IS WHAT KEEPS ONE LONG LINE FROM WIDENING THE WHOLE STEP.
	# A ScrollContainer's own minimum width does not grow with what it holds, so
	# the long line becomes a sideways scroll inside the code block instead of a
	# wider rect handed to every paragraph beside it.
	var scroller := ScrollContainer.new()
	scroller.name = "Scroller"
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# Vertical NEVER: the step already scrolls, and a second vertical bar for
	# four lines of code is the two-scrollbars-for-one-body problem the
	# paragraph labels avoid with fit_content.
	scroller.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroller.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.name = "Source"
	label.text = source
	# NOT autowrapped. Wrapping code changes what it says: an indented
	# continuation reads as a new statement, and a learner copying it out gets
	# something that does not run. Sideways scrolling is the honest way to show
	# a line too long for the dock.
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	scroller.add_child(label)
	panel.add_child(scroller)
	add_child(panel)

	# A ScrollContainer claims no height of its own, so ask the code how tall it
	# is and hold exactly that. Height is safe to inherit; width is what had to
	# stop being inherited.
	scroller.custom_minimum_size = Vector2(0, label.get_minimum_size().y)


func _add_paragraph(paragraph: String) -> void:
	var runs := Tokenizer.tokenize_inline(paragraph)
	for run in runs:
		if str(run.get("kind", "")) == Tokenizer.RUN_GLOSSARY:
			_terms.append(str(run.get("text", "")))

	var label := RichTextLabel.new()
	label.name = "Paragraph"
	label.set_meta(KIND_META, KIND_PARAGRAPH)
	label.bbcode_enabled = true
	# FIT_CONTENT PLUS WORD WRAP is the pair that makes a paragraph behave like
	# text in a narrow dock: wrap at word boundaries, and be as tall as that
	# takes. Without fit_content a RichTextLabel takes a fixed height and
	# scrolls its own content, which inside a scrolling panel is two scrollbars
	# for one body.
	label.fit_content = true
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Selectable, so a learner can copy a line into a search or a bug report.
	label.selection_enabled = true
	label.text = to_bbcode(runs)
	add_child(label)

	label.meta_clicked.connect(func(meta): glossary_term_clicked.emit(str(meta)))
