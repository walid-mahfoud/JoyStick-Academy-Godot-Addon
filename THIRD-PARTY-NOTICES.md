# Third-party notices

What ships inside the JoyStick Academy Godot addon that was not written for it.

**This list was derived from the build rather than from memory.** The shipped
dependency graph is `JoyStickAcademy.Host.deps.json` from a Release
self-contained publish, read on 2026-09-18: it names **one** package, and that
one is a build-time tool that does not ship. Everything else in the archive is
either ours or part of .NET itself.

## The .NET 8 runtime and base class library

**Microsoft, MIT licence.** <https://github.com/dotnet/runtime/blob/main/LICENSE.TXT>

The sidecar is published **self-contained**, which means the .NET runtime and
the base class libraries are bundled inside the single executable at
`addons/joystickacademy/bin/<platform>/`. That is the whole reason a learner
does not have to install anything: the alternative, a framework-dependent
build, needs .NET on their machine, and this architecture exists to avoid
exactly that.

Nothing is redistributed in source form and nothing is modified.

## Nothing else

There is no third-party NuGet package in the shipped graph, and that is a
decision rather than an accident:

* **The shared Core builds its own JSON by hand.** `Telemetry/PostHogClient.cs`
  says why in its own comment — it avoids `JsonUtility`'s limitations and avoids
  "pulling Newtonsoft.Json into the plugin's dependency surface". Measured:
  there is no `using Newtonsoft` anywhere in Core.
* **The host uses `System.Text.Json`**, which is part of .NET rather than a
  package.
* **The addon is GDScript and vendors nothing.** In particular it does **not**
  vendor a test framework: the suite in `Tests/` is about a hundred lines of our
  own, because GUT and gdUnit4 are both Godot *addons* and vendoring one into a
  repository whose product is an addon puts it inside `addons/` beside ours, to
  be excluded from the package by name and possibly enabled by a learner.

## Development-time only, not shipped

Named so the absence is a statement rather than an oversight.

| Tool | Licence | Where |
|---|---|---|
| `Microsoft.NET.ILLink.Tasks` | MIT | build-time trimming analysis; no output in the archive |
| NUnit, NUnit3TestAdapter, Microsoft.NET.Test.Sdk | MIT | `Host/JoyStickAcademy.Host.Tests/`, which the packaging script excludes |

`Tools/package_addon.py` refuses to write an archive containing `Host/` or
`Tests/`, so none of these can reach a learner by accident.

## The addon itself

Proprietary. JoyStick Studios SARL AU, all rights reserved. See [LICENSE.md](LICENSE.md).
