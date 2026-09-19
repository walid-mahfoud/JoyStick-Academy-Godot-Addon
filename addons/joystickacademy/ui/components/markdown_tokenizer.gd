@tool
extends RefCounted

## Splits walkthrough step markdown into blocks, paragraphs and inline runs.
##
## PURE, AND SEPARATE FROM THE THING THAT DRAWS IT. Every rule here is a string
## rule, so it is testable without an editor, without a Control and without a
## theme -- which matters because the rules are where the bugs are and the
## drawing is where the test cost is. `rich_markdown_block.gd` turns what this
## returns into nodes and owns nothing else.
##
## A PORT OF THE SHARED ONE, RULE FOR RULE, and the fidelity is the point rather
## than the elegance. The same authored step body has to render the same way on
## Unity, Unreal and Godot, so a Godot-flavoured improvement here is a
## divergence a content author meets as "it looks wrong on one engine". Where
## this file differs from Unity's `MarkdownTokenizer`, it says so and why.
##
## THE ORDER OF THE TWO INLINE PASSES IS LOAD-BEARING. Code spans are tokenized
## BEFORE emphasis, so `` `**not bold**` `` stays literal; doing it the other way
## round makes a code sample containing asterisks render as emphasis, and code
## samples containing asterisks are ordinary in every language this teaches.
##
## AND WITHIN EMPHASIS, MOST SPECIFIC FIRST. `**term:X**` is tried before
## `**bold**`, which is tried before `*italic*`. Reversed, the glossary syntax --
## which is the whole of mobile Phase 25's term popups -- is swallowed as bold
## and the learner gets a bold word with no definition behind it.

## What a block is.
const KIND_TEXT := "text"
const KIND_CODE := "code"

## What an inline run is.
const RUN_PLAIN := "plain"
const RUN_BOLD := "bold"
const RUN_ITALIC := "italic"
## A `**term:X**` glossary reference. `text` is the term name, trimmed.
const RUN_GLOSSARY := "glossary"
## A single-backtick code span. `text` is verbatim, delimiters stripped.
const RUN_CODE := "code"

## A fence opener: three or more backticks and an optional info string.
##
## ANYTHING ELSE ON THE LINE DISQUALIFIES IT, which is why the pattern is
## anchored at both ends. A stray triple backtick mid-sentence would otherwise
## open a code block that swallows the rest of the step.
const _FENCE_OPEN := "^[ \\t]*(`{3,})[ \\t]*([A-Za-z0-9_+#.\\-]*)[ \\t]*$"

## A fence closer carries no info string.
const _FENCE_CLOSE := "^[ \\t]*(`{3,})[ \\t]*$"

## An inline code span. NEWLINE-FREE, so an unmatched backtick cannot span
## paragraphs and turn the rest of a step into code.
const _INLINE_CODE := "`([^`\\n]+)`"

## Emphasis, most specific alternative first. See the header.
const _EMPHASIS := "\\*\\*term:([A-Za-z0-9_\\-\\.\\s]+?)\\*\\*|\\*\\*(.+?)\\*\\*|\\*(.+?)\\*"

## A paragraph break is a blank line, and A LINE OF SPACES IS BLANK. An author
## cannot see the difference between "\n\n" and "\n \n" and neither should this;
## the stricter form left "First.\n \nSecond." as one paragraph while the
## documented contract said otherwise.
const _PARAGRAPH_BREAK := "\\n[ \\t]*\\n(?:[ \\t]*\\n)*"


## Collapse CRLF and CR to LF, so every line rule below is single-character.
static func normalize(markdown: String) -> String:
	if markdown == "":
		return ""
	return markdown.replace("\r\n", "\n").replace("\r", "\n")


## Split a document into alternating text and code blocks, in source order.
##
## Each entry is {"kind": KIND_*, "text": String, "info": String}. `info` is the
## fence's info string -- ```` ```gdscript ```` yields "gdscript" -- and is empty
## for a bare fence and for every text block. It is CAPTURED BUT NOT RENDERED,
## on purpose: a future highlighter needs something to switch on, and dropping
## it at the tokenizer is the bug this field exists to prevent recurring.
##
## AN UNTERMINATED FENCE IS ORDINARY TEXT. A step body whose author opened a
## fence and never closed it renders as prose rather than swallowing everything
## after it into a code block -- the failure that looks like the step lost half
## its content.
static func split_blocks(markdown: String) -> Array:
	var blocks: Array = []
	var text := normalize(markdown)
	if text == "":
		return blocks

	var opener := RegEx.create_from_string(_FENCE_OPEN)
	var closer := RegEx.create_from_string(_FENCE_CLOSE)

	var lines := text.split("\n")
	var pending: Array = []
	var index := 0

	while index < lines.size():
		var line: String = lines[index]
		var open_match := opener.search(line)
		if open_match == null:
			pending.append(line)
			index += 1
			continue

		# A fence opens here, IF it closes. Look ahead before committing:
		# committing first and discovering no closer would mean unwinding.
		var fence: String = open_match.get_string(1)
		var close_at := -1
		var scan := index + 1
		while scan < lines.size():
			var close_match := closer.search(lines[scan])
			if close_match != null and close_match.get_string(1).length() >= fence.length():
				close_at = scan
				break
			scan += 1

		if close_at < 0:
			# No closer. This line is prose, including its backticks.
			pending.append(line)
			index += 1
			continue

		if not pending.is_empty():
			blocks.append({
				"kind": KIND_TEXT, "text": "\n".join(pending), "info": "",
			})
			pending = []

		var body: Array = []
		for i in range(index + 1, close_at):
			body.append(lines[i])
		blocks.append({
			"kind": KIND_CODE,
			"text": "\n".join(body),
			"info": open_match.get_string(2),
		})
		index = close_at + 1

	if not pending.is_empty():
		blocks.append({"kind": KIND_TEXT, "text": "\n".join(pending), "info": ""})
	return blocks


## Split one TEXT block into paragraphs.
##
## ONLY EVER CALLED ON A TEXT BLOCK, which is why there is no equivalent of the
## shared version's `BuildSplitBarrierMask`. That mask exists to stop a
## paragraph split landing inside a fenced region when the splitter runs over a
## whole document; here `split_blocks` has already separated code out, so the
## splitter never sees a fence and the mask would guard nothing. Noted because
## the absence of a ported function is otherwise indistinguishable from an
## oversight.
static func split_paragraphs(text: String) -> Array:
	var out: Array = []
	if text.strip_edges() == "":
		return out
	# BY HAND, because Godot's RegEx HAS NO `split`. It offers search,
	# search_all and sub and nothing else, so a ported `Regex.Split` compiles
	# fine, returns nothing, and every multi-paragraph step renders as one
	# paragraph -- which looks like a styling problem rather than a missing
	# method.
	var body := normalize(text)
	var breaker := RegEx.create_from_string(_PARAGRAPH_BREAK)
	var cursor := 0
	for hit in breaker.search_all(body):
		var piece: String = body.substr(cursor, hit.get_start() - cursor).strip_edges()
		if piece != "":
			out.append(piece)
		cursor = hit.get_end()
	var last: String = body.substr(cursor).strip_edges()
	if last != "":
		out.append(last)
	return out


## Split one paragraph into inline runs, in source order.
##
## Each entry is {"kind": RUN_*, "text": String}.
static func tokenize_inline(paragraph: String) -> Array:
	var runs: Array = []
	if paragraph == "":
		return runs

	var code := RegEx.create_from_string(_INLINE_CODE)
	var cursor := 0
	for hit in code.search_all(paragraph):
		if hit.get_start() > cursor:
			_append_emphasis(runs, paragraph.substr(cursor, hit.get_start() - cursor))
		runs.append({"kind": RUN_CODE, "text": hit.get_string(1)})
		cursor = hit.get_end()

	if cursor < paragraph.length():
		_append_emphasis(runs, paragraph.substr(cursor))
	return runs


## Emphasis over a stretch that is known to contain no code spans.
static func _append_emphasis(runs: Array, text: String) -> void:
	if text == "":
		return
	var emphasis := RegEx.create_from_string(_EMPHASIS)
	var cursor := 0
	for hit in emphasis.search_all(text):
		if hit.get_start() > cursor:
			_append_plain(runs, text.substr(cursor, hit.get_start() - cursor))

		# WHICH ALTERNATIVE MATCHED, by group participation rather than by
		# emptiness. A group that did not take part reports a start of -1, while
		# one that matched an empty string reports a real offset -- and treating
		# those the same would file `****` as a glossary term with no name.
		if hit.get_start(1) >= 0:
			runs.append({
				"kind": RUN_GLOSSARY, "text": hit.get_string(1).strip_edges(),
			})
		elif hit.get_start(2) >= 0:
			runs.append({"kind": RUN_BOLD, "text": hit.get_string(2)})
		else:
			runs.append({"kind": RUN_ITALIC, "text": hit.get_string(3)})
		cursor = hit.get_end()

	if cursor < text.length():
		_append_plain(runs, text.substr(cursor))


## Add plain text.
##
## THERE IS NO MERGE HERE, AND THE ABSENCE IS DELIBERATE. The first version
## merged with a plain run already at the end, on the reasoning that two
## adjacent plain runs become two Labels and two Labels break a line where one
## would have wrapped. That reasoning is sound and the branch was UNREACHABLE:
## a mutation harness removed it and every test still passed, which is how it
## was found.
##
## Two plain runs cannot end up adjacent by construction. `tokenize_inline`
## calls the emphasis pass once per gap between code spans, so consecutive calls
## always have a code run between them; and within the emphasis pass a plain run
## is only ever emitted before an emphasis match or at the very end. Either way
## something sits between any two of them.
##
## The merge is therefore reinstated only if that invariant changes -- and
## `test_adjacent_plain_text_is_one_run` asserts the invariant itself rather
## than the merge, so it fails if it ever does.
static func _append_plain(runs: Array, text: String) -> void:
	if text == "":
		return
	runs.append({"kind": RUN_PLAIN, "text": text})
