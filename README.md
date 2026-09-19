# JoyStick Academy for Godot

Learn game development inside the Godot editor. Open a walkthrough,
do the work, and watch the checks go green. Runs on standard Godot:
no .NET build, no SDK, nothing to install.

## This repository is a mirror

It carries **only what ships**, assembled from the published release
archives, and it exists so the Godot Asset Library has a public URL
to list. Development happens in a private repository.

**Do not open pull requests here.** Every publish replaces this
repository's entire history with a single commit, so anything added
here is lost at the next release. Issues and questions are welcome
at the address in the addon's own documentation.

## Version

`0.1.0`

## Supported platforms

The addon runs a small helper process beside the editor, and that
helper is a native binary, so support is per platform rather than
universal:

| Platform | Included |
|---|---|
| Windows x64 | yes |
| Linux x64 | yes |
| macOS Intel (x64) | yes |
| macOS Apple Silicon (arm64) | yes |

All four are present in this repository, so installing it works on
any of them without picking a build. The editor selects the one that
matches the machine it is running on.

## Install

Copy `addons/joystickacademy` into your project's `addons/` folder,
then enable **JoyStick Academy** in Project > Project Settings >
Plugins.

See `LICENSE.md` and `THIRD-PARTY-NOTICES.md` for licensing.
