# PenguinRacer — build progress

Companion to [`godot-port-plan.md`](./godot-port-plan.md). What exists today, and what is
knowingly missing.

How it got here — the two de-risking spikes in full, and the nineteen things the plan did not
know — moved to [`history.md`](./history.md). The distilled version of the same lessons, the one
worth reading before touching the code, is the trap list in [`AGENTS.md`](./AGENTS.md).

---

## Risks

| Risk | State |
|---|---|
| **S1** ping-pong `SubViewport` render targets on web | **PASS** — verified numerically, native and Chromium/WebGL2. Firefox untested: no GPU here. |
| **S2** GDScript ODE23 substep loop | **PASS with margin** — 0.045 ms/frame native, 0.073 ms in-browser (0.44 % of a 16.7 ms budget). The godot-rust GDExtension contingency should not be built. But it measured the loop the plan was afraid of and not the frame: see the profiling pass below for the two costs that were actually dropping frames. |
| **S3** heightmap dequantization per course | open — see Known gaps |
| **S4** RGBA8 snow trail banding | open |
| **S5** asset licence audit | open — see Known gaps |
| **S6** web cold-load size | **done** — `tools/build_web_streamed.sh`, per-course + music streaming, ~65 MB base against 161 MB |
| **S7** planar character reflection on ice | **PASS** native — settled the design (shared `World3D`, no duplicate rigs, winding needs no fixing) and measured the Fresnel weight that shaped the shader. **Web untested**: no browser GPU here. |

The closed spikes are written up in [`history.md`](./history.md), including what S2's headroom
was actually bought with — two deviations that are load-bearing and should not be undone. S7
keeps its findings in its own doc comment, `game/spikes/s7_reflection/s7_spike.gd`.

---

## Built

### Phase 0 — physics core · **done**

`game/scripts/physics/` — `RacePhysics` is a plain `RefCounted` with zero node dependencies,
stepped against a `SurfaceProvider`. Every force from etracer.md §4.1 is ported: gravity, the
piecewise spring normal force, jump, steering-rotated friction, brake, Reynolds-table air drag,
paddle, and the roll normal. ODE23 (Bogacki–Shampine) with adaptive stepping, retry and the
`MAX_STEP_DIST` cap. Trees and herring go through a uniform spatial grid, fixing the original's
O(items) scan per substep.

**0 failures** — 2293 assertions when the phase closed, 4665 today across physics, surface,
input, audio, the imported terrain library, the settings file, the character rig, the chase
camera, the HUD's arithmetic and the weather, in 13 s headless. Per-force golden values are
worked out by hand from the constants — air drag at 20 m/s, each of the three spring bands, the
400 N lateral friction cap, the 30°/55° bank angles, the paddle's fade to nothing at 60 km/h — so
a change in feel shows up as a test failure rather than as a vague complaint. Whole-simulation
tests cover terrain following, steering symmetry, bounds (including the new polygon play area),
items, trees, the finish, determinism under a replayed input trace, and stability at 10 fps.

Deviations from the original are marked `DEVIATION` in the source, each with a reason. The
finish sequence keeps real gravity instead of the original's flat 500 N hack; below
`RacePhysics.FINISH_STOP_SPEED` (3 m/s, the original's own cutoff for leaving the racing loop
altogether) it now freezes the racer instead of integrating a permanent low-speed creep — the
original's early exit gave it a full stop for free, and without it the creep sat exactly in the
chase camera's un-lagged speed band and read as the camera jittering through the finish delay
instead of the finish clip playing cleanly. See the trap list.

### Phase 1 — importer and first drivable course · **done**

`game/addons/etr_import/` — one-way and re-runnable, driven by `tools/import_all.sh`.
**All 44 courses import**, along with 43 terrain layers, 14 object prefabs, 8 environment
presets, 5 characters, the event/cup tables and 111 strings × 13 languages.

- `elev.png` → float32 local relief, Catmull-Rom upsampled ×2 with an edge-preserving bilateral
  pass; the global slope stays analytic in `CourseData.base_angle`.
- `terrain.png` → authored splat weights: the one-hot index field bilinearly resampled onto the
  heightmap grid, then boundary-blurred, capped at 8 layers. No surveyed course exceeds the cap.
  The importer writes the splat's `.import` sidecar itself, because two of Godot's texture
  defaults corrupt a weight field (2026-09-11, below).
- `items.lst` (or `trees.png` for the 24 courses without one) → per-instance markers in
  `course.tscn`, batched into `MultiMesh` at load.
- `course.dim`, `events.lst`, `terrains.lst`, `light.lst`, `object_types.lst`, `shape.lst`,
  the four keyframe lists and the 15 translation files → typed resources.
- Numeric string IDs become semantic keys (`PRESS_ANY_KEY_TO_START`), with the old IDs recorded
  in `i18n/legacy_string_ids.cfg` so a bad mapping can be traced.

The importer reports the original's terrain colour-key collisions as warnings rather than
letting them stay a mystery: `snow`, `dirty_snow`, `thin_snow` and `strike_snow` all match each
other within the ±30 tolerance.

Terrain layers are one resource per *record* in `terrains.lst`, not per `[name]` — the file
declares `pave04` three times, which is legal in a format where courses reference a terrain by
colour and nothing looks one up by name. Keying by name collapsed two of the three from Phase 1
until 2026-09-01; the layers now carry `legacy_name` and `legacy_index` back to their record, and
`tests/test_terrain_library.gd` checks the generated set against the file. History §17.

Generated resources carry an `import_fingerprint` and re-import skips anything that no longer
hashes to it (2026-09-01). The `modified_in_editor` flag this replaces had been checked since
Phase 1 and never once fired — nothing ever set it — and terrain layers, the one place a designer
can tune a material from the Inspector, had no guard at all. See materials.md §6.

`bunny_hill` is drivable end to end with chunked terrain, splat-blended PBR, instanced trees,
herring pickups, the chase camera and the HUD — **including in a browser**. The Phase 1 exit
criterion is met: a `WebOneCourse` export loads and runs bunny_hill under Chromium/WebGL2,
streaming 21 terrain chunks, on a 6.6 MB pck. Long courses work too — `wild_mountains`
(100×1000) runs, and the per-course pck size was the shape Phase 6's streaming needed — real
per-course streaming (below, S6) has since replaced `WebOneCourse`.

### Phase 2 — rendering · **partial**

`game/scripts/render/` + `game/shaders/` — chunked terrain with splat-blended PBR, instanced
course objects in the original's two shapes, the migrated three-quad skybox, per-environment
fog and light, and the original's HUD redrawn (below).

**Trees are two fixed planes at 90°; items are billboards.** `DrawTrees` is two loops in one
function: `CollArr` gets eight vertices — a quad across X and a quad across Z, from the ground to
`[height]`, never turned toward anything — and `NocollArr` gets four turned to face the
viewpoint. For a phase every one of the fourteen object types got the billboard, which renders
perfectly and is wrong only in motion, when the whole forest swivels together and no tree ever
shows a second profile. `[coll]` is what the two loops split on and is now what the importer
splits on: a collidable type gets `ETRImport._cross_quad_mesh` and `object_cross.gdshader`, and
everything else keeps the quad and `object_billboard.gdshader`. Both are still unit-sized, so the
per-instance `(diameter, height, diameter)` scale is the original's `treeRadius = diam / 2`.
The shading is deliberately not the original's: ETR gives all eight vertices one world-space
normal and lights the tree flat, and shading each quad by its own face normal instead would split
it into a bright half and a dark half — so the cylinder impostor already used for the billboards
is swept across both planes, which keeps the even brightness and adds the volume. Snow and ice carry two octaves of procedural micro-relief, a crystal
glint built from per-texel facet normals, and a Fresnel sky reflection on ice — the last of which
is a *split* of the surface rather than an addition to it, and reflects a sky measured off the
migrated skybox rather than the fog colour. See "Ice stopped going white at a flat angle".

**The spray draws ETR's particles, not just ETR's particle counts.** The counts and velocities
were ported in phase 0, but the first cut textured none of it: every particle was a flat white
square at full size, fading never — plausible against snow at a glance, and nothing failed. ETR's
`Particle::Draw` textures each particle from a 64×64 atlas of four soft puffs (`snowparticles.png`),
picks one quadrant per particle at birth and keeps it, grows the particle from 0.035 m toward a
per-particle base of up to 0.18 m across its whole life, fades it out linearly, and gives each one
a lifetime of `FRandom() × 1.0 s` rather than a fixed length. All of it is ported now; the atlas
itself is redrawn procedurally in `SprayEmitter.make_puff_image` because the original is texture
art that waits on the licence audit (the checkbox-icon standing), and the spray tint is sunny's
`[partcol] 0.85 0.9 1.0` standing in for a value `EnvironmentPreset` does not carry yet. A
before/after capture of a Bunny Hill carve differs inside the spray plume and nowhere else.

**Two renderers: Mobile on the desktop, Compatibility on the web.** `project.godot` had said
`gl_compatibility` since the first commit, on the entirely reasonable ground that WebGL2 offers
nothing else — and the desktop build had been inheriting the browser's constraint for five phases
without that being written down anywhere as a choice. It cost more than a feature list. Under
Compatibility a light that casts shadows is drawn in a *second, additive pass blended in sRGB*
(godotengine/godot#77496, #90259), so the sun arrived five to ten times too bright with its N·L
gradient crushed flat by a curve that is steepest near zero — every slope facing the sun at the
same value, which is what "the left bank at Bumpy Ride is a white sheet" was. It is a framebuffer
blend: no shader reaches it and no gain fits around it. `rendering_method` is `mobile` now,
`rendering_method.web` is `gl_compatibility`, and `RenderBackend` is the seam — it asks the server
for a `RenderingDevice` rather than reading the setting, so a desktop run passing
`--rendering-method gl_compatibility` (which is how the web look gets checked without a browser)
answers the same as the browser does. history §24 has the measurements and the shader-based
shadow system that was built first and thrown away.

**Every lit shader reproduces ETR's illumination clamp**, which the split made both necessary and
worth doing: `shaders/etr_illumination.gdshaderinc` is `texture × clamp(ambient + sun·N·L, 0, 1)`,
included by the terrain and both object shaders, each `ambient_light_disabled` so the two terms
can meet inside `light()` — the engine adds its ambient after the light loop, where the sum can no
longer happen. Multiplying first and clamping the product, which is what a PBR renderer does,
sends a slope to flat 255 white past `illum > 1/albedo`; two courses under the same sun then want
gains a factor of 1.75 apart. With the clamp in ETR's place, `sun_gain` stops being a fit and
becomes a derivation — 1.95, one scalar on the migrated `[diff]`, from where ETR's own red
saturates.

**The sun casts a real shadow map, on the desktop.** PSSM, four splits, range tied to the fog, and
`shadow_normal_bias` at 0.4 rather than Godot's 2.0, which is world metres and had been erasing a
0.6 m penguin's shadow entirely. Three gates, two of them migrated: `RenderBackend` (the renderer),
`EnvironmentPreset.casts_shadows` (`DrawShadow`'s own `light_id` 1/3 rule — nothing casts under a
cloudy or a night sky) and `GameConfig.shadows` (ETR's `perf_level`, now a row on the settings
screen, hidden where the renderer refuses). The web build has none, deliberately.

Tone is matched to the original on Bunny Hill under `tuxracer_sunny`, at both ends of the range
and in all three channels. `EnvironmentPreset.ambient_gain` places the shaded end and is history
§22's fit verbatim — a shaded fragment is ambient only, and the ambient was always in the base
pass, so that end was never distorted by the sRGB pass. `sun_gain` places the lit end and is
derived from the clamp. history §11, §22 and §24 are worth reading before touching a light value,
because they are mostly about why the obvious experiments do not work: the ambient the data means
is not the ambient Godot applies by default; `light.lst`'s numbers are display-space multipliers
that Godot will sRGB-decode into the wrong channel balance unless they are encoded on the way in;
and "turning one light off gives two frames that do not sum to the whole" was never a rendering
subtlety, it was the shadow pass being culled along with the light.

`ambient_gain` is a `Color` and not a scalar. ETR clamps per channel in display space and its snow
is already at the blue ceiling before any light is applied — `snow.png` is (236, 245, 255) and
`[amb]` is (0.70, 0.78, 1.00) — so one number that puts red on the reference necessarily takes
blue off a ceiling the original never leaves. That, plus the decode above, is why the shaded snow
was 23 levels too dark in red while the lit near field had green pinned at 255 over three
quarters of its area. `sun_gain` no longer needs three numbers for the same job, because the
per-channel behaviour they were reproducing *is* the clamp, and the clamp is now where ETR puts it.

Measured on the Bunny Hill frame history §11 and §22 were fitted on, against ETR's 239.2 R /
247.1 G / 3.5 % of green clipped:

| | before (Compat + shadows) | after, Mobile | after, Compat |
|---|---|---|---|
| lit near field R | 238.3 | **234.9** | **235.5** |
| lit near field G | 251.4 | **244.3** | **245.0** |
| G clipped | 53.2 % | **2.9 %** | **7.2 %** |

Bumpy Ride's left bank — the report that started it — goes from 251.0 R with 60 % clipped to
233.4 with 1.2 %. The two renderers agreeing to within a level on snow is the property that
matters most: one fit serves both targets, and the browser gets the desktop's look minus the
shadows.

No LightmapGI bake. The remaining gaps — the character's own material, seven untuned
environments, ice under Compatibility, the camera framing — are in Known gaps below.

#### The HUD is the original's, redrawn (2026-09-11)

`RaceHUD` was a two-line text overlay — `12.34 s   56.7 km/h   herring 3` in the top-left corner —
and it is now `hud.cpp`'s six controls, in `hud.cpp`'s places:

- **The stopwatch and the time**, top left, as `MM:SS` with the hundredths trailing smaller.
- **The herring count and the fish**, top right.
- **The gauge**, bottom right: one dial carrying two unrelated numbers, which is most of what makes
  the original's HUD read as a HUD rather than as a row of text. Inside it, the jump charge as a
  translucent blue fill that rises up the disc while the key is held; around the outside, the speed
  as an arc that fills green to the paddling ceiling, then yellow to 100 km/h, then red to 160,
  with the speed itself in numbers at the centre. The band edges are fractions of the *sweep*, not
  of the speed range, so they are the same three angles at every speed — which is what lets a
  player read "past green" without reading the number.
- **The course-position bar**, up the right edge, filling from the bottom as you descend.
- **The wind rose**, bottom left, with a fat needle for the wind and a thin one for your heading.
  Drawn only when the course has wind, which — as in the original's practice mode — is never,
  because wind is a property of a cup race in `events.lst` and there are no cups. `--wind=1..3`
  makes it reachable; the [WindField] behind it was already ported and already feeds air drag.
- **The frame rate**, centred across the top, behind `--fps` where ETR has `param.display_fps`.

**Redrawn, not copied.** All of it is textured quads in the original and none of that art is in
this tree, for the same reason the menus wear ETR's palette without ETR's corner ornaments: the
licence audit is open. What is portable is the geometry, which lives in `hud.cpp`'s constants
rather than in the art, so the layout is the original's numbers and the shapes are
[CanvasItem] primitives built from them. Two numbers had to be measured off the art instead,
because the artist put them there and not in a `#define`: the jump disc's radius and the speed
ring's two edges. The typeface is the one thing that could not be reproduced — ETR's numbers are a
12-glyph bitmap strip — so the glyphs are the theme font emboldened, drawn on the strip's own
fixed 22×32 cell so that a rolling hundredths digit still does not shove the seconds sideways.

Three things on screen are not in the original and are marked `DEVIATION` where they are drawn:
the status line under the time (the ghost delta, or the standings — this game has ghosts and
opponents and ETR has neither), the `PRESS ANY KEY TO START` hint over the start animation, and
`Race Over` beside the time for the three seconds between the line and the results panel, which
the original does not need because it leaves the racing loop at the line.

Positions are canvas pixels against the project's 720-pixel design height rather than against the
real window. ETR anchors to the window corners, so its gauge is the same 128 px at 640×480 and at
1920×1080 and reads half the size on the second; `canvas_items` stretch scales ours, which is how
the rest of this shell already works.

The canvas is 720 tall and *not* always 1280 wide. `window/stretch/aspect="expand"` grows it along
whichever side the window is longer on, so the HUD is drawn on 1280×960 in a 4:3 window and on
1680×720 in a 21:9 one. Each piece that is not top-left is therefore anchored to its own edge at
paint time — `gauge_center`, `speed_digits_at`, `herring_digits_at`, `position_bar_rect`,
`wind_center`, `wind_digits_at`, `fps_digits_at`, `hint_top`, all static and all taking the canvas
— because one shared scale factor cannot move the gauge right while leaving the stopwatch where it
is and leaving both the same size. `test_hud.gd` checks the distances rather than the positions, on
16:9, 21:9 and 4:3 canvases: a piece anchored to the base instead of to the canvas looks perfectly
correct in every screenshot in these notes, all of which are 16:9.

What is still owed: the cup-racing half of the time and herring readouts, where the original
counts *down* to the gold/silver/bronze thresholds and colours the number by which one is still in
reach. The thresholds are imported and sitting on `RaceEvent`; there is no cup to race yet.

### Phase 3 — snow · **mechanism proven, integration partial**

Both halves of the dual representation exist and are wired in:

- `SnowFieldGPU` — ping-pong `SubViewport`s, 1024² over a 64 m toroidally-scrolled window,
  stamped and decayed by one fragment pass per frame. Verified by S1.
- `SnowField` — the CPU mirror, 128² over the same window, read by `HeightmapSurface.sample()`.
  Its trench is **about 1.5 m wide, not 0.45 m**, and deliberately so: at 50 cm/texel a trench the
  width of the penguin is below what the grid can represent, and storing it anyway made the depth
  read back a function of where in the texel the racer stood rather than of how deep it was — a
  3.9× swing that put 50 mm of bob on the drawn body at the texel-crossing rate. The deposit is
  band-limited to 1.5 texels (`SnowField.MIN_FOOTPRINT`) with the rate divided by the same
  widening, so a pass still reaches the depth it used to; the ceilings on depth and compaction are
  approached rather than clamped, because a clamp is the same kink one level up. The drawn trench
  is the GPU field's, at 6.25 cm/texel, and is unaffected. See the trap list.

The terrain shader displaces from the trail map, raises ridges at the trench lip from the
Laplacian of the depth field, and reconstructs normals from it. A carve leaves a visible track
down the slope in the running game — since history §12, one with a self-occluded floor and a
brighter ploughed lip as well as a shaded wall.

**On the direction of the gameplay effect.** Plan §4.3 says packed snow should "raise friction
and lower compression_depth", but the paragraph below it — and the whole design rationale — is
that packed snow is *faster* than fresh powder, which is what makes racing lines matter. In this
force model friction directly scales the retarding force (ice 0.2 fast … rock 0.7 slow), so
"faster" means friction goes **down** in a packed trench. That is what `SnowField` does, and both
coefficients are exported so the call can be redone by feel. Flagging it rather than quietly
picking a side.

### Phase 4 — character · **rig, canned animations and the racing pose layer done**

`shape.lst` → a welded `ArrayMesh` of scaled spheres **skinned to** a `Skeleton3D` carrying ETR's
own joint names, and the four keyframe lists → an `AnimationLibrary` plus the root motion the
animations cannot carry. A recognisable Tux is on screen, he walks himself to the start line
before every race, and authored skinned glTF art drops in later against the same joint names.

The scene the importer writes is now a `CharacterRig`: skeleton, skinned mesh, `AnimationPlayer`,
and one `KeyframePath` per clip. The race scene owns the clock and asks the rig to pose itself at
a time; nothing about the character reaches back into the simulation.

**Each sphere is tessellated at the original's own resolution** (2026-09-14). `[vis]` is a level
of detail rather than a visibility flag — `CCharShape::VisibleNode` reads it as `gluSphere`'s
stack count — and welding every node at a fixed 8×12 about +Y instead left Tux's belly notched
along the black/white seam: the black body and the white belly are overlapping ellipsoids about
0.07 apart at the front, so a facet of the coarse black sphere bulging past the white one won the
depth test and broke the boundary into blocks. `_sphere_divisions` now ports the original's
`clamp(3, round(tux_sphere_divisions * vis / 10), 16)` and the sphere is built about the node's
own +Z, which is where `gluSphere` puts its poles and, for a belly ellipsoid, where the
protrusion is. The seam is a clean curve on all five. It is also *cheaper* — detail lands where
`[vis]` asks for it rather than everywhere, and Tux's mesh fell from 3978 vertices to 3593. See
the trap list.

**The start animation.** `CIntro` in the original, and the first thing the game does after a
course finishes loading: Tux stands 1.25 m across the slope and a metre behind the line, waddles
over in six steps, turns to face down the hill, drops onto his belly and the race begins. Four and
a half seconds; any key skips it, and the HUD says so. `r` mid-race does not replay it — the
original's Reset state re-enters Racing, not Intro. Scripted runs (`--auto-input=`, and anything
passing `--no-intro` or `?nointro=1`) never see it, which is what keeps every reference capture
where it was.

A networked race skips it too — four and a half seconds of walking is fine on your own clock and
is four and a half seconds of nobody agreeing when the race began between peers — and for one
phase *every* race counted as networked. `RaceNetwork.active()` asked whether
`multiplayer.multiplayer_peer` was non-null and reported `CONNECTION_CONNECTED`, which Godot's
default `OfflineMultiplayerPeer` does before anything has touched the network. So from the
opponents work until now the start animation never played: the race opened already at
`INIT_TUX_SPEED`, with no error and nothing in the log. `active()` now asks whether the peer is
the offline one, and `TestMultiplayer._no_session` asserts both halves — that the default peer
really does call itself connected, and that the game is not in a session anyway.

Four things had to be fixed before any of that could show:

- **The mesh was not skinned to the skeleton it shipped with.** Vertices carried no bone indices
  and no weights, and the `MeshInstance3D` had neither a `Skin` nor a path to the `Skeleton3D`.
  Every joint name was right, every bone posed correctly, and the model was a statue. Each sphere
  is now bound rigidly to the nearest joint above it — which is not an approximation, it is what
  the original does, since a sphere is a leaf under exactly one chain of matrices.
- **Every bone was a root.** `set_bone_parent` was never reached, because the walk up to the
  nearest ancestor joint used a helper that could only return 0 or −1. Rests were global
  transforms too, which is self-consistent with a flat list — and rotating a hip left the knee
  behind.
- **The joint rotations were all about X.** The file names its axis per tag and they are not all
  the same one: `[sh]`, `[hip]`, `[knee]`, `[ankle]` and `[neck]` turn about Z, `[head]` and
  `[arm]` about Y. A `Skeleton3D` rotation track is also an absolute pose rather than an offset
  from the rest, so each key is `rest × R`.
- **A missing tag is a zero, not "hold".** The original resets every joint each frame and
  reapplies what the file names, and `SPFloatN` defaults to 0. Keying only the tags present is
  what would leave Tux racing the whole course with his flippers out, because `start.lst` stops
  writing `[sh]` on its seventh line rather than writing zeros there.

The root motion went to a `KeyframePath` resource rather than a fifth track, for two reasons the
plan did not know: the authored Y is a *clearance above the terrain* (`CKeyframe::Update` adds
`Course.FindYCoord`), so a baked position track would walk Tux through the hill on 43 of the 44
courses; and the yaw/pitch/roll is applied to node 0, whose frame is the world, so it belongs to
the node the race scene positions the character with — above the rig, and out of reach of any
`AnimationPlayer` on it. The race scene samples the path against the same clock it seeks the
animation on, so the two cannot drift.

**The racing pose.** `CCharShape::AdjustJoints` — the whole of the character animation that is
not a canned clip, and what every frame of every race that is not the start animation looks like.
`CharacterRig.adjust_joints` is the port: flippers back to brake, the inside flipper out through
a turn (the two share one limit and are clamped together before a flap is added past it), half a
sine of stroke through both while paddling with the legs kicking at twice the rate, six
half-cycles of flap over a jump, knees that tuck with speed to a ceiling at 35 m/s and ankles that
extend to one at 50, hips and knees bracing ±20° against the net force through the body, and a
tail and a head that follow the lean. The eleven joints are posed as `rest × Rz × Ry`, the two
axes and their order being the original's `RotateNode(name, 3, …)` then `RotateNode(name, 2, …)`;
a character missing one is skipped rather than defaulted, which is what Samuel having no right leg
and no tail needs.

It reads a `RacerState` and nothing else, so it is not the player's animation — it is every
racer's, including a computer opponent, a ghost and a network peer. That is what put four floats
into the state (above): the steering lean is integrated and decayed rather than derived, and the
two stroke phases and the body-up force are measured from things only a simulation has. It is a
no-op while a clip is playing, which is the same split the original has — `CIntro` poses through
`CKeyframe::Update` and never calls `AdjustJoints`, and `CRacing` calls it and plays no clip.

Still missing: an impact reaction on a tree hit, which the original does not have either.

**The finish-line clip is the same machinery as the intro, and for a while it was not.**
`finish`/`wonrace`/`lostrace` play on the results screen (`RaceScene._start_finish_clip`, chosen
by `RaceOutcome.clip`), and they were wired as joints only — the `Animation` seeked, the
`KeyframePath` ignored, on the reasoning that the racer has already coasted to a stop so there is
nowhere for root motion to carry it. That reasoning was wrong about what is in the clip. The
whole of standing up is on node 0: all three open at `[yaw] 180 [pitch] 109` — face down the
hill, tipped past horizontal, which is the pose the race leaves the body in — and walk that to
`[yaw] 5 [pitch] 1` while lifting `[pos]` by 0.35 m, so the penguin rises onto its feet and turns
to face back up the hill at the camera. The joint tracks only fold the flippers and the legs in
underneath. Played without the path, the animation ran correctly and invisibly, and the penguin
lay in the snow through the entire results screen. `RaceScene._apply_finish_pose` is now
`IntroSequence._apply_pose` for the other end of the race: same clock, same
`CharacterRig.parent_basis_for`, same reading of the authored Y as a clearance the terrain height
is added to, with `CGameOver::Enter`'s own `-0.18` height correction where the intro uses `-0.05`.
The clip also stops looping — it runs out and holds its last pose, which is what
`CKeyframe::Update` does, and which looping now visibly contradicts because it would replay the
stand-up from lying down every few seconds. `start.lst` never caught this: it is authored upright
and keys yaw only, so the pitch axis was untested until something used it. `TestCharacter` now
asserts that all three finish-family clips start prone and end on their feet, on the path.

Fixing the clip changed nothing on screen, because the results screen was hiding it twice over.
`results_menu.tscn` was a `CenterContainer` — and the chase camera puts the penguin in the middle
of the frame, so the panel covered the animation exactly — over a full-screen `ColorRect` at 72 %
blue, which took the snow from 237/252/255 down to 103/126/181 and left no pixel under 80
anywhere in the frame. `CGameOver` does neither: its message frame is 500 wide at
`topframe = 80` and the course behind it goes on rendering at full brightness. The panel is now
anchored top-centre at 80 px, which `window/stretch/mode="canvas_items"` makes 80 of a 720-high
canvas whatever the window is, and the dim is gone. The result is the original's frame: message
at the top, penguin standing on its trench below it, course lit as it was a second earlier.

### Phase 5 — game shell · **menu, course selection, settings and audio done; cups and profiles not started**

The first slice: picking what to race next. `scenes/course_menu.tscn` + `scripts/shell/course_menu.gd`
list all 44 courses with preview, author, length, slope and description, and hand the choice to
whoever is showing them. Esc opens it mid-race and drops back to it — there is no Continue button,
so that is a way to abandon the run for another course, not a pause — and it comes back up 3 s
after the finish line with the time and herring count, so the next course is one keypress away. `P`
is the pause: a plain freeze with a `PAUSED` label and no course list, toggled back off by the same
key.

Three decisions worth keeping:

- **The menu drew over the running race rather than replacing it — until there was somewhere else
  to draw.** Plan §4.1 puts the shell above the race scene; for one phase the course-select screen
  was a `CanvasLayer` inside it, because nothing needed to exist before a course was loaded and
  that arrangement cost nothing. A title screen is exactly the thing that does, so the shell is
  now the plan's shape after all (below). The panel still draws over the live course when it is
  opened from inside a race, which is the half of the original decision that was right.
- **The course list is a generated resource, not a directory scan.** `DirAccess` over
  `res://courses/` returns nothing in an exported build: the exporter converts text resources to
  binary and remaps them off their source paths. `resources/courses.tres` is written by the
  importer (merging, so a `--course=` run does not truncate the other 43) and is the same index in
  the editor, in a native build and in the browser. It holds metadata and paths only — a catalog
  that referenced the 44 `CourseData` resources would pull every heightmap into memory to draw a
  192×144 thumbnail.
- **Course names now come from `courses.lst`.** They live in the group listing, not in
  `course.dim`, so every course had been importing with its directory name as its display name —
  "bunny_hill" rather than "Bunny Hill". `CourseData.display_name` is display text, not a
  translation key; ETR does not translate course names either.

The 13 imported translations are registered in `project.godot` and the menu reads its labels
through `tr()`, so the semantic keys from Phase 1 are exercised for the first time.

The second slice: sound. `scripts/audio/` holds the two generated banks — `SoundBank` from
`sounds.lst`, `MusicLibrary` from `music.lst` + `racing_themes.lst` — and `AudioDirector`, an
autoload that is `CSound` and `CMusic` rebuilt on Godot's audio server, one voice per cue and a
`Music`/`SFX` bus pair under Master. All 20 streams are migrated unchanged.

What plays, and where the original plays it:

| Event | Cue | ETR |
|---|---|---|
| Herring collected | `pickup1` + `pickup2` + `pickup3` | `CControl::CheckItemCollection` |
| Tree hit | `tree_hit` | `CControl::CheckTreeCollisions` |
| Riding a terrain | `[sound]` of the dominant layer, looped | `PlayTerrainSound` |
| Racing | theme's `[race]`, from `CourseData.music_theme` | `CRacing::Enter` |
| Menu over a race | `param.menu_music` — `start_1` | every menu screen |
| Menu after a finish | theme's `[wonrace]` | `CGameOver::Enter` |

Two decisions worth keeping:

- **The banks are global resources, not per-course references.** `TerrainLayer.slide_sound` is a
  `StringName` resolved against `SoundBank`, exactly as `TerrList[i].sound` is an index resolved
  against `CSound`. Holding an `AudioStream` there instead would have pulled the same 4 MB of
  shared effects into all 44 course packs.
- **The win sting waits for the menu.** Crossing the line keeps the racing track under the 3 s
  finish deceleration and the theme's `[wonrace]` starts with the results panel — which is the
  same order the original has, since its finish keyframe runs inside the racing state and
  `CGameOver::Enter` is what changes the music.

**Fixed 2026-09-09 — the terrain slide never made a sound.** Everything above it worked: the
splat resolved to a layer, the layer named a cue, the cue had a player, the player reported
`playing`, and the mixer gain was right. `AudioDirector._set_loop` turned `LOOP_FORWARD` on and
left `AudioStreamWAV.loop_end` at the importer's 0, which is the playback's end limit once the
mode is on — so every start wrapped to frame 0 having mixed nothing and retired there. The cue
held a voice and emitted silence on ice, rock, grass, mud and leaves alike. `_set_loop` now sets
the window as well as the mode; `TestAudio` asserts `loop_end > loop_begin` and that the window
spans the sample, because `loop_mode` read correct the whole time and the old assertion on it
passed throughout. See the trap in AGENTS.md.

**Fixed 2026-09-16 — the web build had no audio at all.** Not the game's doing: Godot ships
`audio/general/default_playback_type.web` = Sample, which takes every player off `AudioServer`'s
mixer and gives the stream to the browser's own Web Audio graph. Sample playback carries
`AudioStreamWAV` and nothing else, so all ten pieces of music went silent, and the effects that
survive it lose the loop window `_set_loop` writes and the `race_gain` that reaches the voice
through the `SFX` bus. Measured in Chromium: `_music.playing` true, the stream loaded off the
streamed `music.pck`, `get_playback_position()` advancing — and every bus at its -200 dB floor,
with an analyser on `AudioContext.destination` reading an RMS of exactly 0 against 0.21 for a
control oscillator through the same tap. `project.godot` now sets
`audio/general/default_playback_type.web=0`, which is the desktop's mixer on both platforms;
`TestAudio._web_playback_type` asserts it, because nothing else in a headless run can see a `.web`
override. Menu music, the racing theme, the pickups and the terrain slide all sound in a browser
now, and the bus peaks match the desktop's to within the frame. See the trap in AGENTS.md.

**Fixed alongside it — the racing theme took two minutes to arrive.** `HTTPRequest` reads one
`download_chunk_size` per idle frame, so at the default 64 KiB a download's speed is the *frame
rate*, not the link. The course pack never showed it (549 KB, fetched over the loading screen, 14
frames), but the 14 MB music pack is 215 chunks and the race asks for it while the hill is
rendering: timed in-browser under software GL it landed **117 s** after the start, which read as a
hung fetch rather than a slow one. `PackStream.DOWNLOAD_CHUNK_SIZE` is 1 MiB now — 14 polls, and
the same fetch completes about 6 s in.

`-- --no-audio` gates the whole thing, for capture runs where a soundtrack is only a slow start.
Volumes are the original's `param.sound_volume` 90 / `param.music_volume` 20 and live on the
director. The configuration screen does not move them yet — they are two more keys the settings
file would have to carry first.

The third slice: the screen the game starts on. `scenes/main_menu.tscn` +
`scripts/shell/main_menu.gd` is the main scene now, and `race.tscn` is something it hands over to
and takes back. Two entries, both of them ETR's own — `PRACTICE`, which opens the course list, and
`CONFIGURATION`, which is the settings screen — so the labels come out of the imported strings in
13 languages rather than being written in English in a scene file. Quit is there on desktop and
hidden in a browser, where the tab owns it. Cups, events and profiles are more entries in the same
column when they arrive.

Four decisions worth keeping:

- **The course travels on a static.** `RaceScene.requested_course_path` is written just before
  `change_scene_to_file` and read in `_ready`. A scene swap leaves nothing to set a property on —
  the node is built by the tree, after the caller is gone — and an autoload for one string would
  be a third global for the shell to own. `load_course` writes it back, so the menu highlights
  what was actually raced.
- **A scripted run never sees the menu.** `--course=` or `--auto-input=` hands straight over, which
  is every `tools/shot.sh`, every headless capture and the whole verification path; in a browser
  `index.html?course=<dir>` says the same thing, since there is no command line in a page. `RACE_READY`
  therefore still arrives where it always did. A bare `--capture=` is deliberately *not* on that
  list: it screenshots whatever is on screen, which is how the shell itself gets verified.
- **The loading panel is drawn before the load starts.** Building a course blocks the main thread
  long enough to read as a freeze, and `visible = true` on the frame you then block is a panel
  nobody sees — `await RenderingServer.frame_post_draw` is what makes it a composited frame rather
  than an assignment.
- **Leaving a race frees it.** Back from the in-race menu changes scene rather than hiding a
  panel: a loaded course is most of the memory in the game and the menu has a gradient to draw
  over, not a slope. It is also the original's "abort race", which until now had nowhere to go.
- **Leaving the game goes through the audio director.** Quit, the window's close button, `Esc`
  out of `key_log` and the end of a capture all call `AudioDirector.quit_game()` rather than
  `SceneTree.quit()`, because a playback that is stopped as the tree comes down is never released
  and Godot says so on the way out (history §18). The director owns `auto_accept_quit` for the
  same reason. Anything added later that wants to end the process wants that method, not the
  tree's.
- **...and it waits for the playbacks, not for a duration.** The wait used to be a 100 ms
  `SceneTree` timer, which counts frame deltas rather than wall clock: instrumented on the real
  path it returned after 43 ms and four frames, and the music was released on the fifth, so every
  quit from the main menu still leaked `start1-jt.ogg` and its packet sequence — the same four
  instances the wait was added to stop. `AudioDirector.await_settled` yields until the playbacks
  `begin_shutdown` stopped are actually gone, watched through `weakref` and counted by
  `settling()`, with `QUIT_SETTLE_TIMEOUT` only as a backstop. It is also quicker: quitting from a
  silent screen no longer sleeps at all.
- **...and the silence it starts with is one-way.** The tree keeps processing through the wait, so
  silencing once only opened a window for the next caller: `RaceScene._update_slide_sound` plays
  the terrain's cue every tick, and the player having just been stopped is what let it through.
  Every quit from a race leaked `rock_slide.wav` and its playback on top of the music.
  `AudioDirector.begin_shutdown()` — silence, then a gate `play` and `_play_stream` refuse on — is
  what the wait now begins with, and it covers the pickups, the tree hit and the music as well as
  the slide. `TestAudio` asserts the refusal and the watch list; the symptom itself is an
  exit-time warning and cannot fail a test.

The fourth slice: settings. `scripts/config/game_config.gd` is the `Config` autoload and
`user://penguinracer.cfg` is its file — plain text, written with its comments the first time the
game runs, read once at startup, edited by hand or from `scenes/settings_menu.tscn`. It is ETR's
`options.txt` in shape and in purpose: that file also has a group its options screen can set and a
group only the file can, and this is now the first group, because the screen exists. Five keys —
window size, fullscreen, `render_scale` (the 3D viewport's fraction of the window, the cheapest
framerate knob under Compatibility) and the two fog distances.

The screen writes the file back the way the file was written in the first place: as commented
text, by hand, not through `ConfigFile.save`, which drops every comment it did not put there. The
comments are regenerated on each save, so editing the prose in the file does not survive a visit
to the screen and editing the values does — `tests/test_config.gd` round-trips the writer through
the reader, including `"auto"`, which is the one value that is not a size and which a naive
`0x0` would lose. Editing is transactional: the widgets hold the copy, Ok applies and saves,
Cancel throws it away. Every slider spans exactly what `GameConfig.read` would clamp a hand-edited
value to, so the screen cannot silently narrow a file it did not write.

The resolution row asks the display rather than carrying a list. It used to offer six hardcoded
sizes, which was arbitrary in both directions — a 1366x768 laptop was invited to open a 2560x1440
window it cannot show, and a 4K monitor was never offered its own resolution. `DisplayModes`
builds the list instead: the screen's own size, plus the standard modes that share its shape and
fit inside `DisplayServer.screen_get_usable_rect` (the desktop minus its taskbar), plus whatever
the file already says, so opening the screen still cannot resize anybody's window. There is no
mode enumeration in Godot to call — `DisplayServer` has no `SDL_GetDisplayMode` — so shape and fit
are what stand in for one, and a panel nothing standard shares a shape with (21:9, portrait) is
offered fractions of itself. On the 1600x900 screen in this container the drop-down comes out
`auto, 854x480, 1024x576, 1280x720, 1366x768, 1600x900` and stops there.

Every row has the display's shape, and that is now the only thing the filter is for. It spent a
day meaning something else: the list was briefly filtered by the *game's* 16:9 instead, on the
argument that `stretch/aspect="keep"` letterboxes any window that is not, so a 16:10 laptop
offering 16:10 sizes was offering black bars whichever shape it matched. That argument was sound
and the conclusion was wrong — the answer was to stop letterboxing. `project.godot` now ships
`window/stretch/aspect="expand"`: the canvas keeps the 720-pixel short side of the base and grows
along the long one, so a 16:10 window is 1280x800 of canvas, a 21:9 one is 1680x720, and a 4:3 one
is 1280x960. Nothing is letterboxed at any shape, the drop-down can go back to offering what the
monitor actually has, and the two pieces that were relying on a fixed canvas — the HUD's corners
and the camera's lens — were changed to carry it (see the HUD section, and `ChaseCamera`).
`DisplayModes` is pure and node-free — the list-building could not stay on `SettingsMenu`, which
names the `Config` autoload, without the static call from `tests/test_config.gd` breaking its
compile; that is the `RaceOutcome` trap a second time. The resolution and fullscreen rows are
hidden on the web build, as they have been since the screen landed: the page sizes the canvas
there and `apply_display` returns early, so both would be dead knobs. Nothing is now even asked
of `DisplayServer` on that build.

Fog is why it exists now. `light.lst` ships `[fogstart] 0` for six of the eight presets, and the
two of those six that are sunny are what all 44 shipped courses select, so the original's haze
begins at the camera and the trees two lengths ahead are already washed toward white; the defaults here are 40 m of clear air and 2x the migrated range, i.e. 40–150 m where the
data says 0–75. **This reverses a correction made the same day** — a 2.5x stretch had just been
backed out as a wording-level "improvement" that removed the haze ETR's snow sits inside — and
the difference is that it is now measured and revertible. On Bunny Hill the mid-distance tree band
regains its contrast (5th percentile 143 → 65, clipping 19 % → 12 %) while the near field, which
is where the `ambient_gain`/`sun_gain` tone match was fitted, does not move at all
(mean 226.8 → 226.5, every percentile identical). `start_distance = 0` and `distance_scale = 1`
in the settings file render exactly what the file says, which is the point of putting it there
rather than in the migrated preset.

`EnvironmentPreset.to_environment()` still writes the migrated range; `GameConfig.apply_fog`
overwrites it in `RaceScene._apply_environment`, and the directional-shadow range now reads the
built `Environment` rather than the preset, so a stretched fog carries the shadows out with it.
Godot's own `--resolution`/`--fullscreen` outrank the file — `tools/shot.sh` keeps capturing at
1280x720 whatever a developer's settings say.

The fifth slice: making it look like the original. `themes/etr_menu.tres` is the colour table at
the top of `etr-0.8.4/src/common.cpp` expressed as a Godot theme, and all three screens wear it
instead of the thirty-odd `theme_override_colors` they used to carry between them. Every value in
it is one of ETR's named constants — `colBackgr` (0.4, 0.6, 0.8) is the flat blue `Winsys.clear()`
paints every menu screen with, `colMBackgr` fills a framed box, `colDBackgr` is the recessed fill
under a selected row or a slider track, text and frame outlines are white, focus is `colDYell`
and a secondary line is `colLGrey`. Frames are square and 3 px, because ETR's are SFML
`RectangleShape`s with `setOutlineThickness(3)` and no notion of a corner radius.

Three things followed from reading the original rather than guessing at it:

- **ETR's menu buttons have no chrome at all.** `TTextButton` is a `sf::Text` and a mouse
  rectangle; it is white, and it turns `colDYell` when the mouse is over it or the keyboard has
  walked onto it — those being the same thing there, since `MouseMove` sets `focus`. So `Button`
  in the theme is `StyleBoxEmpty` in all five states with the colour doing the work, and the main
  menu's column is centred under the title the way `CGameTypeSelect::Enter` centres its seven.
- **The blue is the screen, not a scrim.** The course list opened from the main menu is an opaque
  `colBackgr` screen; opened over a running race, where the course stays loaded and rendered
  behind the panel, the same rectangle is a translucent `colDBackgr` wash instead. That is
  `over_race`, the flag `CourseMenu.open` takes to decide which.
- **The checkbox had to be redrawn.** ETR's is a ring with a cream tick (`checkbox.png` +
  `checkmark_small.png`, and the tick really is 255, 250, 208), not a box; Godot's default
  `CheckButton` is a dark slab that vanishes against blue and cannot be modulated lighter.
  `themes/checkbox_{on,off}.png` are that shape drawn here, 32², bound as the `CheckBox` icons.

Not migrated: the four corner ornaments and the title logo `DrawGUIFrame`/`DrawGUIBackground`
paint over the blue, and the `param.ui_snow` particles that drift across every menu. All of it is
`etr-0.8.4/data/textures` art and waits on the licence audit.

The sixth slice: the other four characters. `char/characters.lst` is a five-record file — Tux,
Trixi, Boris, Samuel, Beastie — and the importer has been walking all five since Phase 4, writing
a rig and four baked clips for each. Nothing could pick one: `RaceScene.character_scene_path` was
an `@export` hardcoded to `tux/tux.tscn` and four of the five were dead weight in the pack.

What was missing was the same thing the course list needed, for the same reason. `DirAccess` over
`res://` finds nothing in an exported build, so the importer now writes `resources/characters.tres`
— a `CharacterCatalog` of `CharacterListing` rows, one per record, carrying the `[name]` the player
reads, the scene path and the `preview.png` that ETR's registration screen draws in a white frame.
The order is the file's, not alphabetical, because ETR's spinner opens on index 0 and index 0 has
to be Tux for that to mean anything. `RaceScene._install_character` resolves through it, and the
`@export` is now empty by default and means "a rig that is not in the catalog at all" — the hook
authored glTF art drops into.

The choice is `[game] character` in `penguinracer.cfg` and `character_menu.tscn` moves it: ETR's
"Select a character:" over arrows flanking a framed name, the 128x128 preview in a `PictureFrame`
below, Enter and Back. The spinner clamps rather than wrapping and greys out the end arrow, which
is `TUpDown::Click` calling `SetActive(false)`. Left and right drive it from anywhere on the
screen, handled in `_input` rather than `_unhandled_input` because horizontal focus traversal on
a focused `Button` consumes the event before anything unhandled sees it.

Two things had to be decided rather than migrated:

- **Where the question goes.** ETR asks on `CRegist`, the first screen of a launch, beside a
  player-profile spinner. There are no profiles here yet, so half that screen has nothing in it;
  the character half is its own main-menu entry instead, labelled with ETR's own string and the
  current name after it — `Select a character: Tux`.
- **Whether the answer is kept.** ETR's is not: `g_game.character` is a pointer set from a spinner
  that opens on index 0 every time, and `players.lst` has no column for it. Here it is written to
  the settings file, because a menu entry that forgets what you told it a launch ago is worse than
  no entry. `--character=<dir>` and `?character=<dir>` name one for a single run and do not write.

The four others are not skins of Tux. Each has its own `shape.lst` and its own `start.lst`,
`finish.lst`, `wonrace.lst` and `lostrace.lst`, and the data disagrees with itself between them:
four of the five spell the left elbow `[joint] joint` — `[name] joint for left_elbow` beside it
gives the slip away — and Samuel has no right leg, no hands and no tail at all. Both are faithful
and neither is fixable, because `CCharShape::RotateNode` looks a name up and returns false when it
is missing, so the original never rotates a joint the file does not name. The test suite grew a
group that asserts the contract all five share (a skinned mesh, one root bone, parents before
children, the five joints they all have, a clip whose length matches its root motion, and a
finish-family clip that stands the character up) rather
than Tux's sixteen-bone list, which is only Tux's. 4047 assertions, 0 failures.

A third disagreement surfaced later, as a bubble on Trixi's belly: the `[node]` ids in a
`shape.lst` are not unique. Her bow reuses 72/73/74 and Beastie's horns reuse 72–79, on ids the
body and the breast already took. `CCharShape` is unbothered — `Index[node_name]` is only read
while the line that names it is being applied, and the tree is pointers — but `_build_character`
kept one `parents` dictionary per id and resolved each sphere's bone after the loop, so the body
and the breast came out riding the **head** bone and swung off the belly whenever the head leaned.
It numbers every record now and keeps the id map as the shadowing lookup it is in the original.
Only Trixi's and Beastie's meshes changed; the other three re-imported byte-identical.
`TestCharacter._bound_near_its_bone` is the guard — no vertex further from its bone than the body
ellipsoid's own reach — and it fails on both old rigs and on neither new one.

Verified end to end: all five race on Bunny Hill under `--character=`, natively on the GPU and in
Chromium through `?character=beastie` against the `WebOneCourse` export. The previews are ETR data
art and go into the licence audit with the rest of the imported assets.

Not done, and none of it started: cups and events (the resources are imported and unused),
medals from the migrated thresholds, and save profiles — the player half of `CRegist` waits on the
last of those. Sound and music volumes and the language are ETR's `options.txt` keys that this
file and this screen still do not carry.

### Multiplayer foundation · **seams built, ghosts working, network scaffold desktop-only**

Not a phase in the plan — plan §8.4 says redesign beyond the original is in scope and should be
taken into account in the initial design. This is that: the shape three separate features need,
built once, with one of them finished so the shape is not a guess.

**One racer became a list of racers.** `RaceScene` used to hold *the* player: one `RacePhysics`,
one `$Player` node, one input poll, one herring count. It now holds `racers: Array[Racer]` and
advances all of them on the same tick. The split under `Racer` is the whole design:

```
Racer                  identity, rig, and the interpolated body transform
  ├── SimulatedRacer   owns a RacePhysics, fed by an InputSource
  │                    → the local player today, an AI opponent later
  └── PlaybackRacer    owns a RacerStateStream, read by time
                       → a ghost today, a network peer today
```

`RacerState` is the seam: 18 float32s — time, position, orientation, velocity, progress, flags,
herring, and the four the character rig poses its joints from — and the *only* thing the
presentation reads. A simulated racer fills it from `RacePhysics`; a ghost fills it from a
recorded stream; a peer fills it from a packet. The same 18 floats are the file format and the
wire format, so a ghost on disk and a snapshot on the wire are the same bytes in the same order.

The last four were added with the racing pose layer (Phase 4). They are the part of
`AdjustJoints` that a pose does not imply: the steering lean, which is integrated over half a
second and decays over another fifth; the paddle and flap phases, each measured from a tick only
the simulation knows about; and the net force along the body's own up axis. Without them a ghost
and a network peer slide down the hill in the rest pose while the player beside them animates.

**The simulation runs on a fixed 60 Hz tick, and the presentation interpolates.** This is the
load-bearing change and everything else rests on it: a run has to mean the same thing at 30 fps
and at 144 or a recorded ghost is not a fair opponent and two peers cannot agree who reached the
line first. `tests/test_multiplayer.gd` asserts it directly — a run recorded as intent, replayed
through `ReplayInputSource`, lands within 1e-9 of where it started. Getting the interpolation
*phase* right was the one subtle part and moved every reference capture the first time; see
history §20. It moves none of them now: outside the spray, a 200-frame Bunny Hill capture is
pixel-identical to the one from before this work.

**Ghosts are the consumer that proves the seams.** Every run the player makes is recorded — 2
bytes of intent per tick plus an 18-float pose every third tick, about 190 kB for a four-minute
run — but nothing is written to disk automatically any more. A finished race brings up a results
screen over the still-loaded course (`ResultsMenu`) showing the time, the herring and — if the
race had one — how far ahead of or behind a saved run's ghost it finished, while the character
plays a `wonrace`/`lostrace`/`finish` clip (there are no cups in this rebuild, so the mapping —
`RaceOutcome.clip` — is place in a field race, or beating the loaded ghost in a solo one, or
nothing to win or lose in a plain practice run). From there the player can name the run and keep
it (`SavedRunStore`, `user://runs/<course>_<ticks>.res`, one file per save, never overwritten).
The main menu's **Race against ghost** entry (`GhostMenu`) lists every saved run across every
course — time, herring, deletable — and racing one starts Practice on that run's course with it
loaded as the ghost, translucent on the line it took, gap in seconds on the HUD. This replaced the
one-best-per-course auto-save and the `[game] ghosts` checkbox on the Configuration screen, which
are both gone.

Two things are recorded, deliberately, and they are not redundant:

- **Poses** are what a ghost plays back. Exact by construction, cost nothing to replay, and ask
  nothing of the physics still being what it was. That last part is why they exist: input replay
  only reproduces a run if every float lands on the same bit, and this game ships to native
  desktops *and* to a WebAssembly runtime with a different libm. A ghost recorded on one and
  replayed on the other would drift, slowly and unfalsifiably.
- **The input trace** is a fortieth of the size and is the exact thing for anything that has to
  re-derive a run rather than repeat it: a regression test, a saved run replayed against a changed
  force constant, and the corpus an AI would be scored against. It carries a hash of every
  constant in the force model, so a trace from before one moved says so instead of quietly
  producing a different race.

**AI opponents need no new machinery.** An opponent is an `InputSource` subclass — `poll()` is
handed the `RacePhysics`, which owns the position, the velocity, the surface under the racer and
the tree grid ahead of it — driving a `SimulatedRacer`. Nothing is stubbed for it and nothing is
waiting on it; the seam is exercised today by `ScriptedInputSource`, which is what `--auto-input=`
became.

**The network scaffold is ENet, peer-to-peer, and desktop-only.** `Net` (`scripts/net/race_network.gd`)
hosts or joins a session; each peer simulates only itself and broadcasts a snapshot 20 times a
second, and every other peer draws it as a `PlaybackRacer` read 150 ms behind the local clock.
No host authority over positions, no rollback, no prediction — the surface is identical on every
machine and the only shared mutable state is the herring. Racers *do* collide, and that fits
under a design with no authority only because the contact is resolved twice, once by each body
(see **Racers collide** below). Verified with two processes on one machine: both see the other on
the hill, spawned off the first snapshot to arrive.

```bash
godot --path game -- --host --course=bunny_hill
godot --path game -- --join=127.0.0.1 --course=bunny_hill
```

What it is not: there is no lobby screen (both ends name the course themselves, though
`RaceNetwork.course_dir` already carries the host's choice to the client and nothing reads it
yet), no countdown, no finishing-order screen, and **no web support** — ENet is UDP and a browser
has no UDP socket. WebRTC delivers the same `MultiplayerAPI` with the same RPCs behind
`RaceNetwork._new_peer`, and additionally needs a signalling server, which is hosted
infrastructure rather than a piece of this repository.

**Two bugs fell out of the refactor and are fixed.** `ObjectGrid.reset_collectables` had never
been called, so pressing `r` raced a course stripped of every herring the previous run collected —
invisible until a ghost of that run was there collecting fish that were not; `CourseRoot.reset_items`
now puts back both the grid flag and the instance transform. And a peer joining a race already in
progress used to stand still forever, because its playback clock started at zero while its
snapshots were stamped a minute in.

### Computer opponents · **done**

Also not a phase in the plan, and beyond the original in a plainer way than the multiplayer
foundation was: ETR races the clock. `CRacing` simulates one `CControl`, and the only other times
on its hill are the highscore table's. This is a second mode beside Practice — a field of one to
nine racers you can actually be beaten by.

**It arrived through the seam and changed nothing else.** The racer layer was built with
`InputSource` as the place an opponent would come from, and this is that prediction being cashed:
an opponent is a `SimulatedRacer` with an `AIInputSource` where the keyboard goes. The class did
not change. `SimulatedRacer` gained two fields — a smaller particle pool and a start-line offset —
and `RaceScene` gained a constructor for the field and a per-tick line telling the opponents where
everybody is. The presentation, the recorder, the herring grid, the snow stamps, the standings and
the interpolated draw are all the code that was already there.

```
RaceSetup            0 opponents = Practice, 1..9 = a race, plus a skill
  └── AISkill        one tuning table per level: EASY, MEDIUM, HARD
        └── AIInputSource   plans a line, returns the seven fields a keyboard fills
```

**A difficulty setting is not allowed to touch the physics.** Every racer on the hill is the same
twenty-kilogram point mass under the same §4.1 forces — `characters.lst` carries no per-character
constants and neither does this — so the only thing a level can move is the quality of the intent.
`AISkill` is therefore a table of driving habits:

| | easy | medium | hard |
|---|---|---|---|
| lookahead | 13 m | 20 m | 28 m |
| replan interval | 10 ticks (167 ms) | 5 (83 ms) | 3 (50 ms) |
| full lock at | 36° | 26° | 18° |
| clearance round a trunk | 3.4 m | 2.4 m | 1.9 m |
| paddles below | 7.0 m/s | 12.0 m/s | 16.67 m/s (all of it) |
| brakes above | 12.0 m/s | 19.0 m/s | never |
| brakes at a heading error of | 20° | 34° | 52° |
| weave | 3.4 m | 1.6 m | 0.5 m |
| reads the friction ahead | no | half | fully |
| detours for herring | most | some | barely |

That is what makes the ladder honest, and it comes out in the simulation rather than in a
multiplier. Thirty seconds down a 22° rolling slope, no trees:

```
easy    230.6 m   27.8 km/h
medium  332.5 m   44.1 km/h
hard    421.9 m   58.3 km/h
paddle  412.8 m   60.5 km/h     <- a player holding the accelerator and nothing else
```

So a hard opponent on an open slope is about as fast as a perfect straight line, and faster than
one on a course with anything in the way. Medium is comfortably beatable and easy is a long way
back. The three assertions that keep it that way are in `tests/test_ai.gd`: the tuning table has to
be monotone in every column, the three levels have to finish in order with the ends of the ladder
at least 25 m apart, and each has to actually get down the hill.

**How the planner works.** Once every `plan_interval` ticks it picks a world x it wants to be at
`lookahead` metres further down, by scoring nine candidate lines 1.5 m apart:

- **trees**, by how far the line intrudes into the clearance the level insists on, plus a flat
  charge larger than everything else put together for a line that actually collides;
- **the play bounds**, which reject a candidate outright — with the probe's z pulled back inside
  the polygon, or the last thirty metres of every course would be raced by an opponent with no
  opinion about where to go;
- **swerving**, because the fastest line through nothing is a straight one, plus a weak pull back
  toward the lane it started in;
- **the terrain**, where `line_greed` prefers the low friction of ice or a packed trench — packed
  snow is faster here, so an opponent that reads it is taking a real racing line;
- **herring**, inverted on purpose: the fish are points and points cost time, so it is the easy
  opponent that chases them;
- **the other racers**, which is the one thing it is told rather than shown.

Between plans it steers at the aim point it last chose, which is what makes the interval a
reaction time and not merely a saving. Paddling, braking and the weave are decided every tick.

**Why the other racers have to be told.** The trees and the herring were loaded with the course
and are in every `RacePhysics` already; another penguin is a body being integrated somewhere else
on the same tick, so it can only arrive from outside. `RaceScene._refresh_rivals` publishes one
`RacerField` before anybody advances and hands it to every racer with its own index in it — the
simulation bounces off it and the planner steers around it, so the racer an opponent avoids is
exactly the one it would hit. The steering term is a *soft* penalty and much weaker than the
tree's: an opponent will still drive through another to miss a trunk, because the trunk is the one
that costs a race. Left with neither, two opponents that both wanted the same herring converged on
it and rode the rest of the course as one blurred penguin.

**It is deterministic.** The only randomness is a per-seat personality — weave phase, and a few
per cent either way on lookahead, nerve, paddle discipline and tree clearance — drawn once at
construction from a seeded `RandomNumberGenerator`. Nothing is rolled per tick. So a field replays
identically, which is what lets it be recorded like any other run and asserted on headlessly.

**What the player sees.** *Race the computer* on the main menu opens the same course screen
Practice does, with two spinners on it: how many, and how well they drive. Both are remembered in
`penguinracer.cfg` and both can be changed from the in-race menu, so someone who has just been
beaten can drop the difficulty and press Race! again without walking back out. The field starts
abreast, three metres apart, laid out either side of the course's own start point — the player is
never moved, so a practice run and every reference capture start exactly where they always did.
Opponents wear the other characters, taken from the catalog starting after the player's own, and
are called by them; a tenth racer would be "Trixi 2". The HUD's status line becomes the standings:
place out of the field, and the name and distance of the racer either side of you. The result panel
leads with `Position 3rd`, from the migrated `POSITION` and `1ST`..`10TH` — which is also why the
field stops at nine.

A race against opponents never draws a ghost, loaded or not: the status line is the standings, and
a translucent copy of yourself among eight racers is one more thing to mistake for one of them. The
run is still recorded either way, so it can still be saved from the results screen afterwards.

**What it costs.** Ten `RacePhysics` on the tick instead of one. The S2 benchmark is 0.045 ms per
frame per racer, so a full field is under half a millisecond — about 3 % of a 16.7 ms budget
native, 4 % in the browser. Opponents get a quarter of the player's spray particle pool. A capture
of Bunny Hill in Practice is byte-identical to one from before this work, outside the
`GPUParticles3D` plume that is not reproducible between any two runs.

### Racers collide · **done**

Everyone on the hill is a body: the player, the computer field, and a peer over the network. Two
of them touching is a contact and no longer a coincidence of drawing.

**One field, published once a tick.** `RaceScene._refresh_rivals` fills a `RacerField` — a
position and a velocity per racer, an `Array` shared by reference and rewritten in place — before
anybody advances, so every racer resolves the tick against the same instant. `RacePhysics.rivals`
and `rival_index` are the whole of the plumbing on the simulation side; the planner reads the same
array (`AIInputSource.rivals` *is* `RacerField.positions`), so the racer an opponent steers around
is exactly the one it would hit.

**The contact is resolved twice, once by each body.** `_adjust_racer_collision` runs where the
tree collision runs, at the end of each accepted ODE substep, and applies the textbook equal-mass
impulse to *itself*: remove the closing component of the relative velocity along the horizontal
line between the two centres, hand back `RACER_RESTITUTION` (0.35) of it. The other body computes
the mirror image in its own simulation, so what one is paid the other pays with neither of them
ever writing to the other — symmetrical to the tick rather than to the bit, since each resolves
against the other's velocity as published at the start of it and its own as it is mid-substep.
That is what makes this survivable under a
peer-to-peer network with no authority anywhere — and it is why it works unchanged when the other
body is a remote peer being played back from snapshots and not simulated on this machine at all.

On top of the impulse sits an overlap term, a position error corrected through the only channel
the simulation has: two bodies inside each other have no closing velocity to remove, and without
it a narrow course that clamps two start lanes together would run the whole race with two penguins
in one place. It is capped at 1.2 m/s at full overlap, so being nudged never reads as being fired.
Two racers exactly on top of each other separate along a normal chosen by index, not by anything
measured, so a replay lands on the same bit.

**A ghost is not in the field.** `Racer.collides()` is the predicate and `Kind.GHOST` is the one
that answers no: a recording of a run that already happened cannot be pushed back, and a player
shoved off their line by their own best time would be losing to something that cannot lose. It is
also the only racer on the hill that no contact can move, so a collision with it could only ever
go one way.

**What it changes for the player.** Running into somebody costs the speed you were closing at and
plays `tree_hit` — the only impact cue the original ships, since ETR has nobody on its hill to run
into. Only the local player's contacts are audible and only their own end of them is connected,
or one bump would fire the cue twice.

Covered by `tests/test_simulation.gd::_racer_contact`: two racers started half a metre apart end
up beside each other rather than inside each other, the shove is symmetrical to within 5 cm over
five seconds, nobody is launched, a moving racer does not drive through a stationary one, and — the
assertion that guards every reference capture in the repository — a racer alone in a field of one
drives to within 1e-12 of one with no field at all.

### Frame time, course load, and three files out of `RaceScene` · **done**

A profiling pass over the whole tree, written up in [`REVIEW.md`](./REVIEW.md). The headline is
that **risk S2 measured the right loop and the wrong thing**: the ODE substep loop is 0.046 ms a
frame and was never the problem, and the two costs that actually dropped frames had nothing
measuring them at all.

| | before | after |
|---|---|---|
| `SnowField.decay` | 0.744 ms/tick | **0.0002 ms/tick** |
| `TerrainRenderer._build_chunk` | 6.8 ms | **1.4 ms** |
| worst in-race frame, `wild_mountains` over 30 s | 26.1 ms, 11 frames over 8 ms | **1.9 ms, none** |
| `HeightmapSurface.from_course`, `the_long_ride` | 1816 ms | **1055 ms** |
| `HeightmapSurface.from_course`, `bunny_hill` | 127 ms | **74 ms** |

All four fixes are algorithmic and all four stay in GDScript. The decay applied one exponential to
16 384 texels sixty times a second and is now a scale factor readers multiply through. A chunk
vertex sits exactly on a heightmap texel, so `sample_into` was bilinear-filtering a texel against
itself 4096 times a chunk; it indexes `surface.heights`/`normals` instead, which also stopped the
CPU snow mirror being baked into a mesh depending on when it happened to be built. Streaming is
queued nearest-first and drained under a millisecond budget, with an `immediate` flag for the
course load. `_decode_splat` recognises the shipped case — one RGBA8 splat map at exactly the
heightmap's resolution — as a copy.

**A bug came out of the last one.** `int(float(x) / float(target.x) * float(sw))` is not an
identity when the sizes are equal: eleven of bunny_hill's 179 columns and eight of its 519 rows
were reading the neighbouring texel's terrain, so whole 50 cm stripes of every shipped course ran
on the wrong friction. It was invisible because the shading comes from the splat texture directly
on the GPU and only the physics goes through the resample. Index maps are integer arithmetic now,
and `TestSurface._splat_resample` asserts the identity on the six widths that ship.

Structurally, `race_scene.gd` is 1094 → 815 lines. `RacerRoster` owns who is on the hill and who
is winning (and is the `Racers` node); `IntroSequence` owns the start animation and the camera it
borrows; `LaunchArgs` parses the command line and the URL query once into one list, which closed a
gap nobody had written down — `?opponents=5&difficulty=hard` did nothing in a browser. Each was
extracted with the Bunny Hill reference capture byte-identical either side.

`TestScripts` is new and covers a real hole: the suite is written against the node-free
simulation, so it never loaded `race_scene.gd` or anything under `scripts/shell/`, and a parse
error there passed 3638 assertions. The benchmark now also reports ten racers on one snow field
(1.64 ms/frame, 9.8 % of budget) and `SnowField.decay`, so neither cost can quietly come back.

3646 assertions, 0 failures.

**Not done:** the importer is still one 1849-line class. `REVIEW.md` §4 proposed splitting it and
the outcome section explains why that was stopped — every domain threads `_log`/`_warn`/
`_protected`/`source_dir` through `self`, so there is no cheap composition seam, and verifying it
needs a full 44-course re-import whose diff is ~116 000 lines by design.

### The forest stopped flickering · **done**

Reported as trees that "sometimes flicker, looks a bit like z-fighting", on the wall of trees down
the left of Challenge One, from the moment the start animation ends. It was z-fighting, and the
cause is in the data rather than in the renderer: ETR places every object on an object-map cell
and draws a collidable one as two world-axis-aligned quads, so **a row of trees shares its z to
the last bit and the X-quads of any two standing closer together than the sum of their radii are
exactly coplanar over the overlap**. No depth buffer resolves that — the test is a comparison and
neither surface is in front — so the pair swaps, frame by frame, over a region the size of a tree.
Challenge One has 1255 such pairs, 522 of them in the column at x = 50.505 that lines the left of
the course.

`CourseRoot.decorrelating_yaw` turns each collidable object by a yaw hashed from its own position,
±20°. The geometry stays the original's — two fixed planes at 90°, turned toward nothing — and the
position, the silhouette and the collision cylinder do not move. Measured on a 1/10-speed capture
of Challenge One (so the camera creeps and any large frame-to-frame change is flicker rather than
motion), pixels that oscillate across eight frames: **1142 → 192**. Widening the jitter to ±45°
gives 179, which is the floor: the residual is the alpha-scissor cutout edge crawling by a pixel,
not depth fighting. ±20° is kept because it leaves a tree presenting ETR's face to a racer coming
down the fall line.

A hash decorrelates in the aggregate and cannot promise a floor, so
`TestObjects._no_two_trees_share_a_plane` asserts the distribution rather than the worst pair: no
overlapping pair coplanar (3215 → 0), and the share within a tenth of a degree in line with what
±20° of spread predicts (11 of 3215, against 16 expected). It reads the yaw off the markers and
the shared helper, not off the `MultiMesh` — `MultiMesh.get_instance_transform` returns the
identity under `--headless`, which would have made every tree look perfectly coplanar with every
other and passed the test for the wrong reason.

3818 assertions, 0 failures.


### The camera stopped swinging on a jump · **done**

Reported as the camera making "1-3 nervous moves from left to right" during a jump. The lag model
was not the cause and neither was the racer: **airborne, the horizontal velocity is exactly
constant** — there is no steering off the ground (`calc_friction_force` returns zero, and steering
in this game is a rotation of the friction force), and neither gravity, the jump impulse nor
Reynolds drag turns it. So everything the camera did sideways came from the one other lateral term
in `ChaseCamera.track`: `up = surface_normal.lerp(UP, 0.5)`, the lean that keeps the camera from
burying itself in a steep pitch, multiplied by `height` and added to the offset.

That lean was taking the **whole** terrain normal, including its across-track half, which does
nothing for the burying problem and translates the camera sideways instead — a yaw swing at 4 m
behind the player. On the ground it is at least coherent, because the racer is on the surface it
is leaning with. Airborne it is not: the racer flies straight and the ground beneath it does
whatever it likes, and a jump is taken off the ridge where the normal sweeps hardest of all.

Measured by driving the real physics down a real course, jumping, and reading the yaw off
`ChaseCamera`'s own basis over the airborne stretch:

| course | camera yaw, before | reversals | after | heading moved |
|---|---|---|---|---|
| Bumpy Ride | 16.63° over 1.85 s | 5 | 0.12° | 0.01° |
| Downhill Fear | 11.17° over 1.70 s | 4 | 0.22° | 0.00° |
| Wild Mountains | 11.23° over 0.62 s | 2 | 0.03° | 0.00° |
| Chinese Wall | 1.98° over 0.50 s | 1 | 0.03° | 0.00° |
| Bunny Hill | 0.61° over 0.43 s | 0 | 0.02° | 0.00° |

Two to five reversals of eleven to seventeen degrees, on a penguin flying dead straight, is the
report exactly.

`ChaseCamera._lean_up` keeps only the component of the tilt in the vertical plane the racer is
travelling in. The anti-burying behaviour is unchanged — it was always a fore-and-aft effect — and
the `MIN_CAMERA_HEIGHT` backstop fires at the same rate as before (Downhill Fear 48.5 % → 49.2 %,
Wild Mountains 74.5 % → 74.4 %). The ground ride got quieter too, since the same term was
wobbling the camera over every bump: mean |Δ²| of the drawn yaw halved on Bunny Hill (0.0042° →
0.0021°) and on Bumpy Ride (0.0216° → 0.0084°).

`TestCamera` asserts the invariant rather than the numbers — the lean is square to the direction
of travel for any normal and any heading — plus the end-to-end property on two courses, and that
the pitch half survived, so deleting the lean outright would not pass. It also asserts that the
normal under the flight really does sweep, or the test would pass on a course that got flattened.

4096 assertions, 0 failures.


### Ice reflects the racers standing on it

ETR reflects nothing, and neither did we: ice was a Fresnel-weighted two-colour sky ramp and a sun
glare, which is what distinguished it from snow. It now also reflects the penguins.

`IceReflection` is a `SubViewport` on the **same `World3D`** as the race, holding one camera: the
chase camera reflected through the ice plane under whoever is being watched, with `cull_mask`
narrowed to the layer `Racer._apply_reflected` puts the rigs on. Because the world is
shared, the mirror draws the rigs the main pass already posed — no duplicate rig, no pose copy,
and a ghost, an opponent and a remote peer are reflected without any of them being mentioned. The
ice branch of `terrain.gdshader` samples the result by `SCREEN_UV`.

Three things were measured rather than assumed, all in spike S7:

- **The shared world works.** A camera basis with determinant −1 renders identically to the
  alternative design (a mirrored duplicate in a world of its own): reflection patch r=0.669
  against a control of r=0.616, in both. The shared version is strictly less machinery.
- **The winding needs no fixing.** `CULL_BACK`, `CULL_FRONT` and `CULL_DISABLED` all measure
  0.669 to three decimals — the renderer flips the front face itself for a mirrored view matrix —
  so character materials are untouched and there is no per-racer material duplication.
- **Fresnel at chase-camera incidence is 0.02–0.09.** Probing `EMISSION = vec3(fresnel)` moved the
  plane by 0.004. This is the same wall the sky ramp hit and it is recorded in AGENTS.md as "0.09
  of sky over an already near-white albedo is four levels nobody sees".

That last one is why the reflection **occludes the sky ramp instead of adding to it**. Where the
mirror has a penguin, the penguin is what the ice reflects *instead of* the sky, so the whole term
stays inside the Fresnel budget the sky was already spending and can never out-brighten the
surface it is a reflection in. A dark penguin between bright ice and a bright sky is a dark shape,
which is the one thing that shows up on a surface already near the ceiling. An additive version of
the same term is invisible.

Measured on `tuxway` (100 % ice), 200 frames, `--auto-input=carve`:

| | pixels changed | max delta | where |
|---|---|---|---|
| reflections on vs off | 4227 (0.29 %) | 17 levels | one box, (741,448)–(857,515) |
| rerun, same setting | 0 | 0 | — |

The capture is bit-exact on rerun, so all 4227 pixels are the feature, and they are confined to a
box directly under the penguin — which is the plane fade doing its job. The player's own
reflection is the *least* visible case, and correctly so: a penguin lying on its belly on the ice
occludes nearly all of its own reflection. Opponents seen across the slope, at the grazing angles
Fresnel likes, are where it reads.

Cost, `tuxway` with a field of nine, unthrottled: **0.11 ms/frame** (5.35 ms against 5.24 ms), or
about 0.7 % of a 16.7 ms budget. The mirror renders at half the main viewport's resolution — a
reflection in ice is the one image in the frame allowed to be soft — and stacks with
`render_scale` rather than fighting it. `[display] ice_reflections = false` turns it off and frees
the target; the Configuration screen has the checkbox.

The approximation is the plane, and it is the honest one: a planar reflection is only true on its
plane and the terrain is a heightmap. The plane is the tangent under the racer being watched,
which is exact at the contact point — where the feet are, and where the eye checks it — and wrong
at a rate that grows with distance from it. `reflection_fade_distance` (8 m) confines the term to
the patch the plane came from. Without it the `SCREEN_UV` lookup would put a penguin into any ice
anywhere in frame, at any height and any slope. It bounds the error in the *surface* and not the
one in the *subject*, which is the half that went wrong later — see *An opponent's reflection
stopped floating off its penguin*.

`TestReflection` asserts the geometry rather than the pixels: the plane is fixed, the mirror is
its own inverse, the determinant is −1 and the basis stays orthogonal, a camera one metre up comes
back one metre down without sliding sideways, the racer meshes are on both visual layers, and the
setting round-trips through the hand-written settings file.

4228 assertions, 0 failures.


### Ice stopped going white at a flat angle · **done**

Reported after the renderer split: *"when looked at a flat angle, ice now is very bright — almost
white"*, from the opening seconds of **Who Says Penguins Can't Fly?**, which is a course with no
snow layer in it at all (`rock`, `ice1`, `rock06`, `rock01`) and so shows the ice branch with
nothing else in the way.

It was one bug with two causes, and the renderer split only *revealed* it. Under the old
`EMISSION` path Compatibility sRGB-decoded the reflection to 43 % of itself, which kept it
accidentally inside budget; moving it to `SPECULAR_LIGHT` — correct, and done for the units —
delivered it at full strength.

**The term was added instead of split.** Fresnel divides incoming light between the mirror and the
diffuse underneath; the shader added `F · sky` on top of a diffuse that had already been through
ETR's illumination clamp, so the surface could exceed its own albedo — the one thing
`etr_illumination.gdshaderinc` exists to prevent. Invisible at the ~65° incidence the ice look was
*fitted* at, where `F` is 0.09 and the term is four levels. At 84°, sighting down a gully, `F`
reaches 0.6.

**And the radiance being mirrored was not a sky.** `sky_horizon` was the preset's `fog_color`, and
ETR's `[fogcol]` is a fade target: 40 of the 44 shipped courses declare `1 1 1`. The ice was
reflecting a sky at full radiance — brighter than the skybox drawn beside it in the same frame,
and achromatic where the real one is blue. The migrated faces measure (184, 196, 218) across their
horizon band and the frame draws that at linear 0.59/0.62/0.73, against the 1.0/1.0/1.0 the mirror
was being handed.

The fix is three lines and one new migrated field:

- `mirror_share` comes out of `ALBEDO` (`1 - mirror_share`), which is the half Godot multiplies
  the diffuse by, so the mirror and the diffuse sum to the surface instead of past it;
- the grazing end of Schlick is `1 - ice_roughness` rather than 1, because a rough dielectric never
  becomes a perfect mirror;
- `EnvironmentPreset.sky_horizon_color`, averaged by the importer off the middle tenth of all three
  faces. The band matters: the top of a face is deep blue and the bottom is mountains, which is why
  `sky_nadir_color` — 40 % darker than the sky above it — could not stand in.

Measured, on the real GPU at a true 1280×720:

| | before | after | with the reflection off |
|---|---|---|---|
| `penguins_cant_fly`, worst grazing lift | +135 levels | +43 | — |
| ... p99 lift | +80 | +15 | — |
| ... frame fully white | 0.74 % | 0.12 % | 0.12 % |
| `tuxway` far lake, grazing | 252/254/254, **74.5 % clipped** | 168/181/201, 0 % | — |
| `tuxway` mid-lake, chase incidence | 200/205/212 | 183/190/199 | — |
| `tuxway` foreground, near normal | 168/176/187 | 165/173/184 | — |
| Bunny Hill lit near field (snow) | 237.1/246.2/255.0 | 237.1/246.2/255.0 | — |

Snow is identical to the decimal because every line of the change is gated behind `ice_mask > 0`.
Ice at chase incidence does drop 13–17 levels, which is the fit moving because one of its inputs
was wrong, not the fit being abandoned: it was solved against a white sky the frame never had.
`ice_albedo` is the knob if the mid-tone wants to come back — putting the white sky back is not.

Then, on request, some of the far-field sheen came back — not by loosening the bound, but by
fixing what a grazing ray reflects. The ramp is a *sky* ramp, and a mirror ray that leaves at three
degrees has not reached the sky: from distant ice it crosses the far field first, and the far field
is by definition what the fog has faded to `fog_color`. So `fog_color` returns as
`ice_distant_tint` — the same constant the horizon end was wrongly using, now answering the
question it actually answers. **Two gates, and the distance one is the load-bearing half.** A first
cut used the terrain's own albedo with no distance gate and went the wrong way on the very course
that was reported: the shaded gully bowl fell from 150/167/193 to 126/145/164, because up close a
low ray lands on the near bank, which on `penguins_cant_fly` is the rock blended into its own
splat. Gated on distance, the same term lifts far ice down the gully from 168/180/202 to
186/195/212 and the worst grazing point from 138/155/185 to 188/197/215, against the 220/229/245
the unbounded build had there — with the frame's fully-white fraction going 0.12 % to 0.15 %.

`TestLighting` asserts the energy split, the roughness cap and the distance gate textually, for the
same reason it asserts the clamp that way: adding rather than mixing renders a perfectly plausible
frame at the angle anyone would check, and dropping the distance gate renders a plausible one at
the *distance* anyone would check. `TestEnvironments` asserts that all eight presets reflect
something below white, and that it is not `fog_color`.

4307 assertions, 0 failures.

---

### The earth stopped reaching into the valley (2026-09-11) · **done**

Reported against **Who Says Penguins Can't Fly?** again — the same course, for the same reason it
found the ice bug: it is a bare ice gully between two rock plateaus and nothing else is in the way.
*"The original has the whole valley covered by ice and the plateau top on both sides is earth; the
Godot port lets the earth-material reach deeper into the valley."*

The splat PNG on disk was correct. Measured against ETR's own field — the per-vertex terrain index
from `terrain.png`, resolved through `GetTerrain`'s first-within-±30 scan and rendered by
`quadsquare`'s ordered vertex alpha — the importer's output covered the course 58.5 % rock /
30.5 % ice / 9.8 % rock06 / 1.2 % rock01 against ETR's 58.8 / 30.2 / 9.7 / 1.2.

**The texture importer was editing it.** `process/fix_alpha_border` defaults on, and it rewrites
the RGB of every texel whose alpha is below 30/255 with the RGB of the nearest texel above it
within four texels. That is the right thing to do to a cutout sprite and the wrong thing to do to a
weight field, where alpha is layer 3's weight; "nearly transparent" here means "not mostly rock01",
which is 98.8 % of this course. Comparing the loaded `Texture2D` against the PNG byte for byte:
**18.7 % of texels differed**, channel deltas up to 255. Ice fell to 26.9 % and rock06 rose to
14.1 %, and because the rock01 slivers sit exactly along the rim — they are the antialiasing ramp
in the source image — the bleed painted rock weights over the ice next to them, which is the earth
walking down the wall. 20 of the 44 courses have four or more layers and all 20 were affected.

Two grid errors were underneath it, each worth a fraction of a metre and both pushing the same way:
`build_splat()` mapped the source grid onto the target with `x / target_w * nx`, truncating where it
should round and stretching by a texel end to end, and `terrain.gdshader` read the result at
`world / world_size` instead of on texel centres. Fixing the first by rounding only moved the bias
to the other side — `HEIGHT_UPSAMPLE` is even, so half the target samples land exactly between two
source vertices — so the resample is bilinear now, which is also what ETR's vertex alpha does across
a boundary cell. Measured against ETR's 50 % crossing over 255 rows: **+0.28 cells mean before,
−0.01 after**, worst case 0.60 → 0.30.

The fix is three lines of arithmetic and a `.import` sidecar the importer now writes itself
(`write_splat_import()`, which also pins `detect_3d/compress_to` to Disabled so the editor can never
quietly re-import the weights block-compressed). `tests/test_splat.gd` guards the consumer rather
than the settings: every texel's weights must still sum to one across all of a course's splat maps,
which the bleed breaks by up to 85/255 and which no amount of legitimate image processing would.
It also compares the loaded texture against the PNG wherever the PNG is reachable. See
[`materials.md`](./materials.md) §1.2 and the trap list.

4544 assertions, 0 failures.

### It snows now, at four grades (2026-09-14) · **done**

ETR's race-select screen offers three weather controls beside the course list — light, snow and
wind, each an icon button cycling four states (`CRaceSelect`, `g_game.light_id/snow_id/wind_id`).
The snow one is built.

`SnowFall` is both of the original's layers, and they are two different effects:

- **Flakes** (`CFlakes`) — three nested boxes around the player, 5 m, 12 m and 30 m wide, holding
  400/500/1000 quads each depending on the grade. The boxes are staggered *ahead* of the racer —
  the near one straddles them, the other two cover 2–10 m and 10–25 m down the hill — and the
  flakes get bigger and fall faster the further out they are, so all three read as one field at
  about the same size on screen. Nothing spawns and nothing dies: a flake that leaves the box is
  teleported to the opposite face.
- **Curtains** (`CCurtain`) — three rings of big tiles at 40, 50 and 60 m, each quad 15–32 m
  across, drawn from a sparse field of specks, turning slowly around the player on six shared
  oscillators and sinking at 3 m/s. This is what makes heavy snow read as weather rather than as
  confetti in front of the camera: at that distance an individual flake is below a pixel and a
  tile of them is not.

**The flakes are a `MultiMesh` with the motion in a vertex shader**, where the original walks up
to three thousand of them on the CPU every frame. It can be, because the whole of the per-frame
motion is two numbers the area shares — the drift (wind, plus the part of the player's own travel
the snow does not follow) and the integral of the fall speed, which a flake scales by its own
size. `shaders/snow_flakes.gdshader` adds them, wraps with a `mod` and billboards, and the batch
itself never changes. Two things fall out of that. It is **deterministic**, which the spray's
`GPUParticles3D` is not — a snowing reference capture is comparable frame for frame, and a
snow-free one is byte-identical to what the repository had (measured: the residual against a
build with the node absent is 0.353 % of the frame at a mean |Δ| of 0.033/255, against a
run-to-run noise floor of 0.367 % and 0.034 for two identical runs, all of it inside the spray
plume). And it is **cheap**: 900 frames of Bunny Hill take the same wall time at grade 3 as at
grade 0 on this GPU, and the CPU half — three uniform sets and 135 curtain transforms — is
0.137 ms a frame, measured over 3600 updates.

**The follow fraction is the whole feel of it.** `CFlakes::Update` moves every flake by 80 % of
how far the player fell and 60 % of how far they travelled down the hill, and not at all
sideways: at 100 % the snow is painted on the camera and at 0 % it is a wall you fly through at
80 km/h with every flake a streak. That residue is what the shader's drift accumulates, and
`TestSnowFall` asserts it as arithmetic because a still frame cannot show it.

Chosen on the course screen, in Practice and in a race alike — ETR puts it there too — and
remembered as `[game] snowfall` in `penguinracer.cfg`. `--snow=0..3` and `?snow=` name a grade for
one run without going through the menu, which is how the captures above were taken. It is
**presentation and nothing else**: no racer drives differently in it, which is the original's
arrangement as well. The tint is the environment's `[partcol]`, the same field the spray is
tinted by, so night snow would be blue without anything in the effect knowing which sky it is
under.

The art is redrawn rather than copied, like the spray's puff atlas and for the same reason: the
flakes borrow `SprayEmitter.make_puff_image` (ETR binds the same `SNOW_PART` atlas for both), and
the curtain tiles are generated to the originals' measured density — 251, 882 and 2184 specks
over a 512² tile, covering 1.5 %, 4.6 % and 14.7 %. The deviations that ride with the port are in
the trap list under AGENTS.md's deviations.

Verified on both renderers: Mobile on the desktop and Compatibility, which is what the browser
runs — the `MultiMesh`, the custom instance data and the vertex-stage billboard are all inside
WebGL2's floor.

4665 assertions, 0 failures.

### The window can be any shape · **done**

`project.godot` now ships `window/stretch/mode="canvas_items"` with `aspect="expand"` instead of
the default `keep`. The canvas holds the 1280x720 base's 720-pixel short side and grows along the
long one, so a 16:10 laptop draws on 1280x800, a 21:9 monitor on 1680x720 and a 4:3 panel on
1280x960, and no window shape is letterboxed against a design resolution any more. Two things had
to change to carry that, one in each dimension of the problem: the HUD's corners (see the HUD
section) and the camera's lens.

`window/stretch/aspect="expand"` made the window's shape the camera's business. Wider than 16:9 it
already was: `Camera3D` keeps the vertical angle by default and opens the horizontal one, so a
21:9 window really does see more hill to either side, which is the whole reason for expanding
rather than letterboxing. Narrower than 16:9 that same default is backwards — it would hold the
vertical angle and *close* the horizontal one, so a 4:3 window would see less of the course to the
sides than a 16:9 window, and less than the letterboxed 4:3 window it replaced, which at least kept
the entire 16:9 picture between its black bars. Peripheral vision is not a thing to lose to a
window shape in a downhill racer.

`ChaseCamera.fov_for_aspect` opens the vertical angle instead below 16:9, by exactly enough to hold
the horizontal angle at the design value: 70° vertical at 16:9 becomes 75.8° at 16:10, 86.1° at
4:3 and 102.5° at 1:1, and the 16:9 frame stays a subset of what every shape draws. At and above
16:9 it returns the design angle untouched, so every capture in these notes is of the same lens it
always was. It is static and pure and `TestCamera` drives it directly, including the zero-area
window a platform reports for a frame or two, which an unguarded division would answer with NaN.

Checking any of it needed a bug fixed first. `GameConfig.apply_display` is supposed to stand aside
when the command line has already sized the window — that is what lets `tools/shot.sh` capture at
a size the developer's own settings file does not name — and it guarded itself with
`OS.get_cmdline_args().has("--resolution")`, which is never true: the engine consumes the arguments
it recognises and hands the script only what is left. The file had quietly been winning every
capture, so the first three screenshots taken at three different shapes came back as three
identical 1280x720 PNGs. It measures the window against the `project.godot` base now, in logical
pixels because a fractional output scale does not hand back the size that was asked for, and the
settings screen passes `forced` so that a player naming a size still outranks the launch.

Then checked at three shapes — 1280x720, 1280x960 and 1500x643, all of Bunny Hill at the same
frame of the same scripted run. The 4:3 frame keeps the same hill between the same trees and adds
sky above and snow below; the 21:9 frame adds slope to either side; both wear the HUD in their own
four corners. The 16:9 capture is byte-identical to the one taken before any of this, which is the
check that matters: the anchors and the lens are exact no-ops at the design shape.

4724 assertions, 0 failures.

### The streamed build says what it is doing (2026-09-16) · **done**

On a web build a course arrives over the network (risk S6, `PackStream`), and until now the
player watched it arrive from inside the race: `race.tscn` was already drawing, so the rig stood
on nothing for the length of the download with a bare centred `Loading course…` label over it.
The menu *did* raise ETR's proper loading panel — the course in yellow, "please wait" under it —
but `change_scene_to_file` tore it down with the menu, one scene before the wait actually
happened.

That panel is now a scene of its own, `scenes/loading_screen.tscn` / `LoadingScreen`, instanced
in both `main_menu.tscn` and `race.tscn`. Same markup, same theme, opaque backdrop, so the swap
between the two is invisible and there is no frame in which a penguin is standing on an empty
hillside. It comes down after `restart()`, not after the download — everything it covers has to
be finished, and the three blocking steps between those two points (`load()`, `build_runtime()`,
`TerrainRenderer.setup` plus the first streaming pass) are most of the freeze on a slow machine.

The bar under it is the download for its first three quarters and then four fixed marks, because
those four steps cannot report from the inside. Getting a *total* to divide by took finding out
that **`HTTPRequest.get_body_size()` is -1 for the whole of a download on the web export** — the
web `HTTPClient` wraps `fetch` and never surfaces `Content-Length`, confirmed against this
project's own server with the header verified present by `curl`, nineteen consecutive polls all
reading `total=-1` while `downloaded` climbed correctly. `PackStream` asks the page instead, with
a `HEAD` through `JavaScriptBridge` fired beside the real request; if that comes back empty the
bar is taken away and the note counts megabytes rather than parking at a number that is not true.
`tools/webtest/server.js` gained `Content-Length` in the same pass — Node answers chunked without
it, so the harness had only ever been exercising the fallback.

Verified in Chromium against the streamed build, throttled to 2 Mbit/s after boot so that only
the course pack is slow: Snow Run 2 (9.0 MB) draws "Loading 'Snow Run 2'", a live `4.1 / 9.0 MB`
and a bar that fills, then holds at the phase marks through the build, then hands over to a
complete hillside. `RACE_READY` still arrives.

**The native path is unmoved, and that was the thing to be careful about.** `DebugCapture` counts
frames from the moment the process starts, so a frame spent painting a panel on the way in would
renumber every reference capture in the repository. The phase steps wait for a composited frame
only when `PackStream.is_streamed()` says this build is actually fetching; on native `ensure`
never suspends and `load_course` still runs start to finish inside one frame.
`Engine.get_process_frames()` at `RACE_READY` reads 0 before the change and 0 after. (A capture
off this container's real GPU is not byte-reproducible run to run — two runs of unchanged code
differ, with snowfall off as well — so `md5sum` cannot settle that question and the frame count
is what was measured.)

4724 assertions, 0 failures.


### An opponent's reflection stopped floating off its penguin (2026-09-16) · **done**

Reported from *Who Says Penguins Can't Fly?* with a field of three: a few seconds after the
start, one opponent's reflection is hanging on the far wall of the pipe, several metres from the
penguin it belongs to, while the player's own sits correctly under their feet.

**One plane, and it only ever belonged to one racer.** `IceReflection` mirrors the chase camera
through the tangent plane under the racer *being watched* — exact at that racer's contact point,
which is the whole of why the feature reads. Everybody else is mirrored through it too. A racer
standing `d` off that plane is put `2d` the other side of it, and the image lands wherever that
projects. `reflection_fade_distance` does not catch it: it asks where the *ice being shaded* is,
never where the *penguin being mirrored* was standing, so a bogus reflection is accepted by any
ice within 8 m of the plane.

Instrumented on the reported course, three opponents, 60 Hz:

| | offset from the mirror plane | tilt of their ice against it |
|---|---|---|
| field on the open slope | 0.0–0.2 m | a few degrees |
| field spread across the pipe | 2–4 m | 30–107° |

So the artefact is exactly as intermittent as it looked. The tilt column is the worse half and it
is easy to miss: when the player is halfway up a wall the mirror plane itself leans 50° off
vertical, and an opponent on the flat trench floor — which can pass a height test — comes back
rotated by twice the disagreement.

**The fix is a per-racer admission test, because there is no second plane to give them.** One
pass, one camera, one plane; nine of them would be nine half-screen targets on a WebGL2 budget
(rule 2). So `IceReflection.admits` asks, per racer per drawn frame, whether the plane is nearly
true for the ice *that* racer is standing on — within `PLANE_TOLERANCE` (0.6 m, a little under
the length of a penguin, so the worst image that survives is displaced by less than the thing
casting it) and `NORMAL_TOLERANCE_DEG` (15°) — and `Racer.reflected` clears the rig's reflection
layer bit for the ones it refuses. A missing reflection is ETR's own answer and reads as ice that
is not quite mirror-smooth. A wrong one reads as a bug, because it is one.

Both tolerances widen by `ADMIT_HYSTERESIS` (1.6) for a racer already in the mirror. That is not
tidiness: an opponent holding your line one hump behind sits *at* the threshold for seconds at a
time, and a single-threshold test strobes its reflection. There is no per-racer fade to soften
the transition with — the rigs share their materials with the main pass, so anything done to dim
the mirror dims the penguin — so the transition is a pop, and the thing to do about a pop is make
it happen once.

**The watched racer is exempt, and measuring is what said so.** Its offset is zero by
construction, but the plane's normal is *smoothed* (`NORMAL_TAU`) and the terrain's is not:
carving across the pipe at 78 km/h opens **14.2°** between the sampled normal and the smoothed
one, against a 15° tolerance. The test would have started dropping the one reflection in the
frame that must never blink. `RaceScene._admit_racers_to_reflection` skips it and says why.

Verified by capture, `penguins_cant_fly`, 3 opponents, `--auto-input=carve`, 1280x720:

| | pixels changed | max delta | where |
|---|---|---|---|
| frame 340, before vs after | 536 (0.06 %) | 48 levels | one box, (529,311)–(552,342) |
| frame 260 (field bunched on the open slope) | 0 | 0 | byte-identical |

The changed box is the floating penguin and nothing else; the player's own reflection, the rigs
and the terrain are untouched to the byte. And on `tuxway` — 100 % ice, the course the feature
was measured on in the first place — **no opponent is refused in 600 frames, and a 300-frame
carve with a field of three comes back pixel-identical** (A/B with `game/` stashed, every one of
the 921 600 pixels equal). The gate costs nothing where the reflection was already right.

What it does cost is on bent terrain: on the reported course the median opponent sits 0.63 m off
the plane on ice tilted 20° from it, so over a 600-frame run each of the three is refused 52–66 %
of the time, with 5–7 transitions each. That is the honest read of the geometry rather than a
tuning failure — at 0.63 m and 20° the reflection that *was* being drawn was a metre and a quarter
from its penguin and rotated 40° — and most of those refusals are invisible either way, because
the image they would have drawn lands off the ice or off the screen.

`TestReflection` gained four cases: a racer can be taken out of the mirror and put back without
ever leaving layer 1, the plane admits its own ground and anywhere along it, it refuses the 2–4 m
and 25–60° cases measured above, and the hysteresis band holds a racer in that it would not let
in.

4764 assertions, 0 failures.


### ... and the player's own stopped climbing the wall (2026-09-17) · **done**

The same report came back with a second picture: not an opponent this time, but a reflection
directly *above* the racer it belongs to, with the racer still visibly on the ground. Reliably,
within the first few seconds of *Who Says Penguins Can't Fly?*, with no steering at all.

**Reproducing it needed the intro.** `RaceScene` sets `_intro_enabled = play_intro and
_auto_input.is_empty()`, so every `--auto-input=` capture in this repository skips the start
animation, and the whole first act of that course happens on a different clock than the one the
player sees. A run with no input source at all — `--course=… --character=trixi --opponents=3`
and nothing else — is what "just let it run, no steering" actually means, and it puts the
artefact at frame 655, byte-reproducible.

**Neither obvious cause was the cause**, which is why they were measured instead of assumed:

| suspected | result |
|---|---|
| the fragment is far off the mirror plane (`reflection_fade_distance` 8 m is loose) | tightening it to 2 m changes **0 pixels** — the ice showing the reflection is within a metre of the plane |
| `character_reflection_shear` (0.02 screen widths ≈ 20 px) drags it | removing it entirely moves 328 px by at most **8 levels** |

What it is instead is the mirror working exactly as specified. A racer's image sits `2 h` off its
own feet along the plane normal — `h` is how far the drawn body floats over the ice, about a
third of a metre, so the separation is of the order of a body. **On a floor that offset points
down the screen and lands under the belly, which is the only reason the effect has ever read as a
reflection. On a wall it points sideways.** Measured at the reported frame: the mirror plane is
**51–58° off vertical** — the racer is traversing a banked pipe — so the image slides out from
under its penguin and stands beside it. And Fresnel is at its strongest on that same wall, so the
thing that slides out is drawn nearly opaque: a solid second penguin rather than a shape in the
ice.

**The discriminator is not the incidence.** The first attempt faded the term toward grazing,
on the theory that the sky has no parallax and a penguin has plenty. It moved 4414 pixels of
`tuxway` by up to 126 levels — because a chase camera is *always* near-grazing, measured at
0.27–0.30 against the plane on the flat lake and on the wall alike. The quantity that does
separate them is how much of the offset projects to screen-*down* rather than screen-sideways:

| | screen-downwardness of the mirror offset |
|---|---|
| `tuxway`, 300 frames | 0.969 – 1.000, never lower |
| `penguins_cant_fly`, the two reported frames | 0.665 and 0.542 |

`IceReflection.attachment()` is that number, faded to nothing between 0.94 and 0.80 — outside the
first range, inside the second — and handed to the shader as one scalar for the whole frame,
since nothing about it varies across one. The sky ramp does not see it at any angle.

Verified by capture, frame 655, A/B in one session with the scalar pinned to 1.0 for the control:
**579 pixels changed (0.16 %), max 35 levels, all of them inside one box** — the floating twin,
which is gone. And `tuxway`, 300 frames with a field of three, the course the whole feature was
fitted on: unchanged.

`TestReflection` gained a case for the scalar: a level plane under a camera at any pitch is fully
attached, one banked 50–90° across the view is dropped, looking straight down the normal is
attached by definition, and the band is asserted against the two measurements above so that
moving it has to move them too.

4781 assertions, 0 failures.

---

## Known gaps

- **The near-field terrain mesh is too coarse for the trench to read as geometry.** Chunk
  vertices sit ~0.5 m apart; the contact patch is 0.45 m wide. Lighting sells the trench
  (normals are reconstructed per fragment from the trail map) but the silhouette does not move.
  Plan §4.4 already anticipates this — "only chunks inside the deformation window need the
  displacement path" — so the fix is a denser mesh for those chunks. Until then the racer is
  drawn against the bare heightmap rather than against the trench it is standing in
  (`Racer._drawn_snow_lift`), because the alternative is a penguin sunk into snow that was never
  dug out. That compensation comes out when this gap closes. It is sampled **on the tick** and
  interpolated with the pose (`Racer.sample_snow_lift`): read live from `present()` it was a
  60 Hz, ~4 mm sawtooth on the drawn body — the field is smooth in space but a step function in
  time, and frame time was resampling the steps. It is also the one consumer that takes the
  trench back undivided, which is why it — and not the physics, which filters through the spring —
  is where the grid's aliasing showed up as a visible 12 Hz bob. Both are fixed; see the trap list.
- **The lit near field still clips more than the original's.** Closed as far as two measured
  surfaces can take it — both now match within a level in all three channels (history §22) — but
  our lit region's *upper half* runs about six levels over ETR's, so 53 % of its green clips
  where the original clips 3.5 %. Ruled out: the §12 relief and glint (turning them off makes the
  region brighter, not darker), the trench lip's albedo boost and the half-Lambert wrap (two
  levels each, both deliberate). What is left is most likely that the two frames are not the same
  view — ETR's reference is at 25 km/h on undisturbed snow, ours at 44 km/h over a fresh trench,
  and the camera is 70° FOV at 19° above the slope where the original is 60° at 10°. It wants a
  reference capture taken at a matched camera, not another fitted number.
- **The snow is tuned against one frame of one course.** Bunny Hill under `tuxracer_sunny` now
  matches the original at both ends of its range and in all three channels (history §11, §12,
  §22), but the fit is six numbers solved on two surfaces in one screenshot. It does reach every
  shipped course: all 44 select a *sunny* preset — 40 `etr_sunny`, 4 `tuxracer_sunny` — and the
  two carry identical `[diff]` and `[amb]`, differing only in the skybox (the `etr` faces are
  1024² and much brighter) and the fog colour. Since `ambient_light_sky_contribution` is 0 the
  brighter sky does not feed the ambient, so the fit should carry; nobody has measured it on an
  `etr_sunny` course against a reference. The four cloudy/evening/night presets are untuned and
  **§22's fix moved the dark ones the wrong way**: undoing an sRGB decode raises a dark value far
  more than a bright one, so `night`'s `[amb] 0.2` now gives a shaded snow of about 105/255
  against the original's 47, where the old double-bend accidentally gave 45. Nothing selects them
  so nothing regressed, but each needs its own fitted `sun_gain`/`ambient_gain` — which is what
  those being per-preset fields is for. Same method, one reference capture each.
- **The camera does not frame the course the way the original does.** `race.tscn` uses a 70°
  vertical FOV where `param.fov` is 60, and `ChaseCamera` sits 19° above the slope plane where
  `view.cpp` puts it at `CAMERA_ANGLE_ABOVE_SLOPE`/`PLAYER_ANGLE_IN_CAMERA` = 10°. Both are
  one-line changes; together they are why a side-by-side still looks different after the shading
  matches — ours shows a third less sky. Left alone because it changes how the game plays, not
  how it looks, and that is a design call rather than a fidelity one.
- **The game shell stops at free course selection** (Phase 5): no cup progression, medals or save
  profiles. The migrated event thresholds are sitting there ready; the translations are wired up.
  The settings screen moves the six keys a player can act on and not the three ETR's own
  configuration screen also has — sound volume, music volume and language — nor the two
  multiplayer keys, which are a name nobody can see used and a port with no session to open. The screens carry the original's
  palette but none of its menu art — corner ornaments, title logo, drifting `ui_snow` — which is
  blocked on the licence audit below.
- **All five characters are the importer's welded-sphere placeholders**, and only Tux's has been
  looked at joint by joint. The other four render, animate and carry their own clips, and the
  suite checks the contract they share; nobody has compared Trixi's start animation against the
  original frame by frame; a ghost is drawn as whoever set the time, not as whoever is racing now.
  The racing pose layer does run for all five, and four of them are missing at least one joint it
  names — Samuel has no right leg and no tail — so half of what `AdjustJoints` asks for silently
  does nothing on him, exactly as in the original. Every character has identical physics, which is
  true in ETR too: `characters.lst` carries no per-character constants and `[type]` is a column
  nothing reads.
- **The start and finish banners billboard, where the original pins them.** `object_types.lst`
  gives both `[usenorm] 1 [norm] 0 0 1` and `DrawTrees` builds their quad about that fixed normal
  rather than about the view direction — so in ETR they face up the hill and turn out of view as
  you pass, and here they follow the camera. Only two of the fourteen object types set the flag,
  the importer does not read it yet, and it is the same defect class as the trees were: one more
  branch in `build_object_prefabs`, plus a third mesh orientation or a uniform on the billboard
  shader.
- **The terrain slide sound is on or off**, because the original's speed-and-lean `SlideVolume`
  ships commented out (history §16), and 12 of the 43 terrains — `snow` among them — name no
  sound at all. Both are faithful and both are the obvious first thing to improve; the mapping is one
  `StringName` per terrain resource and the volume is one call in `RaceScene`.
- **Heightmap dequantization has not been eyeballed per course** (risk S3). The pipeline runs on
  all 44; three courses of differing character should be compared against original screenshots.
- **The snow and ice shading terms are tuned by eye, not against a reference.** Unlike the tone
  fit, history §12's relief amplitudes, glint sharpness and ice albedo have no measured target —
  the original has no equivalent to measure against. They are all uniforms with the neutral value
  documented, so backing any of them out is a one-line change.
- **`wind_direction` is a shader constant, not course data.** Every course's sastrugi run the same
  way. It wants to come off the environment preset, or at least be seeded per course.
- **A terrain material has two authored shading knobs and no more** — `roughness` and `uv_scale`,
  both added 2026-09-01 when the dead `normal`/`roughness` texture slots came out. Everything else
  the shader does to snow and ice is course-global, and per-layer normal maps are out of reach
  under Compatibility: the terrain shader already binds 13 of WebGL2's guaranteed 16 fragment
  texture units. materials.md §5 has the arithmetic and the extension point.
- **Multiplayer is a transport and a seam, not a game mode.** No lobby, no countdown, no
  finishing-order screen, no way in from the menu — a session is `--host`/`--join=` on the command
  line. And no web: ENet is UDP. The snapshot path a WebRTC peer would use is the one ghosts
  already run on, so the missing piece is the peer and a signalling server, not the game code.
- **A ghost is silent and leaves no trench.** It is a `PlaybackRacer`, so it has no ODE substeps
  to hang spray on and never stamps the deformation field. The same is true of a remote racer,
  plus its tree hits: the mixer has one voice per cue and no positional audio, so another racer's
  collision would be indistinguishable from your own. Spray from a state stream would have to be
  driven off the sampled velocity and steering flags rather than off substeps.
- **The GPU deformation window follows one racer.** It is a single 64 m toroidal window centred on
  the view target, so a second simulated racer outside it deforms the CPU mirror — which is what
  the physics reads, and is course-wide — but leaves no visible trench.
  `SimulatedRacer.deforms_snow` is the knob if eight racers stamping one 1024² target ever has to
  give.
- **Herring are first come, first served, and shared.** Two simulated racers on one course race
  for the same fish, because `RacePhysics.items` is one `ObjectGrid` and collecting clears the flag
  on it. That is the competitive reading; a per-racer item set would be a copy of the whole table
  per opponent. Over the network nobody agrees about it at all — a remote racer is played back and
  never touches the grid, so each machine only removes what its own racers collected.
- **A computer opponent never jumps, never does a trick and never uses the terrain vertically.**
  The jump is a fixed 294 N impulse that costs contact with the snow, and nothing in this force
  model makes leaving the ground faster, so the planner has no reason to reach for it — which also
  means an opponent will not clear a gap or use a ramp the way a good player does. Tricks are pure
  score and it ignores them.
- **The planner is two-dimensional.** It scores candidate lines in XZ and never looks at the
  height field, so it cannot see that the fast line is over a roll rather than round it, and it
  cannot tell a drop from a slope. A terrain sample is taken for friction only. Adding relief to
  the score is the obvious next thing and needs no new machinery.
- **A collision between two peers is agreed on only approximately.** Each end resolves the
  contact against where the other was `INTERPOLATION_DELAY` (150 ms) ago, so a hard
  shoulder-to-shoulder bump is felt slightly differently on the two machines and a fast glancing
  one can be felt at one end and not the other. That is the honest price of having no authority
  over positions; closing it means a server that owns every racer, which this transport would not
  survive. Between local racers — the player and the computer field — there is no such gap and the
  pair is exactly symmetrical.
- **A contact is a velocity impulse and not a solver.** One pass per ODE substep, no position
  correction and no simultaneous resolution of a pile-up, so ten racers shoved into the same
  square metre resolve pairwise over a few ticks rather than at once. The overlap term is what
  stops that reading as bodies inside each other; nothing stops a racer being squeezed against a
  tree, which is a wall and does not move.
- **Nobody can be knocked over, off their line hard, or out of a race.** The response is
  horizontal, restitution 0.35, and the physics has no notion of a crash state — ETR's own tree
  hit is the same shape, a velocity deflection and nothing else. Being barged is a lost second,
  never a fall.
- **A race is not a cup.** The finishing place is one line on the results screen that comes up
  after the line, and `wonrace`/`lostrace` follow place rather than a cup standing. No podium, no
  per-racer times, no points table — those belong with the imported `EventSet` data and the
  profiles that are still to come.
- **An opponent's grooming counts toward a saved time.** Nine simulated racers stamp the same
  `SnowField`, and packed snow is faster here, so a time set in a race is not strictly comparable
  to one set alone — and nothing stops either from being saved from the results screen. That is
  the deliberate reading (racing a groomed line is racing), but it means a saved run from a race
  and one from a practice run are not quite the same measurement.
- **The character is the one lit surface without the illumination clamp**, and adding only the
  clamp would make it look worse rather than better. Three things are wrong together.
  `shape.lst` gives each part a `[diff]` in *display* space — Tux's `blackcol` is `0.1 0.1 0.1` —
  and the importer stores it as a linear vertex colour on a `StandardMaterial3D`, so a fully lit
  black part reads 89/255 where ETR reads 26. The material has no clamp, so on a racing pose with
  the sun on his back the illumination runs to about 2.5 and he reads 137: grey, not black.
  And ETR gives every character material a real `[spec]`/`[exp]` (`blackcol` is 0.5 at exponent
  20), which is where the form on his sunlit side comes from in the original and which this build
  has never had — so clamping alone would pin everything above `ndl` = 0.21 flat and take away the
  gradient without giving the highlight back. Done together: `srgb_to_linear` on the migrated
  colours, the include, and a specular lobe land the back at 22 against ETR's 26 and the white
  belly at 199 against 199. It needs a `character.gdshader` and a transparent variant of it
  (`Racer.make_translucent` duplicates a `StandardMaterial3D` today) plus a re-import of the five
  rigs, which is why it is a job and not a line.
- **Ice is 16 levels darker under Compatibility than under Mobile.** `tuxway` mid-lake measures
  176.6 R on the desktop and 160.5 in the browser, and the reflected penguin is correspondingly
  fainter. Most of the original 25-level gap was the sky reflection going through `EMISSION`,
  which the two renderers do not treat alike — `EMISSION = vec3(0.5)` reads back as 0.500 linear
  under Mobile and 0.216 under Compatibility, and it rides `SPECULAR_LIGHT` now, which they agree
  on. The remaining 16 are somewhere else in the ice branch and have not been chased. Snow, which
  is most of every course, agrees to within a level.
- **Asset licence audit not started** (risk S5). Independent of engineering, long lead time,
  blocks Phase 5.
- **Two terrain layers import with no albedo**, because `terrains.lst` names a texture that is
  not in the tree: `pave04` wants a `pave04.png` nobody shipped and `snowy_hockey_ice` writes
  `snowy_ice02` without the extension. Untextured in the original too, and no shipped course
  paints either colour key, so this is a note rather than a bug — the importer warns.
- **Two of ETR's three weather controls are still missing.** The race-select screen offers light,
  snow and wind; only the snow is on the course screen. The **light** one cannot simply be added:
  it picks one of four `light.lst` presets, and only the *sunny* ones have had their
  `sun_gain`/`ambient_gain` pair fitted — the display-space fix moved evening and night the wrong
  way (night's shaded snow reads about 105/255 against the original's 47), so offering them would
  ship a course that is visibly wrong. Nothing selects them today, which is why nothing has
  regressed. The **wind** one is only `--wind=`: `WindField` and the HUD's rose are built and
  feed air drag, but wind belongs to a cup race in `events.lst` and there are no cups yet, so
  there has been nowhere for the player to ask for it. Adding it to the same row the snow is on
  is now a small job — `RaceSetup` is the object that carries this.
- **Nothing occludes a racer in the ice mirror.** The mirror pass narrows `cull_mask` to the
  racer layer, which is what keeps the reflection of a slope out of the slope, and the cost is
  that the pass contains no occluders at all: a penguin behind a tree, a rock or a rise is drawn
  into the mirror as if the line were clear. The per-racer admission test takes most of it away
  incidentally — it confines the mirror to racers standing within 0.6 m and 15° of one plane, and
  there is not much course between two points in a slab that thin — but it is not a fix for this,
  and a real one wants depth in the mirror pass, which Compatibility will not cheaply give
  (rule 2). No capture has been made that shows it; it is listed because it is a property of the
  design rather than a suspicion.
- **`[starttex]`, `[tracktex]` and `[stoptex]` are still unported.** They are the original's
  trackmark decal atlas indices, and the GPU trail map replaced the thing they index. Nothing
  needs them; listed so the gap in `terrains.lst` coverage is deliberate.
