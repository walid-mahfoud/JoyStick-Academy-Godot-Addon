@tool
extends VBoxContainer

## A view with nothing in it yet.
##
## NO LONGER SHIPPED IN THE DOCK -- the ten real views replaced it on
## 2026-09-18 -- and it is kept because the ROUTER'S own tests need it.
##
## A router tested only against the real views tests them too: a change to the
## library's rendering would fail a routing test, and somebody reading that
## failure looks in the wrong file. This is a view with no behaviour beyond the
## lifecycle, which is exactly what a routing test should be routing between.
##
## It implements both lifecycle hooks and counts them, which is what lets the
## router's tests assert that a hook fired ONCE rather than that it fired.

var shown_count := 0
var hidden_count := 0

var _label: Label


func _init(title: String = "Coming soon") -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_label = Label.new()
	_label.text = title
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_label)


func title() -> String:
	return _label.text if _label != null else ""


func on_shown() -> void:
	shown_count += 1


func on_hidden() -> void:
	hidden_count += 1
