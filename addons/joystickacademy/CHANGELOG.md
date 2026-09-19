# Changelog

All notable changes to the JoyStick Academy Godot addon.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Every number in here was measured on the day it was written.** A count that
could not be measured is absent rather than estimated — plan 10's most expensive
lesson was a README describing a plugin as it had been planned rather than as it
shipped.

## [Unreleased]

### Added

- **Sign in by pairing this editor to your phone.** The panel shows a short
  code; you type it into JoyStick Academy under Account → Pair a plugin, and the
  panel moves on by itself. There is no scanner on the editor side, and the page
  says so. The code is shown exactly as the server issued it, because the server
  matches on what it sent and nothing else.
- **Walkthroughs, with the checks live underneath the step.** Make the edit the
  step asks for and the strip follows within a couple of seconds, without
  pressing anything. A step with checks gates Next and says what is outstanding;
  a step with none advances freely.
- **Steps that can only be answered by running the game get a Run button.**
  Eight of the twenty check kinds watch a game rather than read a project, and
  those cannot follow along by themselves: the panel launches the scene you have
  open with an observer in it, watches the run, and checks the step against what
  it saw. Godot's own Play button will not do, because that game has no observer
  in it and nothing is recorded.
- **Resuming into the step you stopped at**, with four refusals: not if you have
  already navigated, not into a different lesson, not to a step the lesson no
  longer has, and not to step one.
- **Hand-off from the phone.** "Practise this in Godot" surfaces the lesson in
  the panel, and the phone's progress screen follows the step you are on.
- **Gem-cost hints**, charged before they are revealed.
- **Glossary definitions** from `**term:X**` tags in step bodies, opened by
  tapping the term.
- **Capstone studio and submission**, with milestones verified live.
- **Your standing** — XP, streak, lessons — and a **diagnostics page** that
  tells the four ways this can be broken apart rather than reporting one verdict.
- **The verifier engine**, answering 17 of the 20 kinds the content vocabulary
  uses. `compiles_cleanly`, `count_of_prefabs` and `terrain_has_layers` are
  refused as unsupported on this engine rather than silently failing; see
  [docs/verifier-kinds.md](docs/verifier-kinds.md) for what each one measures and
  why these three cannot be.

### Notes

- **Runs on stock Godot 4.5+.** Not the .NET build. Nothing to install: the
  shared C# core ships inside the addon as a self-contained sidecar process the
  addon launches and talks to over pipes.
- **Windows, Linux and macOS**, one platform's sidecar per download.
- **The binaries are not signed or notarised.** On Windows, SmartScreen may warn
  the first time the sidecar starts; on macOS, Gatekeeper may refuse it until it
  is allowed in System Settings → Privacy & Security. Recorded here as a known
  limitation rather than left to be discovered.
