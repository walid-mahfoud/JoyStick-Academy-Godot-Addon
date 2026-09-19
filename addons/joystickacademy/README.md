# JoyStick Academy — Godot addon

Learn game development inside the Godot editor. Open a walkthrough, do the work
in your own project, and watch the checks go green as you do it. The XP, the
gems and the streak land on your phone, because it is the same account.

The Godot counterpart to the Unity and Unreal editor plugins.

> **Every number in this file was measured on the day it was written.** A count
> that could not be measured is absent rather than estimated. Plan 10's most
> expensive lesson was a README describing a plugin as it had been planned
> rather than as it shipped.

## What makes it different from the other two

It is a **GDScript** addon and it runs on **stock Godot** — not the .NET build.
There is nothing for a learner to install: enable the addon and it works.

The shared C# Core still runs, as a **self-contained sidecar process** bundled
inside the addon, which the addon launches and talks to over pipes. So this is
the first of the four engines where Core is not in the editor's process, and
that is where most of the engineering lives. Why, at length:
[docs/architecture-decision.md](docs/architecture-decision.md).

## Installing

Download the archive for your platform and copy `addons/joystickacademy/` into
your Godot project, then enable **JoyStick Academy** in Project → Project
Settings → Plugins.

One platform's sidecar per archive, deliberately: four is a quarter of a
gigabyte, three quarters of which can never run on the machine that downloaded
it.

**The binaries are not signed or notarised.** Windows SmartScreen may warn the
first time the sidecar starts, and macOS Gatekeeper may refuse it until you
allow it in System Settings → Privacy & Security. Recorded here rather than left
to be discovered.

## Supported Godot

**4.5+, stock build.** `Tools/check_stock_godot.py` asserts both, and the
runtime half of that check asks the engine rather than the filesystem:

```bash
python Tools/check_stock_godot.py --godot <path-to-godot>
```

One measurement worth carrying, because it contradicts a note elsewhere in this
project: `--build-solutions` **is** listed in `--help` on the stock 4.5.1 build,
so it identifies nothing. The markers are `GodotSharp/` on disk and
`ClassDB.class_exists("CSharpScript")` at runtime.

## What it does

* **Sign in** by pairing this editor to your phone. The panel shows a code; you
  type it into the app under Account → Pair a plugin. There is no scanner on the
  editor side, and the page says so.
* **Walkthroughs**, with the checks live underneath the step. A step with checks
  gates Next and says what is outstanding; a step with none advances freely.
* **Resume** into the step you stopped at, with four refusals — not if you have
  navigated on, not into a different lesson, not to a step the lesson no longer
  has, and not to step one.
* **Hand-off from the phone.** "Practise this in Godot" surfaces the lesson
  here, and the phone's progress screen follows the step you are on.
* **Hints** you pay gems for, **glossary** definitions from `**term:X**` tags,
  **capstones** with live verification and submission, **your standing**, and a
  **diagnostics page** that tells the four ways this can be broken apart.

## What it can and cannot check

The verifier engine answers **17 of the 20 kinds** the content vocabulary uses.
`compiles_cleanly`, `terrain_has_layers` and `has_win_condition` are refused as
**unsupported on this engine** rather than silently failing, because "Godot
cannot check this kind of thing" and "it tried and something went wrong" are
different sentences that go to different people.

The eight play-mode kinds need the game itself to run, so a step carrying one
shows a **Run your game** button: the panel launches the scene you have open
with an observer in it, watches what happens, and checks the step against that.
Pressing Godot's own Play button instead will not do — that game has no observer
in it, so nothing is recorded.

What each kind measures, and the measurement behind each refusal:
[docs/verifier-kinds.md](docs/verifier-kinds.md).

## Layout

| Path | What lives there |
|---|---|
| `addons/joystickacademy/` | The GDScript addon: everything Godot loads. |
| `Host/` | The .NET sidecar that hosts the shared Core. |
| `Tools/` | Check and packaging scripts. Each one self-tests. |
| `Tests/` | The GDScript suite. |
| `docs/` | Decisions and protocol specs. |

## Building it yourself

```bash
python Tools/publish_host.py --rid win-x64   # or linux-x64, osx-x64, osx-arm64
python Tools/package_addon.py --rid win-x64
```

`package_addon.py` inspects what it is about to zip rather than what is in the
repository, and refuses to write an incomplete archive. That is not caution: the
Unreal plugin shipped 1.0.0 with no README inside it, because everybody assumed
it was there and nothing looked.

## Running the checks

```bash
godot --headless --script Tests/run_tests.gd    # the addon suite
python Tools/check_suite_clean.py               # ...and no script errors in it
dotnet test Host/JoyStickAcademy.Host.Tests     # the sidecar suite
python Tools/check_addon_enables.py             # enable it in a real editor
```

`check_suite_clean.py` is not redundant with the suite. **A GDScript runtime
error aborts the enclosing function and nothing raises**, so a test that hits one
reports the assertions it already made and prints a green line; the only sign is
a `SCRIPT ERROR:` in output nothing reads. It has caught exactly that.

## License

Proprietary. JoyStick Studios SARL AU, all rights reserved. See [LICENSE.md](LICENSE.md).
