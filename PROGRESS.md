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

**0 failures** — 2293 assertions when the phase closed, 4951 today across physics, surface,
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
art that waits on the licence audit (the checkbox-icon standing), and the spray tint is the
environment's `[partcol]`, re-applied to the live emitters whenever the environment is (it was
read only when they were built until 2026-09-23, so night spray stayed sunny white). A
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
  Drawn only when the course has wind: the course screen's *Wind* row (2026-09-24), or ETR's own
  grades through `--wind=1..3`.
- **The frame rate**, centred across the top, behind `[display] show_fps` (ETR's
  `param.display_fps`, off by default, a checkbox on the Configuration screen), or `--fps` / `?fps`
  for one run.

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
paint over the blue. Both are `etr-0.8.4/data/textures` art and wait on the licence audit.

The `param.ui_snow` particles came later (`scripts/shell/menu_snow.gd`, `MenuSnow`): ETR's
`TGuiParticle` update verbatim — gravity, air drag, and a push from the pointer's velocity that
falls off with the squared distance and scales with flake size — drawn as one `MultiMesh` of the
spray's redrawn puff atlas. It runs behind the main menu's root page and nowhere else yet: the
panels opened from it are opaque `colBackgr` screens and hide it, where ETR draws it under every
menu. The count stays at ETR's starting one (about one flake per pixel of width, ~1 ms a frame
natively in GDScript) rather than climbing to ETR's ~2400. `TestMenuSnow` covers fall, push and
determinism.

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
last of those. Sound and music volumes are ETR's `options.txt` keys that this file and this
screen still do not carry; the language arrived on 2026-09-28 (see below).

### Multiplayer foundation · **done — seams built, ghosts working, and the network on top of them**

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
plays a `wonrace`/`lostrace` clip (there are no cups in this rebuild, so the mapping —
`RaceOutcome.clip` — is place in a field race, or beating the loaded ghost in a solo one, or
`wonrace` in a plain practice run, which has nothing to lose; ETR plays `finish` there, see the
deviations in AGENTS.md). From there the player can name the run and keep it (`SavedRunStore`, `user://runs/<course>_<ticks>.res`, one file per save, never overwritten).
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

**The network scaffold was ENet, peer-to-peer, and desktop-only**, and it is now a dedicated
server over WebSocket — see **Network multiplayer** below, which is the feature this scaffold was
the shape of. What survived the change unaltered is the part that mattered: each peer simulates
only itself and publishes a snapshot 20 times a second, every other peer draws it as a
`PlaybackRacer` read 150 ms behind the local clock, and no machine has any authority over any
position. Racers *do* collide, and that fits under a design with no authority only because the
contact is resolved twice, once by each body (see **Racers collide** below).

**Two bugs fell out of the refactor and are fixed.** `ObjectGrid.reset_collectables` had never
been called, so pressing `r` raced a course stripped of every herring the previous run collected —
invisible until a ghost of that run was there collecting fish that were not; `CourseRoot.reset_items`
now puts back both the grid flag and the instance transform. And a peer joining a race already in
progress used to stand still forever, because its playback clock started at zero while its
snapshots were stamped a minute in.

### Network multiplayer · **done**

Beyond the original in the largest way this rebuild goes: ETR has nobody on the hill at all, and
this is eight people on it, on two kinds of machine, out of one server.

**There is a server now, and it serves both halves.** `game/scenes/server.tscn` is the game's own
project run headless — `godot --headless --path game res://scenes/server.tscn -- --port=27015
--web-root=build/web --web-port=8060`, or `tools/serve.sh` — and it opens two listeners:

- **races**, on a `WebSocketMultiplayerPeer` server. WebSocket because a browser cannot open a UDP
  socket and this project ships to a browser: the old ENet transport could only ever have served
  half the targets. One protocol, so a desktop player and a player in a tab are in the same room.
- **the web build**, over HTTP (`WebFileServer`), with `Cross-Origin-Opener-Policy` and
  `Cross-Origin-Embedder-Policy` set — the `Web` preset has `thread_support=true`, so without
  cross-origin isolation the export dies in the console naming neither — and with `.wasm` and
  `.pck` served as themselves. `GET` and `HEAD`, one optional byte range, no keep-alive, no TLS;
  anything facing the open internet wants a reverse proxy in front terminating TLS and forwarding
  `wss://`.

The point of the two being one process: open `http://<server>:8060/` and the lobby's address field
is already filled in with the host that served the page (`RaceNetwork.default_address`, off
`location.hostname`). A link is enough.

**The server is a relay, and `LobbyServer` is the only thing on it that decides anything.** It is
a plain `RefCounted` with no `MultiplayerAPI` in it, no frames and no clock of its own — every
method takes a peer id and returns a result — which is what makes the interesting half of
multiplayer testable: `tests/test_lobby.gd` drives whole sessions through it with no sockets at
all (room filling up, password refusing the wrong digest, admin leaving and the race carrying on,
finishing order, the abandon backstop). `RaceNetwork` owns the `@rpc` surface on both ends and
calls into it on the one that is serving; the two ends are the same file, so the protocol cannot
drift between client and server.

What the server owns: the room list, who may enter a room, who may start a race, and when a race
is over. What it does not own: any position. A snapshot arrives from one member and is forwarded
to the others unread.

**The lobby is three pages behind one panel** (`LobbyMenu`), and the page is never chosen by a
button — it is chosen by what `Net` says is true, which is what makes the screen survive things
that happen *to* it rather than through it:

```
CONNECT   your name, and the server               → Net.connect_to_server
BROWSE    every race not yet started              → Net.join_room
ROOM      who is here, and the Start button       → Net.start_race
```

**The course is picked on the course screen, not on a page of the lobby.** *Create a race* and the
admin's *Change course* open `CourseMenu` — the same list, preview and details Practice and *Race
the computer* use — in one of two network modes: `NET_CREATE` swaps the opponents row for a race
name and a password and says *Create*, `NET_ROOM` shows only the snow row and says *Choose*.
`LobbyMenu` carries its own instance of it one layer up and makes the `Net` call itself; the
course screen never talks to the network. A create is answered asynchronously and can be refused,
so the picker stays up saying *Creating the race…* until the room arrives or the server's reason
does, which it then shows in place. It is taken down by the same news that moves the pages: the
session dropping, or the admin's seat passing to somebody else mid-choice. Until 2026-09-23 the
lobby had a CREATE page and two dropdowns of its own, and a player opening a room never saw what
the course looked like.

A race carries a name, a course, a snowfall grade and an optional password. The creator is its
admin: only they can change the course and only they can start it, and when they close the window
the room is handed to whoever has been in it longest rather than collapsing under seven other
people. **The password never leaves the machine that typed it** — what goes on the wire is
`sha256("penguinracer:" + room name + ":" + password)`, salted by the room name so one password on
two races is two credentials. That digest *is* the credential and the server stores it as it
arrives; the claim is "this keeps strangers out", not "this is a secret", and it is written down
that way because ws:// is plaintext.

**A name belongs to one player at a time, server-wide.** The name is the whole of what one player
knows another by here — the browser's host column, the member list, the HUD standings and the
finishing order are all names and nothing else — so two penguins called "Clemens" make every one
of those unreadable and a results screen that cannot be argued about. `LobbyServer.add_peer`
refuses a hello under a name somebody already holds, case-insensitively, the same way two races
cannot share a name; `RaceNetwork.cli_error` turns that one refusal into a dropped session, so the
lobby lands back on its CONNECT page with the name field still filled in and *Somebody on this
server is already racing under that name* on the status line. Refusing the name is not refusing the
peer: a caller the server has never heard of is still seated, under a name nobody holds, because
every other call it could make would answer `unknown_peer` otherwise.

**Starting is a handshake, not a broadcast.** A 9 MB course pack is twenty seconds on one link and
half a second on another, so a race that began when the admin's hill was ready would be a race two
people had already lost. Everyone loads, everyone reports ready (`RaceNetwork.report_ready`), the
server waits for the last of them and then sends one `cli_race_go`; each client runs a
three-second `3 · 2 · 1` off it. There is no start animation in a network race — `CIntro` is four
and a half seconds on your own clock and four and a half seconds of disagreement on eight.

**The race is over when the last racer crosses the line.** This is the rule the whole feature
turns on and it is asserted directly in `tests/test_lobby.gd`. Your own finish is reported and
nothing else happens: the hill keeps running, your penguin decelerates to a stop, and the camera
hands itself to whoever is still coming down — `RacerRoster.view_target`, which the roster's own
doc comment has said was for exactly this since the day it was written, and which the chase
camera, the terrain streaming window, the GPU deformation window and the ice mirror all already
read. The HUD says how many are left. When the last one is in, every client gets the same
finishing order and the results screen shows it — the *server's* order, eight reported times,
rather than this machine's standings, which are eight interpolated positions and a different
question.

**Only the winner is shown the finish-line clip.** A solo race plays `wonrace`/`lostrace`/`finish`
to whoever ran it, which is what `CGameOver` does; a network race plays it to first place and
nobody else. Seven people watching four seconds of `lostrace` are watching it *over* the one thing
they were waiting for — the server's finishing order, on the panel above the penguin — and the
clip reads as the last thing that happens rather than as the answer. Everyone else's penguin stays
where it came to rest, which is where it was a moment earlier anyway. The outcome is still worked
out for every client, because the results screen's music sting is chosen by it: a loss still sounds
like one. `RaceScene._on_network_race_over`.

Two things stop a race hanging on somebody who has stopped playing: a disconnect ends that racer's
race in the tick the transport notices it, and Esc is a forfeit (`RaceNetwork.forfeit`) rather than
a pause. The backstop nobody racing will ever meet is `ABANDON_AFTER_MSEC`, five minutes after the
first finisher, for a window left open on an empty desk.

**Everything on the hill is the machinery that was already there.** A peer is a `PlaybackRacer`
fed from `RacerStateStream`, which is the ghost's class; a network race is `RaceSetup.networked`,
which is one more field on the object Practice and *Race the computer* already travel on; the
start line is `RaceSetup.lane_offset` of the racer's seat in the room's member list, which is the
same list in the same order on every machine so no two peers claim a lane. Nothing in the
presentation branches on any of it.

Verified end to end with a real server and two real clients: a room created with a password, the
wrong one refused and the right one accepted, both clients loading Bunny Hill, the countdown, the
snapshot stream in both directions, the host finishing at 46.38 s with the race *not* over, the
camera spectating the guest down the rest of the hill, and the race ending at 62.83 s when the
guest crossed — with the results screen carrying the server's order and the local penguin standing
up out of the racing pose in front of it. The server's log for that run:

```
[lobby] host opened "Test" on bunny_hill
[lobby] guest joined "Test" (2/8)
[lobby] "Test" starts bunny_hill with 2 racers
[lobby] "Test" is over — host 46.38s, guest 62.83s
```

And verified in a browser, which is the half the old transport could never have: the `Web` export
served over HTTP **by this same server process**, loaded in headless Chromium through
`tools/webtest/run_web_test.js`, reading `?lobby`, resolving the address off `location.hostname`,
and opening the session — `LOBBY_CONNECTED as peer 1094304107`, with the lobby drawn and the
`Build configuration: … multi-threaded` line proving the COOP/COEP headers took. That marker is in
`RaceNetwork._on_connected` for the same reason `RACE_READY` is in `RaceScene.restart`: it is the
one line that says the socket is genuinely up rather than merely asked for.

What it is not: there is no chat, no spectator-only seat, no reconnect into a race in progress (a
room that has started cannot be joined), no cups, and no rate limiting or account of any kind on
the server — it is a server you run for people you know, on a LAN or behind a proxy, not a public
one. The transport is TCP, so a lost snapshot delays the ones behind it; at 20 packets a second of
72 bytes that has not been worth a second transport, and `RacerStateStream` interpolates through a
late snapshot exactly as it does through a missing one. WebRTC would buy the unreliable channel
back for the price of a signalling server and a second code path at both ends.

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
The snow one is built. (The light one followed on 2026-09-23 — see below.)

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

**Update, 2026-09-23: the follow fraction is gone.** The half-following snow read as an overlay
unrelated to the racer — at 80 km/h it came at you at two fifths of your speed, and each box moved
as one sheet. The flakes now hang in the world (the drift is the wind less the box's own move),
and the shader draws each one stretched along how far it moved against the camera over a 1/60 s
shutter, measured with last frame's view matrix so camera turns streak it too, dimmed by the
square root of the stretch. Each flake falls at its own speed around a real 1.1 m/s (ETR's size ×
5 flattened the parallax) and sways on its own phase; the wind is carried level; flakes fade at the
box faces and near the lens. Still deterministic. The curtains are unchanged and still orbit the
player — the next thing to replace if the far snow reads as an overlay too.

**Update, same day: the curtains are gone too.** A ring centred on the player moves with the
player, so the far snow had no parallax and never loomed as you rode into it. It is now a fourth
flake area through the same world-anchored shader: a box 150 m square about the player holding
2150–2300 quads 5–6.5 m wide, each a random 128² patch cut from the grade's curtain tile (the redrawn
`snow1/2/3.png`, unchanged), faded in 25–35 m from the camera and out 60–72 m. Per square metre
that is the curtains' speck density and speck size; captured against the rings at grades 1 and 3,
day and night, it matches, and it now also covers the view back up the hill in the start
animation, which the rings (±100° about the fall line) left empty. Still deterministic, and no
per-frame CPU work beyond the uniforms — the 135 curtain transforms a frame are gone.
The largest flakes were then trimmed by a fifth — the outer near box tops out at 0.15 / 0.18 /
0.28 m instead of ETR's 0.18 / 0.22 / 0.35, and the far patches at 6.5 m instead of 8 (with more
of them) — because world-anchored, the top of both ranges read as blobs.

**Update, 2026-09-25: one flake size everywhere.** Trimming the outer flakes did not fix the
blobs, because size was never the fault — the pairing was. On screen a flake's size and its speed
both go as one over its distance, so their ratio is fixed per flake and says nothing about depth.
ETR's outer flakes were ten times the near ones in the world, so on screen they were as big as the
near flakes and ten times slower: large round discs drifting while small ones rushed past, which
no real snowfall does. Every box now holds the near box's sizes (1.5–5 cm by grade), the middle
and far boxes hold 2× and 4× the near count because each covers so much less of the screen, and a
flake that would fall below 1.5 px is drawn at 1.5 px with its alpha cut by the area it gained
(`MIN_PIXELS` in the shader), so it neither flickers nor adds coverage. The curtain tiles had the
same flaw one layer out — specks up to 22 texels are half-metre flakes at 30–70 m — so they are
now 1000 / 3000 / 10500 specks of 0.8–1.6 texels radius, which keeps the originals' coverage
(about 1.5 / 4.5 / 14.6 %, simulated; `TestSnowFall` holds it) and turns the far snow from drifting discs into grain.

**Same day: the near flakes are clumps, not discs.** With the size fixed, a close flake was still
a perfect soft circle — ETR's spray puff, which is fine on a particle that lives a second and
reads as a dot on one drifting past the lens. The flakes now draw `SnowFall.make_flake_image`: 16
cells, each grown like an aggregate (a seed lobe and 6–12 smaller ones, each fused onto the rim
of one already placed), and the shader turns each one at its own rate and wobbles it edge-on, so
no two flakes on screen share an outline for long. The spray keeps its puffs. `TestSnowFall`
asserts the clumps stay inside `FLAKE_REACH` and that none covers as much as the disc it reaches.

**Update, 2026-09-30: no white bursts at the lens.** A flake passing the camera flashed a white
haze over a sizeable part of the frame. The near fade read only the streak's head, and the tail is
clamped 5 cm in front of the lens so its projection cannot flip — so a flake beside or behind the
lens, with its tail across it, was drawn as a 5 cm quad at 5 cm: half the frame at full alpha. A
camera jerked round by a crash does that to a whole box at once (Bunny Hill, grade 3, `paddle`:
frames 428–433 hazed, the tree on the left washed out). The near fade now reads the streak's
closest approach to the lens, with both ends required in front of it, and runs 1–2 m rather than
0.25–0.9 m, so a flake no longer whizzes past as a 30–70 px blob either; a faded-out quad collapses
to nothing rather than filling the frame at alpha 0. `LensSnow`'s flakes melting on the lens are
the one deliberate snow on the camera and are unchanged.

Chosen on the course screen, in Practice and in a race alike — ETR puts it there too — and
remembered as `[game] snowfall` in `penguinracer.cfg`. `--snow=0..3` and `?snow=` name a grade for
one run without going through the menu, which is how the captures above were taken. It is
**presentation and nothing else**: no racer drives differently in it, which is the original's
arrangement as well. The tint is the environment's `[partcol]`, the same field the spray is
tinted by, so night snow is blue without anything in the effect knowing which sky it is
under — which is exactly what happened when the sky became a choice.

The art is redrawn rather than copied, like the spray's puff atlas and for the same reason: the
flakes borrow `SprayEmitter.make_puff_image` (ETR binds the same `SNOW_PART` atlas for both), and
the curtain tiles are generated to the originals' measured density — 251, 882 and 2184 specks
over a 512² tile, covering 1.5 %, 4.6 % and 14.7 %. The deviations that ride with the port are in
the trap list under AGENTS.md's deviations.

Verified on both renderers: Mobile on the desktop and Compatibility, which is what the browser
runs — the `MultiMesh`, the custom instance data and the vertex-stage billboard are all inside
WebGL2's floor.

4665 assertions, 0 failures.

**Snow on the lens (2026-09-29).** While it snows, the odd flake now lands on the camera, sits
there out of focus and melts away (`scripts/render/lens_snow.gd`, `LensSnow`, a `CanvasLayer` under
the HUD). ETR has nothing like it, and it is the one piece of snow that is deliberately *on* the
camera, so it is kept small: at most 2 / 4 / 6 flakes on the lens at once for grades 1 / 2 / 3,
landing 0.35 / 0.8 / 1.5 a second at 20 m/s, each staying 0.8–2.8 s with the last 45 % a melt
(fainter, shrinking to 75 %). The rate follows the camera's speed into the air along the way it
faces (`LensSnow.landing_factor`): a tenth of it standing still, up to 1.5× — so the intro and a
stopped spectator see almost none. A flake lands only where its whole disc clears an ellipse
round the penguin (centre 0.5 / 0.54, half-extents 0.30 × 0.34 of the canvas), so it is only ever
seen in the band round the edges. It is not white paint: `shaders/lens_snow.gdshader` blurs the
frame behind each blob (24 taps over 3 % of the canvas height) and lifts it toward `[partcol]`, so
it reads as a defocused frosted patch over sunlit snow and a hazy disc at night. The blob outlines
are generated (`LensSnow.make_blob_image`). Deterministic from a seed and reset on every restart.

Trap found on the way: in a `canvas_item` fragment `COLOR` already has the texture multiplied in,
so reading the modulate's alpha there squared the mask and let the sharp scene through the blur.
The shader carries the vertex colour across in a varying.

**Verified**: `TestLensSnow` (middle stays clear at 16:9, 4:3 and 9:16; more per grade and under
each cap; speed; melt; determinism; the atlas) and the suite — 6330 passed, 1 failed, the
pre-existing `lighting/what project.godot ships`. Captured `wild_mountains` at grades 1 and 3,
sunny and night, under Mobile and Compatibility (same frame in both). **Not done**: a phone.

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

### The sky is a choice now (2026-09-23) · **done**

The second of ETR's three weather controls. `CRaceSelect` offers light, snow and wind beside its
course list; the snow has been on the course screen since 2026-09-14 and the light is now beside
it, as a **Conditions** spinner offering three of the original's four times of day — sunny,
cloudy and night.

**A course names a place, not a time of day.** `courses.lst` carries `[env] etr` or
`[env] tuxracer`, which is a *location* with a `light.lst` and a three-faced skybox authored under
it for each light; the original picks the light per race, out of `events.lst` for a cup. So the
importer keeps selecting `<location>_sunny` for a course and `LightCondition.preset_for` swaps in
the sibling the race asked for. It is carried on `RaceSetup` beside the snowfall, remembered as
`[game] conditions`, reachable as `--light=`/`?light=` for a capture, and carried on a lobby room
so that eight people in a room are racing the same hill under the same sky.

Everything downstream of the preset already re-reads it, because changing the course always could:
the sun's colour and direction, the ambient the terrain clamps its sun against, the fog colour and
range, the skybox, the `[partcol]` the flakes and the spray are tinted by, the horizon band the ice
reflects — and whether anything casts a shadow at all, which is not a quality setting but
`CCharShape::DrawShadow` returning immediately under `light_id` 1 and 3. Under cloudy and night
nothing on the hill casts one, in both games. Picking a new sky over a running race re-lights it in
place (`RaceScene._apply_conditions`) rather than rebuilding the course.

#### The part that was actually blocking this

The gate was never the menu. It was that **all eight presets shared one pair of gains** — the
`sun_gain`/`ambient_gain` fitted on `tuxracer_sunny` against a reference capture (history §11,
§22), sitting on the script as the default — and on a dark sky that pair is wrong in a way §22
had already measured and recorded: night's shaded snow came out at about 105/255 against the
original's 47. Offering the sky would have shipped a course that is visibly wrong.

The reason is worth stating in one line, because it is the same class of bug as the two before it.
A shaded fragment renders at `srgb(ambient_color * ambient_gain)`, so sharing the *gain* shares the
correction in **linear** space — and undoing an sRGB decode raises a dark value far more than a
bright one. What the fit actually says is a **display-space** claim: *this bank wants about a tenth
more light than `[amb]` alone*. `EnvironmentPreset.fit_correction()` recovers that tenth from the
fitted pair — (1.128, 1.097, 0.991) — and `derive_ambient_gain` applies it to any `[amb]`, in the
space ETR's arithmetic lives in. `derive_sun_gain` is the derivation `sun_gain` has always
documented, generalised to a sky too dark to reach the clamp: where ETR's snow saturates at
`N·L = (1 − amb) / diff`, our sun is scaled to saturate at the same angle; where it never
saturates — night's red stops at 0.59 — it is matched at full `N·L` instead. The two cases meet
continuously at an angle of 1. The importer writes both onto the resource, so a preset is still
readable on sight and re-importable.

Two things say the derivation is the documented rule and not a second guess at it. The fitted
ambient pair is its **fixed point**: handed the surface the fit was measured on it returns the
fitted gain exactly, by construction. And the sun half, run on `tuxracer_sunny`, returns **1.948**
in red where the fit carries 1.95 — the channel the derivation was written for, to a tenth of a per
cent. (It returns 1.87 in green, which §22 already recorded as within 5 %, and 0.46 in blue, where
both games are clipped on the ambient alone and the difference lives below `N·L` 0.05.) The two
sunny presets keep the measured pair regardless: every tone measurement in the repository is on one
of them, and nothing in this change moves either file by a byte.

#### What it measures

Snow (`snow.png`, 236/245/255) under each sky, as the arithmetic gives it — ours against what ETR's
own `clamp([amb] + [diff]·N·L)` produces:

| preset | shaded, ours | shaded, ETR | lit, ours | lit, ETR |
|---|---|---|---|---|
| `*_sunny` | 187, 210, 253 | 153, 179, 242 | 236, 245, 255 | 236, 245, 255 |
| `*_cloudy` | 157, 161, 162 | 139, 147, 163 | 236, 245, 255 | 236, 245, 255 |
| `*_night` | 53, 78, 136 | 47, 71, 138 | 139, 196, 255 | 139, 196, 255 |

The lit end is exact everywhere. The shaded end is ETR's own number times the measured correction
— which is what the correction is for, and why sunny's row is the widest gap in the table rather
than an error in it.

And on a real frame, 250 frames into Bunny Hill under `tuxracer_night`, near-field region mean:

| | before (shared sunny gains) | after |
|---|---|---|
| R | 139.7 | **78.4** |
| G | 171.7 | **113.0** |
| B | 237.5, 11.8 % clipped | **209.4, 1.0 %** |

`TestEnvironments` now asserts both ends of that arithmetic on all eight presets rather than only
the round trip — the assertion that was missing when one pair of gains was shared, since a wrong
gain passes a round trip perfectly — plus the fixed point, the `LightCondition` lookup, and that
`SNOW_WRAP` still matches `terrain.gdshader`'s `wrap_amount`, which the sun derivation reads the
clamp angle through.

4951 assertions, 0 failures.

### The far slope stopped smearing (2026-09-23) · **done**

The terrain samplers were already `filter_linear_mipmap_anisotropic` (history §7), but a sampler
hint only switches anisotropy on; the *level* is the project setting
`rendering/textures/default_filters/anisotropic_filtering_level`, which was unset — Godot's 4x.
A downhill camera reads most of the frame at a grazing angle, which is exactly where 4x runs out.
It is now 16x on both renderers. On the web, Godot's GLES3 driver enables it whenever the browser
offers `EXT_texture_filter_anisotropic` and caps it at the setting, so the same line reaches WebGL2.

Bunny Hill, `carve`, 250 frames, 1280x720, mean absolute error per 120-pixel band, top to bottom:

| | 0–120 | 120–240 | 240–360 | 360–480 | 480–600 | 600–720 |
|---|---|---|---|---|---|---|
| Compatibility, 4x → 16x | 0.1 | 13.6 | 44.7 | 14.1 | 0.1 | 0.0 |
| Compatibility, off → 4x | 2.3 | 72.6 | 182.4 | 108.8 | 18.0 | 0.1 |
| Mobile, 4x → 16x | 0.2 | 17.5 | 55.9 | 39.1 | 0.2 | 0.0 |

The change lives entirely in the middle and far slope; the near field and the sky do not move,
and an unset setting reproduces an explicit 4x (the 360–480 band excepted — the spray). Held
at trilinear on purpose: `sparkle_noise`, whose mip chain *is* the fade that stops the glints
aliasing, and `detail_map`, which fades its octaves explicitly with distance anyway.
Not yet looked at in a browser.

### Bare trees became trees (2026-09-24) · **done**

The leafless tree (`tree_barren`, `tree_barren2`: 1583 of them on `bronze_set`, 172 on Bunny Hill)
was still ETR's 239×245 picture on two crossed quads — a staircase of magnified texels within a
few metres, a flat card from the side, a grey smudge beyond. It now goes through `Forest` like the
conifer, as `BareTreeMesh`: a grown skeleton (1 trunk, 7 limbs, 28 + 84 branches) drawn as
tapered tubes, with twig cards at the finest branches. Triangles per level: 2070 / 1072 / 340
(the conifer's are 386 / 84 / 38), then the octahedral impostor.

Things that did not work first time, each now in the trap list: the twigs vanished a few metres
out (mip-averaged alpha under the scissor → `alpha_mip_boost`); boosted too hard, and with the
card normals pointing up, the crown read as white broccoli; baked from LOD 0 the impostor was a
dark blob replacing an airy tree (→ baked from LOD 2); boosting the bake's alpha put a solid cap
on it; and the finest limbs' radius codes rounded to 0 in the 8-bit vertex colour.

Frame rate, 1280x720, Mobile, the container's integrated Radeon, vsync off, `paddle`, 1500
frames: `bronze_set` 228–277 FPS before and 238–277 after (no measurable change); Bunny Hill,
whose bare trees are the largest (up to 8 m) and stand by the track, 278–301 before and 201–262
after. Looked at under both renderers and at snowfall 3; not yet in a browser. The impostor is a
little sparser at its edges than LOD 2 at the 75 m hand-over, inside the fog.

---

### The wind is a choice now (2026-09-24) · **done**

The third of ETR's weather controls, on the course screen beside the other two as a **Wind**
spinner: none, light or strong. It is not ETR's `wind_id`. ETR's grades blow from wherever their
tables allow and go through the air drag everywhere (`WIND_FACTOR` × 30–100 units of crosswind),
which makes a hard course of an easy one; they stay reachable as `--wind=1..3`, unchanged.

**A crosswind, from one side.** `WindField.init_crosswind` runs the same `CWind` state machine on
tables of its own: within 15° of square to the fall line, on a side the seed picks — from the left
or from the right — with gusts (light 6–26 units, never over 35; strong 25–70, gusting to 85). The
side is rolled on every start. Every racer carries a field on the same seed, so the whole field
feels the same gusts; a network race uses a seed the server rolls at Start
(`LobbyServer.Room.wind_seed`, sent with `cli_race_starting`), and a scripted or captured run pins
it to 0 (`--wind-seed=` overrides) so captures still reproduce.

**What it moves.** The trees: `wind_strength` is `speed / 100`, and the sway coefficients were
raised so that a strong wind reads — a steady lean downwind (`lean_per_wind` 0.06), a wider sway
(0.05) and a quicker flutter on top (`flutter_per_wind`) that a still day does not have. The snow:
flakes near and far drift with `WIND_DRIFT` × the wind, as they already did for `--wind=`. The HUD's
wind rose, which until now nobody could see. And **the racer, only in the air**: a level push of
`FLIGHT_ACCEL_PER_SPEED` (0.04 m/s² per unit) along the wind while airborne, nothing on the
ground (`RacePhysics.calc_flight_wind_force`, marked DEVIATION). The drag stays ETR's still-air
drag. A 0.9 s jump lands about 0.5 m downwind in a light wind and 1.5–2.4 m in a strong one, and
the heading follows the velocity, so the penguin comes down pointed slightly downwind. Straight
down Bunny Hill with no steering never leaves the ground and runs identical to a calm one.

Carried like the sky: `RaceSetup.wind` (+ `wind_seed`), `[game] wind` in `penguinracer.cfg`,
`--crosswind=`/`?crosswind=` for one run, `SHOT_WIND=` in `tools/shot.sh`, a lobby room's `wind`.
A recording notes the strength and seed it was raced in (`RaceRecording.wind`/`wind_seed`, 0 on
every older file = calm) and the flight constant is in the physics signature. `TestWind`: the
strengths' ranges, both sides across seeds and each staying on its own, one seed one weather,
bit-identical ground runs, the flight drift's bounds, the setup/lobby round trip.

### Gullies are shaded and shaded snow is blue (2026-09-24) · **done**

Two terms ETR does not have, both in `terrain.gdshader`'s ambient, both marked DEVIATION.

**Ambient occlusion baked from the heightmap.** `TerrainOcclusion.bake` marches eight azimuths out
to 14 m from every other heightmap vertex (the source grid; ~2.6 s for `the_long_ride`, 3½ min for a
full import) and keeps each horizon's sin² — the sky a cosine-weighted floor loses behind it —
fading far occluders. Against the local relief, not the world, so the analytic base slope occludes
nothing. The importer writes it next to the heightmap as `ambient_occlusion.res` (FORMAT_L8,
compressed, 9.2 MB for all 44) and `CourseData.ambient_occlusion` points at it. `TerrainRenderer`
hands it to the shader as **vertex colour**, not a texture — 13 of WebGL2's 16 units are taken, and
it lives on exactly the chunk grid. It takes the ambient (`terrain_ao_strength`) and 35 % of it the
sun (`terrain_ao_sun`, since the web has no shadow map and a clamped sunlit floor would otherwise
show nothing). The trench gets the same horizon measure at fragment rate from four trail-map taps
22 cm out (`trench_wall_ao`), which puts its shade at the foot of the wall under the lip rather than
evenly over the floor. A course imported before this has no colour array and draws unoccluded.

**Fake subsurface scattering on snow.** The ambient filter in `etr_illumination` is now per channel
(`vec3 occlusion`; every other shader passes grey). Snow multiplies it by `snow_scatter_tint`
(0.72, 0.89, 1.0 — red absorbed first, blue kept, since the ambient's blue sits at the clamp) by
the largest of: how far its shadowed, shaped N·L has fallen under `snow_scatter_band` (0.35), its
relief + trench occlusion (× 3), its carve depth (× 0.8). Inside the clamp, so a lit slope on the
ceiling does not move. Measured, Mobile, 1280x720, against the same frames with every new term 0:

| Region | before | after |
|---|---|---|
| Bumpy Ride, open lit snow | 234/244/255 | 233/244/255 |
| Bumpy Ride, tree shadow | 188/211/253 | 160/195/245 |
| Bumpy Ride, carve | 187/208/248 | 158/189/236 |
| Penguins Can't Fly, shaded half-pipe wall | 142/160/194 | 124/140/170 |
| Penguins Can't Fly, lit ice | 132/146/163 | 132/146/163 |

Compatibility moves the same way (Bunny Hill, 3.9 % of the frame by more than two levels vs 5.3 %).
`TestOcclusion`: flat and crest open, a V gully darker down its wall, the foot of a bank darker than
its top, every course's image on its heightmap's grid. All the new uniforms at 0 are the old frame.

### The sky is drawn, and the air has depth (2026-09-24) · **done**

ETR's sky is three photographs on three flat quads and its air is a flat linear fog of `[fogcol]` —
white on 40 of the 44 courses. Both are replaced by default, and both come back with
`[display] sky = "etr"` (`--sky=etr`, `?sky=etr`, `SHOT_SKY=etr`). All of it is a DEVIATION.

**One include, `shaders/atmosphere.gdshaderinc`, read by the sky and by every lit surface**, driven
by global uniforms (`[shader_globals]` in `project.godot`) that `Atmosphere` fills from the preset
and the course. It holds the sky's gradient and sun glow, the distant ridges, and a fog function
each lit shader writes to `FOG` — so the colour a far slope fades to is by construction whatever
the sky draws behind it.

- **Procedural sky** (`procedural_sky.gdshader`): the gradient is the migrated faces' own averages
  (`sky_zenith_color` and siblings), turned toward a clear sky's hue at their own brightness by a
  per-light `blue` (0.85 sunny, 0.5 night, 0 cloudy) and a sunny `zenith_lift` of 1.8, because
  those averages are half mountain and drawn as they are the sky is grey-lavender. A saturation
  boost was tried first and cannot get there: the averages have almost no hue to boost. A sun disc and halo at the light's direction, a horizon band, two
  cloud decks of value noise sheared against each other and drifting downwind of the crosswind
  (accumulated, so a gust turns them rather than teleporting them). Per light (`Atmosphere.LOOKS`):
  cover 0.3 sunny, 0.93 cloudy with the disc all but gone. At night: stars (hash cells, at least a
  pixel wide, twinkling, a Milky Way band), a moon with a phase and maria, and an aurora — curtains
  stacked on a plane ahead of the racer.
- **The moon is not where the light is.** ETR's night light is `[pos] 1 1 1`, behind and above a
  racer heading down −Z; a chase camera looking down a 25° slope sees at most a few degrees above
  the horizon, so the moon stands 9° up, ahead and to the right (`Atmosphere.MOON_DIRECTION`).
  Nothing casts a shadow at night, which is what makes the two impossible to tell apart on snow.
- **Distant ridges**: three layers of ridged noise round the horizon, seeded per course, back to
  front, each hazed by distance, snow on the faces that turn upward, forest on the lower flanks,
  mist pooled at each foot. **Why not meshes:** the race keeps ETR's 40–150 m fog, so terrain is
  fogged out completely long before the horizon, and a fully fogged slope has to turn into *some*
  colour. With a mesh backdrop behind it that colour is a flat shape cut out of the mountains; with
  the ridges as a function of direction the fog function can ask what is behind the slope. The
  near ranges reach well below the horizon — a chase camera on a steep course looks *down* the
  valley, and on Bunny Hill the whole "sky" in shot is below 0° — and they sink by the camera's
  height above the valley floor over 4 km (capped at 0.07, about 4°).
- **Dipped horizon** (`atmo_dip`, `Atmosphere.horizon_dip`): the first cut put the ridges on the true
  horizon, up to ~15° tall. A chase camera at its 40° pitch clamp sees nothing above −5°, so on
  Bumpy Ride they filled all of the backdrop, with grey valley mist between the layers, and no sky
  showed at all. That lost the sunny feel ETR's photographs had. Now sky, sun, clouds and ridges
  are all drawn about a horizon lowered by 0.7 × the course's `base_angle` (capped at 30°). The
  ridges are about half as tall and tighter (feet at −0.02/−0.06/−0.10, height 0.15 − 0.025·layer),
  so they rise off the far end of the course with open sky above them. The fog samples the
  backdrop through the same `atmo_backdrop_dir`, so a far slope still fades into exactly what is
  behind it. The sky only fades to its ground colour from 0.2 under the dipped horizon; fading
  from 0 drew the dip as a grey arc. What is left is a faint curved brightening where the horizon
  haze band follows the dipped horizon, which projects as a curve.
- **Aerial perspective**: the fog colour is the clear sky along the horizon in the view direction,
  glow round the sun included, and as depth fog reaches 1 it becomes the ridges and sky behind.
- **Height fog**: exponential mist, integrated along the ray in closed form, based 4 m below the
  course's lowest point with a 16 m falloff (`MIST_*`), so the top of a descent looks down into it
  and the finish sits in its thin upper edge. It starts at the fog's clear distance. Per light
  (`LOOKS.mist`): light on the clear skies — 0.35 of `MIST_DENSITY` sunny, 0.3 night, 1.6
  overcast — because mist greys whatever it lies over and a clear day reads by its colour. The same
  number thins the mist at the ridges' feet (`atmo_valley_mist`), and `ridge_haze` (0.55 sunny,
  1.0 overcast) how far the ridges fade into the horizon's colour.
- **Night lights** (`CourseLights`, `[display] night_lights`): a lantern on every flag and a torch
  every 22 m down both long edges of the play area, 1.2 m outside it and clear of trees. Flames are
  additive camera-facing quads (`torch_flame.gdshader`) dimmed by the atmosphere's fog amount. The
  light is the eight nearest to the camera, in eight more globals, summed by `atmo_torch_glow`
  **inside** ETR's illumination clamp in every lit shader — a torch is one more light in the
  fixed-function sum. No `OmniLight3D`: a second engine light would run every lit shader's
  `light()` again and add the ambient twice. The racers are not torch-lit.

**Measured**, Bunny Hill, 1280x720:

| | |
|---|---|
| `--sky=etr` against the pre-atmosphere frame, Mobile | mean 0.04 levels, 0.1 % of pixels over 8 (the spray) |
| ... Compatibility | mean 0.02 levels, 0.1 % over 8 |
| procedural, lower half of frame (near field) vs `--sky=etr` | mean 0.02 levels — the fitted near field does not move |
| Mobile vs Compatibility, procedural | mean 5.1, 21 % over 8 — the same as the two renderers already differed (5.2, 21 %) |
| frame cost, 1500 frames at night, Renoir iGPU | +0.7 ms Mobile, +0.5 ms Compatibility |
| cold shader compile | +0.3 s Mobile, +0.8 s Compatibility |

Two things found on the way, both in the trap list: **Compatibility's sky pass does not encode its
output** (the migrated skybox never showed it, because its `source_color` faces are not decoded
there either), so the sky encodes for itself under `#if CURRENT_RENDERER == RENDERER_COMPATIBILITY`;
and **a written `FOG` is blended identically by both renderers**, linear, which is what lets the
`etr` switch reproduce the engine's fog to the level. `TestAtmosphere` holds the rest: every global
the include reads is declared, every lit shader writes `FOG` and clamps the torchlight, `sky = etr`
asks for exactly `[fogcol]` with no mist or ridges, torches stand outside the play area, clear of
trees, on the snow, in the same places every run.

Not done: the evening preset (not offered) comes out sepia, because its photo averages are brown;
the ice still reflects the migrated sky averages, not the bluer procedural ones (its tone was fitted
against those); nothing has been checked in a real browser, only under desktop Compatibility.

## Known gaps

- **Rock faces: one so far.** Mountain Forest has one (140–198 m, right bank), now trimmed,
  compressed, with levels and with the ground under it cut out of the terrain (below). What is
  left of its cost in a view it fills is shading the rock itself (~0.4 ms; its surface is larger
  than the ground it hides) and its shadow (~0.14 ms). The other ~16 rock stretches are a
  `CLIFFS` entry each — but look at every one from the chase camera first, and at the slots,
  where the camera rides close to the walls.
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
- **The snow is tuned against one frame of one course, and the other six skies are derived from
  it rather than measured.** Bunny Hill under `tuxracer_sunny` matches the original at both ends
  of its range and in all three channels (history §11, §12, §22), but the fit is six numbers
  solved on two surfaces in one screenshot. It does reach every shipped course: all 44 select a
  *sunny* preset — 40 `etr_sunny`, 4 `tuxracer_sunny` — and the two carry identical `[diff]` and
  `[amb]`, differing only in the skybox (the `etr` faces are 1024² and much brighter) and the fog
  colour. Since `ambient_light_sky_contribution` is 0 the brighter sky does not feed the ambient,
  so the fit should carry; nobody has measured it on an `etr_sunny` course against a reference.
  The cloudy/evening/night presets now carry gains of their own, derived from that one fit in
  display space (history §25) instead of sharing it in linear space, which is what put night's
  shaded snow at 105/255 against the original's 47. **Derived is not measured.** The correction
  being transferred was fitted on a bank that was shaded but not unlit, and how much sun a shaded
  bank gets is a property of the sky it is under, so the six carry that approximation. Each would
  still be better for one reference capture of its own — same method, one frame each.
- **The camera does not frame the course the way the original does.** `race.tscn` uses a 70°
  vertical FOV where `param.fov` is 60, and `ChaseCamera` sits 19° above the slope plane where
  `view.cpp` puts it at `CAMERA_ANGLE_ABOVE_SLOPE`/`PLAYER_ANGLE_IN_CAMERA` = 10°. Both are
  one-line changes; together they are why a side-by-side still looks different after the shading
  matches — ours shows a third less sky. Left alone because it changes how the game plays, not
  how it looks, and that is a design call rather than a fidelity one.
- **The game shell stops at free course selection** (Phase 5): no cup progression, medals or save
  profiles. The migrated event thresholds are sitting there ready; the translations are wired up.
  The settings screen moves the keys a player can act on, including the language, but not the
  two ETR's own configuration screen also has — sound volume and music volume. The two multiplayer
  keys a player edits (`player_name` and `server`) are on the **Network multiplayer** screen
  instead, where they are what is being asked for; `port` is file-only. The screens carry the original's
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
- **A race that has started cannot be rejoined, and there is no spectator seat.** The two gaps
  left in multiplayer after the lobby, the countdown, the finishing-order screen and the browser
  arrived (see **Network multiplayer** above). A dropped connection is a forfeit; a room closes to
  newcomers the moment the admin presses Start; and there is no way to watch a race you are not
  in, even though the machinery for it is sitting there — a spectator is a client that publishes
  nothing and points `RacerRoster.view_target` at somebody else, which is exactly what a finished
  racer already does.
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
- **The server has no account of anybody and no rate limiting.** It is a server you run for
  people you know — a LAN, or a host behind a reverse proxy — not a public one. A peer can open
  rooms until it hits `MAX_ROOMS`, rename itself every frame, or send snapshots faster than the
  20 Hz the client does; nothing counts any of it. The two things that *are* checked are the two
  that would corrupt somebody else's frame rather than merely annoy: a snapshot is validated
  before it is relayed (`RacerState.is_valid_packet`), and a password digest is compared before a
  room is entered. Closing the rest is a different kind of work from a game and wants a real
  decision about what this server is for.
- **A race in progress cannot be rejoined.** A dropped connection is a forfeit and the room is
  closed to newcomers from the moment the admin presses Start, so a player whose wifi blinks is
  out until the next race. `PlaybackRacer` already handles a peer whose clock is a minute ahead
  (`CLOCK_SNAP`) and `LobbyServer` would need to let a known peer back into a `RACING` room and
  re-send it the course; the reason it does not is that the rejoining client would restart its own
  simulation at the start line, which is a race nobody else can see them in.
- **Asset licence audit not started** (risk S5). Independent of engineering, long lead time,
  blocks Phase 5.
- **Two terrain layers import with no albedo**, because `terrains.lst` names a texture that is
  not in the tree: `pave04` wants a `pave04.png` nobody shipped and `snowy_hockey_ice` writes
  `snowy_ice02` without the extension. Untextured in the original too, and no shipped course
  paints either colour key, so this is a note rather than a bug — the importer warns.
- **One of ETR's four skies is not offered, and ETR's own wind grades are not either.** The
  course screen has all three weather controls (`[game] snowfall`, `conditions`, `wind`), but its
  wind is a crosswind of its own; ETR's `events.lst` grades, which push through the drag
  everywhere, are only `--wind=`, waiting on cups. The fourth sky, **evening**, is imported and carries a derived gain
  like the other two, and is reachable from the Inspector; it is simply not on the screen, because
  three were asked for. Adding it is one entry in `LightCondition.NAMES` and one in `LABELS`.
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

---

### Trees stopped morphing in front of the racer (2026-09-24) · **done**

The forest's level hand-overs (`Forest.LOD_ENDS`) were at 22 / 45 / 75 m. A hand-over there is a
visible change of shape — LOD 0 → 1 drops two fins, four whorl tiers and the trunk — on a tree
still ~140 px tall a second or so ahead of the racer. They are now at **50 / 90 / 130 m**: a 6 m
tree is ~60 px at the first (720p, 70°), ~35 px and half fogged at the second, and the impostor
takes over where the 40–150 m fog has most of it. The 4 m dithered cross-fade is unchanged. The
bare-tree impostor was re-baked, since its limbs are widened to what LOD 2 draws at the last edge.

Frame rate, 1280x720, the container's integrated Radeon, vsync off, `paddle`, median of the
`--print-fps` readings over 1500 frames, before → after: Bunny Hill 91 → 91 (Mobile), 159 → 157
(Compatibility); `bronze_set` 103 → 98, 136 → 131. Within run-to-run noise to about 5 %. Not yet
looked at in a browser.

### The fog stopped drawing the mountains (2026-09-25) · **done**

The `visual_improvements` branch had halved the frame rate on Bunny Hill (224 → 112 FPS, Mobile,
1024x576 logical, vsync off, `paddle`, sunny). Bisected commit by commit, the largest single cost
was the atmosphere (+1.9 ms), and within it the fog: every lit shader's `atmo_fog_at` evaluated the
three ridge layers — ten octaves of noise each — behind every fragment past ~30 % fog, so that a
far slope fades into the skyline behind it. Deleting that lookup outright saved ~1 ms.

The ridges do not change during a race except for how far they have sunk (`atmo_ridges.w`). So
they are now worked out *before* the drop, and `RidgeMap` bakes them once per sky into
`atmo_ridge_map` — a 4096 × 1024 RGBA8 `SubViewport`, colour and coverage above (square-root
encoded, range 2), the haze's share below — which the fog reads in two texels. The haze colour
depends on the drop, so it stays out of the bake and is added at lookup. The sky still evaluates
the ridges itself, so its crests stay sharp at any resolution.

One visible change, on purpose: the rock-and-snow pattern on the ridges used to be computed from
the elevation *after* the drop, so as a racer descended and the ranges sank, the pattern slid over
them. It now sinks with them. Against HEAD that moves 0.2–1.4 % of the frame (the ridges only);
against the new maths evaluated analytically, the baked fog is within 17 levels at worst and a
mean of ≤ 0.002 on Bunny Hill, Bumpy Ride, `bronze_set` and the four steepest courses, sunny,
cloudy and night, both renderers.

The first cut kept the analytic ridges as a fallback (no map yet, or a direction below the map)
and saved only 0.25–0.45 ms: a branch never taken still costs the registers of its widest path.
Without it — no map means bare sky, below the map reads its bottom row — paired runs, before → after:

| | Mobile | Compatibility |
|---|---|---|
| Bunny Hill | 112 → 128 FPS (−1.1 ms) | 204 → 221 (−0.4 ms) |
| `bronze_set` | 123 → 140 (−1.0 ms) | 174 → 193 (−0.6 ms) |

Front-to-back compositing with an early out was tried first, alone: exact, but −0.1 ms. It stays,
in the layer loop both paths share. Not yet looked at in a browser; the map is 16 MB of VRAM there.

### Quality presets on the Configuration screen (2026-09-25) · **done**

The `visual_improvements` work made the frame too dear for a slow machine, and all of it was one
setting: on or off. The **Configuration** screen now has a quality preset — Fastest, Fast,
Medium, High quality, Best quality — over the knobs that move the frame time, each also its own
row and its own key (`[quality]` in `penguinracer.cfg`, besides the existing `render_scale`,
`ice_reflections`, `shadows` and `sky`):

- **Anti-aliasing** off / 2x / 4x (`Viewport.msaa_3d`; 2x is what `project.godot` always set).
- **Sky detail** low / medium / high. Compile-time variants of `procedural_sky.gdshader`
  (`ATMO_SKY_DETAIL`, defined by `Atmosphere.sky_shader`), not a uniform — a never-taken branch
  still costs. Fewer cloud octaves; low also reads the ridges from `RidgeMap`'s bake, as the fog
  does, a little softer at the crest.
- **Tree detail distance** 0.5–1.5 × `Forest.LOD_ENDS`. Below 1 the bare impostor takes over a
  little thicker than LOD 2 (it is baked for 130 m).
- **Tree shadows** off / near (LOD 0 only) / all.
- **Shadow detail** low (2048, 2 splits) / medium (2048, 4) / high (4096, 4, as shipped) / best
  (8192, 4).

The preset is derived, never stored (`QualityPreset.matching`; anything else reads "Custom").
**High quality is the defaults and the shipped frame**, so an untouched file moves no capture.
`--quality=<preset>` / `?quality=` runs one session at a preset.

One knob at a time against High, Mobile, the iGPU, 1024x576 logical, vsync off, `--fixed-fps 60`
(so every run draws the same 50 s of `paddle`), 3000 frames, median `--print-fps`, two runs; ms a
frame saved, Bunny Hill / `bronze_set`: 2048 atlas 1.1 / 0.6 (two splits as well 1.7 / 1.0), no tree
shadows 1.5 / 0.2, no MSAA 0.7 / 0.8, low sky 0.6 / 0.6, trees at 0.5× 0.4 / 0.2, LOD-0-only tree
shadows 0.25 / 0.2. Next to nothing: medium sky, 4096 in two splits, LOD 0+1 tree shadows (the
near trees in the fine cascades are the whole bill). Dearer: the 8192 atlas +3.9 / +1.9, 4x MSAA
+0.1 / +0.3, trees at 1.2× ~0. The presets, FPS:

| | Fastest | Fast | Medium | High | Best |
|---|---|---|---|---|---|
| Mobile, Bunny Hill | 458 | 267 | 171 | 129 | 82 |
| Mobile, `bronze_set` | 406 | 252 | 175 | 144 | 108 |
| Compatibility, Bunny Hill | 447 | 348 | 259 | 230 | 207 |
| Compatibility, `bronze_set` | 394 | 309 | 231 | 199 | 178 |

Compatibility draws no shadows, so its spread is narrower. Not yet looked at in a browser.

**Follow-up: the hand-overs are sized for the screen.** At Best in a 2560x1440 window a conifer
right ahead of the racer went grainy for a moment — the Bayer cross-fade of its 60 m hand-over.
`LOD_ENDS` were chosen as pixel sizes at 720p, and at 1440p the same tree is twice as tall.
`Forest.screen_scale_for` now scales every hand-over by the window's physical height / 720,
never below 1 (small windows and every capture at 1024x576 logical are unchanged) and capped at
2, and re-lays the bands if the window is resized mid-race; the screen's tree-detail label shows
the distances that result. Level-tinted captures confirm it (at 1440p the trees that were
handing over at 60 m draw LOD 0). Cost at 1440p, High, interleaved pairs: 47 → 46 FPS. A first
unpaired run said 44 → 63 — the iGPU's clock states, not the change.

Best no longer uses the 8192 shadow atlas: paired against 4096 at 1/5 speed it differs by a few
hundred pixels of 230 000 on any frame, and it cost 3.9 ms on Bunny Hill. The row keeps it.

About one run in six on this machine writes its capture and then never exits — HEAD before this
change too (1 of 6 on `bronze_set`), so the benchmark wraps each run in a `timeout`. Not chased.

### Phones: an Android build, and touch controls there and in a phone's browser (2026-09-27) · **done, not yet raced on hardware**

**Android.** A hand-maintained `Android` export preset (prebuilt template, no Gradle build,
arm64-v8a, `org.penguinracer.game`, immersive, landscape either way up, INTERNET for the lobby)
and `tools/build_android.sh [--release] [--install]`. The whole game is in the APK (137 MB) —
streaming is a browser concern. A phone runs the **Mobile** renderer, like the desktop: `project.godot`'s
`rendering_method.mobile = gl_compatibility` override is gone (a device without Vulkan still falls
back to Compatibility by itself, and `RenderBackend` then drops the shadows as on the web). A
phone's first run (Android or a phone's browser) writes the **Medium** preset instead of High; the desktop default and every capture are unchanged. The window
is not the settings file's to size on a phone (`GameConfig.owns_window`), and Android's back
button is Esc (`quit_on_go_back` off; `GameConfig._notification`) — it used to quit mid-race.

**Three schemes**, `[controls] touch` / a Configuration row shown only on a phone:
- **tilt** (default) — `TiltSteering`: roll steers (analogue, 2.5° deadzone, full lock at 22°,
  floored at 0.21 because `RacePhysics` ignores a stick under 0.2); tipping the top edge away
  paddles, back brakes, ±11° on / 7° off around a neutral taken over the first 0.35 s of each run
  (`LocalInputSource.reset` → `recenter`). Roll is measured against the horizontal, so it does
  not care how far back the phone is held. Jump and the trick modifier are buttons; a tilted
  phone also sets the digital left/right flags so a roll in the air still works.
- **buttons** — steer, paddle, brake, jump, trick, all on screen.
- **off**.
Restart (`r`), menu (Esc) and pause buttons, small and in one row along the top, in every scheme
but off; no pause or restart in a network race; while paused by `P` only the pause button stays,
to resume with. Restart is held like a key rather than tapped, because `RaceScene` polls `r` with
`is_action_just_pressed`, which a press and release in one frame never satisfies. The rest sit
under two thumbs of a phone held in both hands: left above jump (and the trick modifier, a star)
on the left edge, right at the same height on the right edge with paddle above and brake below.
The trick modifier used to be a circular arrow, which read as a restart that did nothing. If tilt was chosen and no reading ever
arrives (motion access refused, a desktop), the steering buttons come back.

**How it is wired.** `TouchControls` presses the existing actions (`Input.action_press`), so
`LocalInputSource`/`KeyHoldFilter` read a thumb exactly as they read a key, on the tick. Tilt is
not an action; `LocalInputSource.poll` reads `MotionSensor` once per tick and merges it (a key
held outranks it). `RacePhysics` is untouched. `MotionSensor` is where the platforms stop
differing: `Input.get_gravity()` natively (sensors are opt-in in 4.x:
`input_devices/sensors/enable_*`), and on the web a `devicemotion` listener injected through
`JavaScriptBridge`, because Godot 4's web platform does not feed the accelerometer. The browser's
reading is in the device's natural frame and signed as the reaction force, so
`MotionSensor.web_to_screen` turns it by `screen.orientation.angle` and flips it (not on iOS,
which reports gravity itself). The same injected script asks iOS for motion permission and
requests fullscreen + a landscape lock from its own `touchend` handler — a Godot input event is
dispatched off the gesture and would be refused. A phone's browser is `web_android`/`web_ios`
(`TouchScheme.platform_is_mobile`); `--touch[=tilt|buttons|off]` / `?touch` forces the overlay on
a desktop. The web preset now turns on Godot's virtual keyboard, for the lobby's name field.

**Layout** clears every HUD piece on 16:9, 19.5:9, 21:9 and 4:3 canvases (`TestTouch`, which also
covers the scheme matrix, the tilt geometry, the browser remap against Android's native
rotations, and the merge). The start hint reads `TAP TO START` under the overlay.

**Verified**: the suite; a render with `--touch=buttons` and `--touch=tilt` on the desktop; the
streamed web build in Chromium emulating an Android phone (`MOBILE=1` in
`tools/webtest/run_web_test.js`) — `web_android` picked tilt, and synthetic `devicemotion` events
(`MOBILE_TILT=x,y,z`) dropped the steering buttons and carved the penguin right. The APK exports,
signs and has the expected manifest. **Not verified**: a real phone — the tilt thresholds are
reasoned, not played, and Android's sign/rotation conventions are from the engine source, not a
device; iOS Safari's inverted sign is from its documented behaviour, also untested.

**Also fixed on the way**: `export_presets.cfg` held three copies of the 45 generated presets. The
Godot editor rewrites the file without its comments, so `gen_course_export_presets.py` lost its
markers and appended a fresh block each time. It now recognises its presets by name
(`Course_*`, `MusicPack`) wherever they are, and renumbers the hand-maintained ones (`Web`,
`WebSpike`, `Server`, `Android`) from 0.

**Still failing, not from this**: `lighting/what project.godot ships` wants
`rendering_method.web="gl_compatibility"`, which 78f80ca dropped (the editor omits a value equal to
its default, which this one is — the web still runs Compatibility).

### English and German, detected or chosen (2026-09-28) · **done**

The interface is in English or German, and in nothing else. ETR's 13 imported tables cover its
111 strings and none of the ~125 this rebuild added (lobby, ghosts, opponents, the settings
screen), which were English literals — so a German system got a menu half in German, and a French
one half in French. Now every string a player reads goes through the table: ETR's key where one
fits, otherwise a row of the hand-written `game/i18n/ui.csv` (`keys,en,de`), registered ahead of
the imported tables in `project.godot`. Scenes hold keys and let auto-translate draw them;
scripts `tr()`; the label constants (`AISkill`, `LightCondition`, `WindField`, `TouchScheme`,
`QualityPreset`, the snow grades) are keys; `LobbyServer.explain` translates on the client, so
each player reads a refusal in their own language.

`Language` (`scripts/config/language.gd`) pins the locale to `en` or `de`. `[game] language =
"auto"` (the default) takes `OS.get_locale()` — `LANG` on a desktop, the system language on
Android, `navigator.language` in a browser — and gives German to a German locale, English to
anything else. The settings screen's new first row offers *Automatic (…)* (naming what it comes
to), *English* and *Deutsch*; Ok applies it and rebuilds the main menu, because text put up with
`tr()` does not follow a locale change on its own. `--lang=de` / `?lang=de` override for one run.

**Verified**: the suite (`config/language`, `config/string table` — both columns present,
placeholders matching, and the engine resolving a key of each kind in each locale); every menu
panel rendered with `--lang=de` and `--lang=en`; a desktop run under `LANG=de_DE.UTF-8` coming up
German with no setting; switching on the settings screen writing `language = "de"` and the
rebuilt menu in German. **Not verified**: a browser or a phone picking the locale up — both are
the engine's `OS.get_locale()`, not code of ours. The course descriptions stay English, as ETR
ships them.

### A thunderstorm (2026-09-28) · **done**

A fourth sky on the course screen, **Thunderstorm** (*Gewitter*), and the first that is not ETR's:
rather dark — darker than cloudy, lighter than night — with lightning flashing in the cloud deck and
lighting the hill for a moment. `--light=thunderstorm`, `[game] conditions = "thunderstorm"`,
`SHOT_LIGHT=thunderstorm`; carried on a lobby room like the others (`LightCondition.Kind` 4).

**The preset is derived, not imported.** No `light.lst` describes a storm, so
`LightCondition.preset_for` builds `<location>_thunderstorm` from the location's cloudy preset
(`EnvironmentPreset.storm_from`, cached so a race does not re-light for nothing). `[diff]` and
`[amb]` are scaled by `STORM_LIGHT` (0.74, 0.76, 0.82) as if `light.lst` had said so and the gains
re-derived the importer's way, so the shaded end lands at exactly that fraction of cloudy's in
display space; sky colours, fog and ETR's photographed sky (`sky_energy`) by `STORM_SKY`. Nothing
casts a shadow. Bunny Hill, frame 110, `carve`, snow half of the frame (G mean): cloudy 193, storm
140, night 140 — but night's is saturated blue (B 216, 57 % clipped) under a sky of 48 where the
storm's is 84, so the storm reads plainly lighter. The first try at 0.62 put the storm's snow
*under* night's (119) and was raised.

**The flash is the sun.** `Lightning` (`scripts/render/lightning.gd`) strikes every 3.5–11 s within
about 57° of where the camera looks, each strike 1–4 return strokes (12 ms rise, 75 ms decay), 65 %
of them with a visible bolt and the rest sheet lightning, all from a seed hashed off the course's
name so a capture reproduces. It adds `LIGHT_FLASH` to the one `DirectionalLight3D` and turns it
toward the strike by the flash's share of the light: a second light would run `light()` again and
add the ambient twice inside ETR's clamp. So the terrain, trees, objects and racers flash together,
inside the clamp, on both renderers. The sky reads two new globals, `atmo_flash` and `atmo_bolt`:
`atmo_sky` adds the flash (brightest over the strike), so the haze in front of a far slope flashes
with the sky behind it; the clouds glow from inside; and the storm's sky — only the storm's,
`ATMO_LIGHTNING` in `Atmosphere.sky_shader` — draws a jagged bolt with one branch from the cloud
base down behind the ridges. ETR's skybox (`--sky=etr`) gets the sheet flash, no bolt.

**Verified**: the suite (`environments/a thunderstorm`: between cloudy and night, cached, cloudy
left alone, dimmed in display space; `atmosphere/lightning`: only the storm's look has it, the bolt
define only in its sky, the stroke envelope, a seed is a storm, 30 s flashes several times and
lifts the sun). 6095 passed, 1 failed — the pre-existing `lighting/what project.godot ships`.
Captures on Bunny Hill under Mobile at frames 110 (dark), 239 (sheet flash), 1170 (a bolt behind
the trees), Compatibility at 1170, and `--sky=etr` at 239. **Not done**: thunder — ETR ships no
sound for it, and the licence audit makes a new one a separate job. A paused race holds whatever
flash it was paused in.

### The shadow's edge filter is a setting (2026-09-28) · **done, not measured on a phone**

The sun's soft-shadow filter was fixed at Soft Medium in `project.godot` (for both platforms, to
clear the dither Mobile has no TAA to average away), and on an Adreno 650 at 100 % render scale
its taps are part of a frame that does not hold a playable rate. It is now
`[quality] shadow_filter` — hard / very_low / low / medium / high, Godot's `ShadowQuality` index
for index, Ultra left out — and the **Shadow edges** row under Shadow detail, hidden and disabled
with the other shadow rows. `RaceScene._apply_shadow_detail` sets it with
`RenderingServer.directional_soft_shadow_filter_set_quality` whenever it sets the atlas.

Presets: Medium, High and Best keep Soft Medium, so the shipped frame and the phone's first-run
Medium do not move; Fast takes Soft Low; Fastest (no shadows) names Hard. A settings file saved at
Fast before this reads the missing key as Medium, and so shows "Custom" until Fast is picked again.

**Verified**: the suite (the default matches `project.godot`, the key round-trips by name, an
unknown name keeps Medium) — 6097 passed, 1 failed, the pre-existing `lighting/what project.godot
ships`. Captures on Bunny Hill at `--quality=fast`, Soft Low against Hard: the tree and penguin
shadow edges go from soft to stepped, so the runtime call takes. **Not done**: what each level
saves on the phone — the frame times above are the iGPU's and do not include this knob.

### The render scale is a drop-down (2026-09-28) · **done, presets not re-measured**

The **3D render scale** row was a slider over the file's whole 0.25–2.0 in 5 % steps; it is now a
drop-down of 25 / 50 / 75 / 100 % (`QualityPreset.RENDER_SCALES`), with the pixels it renders
beside it. The file still takes anything in 0.25–2.0: a value off the list (a hand-edited 0.65,
or 1.5) gets a row of its own while the screen is open, so Ok writes back what was read — the
promise the sliders keep by matching the file's clamp.

Every preset has to be a row, so two moved: **Fastest 0.7 → 0.5** and **Fast 0.85 → 0.75**.
Medium, High and Best stay at 1.0, so the shipped frame and the phone's first-run Medium do not
move. A file saved at Fastest or Fast before this now reads "Custom" (with a 70 % or 85 % row)
until the preset is picked again. The FPS table in *Quality presets* above was measured at the
old scales; its Fastest and Fast columns are not current.

**Verified**: the suite (every preset's scale is a row of the drop-down) — 6102 passed, 1 failed,
the pre-existing `lighting/what project.godot ships`. The screen opened in the game: the four
rows, a hand-set 0.65 shown as its own "65 %" row and read back unchanged, Fastest and Fast
selecting 50 % and 75 %, and 50 % picked by hand reading "Custom".

### Shrubs became bushes; the bare tree lost its brooms (2026-09-28) · **done, not looked at in a browser**

**The shrub** (`shrub.png`: 2138 on `bronze_set`, 2010 on `pygoscelis_adeliae`, lining the track on
Bunny Hill) was the last collidable object still drawn as ETR's two crossed quads. It now goes
through `Forest` like the two trees, as `ShrubMesh`: the conifer's treatment with a bush's shape —
radial fins carrying the picture's halves for the silhouette, and sprigs bursting from the root
over the whole dome, each carrying the strip of the picture along its own ray out to the rim. The
outline is measured off the picture's alpha (`ShrubMesh.PROFILE`). Triangles per level 392 / 116 /
56, then its own octahedral impostor (`shrub_{albedo,normal}.png`, from LOD 0). `ObjectPrefab.shrub`
marks the prefab, set by the importer (`SHRUB_TEXTURE`) and by hand in `shrub.tres` and every
course's embedded copy.

What did not work first: sprigs cut as level strips (the conifer's whorls) drew every card as a
trapezoid across the solid heart of the picture; the lowest sprigs, near level, were only ever seen
as streaks by a chase camera; and even along the ray, a sprig's straight root and sides showed up
close as shards. Sprigs now start at 20°, and fade to their root and sides through `COLOR.a`, which
`conifer.gdshader` and the bake multiply into the picture's alpha (1 on every other vertex), so the
scissor cuts along the picture's gaps. Close up (a shrub passed at 2 m) it is still a 256² picture
magnified — as the conifer is — but a volume, not a card.

**The bare tree** drew its finest order as 84 tubes, each with a spray card stood upright on a stalk
at its tip and another at its middle: seen from the track, a crown of little brooms. The finest
order is now *only* a card, laid along the branch from where it leaves its limb, facing out of the
crown; the sprays are redrawn as a crooked twig with alternating side shoots (no stalk); twigs
wander more and pull upward less; a card's normal is held near level, which also took the white
off the crown's top. Triangles 2070 / 1072 / 340 → **1276 / 684 / 394** (LOD 2 keeps the second
order, or the twigs float). Impostor re-baked.

`tools/tree_portrait.sh` (`tests/tree_portrait.gd`) draws one species on flat snow at a chosen
distance, level or field of view, fog off — how all of the above was looked at.

**Verified**: the suite — 6145 passed, 1 failed, the pre-existing `lighting/what project.godot
ships`; new: twigs are cards at every level and never tubes, shrub levels cheapen, stay in the unit
box and sample only the picture, sprigs end on the outline, every course marks its shrub. Captures
on Bunny Hill (Mobile and Compatibility), `bronze_set`, `keep_country_tidy`; each level of both
species at its own distance. Frame rate, 1024x576 logical, iGPU, vsync off, `paddle`, median
`--print-fps` over 1500 frames, before → after: Bunny Hill 120 → 123 (Mobile), 228 → 233
(Compatibility); `bronze_set` 135 → 140, 199 → 202 — no cost, within noise. **Not done**: a
browser, a phone.

### The course list is in three parts, and a course can be added by address (2026-09-29) · **done, not tried in a browser or on a phone**

**Three parts**, each under a header row that cannot be selected (`CourseMenu._fill_list`):
*Tux Racer*, *Extreme Tux Racer*, *Added courses*. `CourseListing.category()` decides, from
`CourseCatalog.TUXRACER_ORIGINALS` — Bunny Hill, Twisty Slope, Bumpy Ride, Frozen River, Path of
Daggers. ETR's `default` group cannot stand in for that list: it holds 22 courses, seventeen of
them ETR's own (Chinese Wall, Milos Castle, ...). The five are what ETR's data itself marks as Tux
Racer's: the only courses by Jasmin Patry, the only ones on `[env] tuxracer`, and the whole of
`events.lst`'s *Tux Racer Classics* ("courses that shipped with the original Tux Racer"). The
Tux Racer 0.61 source tarball carries no course data to check against — its only course names are
`path_of_daggers` and `ingos_speedway` (not in ETR) in a comment in `course_mgr.c`. `group` stays
on the listing as provenance; `courses.tres` was not re-imported (its row order is the old one,
`load_with_external` re-sorts).

**Added courses** (`ExternalCourses`): *Add course…* under the list takes an http(s) address of a
course `.pck` — the pack a `Course_<dir>` preset exports, the same file the streamed web build
fetches. The file name is the course (`…/tuxway.pck` must carry `res://courses/tuxway/`), a name
the build ships is refused before any fetch, and a pack that does not carry its course is refused
after. What is kept, in `user://external_courses.cfg`, is the entry — address, name, author,
description, size, slope — never the pack: it is fetched again on the first race of each session
into `user://cache/external/`, which is emptied before that first fetch. Until then the row has no
preview and shows the host it comes from. *Remove* forgets the entry; the pack stays mounted until
quit (Godot cannot unmount one). `CourseCatalog.load_with_external()` is what the shell lists and
looks up in (course menu, ghosts, `RaceScene.load_course`); `load_default()` stays the build's
alone, so the suite never depends on the machine's list. The lobby's picker leaves added courses
out — the other racers would have no way to fetch them.

`PackStream.fetch_and_mount(url, cache_path, on_progress, replace_files)` is the old web-only fetch
opened up to an absolute URL on every platform. Two fixes fell out: the `HTTPRequest` was added
deferred and one `process_frame` later assumed to be in the tree, which it is not when the caller
is itself inside the frame's process step (the request then refuses outright); and off the web
the size comes from `get_body_size()`, which is -1 until the headers arrive, so it is asked until
it answers.

**A pack is code.** A `.pck` can carry scripts and a course scene can attach one, so adding an
address trusts its host like installing a mod. Packs from an address are mounted with
`replace_files = false`, so one cannot replace a file the build ships; that is all the protection
there is. On the web the host must also answer CORS (the page is cross-origin isolated).

**Verified**: the suite — 6289 passed, 1 failed, the pre-existing `lighting/what project.godot
ships`; new `TestExternalCourses` (the five and nothing else are Tux Racer's, sort order, which
addresses name which course, the entry round trip, the refusals). By hand, natively, against a
local HTTP server: a pack added, listed last, its scene loaded; the same course twice, a 404, a
pack missing its `course.tres` and a dead port each refused with their own message. The menu
captured (Mobile, real GPU) with an added course and with the address row open; arrow keys step
over the header rows. **Not done**: an added course raced from the menu, a browser (CORS, the
`HEAD` size probe cross-origin), a phone.

### The going-on button is the rightmost one, and the course screen's spinners line up (2026-09-29) · **done**

Every button row reads Back first and the button that moves forward last: *Race* on the ghost
list (Back · Delete · Race), *Connect*, *Join* (Back · Disconnect · Refresh · Create a race ·
Join), *Start the race* (Back · Leave · Change course · Start), and *OK* in the settings (Cancel ·
OK) — the order the course screen already had. Only the scene files' child order changed; no
script depends on it.

The course screen's option rows (opponents/skill, snowfall/conditions, wind) are one 5-column
`GridContainer`, label · spinner · spacer · label · spinner, so each column starts at the same x
whatever the labels say in either language. A grid has no row node to hide, so Race mode shows
and hides the opponents row's five cells (`CourseMenu._field_cells`). `_equalize_option_widths`
gives all five spinners the widest one's width (never below 150 px), so the two columns match.

**Verified**: the suite — 6289 passed, 1 failed, the pre-existing `lighting/what project.godot
ships`. Captured the course screen in English and German, in Race and in Create mode, and the
ghost, lobby (all three pages) and settings screens, from a throwaway probe script.

**Folders and server names (same day).** *Add course…* now asks for a **server name** as well as an
address, and the added courses are listed under a header per server name rather than one *Added
courses* header (that one is left only while nothing has been added). The address may be a
**folder**: anything http(s) that is not a `.pck` is read as one, and its `courses.json` fetched
(or the `.json` named outright). The index is `{"courses": [{"file", "name", "author",
"description", "width", "length", "angle"}]}` with only `file` required — relative to the index or
a whole address (`ExternalCourses.parse_index`). Every course in it this game does not have yet
is added from the index alone; nothing is fetched until it is raced, and a pack that turns out not
to be its course fails there, on the loading screen. Courses the game ships or already has are
counted and skipped; a folder with nothing new says so. `tools/gen_course_index.py <folder>`
writes the index for a folder of `<dir>.pck`, taking the menu lines from `courses.tres`.
`PackStream.fetch` is the byte half of `fetch_and_mount`, which the index read shares.

**Verified**: the suite — 6303 passed, 1 failed (the same pre-existing one); `TestExternalCourses`
now also covers the index (relative, subfolder and whole addresses; non-packs and junk left out;
a page that is not an index), folder addresses, the server-name refusal and the per-server order.
By hand against a local HTTP server: a folder of three packs indexed by the tool → two added, the
built-in one skipped; the same folder again → nothing new; a single pack under a second server;
a folder without an index refused; a folder course fetched and loaded only on `ensure`. The menu
captured with two servers and the two-field add row. **Not done**: a browser, a phone, removing a
whole server at once (courses are removed one at a time).

### A phone can split the tilt: steer by it, or speed by it (2026-09-29) · **done, not raced on hardware**

`[controls] touch` has five schemes, in the settings screen's order: `buttons`, `tilt_steer` (the
roll steers, paddle and brake are buttons), `tilt_speed` (buttons steer, the pitch paddles and
brakes), `tilt` (both — still the phone's default) and `off`. The file stores the name, so an older
file's `tilt`/`buttons` reads unchanged; the enum was reordered for the drop-down. `TouchScheme`
answers `tilt_steers` / `tilt_speeds` per kind; `RacerRoster.build_local` takes the kind and sets
`TiltSteering.steers` / `.speeds`, which `LocalInputSource._merge_tilt` honours (the other half is
the buttons', and a tilt there is ignored). `TouchControls.shown` drops only the buttons the tilt
replaced (`TILT_STEERED`, `TILT_SPED`) and brings them back if no reading ever arrives; the level
along the bottom draws only the tilt's half. `--touch=tilt_steer|tilt_speed` forces either on a
desktop — where, with no sensor, every button is drawn.

**Verified**: the suite — 6360 passed, 1 failed (the same pre-existing `lighting/what
project.godot ships`); `TestTouch` now covers the halves per kind, the half-merges and the
buttons each mixed scheme draws. **Not done**: a phone, and a render (a desktop has no sensor, so
the overlay shows every button whichever tilt scheme is forced).

### The ice reflects the world, not only the racers (2026-09-29) · **done, browser seen only through SwiftShader, not measured on a phone**

`IceEnvironment` (`scripts/render/ice_environment.gd`) renders a small cube round the watched
racer — six 128² `SubViewport` faces from 0.5 m above the drawn ice, 90° square lenses, drawn side
by side into one 3x2 atlas by a 2D pass (no readback) — and `terrain.gdshader` samples it in the
ice branch in place of the two-colour sky ramp: the mirror ray is walked out to a 60 m sphere round
the probe and looked up from its centre (`ice_env_uv`, face table shared with
`IceEnvironment.FACE_FORWARD`/`FACE_UP`), faded back to the ramp toward the sphere's edge, then the
racers' planar mirror goes on top as before. `tuxway`'s lake carries the mountains, `inception`'s
walls reflect each other, and at night the bank's torches are in the ice.

**What is not in it.** Racers, spray and falling snow moved from layer 1 to
`IceEnvironment.NEAR_FIELD_LAYER` (1 << 2); the main camera sees every layer, the probe's cameras
all but that one and the mirror's. `Racer._apply_reflected` now sets the whole mask. A face's own
terrain skips both screen-space terms (the probe and the mirror) — recognised by its 90° square
projection, which no window has.

**When it runs.** Only while ice lies within 90 m of the camera (`build_ice_map`: the dominant
layer sampled every 4 m, kept in 16 m cells dilated by the range) — a course without ice pays
nothing. Then all six faces every frame. A first cut re-took the cube only every 3 m / 0.5 s at two
faces a frame (0.3 ms) and **read as a stutter** — the reflection jumped each time the probe caught
up — so that saving is gone.

**Cost.** Per face ~0.9 ms on the Renoir iGPU under Mobile (720p, `tuxway` carve, unthrottled
`--print-fps`), flat in the face size; with the sun's shadows off 0.26 ms — ~70 % of a face is the
shadow cascades, which Godot renders again for every camera and has no per-viewport switch for.
Six a frame measured 211 → 102 fps (~5 ms). Paired runs later in the day, with something else on
the host holding the GPU at 75 % busy: Mobile 85 → 52 fps, Compatibility (desktop GL, no shadows)
112 → 87 fps. The absolute numbers from that session are not worth keeping; the ratio is.

**On every renderer, as a setting.** `[display] ice_world_reflections`, the quality row *Ice
reflects the world*: on at HIGH and BEST, off at MEDIUM and below (a phone starts at MEDIUM). Under
Compatibility the atlas is the terrain's **16th** sampler (15 = 14 + `atmo_ridge_map`), which is all
WebGL2 guarantees and what most real browsers report. So it is declared only under `ICE_ENV_ATLAS`,
defined in a variant of the shader `TerrainRenderer.ice_environment_shader()` builds when the
setting is on (inserted after `shader_type`, which Godot reads before preprocessing); off, the
terrain compiles exactly as before, 15 units. `RaceScene` builds no `IceEnvironment` at all then.

**Compatibility does not decode the atlas.** Measured with the ice temporarily showing the atlas
raw (`tuxway` frame 200): a mountain at R 119 came back mirrored at 123 under Mobile and 184 under
Compatibility — its encoded 120/255 taken for linear. There the sampler has no `source_color` and
`ice_env_sample` decodes by hand; after it, 122.9 on both.

**Verified**: the suite — 6400 passed, 1 failed (the same pre-existing `lighting/what
project.godot ships`); `TestReflection` checks the six face cameras against `face_uv`, the
near-field layer on and off, both settings through the file, and that the atlas is declared only
under `#ifdef ICE_ENV_ATLAS` and the variant is the file plus the define. Renders: `tuxway`,
`inception`, `frozen_lakes`, `frozen_river` and a `tuxway` night under Mobile; `tuxway` under
Compatibility on the desktop and **in headless Chromium** (streamed web build, WebGL2 over
SwiftShader — which reports 32 units, so the 16-unit case is still unseen). Tone, `tuxway` against
the build before (Mobile, R means): near ice 181.6 → 182.3, mid lake 164.7 → 162.0 with the
mountains' contrast, far ice 166.5 → 180.9, nothing clipped; under Compatibility +0.7 / −2.5 / +8.
The settings row, driven in a scene: ticked at HIGH, unticking gives *Custom*, MEDIUM clears it.
Two of the first timing runs with the probe on hung (killed at 200 s); many runs since did not —
the random GPU hang in the trap list, as far as can be told. **Not done**: a phone, a real browser
on a 16-unit GPU, the thunderstorm.

**Near things out of the cube (same day).** Reported: a small object — a red flag, once a whole ice
field — colouring a large area of ice for a blink, depending on angle and distance. A cube map
magnifies what is near its centre: a flag a metre from the probe spans ~6° by 50° of a face, and
every ice pixel whose mirror ray falls in that wedge takes its colour. Reproduced with the ice
showing the atlas raw: on `inception` (frame 300) the canyon wall beside the probe turned half the
floor one flat pale blue, on `frozen_lakes` (frame 600) a shrub by the racer speckled a whole ice
patch green. The probe cameras' near plane went from 0.1 m to 5 m (`PROBE_NEAR`); the same
`inception` frame then reflects the far wall and the sky, `tuxway` is unchanged. The exact
flag case was not caught on a capture.

### The trees' shadows can be baked, and the web gets them (2026-09-29) · **done, not measured on a phone, not seen in a real browser**

**What.** `TreeShadowBake` works out the conifers', bare trees' and shrubs' shadows once per course
and sun, as the course loads, into the terrain's vertex colour B (`TerrainRenderer`, beside the
relief occlusion in R and the torchlight in G). `terrain.gdshader` multiplies it into the sun term
wherever the shadow map's `ATTENUATION` goes, so a baked shadow falls to the ambient and goes the
same blue a mapped one does. Under **Compatibility** — which cannot draw a shadow map at all — it is
always on (sky and `[display] shadows` permitting), so the web build has tree shadows for the first
time. Under **Mobile** it is a choice: `[quality] tree_shadow_kind = "dynamic" | "baked"`, the
*Tree shadow type* row, `--tree-shadows=` / `?tree-shadows=` / `SHOT_TREE_SHADOWS` for one run.
Baked takes the trees out of the shadow map (the racers keep theirs) and the *Tree shadows* row is
disabled. The **Fast** preset now bakes (it had no tree shadows); every other preset, and the
defaults, are unchanged, and the default Mobile frame is pixel-identical to before. The settings
screen's *Shadows* row is now shown under Compatibility too, since it switches the bake; the four
shadow-map rows stay hidden there.

**How.** A tree is its species' crown profile (the one its mesh is built on) as a solid of
revolution with a density; a vertex's shadow is what a ray from it to the sun loses crossing it.
Marched once per tree size as a small stamp and `Image.blend_rect`ed, black at the shadow's
opacity, into a half-float map of the course — which multiplies, so crowns in line compound. Found
along the way, top down against the shadow map on Bunny Hill:

- **A density of 1.4 left every tip pale.** The fins are cutouts of an opaque picture; a thin ray
  through the crown's tip is stopped. 5 for conifers, 4 for shrubs.
- **The course's plane is not the ground.** Shadows down Bunny Hill's banks came out 2–3 m short
  of the mapped ones. Ground falling away from the sun lengthens a shadow exactly as a taller tree
  would on the plane, so the slope along the sun (a plane fitted through three heights under the
  shadow) goes into the height the stamp is picked by (`_stretch`). A stamp per slope instead was
  ~3000 stamps and 0.8 s on `bronze_set`.
- **Bunny Hill's rows are 1 m apart**, and a sharp stamp drew every shadow as a staircase. Blurred
  [1 2 1], the shadows turned into pale smears: snow in the sun sits at ETR's illumination clamp,
  so half a shadow barely darkens it. Blurred and then doubled (up to the species' ceiling), the
  inside of the sharp shadow's half-way line is full strength and only the ramp outside is soft.
  Probe points in a shadow now read 171/204/254 baked against 163/198/249 mapped.

`splat_uv` moved from a vertex varying to `splat_uv_of(world_pos)` in `fragment()` to free the
components the bake rides in (trap list).

**Cost.** Nothing a frame. At load, headless on the desktop ~50–150 ms for the biggest courses
(the machine's own noise is 2× run to run); **in headless Chromium 121 ms on Bunny Hill and 237 ms
on `bronze_set`** (8153 trees), printed as `TREE_SHADOWS baked N trees in M ms`. A sky change
mid-race to one with the same sun costs nothing (cloudy only turns the strength to 0); a new sun
re-bakes and rebuilds the built chunks (~220 ms, headless).

**Not done, by design.** Flags (a pole is thinner than a vertex spacing), bare trees' limbs (a
faint wash instead), trees shading each other, racers darkening under a tree, shadows that sway.

**Verified**: the suite — 6425 passed, 1 failed (the same pre-existing `lighting/what
project.godot ships`); `TestTreeShadows` holds a conifer's shadow to the side away from the sun,
its length at 45°, a bare crown fainter, two crowns compounding, a bank lengthening it, no bytes
for no trees or a sun on the horizon, and times the bake on `bronze_set` and Bunny Hill;
`TestConfig` the new key through the file. Renders: Bunny Hill top down and in the chase view
under Mobile dynamic, Mobile baked and Compatibility; `bronze_set` and `challenge_one` chase views;
Bunny Hill and `bronze_set` in headless Chromium (streamed web build over SwiftShader).

### Rock has grain at the racer's feet (2026-09-30) · **done, not seen in a real browser or on a phone**

**What.** Steering left from the start of Who Says Penguins Can't Fly puts the racer on `rock`,
and at the chase camera's distance its 256-texel photograph (6 m repeat, 2.3 cm a texel) is
magnified into visible blocks. Rock now has a **detail texture**: each layer with a
`TerrainLayer.detail_strength` reads its own albedo a second time, 4.7x finer and turned 0.63 rad,
and multiplies the colour by that read's brightness over the photograph's mean, fading out by 30 m.
The importer seeds 0.8 on `is_rock()` — ETR's friction ≥ 0.6 and not deformable: the eight
`rock*`, `snowy_rock02/06`, `fine_pebbles` — and 0 everywhere else. `DEVIATION`, marked in the
shader.

**Why not a bump map.** Asked first, and measured before answering: on that view in the sunny
preset every visible rock pixel is at the illumination clamp in all three channels, the red one
(the least clamped) at 1.5–2x. A perturbed normal changes nothing there — an exaggerated 4 cm
luminance bump moved 599 pixels of ~920k on the course's opening frame, all on the sun-grazing rim.
Under cloudy the same rock is below the clamp in every channel, so a bump would show there. The
detail texture changes the albedo, which is what the clamp lets through, so it shows in every sky.

**Found on the way.** The mean is the 1x1 mip, read in the shader rather than uploaded, and mips
are averaged in display space, so it is below the linear mean: a linear ratio brightened the rock
by 2.4 levels. Taken in display space (`pow(ratio, 1/2.2)`) the near-field mean is 115.8 before,
116.0 at strength 0.6 and 115.6 at 1.0; the standard deviation 38.0 → 39.6 → 41.7.

**Cost.** No texture unit (the shader is at its last one under Compatibility), no varying: two
taps of an already-bound sampler per detailed layer, only where that layer has weight and within
30 m. Adding the field to the fingerprint moved all 43 layers' hashes; they were rewritten, and
`import_all.sh --course=penguins_cant_fly` then reproduced every layer byte for byte.

**Verified**: the suite — 6471 passed, 1 failed (the same pre-existing `lighting/what
project.godot ships`); `TestTerrainLibrary` pins the seed on all 43 layers, the eleven rock
terrains, and `layer_detail` in splat order in Penguins' built material (rock, ice, rock, rock).
Renders: Penguins steering left at 6 s and 8 s under Mobile and at 6 s under Compatibility;
Bunny Hill's opening frame is unchanged beyond 13 pixels (its rock is beyond the fade there).

### A course of our own: Forest Trail (2026-09-30) · **done, not seen in a real browser or on a phone**

**What.** The first course that is not ETR's: **Forest Trail** (`courses/forest_trail/`), 1600 m
at 19°, a snowy trail winding down through a conifer forest. The trail is `snow` with eight
patches of `ice1` on it, edged by `icy_forest_floor`; the forest floor is bare earth (`dirt` and
`forest_floor2`, in patches). About 4400 conifers (5.5–14 m, taller than ETR's) and 700 bushes
stand in it, with **boulders, stone scatters, fallen logs and stumps** on the ground: 316 / 616 /
192 / 201, half of each drawn within 25 m of the trail, where a racer sees them. Sixty-five
herring in 13 lines drift across the trail; the start and finish banners stand on it.
Listed under a new fourth heading, **PenguinRacer** (`CourseListing.Category.PENGUINRACER`,
group `penguinracer`), between ETR's courses and those added by address.

**How it is made.** `tools/gen_forest_trail.sh` runs `addons/course_gen/gen_forest_trail.gd`
twice with an `--import` between, as the importer is run. Everything is a function of the
distance down the trail — its centre line (three sines, straight for the first 90 m and the last
180 m), its width (13–23 m, 24 m at the gates), three kickers — plus seeded `FastNoiseLite`. It
writes what the importer writes (float relief at 0.5 m, the occlusion bake, splat maps summing
to 255 exactly, `course.tscn` of markers) and adds its row to `resources/courses.tres`.
`imported_from` is empty, so the ETR importer never visits the course and its catalog merge keeps
the row. Deterministic; re-running it rewrites the same course. A first run with no
`preview.png` draws a map as a placeholder; the committed preview is a capture.

**The props** are new object types — `resources/objects/{boulder,stones,log,stump}.tres`, written
by the generator — drawn from `PropMesh` (procedural, flat-shaded, colours painted into the
vertex colours: nothing for the licence audit) with `object_prop.gdshader` (vertex colour ×
world-space value-noise mottle, a dusting of snow on upward faces, ETR's clamp, the atmosphere's
fog, torchlight). They are ordinary `MultiMesh` batches in `CourseRoot`. Two small general
additions carry them: `ObjectPrefab.ground_aligned` stands a prop square to the ground
(`CourseRoot.ground_normal`, across ±1 m) rather than upright, and a marker's Z scale is now read
(it was always the X scale), so a log's marker gives length in X and thickness in Y and Z.
Boulders and stumps are collidable, as trees are (cylinder); stones and logs are decoration.

**The play area is the trail.** `play_bounds` is a corridor, the trail plus 5 m of forest either
side, in 24 m pieces. `RacePhysics` keeps a racer inside it and `AIInputSource` plans inside it,
and without it a computer opponent — which reads no terrain but friction — ran straight on at
the first bend and spent the race in the trees. With it, and the tightest wiggle of the centre
line softened, the hard driver holds the trail at ~60 km/h and collects the herring.

**Found on the way.** Night torches stand every `CourseLights.SPACING` along the play area's
long edges, so a corridor built of 8 m pieces got none, and `torch_positions` decided "outward"
from the polygon's centroid, which a winding corridor puts on the wrong side of its own edge.
It now takes the side from the polygon's winding (same answer for every rectangle), the corridor
is built in 24 m pieces, and the generator clears 3.5 m round each torch spot before planting the
forest, which otherwise took 117 of the 132.

**Also.** `--auto-input=ai` puts the computer's driver (hard) in the player's seat, so a capture
follows a course's line instead of slaloming into its trees.

**Verified**: the suite — 6557 passed, 1 failed (the same pre-existing `lighting/what
project.godot ships`); `TestProps` checks the meshes face out and fit the unit box, the prefabs,
the ground normal on a plain slope, the catalog row and category, that every tree, bush and prop
is off the trail and on earth rather than snow or ice, herring and banners on it, and the
corridor. `TestObjects` now counts the four props beside ETR's fourteen. Renders under Mobile
(sunny, night) and Compatibility, driven by `--auto-input=ai` down the whole course.
**Not done**: a real browser, a phone, a frame-rate measurement of 4400 trees, and the
course's music/time/herring targets (it is in no event or cup).

### Forest Trail: a narrower trail that forks, and a conifer floor with snow in the gaps (2026-09-30) · **done, not seen in a real browser or on a phone**

**What.** Reworked after a first look. The trail is **8–12 m wide** (was 13–23 m, which read as
a snowfield beside a forest). A tree line stands along both edges of every branch, so the racer
runs between walls of trees. From 540 m to 1100 m the trail **forks**: two branches part to ~36 m
apart, each wandering on its own, with a wooded island between them. The left branch has the
kicker; the right has more ice. They rejoin before the finish. The world is 120 m wide to make
room. The **forest floor is conifer litter**: a new layer, `conifer_needles`, whose 512² texture
the generator draws (humus, 16 000 needles in rust, tan, dark brown and a few green, twigs, spruce
cones, all antialiased and tileable). It repeats every 3 m with a detail strength of 0.5 and has
ETR's forest-floor friction and sound. **Snow lies where the crowns leave a gap**: the generator
plants the forest *before* painting the ground, sums each conifer's crown (and, weaker, each
bush's) into a 1 m canopy map, and lays `thin_snow` where cover is low, snow-dusted litter
(`icy_forest_floor`) where it is partial, and needles under the crowns, with a little bare
`dirt`. The result: about 58 % needles, 21 % forest snow, 10 % trail.

**How.** Everything that used `centre_x(d)` takes a branch; `beyond_edge` is the nearer branch's.
Both stages now place the same objects: the assets stage to lay the snow round them, the
resources stage to write them. Torch spots need only the play area, so both stages clear them
against a flat stand-in surface. The play area spans both branches and the island (a polygon has
no holes). The branches part with an ease-out rather than a smoothstep: a smoothstep kept them
overlapping for half the ramp, one snowfield three trails wide. `conifer_needles` lives in
`courses/forest_trail/` with its texture, not in `resources/terrain/`, which `TestTerrainLibrary`
holds to `terrains.lst` record for record. It ships in the course's own pack.

**Verified**: the suite — 6570 passed, 1 failed (the pre-existing `lighting/what project.godot
ships`). `TestProps` adds the fork (one trail above and below, two with forest between in the
middle, both in the play area) and the floor (the course's own needle layer, >50 % of the
forest floor needles, 10–40 % snow, none of the trail's snow in the forest). All 132 night
torches still stand. Renders under Mobile down the whole course and through the fork with
`--auto-input=ai` (the hard driver holds a branch at 60–69 km/h), and under Compatibility.

### A second course of our own: Mountain Forest (2026-09-30) · **done, not seen in a real browser or on a phone**

**What.** **Mountain Forest** (`courses/mountain_forest/`), 1420 m to the finish down the floor
of a steep wooded gully — Forest Trail's opposite. The trail is **5–8 m wide** (Forest Trail:
8–12), and either side a bank climbs off a narrow shoulder: 14–30 m high, over a 14–22 m length
scale, craggy, drifting in height and steepness along the course and independently per side.
The walls close the view in, so the forest is thinner (~900 conifers against Forest Trail's
~1500) and stands where it is seen: a tree line along both edges and a jittered grid on the lower
walls, thinning up them and missing on the crags. **The fall line is uneven**: thirteen sections,
chutes of 24–31° and benches of 12–14° (under the 19.3° at which snow's friction holds a racer),
eased over ±14 m so no lip launches anyone; the base slope is their mean, 22.0°. On five benches
and in one chute the gully **pinches to a 5 m slot with a dead trunk lodged across it
overhead** — resting where each bank first stands 3.6 m (one side up to a metre higher, so it
leans) over the trail, ends sunk 1.8 m into the banks, a line of herring under it as bait. Two
kickers stand at the foot of benches, so their landings are downhill; nine ice patches lie in the
chutes. The walls are the forest floor (needles under crowns, snow in gaps), bare earth with snow
lying in patches where too steep for litter, and `snowy_rock06` / `rock06` on the crags. The
**sky is a near range**: twice the usual height, broader, less hazed, wooded almost to the crests.

**How.** `tools/gen_mountain_forest.sh` → `addons/course_gen/gen_mountain_forest.gd`, the same
two stages as Forest Trail. The steps are relief: the heightmap is relief over the analytic
`base_angle`, so the generator integrates each section's gradient minus the mean down the course
(`_profile`, centred) and adds it to the walls. **The occlusion bake gets the walls without the
steps** — it measures against a uniformly tilted plane, and a change of gradient is not a bank.
What both generators share moved to `CourseGenKit` (splat maps, the occupancy grid, the drawn
needle texture and layer, `course.tscn`, the catalog row); Forest Trail regenerates byte-identical
(only `course.tscn`'s ids churn). Mountain Forest writes its own copy of the needle layer: a
course's web pack carries only its own directory.

**Three general additions carry it**, each a no-op for every other course:
- **A marker's Y is a height above the ground, and its X/Z rotations are read** (`CourseRoot`).
  Every existing marker has Y = 0 and no tilt — checked across all 45 `course.tscn`.
- **`PropMesh.Kind.TRUNK`**: a log for 12:0.7 spans — 16 segments, 12 sides, bark unevenness that
  runs along it rather than changing per ring (Forest Trail's log stretched that far read as a
  stack of planks), branch stubs square to the axis so the stretch leaves them alone. Prefab
  `lodged_log`: level, decorative, not collidable — the grid knows only upright cylinders.
- **`CourseData.backdrop_height` / `backdrop_forest` / `backdrop_near`** → `Atmosphere.ridge_shape`
  → a new global, `atmo_ridge_shape` (default `(1, 0, 0, 0)`, the old skyline to the term):
  scales the ridges' amplitude, broadens and de-hazes them, and lifts the tree line to just under
  the crests, where `atmo_ridge_firs` draws the canopy as staggered fir tops (one per cell, shifted,
  sized, some missing, a few snowed on). The ridge map's top row is now `atmo_map_t_max()`, 0.16 or
  just over the tallest crest a shape raises.

**Found on the way.** A play area reaching 3 m up the walls had the computer — which plans inside
it and reads no slope — carve up the bank on every bend and stall on the rock at 29 km/h. At 1 m
(the foot of the bank) the hard driver holds the gully floor at 60–87 km/h and finishes in about
1:20 with 25 herring.

**Verified**: the suite — 6643 passed, 3 failed, all three pre-existing: `lighting/what project.godot ships` and `props/forest floor` ×2 (Forest
Trail's committed floor is 23 % needles / 69 % snow since `FOREST_DENSITY` went to 0.2 — the test
still expects the denser forest). `TestMountainForest`: catalog row, own needle layer, the near
backdrop, the fall line on the real heightmap (≥ 5 chutes over 24°, ≥ 5 benches under 16°, never
uphill), walls ≥ 4 m up 8 m out and ≥ 10 m up 25 m out every 10 m, trail ≤ 9 m wide, every marker
on the right side of the edge, every trunk ≥ 3 m clear of the snow over the whole trail with both
ends in a bank, and `CourseRoot` lifting and rolling a marker. `TestAtmosphere`: the shape's
default everywhere and its reach to the shaders and the map. Renders under Mobile (sunny, night)
down the whole course with `--auto-input=ai`, and under Compatibility.
**Not done**: a real browser, a phone, a frame-rate measurement, event/cup targets.

### Mountain Forest: fewer trunks overhead, bumps, obstacles on the trail (2026-09-30) · **done, not seen in a real browser or on a phone**

**What.** After a first look: **two** trunks lodged overhead (560 m, 1140 m), not five; five read
as a pattern. **Eight bumps** (0.6–0.8 m over a 7 m ramp and a 3 m drop, a hop rather than a
kicker's flight) besides the two kickers. None sits within 30 m before an obstacle, so no
landing is on one, and none on a lip: at 290 m the bench-to-chute crest threw it 1.1 m proud.
**Obstacles on the trail**: three boulders (`trail_boulder`, the boulder prefab by another type
name via `CourseGenKit.write_scene`'s `prefab_of`) and four **fallen trunks** lying from a bank
to just short of the trail's middle, crown on the snow, resting on the bank where it first stands
1.2 m, the rest sunk into it. A fallen trunk is drawn with the lodged trunk's prefab and made
solid by a row of `trunk_collider` markers (a new prefab: collidable, no mesh), one every 0.5 m
along the part over the trail, each as tall as the trunk there. The grid only knows upright
cylinders, and the physics checks their height, so a trunk can be jumped.

**Making them fair took four passes, each found by the hard AI stopping dead**, the last three
with a headless probe that drives it through the real collision grid and play area and logs
speed by distance:
1. A fallen trunk first ran on 1.8 m into the bank at ground level and stood up the wall like a
   pole. It now rests where the bank stands 1.2 m and runs on along that line.
2. The AI crawled at 5 km/h in the 1140 m slot. The corridor's 24 m pieces, drawn from the width
   at their ends, cut across the slot's pinch; each vertex now takes the narrowest width within a
   piece either side. On the way, every collidable object's cylinder (a conifer's is as wide as
   its crown) was moved clear of the play area plus 0.8 m (`PLAY_CLEARANCE`); the tree line's had
   reached the edge.
3. With the open half on the outside of the next bend, every one of the AI's nine lanes round the
   trunk left the play area. The open side is now the one the trail turns toward over the next
   30 m (`open_side`), and the trail widens 1.2 m a side beside an obstacle (`obstacle_room`).
4. On a real bend there is still no straight line round anything, so obstacles moved to where the
   centre line is nearly straight from 40 m before to 30 m after, early in chutes. A crash at a
   chute's foot left the racer crawling across the bench below.

The hard AI now passes all seven and finishes in about 1:21 with no dip under 30 km/h in the probe.

**Verified**: the suite, 6690 passed and 3 failed, the same three pre-existing ones.
`TestMountainForest` adds: every obstacle blocks part of the trail and leaves ≥ 2.5 m of line
past it (the collision cylinders plus a racer's 0.6 m either side, 3 m before to 3 m after) on
the side the trail turns toward; the trunk's collider draws nothing; every bump stands roughly
its height proud of the trail on the real heightmap; the 9 m width limit holds away from
obstacles. `TestObjects` counts the collider prefab. Renders under Mobile with
`--auto-input=ai`: jumps off the bumps, round a fallen trunk, past a boulder, to the finish.

### Mountain Forest: rock and ice on the walls in long stretches (2026-09-30) · **done, not yet looked at**

**What.** The walls (everything past the trail's edge litter) were ~22 % rock in crag-sized
speckles and had no ice. They are now 10 % rock (6 % snowed-on `snowy_rock06` at a stretch's
fringe, 4 % bare `rock06` at its core) and 5 % ice (`ice1`), each as a few long stretches of
one wall — 5–30 m down the course, trail's edge to ridge — where no tree stands: 22 of rock and
16 of ice over both walls. The rest stays earth, needles and snow-dusted litter. A first cut by
share, over the crag noise and a small seep noise, scattered both evenly along the walls.

**How.** `gen_mountain_forest.gd` scores each wall cell by a slow noise of distance down the
course, one per side (`_outcrop_noise` 1/45 m for rock, `_seep_noise` 1/35 m for ice), with the
crag and edge noises only ragging the edges, and `_wall_thresholds` picks the cut-offs by
quantile, so `WALL_ROCK_SHARE` / `WALL_BARE_ROCK_SHARE` / `WALL_ICE_SHARE` hold whatever the
noise does; the ice cut is taken over what the rock leaves. The scores read only the course's
shape, so both stages compute the cuts and the tree line and wall forest skip those stretches
(`_bare_wall`). The generator prints each layer's share of the walls.

**Verified**: the generator's own counts (walls 10.0 % rock, 5.0 % ice), stretch lengths read back
from the splat maps; the suite, the same three pre-existing failures. Not rendered.

### Stretched props light in a checkerboard: the shader turns their normals itself (2026-09-30) · **done, not seen in a real browser or on a phone**

**What.** Mountain Forest's trunks (fallen on the trail and lodged overhead) were patched light
and dark triangle by triangle, in the snow dusting and in the lighting alike — reported under
Mobile, where the sun's shadows make it loudest, but Compatibility drew the same pattern.

**Why.** Godot turns a MultiMesh instance's normal by the instance matrix itself and uses the
inverse-transpose only when the *node* is non-uniformly scaled (`INSTANCE_FLAGS_NON_UNIFORM_SCALE`
in `scene_forward_mobile.glsl`, `FLAGS_NON_UNIFORM_SCALE` in the Compatibility `scene.glsl`),
never for a per-instance scale. `PropMesh.TRUNK` is built in the unit box and its marker
stretches it ~15:1, so each bark facet's small along-the-axis tilt is multiplied by that ratio
and the two triangles of every slightly non-planar quad point far apart.

**How.** `object_prop.gdshader` is `skip_vertex_transform` and transforms the vertex and the normal
itself, with `transpose(inverse(mat3(MODEL_MATRIX)))`. That covers every solid prop, since each
one's marker scale is non-uniform.

**Verified**: a throwaway probe (one trunk as a MultiMesh stretched 9 × 0.6 × 0.6 under a
shadowed sun), old shader against new, Mobile and Compatibility: the checkerboard went, and the
snow sits as one cap along the top. The suite shows the same three pre-existing failures. Not
raced to a trunk in the game itself.

**Then the branch stubs.** Once the normals were right, the trunk still had pale strips along its
side and flat brown wedges on top. Those were its broken-branch stubs: built round in the unit
box, then stretched with the rest, so a stub 0.12 across became a blade 1–2 m long and a few cm
thick, with the pale broken tip smeared along the bark. `PropMesh._stub` now builds each stub
`LOG_STRETCH` (10) / `TRUNK_STRETCH` (15) times narrower along X, the typical ratio of length to
thickness for each kind of marker. Only `log.tres` and `lodged_log.tres` had their meshes rebuilt;
the courses were not regenerated. Checked in the same probe: short round nubs, no strips.

**Then the look close up.** Seen from above, the trunk was a grey beam: 12 flat-shaded sides, a
top painted one uniform grey (the shader *mixed* `snow_cover` = 0.55 of snow into every upward
face, so a log's top was 45 % bark), and stubs tapering to spikes. Now the bark of a log or trunk
is smooth-shaded round its girth (`PropMesh.BARK_SMOOTH_GROUP`; rock, cut ends and stubs stay
faceted), the stubs are short and blunt, and `snow_cover` is how much of what faces the sky
carries snow: full-white patches from a coarse noise (`snow_patch_scale` 0.6 m, plus an octave
0.3 of that) with a ragged edge. This applies to every solid prop. Checked in the probe on
Mobile: round logs with a snow cap that breaks along the top; the boulder with a snowed crown; the
stump white on top. Open: a stone scatter comes out nearly all white, since its tops are flat. A
lower `snow_cover` on `stones.tres` would fix it, and the Forest Trail generator writes that material.

### Mountain Forest: the walls' ice kept bare, and a pile of stones halfway down (2026-09-30) · **done, not seen in a real browser or on a phone**

**What.** Trees already kept off the walls' stretches of ice, but bushes, stone scatters,
boulders, stumps and logs were placed without looking, and stood on it. Now nothing does: the
ice reads as a clean sheet. And a pile of stones now stands beside the trail at 717 m, about
halfway down: a core boulder, six round it, three smaller ones lifted onto those and one on
top, with loose stones round its foot. It is on the bank the trail turns away from, so it is in
view ahead, and its foot is `PLAY_CLEARANCE` off the trail's edge, so it is scenery, not an obstacle.

**How.** `gen_mountain_forest.gd`: `_on_wall_ice(x, z, r)` is `_material`'s wall-ice test, taken at
a footprint's centre and four points at its radius. The tree line, the wall forest, the shrubs,
`_scatter` and `_scatter_logs` all skip a spot where it holds. `_pile_stones` places a new type,
`stone_pile`, drawn with the boulder prefab (`PREFAB_OF`), with the upper stones raised by
their marker's Y. It starts at `STONE_PILE` (705 m) and steps down until the foot is clear of a
torch and of the ice. The fallen and lodged trunks still sink their ends into whatever bank
they meet.

**Verified**: `TestMountainForest` checks that no off-trail marker on a wall sits on ice, read off
the splat map the race draws, and that the pile is there and off the trail. The suite shows the
same three pre-existing failures. Rendered on Mobile with a carve run: at 01:09 the pile is on
the bank ahead.

### The sun sends rays through the air (2026-10-01) · **done, not seen in a real browser or on a phone**

**What.** Under a clear sun the bright sky round the disc is smeared out along lines from the sun,
so a trunk, a crest or the penguin in front of it throws a dark gap across the frame and the light
between reads as shafts (`SunShafts`, `sun_shafts.gdshader`). A setting: `[display] sun_shafts`,
the *Sun rays* row, on at High and Best, off below (`QualityPreset`); `--sun-shafts=on|off` /
`?sun-shafts=` and `SHOT_SUN_SHAFTS` for one run. Only under a look with `shafts` (sunny, evening)
and never under `sky = etr`.

**How.** Screen space, so on both renderers: Forward+'s volumetric fog is the only engine way to
real ones, and it would lay a second fog over the `FOG` every lit shader writes. One
`MeshInstance3D` quad whose vertex shader covers the clip square, last in the transparent pass,
on `NEAR_FIELD_LAYER` so the ice's probe and mirror leave it out. Each pixel walks 20 jittered taps
toward the disc and integrates the source along the way: open sky (cleared depth — sunlit snow is
as white as the air by the disc, so brightness alone cannot tell them apart), bright (display
luminance 0.7–0.96), within a Gaussian 0.18 of the height round the disc. Integrated, not
averaged — an average made every pixel by the disc pure source and swelled into a second glare —
then faded by distance (1/e at 0.42 heights). Added in display space: Compatibility blends display
values, Mobile linear light, so `to_output` takes the step there. A constant +0.1 checked it:
+25.5 levels on Mobile, +23 on Compatibility, flat over any background.

**Two things found on the way** (both in the trap list):
- **Compatibility's depth is reversed in 4.7 too.** The GLES3 scene clears depth to 0 and tests
  `GL_GEQUAL`; a `>= 1.0` sky test found no sky at all there and the pass drew nothing.
- **The pass was running for most of a run.** Riding straight the disc stands ~0.03 of the height
  past the right edge, and a fade reaching 0.3 past it ran the pass all the time for a beam of
  ≤ 7 levels in from the corner — and moved Bunny Hill's reference capture. The rays now fade in
  over the first 0.08 *inside* the edge (`SunShafts.EDGE_FADE`). Bunny Hill / `paddle` at frame
  250 is byte-identical on and off.

**Cost**, iGPU, Forest Trail with the sun held in frame for the whole run (a temporary sun
direction, not committed), 1024x576, vsync off, `--fixed-fps 60`, median `--print-fps`, two runs
each: Mobile 92 → 82 FPS (+1.3 ms), Compatibility 107 → 96 (+1.1 ms). One tap alone is 0.9 ms
on Mobile — the screen and depth copies and a full-screen pass — so the taps are the smaller part;
28 taps looked the same as 20 and cost 0.4 ms more. Nothing at all with the disc out of shot,
which with the sun 52° right of the fall line is most of a run.

**Verified**: `TestAtmosphere` (every look says `shafts`, only a clear procedural sun has them,
the fade is full in shot and zero just out of it where the racer rides straight), `TestConfig`
(default on, High still the defaults, every preset round-trips through the file,
`--sun-shafts=`/`?sun-shafts=`). The suite shows the same three pre-existing failures. Rendered on
Mobile and Compatibility with the test sun in shot over Forest Trail's trees: rays fan out from
the disc with gaps behind the crowns, and the two renderers look alike; Compatibility's faint
tails end sooner (8-bit blending drops increments under a level). With the real sun an AI run
brings the disc in at the top-right corner on right turns. The settings row loads, reads
"Sun rays:", and unticking it turns High into Custom. Not looked at in a browser, nor on a phone,
which starts at Medium and so has them off.

### The camera's motion blurs the frame (2026-10-01) · **done, not seen in a real browser or on a phone**

**What.** While the camera moves, the frame smears along each pixel's motion: the snow at the
bottom of the frame streaks past, near trees drag, a hard turn blurs the hillside sideways. The
racers stay sharp, and so do the HUD, the lens snow and flare, the falling snow, the spray and a
ghost (`MotionBlur`, `motion_blur.gdshader`). A setting: `[display] motion_blur`, the *Motion
blur* row, on only at Best (`QualityPreset`); `--motion-blur=on|off` / `?motion-blur=` and
`SHOT_MOTION_BLUR` for one run. Off at High because it changes every frame the camera moves in,
and High is the shipped frame every reference capture was taken of.

**How.** Camera motion only, because neither renderer hands a spatial shader a velocity buffer.
One clip-square quad on `NEAR_FIELD_LAYER` (the ice's probe and mirror leave it out), like the
sun's rays, but *first* in the transparent pass (`RENDER_PRIORITY_MIN`): it reads the screen copy
taken after the opaque pass and writes the smeared frame back over it, so everything transparent
is drawn afterwards, sharp. Per pixel: depth → view space (`INV_PROJECTION_MATRIX`; Compatibility's
NDC depth is `depth * 2 - 1`) → world → last frame's view (`previous_view`, from the script) →
this frame's projection (the lens only changes on a resize), and ten jittered taps along the
difference times a 180° shutter (`SHUTTER_SECONDS / delta`, so the smear is the same length at
any frame rate), capped at 0.035 of the height. Averaged in linear (squared under Compatibility,
whose copy is display values).

**The penguin.** Camera-only blur treats everything as standing still, and the chase camera
moves with the racer it watches: the first sketch would have smeared the penguin as hard as the
snow beside it. So each racer in shot — up to four, nearest first, all alike (the watched one is
not special-cased) — is a 0.75 m sphere round its body that carries the body's own displacement
since the last frame, and a tap whose racer share differs from the pixel's is down-weighted, so
the snow round the penguin does not pick it up and it does not pick up the snow.

**Hidden, and free**, whenever the camera's move this frame would smear under half a pixel, on a
pause (`RaceScene._process` calls `hold()`, so the first frame after it starts fresh) and on a
cut (≥ 4 m or 25° in a frame — a restart puts the camera back at the top).

**Sweeping a constant**: forcing a zero-length smear with the pass drawn gives a byte-identical
frame under Mobile. Under Compatibility it moves the frame by ±1 level (mean 0.23, max 7, in the
darks) — and so does a bare passthrough, so that is Compatibility's screen-copy path, which the
sun's rays already pay, not this shader. Compatibility captures are themselves byte-reproducible
run to run here, which is what made the residual visible. In the trap list.

**Cost**, iGPU, Bunny Hill `paddle`, 1280x720 logical (1600x900 physical), vsync off, no fixed
fps, mean `--print-fps` frame time, sun's rays off so the copies are charged to the blur:
Mobile 11.9 → 13.8 ms (+1.9), Compatibility 8.2 → 9.7 ms (+1.5). With the rays in shot the copies
are shared.

**Verified**: `TestCamera._motion_blur_reads_the_camera` (a still camera draws no pass, riding
smears under the cap, a turn smears its share of the lens times the shutter, a restart and a
quarter turn are cuts, the shader holds as many racers as the script hands it), `TestConfig`
(default off, `--motion-blur=`/`?motion-blur=`). The suite shows the same three pre-existing
failures. Rendered on Mobile and Compatibility, Bunny Hill `carve` at frame 250 and `paddle` in
heavy snow at 420: the two renderers smear alike, the penguin, flakes and HUD are sharp, the far
hill is near enough still. Not looked at in a browser, nor on a phone, which starts at Medium and
so has it off.

**Follow-up, same day: riding straight showed almost no blur.** At one 180° shutter a straight
run smeared only the near snow and the frame's edges by a few pixels — forward motion streams
out of the point ahead, where nothing moves — while a turn swept the whole frame. A five-times
shutter for everything gave the straight run its speed and turned a carve into a smudge. So
travel and turn are exposed apart (`TRAVEL_SHUTTER_SECONDS` 5/120 s, `TURN_SHUTTER_SECONDS`
1/120 s; `MotionBlur.exposed`), the cap is 0.1 of the height, and the shader spends a tap per
4 px of smear, 4 to 16. That smeared the penguin across a carve: the chase camera holds it still
by turning and travelling together, and the two no longer cancelled. The racers now open the
shutter at one exposure for both (`body_view`), with their own displacement, blended in by the
body share. Rendered on Mobile and Compatibility, Bunny Hill `carve` at 250 and `paddle` in heavy
snow at 420: the straight run streams the near snow and trees out of the frame, the carve keeps
the far hill readable, the penguin is sharp in both. Cost on Mobile, as above but measured over
the race only: 9.4 → 12.4 ms (+3.0, was +1.9 with ten taps over a 0.035 cap). Compatibility not
re-measured: `--disable-vsync` did not take there, and both runs sat at the display's 145 Hz.
`TestCamera` checks the two exposures (`exposed`: 2.5 frames of travel and half a frame of turn
back; one and one is the last frame's camera).

### Steep faces textured from the side, and real rock on Mountain Forest's walls (2026-10-05) · **done as a spike, not seen in a real browser or on a phone**

**Why.** On Mountain Forest's walls the heightmap is at its worst: one height per point every
half metre across X and Z is a vertex every 1.5 m up a 72° face, and the photographs were
projected straight down, so the rock was a smooth sheet streaked 2.4–3.2x down its fall. The
props on it (stones, a shrub) read as stuck on. Normal maps were not the answer — sunlit rock sits
at the illumination clamp (*Rock has grain*, above) — so what survives is geometry: silhouette,
cast shadow, occlusion, and the ledges' snow.

**Steep mapping** (`terrain.gdshader`, `Steep_Mapping`): past |n.y| 0.85 every non-snow layer is
also read on the ZY and XY planes, by the face's normal, and the side reads take over by 0.55.
No texture unit, no varying; gentler ground is the top projection exactly. `DEVIATION`.
`steep_mapping = 0` restores ETR's projection. It applies to every course, so the walls of the
imported ones change too.

**Rock faces** (`CliffSet`, `CliffBuilder`, `CourseData.cliffs`): see the deviation in AGENTS.md.
The face is generated with the course (`tools/gen_mountain_forest.sh` writes `cliffs.res`), drawn
by `TerrainRenderer` in the chunks' material, and read by the chase camera as a lift over the
heightmap. Props that would have stood on it are not placed, but spend their random draw and keep
their footprint, so the rest of the course is where it was: the regenerated course differs from
the committed one by one boulder, one shrub and three stones, all on the rock, and its splat maps
are byte-identical.

**Cost**, iGPU, Mobile, 1280x720, the camera pinned across the trail with the face filling half
the frame, GPU time over 400 frames: 6.12 ms bare; +0.24 steep mapping; +0.85 the face; 7.26
both.

**Verified**: `TestMountainForest._the_rock_faces` — 14k vertices stand out of the wall and 22k
are buried, none is in the play area, the nearest stands 2.69 m off the trail's edge (the play
area reaches 1 m), the camera's lift is over every standing vertex (worst 0.000 m under), and no
marker stands on the rock. The suite shows the three pre-existing failures (`lighting/what
project.godot ships`, two `props/forest floor`) and nothing new. Rendered on Mobile at the chase
camera (frames 600–700 with the AI driving) and from three pinned viewpoints, and one of those
under Compatibility: the beds, joints and ledge snow read on both, the rock's colour runs on into
the ground round it, and the near trail is lit as before.

**Follow-up, same day: the face made lean.** Three things the spike left, done:

- *Buried quads left out.* A quad whose four corners are all at the bottom of the mask lies
  wholly under the ground and is not written: 36 344 → 18 255 vertices. The edge quads that carry
  the rock down under the ground stay.
- *The ground under the rock left out of the terrain.* `CliffBuilder._add_holes` rasterises the
  face's triangles onto a half-cell grid and keeps the *lowest* rock over each sample; a heightmap
  quad whose nine samples all have rock ≥ 0.1 m over the drawn ground (the higher of the two ways
  a quad is split at its middle) is shut in — rock above, ground or rock wherever it runs out —
  and goes into `CliffSet.holes`, which `_build_chunk` skips. 2454 quads, 613 m². The rock no
  longer backs into the wall where it stands (`along` is held at ≥ 0.1 m), which is what lets it
  cover.
- *Compressed, with levels.* `Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES` (with dummy tangents, which it
  requires), and `ImporterMesh.generate_lods` per piece in the generator: 4–5 levels each, stored
  beside the mesh in `CliffSet.lods` and handed to `add_surface_from_arrays` when the renderer
  rebuilds the mesh with its colours. Generated with the course, not at load, so a template
  without the simplifier still gets them. `cliffs.res` 1 MB → 560 KB.

**Cost**, same pinned view and probe, three runs each: 7.26 ms before this, 6.92 after (−0.34).
The overdraw was less of the face's 0.85 ms than guessed; of the ~0.55 left, ~0.14 is its
shadow.

**Verified**: `_the_rock_faces` grows checks for all three — fewer buried vertices than standing,
every piece compressed with levels indexing its own vertices and each smaller than the piece, no
quad left out in or beside the play area, rock standing over every corner of every one, and the
chunk holding the first drawing exactly that many quads fewer. The suite: the same three
pre-existing failures. Rendered on Mobile from the chase-camera angle, close up, straight down
from 28 m, from the top of the wall looking down the face, grazing along its foot, and with the
levels forced coarse (`mesh_lod_threshold` 60); and straight down under Compatibility. No ground
shows through anywhere.

### Trees and props shade the ground round them: contact AO (2026-10-05) · **done, not seen in a real browser or on a phone**

The relief occlusion (`TerrainOcclusion`, 2026-09-24) knew nothing of what stands on the hill:
the snow at a boulder's foot, under a spruce's skirt or along a fallen trunk saw the same sky as
open piste, so on the web, with no shadow map, everything floated. `ContactOcclusion` bakes it
in at load and multiplies it into the relief's image before `TerrainRenderer` reads it, so the
terrain still reads one sky term in `COLOR.r`: no varying, no texture unit, no shader change,
nothing a frame. This was `editor-plan.md`'s Phase 6 *contact AO*, for the objects there are.

**How.** The same horizon measure as the relief's (cosine-weighted, `sin²` of each azimuth's
horizon, faded by distance), taken against the objects. Each is a solid of revolution on level
ground: a tree its species' crown profile (`TreeShadowBake.crown_radius`) at a per-species
opacity (conifer 0.85, bare 0.3, shrub 0.8); a ground-aligned prop the widest its mesh reaches
at each height, and a prop over 1.6x longer than wide (a log) a row of round solids each as wide
as it. A crown that starts above the snow leaves the band under it open: an azimuth loses the
sky between the solid's lowest and highest points. Being round on the level, a solid's loss is a
function of the distance from its axis alone, so it is one table per shape and size class
(`TreeShadowBake`'s 1.12 ratio) and one stamp, `blend_rect`ed into the relief's image. Out to
6 m past the outline. Left out: the slope (a solid stands on the level), the overhead trunk,
anything thin (flags, a bare tree's limbs), and the invisible colliders.

**What was found on the way.**

- *A vertex under a stone smeared black.* Inside a solid every azimuth is lost, and the terrain
  interpolates that vertex's black across the half-metre triangles round it, past the stone's
  edge. A vertex inside the foot now takes the foot's value; a prop's outline is closed down to
  the ground (each edge's crossing of y = 0 is sampled, and the bottom levels take the lowest
  measured one), or a sunk boulder had no foot at all.
- *The whole course a level darker.* Godot truncates a float to a byte and a half float sits
  just under most byte values, so the relief round-tripped through `RGBAH` came back a level or
  two low everywhere (trap list). The map is `RGBAF`, which round-trips every byte.
- *Slate shadows on the web.* At full strength the baked tree shadows, where the ambient is all
  there is, went slate grey beside every trunk. 0.6 of the loss is kept (`BOUNCE_KEPT`): the
  ground at a tree's foot is lit by the sunlit snow beside it, which a sky measure leaves out.

**Cost**, at load on the desktop: Bunny Hill (769 trees) 75 ms, `bronze_set` (8153) 120 ms,
`the_long_ride` 100 ms, Mountain Forest (2114 solids, 14 shapes) 140 ms, Forest Trail (7052)
170 ms — most of it the tables in GDScript. It prints one `CONTACT_AO` line per load. Not
measured in a browser.

**What it looks like.** Sunlit snow sits at ETR's clamp, so in the sun the term barely shows;
it lives in the shade. Mobile: tree bases and bushes get a soft blue ring, Forest Trail's
needle floor darkens under the crowns, Mountain Forest's wooded bank darkens. Compatibility: the
baked tree shadows deepen toward each trunk (`the_long_ride`). Measured A/B, 250 frames carving:
0.5–1.3 % of the frame moves by more than 8 levels (Bunny Hill 0.76 / 0.99 %, Forest Trail
0.50 / 0.53 %, Mountain Forest 1.07 / 1.30 %, Mobile / Compatibility), part of it the spray,
which never reproduces. Every reference capture with a
tree in shade moves.

**Verified**: `TestContactOcclusion` (27 checks): open ground far from anything is left alone;
a conifer is darkest under its crown, lighter at its edge and 3 m out, the same all round, and
a bare crown takes far less; a box-shaped prop is darker at its foot than a metre out and the
vertex under it carries the foot's value; a log is a row and shades along its length, not as a
disc; the relief is multiplied, to the byte where nothing stands, and the course's own image is
left alone; on `bronze_set`, Forest Trail and Mountain Forest it bakes one byte per vertex, never
lighter than the relief, leaves the overhead trunk and the colliders out, and is quick. The
suite: the same three pre-existing failures. Rendered A/B on Mobile and Compatibility on Bunny
Hill, Forest Trail, Mountain Forest and `the_long_ride`.
