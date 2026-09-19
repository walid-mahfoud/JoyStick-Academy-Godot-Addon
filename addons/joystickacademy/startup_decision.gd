extends RefCounted

## What the addon should do when it is enabled: start, or explain itself.
##
## WHY THIS IS NOT IN plugin.gd. plugin.gd is an EditorPlugin and needs a
## running editor to instantiate, so a rule written there can only ever be
## read, never exercised. The rules collected here are the ones a learner meets
## FIRST -- on an unsupported platform, or after a download that lost a file --
## and getting them wrong is not a crash. It is an addon that either says
## nothing or says the wrong thing forever.
##
## THE FAILURE THIS PREVENTS IS THE LOUD ONE. An addon that errors every frame
## is worse than one that is honestly unavailable: a plugin printing to the
## Output panel sixty times a second buries whatever the learner was actually
## doing, and the editor becomes unusable over a feature that simply is not
## available here. So every refusal below STOPS -- no retry, no per-frame work,
## one message -- and the tests assert that rather than trusting it.

const Locator := preload("res://addons/joystickacademy/sidecar_locator.gd")
const BinIntegrity := preload("res://addons/joystickacademy/bin_integrity.gd")
const Codec := preload("res://addons/joystickacademy/protocol/frame_codec.gd")


## What the plugin should do next.
enum Action {
	## Launch the sidecar. `path` is what to launch.
	START,
	## Do not launch, and do not try again. `reason` is for the learner.
	STOP,
}


## Decide, given what the locator found.
##
## `found` is sidecar_locator.locate_with_source()'s Dictionary. Taken as an
## argument rather than fetched here so the no-binary case can actually be
## tested: this repository always HAS a sidecar built, so a function that asked
## the locator itself could never be driven down the path that matters most.
##
## Returns:
##   action    Action
##   path      String   what to launch, "" unless START
##   reason    String   learner-facing, "" unless STOP
##   detail    String   maintainer-facing, always something
##   severity  String   how to show `detail`, from Codec.LOG_LEVELS
##   verified  bool     the integrity check ran and passed
##
## SEVERITY IS PART OF THE DECISION, not of the display, and the two STOPs
## differ on it. An unsupported platform is not an error: nothing is broken,
## this simply is not a platform we ship for, and push_error over it puts a red
## line in the Output panel of somebody who did nothing wrong. A binary that
## does not match its manifest IS an error, and a learner who reports "it does
## nothing" needs it to have been loud.
## `os_name` defaults to this machine's. It is a parameter because the
## unsupported-platform branch is unreachable on any machine that runs this
## suite, and it is the branch a learner on an unsupported platform meets
## FIRST -- see sidecar_locator.runtime_identifier for the same reasoning.
static func decide(found: Dictionary, os_name := OS.get_name()) -> Dictionary:
	var path := str(found.get("path", ""))
	var source := str(found.get("source", ""))

	if path == "":
		# Not an error and not a retry. Either this platform is one we do not
		# ship for -- which will still be true tomorrow -- or the install is
		# broken, which a reinstall fixes and a retry does not.
		var supported := Locator.runtime_identifier(os_name) != ""
		return {
			"action": Action.STOP,
			"path": "",
			"reason": Locator.explain_missing(os_name),
			"detail": ("the install is missing its sidecar for %s" if supported
				else "no sidecar ships for %s") % os_name,
			# A broken install is worth a warning -- it is fixable and the
			# learner should know -- while an unsupported platform is merely a
			# fact about this machine.
			"severity": Codec.LEVEL_WARN if supported else Codec.LEVEL_INFO,
			"verified": false,
		}

	var integrity := BinIntegrity.decide(source, Locator.bundled_directory())
	if not integrity["launch"]:
		return {
			"action": Action.STOP,
			"path": "",
			"reason": integrity["reason"],
			"detail": integrity["detail"],
			"severity": Codec.LEVEL_ERROR,
			"verified": false,
		}

	return {
		"action": Action.START,
		"path": path,
		"reason": "",
		"detail": integrity["detail"],
		"severity": Codec.LEVEL_INFO,
		"verified": integrity["verified"],
	}
