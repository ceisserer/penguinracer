# REVIEW.md — structure and performance

A read of the tree at `c934a6b`, plus five throwaway benchmarks run headless against the real
course data. Two questions were asked: **what would I re-structure**, and **where does GDScript's
speed actually hurt**. They have different answers, and the second one is the more interesting:
the ODE loop everybody worried about is fine, and the two things that cost frames were never
measured.

Nothing here is a correctness complaint. The physics suite is 3580 assertions green in 2.5 s, the
layering rules in AGENTS.md are actually obeyed by the code, and the racer/`RacerState` seam does
what its docstring claims — `AIInputSource` really did drop in without the presentation learning
about it. What follows is about size, duplication and frame time.

---

## Method

All numbers below are native, headless, on this container's CPU, measured with
`Time.get_ticks_usec()` over 3600 frames (60 s of simulated racing) unless stated. Benchmark
scripts were temporary and have been removed; each one is reproduced in the appendix so the
numbers can be re-taken.

I did **not** re-measure in a browser. Where a web figure is quoted it is this repository's own
S2 ratio — 0.045 ms native against 0.073 ms in Chromium/WebGL2, i.e. **≈1.6×** — applied to a
native measurement, and it is marked as such. The chunk-streaming measurement also excludes the
actual GPU submission of the new mesh, so the real hitch is at least as large as reported.

---

# Part 1 — What I would re-structure

Ranked by what it buys, not by how much code it moves.

## 1. `RaceScene` is five objects wearing one hat (1094 lines)

`scripts/race/race_scene.gd` is the largest gameplay file by a factor of 1.3 over the physics
core, and it is large for the ordinary reason: it accreted every new feature because it was the
only place that could see everything. It currently owns

- the fixed-tick loop and the presentation interpolation (`_process`, `_simulation_tick`, `_present`),
- **the racer roster** — building the local player, building and rebuilding the field, spawning and
  reaping network peers, loading the ghost, publishing the `RacerField`, and the standings
  (`_create_local_racer:300` … `_add_racer:405`, `_refresh_rivals:641`, `_spawn_remote:790`,
  `_sync_remote_racers:806`, `standings:819`, `place_of:842`),
- **the start-animation state machine** (`_begin_intro:700` … `_end_intro:757`, plus four
  `_intro_*`/`_camera_*_before_intro` members that exist only for it),
- course loading and teardown,
- environment application and shadow-range derivation,
- the pause/menu/scene-transition shell,
- and the audio event handlers, including the terrain slide loop.

Two of those come out cleanly and are worth taking:

**`RacerRoster`** (a `RefCounted`, or a thin `Node3D` replacing `$Racers`) owning `racers`,
`local`, `opponents`, `ghost`, `_remote`, `_rivals` and `view_target`, with `add`, `rebuild_field`,
`refresh_rivals`, `standings`, `place_of`, `spawn_remote`, `sync_remote`. That is roughly 250
lines, it is the part with the most invariants (the slot indices in `_refresh_rivals` must agree
with `Racer.collides()`, which must agree with what `AIInputSource.rivals` is handed), and those
invariants are currently enforced by three methods that happen to sit near each other in one file.
It is also the piece a spectator mode, a lobby, or a "restart keeps the field" feature all have to
touch.

**`IntroSequence`** — the ~90 lines from `_begin_intro` to `_end_intro`, plus `_intro_path`,
`_intro_time`, `_camera_mode_before_intro`, `_camera_distance_before_intro`, `_intro_enabled`.
It is a self-contained state machine with two exits (ran out, or a key), it borrows the camera and
gives it back, and it is stepped from the tick like anything else. As a small object with
`begin(rig, course, camera)` / `step(dt) -> bool` / `abort()`, `RaceScene` keeps one
`intro_running` bool and one call.

After both, `RaceScene` is ~700 lines and reads as what its docstring says it is: the tick loop
and the course.

I would **not** split out course loading or the environment — they are short, they are only called
from `load_course`, and pulling them out would buy an indirection and no invariant.

## 2. Command-line and URL parsing happens in six places, and the two transports have drifted

`OS.get_cmdline_user_args()` is walked independently in `main_menu.gd:237`, `main_menu.gd:248`,
`race_scene.gd:254`, `race_network.gd:291`, `audio_director.gd:140` and `debug_capture.gd:16`
(plus `game_config.gd:304` on the *engine* args). `_url_query()` — the browser's stand-in for a
command line — exists only in `MainMenu`, is called four times, and each call is a fresh
`JavaScriptBridge.eval`.

The consequence is not style, it is a capability gap nobody wrote down. Desktop understands
`--course`, `--character`, `--no-intro`, `--auto-input`, `--camera`, `--remote-keyboard`,
`--no-audio`, `--opponents`, `--difficulty`, `--capture`, `--host`, `--join`. The browser
understands `course`, `character`, `nointro`, `autostart`. So `?opponents=5&difficulty=hard`
silently does nothing, and the web build cannot start a race against the computer except through
the menu — which is fine as a decision and invisible as an accident. `--course=` is additionally
parsed *twice*, in `MainMenu` and again in `RaceScene`, with a precedence rule
("the shell outranks the command line here, unlike `--course=`") that only exists because both
read it.

I would add one `LaunchArgs` value object, parsed once at boot from whichever source the platform
has, exposing typed fields. It removes six scans, makes the desktop/web matrix a single list you
can read, and turns "the browser has no `--opponents`" into a line of code rather than an absence.

## 3. Four static mutable fields are the shell→race channel

`RaceScene.requested_course_path`, `requested_character`, `requested_setup` and `play_intro` are
`static var`s written by `MainMenu` just before `change_scene_to_file`, plus
`MainMenu._boot_handled`. The reasoning in the docstrings is sound as far as it goes — a scene
about to be built has no instance to set a property on — and it was one string when it was
written. It is now four values with four different lifetime rules, each documented in prose
("cleared by nobody, so a session keeps racing the field it chose"), and it is why `MainMenu` has
a parse-time type dependency on `RaceScene`.

One `RaceRequest` `RefCounted` — course, character, setup, intro — handed through an existing
autoload would give the four values one lifetime, one place to clear them, and one place to
document the rule. This is a genuine trade (it is a fifth global against four static fields) and I
would call it a small win rather than an obvious one. Worth doing when the lobby lands, because a
lobby adds a fifth field to the current arrangement.

## 4. The importer is one 1849-line class over ten unrelated domains

`addons/etr_import/etr_import.gd` covers terrains, audio, heightmaps, splat construction, objects,
courses, events, environments, translations and characters. Nothing structural forces it to be one
file — the passes barely share state, and the shared helpers (`_log`, `_warn`, `_protected`,
`ensure_dir`, `copy_file`, `load_external_image`) are six short functions.

It is an offline tool, so this costs nothing at runtime and is the lowest-risk split in the tree:
`etr_terrains.gd`, `etr_course.gd`, `etr_characters.gd`, `etr_audio.gd`, `etr_env.gd`,
`etr_i18n.gd`, with `etr_import.gd` reduced to the driver, the fingerprint logic and the shared
helpers. The reason to bother is that the character importer alone is 470 lines and is the part
most likely to grow (the procedural `AdjustJoints` layer in Phase 4 is not written yet), and
right now every change to it re-touches the file that also owns the splat blur.

## 5. Small structural items

- **`SprayEmitter.emit_for_substep:108` allocates a `SurfaceSample` per substep** and samples a
  point its own caller has already sampled. `SimulatedRacer._on_substep:147` carefully reuses a
  member `_sample` — and then calls the spray, which does `var sample := SurfaceSample.new()` and
  re-queries the same `(x, z)`. Pass the caller's sample in; that is one allocation and one full
  surface query per substep removed, and it makes the two agree about the terrain by construction.
- **`CourseRoot._item_instances:19` stores `[type_name, slot]` and re-resolves
  `get_node_or_null("Batch_%s")` on every `hide_item:84` and every entry of `reset_items:101`.**
  Store the `MultiMeshInstance3D` reference. A restart on a fish-heavy course is currently one
  string format and one node lookup per collected herring.
- ~~**`RaceScene.place_of:842` is a second sort for a question the first sort already
  answered.**~~ **Withdrawn.** `place_of` is called once, from `_result_line`, at the finish — not
  on the frame path. `RaceHUD._show_standings:86` does call `standings()` every frame, but that is
  one `duplicate` and a ten-element sort, which is genuinely nothing. No change made.
- **`ObjectGrid.build:39` read-modify-writes a `PackedInt32Array` per insertion**
  (`var arr = _cells[k]` … `arr.push_back(i)` … `_cells[k] = arr`). Packed arrays are
  copy-on-write, so each insert into an occupied cell copies the cell. Occupancy is low so this is
  bounded, but building the grid from an `Array[PackedInt32Array]` and converting once is both
  shorter and linear.
- **`terrain_layer.gd` still has no consumer for some of what it carries** — the trap list already
  records `normal`/`roughness` as the lesson. Worth a periodic sweep, since `materials.md` says the
  shader is at 13 of WebGL2's guaranteed 16 fragment texture units and cannot grow.

---

# Part 2 — Where GDScript is actually the problem

## The short answer

**Not in the physics.** The measured cost of one racer's full simulation — ODE23 with adaptive
retries, surface queries, tree and item grids, racer contacts — is **0.047 ms/frame**, and
0.050 ms with the CPU snow field attached. Ten AI-driven racers on one hill, each with its own
`RacePhysics` and its own planner, cost **1.16 ms/frame** together. At the project's own 1.6× web
ratio that is ~1.9 ms of a 16.7 ms browser frame for a full field of ten. Risk S2's verdict holds
and the GDExtension contingency should stay unbuilt.

**Yes in two places, and neither of them is the ODE loop.** S2 measured the thing the plan was
afraid of. The two things that actually drop frames were never on the list.

| What | Measured | Per what |
|---|---|---|
| One racer, full simulation | 0.047 ms | frame |
| One racer + CPU snow field | 0.050 ms | frame |
| **Ten AI racers + snow** | **1.16 ms** | **frame** |
| `SnowField.stamp` | 0.005 ms | call (~1.2/frame/racer) |
| **`SnowField.decay`** | **0.744 ms** | **every tick** |
| `SnowField.recenter` | 0.058 ms | every tick |
| **`TerrainRenderer._build_chunk`** | **6.5–7.7 ms** | **chunk** |
| `HeightmapSurface.from_course` — bunny_hill | 127 ms | course load |
| `HeightmapSurface.from_course` — the_long_ride | 1816 ms | course load |

## Problem 1 — `SnowField.decay` costs 15× the entire physics simulation

`scripts/physics/snow_field.gd:135`. Called from `RaceScene._simulation_tick`, every tick, 60 Hz:

```gdscript
for i: int in depth.size():
    depth[i] *= kd
    pack[i] *= kp
```

That is 32 768 `PackedFloat32Array` element reads, multiplies and writes in an interpreted loop,
**0.744 ms** — against 0.047 ms for the whole of `RacePhysics.step`. It is 4.5 % of a native
frame and, at the S2 ratio, **~1.2 ms or 7 % of a browser frame**, spent every single frame of
every race whether or not anyone has touched the snow.

It is also, arithmetically, doing almost nothing. `refill_tau` is 90 s and `pack_tau` is 600 s, so
one tick's factor is `exp(-1/60/90)` = 0.999815. Sixty of them multiply to 0.9889.

Three fixes, cheapest first:

1. **Make it O(1).** Keep `_depth_scale` and `_pack_scale` scalars; `decay()` multiplies the two
   scalars, readers divide, `stamp` divides on the way in. Renormalise the arrays (one full pass)
   only when a scalar drifts past, say, 1e-3 — which at these taus is roughly once a minute. The
   per-tick cost goes from 0.744 ms to about a nanosecond. The clamp in `stamp`
   (`minf(max_trench, …)`) needs the scale folded in, and `apply_to_sample` needs the divide; both
   are one line.
2. **Or decay every N ticks** with `exp(-N*dt/tau)`. Trivially correct, and at N = 30 it is 0.025
   ms/tick amortised. Less elegant, but it is four characters of change and no invariant.
3. **Not** a native rewrite. This is an algorithmic cost, not a language cost — the same loop in
   C++ would still be 32 768 pointless multiplies, just cheap enough not to notice.

This is the single best frame-time change available in the tree, and it is about ten lines.

## Problem 2 — terrain chunk building is a periodic 26 ms hitch

`scripts/render/terrain_renderer.gd:284`. A chunk is 64×64 vertices, and each vertex costs one
`HeightmapSurface.sample_into` — a GDScript method call doing four bilinear lerps over five arrays
plus a `normalized()`. Measured: **6.5–7.7 ms to build one chunk.**

`update_streaming:252` builds every newly-in-range chunk synchronously, inside `_present`, inside
the frame. Riding 600 m down the hill at 20 m/s:

| Course | Worst single frame | Frames over 8 ms (of 1800) | Mean |
|---|---|---|---|
| `wild_mountains` | **26.1 ms** | 11 | 0.15 ms |
| `the_long_ride` | **24.0 ms** | 19 | 0.23 ms |

So: eleven dropped frames in thirty seconds, at a regular cadence — one whole chunk row every
~32 m of descent, which at racing speed is every 1.5–2 s. The mean is nothing and the peak is a
guaranteed stutter. At the S2 ratio a browser sees ~40 ms, and it does not have the option of
absorbing it: `MAX_TICKS_PER_FRAME` is 8, so a 40 ms frame is two ticks of catch-up and the
simulation visibly lurches with the picture.

Note that this measurement is CPU-side only — it excludes `ArrayMesh.add_surface_from_arrays`
actually uploading, and excludes the `MeshInstance3D` entering the tree. The real hitch is larger.

The fix is not native code, it is a budget. `update_streaming` should collect the newly-needed
chunk keys into a queue and build **one per frame** (or until a millisecond budget is spent),
rather than all of them. `stream_radius` is 400 m and the camera's far plane is fog-limited to
70–150 m, so there are hundreds of metres of slack — a chunk that arrives three frames late cannot
be seen arriving. The initial load is the one case that legitimately wants them all at once, and
`MainMenu` already draws a "please wait" panel and waits for `frame_post_draw` before starting it;
give `update_streaming` an `immediate: bool` for that call and time-slice everything after it.

Threads are not an option here: all three web export presets ship `variant/thread_support=false`,
so `WorkerThreadPool` is desktop-only and the fix has to work single-threaded anyway.

A second, larger option is to bake chunk meshes at import time. That trades 1.8 s of load and
every runtime rebuild for pck size, which AGENTS.md already lists as a shipping problem (161 MB
cold load). I would not.

## Problem 3 — course load is 1.8 s on the longest course, and 70 % of it is `Image.get_pixel`

`HeightmapSurface.from_course:224`, broken down:

| Course | Grid | `_build_normals` | `_decode_splat` | Total |
|---|---|---|---|---|
| `bunny_hill` | 179 × 519 | 43 ms | 84 ms | 127 ms |
| `the_long_ride` | 159 × 7999 | 516 ms | 1299 ms | 1816 ms |

`_decode_splat:240` is a triple-nested GDScript loop calling `Image.get_pixel(sx, sy)` once per
target texel per splat map — 1.27 M calls for `the_long_ride`, each one a bound-method dispatch
returning a `Color` Variant, to extract four bytes. Reading `img.get_data()` once into a
`PackedByteArray` and indexing it directly (`data[(sy*sw + sx)*4 + ch]`) is the same arithmetic
with none of the dispatch, and should take this well under 200 ms. This is the clearest case in
the tree of GDScript's per-call overhead being the whole cost, and the clearest case of it being
fixable without leaving GDScript.

`_build_normals:131` is a genuine 1.27 M-iteration numeric loop and there is no trick for it —
0.5 s is roughly what interpreted GDScript costs for that shape. Options: accept it (it is a
load screen, and the load screen already exists and is drawn before the work starts); or have the
importer write the normals into the course resource alongside the heightmap, which is the same
trade as baking meshes but far cheaper in bytes (a `PackedVector3Array`, or two bytes per texel if
octahedron-encoded). I would do the `_decode_splat` fix and leave `_build_normals` alone until
somebody complains, because at 3× for the browser this is ~1.5 s of a load that already shows a
panel.

## Problem 4 — `time_at_progress` is an O(n) scan on the HUD's frame path

`scripts/race/racer_state_stream.gd:127`. `RaceHUD._update_status:66` calls
`RaceScene.ghost_delta()` every frame, which calls this, which walks the recording from sample
zero until it finds one past the player's progress. A ghost is recorded at 20 Hz, so a two-minute
run is 2400 samples and the scan lengthens as the player descends. The class already has exactly
the right machinery ten lines above — `_bracket` keeps a `_cursor` and walks forward from where the
last read left off, precisely because "playback walks forward". `time_at_progress` should keep its
own cursor on the same argument. Small, but it is the only per-frame cost in the game that grows
with course length.

## Where GDScript is *not* the problem, for the record

- **The ODE solver.** 3.6 net-force evaluations per frame, 1.2 substeps, 0.047 ms. The decision to
  write it against `Vector3` rather than six scalar channels is a large part of why — it is a
  quarter of the interpreted bookkeeping — and reusing the stage-3 force as the next step's
  starting force (dropping 4 evaluations to 3) is another 25 %. Both are the right kind of
  optimisation: fewer interpreted operations, identical numerics.
- **The AI planner.** Nine candidate lines against a gathered corridor, once every
  `plan_interval` ticks, with the trees flattened into `PackedFloat32Array`s first so scoring is
  nine passes over packed memory rather than nine trips through the spatial grid. Ten of them cost
  ~0.65 ms/frame between them, planner and physics together.
- **Character skinning and animation.** `Skeleton3D` and `AnimationPlayer` are engine-side; the
  only GDScript in the loop is `KeyframePath` sampling, which is one lookup.
- **The importer.** Offline. `import_all.sh` can take a minute and nobody is waiting on a frame.
- **The snow GPU field.** One fragment pass, eight stamps, no readback. Correct by construction.

---

## If I were picking three things

1. `SnowField.decay` → O(1) scalar. **~10 lines, buys 0.74 ms of every frame.**
2. `update_streaming` → one chunk per frame. **~25 lines, removes an 11-per-30-seconds stutter.**
3. `_decode_splat` → `get_data()` instead of `get_pixel()`. **~10 lines, buys 1.1 s of course load.**

All three are algorithmic, all three stay in GDScript, and together they are about 45 lines. The
structural work in Part 1 — `RacerRoster`, `IntroSequence`, `LaunchArgs` — buys nothing in frame
time and should be judged purely on whether the next three features are easier to write with it,
which I think they are: a lobby, a spectator camera and cups all touch the roster.

---

## Appendix — reproducing the numbers

Each of these was a temporary `game/tests/_bench*.gd` run as
`godot --headless --path game --script res://tests/_benchN.gd`, with a `SceneTree` subclass doing
the work in the first `_process` (per the trap in AGENTS.md about `_initialize` running before the
root Window is in the tree).

- **Physics, with and without a snow field**: the `BenchPhysics.run` fixture (rolling 35° slope,
  4000 trees, 500 herring, slalom input), once with `surface.snow_field = SnowField.new()` and once
  without. 3600 frames after a 60-frame warm-up.
- **Ten AI racers**: ten `RacePhysics` on the same fixture shape, each with an
  `AIInputSource(AISkill.for_level(HARD), seat, 0)`, sharing one `RacerField` refreshed before each
  tick — the order `RaceScene._refresh_rivals` uses.
- **Snow field**: `decay(1/60)` and `recenter` called 3600 times each, separately; `stamp` 72 000
  times.
- **Surface build**: `HeightmapSurface.from_course` on the real `courses/<name>/course.tres`, loaded
  with `CACHE_MODE_IGNORE`, timed whole and split by timing `build()` alone first.
- **Chunk streaming**: a real `TerrainRenderer` added to the root, `setup()` with the real course,
  then `update_streaming` called 1800 times along a 20 m/s descent, recording worst and mean.

The stock benchmark for comparison — `godot --headless --path game --script res://tests/run_tests.gd`
— currently reports 0.0461 ms/frame, 1.20 substeps, 3.60 force evaluations, 0.28 % of budget.
Its fixture has **no snow field attached** and simulates **one** racer, which is why it is not the
number that predicts a frame any more. Worth extending it with a "ten racers plus snow" case and a
`SnowField.decay` line, so the two real costs appear in the suite that everyone runs.

---

# Outcome — what was done

Everything in Part 2, the small items in Part 1 §5, and Part 1 §1 and §2. Verified with the
headless suite (3580 → **3646** assertions, 0 failures) and against a byte-compared Bunny Hill
`carve` capture at every step.

| Item | Result |
|---|---|
| `SnowField.decay` → scalar | 0.744 → **0.0002 ms/tick** |
| Chunk build reads the grid | 6.8 → **1.4 ms/chunk** |
| Streaming budget | worst in-race frame 26.1 → **1.9 ms**, 11 frames over 8 ms → **0** |
| `_decode_splat` | `the_long_ride` 1816 → **1055 ms**, `bunny_hill` 127 → **74 ms** |
| `time_at_progress` cursor | O(n)/frame → O(1) amortised |
| `RacerRoster` + `IntroSequence` + `LaunchArgs` | `race_scene.gd` 1094 → **815 lines** |
| Spray sample, herring batch lookup, `ObjectGrid.build` | done |
| `place_of` | **withdrawn** — not on the frame path; see §5 |
| Importer split (§4) | **not done** — see below |

## A bug the splat work uncovered

`int(float(x) / float(target.x) * float(sw))` is not an identity when the two sizes are equal:
`178 / 179.0 * 179.0` is `177.99999999999997`. Splat maps are exactly heightmap-sized on all 44
shipped courses, so **eleven of bunny_hill's 179 columns and eight of its 519 rows read the
neighbouring texel's terrain** — whole 50 cm stripes of every course running on the wrong
friction, for as long as the function has existed. Nothing looked wrong because the shading comes
from the splat texture directly on the GPU and only the physics goes through the resample.
`TestSurface._splat_resample` asserts the identity on the six widths that ship, and fails against
the old code.

That fix is why the reference capture moved: 6.2 % of pixels, but a **mean absolute delta of
0.068/255** and only 35 pixels above 32/255. It is the chaotic divergence of a perturbed run
redithering the view-dependent crystal glint, not a visual change. Isolated by reverting one file
at a time.

## A gap in the suite

`TestScripts` is new. The suite is written against the node-free simulation, so it never loaded
`race_scene.gd` or anything under `scripts/shell/` — a parse error in `race_hud.gd` passed 3638
assertions and was found by taking a screenshot. It now walks every script and loads every scene.
Two things it had to learn: `ResourceLoader.load` returns a real `GDScript` for a file that failed
to parse, so the check is `can_instantiate()`; and `CACHE_MODE_IGNORE` segfaults the engine by
swapping script objects under live instances.

The benchmark now also reports the two numbers that actually predict a frame — ten racers with
nine planners on one snow field (**1.64 ms**, 9.8 % of budget) and `SnowField.decay` — so neither
can quietly regress.

## Why the importer split was not done

§4 called it "the lowest-risk split in the tree". Reading its shared state changed that
assessment. All ten domains thread `_log`, `_warn`, `_protected` and `source_dir` through `self`,
so composition means rewriting every helper call site across 1849 lines, and the alternative — an
inheritance chain purely to divide a file — trades one smell for another. Verification needs a
full 44-course re-import whose diff is ~116 000 lines *by design*, which has to be audited by the
`unique_id=` filter before anything can be believed.

That is a disproportionate cost for an offline tool that blocks nothing, and it is work best done
by whoever is next inside the character importer, who will be re-running and auditing the import
anyway. The rest of §4 stands: the file is too big and the character half is the part that will
grow.

## Still open

- `_build_normals` and `set_splat` are the remaining halves of course load (516 ms and ~500 ms on
  `the_long_ride`). Both are genuine 1.27 M-iteration numeric loops with no engine call to
  delegate to; §Problem 3 argues for leaving them, and that argument is unchanged.
- Part 1 §3 (`RaceRequest`) deliberately deferred to the lobby, as written.
