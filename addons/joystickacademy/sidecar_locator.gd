extends RefCounted

## Where the bundled sidecar lives, per platform.
##
## The addon ships one executable per platform under bin/, and picks the one
## for the machine it is running on. A learner never sees any of this: they
## enable the addon and it works.

const BIN_ROOT := "res://addons/joystickacademy/bin"

## The platforms the addon ships a sidecar for. A machine outside this list
## gets a clear message rather than a silent failure -- see plugin.gd.
const SUPPORTED := {
	"Windows": "win-x64",
	"macOS": "osx",              ## resolved further by architecture below
	"Linux": "linux-x64",
	"FreeBSD": "linux-x64",
	"NetBSD": "linux-x64",
	"OpenBSD": "linux-x64",
	"BSD": "linux-x64",
}


## The runtime identifier for this machine, or "" when it is not supported.
##
## `os_name` defaults to this machine's and is a parameter for one reason: the
## UNSUPPORTED branch is the one a learner meets on a platform we do not ship
## for, and it is unreachable on every machine that runs these tests. A branch
## that can only be read is a branch that drifts, and this one decides whether
## the addon tells somebody "not here yet" or "your install is broken".
static func runtime_identifier(os_name := OS.get_name()) -> String:
	if not SUPPORTED.has(os_name):
		return ""
	var rid: String = SUPPORTED[os_name]
	if rid == "osx":
		# Apple silicon and Intel are different binaries, and running the wrong
		# one fails in a way that reads as a corrupt download rather than a
		# wrong architecture.
		return "osx-arm64" if _is_arm() else "osx-x64"
	return rid


static func _is_arm() -> bool:
	var arch := Engine.get_architecture_name()
	return arch.contains("arm") or arch.contains("aarch")


## The path the sidecar should be at for this machine.
static func expected_path() -> String:
	var rid := runtime_identifier()
	if rid == "":
		return ""
	var name := "JoyStickAcademy.Host"
	if OS.get_name() == "Windows":
		name += ".exe"
	return BIN_ROOT.path_join(rid).path_join(name)


## Where a located sidecar came from.
##
## This is not bookkeeping: only SOURCE_BUNDLED has ever been published, so it
## is the only one with a hash manifest beside it, and it is the only one the
## integrity gate can check. The other two are developer paths. Returning the
## source alongside the path is what lets the caller refuse an unverifiable
## BUNDLED binary while still running an unverifiable DEVELOPMENT one -- and,
## just as importantly, say which of those it did.
const SOURCE_NONE := ""
const SOURCE_OVERRIDE := "override"
const SOURCE_BUNDLED := "bundled"
const SOURCE_DEVELOPMENT := "development"


## Find the sidecar, preferring the bundled one.
##
## Returns {"path": String, "source": String}; path is "" when there is none to
## run. Three places are tried, and the order matters:
##
##   1. JSA_HOST_EXE, so CI and a developer can point at a fresh build without
##      copying it into the addon on every change.
##   2. The bundled binary, which is what every learner uses.
##   3. The local debug build, so the addon works in THIS repo before anything
##      has been packaged.
##
## The development fallbacks are deliberately last. If they came first, a
## packaging bug that shipped no binary at all would still work on the machine
## of the one person able to notice.
static func locate_with_source() -> Dictionary:
	var override := OS.get_environment("JSA_HOST_EXE")
	if override != "" and FileAccess.file_exists(override):
		return {"path": override, "source": SOURCE_OVERRIDE}

	var bundled := expected_path()
	if bundled != "" and FileAccess.file_exists(bundled):
		return {
			"path": ProjectSettings.globalize_path(bundled),
			"source": SOURCE_BUNDLED,
		}

	var dev := _development_build_path()
	if dev != "" and FileAccess.file_exists(dev):
		return {"path": dev, "source": SOURCE_DEVELOPMENT}

	return {"path": "", "source": SOURCE_NONE}


## The path alone, for callers that genuinely do not care where it came from.
static func locate() -> String:
	return locate_with_source()["path"]


## The directory the bundled sidecar lives in, absolute, or "" when this
## platform has none. The integrity manifest sits in here beside the binary.
static func bundled_directory() -> String:
	var rid := runtime_identifier()
	if rid == "":
		return ""
	return ProjectSettings.globalize_path(BIN_ROOT.path_join(rid))


static func _development_build_path() -> String:
	var rid := runtime_identifier()
	if rid == "":
		return ""
	var name := "JoyStickAcademy.Host.exe" if OS.get_name() == "Windows" else "JoyStickAcademy.Host"
	# Only meaningful when the addon is being run from its own repository.
	return ProjectSettings.globalize_path("res://").path_join(
		"Host/JoyStickAcademy.Host/bin/Debug/net8.0/%s/%s" % [rid, name])


## Why the sidecar could not be found, phrased for a learner rather than a
## maintainer.
##
## The two cases are genuinely different and must not be flattened: an
## unsupported platform is something they cannot fix and should stop expecting
## to work, while a missing file on a supported platform is a broken install
## they can fix by reinstalling.
static func explain_missing(os_name := OS.get_name()) -> String:
	if runtime_identifier(os_name) == "":
		return ("JoyStick Academy does not support %s yet, so the plugin cannot run here. "
			+ "Everything else in Godot is unaffected.") % os_name
	return ("JoyStick Academy is missing part of its install and cannot start. "
		+ "Reinstalling the plugin from the Asset Library should fix it.")
