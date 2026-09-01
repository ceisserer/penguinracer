# PenguinRacer — build progress

Companion to [`godot-port-plan.md`](./godot-port-plan.md). What exists today, and what is
knowingly missing.

How it got here — the two de-risking spikes in full, and the seventeen things the plan did not
know — moved to [`history.md`](./history.md). The distilled version of the same lessons, the one
worth reading before touching the code, is the trap list in [`AGENTS.md`](./AGENTS.md).

---

## Risks

| Risk | State |
|---|---|
| **S1** ping-pong `SubViewport` render targets on web | **PASS** — verified numerically, native and Chromium/WebGL2. Firefox untested: no GPU here. |
| **S2** GDScript ODE23 substep loop | **PASS with margin** — 0.045 ms/frame native, 0.073 ms in-browser (0.44 % of a 16.7 ms budget). The godot-rust GDExtension contingency should not be built. |
| **S3** heightmap dequantization per course | open — see Known gaps |
| **S4** RGBA8 snow trail banding | open |
| **S5** asset licence audit | open — see Known gaps |
| **S6** web cold-load size | open — see Known gaps |

Both closed spikes are written up in [`history.md`](./history.md), including what S2's headroom
was actually bought with — two deviations that are load-bearing and should not be undone.

---

## Built

### Phase 0 — physics core · **done**

`game/scripts/physics/` — `RacePhysics` is a plain `RefCounted` with zero node dependencies,
stepped against a `SurfaceProvider`. Every force from etracer.md §4.1 is ported: gravity, the
piecewise spring normal force, jump, steering-rotated friction, brake, Reynolds-table air drag,
paddle, and the roll normal. ODE23 (Bogacki–Shampine) with adaptive stepping, retry and the
`MAX_STEP_DIST` cap. Trees and herring go through a uniform spatial grid, fixing the original's
O(items) scan per substep.

**0 failures** — 2293 assertions when the phase closed, 2921 today across physics, surface,
input, audio and the imported terrain library, in 0.9 s headless. Per-force golden values are
worked out by hand from the constants — air drag at 20 m/s, each of the three spring bands, the
400 N lateral friction cap, the 30°/55° bank angles, the paddle's fade to nothing at 60 km/h — so
a change in feel shows up as a test failure rather than as a vague complaint. Whole-simulation
tests cover terrain following, steering symmetry, bounds (including the new polygon play area),
items, trees, the finish, determinism under a replayed input trace, and stability at 10 fps.

Deviations from the original are marked `DEVIATION` in the source, each with a reason. The
finish sequence keeps real gravity instead of the original's flat 500 N hack.

### Phase 1 — importer and first drivable course · **done**

`game/addons/etr_import/` — one-way and re-runnable, driven by `tools/import_all.sh`.
**All 44 courses import**, along with 43 terrain layers, 14 object prefabs, 8 environment
presets, 5 characters, the event/cup tables and 111 strings × 13 languages.

- `elev.png` → float32 local relief, Catmull-Rom upsampled ×2 with an edge-preserving bilateral
  pass; the global slope stays analytic in `CourseData.base_angle`.
- `terrain.png` → authored splat weights, one-hot then boundary-blurred, capped at 8 layers.
  No surveyed course exceeds the cap.
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

`bunny_hill` is drivable end to end with chunked terrain, splat-blended PBR, instanced trees,
herring pickups, the chase camera and a HUD — **including in a browser**. The Phase 1 exit
criterion is met: a `WebOneCourse` export loads and runs bunny_hill under Chromium/WebGL2,
streaming 21 terrain chunks, on a 6.6 MB pck. Long courses work too — `wild_mountains`
(100×1000) runs, and the per-course pck size is the shape Phase 6's streaming needs.

### Phase 2 — rendering · **partial**

`game/scripts/render/` + `game/shaders/` — chunked terrain with splat-blended PBR, instanced
course objects on a cylinder-shaded billboard, the migrated three-quad skybox, per-environment
fog and light, and a HUD. Snow and ice carry two octaves of procedural micro-relief, a crystal
glint built from per-texel facet normals, and a Fresnel sky reflection on ice.

Tone is matched to the original on Bunny Hill under `tuxracer_sunny`, at both ends of the range,
by fitting `EnvironmentPreset.ambient_energy` and `sun_energy` together against two measured
points on one captured frame. That fit is the subject of history §11, and reading it before
touching a light value will save re-deriving why the obvious experiments do not work: the
ambient the data means is not the ambient Godot applies by default, and turning one light off to
isolate a term gives two frames that do not sum to the whole.

No LightmapGI bake. The remaining gaps — seven untuned environments, the cyan channel, the
camera framing — are in Known gaps below.

### Phase 3 — snow · **mechanism proven, integration partial**

Both halves of the dual representation exist and are wired in:

- `SnowFieldGPU` — ping-pong `SubViewport`s, 1024² over a 64 m toroidally-scrolled window,
  stamped and decayed by one fragment pass per frame. Verified by S1.
- `SnowField` — the CPU mirror, 128² over the same window, read by `HeightmapSurface.sample()`.

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

### Phase 4 — character · **placeholder done**

`shape.lst` → a welded `ArrayMesh` of scaled spheres plus a `Skeleton3D` carrying ETR's own joint
names, and the four keyframe lists → an `AnimationLibrary`. A recognisable Tux is on screen now,
and authored skinned glTF art drops in later against the same joint names.

### Phase 5 — game shell · **course selection and audio done, rest not started**

The first slice: picking what to race next. `scenes/course_menu.tscn` + `scripts/shell/course_menu.gd`
list all 44 courses with preview, author, length, slope and description, and hand the choice to
`RaceScene`, which swaps the course in place through the `load_course` path that already existed.
Esc opens and closes it mid-race; it comes back up 3 s after the finish line with the time and
herring count, so the next course is one keypress away.

Three decisions worth keeping:

- **The menu draws over the running race rather than replacing it.** Plan §4.1 puts the shell
  above the race scene; the course-select screen is a `CanvasLayer` inside it instead. The course
  behind the panel stays loaded and rendered, so opening the menu costs nothing, closing it
  resumes exactly where the player was, and `--capture`/`RACE_READY` keep working unchanged.
  A screen that has to exist before any course is loaded — a title screen, cup selection — will
  want the plan's arrangement; this one did not.
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

`-- --no-audio` gates the whole thing, for capture runs where a soundtrack is only a slow start.
Volumes are the original's `param.sound_volume` 90 / `param.music_volume` 20 and live on the
director; there is no options screen to move them from yet.

Not done, and none of it started: cups and events (the resources are imported and unused),
medals from the migrated thresholds, save profiles, settings.

## Known gaps

- **The near-field terrain mesh is too coarse for the trench to read as geometry.** Chunk
  vertices sit ~0.5 m apart; the contact patch is 0.45 m wide. Lighting sells the trench
  (normals are reconstructed per fragment from the trail map) but the silhouette does not move.
  Plan §4.4 already anticipates this — "only chunks inside the deformation window need the
  displacement path" — so the fix is a denser mesh for those chunks.
- **Web cold load is 161 MB** (128 MB pck), because the export bundles all 44 courses. Risk S6,
  Phase 6: stream per course, compress, load music on demand.
- **The snow is a channel too cyan.** Red matches the original within two levels at both ends,
  but green sits about seven over on lit snow (255 against 248) because ETR's `[diff] 1.0 0.9 1.0`
  is a display-space multiplier and Godot sRGB-decodes it to 0.787. A third fitted scalar would
  close it; so would migrating the light colours through `linear_to_srgb`, at the cost of the
  generated presets no longer matching `light.lst` on sight.
- **The snow is tuned against one frame of one course.** Bunny Hill under `tuxracer_sunny` now
  matches the original at both ends of its range (history §11, still true after §12), but the fit
  is two scalars solved on two surfaces in one screenshot. The other seven environments — the
  three `etr` skyboxes are 1024² and much brighter, and `night` and `evening` invert the balance
  between sun and ambient — have not been compared against anything. Same method, one reference
  capture each.
- **The camera does not frame the course the way the original does.** `race.tscn` uses a 70°
  vertical FOV where `param.fov` is 60, and `ChaseCamera` sits 19° above the slope plane where
  `view.cpp` puts it at `CAMERA_ANGLE_ABOVE_SLOPE`/`PLAYER_ANGLE_IN_CAMERA` = 10°. Both are
  one-line changes; together they are why a side-by-side still looks different after the shading
  matches — ours shows a third less sky. Left alone because it changes how the game plays, not
  how it looks, and that is a design call rather than a fidelity one.
- **The game shell stops at course selection and sound** (Phase 5): no cup progression, medals,
  save profiles or settings. The migrated event thresholds are sitting there ready; the
  translations are now wired up.
- **The terrain slide sound is on or off**, because the original's speed-and-lean `SlideVolume`
  ships commented out (history §16), and 12 of the 43 terrains — `snow` among them — name no
  sound at all. Both are faithful and both are the obvious first thing to improve; the mapping is one
  `StringName` per terrain resource and the volume is one call in `RaceScene`.
- **Web cold load gains 18 MB of audio** on top of the 161 MB, and music is the easiest part of
  the pack to stream rather than bundle — 14 MB of it, none needed before the first frame.
- **Heightmap dequantization has not been eyeballed per course** (risk S3). The pipeline runs on
  all 44; three courses of differing character should be compared against original screenshots.
- **The snow and ice shading terms are tuned by eye, not against a reference.** Unlike the tone
  fit, history §12's relief amplitudes, glint sharpness and ice albedo have no measured target —
  the original has no equivalent to measure against. They are all uniforms with the neutral value
  documented, so backing any of them out is a one-line change.
- **`wind_direction` is a shader constant, not course data.** Every course's sastrugi run the same
  way. It wants to come off the environment preset, or at least be seeded per course.
- **Asset licence audit not started** (risk S5). Independent of engineering, long lead time,
  blocks Phase 5.
- **Two terrain layers import with no albedo**, because `terrains.lst` names a texture that is
  not in the tree: `pave04` wants a `pave04.png` nobody shipped and `snowy_hockey_ice` writes
  `snowy_ice02` without the extension. Untextured in the original too, and no shipped course
  paints either colour key, so this is a note rather than a bug — the importer warns.
- **`[starttex]`, `[tracktex]` and `[stoptex]` are still unported.** They are the original's
  trackmark decal atlas indices, and the GPU trail map replaced the thing they index. Nothing
  needs them; listed so the gap in `terrains.lst` coverage is deliberate.
