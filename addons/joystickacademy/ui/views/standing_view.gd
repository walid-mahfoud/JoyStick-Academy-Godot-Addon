@tool
extends "res://addons/joystickacademy/ui/views/view_base.gd"

## Plan item 34. XP, gems, the streak, and where the week stands.
##
## IT SHOWS WHAT THE PHONE SHOWS. Every figure here is the same one the app
## displays, fetched from the same place, and the point is that a learner
## working in the editor is not working in a second, separate account. A number
## computed here would drift the first time somebody did a lesson on their
## phone.
##
## ZERO IS A REAL VALUE AND ABSENT IS NOT. A streak of zero means the streak
## broke, which is worth showing; a streak the payload did not carry means this
## helper is older than the field and showing "0" would tell a learner they lost
## something. Missing figures are drawn as a dash.
##
## THE LEAGUE IS OPTIONAL BECAUSE IT IS OPTIONAL. A learner who has not joined
## one has no rank, and inventing "unranked" as a position among people is worse
## than leaving the row out.

const Header := preload("res://addons/joystickacademy/ui/components/header.gd")

const COMMAND_REFRESH := "standing.refresh"

# THERE WAS A SECOND COMMAND HERE, `standing.open_on_phone`, AND IT WAS NEVER
# SENT. Nothing connected it to anything, so it was a name the shell had to
# route for a press no learner could make. Removed rather than wired up: there
# is no way for a desktop editor to open an app on somebody's phone, and the
# one mechanism that would have made it meaningful -- a QR code -- was decided
# against for the sign-in flow (plan item 39) for the same reason it would be
# wrong here, that people look for a scanner and there is not one.

## What a figure looks like when the payload did not carry it.
const ABSENT := "—"


var _header: Control = null
var _figures: GridContainer = null
var _league: Label = null
var _refresh_button: Button = null


func _init() -> void:
	name = "StandingView"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	_header = Header.new()
	add_child(_header)
	_header.set_title("Your standing")

	_figures = GridContainer.new()
	_figures.name = "Figures"
	_figures.columns = 2
	_figures.add_theme_constant_override("h_separation", 12)
	_figures.add_theme_constant_override("v_separation", 4)
	add_child(_figures)

	_league = Label.new()
	_league.name = "League"
	_league.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_league.visible = false
	add_child(_league)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)
	add_child(actions)

	_refresh_button = Button.new()
	_refresh_button.name = "Refresh"
	_refresh_button.text = "Refresh"
	actions.add_child(_refresh_button)

	_refresh_button.pressed.connect(func(): send(COMMAND_REFRESH))


## Every figure, as {label: value}, in the order shown.
func figures() -> Dictionary:
	var out := {}
	var children := _figures.get_children()
	var i := 0
	while i + 1 < children.size():
		out[(children[i] as Label).text] = (children[i + 1] as Label).text
		i += 2
	return out


func league_text() -> String:
	return _league.text


func is_league_shown() -> bool:
	return _league.visible


## How to draw one figure.
##
## ABSENT AND ZERO ARE DIFFERENT ANSWERS. A streak of zero means it broke; a
## streak the payload did not carry means this helper is older than the field,
## and drawing "0" would tell a learner they lost something they still have.
static func figure_text(payload: Dictionary, key: String) -> String:
	if payload == null or not payload.has(key) or payload[key] == null:
		return ABSENT
	var value = payload[key]
	if value is float:
		return str(int(round(value)))
	if value is int:
		return str(value)
	return str(value)


func _render(payload: Dictionary) -> void:
	for child in _figures.get_children():
		child.free()

	_add_figure("XP", figure_text(payload, "totalXp"))
	_add_figure("Gems", figure_text(payload, "gems"))
	_add_figure("Streak", _streak_text(payload))
	_add_figure("Lessons", figure_text(payload, "lessonsCompleted"))

	_render_league(payload)
	_header.set_subtitle(text_at(payload, "displayName"))


func _streak_text(payload: Dictionary) -> String:
	var value := figure_text(payload, "streakDays")
	if value == ABSENT:
		return ABSENT
	# "1 day", not "1 days". The streak is the figure a learner reads most often
	# and the one a bad plural is most visible on.
	return "1 day" if value == "1" else "%s days" % value


func _render_league(payload: Dictionary) -> void:
	var league = payload.get("league", null)
	if not (league is Dictionary):
		# NOT JOINED IS NOT UNRANKED. Inventing a position among people is worse
		# than leaving the row out.
		_league.visible = false
		_league.text = ""
		return

	var tier := text_at(league, "tier")
	var rank := number_at(league, "rank", 0)
	if tier == "" or rank <= 0:
		_league.visible = false
		_league.text = ""
		return

	var size := number_at(league, "size", 0)
	if size > 0:
		_league.text = "%s league — %d of %d this week" % [tier, rank, size]
	else:
		_league.text = "%s league — %d this week" % [tier, rank]
	_league.visible = true


func _add_figure(label: String, value: String) -> void:
	var name_label := Label.new()
	name_label.name = "Label"
	name_label.text = label
	_figures.add_child(name_label)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.text = value
	_figures.add_child(value_label)
