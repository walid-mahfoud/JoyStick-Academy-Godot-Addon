@tool
extends RefCounted

## What the EDITOR has to do for a command the sidecar cannot.
##
## Three of the panel's commands are not requests at all. Copying a diagnostics
## report needs a clipboard, opening the support page needs a browser, and
## choosing a file needs a file dialog -- and all three of those live in the
## editor, which a sidecar has never seen and a headless test has not got
## either.
##
## SO THE DECISION IS HERE AND THE DOING IS IN `plugin.gd`. This file is pure:
## it turns a command into a description of what to do, and every branch of it
## is testable without an editor. The plugin reads that description and calls
## the two or three editor APIs that carry it out, which is the part that cannot
## be tested here and is therefore kept as small as it can be.
##
## The same split as `startup_decision.gd`, `restart_policy.gd` and
## `log_router.gd`, and for the same reason: a rule that can only be read is a
## rule that drifts.

const Footer := preload("res://addons/joystickacademy/ui/components/footer.gd")

## What kind of editor work a command turns into.
const DO_NOTHING := "none"
const DO_CLIPBOARD := "clipboard"
const DO_OPEN_URL := "open_url"
const DO_PICK_FILES := "pick_files"
## Launch the learner's game and watch it. See `plan`'s `player.run` branch.
const DO_PLAY_RUN := "play_run"

## Which picker a chosen file belongs in. Travels out with the plan and comes
## back with the answer, so the dialog's callback does not have to remember
## which button opened it.
const SLOT_ARCHIVE := "archive"
const SLOT_SCREENSHOTS := "screenshots"

## What a submission archive may be.
##
## A .zip AND the two tarballs, because the learner may have made the archive
## themselves on a machine where zip is not the obvious choice. The sidecar
## packages the project itself in the ordinary flow; this is the path for
## somebody who has already got a file.
##
## PLAIN ARRAYS, NOT PackedStringArray. A `const` has to be a constant
## EXPRESSION and `PackedStringArray([...])` is a constructor call, so the
## obvious spelling does not compile -- and the error, "could not resolve
## external class member", names the const rather than the constructor and
## reads as a missing file. The editor dialog takes either.
const ARCHIVE_FILTERS := [
	"*.zip ; Zip archive",
	"*.tar.gz, *.tgz ; Gzipped tarball",
]

const IMAGE_FILTERS := [
	"*.png, *.jpg, *.jpeg, *.webp ; Images",
]


## Turn one local command into a description of the editor work it needs.
##
## Returns a dictionary carrying `do` and whatever that kind needs. An unknown
## command returns DO_NOTHING with a `reason`, which the caller pushes as an
## error: a local command with no plan is the same failure as a command with no
## route -- a button that quietly does nothing -- and it must not be silent.
static func plan(command: Dictionary) -> Dictionary:
	var method := str(command.get("method", ""))
	# READ UNTYPED FIRST. A typed local REFUSES the assignment at runtime rather
	# than taking it and letting the check below catch it -- so `var args:
	# Dictionary = <a String>` aborts the function, and an aborted function in a
	# test reports its earlier assertions and reads as a pass.
	var raw = command.get("args", {})
	var args: Dictionary = raw if raw is Dictionary else {}

	match method:
		"diagnostics.copy":
			var text := str(args.get("text", ""))
			if text.strip_edges() == "":
				# NOT A SILENT NO-OP. Putting an empty string on the clipboard
				# means the next paste is whatever the learner had copied
				# before, which they will send to support believing it is the
				# report.
				return _nothing("there was no report to copy")
			return {"do": DO_CLIPBOARD, "text": text}

		"auth.copy_code":
			# SAME WORK AS THE DIAGNOSTICS REPORT AND A DIFFERENT REASON. The
			# code is ten characters somebody is about to read off one screen
			# and type into another, and a clipboard is only useful to them if
			# the phone is on the same machine -- which for a device running an
			# emulator it often is.
			var code := str(args.get("text", ""))
			if code.strip_edges() == "":
				return _nothing("there is no code to copy yet")
			return {"do": DO_CLIPBOARD, "text": code}

		"account.support":
			return {"do": DO_OPEN_URL, "url": Footer.SUPPORT_URL}

		"player.run":
			# THE WINDOW HAS TO BE THE ONE WE LAUNCHED. A learner pressing Play
			# in Godot themselves runs a game with no observer in it, so nothing
			# is recorded and the check goes on saying no run happened -- which
			# reads as the panel being broken by somebody who just did the thing
			# it asked for. Hence a button of our own, rather than an
			# instruction to use Godot's.
			#
			# WHICH SCENE is the editor's question, not this file's: only the
			# plugin can ask what is open. Deciding it here would mean guessing,
			# and the guess that looks right -- the project's main scene -- is
			# the one measured to be wrong, because it is not the scene the
			# learner just built.
			# THE WATCH LIST IS CARRIED, NOT READ. Its shape belongs to
			# observation_config.gd and to the checks that filled it; this
			# file's job is to say whose work the press is.
			var watch = args.get("watch", {})
			return {
				"do": DO_PLAY_RUN,
				"watch": watch if watch is Dictionary else {},
				# CARRIED, NOT INTERPRETED. The sidecar checks these against the
				# step in front of the learner when the window reports back.
				"lessonId": str(args.get("lessonId", "")),
				"stepIndex": int(args.get("stepIndex", 0)),
			}

		"submission.browse_archive":
			return {
				"do": DO_PICK_FILES,
				"slot": SLOT_ARCHIVE,
				"multiple": false,
				"title": str(args.get("title", "Choose your project archive")),
				"filters": _filters(args, ARCHIVE_FILTERS),
			}

		"submission.browse_screenshots":
			return {
				"do": DO_PICK_FILES,
				"slot": SLOT_SCREENSHOTS,
				"multiple": true,
				"title": str(args.get("title", "Choose your screenshots")),
				"filters": _filters(args, IMAGE_FILTERS),
			}

	return _nothing("no local plan for '%s'" % method)


## The filters the picker asked for, or this file's own when it asked for none.
##
## THE PICKER'S WIN WHEN IT HAS THEM, because the picker is where a capstone's
## own requirements land -- a submission that wants a `.godot` project rather
## than a zip says so through the picker. The defaults are for the ordinary
## case and for a payload from an older sidecar that carried none.
static func _filters(args: Dictionary, fallback: Array) -> Array:
	var given = args.get("filters", null)
	var out: Array = []
	# BOTH SHAPES, because both arrive. A picker hands over a
	# PackedStringArray; the same value round-tripped through JSON -- which is
	# what a payload from the sidecar is -- comes back a plain Array.
	if given is PackedStringArray or given is Array:
		for entry in given:
			if entry is String:
				out.append(entry)
	return out if out.size() > 0 else fallback


static func _nothing(reason: String) -> Dictionary:
	return {"do": DO_NOTHING, "reason": reason}
