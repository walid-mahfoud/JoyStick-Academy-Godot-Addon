extends RefCounted

## Is the binary about to be launched the one that shipped?
##
## The addon launches an executable out of its own directory. This checks that
## executable against a manifest written when it was published, and refuses to
## launch when they disagree.
##
## WHAT THIS ACTUALLY DEFENDS AGAINST, stated plainly because a security check
## described as stronger than it is, is worse than no check at all. The manifest
## sits in the same directory as the binary, and the addon that reads it sits
## beside both. Anyone who can write to that directory can rewrite the manifest
## too. So this is NOT protection from a local attacker, and nothing here should
## ever be described as though it were.
##
## What it does catch, which is what actually goes wrong in practice:
##
##   * A download that finished short, or an archive that extracted partially.
##     Sixty-five megabytes over a bad connection is the single most likely
##     failure this addon has, and a truncated self-contained binary crashes in
##     a way that reads as "the plugin is broken" rather than "re-download it".
##   * A stale binary from a previous version, left behind by a hand-copy or a
##     half-finished update. It runs, it is the wrong build, and only the
##     handshake would have caught it -- after launching it.
##   * A file dropped in beside the sidecar. The publish is single-file, so
##     there is exactly one executable and nothing else legitimately there.
##
## WHEN IT RUNS. Once, immediately before the sidecar is launched, which is once
## per editor session. Measured on this repo's own 67 MB Windows build with
## Godot 4.5.1: about 350 ms at a 1 MB chunk, and the chunk size barely matters
## (405 ms at 64 KB, 301 ms at 4 MB). That is paid on the frame the plugin
## starts the sidecar, not on every frame, and not on project open.
##
## A MISSING MANIFEST IS A REFUSAL, NOT A SKIP. If a missing file turned the
## check off, deleting one small text file would disable it -- and a partial
## extract is exactly the situation that both loses files and most needs
## checking. A bundled install without a manifest is a broken install.
##
## The developer paths are the deliberate exception: a binary found through
## JSA_HOST_EXE or built into Host/.../bin/Debug has never been published and
## has no manifest. Those are not checked, and the caller is told so rather than
## left to assume the check ran. See sidecar_locator.gd's locate_with_source().

## sha256sum's format: <64 hex><two spaces><relative path>, one per line.
## Deliberately the same shape as the standard tool, so an operator can check a
## release by hand with `sha256sum -c` and needs no tool of ours to do it.
const MANIFEST_NAME := "manifest.sha256"

## Measured above: past about 1 MB the gain flattens out, and a bigger chunk is
## a bigger allocation on the editor's own thread.
const CHUNK_BYTES := 1024 * 1024

const _HEX := "0123456789abcdef"

## For SOURCE_BUNDLED. Only the locator is allowed to know where the sidecar
## lives; this file only needs to know which of its answers is the shipped one.
const Locator := preload("res://addons/joystickacademy/sidecar_locator.gd")


## Should the addon launch, given where the binary came from?
##
## THIS FUNCTION IS THE RULE, and it lives here rather than in plugin.gd on
## purpose: plugin.gd needs a running editor to instantiate, so a rule written
## there can only ever be read, never exercised. The asymmetry below is the
## whole design and it is easy to get subtly wrong in either direction, so it
## is somewhere a test can reach.
##
##   * SOURCE_BUNDLED is the only thing that has ever been published, so it is
##     the only thing with a manifest. It is verified, and a failure -- missing
##     manifest included -- refuses the launch.
##   * Everything else is a developer path: JSA_HOST_EXE, or a build in
##     Host/.../bin/Debug. No manifest exists for those and none could, so
##     refusing them would make this repo's own suite unrunnable. They launch
##     UNVERIFIED and say so, because silence would let a maintainer believe
##     the gate ran when it did not.
##
## Returns:
##   launch    bool    go ahead
##   verified  bool    the integrity check actually ran and passed
##   reason    String  learner-facing, "" unless the launch is refused
##   detail    String  maintainer-facing, always something
static func decide(source: String, directory: String) -> Dictionary:
	if source != Locator.SOURCE_BUNDLED:
		return {
			"launch": true,
			"verified": false,
			"reason": "",
			"detail": ("running an unverified %s build of the sidecar; the integrity "
				+ "check applies to published builds only") % _name_for(source),
		}

	var result := verify(directory)
	return {
		"launch": result["ok"],
		"verified": result["ok"],
		"reason": result["reason"],
		"detail": result["detail"],
	}


static func _name_for(source: String) -> String:
	return source if source != "" else "unidentified"


## Check every file in `directory` against its manifest.
##
## Returns a Dictionary:
##   ok          bool    launchable
##   reason      String  learner-facing, "" when ok. Never contains a hash.
##   detail      String  maintainer-facing, for Diagnostics and the Output panel
##   checked     int     files hashed
##   elapsed_ms  int     how long it took, so the cost stays visible
##
## `directory` is an absolute path, not res://: the shipped binary is not a
## Godot resource and is not imported (there is a .gdignore beside it).
static func verify(directory: String) -> Dictionary:
	var started := Time.get_ticks_msec()
	var manifest_path := directory.path_join(MANIFEST_NAME)

	if not FileAccess.file_exists(manifest_path):
		return _refuse(
			"JoyStick Academy cannot verify its own files, so it has not started. "
			+ "Reinstalling the plugin from the Asset Library should fix it.",
			"no %s in %s -- a bundled install must always have one" % [MANIFEST_NAME, directory],
			0, started)

	var parsed := _parse(manifest_path)
	if parsed.has("error"):
		return _refuse(
			"JoyStick Academy's file list is damaged, so it has not started. "
			+ "Reinstalling the plugin from the Asset Library should fix it.",
			parsed["error"], 0, started)

	var expected: Dictionary = parsed["entries"]
	if expected.is_empty():
		return _refuse(
			"JoyStick Academy cannot verify its own files, so it has not started. "
			+ "Reinstalling the plugin from the Asset Library should fix it.",
			"%s lists no files at all, so it would verify anything" % MANIFEST_NAME,
			0, started)

	var present := _files_under(directory)
	var checked := 0

	for relative in expected:
		var full := directory.path_join(relative)
		if not FileAccess.file_exists(full):
			return _refuse(
				"Part of JoyStick Academy is missing, so it has not started. "
				+ "Reinstalling the plugin from the Asset Library should fix it.",
				"%s is listed in %s but is not on disk" % [relative, MANIFEST_NAME],
				checked, started)

		var actual := hash_file(full)
		checked += 1
		if actual == "":
			return _refuse(
				"JoyStick Academy could not read its own files, so it has not started. "
				+ "Reinstalling the plugin from the Asset Library should fix it.",
				"could not read %s to hash it" % relative, checked, started)
		if actual != expected[relative]:
			return _refuse(
				"JoyStick Academy's files do not match what was installed, so it has not "
				+ "started. Reinstalling the plugin from the Asset Library should fix it.",
				# The hashes go in `detail`, never in `reason`: a learner shown
				# two hex strings learns nothing and a maintainer reading a bug
				# report needs both.
				"%s does not match: expected %s, found %s"
					% [relative, expected[relative], actual],
				checked, started)

	# Nothing legitimately sits beside a single-file publish. An unlisted file
	# is a leftover from an older layout or something dropped in, and either way
	# the directory is not the one that was published.
	for relative in present:
		if relative == MANIFEST_NAME:
			continue
		if not expected.has(relative):
			return _refuse(
				"JoyStick Academy found a file it does not recognise, so it has not "
				+ "started. Reinstalling the plugin from the Asset Library should fix it.",
				"%s is present but not listed in %s" % [relative, MANIFEST_NAME],
				checked, started)

	return {
		"ok": true,
		"reason": "",
		"detail": "%d file(s) match %s" % [checked, MANIFEST_NAME],
		"checked": checked,
		"elapsed_ms": Time.get_ticks_msec() - started,
	}


## SHA-256 of a file, lowercase hex, or "" when it cannot be read.
##
## Streamed rather than read whole: these are 65 MB files, and get_file_as_bytes
## would put all of that in memory at once on the editor's own thread.
static func hash_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		file.close()
		return ""
	while not file.eof_reached():
		var chunk := file.get_buffer(CHUNK_BYTES)
		if chunk.size() > 0:
			context.update(chunk)
	file.close()
	return context.finish().hex_encode()


## Parse a manifest into {relative path: lowercase hex digest}.
##
## Returns {"entries": Dictionary} or {"error": String}. Every rejection is a
## rejection of the whole file: a manifest with one line this cannot read is a
## manifest that has been damaged, and silently skipping the line is how a
## check ends up verifying nothing.
static func _parse(manifest_path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(manifest_path)
	if text == "" and FileAccess.get_open_error() != OK:
		return {"error": "could not read %s" % manifest_path}

	var entries := {}
	var line_number := 0
	for raw in text.split("\n"):
		line_number += 1
		var line := raw.strip_edges()
		if line == "" or line.begins_with("#"):
			continue

		var split := line.find("  ")
		if split != 64:
			return {"error": "%s line %d is not '<64 hex><two spaces><path>'"
				% [MANIFEST_NAME, line_number]}

		var digest := line.substr(0, 64).to_lower()
		if not _is_hex(digest):
			return {"error": "%s line %d does not start with a hex digest"
				% [MANIFEST_NAME, line_number]}

		var relative := line.substr(66).strip_edges().replace("\\", "/")
		if relative == "":
			return {"error": "%s line %d names no file" % [MANIFEST_NAME, line_number]}

		# A manifest that can name a path outside its own directory can be
		# pointed at a file that legitimately matches, and the check passes
		# while the binary beside it is never looked at.
		if relative.begins_with("/") or relative.contains("..") or relative.contains(":"):
			return {"error": "%s line %d names a path outside the directory: %s"
				% [MANIFEST_NAME, line_number, relative]}

		if entries.has(relative):
			# Two lines for one file means one of them is not being checked,
			# and which one depends on parse order. That is not a manifest.
			return {"error": "%s lists %s twice" % [MANIFEST_NAME, relative]}

		entries[relative] = digest

	return {"entries": entries}


static func _is_hex(s: String) -> bool:
	for i in s.length():
		if not _HEX.contains(s[i]):
			return false
	return true


## Every file under `directory`, as paths relative to it, forward-slashed.
##
## Dot-files are skipped: .DS_Store and friends turn up beside anything copied
## on macOS, and refusing to launch over one would be a self-inflicted outage
## for no security gain, given what the header says this can and cannot defend
## against.
##
## THE RULE IS THE LEADING DOT, NOT DirAccess.include_hidden, and that is a
## correction rather than a preference. include_hidden asks the OS, and the two
## operating systems disagree about what the question means: on Unix a leading
## dot IS hidden, while on Windows hidden is a file ATTRIBUTE and a file called
## .DS_Store is an ordinary visible file. Leaving it to the flag made this
## listing and publish_host.py's files_under() -- which has always matched on
## the leading dot -- agree on macOS and Linux and disagree on Windows, where a
## dot-file would be absent from the manifest and present in this listing, and
## the addon would refuse to launch over it. Measured: the test for exactly
## this failed on Windows before the rule was made explicit here.
static func _files_under(directory: String, prefix: String = "") -> PackedStringArray:
	var found := PackedStringArray()
	var dir := DirAccess.open(directory)
	if dir == null:
		return found
	dir.include_hidden = true          # ask for everything, then apply OUR rule
	dir.include_navigational = false

	for file_name in dir.get_files():
		if file_name.begins_with("."):
			continue
		found.append(prefix + file_name)
	for sub in dir.get_directories():
		if sub.begins_with("."):
			continue
		found.append_array(_files_under(directory.path_join(sub), prefix + sub + "/"))
	return found


static func _refuse(reason: String, detail: String, checked: int, started: int) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"detail": detail,
		"checked": checked,
		"elapsed_ms": Time.get_ticks_msec() - started,
	}
