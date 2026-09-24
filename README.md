# PenguinRacer

A [Godot 4.7](https://godotengine.org/) rebuild of
[Extreme Tux Racer](https://sourceforge.net/projects/extremetuxracer/) 0.8.4 — downhill penguin
racing with the original's physics model, its 44 courses and its five characters, plus real snow
deformation, computer opponents and ghost replays the original never had.

One project ships to two places: **the web** (WebGL2, Godot's Compatibility renderer) and
**desktop native** (Vulkan, Godot's Mobile renderer). Both targets matter equally, and the
difference between them is a deliberate, gated seam rather than an accident.

> **Status: playable, not finished.** Physics, the content pipeline, the characters and the game
> shell are done or nearly so; rendering and snow integration are partial; polish has not started.
> See [PROGRESS.md](./PROGRESS.md) for the running log and the known gaps, which are catalogued
> honestly rather than quietly.

---

## What this is, and what it is not

**This is a rebuild, not a port.** No C++ was translated line-for-line. The original is treated as
two separable things:

* **A simulation.** ETR's force model and its tuned constants *are* the game — the way Tux
  accelerates, the way a carve bites, how much a paddle stroke is worth at 40 km/h against what it
  is worth at 90. That model is reproduced faithfully, from a written analysis of the original
  source ([`etracer.md`](./etracer.md) §4.1) rather than from the source text itself, so the
  implementation is a GDScript expression of the documented physics.
* **Everything else.** Renderer, data formats, scene graph, menus, audio mixing, object placement
  — all redesigned around Godot's grain, with the original's *content* imported into the new
  shape by a one-way importer that never writes back.

So: a 2026 codebase that drives like a 2010s game, on courses hand-built by people who are
credited below.

What it is **not**: it is not a fork of the ETR C++ tree, not a content reskin, and not a faithful
reproduction of ETR's *looks* in every particular — a handful of places knowingly do better than
the original, and each one is marked `DEVIATION` in the source with its reason.

---

## What is in the box

| | |
|---|---|
| **Courses** | All 44, imported from the original data, with their events and difficulty thresholds |
| **Characters** | Tux, Trixi, Boris, Samuel and Beastie — skinned rigs with the original's keyframe animations, start sequence and finish clips |
| **Terrain** | 43 material types, friction blended per-texel, splat-mapped PBR over a float32 heightmap |
| **Modes** | Practice against the clock, a field of 1–9 computer opponents, a ghost of any saved run, and network multiplayer for up to eight people — desktop and browser in the same race |
| **Snow** | GPU trail deformation with a shaded trench and a ploughed lip, plus carve spray and four levels of falling snow |
| **Weather** | The original's three race-screen controls: how hard it is snowing; the sky — sunny, cloudy or night, each with its own migrated light, fog and skybox; and a crosswind — none, light or strong, from the left or the right — that bends the trees, drives the snow and nudges a penguin in flight |
| **Sky** | Drawn, not photographed: a sun disc, drifting clouds and distant mountain ranges; haze that takes the sky's colour and mist lying in the valley; at night stars, a moon, an aurora, and torches down the course and in place of the flags. The original's skybox and flat fog are one setting away |
| **Shell** | Main menu, course and character screens, the multiplayer lobby, in-race HUD, results and settings, 13 languages |
| **Server** | One headless process serves the web build over HTTP and the race sessions over WebSocket — `tools/serve.sh` |
| **Tests** | 4951 headless assertions, 0 failures, 11 s — physics, surface, input, audio, terrain, camera, replay, opponents, the lobby server |

---

## Quick start

Needs **Godot 4.7.2** on `PATH` as `godot`, and a read-only copy of the ETR 0.8.4 data tree — which
is in this repository at `etr-0.8.4/`.

```bash
./tools/import_all.sh                 # migrate the original content (once)
godot --path game                     # play
godot --path game -- --course=bunny_hill --opponents=5 --difficulty=hard
godot --headless --path game --script res://tests/run_tests.gd   # the suite
./tools/serve.sh                      # a multiplayer server, and the web build behind it
```

The desktop build wants Vulkan; the web build wants Godot's export templates. Every flag, the
web build, the settings file, the capture-and-compare harness and the project layout are in
**[docs/DEVELOPMENT.md](./docs/DEVELOPMENT.md)**.

---

## Design decisions

The eight decisions below are the ones that shaped everything else. Each is a rule the code is
held to, not an aspiration.

### 1. The physics core knows nothing about Godot

`RacePhysics` is a plain `RefCounted` stepped against a `SurfaceProvider` interface. No nodes, no
scene tree, no rendering. That single constraint is what makes a 4700-assertion headless golden
test suite possible, lets the simulation run at a fixed rate independent of the frame rate, and
means a computer opponent, a network peer and the player are literally the same code.

The ODE integrator is adaptive (ODE23), and the stage-3 force evaluation is reused as the next
step's first stage — three evaluations per accepted step instead of four. That, plus a uniform
spatial grid where the original did a linear scan of every tree per substep, is what bought the
headroom to run the whole thing in GDScript.

### 2. GDScript, because the web target says so

C# has no web export in Godot, and GDExtension on the web is fragile. So gameplay is GDScript,
and the question of whether that is fast enough was answered before anything was built: a spike
measured the integrator at **0.045 ms/frame native and 0.073 ms in a browser** — 0.44 % of a
16.7 ms frame. The Rust-GDExtension contingency was cancelled on that number rather than carried
around as an option.

### 3. Two renderers, and the web one is the floor

The desktop runs **Mobile** (Vulkan); the web runs **Compatibility** (WebGL2), which is the only
thing a browser offers. The rule: nothing may *depend* on a feature Compatibility lacks — no
compute shaders, no `RenderingDevice`, no HDR, no SSR/SDFGI/TAA — but a desktop build may **add**
one behind a gate, as long as the web frame without it is still a frame worth shipping.

This started as a single-renderer project and was corrected when the cost became measurable: under
Compatibility a shadow-casting light is moved into a second additive pass that is blended in
**sRGB** rather than linear, so the sun arrives five to ten times too bright with its N·L gradient
crushed flat — and no shader can reach a framebuffer blend. Shadows are therefore desktop-only,
`RenderBackend.supports_light_shadows()` is the gate, and they are the only thing through it so
far.

### 4. Snow is represented twice on purpose

Gameplay never reads back from the GPU, because a readback stalls the browser. So the snow
deformation field exists as two things that deliberately do not match:

* **`SnowFieldGPU`** — 1024², a 64 m window that scrolls toroidally with the player, ping-ponged
  between `SubViewport`s in a fragment shader. This is what you see: the trench, its self-occluded
  floor, the bright ploughed lip.
* **`SnowField`** — a 128² CPU mirror. This is what you feel: packed snow is faster than fresh,
  and grooming left by nine opponents counts for the tenth.

One is for pixels and one is for feel, and neither is authoritative over the other.

### 5. The course format had to go

ETR stores a course as PNGs: 8-bit elevation over a 7–10 m scale (2.7–3.9 cm of quantization, and
visible terracing that the original masks with normal smoothing), terrain type as an RGB colour
key matched within ±30, and objects as colour-keyed pixels in eight legacy colours — which means
no rotation, no per-instance scale, everything snapped to the same ~1 m grid, and a course that is
always an axis-aligned rectangle.

Format v2 is a Godot scene plus a typed `Resource`: a **float32 heightmap**, **authored splat
weight maps** with the three resolutions (elevation, material, object placement) decoupled,
objects as **real scene nodes**, and play bounds as a polygon instead of a sub-rectangle. The
original content is migrated into it; the format no longer limits what can be authored next.

### 6. The importer is one-way and re-runnable

`etr-0.8.4/` is read-only and is never written to, at import time or at runtime. Everything
generated lands under `game/courses/` and `game/resources/`, and each generated resource carries an
`import_fingerprint`. A course you have since edited in the Godot editor no longer hashes to its
fingerprint and is skipped unless you pass `--force` — so re-running the importer after an upstream
change cannot silently eat hand-authored work.

### 7. A racer is whatever fills a `RacerState`

The presentation layer reads one packed struct and nothing else, so it cannot tell the player from
a computer opponent, from a replay ghost, from a network peer. Adding a new kind of racer means
adding an `InputSource`, not a branch in the drawing code. This is the seam the opponents, the
ghosts and the netcode were all built on, and none of the three required changing it.

The struct is 18 floats, and it is a file format and a wire format at the same time: appending a
field is a version bump, and moving one silently reinterprets every ghost anyone has saved.

### 8. Fixed tick, interpolated presentation

The simulation runs at a fixed 60 Hz and `_process` interpolates up to the frame. Nothing that
affects the race may run on frame time — input is polled with the tick length. Only the camera lag,
the streaming window, the particle rates and the deformation render target get the screen's rate.
ETR stepped its ODE with the frame time, which makes a run un-reproducible; here a recorded input
trace replays identically, which is what makes both the ghosts and the automated screenshot
comparisons possible.

### Beyond the original

Four things here that ETR does not have, all of them falling out of the decisions above rather
than bolted on: **snow that deforms**, **1–9 computer opponents** (same physics, same tick — only
their driving habits change with difficulty; they are solid, and they collect herring first-come
first-served), **ghost replays** of any saved run, and **network multiplayer** for up to eight
people on one hill.

Multiplayer runs against one dedicated server, which is this same project run headless — it hands
out the WebAssembly build over HTTP *and* accepts the race sessions those pages open, so a player
on a desktop and a player in a browser tab are in the same room on the same protocol. Open the
lobby and you get every race not yet started; create one with a name and an optional password and
you are its admin, the only one who can pick the course and press Start. Nobody races until the
last machine has the hill built, and then a three-second countdown starts the whole field
together. Every peer simulates only itself and publishes 20 snapshots a second; the server relays
them unread and has no authority over anybody's position. And **the race is over when the last
player crosses the line, not the first** — after your own finish the camera follows whoever is
still coming down, and everyone gets the same finishing order at the same moment.

And one thing the web needed: the browser build is **streamed**. A slim ~65 MB base (engine, shell,
44 preview thumbnails) plus one `.pck` per course fetched on demand, against 161 MB if it were all
one bundle. A native build is unaffected.

---

## How this was built

**Most of this codebase was written by large language models, under human direction.** That is
worth saying plainly on the front page rather than leaving it to be inferred from the commit
history.

The bulk of the work — the GDScript, the shaders, the importer, the test suite and this
documentation — came from **Claude Opus** and **Claude Sonnet**, with smaller contributions from
**DeepSeek V4** and **GLM 5.x**. The direction, the architecture decisions, the physics analysis
in [`etracer.md`](./etracer.md) and the judgement about what was actually finished were human.
Commits are attributed to the repository's author in the ordinary way; there are no per-commit
model trailers, because the disclosure belongs here, once, where someone will read it.

What that means for you as a reader:

* **The physics is the part that was checked hardest.** ETR's force model was reimplemented from
  a written analysis of the original rather than translated, then held to 4724 headless golden
  assertions. Where the constants are the game, the tests are the argument.
* **The traps list is not decoration.** [`AGENTS.md`](./AGENTS.md) catalogues the mistakes this
  process actually made — a shadow pass blended in the wrong colour space, a stripe of wrong
  friction, three loops that did not need to be loops. They were found by running the thing and
  comparing captures, not by reading the diff.
* **[`PROGRESS.md`](./PROGRESS.md) is the honest ledger.** Generated code is confident about
  everything, including the parts that do not work. The known gaps are written down deliberately
  and in detail, and the status line above is kept in step with them.

Review it as you would any other unfamiliar contribution: the tests and the capture harness are
there to be run.

---

## Documentation

This repository documents its own reasoning at length. The short version of where to look:

| File | What it is for |
|---|---|
| [`docs/DEVELOPMENT.md`](./docs/DEVELOPMENT.md) | Commands, prerequisites, layout, the web build, the capture harness |
| [`PROGRESS.md`](./PROGRESS.md) | What is built today and what is knowingly missing — the running log |
| [`godot-port-plan.md`](./godot-port-plan.md) | The architecture and data model in full, with its dated corrections |
| [`etracer.md`](./etracer.md) | Analysis of the original C++: §4.1 is the authoritative physics constants, §5 the legacy file formats |
| [`materials.md`](./materials.md) | How a terrain material works end to end, and why `terrains.lst` has seven kinds of ice |
| [`history.md`](./history.md) | How it got here: the de-risking spikes, and the nineteen things the plan did not know |
| [`AGENTS.md`](./AGENTS.md) | The working rules for this codebase, including the traps found the hard way |

---

## Legal

### Licence

**PenguinRacer is licensed under the GNU General Public License, version 2 or (at your option) any
later version** — the same terms as Extreme Tux Racer, which it is derived from. The full text is
in [LICENSE](./LICENSE).

This is not a free choice. The project's physics model is derived from ETR's GPL-2.0-or-later
implementation, and the shipped courses, characters, textures, skyboxes, audio and translations are
derivative works of ETR's data. A derivative of GPL-2.0-or-later work is distributed under
GPL-2.0-or-later.

```
This program is free software; you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation; either version
2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.
```

### Copyright

Copyright in this repository is **layered, and held by many people**. The new work does not
supersede or absorb anyone's rights in the original:

* **Copyright © 2026 Clemens Eisserer** — the Godot rebuild: the GDScript, the shaders, the
  importer, the new data model, and the features that have no ETR equivalent.
* **Copyright © 2011–2024 The Extreme Tux Racer Team** — ETR 0.8.4, its courses, its data and its
  assets, from which everything here is derived.
* **Copyright © 1999–2000 Jasmin F. Patry** — the original Tux Racer that ETR itself continues.
* **The individual contributors named in the credits below**, who hold copyright in their own
  courses, models, music and translations.

The complete unmodified upstream source and data tree is included at
[`etr-0.8.4/`](./etr-0.8.4/), with its own `COPYING` and `AUTHORS`, so the provenance of every
migrated asset can be traced and the GPL's source requirement is met for the derived work.

### Asset licensing — an open item, read this before redistributing

ETR's data assets have **mixed authorship**, recorded in `etr-0.8.4/data/credits.lst` and
`etr-0.8.4/AUTHORS`. A per-asset licence audit **has not been completed**, and it is tracked as an
open risk in [PROGRESS.md](./PROGRESS.md).

In the meantime the project is conservative where it can be: ETR's menu ornaments, title logo and
HUD textures are **deliberately not in this tree**. The HUD is redrawn from `hud.cpp`'s own layout
constants as primitives, the spray atlas and the falling-snow curtain tiles are redrawn rather than
copied, and the menus reproduce ETR's colour palette rather than its art.

If you intend to redistribute a build, or to reuse an individual asset outside the GPL context it
arrived in, check that asset's authorship yourself. Contributions to the audit are welcome.

### Names

"Tux Racer" has a commercial history — the name went to a closed-source release after the original
free version — which is why the free continuations are named differently. The ETR team grants the
use of theirs explicitly, in their own credits screen:

> Use of the name "Extreme Tux Racer" is granted to any forks or continuations.

This project nevertheless carries its own name, and claims no affiliation with or endorsement by
the Extreme Tux Racer team, the Tux Racer authors, or the Godot Engine project. **Godot** is a
trademark of the Godot Foundation; it is used here only to say which engine this runs on.

**Tux** was created by Larry Ewing with The GIMP, and is used with the acknowledgement he asks for:
credit to lewing@isc.tamu.edu and The GIMP.

---

## Credits

This game exists because other people built it first.

**Tux Racer** — Jasmin Patry, Eric Hall, Patrick Gilhuly, Rick Knowles, Vincent Ma, Mark Riddell.

**The Extreme Tux Racer team** — Steven Bell, Kristian Picon, Nicosmos, R. Niehoff, Philipp Kloke,
Marko Lindqvist.

**Music** — Grady O'Connell, Kristian Picon, Karl Schroeder, Joseph Toscano.
**Graphics** — Nicosmos (logo, HUD, interface), Kristian Picon (objects, skyboxes, characters),
Daniel Poeira and K. Picon (Papercuts font).
**Courses** — the many course creators credited upstream.
**Translations** — Pavel Borecki (cs), Marko Lindqvist (fi), Sylvain St-Amand and Syl (fr),
Philipp Kloke (de), Jonatan Nyberg (sv), Viliam Bur (eo), Rogonow (nl), Andrei Ionel (ro),
Jorge Maldonado Ventura (es), João Frade (pt), and the translators before 0.6.0 whose names were
not recorded.

**And** Larry Ewing for Tux, Ulrich Thatcher for the quadtree algorithm ETR used, and everyone
thanked in `etr-0.8.4/data/credits.lst`.

## Contributing

Issues and pull requests are welcome. Two things worth knowing first: the architecture rules in
[AGENTS.md](./AGENTS.md) are load-bearing (particularly "the physics core has no node
dependencies" and "nothing may depend on a feature the web renderer lacks"), and any intentional
difference from the original's behaviour is marked `DEVIATION` in the source with a reason. Run
the headless suite before opening a PR:

```bash
godot --headless --path game --script res://tests/run_tests.gd
```

By contributing you agree that your contribution is licensed under GPL-2.0-or-later.
