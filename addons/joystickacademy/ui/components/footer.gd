@tool
extends HBoxContainer

## The line along the bottom: what version this is, and where to get help.
##
## IT REPORTS THE PRESS RATHER THAN OPENING ANYTHING. Opening a browser from a
## component means the component knows a URL and knows how to reach the shell,
## and in this addon reaching the shell means the editor -- which a test has
## not got. The view above opens it, and this says only that somebody asked.
##
## THE VERSION IS SHOWN BECAUSE OF WHAT SUPPORT COSTS WITHOUT IT. The first
## question about any plugin problem is which version, and a learner who has to
## go and find out often does not come back.

signal support_requested()

const SUPPORT_URL := "https://joystick-academy.com/support"
const SUPPORT_COPY := "Get help"

var _version: Label = null
var _support: Button = null


func _init() -> void:
	name = "Footer"
	add_theme_constant_override("separation", 8)

	_version = Label.new()
	_version.name = "Version"
	_version.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_version)

	_support = Button.new()
	_support.name = "Support"
	_support.text = SUPPORT_COPY
	_support.flat = true
	add_child(_support)

	_support.pressed.connect(func(): support_requested.emit())


func version_text() -> String:
	return _version.text


func set_version(value: String) -> void:
	# A VERSION NOBODY SET IS NOT VERSION ZERO. Showing "v" with nothing after
	# it, or a hardcoded default, is worse than showing nothing: it answers the
	# support question wrongly and confidently.
	_version.text = "" if value == "" else "v%s" % value
