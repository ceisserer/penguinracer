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

**0 failures** — 2293 assertions when the phase closed, 3254 today across physics, surface,
input, audio, the imported terrain library, the settings file and the character rig, in 0.9 s
headless. Per-force golden values are
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

Generated resources carry an `import_fingerprint` and re-import skips anything that no longer
hashes to it (2026-09-01). The `modified_in_editor` flag this replaces had been checked since
Phase 1 and never once fired — nothing ever set it — and terrain layers, the one place a designer
can tune a material from the Inspector, had no guard at all. See materials.md §6.

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

### Phase 4 — character · **rig and canned animations done; procedural layer not started**

`shape.lst` → a welded `ArrayMesh` of scaled spheres **skinned to** a `Skeleton3D` carrying ETR's
own joint names, and the four keyframe lists → an `AnimationLibrary` plus the root motion the
animations cannot carry. A recognisable Tux is on screen, he walks himself to the start line
before every race, and authored skinned glTF art drops in later against the same joint names.

The scene the importer writes is now a `CharacterRig`: skeleton, skinned mesh, `AnimationPlayer`,
and one `KeyframePath` per clip. The race scene owns the clock and asks the rig to pose itself at
a time; nothing about the character reaches back into the simulation.

**The start animation.** `CIntro` in the original, and the first thing the game does after a
course finishes loading: Tux stands 1.25 m across the slope and a metre behind the line, waddles
over in six steps, turns to face down the hill, drops onto his belly and the race begins. Four and
a half seconds; any key skips it, and the HUD says so. `r` mid-race does not replay it — the
original's Reset state re-enters Racing, not Intro. Scripted runs (`--auto-input=`, and anything
passing `--no-intro` or `?nointro=1`) never see it, which is what keeps every reference capture
where it was.

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

Still missing: the procedural additive layer (lean into turns, brace on brake, flap on paddle,
impact reaction on tree hit) — `AdjustJoints` in the original, which runs *over* the rest pose
during racing where the canned clips replace it. The finish, wonrace and lostrace clips are
imported and playable but not wired to anything; they belong with cups and the game-over screen.

### Phase 5 — game shell · **menu, course selection, settings and audio done; cups and profiles not started**

The first slice: picking what to race next. `scenes/course_menu.tscn` + `scripts/shell/course_menu.gd`
list all 44 courses with preview, author, length, slope and description, and hand the choice to
whoever is showing them. Esc opens and closes it mid-race; it comes back up 3 s after the finish
line with the time and herring count, so the next course is one keypress away.

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

Fog is why it exists now. `light.lst` ships `[fogstart] 0` for six of the eight presets, and the
two of those six that are sunny are what all 44 shipped courses select, so the original's haze
begins at the camera and the trees two lengths ahead are already washed toward white; the defaults here are 40 m of clear air and 2x the migrated range, i.e. 40–150 m where the
data says 0–75. **This reverses a correction made the same day** — a 2.5x stretch had just been
backed out as a wording-level "improvement" that removed the haze ETR's snow sits inside — and
the difference is that it is now measured and revertible. On Bunny Hill the mid-distance tree band
regains its contrast (5th percentile 143 → 65, clipping 19 % → 12 %) while the near field, which
is where the `ambient_energy`/`sun_energy` tone match was fitted, does not move at all
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
  `colBackgr` screen; opened over a running race, where dismissing it resumes the course behind
  it, the same rectangle is a translucent `colDBackgr` wash. That is `resumable` — the flag the
  menu already took to decide whether to offer Continue — deciding one more thing.
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
children, the five joints they all have, and a clip whose length matches its root motion) rather
than Tux's sixteen-bone list, which is only Tux's. 3389 assertions, 0 failures.

Verified end to end: all five race on Bunny Hill under `--character=`, natively on the GPU and in
Chromium through `?character=beastie` against the `WebOneCourse` export. The previews are ETR data
art and go into the licence audit with the rest of the imported assets.

Not done, and none of it started: cups and events (the resources are imported and unused),
medals from the migrated thresholds, and save profiles — the player half of `CRegist` waits on the
last of those. Sound and music volumes and the language are ETR's `options.txt` keys that this
file and this screen still do not carry.

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
- **The game shell stops at free course selection** (Phase 5): no cup progression, medals or save
  profiles. The migrated event thresholds are sitting there ready; the translations are wired up.
  The settings screen moves the six keys the file has and not the three ETR's own configuration
  screen also has — sound volume, music volume and language. The screens carry the original's
  palette but none of its menu art — corner ornaments, title logo, drifting `ui_snow` — which is
  blocked on the licence audit below.
- **All five characters are the importer's welded-sphere placeholders**, and only Tux's has been
  looked at joint by joint. The other four render, animate and carry their own clips, and the
  suite checks the contract they share; nobody has compared Trixi's start animation against the
  original frame by frame. The procedural layer (`AdjustJoints`) is unwritten for all of them,
  and every character has identical physics — which is true in ETR too, `characters.lst` carries
  no per-character constants and `[type]` is a column nothing reads.
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
- **A terrain material has two authored shading knobs and no more** — `roughness` and `uv_scale`,
  both added 2026-09-01 when the dead `normal`/`roughness` texture slots came out. Everything else
  the shader does to snow and ice is course-global, and per-layer normal maps are out of reach
  under Compatibility: the terrain shader already binds 13 of WebGL2's guaranteed 16 fragment
  texture units. materials.md §5 has the arithmetic and the extension point.
- **Asset licence audit not started** (risk S5). Independent of engineering, long lead time,
  blocks Phase 5.
- **Two terrain layers import with no albedo**, because `terrains.lst` names a texture that is
  not in the tree: `pave04` wants a `pave04.png` nobody shipped and `snowy_hockey_ice` writes
  `snowy_ice02` without the extension. Untextured in the original too, and no shipped course
  paints either colour key, so this is a note rather than a bug — the importer warns.
- **`[starttex]`, `[tracktex]` and `[stoptex]` are still unported.** They are the original's
  trackmark decal atlas indices, and the GPU trail map replaced the thing they index. Nothing
  needs them; listed so the gap in `terrains.lst` coverage is deliberate.
