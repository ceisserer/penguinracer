# AGENTS.md — PenguinRacer

Godot 4.7 rebuild of **Extreme Tux Racer 0.8.4**: downhill penguin racing with the original's
physics model and real snow deformation. Ships to **web (WebGL2 / Compatibility)** and **desktop
native (Vulkan / Mobile renderer)** from one project; both targets matter equally. Two renderers,
one project — see architecture rule 2 and [RenderBackend].

**This is a rebuild, not a port.** Only the physics model is translated faithfully (constants are
the game). Everything else is redesigned; original content is imported into the new shape.

## Source documents

| File | Use it for |
|---|---|
| `etracer.md` | What the original C++ does. §4.1 = physics constants (authoritative), §5 = legacy file formats. |
| `godot-port-plan.md` | Architecture, data model, phases, risks. |
| `PROGRESS.md` | What is built today, and the known gaps. The running log. |
| `history.md` | How it got here: the two spikes in full, and the nineteen things the plan did not know. Settled — read it for the reasoning behind a decision, not for current state. |
| `materials.md` | How a terrain material works: `terrains.lst` → `TerrainLayer` → friction on the CPU and shading on the GPU, why there are 43 records and not three, and what the editor can and cannot author. |
| `README.md` | Commands, prerequisites, layout. |

Keep all six current when you change things. State goes in `PROGRESS.md`; once a piece of it is
settled and only the reasoning is still worth having, move it to `history.md` and leave the
distilled lesson in the trap list below. Corrections to the plan go in `godot-port-plan.md`
marked with a date.

## Layout

```
game/                     Godot project (project.godot; mobile on the desktop,
                          gl_compatibility on the web)
  scripts/physics/        RacePhysics + surface + snow — plain RefCounted, zero node deps
  scripts/course/         CourseData, TerrainLayer, prefabs, events, environments
  scripts/render/         terrain chunks, GPU snow field, spray, and IceReflection —
                          the planar mirror pass the ice samples the racers from
  scripts/camera/         chase camera        scripts/shell/  main menu, course menu,
                                                              settings screen, HUD
  scripts/race/           RaceScene (the tick loop and the course) + RacerRoster
                          (who is on the hill, and who is winning) +
                          IntroSequence (the start animation) + the racer
                          layer: Racer + SimulatedRacer +
                          PlaybackRacer, RacerState (the 18-float snapshot that is
                          also the ghost file format and the wire format),
                          RacerStateStream, InputSource and its kinds — including
                          AIInputSource + AISkill, the computer opponents —
                          RaceSetup (practice or a field of 1..9),
                          RaceRecording + RaceRecorder + SavedRunStore + RaceOutcome
  scripts/net/            RaceNetwork autoload (`Net`) — ENet session, snapshot RPCs
  scripts/character/      CharacterRig + KeyframePath — the rig the importer writes
                          and the root motion a keyframe animation cannot carry —
                          plus CharacterCatalog/CharacterListing, the generated
                          index of the five playable characters
  scripts/audio/          AudioDirector autoload + generated sound/music banks
  scripts/config/         GameConfig autoload — the player's settings file —
                          plus RenderBackend, which renderer is running and the
                          one thing that follows from it (shadows) —
                          plus LaunchArgs, the command line and the URL query
                          parsed once into one list, DisplayModes, the window
                          sizes the settings screen offers for the display it is
                          actually on, and PackStream, which
                          fetches a course or the music pack on a web build
                          that streams them (risk S6) and is a no-op
                          everywhere else
  scripts/debug/          DebugCapture autoload (headless screenshots / scripted input),
                          key_log (what a remote desktop is doing to the keyboard)
  shaders/                terrain (splat + snow/ice shading), etr_skybox,
                          object_billboard (items), object_cross (trees),
                          snow_trail, s1_displace, and
                          etr_illumination.gdshaderinc — ETR's sum-ambient-and-
                          sun-then-clamp, included by everything that is lit
  addons/etr_import/      one-way, re-runnable importer from the ETR data tree
  courses/<name>/         GENERATED: course.tres, course.tscn, heightmap.res, splat_*.png
  resources/  i18n/       GENERATED: layers, prefabs, environments, events, course
                          catalog, character catalog + the five rigs and their
                          previews, sound bank + music library, 13 translations
  assets/sounds|music/    GENERATED: the 10 effects and 10 pieces, copied verbatim
  scenes/                 main_menu.tscn (the main scene), course_menu.tscn,
                          character_menu.tscn, settings_menu.tscn, ghost_menu.tscn,
                          race.tscn, results_menu.tscn, key_log.tscn
  user://runs/            NOT in the repo: every run the player named and kept from
                          the results screen, written by SavedRunStore and — when
                          one is chosen from the main menu's Race against ghost
                          list — replayed as a translucent second penguin
  themes/                 etr_menu.tres — ETR's `common.cpp` palette as a Godot
                          theme, and the checkbox icons it binds
  tests/                  headless suite (physics, surface, input, audio, imported
                          terrain library, environment presets, course objects,
                          character rig, chase camera, racer layer, computer
                          opponents) + ODE
                          benchmark + tone_report.gd, which is not a test
  spikes/s1_pingpong/     ping-pong render-target spike (risk S1)
  spikes/s7_reflection/   planar reflection spike (S7): which of the two ways to
                          mirror works here, and what Fresnel costs
etr-0.8.4/                original source + data — READ-ONLY, never write here
tools/                    import_all.sh, shot.sh (deterministic screenshot, real GPU
                          when there is one),
                          png.py + regionstats.py + linstats.py (compare a
                          capture against a reference numerically — pure Python
                          and minutes per frame; `tests/tone_report.gd` is the
                          same statistics in about a second),
                          webtest/ (COOP/COEP server + puppeteer runner),
                          gen_course_export_presets.py + build_web_streamed.sh
                          (the streamed web export, risk S6)
```

Generated trees (`game/courses/`, `game/resources/`, `game/assets/`) are committed. Re-running the
importer rewrites every `course.tscn` and `.tres` with fresh random node/sub-resource ids even
where nothing changed, so check what a re-import actually altered before committing 116 000 lines
of churn:

```bash
git diff -U0 -- 'game/courses/*/course.tscn' \
    | grep '^[-+]' | grep -v '^[-+][-+][-+]' | grep -v 'unique_id='
```

Empty output means the scenes only churned ids — `git checkout` them and commit what is left.

## Commands

```bash
godot --path game                                                  # play (opens on the main menu)
godot --path game -- --course=bunny_hill                           # ... skip it, race that course
godot --path game -- --character=trixi                             # ... as one of the other four
godot --path game -- --remote-keyboard                             # ... over a pulsed remote keyboard
godot --path game -- --no-audio                                    # ... silent, for captures
godot --path game -- --no-intro                                    # ... skipping the start animation
godot --path game -- --host --course=bunny_hill                    # ... hosting a session (ENet, desktop only)
godot --path game -- --join=127.0.0.1 --course=bunny_hill          # ... joining one
godot --path game res://scenes/key_log.tscn                        # what the link does to the keyboard
godot --headless --path game --script res://tests/run_tests.gd     # physics suite + benchmark
godot --headless --path game --script res://tests/tone_report.gd \
    -- shot.png 1.0 lit:100,620,500,715                            # per-region tone of a capture
godot --path game spikes/s1_pingpong/s1_spike.tscn                 # snow RT spike
godot --path game spikes/s7_reflection/s7_spike.tscn               # planar reflection spike

./tools/import_all.sh [--course=bunny_hill] [--force]              # 4-pass importer

# headless verification without a display
godot --path game -- --capture=/tmp/shot.png --capture-frames=200 \
    --auto-input=carve --camera=above --course=wild_mountains

# web — streamed build: base + one .pck per course + one for music
./tools/build_web_streamed.sh
node tools/webtest/server.js build/web 8060 &
node tools/webtest/run_web_test.js \
    "http://127.0.0.1:8060/index.html?course=bunny_hill&nointro=1" /tmp/web.png RACE_READY
```

Settings live in `user://penguinracer.cfg` — on Linux
`~/.local/share/godot/app_userdata/PenguinRacer/`, written with its comments on first run.
Window size, render scale, whether ice reflects the racers, whether anything casts a shadow, fog
distance, the size and skill of
the computer field, and the two multiplayer keys; delete it to get the defaults back. The main menu's **Configuration** screen
moves the seven a player can act on — `[multiplayer] player_name` and `port` are file-only until
there is a lobby, and `opponents`/`opponent_skill` are set from the course screen instead, where
the choice is actually made — and writes the same commented file back. The resolution row offers
the display's own modes (`DisplayModes`, filled from `DisplayServer` at open time), not a fixed
list, and the resolution and fullscreen rows are hidden on the web build, where the page sizes the
canvas and `apply_display` ignores both. The shadows row is hidden for the same reason wherever
`RenderBackend.supports_light_shadows()` is false — the browser, and a desktop run started with
`--rendering-method gl_compatibility` — but the value is still written back, so a preference set
on the desktop survives a session in a browser. Whether a ghost is drawn is
no longer a setting: it is whichever saved run the player chose from the main menu's **Race
against ghost** list, or none.

Export presets: `Web` (the streamed base — engine, shell, all 44 previews, no course internals
or music), one generated `Course_<dir>` per course, `MusicPack`, `WebSpike`. The generated
presets are owned by `tools/gen_course_export_presets.py`, re-run whenever a course is added,
removed or renamed; `tools/build_web_streamed.sh` drives the whole build.
The test server must set COOP/COEP and `.wasm`/`.pck` MIME types or the export fails obscurely.
Prerequisite: Godot 4.7.2 on `PATH` as `godot`, plus export templates for web. The desktop build
needs **Vulkan** now that it runs the Mobile renderer; the web build needs nothing new. Checking
what the browser will do without opening one is a flag:

```bash
godot --path game --rendering-method gl_compatibility --rendering-driver opengl3
                                                                   # ... as the web build renders it
SHOT_METHOD=gl_compatibility SHOT_RESOLUTION=1024x576 tools/shot.sh /tmp/web-look.png
                                                                   # ... and captured, at a true 1280x720
```

`SHOT_METHOD` is `mobile` (the desktop default, Vulkan), `gl_compatibility` (what the browser
runs) or `forward_plus`; the driver follows it. There is no software Vulkan in this image, so the
llvmpipe fallback can only serve Compatibility — `shot.sh` says so rather than quietly capturing
the wrong renderer.

`tools/shot.sh` renders on the container's real GPU (Wayland socket + `/dev/dri/renderD128`),
which needs `libegl1 libegl-mesa0 libdecor-0-0` installed; without them Godot reports it as
"your video card drivers seem not to support the required OpenGL version" and silently falls
back. 120 frames of Bunny Hill: ~3 s on the GPU, ~2 min under llvmpipe. `SHOT_FORCE_SOFTWARE=1`
takes the slow path, which is worth doing before trusting a small tone measurement.

## Current state

| Phase | State |
|---|---|
| 0 — physics core | **done** — every §4.1 force, ODE23 adaptive, spatial grids. 4096 assertions, 0 failures, 3.9 s headless. |
| 1 — importer + first course | **done** — all 44 courses, 43 layers, 14 prefabs, 8 environments, 5 characters, events, 111 strings × 13 languages. bunny_hill drivable in a browser; wild_mountains (100×1000) runs. |
| 2 — rendering | partial — **two renderers**: Mobile on the desktop, Compatibility on the web, split because a shadow-casting light under Compatibility is drawn in an sRGB-blended second pass (trap list). Every lit shader reproduces ETR's illumination clamp; the desktop additionally gets a PSSM directional shadow the original has no equivalent for. Splat PBR, chunked terrain, instanced course objects (trees are the original's two fixed planes at 90°, turned by a hashed yaw so a grid-placed forest does not share them; items are billboards), HUD, migrated skyboxes. Tone matched to the original on Bunny Hill at both ends of the range and in all three channels; no LightmapGI bake. Snow and ice carry procedural micro-relief, a twinkling crystal glint and a Fresnel sky reflection, and the ice reflects the racers standing on it — a planar mirror pass (`IceReflection`) the ice branch samples in place of the sky where there is a penguin. The carve spray draws ETR's textured, growing, fading puffs on a redrawn atlas. |
| 3 — snow | mechanism proven, integration partial — GPU trail map + CPU mirror both wired; a carve leaves a track with a shaded trench, a self-occluded floor and a bright ploughed lip. |
| 4 — character | **done for all five characters** — welded ArrayMesh from `shape.lst` **skinned** to a Skeleton3D with ETR joint names, the four keyframe lists as an AnimationLibrary plus a `KeyframePath` of root motion each, the pre-race start animation (`CIntro`) wired into the race, the finish-line clip (`finish`/`wonrace`/`lostrace`, chosen by `RaceOutcome.clip` — see the game shell row) wired into the results screen, and the racing pose layer (`AdjustJoints`) on `CharacterRig.adjust_joints` — flippers out to brake and the inside one out through a turn, a stroke through them while paddling, a flap on a jump, legs that tuck with speed and brace against the ground, a tail and a head that follow the lean. It runs off a `RacerState` and nothing else, so a ghost and a remote peer animate too. Tux, Trixi, Boris, Samuel and Beastie each carry their own shape and their own clips; `resources/characters.tres` indexes them and `GameConfig.character` picks one. Both canned clips are played the same way — the `Animation` for the joints and the `KeyframePath` for the body — because in both of them the body is where the animation is: `finish.lst` opens lying on the belly and stands the penguin up entirely on node 0. See the trap list. |
| 5 — game shell | partial — `main_menu.tscn` is the main scene: Practice opens the course list, *Race the computer* opens the same list with a field of 1–9 opponents behind it, *Race against ghost* opens a list of every saved run (`ghost_menu.tscn`), Configuration edits `penguinracer.cfg` graphically, and a race is a scene the shell hands over to and takes back. A finished race brings up `results_menu.tscn` over the course — time, herring, the `wonrace`/`lostrace`/`finish` clip playing, and a name field to keep the run — before the ordinary course menu takes over. `character_menu.tscn` is the character half of `CRegist` — arrows over a framed name with the migrated 128x128 preview under it. Every screen wears `themes/etr_menu.tres`, so the shell reads as the original's: the flat `colBackgr` blue, white text, `colDYell` on whatever has focus, square white-outlined frames. Generated course and character catalogs, 13 languages wired to `tr()`, audio (10 effects + 10 pieces + 3 racing themes on an `AudioDirector` autoload that reproduces ETR's one-voice-per-cue mixer). No cups, medals or profiles (data is imported and waiting; the player half of `CRegist` waits on them); no volume or language controls on the settings screen; none of ETR's menu art (corner ornaments, title logo), which waits on the licence audit. |
| 6 — polish/ship | not started. |
| computer opponents | **done** — beyond the original, which has nobody on the hill. `RaceSetup` is the whole mode switch: 0 opponents is Practice and 1–9 is a race, chosen on the course screen and remembered in `penguinracer.cfg`. An opponent is a `SimulatedRacer` driven by an `AIInputSource` — the seam the racer layer was built for, used with no change to it. It plans an aim point every `AISkill.plan_interval` ticks by scoring nine candidate lines against trees, the play bounds, swerve cost, its own lane, the friction ahead, herring and the other racers. **The three levels move driving habits and never the physics**: lookahead, reaction, nerve, how long they paddle, how readily they brake. Measured over 30 s of a 22° slope: easy 231 m, medium 333 m, hard 422 m, a player holding the accelerator straight 413 m. Deterministic — the only randomness is a per-seat personality drawn once from a seed. Opponents are solid: everyone on the hill bounces off everyone else through the shared `RacerField` (see the deviations), which is why the steering term only has to keep them out of each other's way rather than out of each other. No jumps, no tricks, no cups. |
| multiplayer foundation | seams built, ghosts working, network scaffold desktop-only — beyond the original, plan §8.4. The simulation runs on a fixed 60 Hz tick with interpolated presentation; `RaceScene` owns a list of `Racer`s, split into `SimulatedRacer` (a `RacePhysics` fed by an `InputSource`) and `PlaybackRacer` (a `RacerStateStream` read by time). Ghosts are finished end to end: every run is recorded, and a finished race brings up a results screen (`ResultsMenu`) where the player can name it and keep it (`SavedRunStore`, `user://runs/`, one file per save — nothing is written automatically any more). The main menu's **Race against ghost** entry (`GhostMenu`) lists every saved run and racing one draws it translucent with the gap in seconds on the HUD. `Net` hosts/joins an ENet session over `--host`/`--join=` and each peer broadcasts 20 snapshots a second. A peer is a body like any other — the local player collides with it against the snapshot stream, and the machine that owns it resolves the same contact from its side. No lobby, no countdown, no web (ENet is UDP). |

### Spikes

- **S1** ping-pong `SubViewport` RTs on web — **PASS** native + Chromium/WebGL2, numerically
  verified. Firefox untested (no GPU in this container; it refuses WebGL2 under software rendering).
- **S2** GDScript ODE loop — **PASS with margin**: 0.045 ms/frame native, 0.073 ms in-browser
  (0.44 % of 16.7 ms). **The godot-rust GDExtension contingency should not be built.**
- **S7** planar character reflection under Compatibility — **PASS** native, and it settled the
  design. A `SubViewport` sharing the main `World3D` with a determinant −1 camera renders
  identically to a mirrored duplicate in a world of its own, and the renderer flips the winding
  itself (`CULL_BACK`/`FRONT`/`DISABLED` all measure the same), so `IceReflection` carries no
  duplicate rigs and character materials are untouched. It also measured the thing that shaped
  the shader: the Fresnel weight at chase-camera incidence is 0.02–0.09, so the reflection had to
  *occlude* the sky ramp rather than add to it. **Web untested** — no browser GPU in this
  container — which is the one open risk on the feature.
- **S3–S5** open: dequantization eyeball per course, RGBA8 snow banding, asset licence audit.
- **S6** web cold-load size — **done**: `tools/build_web_streamed.sh` builds a slim base
  (engine + shell + all 44 preview thumbnails, ~65 MB against the old 161 MB) plus one `.pck`
  per course (268 KB–9.2 MB) and one for music (14 MB), fetched and mounted at runtime by
  `PackStream` only when a course is chosen or a track first plays. See Commands and the
  `game/scripts/config/pack_stream.gd` doc comment.

### Known gaps

- Near-field terrain mesh too coarse (~0.5 m vertices vs a 0.45 m contact patch) — the trench reads
  in lighting but not in silhouette. Fix: denser mesh for chunks inside the deformation window.
  `Racer._drawn_snow_lift` is the standing compensation for it and comes out when it is fixed.
- The terrain slide sound is on/off with no speed term, and 12 of the 43 terrains (including
  `snow`) name no sound — both faithful, both the obvious first improvement. See the deviations.
- Snow tone is matched on one course under one environment (Bunny Hill / `tuxracer_sunny`).
  All 44 shipped courses select a *sunny* preset — 40 `etr_sunny`, 4 `tuxracer_sunny`, and the
  two carry identical light values — so the fit reaches every course that ships. The
  evening/night presets are a different matter and the display-space fix moved them **the wrong
  way**: undoing an sRGB decode raises a dark value far more than a bright one, so night's
  `[amb] 0.2` went from a shaded snow of about 45/255 to about 105/255 against the original's
  47. Nothing selects them, so nothing regressed; anything that starts to will need its own
  fitted `sun_gain`/`ambient_gain` pair, which is what those fields being per-preset is for.
  The snow/ice/roughness tables now cover all eight splat layers.
- The lit near field still clips more than the original's. After the fit both measured surfaces
  match within a level in all three channels, but our lit region's *upper half* runs about six
  levels over ETR's (median G 254 against 248, so 53 % of it clips where ETR clips 3.5 %). Not
  chased further because the reference frame and ours are not the same view — ETR's is at 25
  km/h on undisturbed snow, ours at 44 km/h over a fresh trench, and the camera is 70° FOV at
  19° above the slope against the original's 60° at 10°. Closing it wants a reference capture
  taken at a matched camera, not another scalar.
- **The character is the one lit surface with no illumination clamp**, and it is a three-part job
  rather than a missing include. `shape.lst` gives every part a `[diff]` in *display* space
  (Tux's `blackcol` is 0.1) and the importer stores it as a linear vertex colour, so his back
  reads 89/255 where ETR reads 26 even with the illumination on the ceiling; and ETR gives the
  character a real `[spec]`/`[exp]` per material, which is where the form on his sunlit side
  comes from and which this build has never had. Clamping alone would pin everything above
  `ndl` = 0.21 flat and take the gradient away without giving the highlight back — **half of this
  is worse than neither**. The three together are: `srgb_to_linear` on the migrated colours, the
  include, and a specular lobe; measured, they land the back at 22 against ETR's 26 and the belly
  at 199 against 199. It needs a `character.gdshader` (plus a transparent variant, since
  `Racer.make_translucent` duplicates a `StandardMaterial3D` today) and a re-import of the five
  rigs.
- Ice is 16 levels darker under Compatibility than under Mobile (`tuxway`, mid-lake: 160.5 R
  against 176.6) after the `EMISSION` half of it was fixed — see the trap list. The residual is
  somewhere else in the ice branch and has not been chased; snow, which is most of every course,
  agrees to within a level.
- Asset licence audit not started — blocks Phase 5, long lead time.

## Architecture rules

1. **`RacePhysics` has zero node dependencies.** Plain `RefCounted` stepped against a
   `SurfaceProvider`. This is what makes headless golden tests possible — do not break it.
2. **Two renderers, and the web one is the floor.** The desktop runs **Mobile** (Vulkan) and the
   web runs **Compatibility** (WebGL2), which is the only thing a browser offers. Nothing may
   *depend* on a feature Compatibility lacks — no compute shaders, no `RenderingDevice`, no HDR
   (RGBA8 only), no decals/volumetrics/SSR/SDFGI/TAA, no manual particle emission — but a desktop
   build may **add** one, behind a gate, as long as the web frame without it is still a frame
   worth shipping. `Sun.shadow_enabled` is the one that does today, and
   `RenderBackend.supports_light_shadows()` is the gate; `race.tscn` ships it off, because a
   scene file cannot ask which renderer it is about to be loaded into. Corrected 2026-09-10 —
   this rule used to end "where Forward+ would help, isolate behind an interface", which was the
   same instruction written as though it would never be taken up.
3. **Gameplay never reads back from the GPU.** Readback stalls the browser. Snow is dual-represented
   on purpose: `SnowFieldGPU` (1024², 64 m toroidal window, for pixels) and `SnowField`
   (128² CPU mirror, for feel). They deliberately do not match.
4. **The importer is one-way and re-runnable.** `etr-0.8.4/` is read-only. Generated resources land
   in `game/courses/` and `game/resources/`. A course or terrain layer edited outside the importer
   no longer hashes to its `import_fingerprint` and is skipped without `--force`.
5. **Deviations from the original are marked `DEVIATION` in the source, each with a reason.**
   Follow that convention.
6. GDScript only for gameplay — C# has no web export. Avoid GDExtension addons.
7. **The simulation runs on a fixed tick and the presentation interpolates.** `RaceScene.SIM_HZ`
   is 60 and `_process` ticks up to the frame, not up to the last tick before it — see the trap
   list for why the phase matters. Nothing that affects the race may run on frame time: input is
   polled with the tick length, and only the camera lag, the streaming window, the particle rates
   and the deformation render target are allowed the screen's rate.
8. **A racer is whatever fills a `RacerState`.** The presentation reads that struct and nothing
   else, so it cannot tell the player from an AI, a ghost or a peer. Do not branch on
   `Racer.kind` in drawing code; add a subclass or an `InputSource` instead. The packed layout
   is a file format and a wire format at once — appending a field is a version bump, moving one
   silently reinterprets every stored ghost. It is 18 floats today: the pose, plus the four the
   character rig poses its joints from, which are there because a ghost and a peer have no
   simulation to read them out of.

## Traps found the hard way

- **A tree in ETR is not a billboard.** `DrawTrees` emits eight fixed vertices per collidable
  object — a quad across X and a quad across Z, both from the ground to `[height]`, never turned
  toward anything — and only then walks `NocollArr` and emits four camera-facing vertices per
  *item*. Both loops live in the same function under the same name, which is most of how one
  billboarded mesh came to serve all fourteen object types. It is silent: a billboarded tree is
  the right texture at the right size in the right place, and it is wrong only while the camera is
  moving, when the whole forest swivels together and no tree ever shows a second profile. The
  giveaway is `[coll]`, which is what the two loops split on. `shaders/object_cross.gdshader` +
  `ETRImport._cross_quad_mesh` are the tree half, `object_billboard.gdshader` + a `QuadMesh` the
  item half, and `TestObjects` asserts which type gets which — against the vertex data, because a
  still frame does not say.
- **Godot omits an exported property that still equals its script's default, so a
  `format_version` declared as the current version is never written to disk.** Every stored file
  then loads back as whatever the running build calls current, and the version check passes for
  all of them — which is worse than having no check, because the bump *looks* like it did
  something. Found when [constant RaceRecording.FORMAT_VERSION] went to 2 for the four floats
  [RacerState] grew and a v1 ghost on disk was read back as v2, replayed at an 18-float stride
  through a 14-float buffer, and drawn as a second penguin standing in the snow. Nothing warned.
  The declared default is now 0 — a version that has never shipped — and `RaceRecorder.begin`
  stamps the real one. Same shape as the `modified_in_editor` trap below: record provenance, do
  not let it be a default.

- **`set_shader_parameter` with a packed array aliases the caller's array.** Clearing your local
  array clears what the shader reads. Pass `.duplicate()`. Cost a whole debugging pass at S1.
- **Compatibility can't `emit_particle()`.** Drive rate-based emitters instead: ETR's per-frame
  count becomes `amount_ratio`, its spray velocity becomes emitter direction and speed.
- **Airborne, the horizontal velocity is exactly constant, so anything the camera does sideways
  came from the ground.** Off the ground there is no steering — steering in this game is a rotation
  of the friction force and `calc_friction_force` returns zero when `airborne` — and neither
  gravity, the jump impulse nor Reynolds drag turns a velocity. That leaves one lateral term in
  `ChaseCamera.track`: the lean, `surface_normal.lerp(UP, 0.5) * height`. It was taking the whole
  normal, and the across-track half of a tilt does nothing for the burying-in-a-steep-pitch problem
  the lean exists for — it just translates the camera sideways, which at `distance` behind the
  player is a yaw swing. A jump is taken off the ridge where that normal sweeps hardest: 11–17° of
  camera yaw with two to five reversals in it, over a racer whose heading moved 0.01°, reported as
  "the camera makes 1-3 nervous moves from left to right during jumps". `ChaseCamera._lean_up`
  keeps only the pitch half. **The diagnosis is the reusable part**: when the presentation moves
  and the simulation provably does not, the input to look at is whichever term reads the world
  rather than the racer. Measure it off the drawn basis over the airborne window —
  `TestCamera._fly` — not off a still frame, which cannot show an oscillation at all.
- **Don't slerp the chase camera's orientation** — the shortest arc carries roll and the lag never
  settles, so the horizon stays tilted. Interpolate position and aim point as vectors, rebuild the
  basis against world up each frame.
- **`env/environment.lst` needs `CSPList(true)`** (one record per line, no leading `*`). Parsing it
  in the default mode silently merges every environment into the first. It is also the one file in
  the data tree that spells a bool out — `[high_res] true` — which `to_int()` reads as 0.
  `SPList.get_bool` matches the original's `Str_BoolN` and accepts both forms.
- **ETR's skybox is three flat quads, not a panorama or a full cube.** `DrawSkybox` binds front,
  left and right on a camera-centred cube; top, bottom and back were never authored, because
  `param.full_skybox` ships off. `shaders/etr_skybox.gdshader` intersects the cube per pixel and
  fades to the front face's averaged edge rows outside it — do not "fix" it into a panorama, that
  resamples three real faces to fill three empty ones.
- ETR's terrain colour keys genuinely collide within ±30 (`snow`, `dirty_snow`, `thin_snow`,
  `strike_snow`). The importer warns rather than hiding it.
- **A terrain's identity is its record, not its `[name]`.** `terrains.lst` declares `pave04`
  three times with three textures, three colour keys and one `[sound]` between them, and that is
  legal: courses paint a colour, `GetTerrainIdx` resolves it to a position in `TerrList`, and
  `TTerrType` has no name field at all. One resource per name silently kept whichever record
  came last, for a whole phase, because no shipped course paints any of the three keys — nothing
  rendered wrong and nothing went red. The importer keys on the record and disambiguates a
  repeated name by its texture stem (`pave04`, `icy_rock06`, `icy_pave04`); `legacy_name` and
  `legacy_index` on `TerrainLayer` point back at the file. Two more records name a texture that
  is not in the tree at all (`pave04.png` was never shipped, `snowy_hockey_ice` writes
  `snowy_ice02` without the extension) — untextured in the original too, warned about here.
- **A course's splat channels are positional, so a layer that fails to load cannot be skipped.**
  Dropping it slides every later layer onto the wrong channel and the course plays the wrong
  friction under the right texture — silently, since it still loads. The importer keeps the slot,
  fills it with a default and warns.
- **ETR's character model frame is +Y forward, +Z belly**, not Godot's +Y up / −Z forward.
  `AdjustOrientation` sets `new_y` = velocity and `new_z` = −surface normal; `shape.lst` agrees
  (head at +Y, legs at −Y, tail at −Y −Z). The importer bakes `ETRImport.MODEL_TO_GODOT` into the
  character scene root; get it wrong and Tux rides the hill standing upright.
- **An ETR keyframe clip is mostly root motion, and the joint tracks alone look like nothing
  happened.** `finish.lst` — and `wonrace`/`lostrace`, which open on the same six frames — starts
  at `[yaw] 180 [pitch] 109`, i.e. face down the hill and tipped past horizontal, and walks that
  to `[yaw] 5 [pitch] 1` while lifting `[pos]` by 0.35 m: the penguin rises onto its feet and
  turns to face back up the hill at the camera. Every degree of that is on node 0, which is
  `KeyframePath` here and not a track in the `Animation`, so playing the clip through the
  `AnimationPlayer` and skipping the path folds the flippers and the legs and leaves the body
  lying in the snow exactly as the race left it — which is what it did for a phase, through the
  whole results screen, with the animation genuinely playing the entire time. `start.lst` does
  not catch this: it is authored upright and keys yaw only, so the intro looks right whether or
  not the pitch axis works. `RaceScene._apply_finish_pose` is `IntroSequence._apply_pose` for the
  other end of the race, and `TestCharacter` now asserts that all three finish-family clips start
  prone and end on their feet — on the path, where the fact lives.
- **A menu drawn over a live race cannot be centred, and cannot dim.** The chase camera puts the
  penguin in the middle of the frame, so `results_menu.tscn`'s centred `CenterContainer` covered
  the finish animation exactly, and its full-screen 72 % blue `ColorRect` washed out everything
  the panel did not reach — snow went from 237/252/255 to 103/126/181, and there was not one
  pixel under 80 left in the frame. The animation played correctly behind both of them and looked
  like nothing at all, which is why fixing the clip on its own changed nothing on screen.
  `CGameOver` has the answer already: a 500-wide frame at `topframe = 80` and a course that keeps
  rendering at full brightness. The panel is anchored top-centre at 80 px now, which
  `window/stretch/mode="canvas_items"` makes 80 of a 720-high canvas at every resolution.
- **A trail-map normal must be added to the terrain normal, never mixed into it.** The trail map is
  empty almost everywhere, so a reconstructed normal is `(0,1,0)` off the trench — mixing toward it
  flattens the whole course and leaves shading detail only near the player.
- **Never let a billboard's shading normal follow the billboard.** `BILLBOARD_FIXED_Y` + a QuadMesh
  normal means N·L tracks the camera and every tree pulses as you ride past. Course objects use
  `shaders/object_billboard.gdshader`, which billboards but shades as a vertical cylinder.
- **Godot imports textures with `mipmaps/generate=false`**, and a `filter_linear` sampler ignores
  mips even when they exist. Both alias into crawling speckle on a slope seen at grazing angles.
  Mipmaps are now forced via `[importer_defaults]` in `project.godot`; terrain and splat samplers
  are `filter_linear_mipmap_anisotropic`. Mipmapped alpha then needs an `fwidth` sharpen before the
  scissor test or thin branches blob.
- **`DirAccess` over `res://` finds nothing in an exported build.** The exporter converts text
  resources to binary and remaps them out of their source paths, so a directory scan that works
  in the editor returns an empty course list in the shipped game. Anything the shell enumerates
  needs a generated index resource — `resources/courses.tres`, written by the importer.
- **Splat maps are data, not colour.** A `source_color` hint sRGB-decodes the weights and crushes a
  minority layer by ~10×, undoing the importer's boundary blur.
- **`light.lst` is not the whole light state.** ETR never calls `glLightModel`, so OpenGL's
  default `GL_LIGHT_MODEL_AMBIENT` of 0.2 sits under every per-light `[amb]` in the file. The
  importer adds it. Without it the shaded side of every slope is about a third too dark and no
  tone curve will fix it, because the ratio between a lit slope and a shaded one is wrong.
- **ETR shades in display space; Godot shades in linear.** Even with the light state complete,
  the same constants land with a much wider spread between lit and shaded here. Close it with
  `EnvironmentPreset.ambient_gain` and `sun_gain` together — solved against two measured points
  on one captured frame, because one number cannot place both ends. Do not fold them back into
  the migrated colours.
- **Godot sRGB-decodes `light_color` and `ambient_light_color`, and `light.lst` is not colours.**
  `[diff] 1.0 0.9 1.0` and `[amb] 0.45 0.53 0.75` are the numbers ETR multiplies its
  display-space texture by; handed to Godot as a `Color` they are decoded, so a stored 0.9
  reaches the shader as 0.787 and *every ratio between the channels is stretched* — the migrated
  ambient's blue-to-red goes from 1.43 in the file to 2.23 in the shader. Nothing fails: the
  frame renders, and a level fit on one channel still lands. What it costs is the other two, and
  on snow they were already near the ceiling — blue sat at 1.80 pre-tonemap against a ceiling of
  1.0, green pinned at 255 over three quarters of the near field, and the only channel with
  headroom left was red, so every bit of shading variation arrived as cyan mottling on white.
  That is what "the snow is too bright" was. `EnvironmentPreset.as_light_color` encodes on the
  way in so the decode gives the file's number back; `TestEnvironments` asserts the round trip.
  Related and separate: **a scalar energy cannot reproduce a per-channel clamp.** ETR's snow
  texture is (236, 245, **255**) and its `[amb]` is (0.70, 0.78, **1.00**), so blue is at the
  ceiling before any light is applied and never leaves it; one scalar that puts red on the
  reference necessarily takes blue off it. `sun_gain`/`ambient_gain` are `Color`s for that
  reason, and their blue components are near 1.0.
- **Under Compatibility a shadow-casting light is drawn in a second pass, and that pass is
  blended in sRGB.** It is a deliberate engine trade-off (godotengine/godot#77496, #90259) — a
  shadowed light has to be in a pass of its own so it cannot flicker between the two blend spaces
  — and `use_hdr_2d` does not change it. What arrives is `srgb(sun · albedo)` added to
  `srgb(ambient)` instead of `srgb(ambient + sun) · albedo`. Two things follow and the second is
  the bad one: the sun lands five to ten times too bright, **and the sRGB curve crushes its N·L
  gradient**, because srgb is steepest near zero, so every slope facing the sun ends up at the
  same value. That is a flat white bank with no form in it, and it is a framebuffer blend, so no
  shader can reach it and no gain can fit around it. Measured on Bumpy Ride: ambient-only 0.4815
  linear, sun-only 0.0624, both with shadows off 0.5441 — the sum — and both with shadows on
  **0.9622**. It also explains, and retires, the old methodology note "do not tune by turning one
  light off, the two frames do not sum to the full frame": setting an energy to zero culls the
  light, which removes the additive pass, which removes the sRGB blend. The sum was fine; the
  full frame was wrong. The fix is the renderer split — Mobile on the desktop has one light loop
  in linear — and `RenderBackend` is where the whole story lives.
- **Godot multiplies `DIFFUSE_LIGHT` by `ALBEDO` once, after the light loop.** A `light()` that
  writes `DIFFUSE_LIGHT += ALBEDO * ...` therefore squares it. Nothing warns, and on snow it is a
  16 % darkening of the sun term only — the ambient took the engine's single multiply — so it is
  a perfectly plausible frame and it was quietly absorbed into `sun_gain` for two phases.
  Measured rather than reasoned: `DIFFUSE_LIGHT += vec3(0.5)` over a surface of albedo 0.5 comes
  back as 0.25. **Sweep a constant, do not reason about the formula** — both of the bugs in this
  pair were found by writing a number into `light()` that could not be confused with anything
  else and reading what came out, and both had survived being reasoned about.
- **`EMISSION` does not mean the same thing on the two renderers, and `DIFFUSE_LIGHT` /
  `SPECULAR_LIGHT` do.** `EMISSION = vec3(0.5)` reads back as 0.500 linear under Mobile and as
  0.216 — which is `srgb_to_linear(0.5)` — under Compatibility. A value that reaches `ALBEDO`
  through a `source_color` sampler round-trips and does not show it, which is why the terrain
  matched between renderers to within a level while the ice did not: the ice's sky reflection was
  the one term going through `EMISSION`, and it was 25 levels darker in the browser with the
  reflected penguin half as visible. It rides `SPECULAR_LIGHT` now, added in `light()`, which is
  the additive channel both renderers agree on. **Do not calibrate a shader against a constant
  written to a colour output** — write the constant into `DIFFUSE_LIGHT` instead, or measure the
  real shader.
- **`--resolution` is logical, and a compositor with a fractional output scale multiplies it.**
  This container's Wayland session runs at 1.25, so `tools/shot.sh`'s "1280x720" was writing
  1600x900 PNGs and every region box in the tone-fitting notes (history §11, §22) was landing
  somewhere else in the frame — the Bunny Hill lit near field measured 213 in the scaled box and
  237 in the unscaled one, and neither was the number the fit was solved on. `SHOT_RESOLUTION=1024x576`
  gets exactly 1280x720 back here. Check the size of the PNG you got before trusting a documented
  rectangle.
- **`Environment.ambient_light_sky_contribution` defaults to 1.0**, which hands the ambient term
  to the sky even when `ambient_light_source` is `AMBIENT_SOURCE_COLOR`. On a snow course the sky
  is a wall of sunlit snow — far brighter than the migrated `[amb]` it displaces, and scaled by
  nothing in `light.lst`. Set it to 0 when the ambient is supposed to come from the data.
- **Pull the exposure down before concluding anything about a scene that clips.** Snow saturates
  the whole frame, and at 255 every hypothesis looks the same. Rendering once with
  `tonemap_exposure` at 0.25 makes the pre-tonemap value readable straight off the PNG. **It is
  a "has this channel any headroom left" instrument, not a measurement**: the two exposures do
  not differ by a clean factor of four at the bright end. A pixel that reads 0.913 linear at
  exposure 1.0 comes back as 0.812 at 0.25, while a mid-tone agrees to 1 %, so a fit taken on the
  dim render lands several levels off. Fit on the exposure the game ships at, where the reference
  frame also lives; use the dim one to find out *which* channel has run out of range.
- **Do not tune by turning one light off.** Rendering with the sun at zero and with the ambient at
  zero gives two frames that do not sum to the full frame — the full frame is about twice their
  sum — so zeroing an energy changes more than that one term. Fit on the full render instead:
  move each energy a little, measure the gradient, solve. Two wrong conclusions came out of the
  isolated frames before that was noticed.
- **Terrain `SPECULAR` left at Godot's 0.5 default is what blows snow out.** `SPECULAR` remaps to
  F0 as `0.16 * s * s`, so 0.5 means F0 = 0.04 — snow's is nearer 0.02, and ETR gives its terrain
  light a black `[spec]`, i.e. none at all. On a surface already close to the ceiling that
  difference is the near field pinning at 255 and the albedo texture disappearing.
- **A procedural relief field's strength is not a 0..1 knob.** The detail map stores the
  gradient of a height field *with respect to UV*, and that gradient peaks near 12 — so a
  "strength" of 0.18 is a slope of 2.9, i.e. a 71 degree tilt, and the first render of it was a
  field of blue blotches. The uniforms are metres of relief (`detail_relief_fine` = 8 mm of wind
  crust) and the shader divides by metres-per-repeat to get a slope. Write the unit in the name.
- **`normalize()` of a mipped white-noise tap is a NaN.** White noise averages to middle grey,
  which decodes to the zero vector at the far end of the mip chain — and a NaN in
  `SPECULAR_LIGHT` survives being multiplied by a zero distance fade, so the term you thought you
  had faded out paints the whole horizon. Add the raw vector to the normal instead and let it
  degenerate: as the facets average out, the glint normal slides back to the surface normal,
  which is what a field of sub-pixel crystals does anyway.
- **`git stash` for an A/B render stashes your test harness too.** Capturing a "before" frame by
  stashing the working tree also reverted the change to `tools/shot.sh` that made captures fast,
  so the baseline silently went back to the two-minute software path and timed out mid-script,
  leaving the work stashed. Commit tooling changes first, then `git stash push -- game`. The
  narrowing is not what makes it safe, though: a stash-based A/B assumes everything you are not
  testing is committed, and in this tree it is not. Where the change under test is one constant,
  toggle the constant.
- **`Input.is_action_just_pressed()` stays true for a key that has already been released.** It
  compares the latched press frame to the current frame and never looks at the key state, so a
  keyboard forwarded as zero-length down/up pulses (RustDesk's Legacy/Translate mode, some VNC
  clients) drives every edge-triggered control and none of the held ones — `r` restarts the race
  while WASD and space do nothing. `KeyHoldFilter` notices the pulse and says so once; passing
  `-- --remote-keyboard` makes it stretch such a press to 100 ms, which is opt-in because the
  stretch costs a local keyboard its frame-exact release. `godot --path game
  res://scenes/key_log.tscn` prints what the link is actually delivering.
- **One zero-length pulse is also what a quick tap looks like.** The detection above diagnosed the
  transport off a single sample for a phase, so one flick of the steering on an ordinary local
  keyboard printed the whole "your remote desktop is forwarding pulses" paragraph — `xdotool key w`
  against a windowed build reproduces it every time. What separates the two is cadence, not shape:
  a pulsed transport repeats the pair at the autorepeat rate for as long as the key is held, and a
  finger cannot tap twice inside 150 ms with both halves of each tap landing in one frame.
  `KeyHoldFilter.PULSE_WINDOW` is that corroboration window; nothing is reported until a second
  pulse on the *same* action lands inside it. Compensation was never gated on the diagnosis, so
  this changed no gameplay behaviour — only what gets printed.
- **A provenance flag that nothing sets is worse than no flag.** `CourseData.modified_in_editor`
  was checked by the importer for two phases and never once fired: the importer was its only
  writer and only ever wrote `false`. Nor can it be fixed by watching the editor — GDScript's
  `_set` is not called for script-declared exports, a property setter cannot tell an Inspector
  edit from a `.tres` being loaded, and there is no `EditorPlugin` here. Record provenance instead
  of observing it: `import_fingerprint` is a hash of what the importer wrote, `edited_since_import()`
  recomputes it, and `_keep_edited()` skips a file that no longer matches. Store the hash rather
  than diffing against a freshly imported record, or every change to the importer's own migration
  logic makes all 43 layers look hand-edited.
- **An exported field nothing reads is an invitation, not a placeholder.** `TerrainLayer` carried
  `normal` and `roughness` as `Texture2D` slots "for later authoring"; the terrain shader has no
  sampler for either and never could, because it already binds 13 of WebGL2's guaranteed 16
  fragment texture units. Assigning one in the Inspector did nothing and said nothing. Same shape
  as the trap below, one step earlier: there, a field reached the resource but not its consumer;
  here it reached the resource and had no consumer at all. `uv_scale` was the middle case — per
  layer in the data, uploaded from `terrain_layers[0]`, so seven of eight values were silently
  discarded.
- **A skeleton with the right joint names can still be a statue.** The generated character carried
  15 correctly named bones with correct transforms and posed perfectly — onto nothing, because the
  mesh had no `ARRAY_BONES`/`ARRAY_WEIGHTS`, the `MeshInstance3D` had no `Skin`, and its `skeleton`
  path still pointed at its parent. Nothing warns: an unskinned mesh under a skeleton renders
  exactly as it should, motionless. Every joint was also its own root, because the walk up to the
  nearest ancestor joint went through a helper that could only return 0 or −1, and the rests were
  global rather than parent-relative — which is *self-consistent* with a flat list, so it drew
  correctly at rest and lost every hip-carries-the-knee relationship. Both were found by trying to
  play an animation, not by reading the generated scene.
- **Four of the five characters name the left elbow `joint`.** `char/<name>/shape.lst` for Trixi,
  Boris, Samuel and Beastie all carry `[joint] joint [name] joint for left_elbow`, and the `[name]`
  beside it is what gives the copy-paste slip away. Samuel goes further and has no right leg, no
  hands and no tail at all. None of it is an error to correct: `CCharShape::RotateNode` looks a
  name up in `NodeIndex` and returns false when it is not there, so the original simply does not
  rotate a joint the file does not name, and `AdjustJoints` is written against exactly that. Import
  what the file says. What it means for tests is that Tux's sixteen-bone joint list is *Tux's* —
  the contract the other four share is weaker (a skinned mesh, one root, parents before children,
  the five joints they all do have) and asserting his list against them fails on the data being
  faithful.
- **`Skeleton3D` bone tracks are absolute poses, and each keyframe tag names its own axis.** A
  rotation key replaces `bone_pose_rotation` outright rather than composing with the rest, so every
  key has to be baked as `rest × R`. And `CKeyframe::InterpolateKeyframe` does not use one axis for
  everything: `[sh]`, `[hip]`, `[knee]`, `[ankle]` and `[neck]` turn about the joint's Z, `[head]`
  and `[arm]` about its Y. Getting either wrong still produces a pose, just not the authored one.
- **In a keyframe file, a missing tag is a zero.** The original resets every joint each frame and
  reapplies only what the line names, and `SPFloatN` defaults to 0 — so `start.lst` dropping `[sh]`
  from its seventh line is what brings Tux's flippers back down before he lies on them. Keying only
  the tags that are present holds the last value instead, and he races the whole course with them
  out.
- **Half of an ETR keyframe is not animation data.** `CKeyframe::Update` writes the body transform
  as well as the joints, and neither half survives baking into an `Animation`: the authored Y is a
  clearance the runtime completes with `Course.FindYCoord` (bake it and the character walks through
  the hill on every course but the one it was baked against), and the yaw/pitch/roll goes to node 0,
  whose frame is the world, so it belongs to the node *above* the rig. It lives in `KeyframePath`,
  sampled by whoever owns the clock — which has to be the same clock the `AnimationPlayer` is
  seeked on, or the two drift. That is why the player runs in
  `ANIMATION_CALLBACK_MODE_PROCESS_MANUAL`.
- **`object.packed_array.push_back(x)` throws the element away.** Reading a packed array back off a
  property — including a script's own `@export var` on another object — hands out a copy, so the
  append lands on a temporary. Build a local `PackedFloat32Array` and assign it once. Cost an
  importer run with every `KeyframePath` empty and no error anywhere.
- **A migrated field is not ported until something reads it.** `[trackmarks]` was imported onto
  `TerrainLayer` and written into every layer resource, but never reached `SurfaceSample`, so the
  deformation stamp gated on `[part]` instead. The two agree on every terrain a shipped course
  uses, and the tests passed because they asserted only what the consumer consumed. When adding a
  surface property, trace it to its consumer and test it there.
- **ETR's mixer has one voice per sound, and the content relies on it.** `TSound` owns a single
  `sf::Sound` and `Play` early-returns while it is playing, so a cue cannot overlap itself — which
  is why a herring fires `pickup1`, `pickup2` *and* `pickup3`, three cues for one event. A voice
  pool would change how a burst sounds. `Halt` likewise checks `getLoop()` first, so one-shots
  can only be stopped by `HaltAll`. Both are reproduced in `AudioDirector`.
- **`[vol]` in `sounds.lst` is dead data.** `CSound::LoadChunk` builds every chunk at
  `param.sound_volume` and never reads the column; the only live per-sound mix is
  `SetSoundVolumes` in `racing.cpp`, which names six of the ten with *different* numbers
  (`snow_sound` is `[vol] 0.2` in the file and gain 1.5 in the code). Both are migrated —
  `SoundCue.race_gain` is the live one, `legacy_volume` the file's — and volumes clip at
  `MIX_MAX_VOLUME` = 100, so at the default 90 that 1.5 is really 1.11.
- **`AudioStreamWAV.loop_mode` is not the loop; `loop_end` is.** Once the mode is on, the
  playback takes its end limit from `loop_end`, and Godot's WAV importer leaves that at 0 for
  any sample imported with looping off — which is all ten effects. `LOOP_FORWARD` with a zero
  window wraps to frame 0 having mixed nothing and retires on the spot, so the cue reports
  `playing`, holds a voice, and is silent. That was the whole of "the terrain slide makes no
  sound": ice, rock, grass, mud and leaves were all resolved correctly, played correctly and
  heard by nobody, while the one-shots were fine because `LOOP_DISABLED` takes the end limit
  from the sample length instead. Nothing warned, and the test asserting `loop_mode ==
  LOOP_FORWARD` passed the entire time. `AudioDirector._set_loop` sets the window with the mode
  now, and `TestAudio` asserts `loop_end > loop_begin` and that it spans the sample. **The
  reusable part**: a flag that names a behaviour is not the behaviour — assert the quantity the
  engine actually reads. Measured the same way it was found, with
  `AudioStreamPlayer.get_playback_position()` over frames: broken it stays at 0.000 and
  `playing` goes false, fixed it advances. That works under the headless Dummy driver, which is
  the only way to test audio here at all.
- **`AudioServer` frees a stopped playback a frame later, so a quit has to wait for it.** `stop()`
  only marks the playback for deletion; the mixer thread has to fade it out and the object is
  freed by the `AudioServer::update()` at the end of a later main-loop iteration. Neither happens
  once the tree is coming down, so silencing from `tree_exiting` — or in the same breath as
  `SceneTree.quit()` — releases nothing and Godot reports "4 ObjectDB instances were leaked at
  exit" plus "2 resources still in use at exit", the music stream and its Ogg packet sequence.
  Every quit goes through `AudioDirector.quit_game()` for that reason: it silences, waits for the
  mixer, then quits, and it owns the window's close button (`auto_accept_quit = false`) so the X
  and Alt+F4 get the same wait. This was read as a dummy-driver artefact for a phase, which it is
  not: the driver only makes it reproduce everywhere, since a container with no sound card falls
  back to it.
- **`SceneTree.create_timer` is not a wall clock, so "wait 100 ms for the mixer" did not.** The
  entry above used to end "the wait is wall-clock, not frames", which is true of what has to
  elapse and false of what a scene-tree timer delivers: it counts down by the frame delta, so the
  interval is however many whole frames fit, each measured with the *previous* frame's length.
  The frame that asks to quit is the one that just wrote a PNG or tore down a course, so that
  delta is nothing like the frames after it. Instrumented on the real path, a 100 ms timer
  returned after **43 ms and four frames**, and the music playback was released on the fifth —
  so every quit from the main menu still leaked `start1-jt.ogg`, its packet sequence and their
  two playbacks, the exact "4 ObjectDB instances / 2 resources" the fix was written against. It
  hid under `tools/shot.sh`, whose `--fixed-fps 60` makes the countdown synthetic and generous.
  `AudioDirector.await_settled` waits for the objects instead: `begin_shutdown` takes a `weakref`
  of every playback it stops, `settling()` counts the ones still alive, and the loop yields until
  that is zero, with `QUIT_SETTLE_TIMEOUT` as a backstop rather than as the mechanism. **The
  reusable part**: when you can name the object you are waiting for, wait for *it*; a duration
  chosen to be comfortably more than enough is only as good as the clock that measures it.
- **A settle window is live, so silencing once is not silence.** The other half of the same
  warning: for as long as the shutdown waits, the tree is still processing, so anything that
  plays a cue on a timer is still asking for it — and `silence()` having just stopped the player
  is exactly what makes `player.playing` false and the next call go through.
  `RaceScene._update_slide_sound` asks every tick, so the looping terrain slide restarted inside
  the window and every quit from a race printed "2 ObjectDB instances were leaked at exit" and
  "1 resources still in use" — `rock_slide.wav` and its playback. `AudioDirector.begin_shutdown()`
  is the fix and the name: it sets a one-way gate that `play` and `_play_stream` refuse on, so the
  silence sticks. The gate lives on the mixer rather than in the race because the race is only the
  loudest caller — the pickups, the tree hit and the music are the same shape. **The reusable
  part**: when a teardown has to wait, the thing it waited for has to be *unable* to come back,
  not merely stopped; a shutdown flag is cheaper than auditing every caller. The web build wants
  it checked on the far side of an `await` too, where `PackStream.ensure` is a real round trip.
- **The headless suite's own "N ObjectDB instances were leaked at exit" is not the game's.** It is
  pre-existing and it wanders — 34–37 over repeated runs of an unchanged tree — because
  `run_tests.gd` calls `SceneTree.quit()` directly and the audio group leaves a director and its
  players behind for the same reason a game that quits without waiting does. It moves when tests
  are added or removed and it is not a signal. When chasing a real leak, reproduce it from the
  game (`--capture=` quits through `AudioDirector`, so its exit is clean and any warning is a
  finding) and read the detail with `--verbose`, which names the instances and the resource paths.
- **A `SceneTree` script's `_initialize` runs before the root Window is inside the tree**, and an
  `AudioStreamPlayer` refuses to start outside one. `tests/run_tests.gd` runs everything on the
  first `_process` for that reason — do not move it back.
- **A window size from a settings file is not the size anything renders at.** `project.godot`
  ships `window/stretch/mode="canvas_items"`, so the root viewport keeps the 1280x720 base
  aspect: ask for a 1024x768 window and the capture comes out 1024x576, letterboxed. The window
  really is the size that was asked for — do not go looking for a bug in the sizing code. Godot's
  own `--resolution`/`--fullscreen` also outrank the file, deliberately, which is what keeps
  `tools/shot.sh` capturing at 1280x720 whatever the developer's own settings say.
- **Nothing in Godot enumerates a display's modes.** `DisplayServer` reports a screen's size,
  usable rect, DPI, scale and refresh rate and stops there — there is no `SDL_GetDisplayMode`, on
  any platform. `DisplayModes` derives the settings screen's list instead: the panel's own
  resolution plus the standard modes that share its shape and fit inside the usable rect, with
  fractions of the panel where nothing standard shares its shape (21:9, portrait). Shape is the
  invariant and it is not cosmetic — with `stretch/aspect="keep"` a window of the wrong shape
  letterboxes itself, which is the trap above seen from the menu.
- **`change_scene_to_file()` called from `_ready` prints "Parent node is busy adding/removing
  children" and carries on.** The shell decides in its own `_ready` whether a scripted run should
  skip the menu, which is exactly that case: the tree is still adding the scene that is asking to
  be replaced. `change_scene_to_file.call_deferred(...)` waits the one frame it takes. The error is
  not fatal — the race loads, `RACE_READY` prints, the capture is correct — so it is a red line
  above a working screenshot rather than anything that fails.
- **A run that wants a rendered course has to name one.** The main scene is `main_menu.tscn`, and
  `--course=` or `--auto-input=` is what hands over to the race before the menu is ever shown —
  `tools/shot.sh` passes both, so captures are unaffected. A bare `--capture=` screenshots the
  menu, deliberately: that is how the shell itself gets verified. In a browser there is no command
  line, so `index.html?course=<dir>` says the same thing and is what keeps the web harness's
  `RACE_READY` arriving.
- **A `Control`'s theme does not reach a `CanvasLayer`'s children.**
  `Control::_propagate_theme_changed` recurses into `CanvasItem` and `Window` children and
  nothing else, so a `CanvasLayer` under a themed `Control` is where propagation stops — the
  labels inside it silently fall back to Godot's default theme, which on a menu means grey-on-blue
  where every neighbouring screen is white-on-blue. Nothing warns; the panel just looks wrong.
  Each of the shell's `CanvasLayer` screens therefore carries `themes/etr_menu.tres` on its own
  top-level `Control` rather than inheriting one. `course_menu.tscn` would need that anyway: it is
  instanced under `race.tscn` too, whose root is a `Node3D` with no theme to inherit.
- **Directional shadows stop at `directional_shadow_max_distance`**, on a sphere around the camera.
  Set shorter than the visible slope it reads as an arc of shadow travelling in front of the
  player. It is derived from the environment's fog range in `RaceScene._shadow_range_for` — keep it
  tied to visibility rather than hardcoding a number.
- **A fixed timestep has a phase, and the textbook one draws a tick behind.** The usual loop adds
  the frame time to an accumulator, ticks while it holds a whole `SIM_DT`, and draws between the
  last two states by `accumulator / SIM_DT` — which at exactly 60 fps is zero every frame, so it
  draws the *previous* tick forever. That is 16.7 ms of constant latency, and it moved every
  reference capture: the procedural snow relief is computed per fragment from the view, so a
  fifteen-centimetre camera shift repainted a sixth of the frame. `RaceScene` keeps how far the
  simulation is *ahead* of the drawn instant instead (`_sim_lead`), ticks while that is
  negative, and draws at `1 − lead / SIM_DT`. At 60 fps the lead is exactly zero and the draw is
  the live tick, bit for bit what the variable-timestep loop did; at 144 Hz the three frames
  between two ticks land exactly where they belong. history §20.
- **`GPUParticles3D` seeds itself per run, so the spray is not part of any bit-exact capture
  comparison.** Two runs of unchanged code differ over the spray by ~20 kB of a 2.2 MB frame.
  Mask x 450–700, y 250–520 out of a `carve` capture of Bunny Hill before concluding anything from
  a byte diff — everything outside that plume really is reproducible, to the byte.
- **An autoload's singleton name is a static type dependency, so two autoloads can be a parse
  cycle.** `GameConfig` names `RaceNetwork.DEFAULT_PORT` for its default; had `RaceNetwork` also
  said `Config.player_name`, GDScript would resolve `Config` to `game_config.gd` at parse time and
  both scripts would fail to compile — reported as *"Nonexistent function 'new' in base
  'GDScript'"* at whatever tried to use one, naming neither. The transport takes its identity
  through `RaceNetwork.configure()` instead, which is the better arrangement anyway.
- **The same cycle reaches an ordinary class the moment another script calls one of its static
  members.** `TestMultiplayer` asserting `RaceScene.outcome_clip(...)` was enough to make
  `RaceScene` fail to compile with *"Identifier not found: Config"* — a usage of the autoload
  `Config` deep inside `RaceScene._ready()`, nowhere near the static function being called. Calling
  a static member forces GDScript to resolve the callee's whole class up front, and `RaceScene`
  carries `Config` the way `GameConfig` carries `RaceNetwork` above; under `TestScripts`'s own
  `CACHE_MODE_REUSE` walk (see below) that eager resolution happened in a context where `Config`
  could not be found, and the failure stuck to the cached script object for the rest of the run.
  Reproduced with a standalone probe script outside `res://tests/` before it was believed — the
  same walk, run manually, did not fail, which is what pointed at the call site rather than the
  file. Fixed the way the trap above was: stopped fighting the cycle and moved the pure mapping
  (`outcome_clip`, no autoload, no node) to its own `RaceOutcome`, which nothing needs to eagerly
  drag `RaceScene` in for. It happened a second time the moment a test called
  `SettingsMenu.sizes_for(...)`, and was fixed the same way — the list-building moved to
  `DisplayModes`. Treat it as the rule: anything a test wants to call statically does not live on
  a script that names an autoload.
- **`ResourceLoader.load(path, "SomeScriptClass")` always fails.** The type hint is checked against
  `ClassDB`, which knows nothing about `class_name`, and the load errors out rather than falling
  back. Pass `""` and cast the result — `SavedRunStore.list_all` does. Also pass
  `CACHE_MODE_IGNORE` for anything under `user://` that the game rewrites while running, or the
  copy read at the start of the race is the run the player has just beaten.
- **GDScript's `%` formatter has no `%g`**, and `PackedStringArray` has no `join` — it is
  `String.join(array)`, the other way round. Both are silent-ish: the first prints *"unsupported
  format character"* per call from inside whatever loop you put it in, the second is a parse error
  that takes every depending script down with it.
- **`int(float(x) / float(n) * float(n))` is not `x`.** `178 / 179.0 * 179.0` is
  177.99999999999997 in double and the truncation takes it to 177. `_decode_splat` resampled the
  splat map onto the heightmap grid with exactly that expression, and the two are the same size
  for all 44 shipped courses — so what should have been an identity was off by one on eleven of
  bunny_hill's 179 columns and eight of its 519 rows. Whole 50 cm stripes of every course ran on
  the neighbouring terrain's friction. Nothing looked wrong, because the *shading* comes from the
  splat texture directly on the GPU and only the physics goes through the resample; the two
  disagreed for as long as the function existed. Index maps are integer arithmetic:
  `x * sw / target.x`. `TestSurface._splat_resample` asserts the identity on the six widths that
  actually ship.
- **A per-element loop that applies the same scalar to every element is a scalar.** `SnowField.decay`
  multiplied 16 384 floats by 0.99982 sixty times a second — 0.74 ms a tick, fifteen times the cost
  of the entire physics simulation, to change the field by two parts in ten thousand. It is now a
  scale factor the readers multiply through, renormalised into the arrays about once a quarter of
  an hour, and it costs 0.0002 ms. The general shape: before optimising a loop, check whether it
  has to be a loop.
- **A chunk vertex sits exactly on a heightmap texel, so `sample_into` there is a bilinear filter
  between a texel and itself.** `TerrainRenderer._build_chunk` paid four lerps over five arrays and
  a `normalized()`, 4096 times a chunk, to read values it could have indexed: 6.8 ms a chunk, and a
  row of them entering the stream radius at once was a 26 ms frame every second and a half. Reading
  `surface.heights` and `surface.normals` directly is 1.4 ms. It also stopped the CPU snow mirror
  being baked into the mesh — `sample_into` subtracts the live trench, so a chunk built while the
  player was carving nearby froze a dent into the terrain for the rest of the race.
- **Streaming work has to be budgeted, not just gated.** `update_streaming` returned early unless
  the camera had moved 5 m and then built *every* newly-in-range chunk in that one frame. The gate
  makes the average cheap and does nothing at all about the peak. It now queues nearest-first and
  drains under [constant TerrainRenderer.BUILD_BUDGET_MS], with an `immediate` flag for the course
  load, where the shell's "please wait" panel is already up. Threads are not an option: all three
  web presets ship `variant/thread_support=false`.
- **A new `class_name` does not exist until the editor has scanned for it.**
  `.godot/global_script_class_cache.cfg` is gitignored and only rewritten by an editor pass, so
  every headless run after adding a class fails with *"Could not find type X in the current
  scope"* — including the test suite, which then reports a compile error in a file you did not
  touch. `godot --headless --path game --editor --quit` first. This bites twice per new class,
  because the second symptom is a scene that silently keeps the old script.
- **The test suite did not compile the shell, and a parse error there passed 3638 assertions.**
  Everything under `scripts/shell/`, plus `race_scene.gd` itself, is reachable only from scenes,
  and the suite is written against the node-free simulation — so nothing loaded them. A broken
  `race_hud.gd` was found by taking a screenshot. `TestScripts` now walks every `.gd` and loads
  every scene. Note that **`ResourceLoader.load` returns a real `GDScript` object for a file that
  failed to parse** — it prints the error and carries on, so `load() != null` passes; check
  `can_instantiate()`. And do not pass `CACHE_MODE_IGNORE` to force a recompile: that replaces the
  script object under every live instance, including the autoloads and the script running the
  loop, and segfaults the engine.
- **Count the magnitude of a capture diff, not the pixels.** Fixing the splat resample below moved
  6.2 % of a Bunny Hill `carve` frame, which reads like a visual regression and is not one: the
  mean absolute channel delta over the whole frame is 0.068/255 and only 35 pixels of 553 536 move
  by more than 32/255. Any change to the surface perturbs the run at the 1e-7 level, the adaptive
  ODE has a discrete accept/reject branch that amplifies it, and the procedural snow relief is
  view-dependent — so a centimetre of camera shift redithers a sixth of the frame by one level.
  A real regression is a small number of large deltas; chaotic divergence is a large number of
  ±1s. Measure both before concluding anything, and bisect by reverting one file at a time rather
  than by looking at the picture.
- **`git stash push -- game` leaves untracked files alone**, which is what makes an A/B bisect
  possible at all: put the probe script at `game/tests/_probe.gd`, never `git add` it, and it
  survives the stash that takes the change under test away. That is the counterpart to the stash
  trap above — the danger is stashing your *tooling*, and an untracked probe is by construction
  not stashable.
- **Static typing does not save you across a scene-level cycle.** `race_hud.gd` declares
  `@export var race: RaceScene` and calls `race.racers`; after that member was moved to
  [RacerRoster] the call was still not a parse error, only a runtime *"Invalid access to property
  or key"* once a frame. `TestScripts` compiles the file happily. Renaming a member that a
  sibling script reaches through an `@export` typed reference needs a grep, not a compiler.
- **`RacePhysics` ignores an analogue stick under 0.2, and there is no warning of any kind.**
  `_calc_steering_controls` takes the stick only when `absf(stick_turn) > 0.2` — the deadzone a
  real thumbstick needs — and otherwise falls through to the digital `left_turn`/`right_turn`
  flags, which are full lock or nothing. A source that steers proportionally and does not set the
  flags therefore does nothing at all below a fifth of lock: the aim point is right, the heading
  error is right, the stick is set correctly, and the racer holds whatever heading it had. It
  presented as two AI opponents that had each correctly decided to give the other room and
  neither moving a centimetre. `AIInputSource.stick_for` maps anything worth correcting to
  [`MIN_EFFECTIVE_STICK`, 1.0] for that reason.
- **A GDScript lambda captures by value, so a counter incremented inside one never comes back.**
  `var hits := 0` + `signal.connect(func(): hits += 1)` compiles, runs, increments a copy, and
  leaves `hits` at zero — which in a test is worse than a crash, because the assertion that the
  opponent hit no trees passed on every run including the ones where it hit eleven. Capture a
  one-element `Array` instead; arrays are references.
- **A contact resolved through velocity alone settles *inside* the contact distance, not at it.**
  Two racers on identical lines are held apart by `_adjust_racer_collision`'s overlap term, which
  is proportional to how far inside each other they are — so it necessarily balances somewhere
  short of touching-and-no-further, at 0.57 m of a 0.6 m contact rather than at 0.6. That is the
  correct behaviour of a spring with no position correction and not a bug to tune out; the
  assertion to write is "beside each other rather than inside each other", against the contact
  distance, not against a number typed into the test.
- **An obstacle that moves with you is not scored like one that stands still.** The first cut of
  the AI's rival avoidance measured, for each candidate line, the distance from that line to the
  other racer — the same test it uses for a tree. Every candidate line starts at the racer's own
  position, so a rival alongside is about equally far from all nine of them: a constant penalty,
  which discriminates between nothing. A tree is somewhere you will be; a rival is a *column* you
  will both still be in when you get there, so what is scored is the lateral gap at the aim point,
  weighted by how close alongside they already are.
- **A new `class_name` is invisible until the project is reimported.** `godot --headless --path
  game --script ...` does not scan the filesystem, so a script added outside the editor is not in
  `.godot/global_script_class_cache.cfg` and every reference to it is *"Could not find type X in
  the current scope"* — including from scripts that were fine a moment ago. Run
  `godot --headless --path game --import` after adding one.
- **`TUX_Y_CORR` is the whole of how deep the penguin rides, and a second offset under it sinks
  him twice.** ETR draws node 0 at `cpos.y + TUX_Y_CORR` and stops: how far into the snow the belly
  goes is already in the point mass, as the terrain's `[depth]` (0.11 m for `snow`) plus about
  0.065 m of spring compression under 20 kg — the body centre sits ~0.175 m *below* the surface
  plane and is drawn 0.36 m above that, i.e. 0.185 m clear, and the model reaches 0.292 m down from
  its origin. A `CHARACTER_SINK` of 0.1 m was added on top of that "so the belly sits in the
  contact patch", which it already did, and the snow field took another 0.04–0.10 m off the height
  underneath: 0.185 m of clearance became 0.014–0.067 m, and two fifths of a 0.6 m penguin went
  under the snow — the belly, the feet and the bottom of the back. Nothing looked broken, because
  a penguin sliding on his belly is *supposed* to be partly buried and there is no line in the
  frame that says how much. Measure it — the number to
  compare against ETR is the model origin's clearance over the **bare** heightmap, and it is
  0.185 m. `TestMultiplayer._where_the_body_is_drawn` asserts it.
- **Every `SceneTree` is already "connected".** Godot installs an
  `OfflineMultiplayerPeer` at startup, so `multiplayer.multiplayer_peer` is non-null and its
  `get_connection_status()` is `CONNECTION_CONNECTED` in a game that has never opened a socket.
  `RaceNetwork.active()` was written as that pair of checks and therefore answered *yes* to every
  single-player race — which silently turned the start animation off for all of them, because
  `restart()` skips the intro in a networked race on purpose. Nothing failed and nothing was
  logged; the race simply began already moving, which is what a race looks like after an intro
  you did not see. Ask whether the peer is the offline one, not whether there is a peer.
  `OfflineMultiplayerPeer` is core and safe to name in a script that ships to web, unlike
  `ENetMultiplayerPeer`.
- **Simulation state read at frame time is a sawtooth, however smooth the field is.** The snow
  lift that draws the body against the bare hill (`Racer._drawn_snow_lift`) was read live from
  `present()`, which puts two clocks in one expression: `SnowField` is written from inside the
  substep loop, so a frame on which a tick ran saw the depth jump by everything that tick had
  stamped, while the frames between saw the interpolated body slide forward onto texels its own
  stamp had not reached yet and the depth fall back. Bunny Hill at 145 fps: a 60 Hz sawtooth of
  about 4 mm on the drawn Y, mean |Δ²| of 2–6 mm against 0.1–0.3 mm for the simulated position
  under it — a penguin that visibly shivered a few seconds into every run, on exactly the
  terrains that take trackmarks. Nothing in the physics showed it, and that is the tell rather
  than the reassurance: the same steps arrive under a 1500 N/m spring at about 1.4 Hz, which
  filters them out, and drawing added them back unfiltered. **`depth_at` being bilinear does not
  help** — the field is smooth in space and a step function in time, and it was time that was
  being resampled. The fix is architecture rule 7 applied to one more quantity: sample on the
  tick at the tick's position, keep two ends, interpolate with the same `alpha` as the pose
  (`Racer.sample_snow_lift`, called last in `RaceScene._simulation_tick`). Median |Δ²| after:
  0.2 mm. `TestMultiplayer._the_lift_runs_on_the_tick` asserts the property rather than the
  number — between two ticks the drawn lift depends on nothing but `alpha`.
- **A deposit narrower than a texel reads back as a phase, not a value.** With the lift moved
  onto the tick, `challenge_one` still bobbed — 50 mm at 12 Hz over a simulated position smooth
  to a tenth of a millimetre. `SnowField` is 50 cm/texel and the contact patch is 45 cm, so the
  stamp footprint fitted *inside one texel*: it landed wholly in that texel when the racer was on
  its centre and split four ways when it was on a corner, and `depth_at` reconstructs bilinearly.
  Swept across one texel, a single 0.10 m stamp read back **0.024 m to 0.095 m — a 3.9× swing**,
  at the texel-crossing rate. Nothing looked wrong: every number was a plausible depth, and the
  physics filtered the ripple out through the spring, so it was visible only in the one consumer
  that takes the trench back undivided. **A trench the true width of the penguin is not
  representable on this grid at all** — the choice is aliased or band-limited, not sharp or
  blurred. `SnowField.MIN_FOOTPRINT` widens the deposit to 1.5 texels, which is where the flat
  top covers every texel a bilinear read can reach and the swing goes to 1.01×; the rate is
  divided by exactly the widening, or a change of representation deepens every trench fourfold.
  Then the **`min()` against `max_trench` turned out to be the same bug one level up** — in deep
  snow the texels under the racer met the ceiling while the ones a texel out did not, and the
  read across that kink went back to depending on the phase, worth 15 mm on its own. Approach a
  ceiling, do not clamp to it. `TestSurface._snow_is_band_limited` asserts the property over the
  whole phase square rather than the constants. The GPU field needs none of this: at 6.25 cm/texel
  the same 0.225 m radius is 3.6 texels.
- **Two axis-aligned cards on a grid are the same plane.** ETR places every object on an
  object-map cell and `DrawTrees` gives a collidable one a quad spanning X and a quad spanning Z,
  turned toward nothing — so a row of trees shares its z to the last bit, and the X-quads of two
  trees standing closer together than the sum of their radii are *exactly coplanar over the
  overlap*. Nothing resolves that: the depth test is a comparison and neither surface is in front,
  so the pair swaps frame by frame over a region the size of a whole tree. `challenge_one` has
  1255 such pairs, 522 of them in the column at x = 50.505 down the left of the course, which is
  where it was reported — trees that "sometimes flicker, looks a bit like z-fighting". Raising the
  near plane does not help and neither does any depth format; **coplanar is not a precision
  problem**. `CourseRoot.decorrelating_yaw` turns each object by a hash of its own position. Two
  measurements are worth keeping: a 1/10-speed capture (`--fixed-fps 600`) makes the camera creep
  so that a large frame-to-frame delta is flicker rather than motion, and widening the jitter until
  the count stops falling is what says the rest is alpha-scissor edge crawl and not fighting.
- **`MultiMesh.get_instance_transform` returns the identity under `--headless`.** The transforms
  live in the [RenderingServer] and the dummy renderer keeps none of them, so every instance reads
  back untransformed with nothing logged. A headless test written against the batch therefore sees
  a forest of perfectly coincident trees and will happily assert whatever that implies. Assert
  against what feeds the batch instead — `TestObjects._no_two_trees_share_a_plane` reads the
  markers and calls the same helper `CourseRoot.build_runtime` does.
- **Dropping a state-machine exit and keeping only the force it used to guard is not the same
  deviation.** The original leaves the racing loop outright once `speed < 3` at the finish line
  (`AdjustVelocity`) — the flat 500 N gravity swap the DEVIATION on `calc_brake_force` already
  called out was never what stopped the player, that early exit was. Kept real gravity and the
  brake ramp but not the exit, and the two fight forever at a few m/s: gravity's downhill component
  never quite zeroes, the flat brake is keyed to `_finish_speed` rather than current speed, and
  `RaceScene` keeps ticking the physics for the full `FINISH_MENU_DELAY` (3 s) before the finish
  clip and results screen appear. The result is a permanent low-speed creep rather than a stop —
  and `ChaseCamera` switches its position/aim lag off below 2 m/s (`NO_INTERP_SPEED`), which is
  exactly that creep's speed band, so for the whole delay the camera drew it, and every bit of
  substep-to-substep ODE noise riding on it, completely unsmoothed: reported as the camera jumping
  at high frequency where the character was supposed to be dancing or slumping. Fixed by porting
  the exit condition rather than only the force — `RacePhysics.FINISH_STOP_SPEED` freezes `vel` and
  skips the ODE solve once a finished, grounded racer is this slow, which is what the original's
  state change gave it for free. The lesson: when a DEVIATION note says "only X is retained," check
  what else the removed behaviour was quietly doing before trusting X to do all of it alone.

## Deliberate deviations from ETR

- **A tree is shaded as a cylinder across both of its planes**, where ETR gives all eight vertices
  `glNormal3i(0, 0, 1)` and lights the whole object flat from one world direction. The geometry is
  the original's exactly; only the normal is not. Shading each quad by its own face normal instead
  splits a tree into a bright half and a dark half at 90° to each other, which is further from ETR
  than either — the cylinder keeps its even aggregate brightness from any azimuth and adds the
  across-quad gradient. `normal_roundness = 0` in `object_cross.gdshader` is the flat card.

- **Each collidable object is turned by a yaw hashed from where it stands** (±20°,
  `CourseRoot.decorrelating_yaw`), where ETR turns none of them at all. The geometry is still the
  original's — two fixed planes at 90°, never turned toward the camera — and the position, the
  silhouette and the collision cylinder are unchanged. It exists only so that a forest placed on
  an object-map grid does not share four planes between all of it; see the trap list for what that
  costs. `YAW_JITTER = 0` is ETR's forest exactly, and its flicker with it.

- Items/trees go through a **uniform spatial grid**; the original did an O(items) linear scan per
  ODE substep.
- **Friction and compression depth are pre-blended per heightmap texel at load** — exact, because
  splat blending and bilinear filtering are both linear, at 4 multiply-adds instead of up to 32.
- **The stage-3 force evaluation is reused as the next step's first stage** (3 evaluations per
  accepted step, not 4). Both of these bought the S2 headroom — keep them.
- **Packed snow lowers friction** (friction scales the retarding force: ice 0.2 fast … rock 0.7
  slow), so a trench is faster and racing lines matter. Plan §4.3 originally said "raise"; that was
  a wording error, corrected 2026-08-31. Both coefficients are exported so the feel can be redone.
- **Finish sequence keeps real gravity** instead of the original's flat 500 N hack.
- **Snow and ice get view-dependent terms the original has no equivalent for.** ETR shades both
  as flat textured diffuse; what distinguishes them there is the texture and `[friction]`. Here
  snow gets two octaves of procedural micro-relief (wind crust and wind-stretched drifts, faded
  by distance) and a glint built from per-texel facet normals, so a different scatter of crystals
  catches the sun as you ride past. Ice gets a Fresnel-weighted sky reflection through `EMISSION`
  — Compatibility will not bind the `Sky` to a spatial shader and the environment reflection is
  deliberately off, so the sky is a two-colour ramp from the preset — plus a tight sun glare on
  the same Fresnel weight, and a diffuse albedo scaled to 0.82. The albedo cut is the part that
  makes the rest visible: Schlick at the ~65 degree incidence a chase camera sits at is about
  0.09, and 0.09 of sky over an already near-white albedo is four levels nobody sees. All of it
  is behind uniforms; `ice_albedo = 1.0` and `detail_relief_* = 0` restore the previous look.

- **The ice reflects the racers standing on it**, and ETR reflects nothing at all — its
  `DrawCharacter` draws the penguin exactly once and its ice differs from its snow only by
  texture and `[friction]`. Compatibility has no SSR and no `RenderingDevice` (rule 2), so this is
  the fixed-function reflection: `IceReflection` renders the racers a second time through a
  `SubViewport` whose camera is the chase camera mirrored through the ice under the player, and
  the ice branch of `terrain.gdshader` samples it by `SCREEN_UV`. Three decisions are worth
  keeping, all of them measured by spike S7 rather than assumed:
  **(1) the mirror shares the main `World3D`** and narrows `cull_mask` to one visual layer, so it
  draws the very rigs the main pass drew — there is no duplicate rig, no pose to copy, and a
  ghost, an opponent and a remote peer are reflected without the reflection knowing they exist
  (rule 8 again). **(2) The determinant is −1 and nothing is done about it**: the renderer flips
  the winding itself for a mirrored view matrix, so character materials are untouched.
  **(3) The reflection occludes the sky ramp rather than adding to it** — where there is a
  penguin in the mirror, the penguin is what the ice reflects *instead of* the sky, which is both
  the physics and the only way it reads. Schlick at chase-camera incidence is 0.02–0.09, and an
  additive term at that weight is invisible; a dark penguin standing between bright ice and a
  bright sky is not. Measured on `tuxway`: 17 levels, against a run-to-run noise floor of zero.
  The one real approximation is the plane. A planar reflection is only true on its plane and the
  terrain is a heightmap, so the plane is the tangent under the racer being watched — exact at
  the contact point, where the eye checks it, and wrong at a rate that grows with distance.
  `reflection_fade_distance` (8 m) is what confines it: the lookup is by `SCREEN_UV`, so without
  it a frozen lake elsewhere in frame would show a penguin reflected in a plane it has nothing to
  do with. `[display] ice_reflections = false` is off, and `character_reflection_opacity = 0` is
  the same thing in the shader.
- **The spray's puff atlas is redrawn, not copied.** ETR textures every spray
  particle from `data/textures/snowparticles.png` — a 64×64, 2×2 atlas of four
  soft puffs, one quadrant per particle chosen at birth and kept — grows each
  particle from 0.035 m toward a per-particle base of up to 0.18 m over its
  whole life, fades it out linearly, and gives it a lifetime of
  `FRandom() × 1.0 s`. The original texture waits on the licence audit like the
  rest of the texture art, so `SprayEmitter.make_puff_image` redraws the atlas
  procedurally (the checkbox-icon standing), deterministic so captures stay
  comparable. Until it arrived the emitter drew ETR's counts and velocities on
  flat white squares at full size, fading never — the *shape* of a ported
  effect is part of the port too. The spray tint is sunny's
  `[partcol] 0.85 0.9 1.0`, standing in until `EnvironmentPreset` carries the
  field.
- **Which layers are ice is `TerrainLayer.is_ice()`, not `[shiny]`.** Seven records are ice and
  the data marks only three of them shiny — `ice1`, `ice2`, `greenice`. `hockey_ice`,
  `snowy_ice`, `snowy_greenice` and `snowy_hockey_ice` ship without it, so the friction clause
  carries most of the set rather than a couple of stragglers. It catches them because every ETR
  ice terrain is `[friction] 0.2` and nothing else goes below 0.3.
- **The illumination is summed and clamped before it touches the albedo**, which is ETR's
  fixed-function order and not a PBR renderer's. `shaders/etr_illumination.gdshaderinc` is
  `texture × clamp(ambient + diffuse · N·L, 0, 1)`, and every lit shader includes it: the terrain,
  and both object shaders, each `ambient_light_disabled` so the two terms can meet inside
  `light()` where the engine's ambient cannot reach them. This is what makes `sun_gain` a
  derivation rather than a fit — ETR saturates red at `0.2 + 0.45 + 1.0·ndl ≥ 1`, i.e. `ndl` =
  0.35, where the half-Lambert `shaped` is 0.210, so `sun = (1 − 0.591) / 0.210 = 1.95`, one
  scalar on the migrated `[diff]`. Multiplying first and clamping the product instead sends a
  slope to flat 255 white the moment the illumination passes `1/albedo`, which on snow is about
  1.2; two courses under the same sun then want gains a factor of 1.75 apart, which is the shape
  of a missing clamp and not of a constant that needs nudging.
- **The sun casts a real shadow map, on the desktop only, and the original casts a blob.** ETR's
  only shadow is `CCharShape::DrawShadow`, the character's own flattened body drawn under it at
  `perf_level > 2` and skipped under `light_id` 1 and 3; `DrawTrees` emits no shadow geometry at
  all. Here it is Godot's PSSM directional shadow, so the trees, the start banner and the hill
  itself cast too — an addition of the same kind as the ice reflection, and off in the same three
  ways: the renderer (`RenderBackend`, which refuses under Compatibility — see the trap list),
  the sky (`EnvironmentPreset.casts_shadows`, which is ETR's `light_id` rule verbatim) and the
  player (`GameConfig.shadows`, which is ETR's `perf_level`). **The web build therefore has no
  shadows at all**, deliberately: the frame it gets instead is the same clamped illumination
  without the shadow term, which measures within a level of the desktop's on snow.
- **Linear tone mapper, no glow, no SSAO.** ETR clamps in display space and has neither effect;
  a filmic curve redistributes both ends of the snow's range and glow smears the highlights that
  snow is mostly made of. Reproducing a fixed-function look means reproducing its transfer curve.
- **Fog is pushed out from the original's range, from the settings file** — 40 m of clear air in
  front of the camera and 2x the migrated distance, i.e. 40–150 m where `light.lst` says 0–75.
  Six of the eight presets ship `[fogstart] 0` — including both sunny ones, which is what all 44
  shipped courses select — so ETR's haze begins *at* the camera and the trees a couple of lengths
  ahead are already washed toward white. An earlier 2.5x stretch was backed
  out on 2026-09-01 as a wording-level "improvement"; this is the same move made deliberately,
  measured, and made revertible — `start_distance = 0` + `distance_scale = 1` in
  `penguinracer.cfg` is the original's fog exactly. Measured on Bunny Hill: the mid-distance tree
  band regains its contrast (5th percentile 143 → 65, clipping 19 % → 12 %) and the near field
  the tone match was solved on does not move at all (mean 226.8 → 226.5). The white haze is still
  what the horizon dissolves into; it just no longer starts on the player.
- **`Environment.fog_density` gates depth fog too**, not just the exponential mode, and defaults
  to 0.01. Set `fog_mode = FOG_MODE_DEPTH` and a range and leave density alone and you get fog at
  one per cent — indistinguishable from fog switched off, and the migrated `[fogstart]`/`[fogend]`
  quietly do nothing. Godot also ramps depth fog with a `smoothstep`, where ETR's `GL_LINEAR` fog
  is linear in distance, so the near field stays clearer here than it does there even at the
  migrated range.
- **Ambient comes from the migrated `[amb]`, not from the sky** —
  `Environment.ambient_light_sky_contribution` has to be set to 0 for that to be true. See the
  trap list.
- **The light constants are migrated verbatim and corrected by a separate fitted gain.**
  `sun_color`/`ambient_color` on an `EnvironmentPreset` are `light.lst`'s numbers and nothing
  else, so a preset can still be read against the file on sight; `sun_gain`/`ambient_gain` are
  the fitted rendering correction and are `Color`s rather than scalars, because ETR clamps per
  channel and one number cannot reproduce that (see the trap list). Both are applied in one
  place — `EnvironmentPreset.as_light_color`, reached from `to_environment()` for the ambient
  and `apply_sun()` for the sun — because the bug that shipped was the two halves of that
  disagreeing.
- **The terrain slide sound resolves through the dominant splat layer**, where ETR used
  `Course.GetTerrainIdx(x, z, 0.5)` — the type holding at least half the blend, else nothing. Ours
  always resolves to a layer, so the cue changes slightly earlier across a boundary and a blend of
  two noisy terrains is never silent.
- **The slide has no speed or lean term.** ETR wrote one — `SlideVolume` in `racing.cpp` — and
  ships it commented out above "this function is not used yet", so the sound is on or off. Ported
  as it stands; the same goes for the 12 terrains that name no `[sound]` at all, `snow` included.
- **The start animation is skipped for scripted runs.** `CIntro` runs before every race in the
  original; here `--auto-input=`, `--no-intro` and `?nointro=1` bypass it, because four and a half
  seconds of Tux walking in front of a frame counter would move every reference capture.
  `tools/shot.sh` always passes `--auto-input=`, so captures are unaffected either way.
- **The HUD says `PRESS ANY KEY TO START` over the start animation.** The original draws its
  ordinary HUD there and never mentions that any key skips it. The string is a migrated one — it is
  what ETR puts under its splash screen.
- **The drawn body is lifted by the trench it is standing in.** ETR has no snow deformation, so
  there is nothing here to port; ours is deliberately two fields that do not match (rule 3).
  `SnowField` takes the trench off the height the simulation stands on, so a carving racer really
  does ride up to `max_trench` lower than the bare heightmap — but the *drawn* surface does not go
  down with it, because the terrain mesh is displaced from the GPU field on vertices too coarse to
  carve. `Racer._drawn_snow_lift` adds back exactly what `SnowField.apply_to_sample` took off, at
  the body's own position, so the penguin rides on the snow that is actually drawn. Both are zero
  outside the 64 m window, so the two stay in step wherever the racer is. **Delete it, do not
  retune it, the day the near-field mesh carries the trench in geometry** — that is the whole of
  the known gap it exists for.
- **A shoulder carrying both `[sh]` and `[arm]` is one quaternion key interpolated by slerp**, where
  the original interpolates the two angles separately and rebuilds both matrices. The two agree
  exactly whenever one angle is constant across a segment, which covers all of `start.lst` (no
  `[arm]` at all). A `Skeleton3D` rotation track offers no per-axis alternative.
- **The menus reproduce ETR's palette, not its menu art.** `themes/etr_menu.tres` is the colour
  table from `src/common.cpp` — `colBackgr` for the screen, `colMBackgr` behind a frame,
  `colDBackgr` for a recessed fill, white text and outlines, `colDYell` for focus, `colLGrey` for
  a secondary line — applied through Godot's theme system rather than by drawing SFML rectangles.
  What is missing is the art `DrawGUIFrame`/`DrawGUIBackground` paint over it: the four corner
  ornaments and the title logo, which are `etr-0.8.4/data/textures` assets and wait on the licence
  audit. The falling `param.ui_snow` particles are missing for the same reason plus one more —
  they are a menu-only particle system with no gameplay tie. ETR's checkbox is its own shape,
  a ring with a cream tick, and is redrawn here as `themes/checkbox_{on,off}.png` rather than
  copied, because Godot's default `CheckButton` switch is a dark slab that disappears on blue.
- **The chosen character is remembered, and it is asked for from the main menu.** ETR asks on
  `CRegist`, the first screen of a launch, where a `TUpDown` over `Char.CharList` sits beside the
  player-profile spinner — and it does not keep the answer: the spinner opens on index 0 every
  time and `players.lst` has no column for it. There are no player profiles here yet, so the
  player half of that screen has nothing to show; the character half is `character_menu.tscn`
  behind its own main-menu entry, and the answer is `[game] character` in `penguinracer.cfg`.
  `--character=<dir>` and `?character=<dir>` name one for a single run without writing the file.
  The arrows are horizontal and flank the name where ETR stacks an up and a down arrow to its
  right; the clamping and the greyed-out end arrow are the original's (`TUpDown::Click` stops at
  `minimum`/`maximum` and calls `SetActive(false)`). The `n / 5` counter under the preview is new:
  five characters behind two arrows give no sense of how many there are.
- **The simulation runs on a fixed 60 Hz tick.** ETR steps its ODE with the frame time and its
  `CControl` state is whatever the frame rate made of it. A fixed tick is what makes a run mean
  the same thing at 30 fps and at 144, which a recorded ghost and two networked peers both
  require. It costs nothing at 60 — see the trap list — and the ODE's own adaptive substepping is
  unchanged underneath it.
- **A ghost is played back as poses, not re-simulated from its input trace.** Both are recorded
  (`RaceRecording`) and they are not redundant: input replay only reproduces a run if every float
  operation lands on the same bit, and this game ships to native desktops and to a WebAssembly
  runtime with a different libm, so a ghost recorded on one and replayed on the other would drift
  unfalsifiably. The trace is for what has to re-derive a run rather than repeat it — regression
  tests, a run replayed against a changed constant, an AI corpus — and carries a hash of the force
  model so a stale one says so.
- **A scripted run neither keeps a ghost nor races one.** `--auto-input=` is every reference
  capture; a capture that set a best time would leave a file behind and every later capture of
  that course would come out with a second penguin on the slope, differing between machines for
  no reason visible in the frame.
- **Every peer simulates only itself and broadcasts snapshots.** No host authority over positions,
  no rollback, no prediction — the surface is identical everywhere and the only shared mutable
  state on the course is the herring. Collisions between racers fit under that without an
  authority *because they are resolved twice*: see the next entry.
- **Racers collide with each other, and it is resolved independently by each of them.** ETR has
  nobody on its hill to hit, so there is nothing to port — `RacePhysics._adjust_racer_collision` is
  the tree collision made symmetrical. Each body reads the others out of a `RacerField` the scene
  publishes once a tick and applies the textbook equal-mass impulse to *itself* (restitution 0.35,
  horizontal, plus an overlap term that separates two bodies with no closing velocity between
  them). What one body is paid the other pays, with neither writing to the other, which is what
  lets the other body be a remote peer that is not simulated on this machine at all. Symmetrical
  to the tick, not to the bit: each resolves against the other's velocity as published at the
  start of it. What it
  costs is agreement: a peer is resolved against where it was `INTERPOLATION_DELAY` ago, so a hard
  bump is felt slightly differently at each end. **A ghost is not in the field** — `Racer.collides()`
  is the predicate — because a recording of a run that already happened cannot be pushed back.
- **Herring are shared and first come, first served** between simulated racers, because
  `RacePhysics.items` is one `ObjectGrid`. A ghost cannot take one — it is not simulated and never
  touches the grid — and over the network each machine only removes what its own racers collected.
- **Only the local player's slide and impacts are audible.** The migrated mixer has one voice
  per cue and no positional audio, so another racer's collision three hundred metres up the hill
  would be indistinguishable from your own. Running into another racer plays `tree_hit`, the only
  impact cue the original ships: a collision the player can feel in the steering and cannot hear
  reads as the physics glitching.
- **There are computer opponents, and the original has none.** ETR races the clock: `CRacing`
  simulates one `CControl` and the only other times on the hill are the highscore table's. A field
  of 1–9 is a second mode beside Practice, chosen on the course screen. What it deliberately is
  not is a difficulty applied to the *simulation* — every racer is the same 20 kg point mass under
  the same §4.1 forces, because `characters.lst` carries no per-character constants and neither
  does this. `AISkill` moves habits only: lookahead, reaction, nerve, paddle discipline, tree
  clearance, weave.
- **An opponent is told where the other racers are.** Everything else an `AIInputSource` reads is
  in its own `RacePhysics`; the racers are not, because they are bodies being integrated elsewhere
  on the same tick. They arrive as the same `RacerField` the simulation bounces off, so the racer
  an opponent steers around is exactly the one it would hit. The steering term is a *soft* penalty
  and deliberately much weaker than the tree's — an opponent will drive through another to miss a
  trunk, because the trunk is the one that costs a race. Without it, two opponents that both want
  the same herring converge on it and spend the rest of the course shouldering each other.
- **A race against opponents draws no ghost**, whatever `[game] ghosts` says. The HUD has one
  status line, and with a field on the hill that line is the standings; a translucent copy of
  yourself beside eight racers is one more thing to mistake for one of them. The run is still
  recorded and a best time is still kept.
- **An opponent's grooming counts.** Nine simulated racers stamp the same `SnowField`, and packed
  snow is faster here, so a time set in a race is not strictly comparable to one set alone —
  and it is still stored as a best time. Racing a groomed line is racing.
- Numeric string IDs became semantic keys (`PRESS_ANY_KEY_TO_START`); old IDs are traceable via
  `i18n/legacy_string_ids.cfg`. `ghost`, the Configuration screen's *Race your best time*, the main menu's
  *Race the computer* and the course screen's *Opponents* / *Skill* / *Easy, Medium, Hard* are the
  strings so far that are neither migrated nor keyed — the original has neither ghosts nor
  opponents, so there is nothing to migrate and a `tr()` key would resolve to nothing in all 13
  languages. The finishing place reuses the migrated `POSITION` and `1ST`..`10TH`, which is also
  why the field stops at nine.

## Licensing

ETR code is **GPL-2.0-or-later**. Physics *constants and the physical model* are facts about a
simulation and are the valuable part — implement from `etracer.md` §4.1 rather than translating
C++ line-for-line. Data assets have mixed authorship (`etr-0.8.4/data/credits.lst`, `AUTHORS`);
treat every reused asset as needing its own licence check.
