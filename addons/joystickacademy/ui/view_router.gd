@tool
extends RefCounted

## One dock, many views, one of them visible.
##
## The GDScript equivalent of the shared Core's ViewRouter, and it is NOT a
## translation of it. Unity keys its views by `typeof(TView)` because C# has
## generics; GDScript has neither generics nor interfaces, so the two places
## that abstraction lands have to be chosen rather than ported.
##
## KEYED BY NAME. The alternative is keying by script class, which in Godot
## means `class_name` -- a GLOBAL registration that puts every one of this
## addon's view classes into the autocomplete of every script in the learner's
## project. A plugin should not be visible in the namespace of the game
## somebody is writing. A string key costs an unknown-name check, which is
## written below and tested, and that is the whole price.
##
## LIFECYCLE IS DUCK-TYPED, AND THE TYPO IS DESIGNED OUT. Unity casts to
## IRoutedView and calls OnShown if the cast succeeds; GDScript has no
## interface to cast to, so this asks `has_method("on_shown")`. That is
## silently forgiving in exactly the wrong way: a view whose author wrote
## `on_show` or `_on_shown` gets no error, no warning, and a lifecycle hook
## that never fires. So registration REFUSES a view carrying a near-miss
## spelling. See `_NEAR_MISSES`.
##
## HIDDEN VIEWS STOP PROCESSING. Godot keeps calling `_process` on an invisible
## node -- visibility is a draw property, not a lifecycle one -- so a view with
## a timer, a poll or an animation keeps running while the learner is looking at
## a different one. Unity's `display: none` has the same property and the same
## trap. Hiding here turns processing off and showing turns it back on.

## The two lifecycle hooks a view may implement. Optional, both of them.
const ON_SHOWN := "on_shown"
const ON_HIDDEN := "on_hidden"

## Spellings that are obviously meant to be a hook and are not one. A view
## carrying any of these is refused at registration rather than silently never
## called.
const _NEAR_MISSES := [
	"on_show", "onShown", "OnShown", "_on_shown", "on_shown_",
	"on_hide", "onHidden", "OnHidden", "_on_hidden", "on_hidden_",
]

var _views := {}
var _current := ""


## Add a view under `view_name`. It starts hidden.
##
## Returns "" on success, or a reason it was refused. A REASON RATHER THAN A
## CRASH: this runs while the editor is building the dock, and an assert here
## takes the whole addon down at enable time -- the one moment a learner has no
## way to find out why.
func register(view_name: String, view: Control) -> String:
	if view_name == "":
		return "a view needs a name"
	if view == null:
		return "no view was given for '%s'" % view_name
	if _views.has(view_name):
		return "'%s' is already registered" % view_name

	for near_miss in _NEAR_MISSES:
		if view.has_method(near_miss):
			return ("'%s' has a method called %s, which looks like a lifecycle hook "
				+ "and is not one. The hooks are %s and %s.") % [
					view_name, near_miss, ON_SHOWN, ON_HIDDEN]

	_views[view_name] = view
	_hide(view)
	return ""


## Show one view and hide whichever was showing.
##
## Returns "" on success, or a reason. Showing the view that is already showing
## is a no-op rather than a hide-then-show: firing on_hidden and on_shown at a
## view that never went anywhere is the kind of spurious lifecycle that makes a
## hook untrustworthy, and Unity's router does exactly that.
func show_view(view_name: String) -> String:
	if not _views.has(view_name):
		return "no view named '%s' is registered" % view_name
	if view_name == _current:
		return ""

	if _current != "":
		var previous: Control = _views[_current]
		_hide(previous)
		if previous.has_method(ON_HIDDEN):
			previous.call(ON_HIDDEN)

	_current = view_name
	var next: Control = _views[view_name]
	_show(next)
	if next.has_method(ON_SHOWN):
		next.call(ON_SHOWN)
	return ""


## The view showing now, or "" before anything has been shown.
func current() -> String:
	return _current


## Every registered name, sorted. For tests and for the Diagnostics view.
func names() -> PackedStringArray:
	var out := PackedStringArray(_views.keys())
	out.sort()
	return out


func has(view_name: String) -> bool:
	return _views.has(view_name)


## The view itself. Null when the name is unknown.
func get_view(view_name: String) -> Control:
	return _views.get(view_name, null)


func _show(view: Control) -> void:
	view.visible = true
	view.set_process(true)
	view.set_physics_process(true)


func _hide(view: Control) -> void:
	view.visible = false
	# See the header: an invisible Godot node keeps processing. A view left
	# polling behind another view is work nobody asked for and, on the sidecar
	# views, requests nobody is waiting for.
	view.set_process(false)
	view.set_physics_process(false)
