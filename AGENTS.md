# AGENTS.md — PenguinRacer

Godot 4.7 rebuild of **Extreme Tux Racer 0.8.4**: downhill penguin racing with the original's
physics model and real snow deformation. Ships to **web (WebGL2 / Compatibility)** and **desktop
native (Vulkan / Mobile renderer)** from one project; both targets matter equally — see
architecture rule 2 and [RenderBackend]. **Android** is a third export and runs Mobile like the
desktop (Compatibility where a device has no Vulkan, or where the player picks it in the settings
screen — `RenderBackend.choose`, read back at the next launch); phones (native or in a browser) race with tilt, on-screen buttons or a mix of the two ([TouchScheme]).

**This is a rebuild, not a port.** Only the physics model is translated faithfully (constants are
the game). Everything else is redesigned; original content is imported into the new shape.

## Source documents

| File | Use it for |
|---|---|
| `etracer.md` | What the original C++ does. §4.1 = physics constants (authoritative), §5 = legacy file formats. |
| `godot-port-plan.md` | Architecture, data model, phases, risks. |
| `PROGRESS.md` | What is built today, and the known gaps. The running log — the full story behind most traps below is there. |
| `history.md` | How it got here: the spikes, and the discoveries that changed the plan (§1–§26). Settled — read it for the reasoning behind a decision, not for current state. |
| `materials.md` | How a terrain material works: `terrains.lst` → `TerrainLayer` → friction on the CPU and shading on the GPU, why there are 43 records, what the editor can author. |
| `docs/DEVELOPMENT.md` | Commands, prerequisites, layout, the web build, the capture harness. |
| `README.md` | Public front page: the project, the eight design decisions, licensing, credits. Keep its status claims in step with `PROGRESS.md`. |

Keep all seven current. State goes in `PROGRESS.md`; once settled and only the reasoning is worth
keeping, move it to `history.md` and leave the distilled lesson in the trap list. Corrections to
the plan go in `godot-port-plan.md`, dated.

## Layout

```
game/                     Godot project (mobile on the desktop, gl_compatibility on the web)
  scripts/physics/        RacePhysics + surface + snow — plain RefCounted, zero node deps
  scripts/course/         CourseData, TerrainLayer, TerrainOcclusion (heightmap AO bake),
                          CliffSet (rock faces laid over a course's walls + the camera's lift),
                          prefabs, events, environments, CourseCatalog/Listing (the menu's
                          index + category), ExternalCourses (courses added by address)
                          (EnvironmentPreset + LightCondition: a course names a place,
                          a race names the time of day — ETR's light_id)
  scripts/render/         terrain chunks, GPU snow field, spray, SnowFall (falling flakes +
                          far snow, all world-anchored), LensSnow (flakes melting on the camera,
                          out of focus, kept off the middle), LensFlare (the sun's glare and
                          ghosts, hidden by whatever covers the disc), SunShafts (rays of the
                          sky round the disc past whatever stands in front of it), MotionBlur (the camera's smear
                          over the frame, the racers kept sharp), IceReflection (planar mirror for the ice),
                          IceEnvironment (cube of the hill round the racer, for the ice),
                          ConiferMesh (3 LOD meshes + hemi-octahedral maths), BareTreeMesh
                          (grown leafless tree, 3 LODs + its drawn twig/bark texture),
                          ShrubMesh (bush from `shrub.png`, 3 LODs), Forest (any of the
                          three: cells × levels, per-tree dithered LOD, wind + snow),
                          Atmosphere (the procedural sky's globals: haze, mist, ridges),
                          CourseLights (night torches, flags → torches),
                          TreeShadowBake (the trees' shadows in the terrain, per sun),
                          PropMesh (boulder, stones, log, stump: procedural solid props)
  scripts/camera/         chase camera
  scripts/shell/          main/course/settings menus, HUD, LobbyMenu (connect → browse → room,
                          own CourseMenu instance), LoadingScreen (shared by menu and race),
                          TouchControls (the phone's on-screen buttons + tilt level),
                          TouchListScroll (drag/flick scrolling for every menu ItemList)
                          MenuSnow (ETR's pointer-scattered snow behind the main menu)
  scripts/race/           RaceScene (tick loop + course), RacerRoster (who is on the hill, who
                          is winning), IntroSequence, the racer layer (Racer, SimulatedRacer,
                          PlaybackRacer, RacerState — the 18-float snapshot that is also the
                          ghost and wire format — RacerStateStream, InputSource kinds incl.
                          AIInputSource + AISkill), RaceSetup (practice or a field of 1..9),
                          RaceRecording, RaceRecorder, SavedRunStore, RaceOutcome,
                          TiltSteering (gravity → steer/paddle/brake), MotionSensor
                          (gravity in screen coordinates, native or via `devicemotion`)
  scripts/net/            RaceNetwork autoload (`Net`: socket, lobby protocol, snapshots),
                          LobbyServer (rooms; the only thing on the wire that decides anything),
                          WebFileServer (web export over HTTP with COOP/COEP), ServerMain
  scripts/character/      CharacterRig, KeyframePath (root motion), CharacterCatalog/Listing
  scripts/audio/          AudioDirector autoload + generated sound/music banks
  scripts/config/         GameConfig autoload (settings file), QualityPreset (the five
                          quality presets and the knobs they set), RenderBackend (which renderer,
                          and shadows), LaunchArgs (command line + URL query), DisplayModes,
                          PackStream (streamed web packs, risk S6; no-op elsewhere),
                          Language (en | de, auto-detected from the platform locale),
                          TouchScheme (buttons | tilt_steer | tilt_speed | tilt | off, and "is this a phone")
  scripts/debug/          DebugCapture autoload (headless screenshots / scripted input), key_log
  shaders/                terrain, etr_skybox, procedural_sky, object_billboard (items), object_cross (shrubs),
                          object_prop (PropMesh's boulders, stones, logs, stumps),
                          conifer + conifer_impostor (all three species; + conifer.gdshaderinc:
                          LOD fade, sway, snow, twig alpha), conifer_bake, snow_trail, snow_flakes, lens_snow, lens_flare, sun_shafts, motion_blur, menu_snow,
                          s1_displace, torch_flame, etr_illumination.gdshaderinc (ETR's
                          sum-then-clamp, included by everything lit), atmosphere.gdshaderinc
                          (sky gradient, ridges, the `FOG` every lit shader writes, torchlight)
  addons/etr_import/      one-way, re-runnable importer from the ETR data tree
  addons/course_gen/      generators of authored courses (Forest Trail, Mountain Forest) and
                          CourseGenKit, what they share — the importer's output shape, never
                          visited by the importer; CliffBuilder (a rock face over a wall)
  courses/<name>/         GENERATED: course.tres, course.tscn, heightmap.res,
                          ambient_occlusion.res, splat_*.png, cliffs.res (44 by the importer,
                          forest_trail and mountain_forest by tools/gen_<name>.sh)
  resources/  i18n/       GENERATED: layers, prefabs, environments, events, course + character
                          catalogs, five rigs + previews, sound bank, music, 13 translations
  i18n/                   GENERATED penguinracer.csv (ETR's strings × 13) + HAND-WRITTEN ui.csv
                          (everything ETR has no string for, en + de) — see Language
  assets/sounds|music/    GENERATED: 10 effects, 10 pieces, copied verbatim
  assets/trees/           BAKED: conifer, bare-tree + shrub impostor atlases (tools/bake_tree_impostors.sh)
  scenes/                 main_menu.tscn (main scene), course/character/settings/ghost/lobby/
                          results menus, race.tscn, loading_screen.tscn, key_log.tscn,
                          server.tscn (the same project headless, no course)
  user://runs/            NOT in the repo: runs kept from the results screen (SavedRunStore),
                          raced as a translucent ghost from the main menu
  user://external_courses.cfg  NOT in the repo: courses added by address (the entries only;
                          packs are re-fetched per session into user://cache/external/)
  themes/                 etr_menu.tres — ETR's `common.cpp` palette + checkbox icons
  tests/                  headless suite + ODE benchmark + tone_report.gd,
                          bake_tree_impostors.gd and tree_portrait.gd (not tests)
  spikes/s1_pingpong/     ping-pong render-target spike (S1)
  spikes/s7_reflection/   planar reflection spike (S7)
etr-0.8.4/                original source + data — READ-ONLY, never write here
tools/                    import_all.sh; serve.sh (dedicated server + web export);
                          build_server.sh (Linux server export + build/web → build/server/);
                          shot.sh (deterministic screenshot, real GPU when present);
                          bake_tree_impostors.sh (re-bake after changing a tree's mesh);
                          tree_portrait.sh (one species up close, any level, no course);
                          png.py, regionstats.py, linstats.py (slow pure-Python capture stats —
                          tests/tone_report.gd does the same in a second); webtest/ (COOP/COEP
                          server + puppeteer runner); gen_course_export_presets.py +
                          build_web_streamed.sh (streamed web export, S6);
                          build_android.sh (the `Android` preset → build/android/*.apk);
                          gen_forest_trail.sh, gen_mountain_forest.sh (regenerate an
                          authored course);
                          gen_course_index.py (courses.json for a folder of course packs)
```

Generated trees (`game/courses/`, `game/resources/`, `game/assets/`) are committed. A re-import
rewrites every `course.tscn` and `.tres` with fresh random ids even where nothing changed, so
check what actually changed before committing 116 000 lines of churn:

```bash
git diff -U0 -- 'game/courses/*/course.tscn' \
    | grep '^[-+]' | grep -v '^[-+][-+][-+]' | grep -v 'unique_id='
```

Empty output means only ids churned — `git checkout` them and commit the rest.

## Commands

```bash
godot --path game                                                  # play (main menu)
godot --path game -- --course=bunny_hill                           # ... straight into a course
godot --path game -- --character=trixi                             # ... as another character
godot --path game -- --remote-keyboard                             # ... over a pulsed remote keyboard
godot --path game -- --no-audio                                    # ... silent, for captures
godot --path game -- --no-intro                                    # ... skipping the start animation
godot --path game -- --fps                                         # ... with a frame-rate readout (this run only)
godot --path game -- --lang=de                                     # ... in German (en|de|auto)
godot --path game -- --touch=buttons                               # ... with a phone's on-screen controls (tilt|tilt_steer|tilt_speed|buttons|off)
godot --path game -- --crosswind=strong                             # ... in a crosswind (none|light|strong)
godot --path game -- --wind=2                                      # ... in ETR's wind grade 1..3 instead
godot --path game -- --snow=3                                      # ... snowing (0..3)
godot --path game -- --light=night                                 # ... under another sky (sunny|cloudy|night|thunderstorm)
godot --path game -- --sky=etr                                     # ... with ETR's skybox and flat fog (procedural|etr)
godot --path game -- --quality=fast                                # ... at a quality preset (fastest|fast|medium|high|best)
godot --path game -- --tree-shadows=baked                          # ... trees' shadows baked, not mapped (dynamic|baked)
godot --path game -- --server=penguin.example                      # ... lobby on that server
godot --path game -- --lobby                                       # ... lobby on the configured one
godot --path game res://scenes/key_log.tscn                        # what the link does to the keyboard
godot --headless --path game --script res://tests/run_tests.gd     # test suite + benchmark
godot --headless --path game --script res://tests/tone_report.gd \
    -- shot.png 1.0 lit:100,620,500,715                            # per-region tone of a capture
godot --path game spikes/s1_pingpong/s1_spike.tscn                 # snow RT spike
godot --path game spikes/s7_reflection/s7_spike.tscn               # planar reflection spike

# dedicated server — races and the web build from one process
# (a relative --web-root resolves against `game/`)
godot --headless --path game res://scenes/server.tscn -- --port=27015 \
    --web-root=../build/web --web-port=8060
./tools/serve.sh                                                   # ... same, with defaults
./tools/build_server.sh [--build-web]                              # ... packaged into build/server/

./tools/import_all.sh [--course=bunny_hill] [--force]              # 4-pass importer
./tools/gen_forest_trail.sh                                        # the authored course, its props, its catalog row
./tools/gen_mountain_forest.sh                                     # ... the other one, and its lodged trunk
./tools/bake_tree_impostors.sh [conifer|bare|shrub]                # after any tree mesh change
./tools/tree_portrait.sh /tmp/t.png bare --dist=8 [--level=2]      # one species up close, no course
./tools/build_android.sh [--release] [--install]                   # Android APK (setup: .devcontainer/setup-android.sh)

# headless verification
godot --path game -- --capture=/tmp/shot.png --capture-frames=200 \
    --auto-input=carve --camera=above --course=wild_mountains
# --auto-input= is carve | brake | paddle | jump (jump is the only way to capture the
# gauge's inner half) | ai (the computer's driver: follows a course's line to the finish). It also DISABLES the start animation, so those captures run on a
# different clock from a player's. To reproduce what a player saw in the first seconds,
# pass no input source — --capture= plus --course= plays the intro and steers nowhere:
godot --path game -- --capture=/tmp/shot.png --capture-frames=655 \
    --course=penguins_cant_fly --opponents=3 --character=trixi --no-audio

# web — streamed build: base + one .pck per course + one for music
./tools/build_web_streamed.sh
node tools/webtest/server.js build/web 8060 &
node tools/webtest/run_web_test.js \
    "http://127.0.0.1:8060/index.html?course=bunny_hill&nointro=1" /tmp/web.png RACE_READY
MOBILE=1 MOBILE_TILT=9,3,2.5 node tools/webtest/run_web_test.js ...  # ... as an Android phone, tilted

# what the browser renders, without a browser
godot --path game --rendering-method gl_compatibility --rendering-driver opengl3
SHOT_METHOD=gl_compatibility SHOT_RESOLUTION=1024x576 tools/shot.sh /tmp/web-look.png
```

**Settings** live in `user://penguinracer.cfg` (Linux: `~/.local/share/godot/app_userdata/PenguinRacer/`),
written with comments on first run; delete it for defaults. The **Configuration** screen edits
the display rows (window size, frame-rate readout, fog distance), the quality rows
(render scale, anti-aliasing, sky and sky detail, tree detail distance, shadows, tree shadow
type, tree shadows, shadow detail, shadow edges, ice reflections, ice reflects the world, sun rays, motion blur) and writes the same commented file back. The **quality preset**
drop-down (Fastest … Best quality) sets the quality rows together and is *derived*, never stored:
`QualityPreset.matching` names whichever preset the values are, else "Custom". **High quality is
the shipped frame and `GameConfig`'s defaults** — `TestConfig` holds them together, so an untouched
file moves no reference capture; keep it that way when adding a knob. Elsewhere: `[multiplayer] player_name`/`server` on the **Network
multiplayer** screen, `port` file-only, `opponents`/`opponent_skill`/`snowfall`/`conditions`/`wind` on
the course screen. Resolution offers the display's own modes (`DisplayModes`); resolution and
fullscreen are hidden on the web and on a phone, where the page or the system sizes the canvas;
`[controls] touch` (buttons/tilt_steer/tilt_speed/tilt/off) is shown only on a phone. The shadow
map's rows (tree shadow type, tree shadows, shadow detail, shadow edges) are hidden wherever
`RenderBackend.supports_light_shadows()` is false but their values are still written back, so a
desktop preference survives a browser session; the shadows row stays, since it also switches the
baked tree shadows. A ghost is not a setting: it is whichever
saved run the player picks from **Race against ghost**, or none.

**Export presets**: `Web` (streamed base — engine, shell, all 45 previews), one generated
`Course_<dir>` per course, `MusicPack`, `WebSpike`, `Server` (Linux dedicated server), `Android`
(whole game in one APK, arm64, prebuilt template). The generated presets belong to
`tools/gen_course_export_presets.py`, which finds them by name — re-run it when a course is
added, removed or renamed, **and after saving presets in the editor**, which drops its markers. The test server must set COOP/COEP and `.wasm`/`.pck` MIME types or
the export fails obscurely. Prerequisites: Godot 4.7.2 on `PATH` as `godot`, web export
templates, and **Vulkan** for the desktop (Mobile renderer).

**Captures**: `SHOT_METHOD` is `mobile` (desktop default), `gl_compatibility` (browser) or
`forward_plus`; the driver follows it. `SHOT_TREE_SHADOWS=dynamic|baked` picks the trees' shadows, `SHOT_SUN_SHAFTS=on|off` the sun's rays, `SHOT_MOTION_BLUR=on|off` the camera's smear. `tools/shot.sh` uses the container's real GPU (Wayland
socket + `/dev/dri/renderD128`, needs `libegl1 libegl-mesa0 libdecor-0-0`; without them Godot
blames "video card drivers" and silently falls back). ~3 s for 120 frames on the GPU, ~2 min on
llvmpipe; `SHOT_FORCE_SOFTWARE=1` takes the slow path, worth doing before trusting a small tone
measurement. There is no software Vulkan here, so llvmpipe can only serve Compatibility —
`shot.sh` says so rather than capturing the wrong renderer.

## Current state

Detail is in `PROGRESS.md`; this is the summary.

| Area | State |
|---|---|
| 0 — physics core | **done** — every §4.1 force, ODE23 adaptive, spatial grids. 4724 assertions, 0 failures, 13 s headless. |
| 1 — importer + first course | **done** — 44 courses, 43 layers, 14 prefabs, 8 environments, 5 characters, events, 111 strings × 13 languages. Plus two authored courses, Forest Trail and Mountain Forest (`addons/course_gen/`), with six prop prefabs of their own (one only a collider). |
| 2 — rendering | partial — Mobile on the desktop, Compatibility on the web (trap list: *sRGB-blended shadow pass*). ETR's illumination clamp in every lit shader except the character's; desktop-only PSSM shadow, the trees' shadows baked into the terrain's vertex colour on the web and by choice on the desktop (`TreeShadowBake`). Splat PBR, chunked terrain, instanced objects (conifers, bare trees and shrubs are 3D meshes at 3 LODs + an octahedral impostor, dithered hand-overs, wind sway, shader snow — [Forest]; anything else collidable is ETR's two crossed planes with a hashed yaw; items are billboards), ETR's HUD redrawn as primitives ([RaceHUD]), migrated skyboxes. Tone matched on Bunny Hill at both ends in all three channels; no LightmapGI. Snow/ice micro-relief, glint, rock detail texture, Fresnel sky, ice reflecting the racers (`IceReflection`) and, as a setting, the hill round them (`IceEnvironment`), textured carve spray, camera motion blur as a setting (`MotionBlur`, Best only). Heightmap AO baked at import + trench-wall AO; shaded/occluded/carved snow tinted blue (fake SSS). |
| 3 — snow | mechanism proven, integration partial — GPU trail map + CPU mirror; a carve leaves a shaded trench with a ploughed lip. |
| 4 — character | **done for all five** — skinned mesh from `shape.lst`, keyframe clips as `AnimationLibrary` + `KeyframePath` root motion, start animation (`CIntro`), finish clips on the results screen (`RaceOutcome.clip`), racing pose layer (`CharacterRig.adjust_joints`, ETR's `AdjustJoints`) driven off `RacerState` alone so ghosts and peers animate. `GameConfig.character` picks one. |
| 5 — game shell | partial — main menu → Practice / Race the computer / Network multiplayer / Race against ghost / character / Configuration; results screen with named runs; ETR palette theme; course + character catalogs (course list in four parts: Tux Racer, ETR, PenguinRacer's own, added by address); English + German, detected or chosen on the settings screen; audio (`AudioDirector`, ETR's one-voice-per-cue mixer). Missing: cups, medals, profiles (data imported), volume controls, ETR's menu art (licence audit). |
| 6 — polish/ship | not started. |
| phones | **done, not raced on hardware** — `Android` preset + `tools/build_android.sh` (Mobile renderer by default, Compatibility selectable in the settings screen from the next launch, whole game in the APK, Medium preset on first run); tilt / tilt-steer / tilt-speed / buttons / off on Android and in a phone's browser (`TouchScheme`, `TouchControls`, `TiltSteering`, `MotionSensor`); back button is Esc. Verified by the suite, desktop renders with `--touch`, and Chromium emulating an Android phone with synthetic `devicemotion`. |
| sky + atmosphere | **done** (beyond ETR) — procedural sky (sun disc low ahead-right with a lens flare and, as a setting, rays past what stands in front of it, drifting clouds; stars, moon, aurora at night), three layers of distant ridges, aerial perspective and valley mist in every lit shader's `FOG`, night torches inside the clamp (baked into the terrain). `[display] sky = etr` / `--sky=etr` is the old frame to the level. See the deviations. |
| weather | **snow (0–3), sky (sunny/cloudy/night/thunderstorm) and wind (none/light/strong) done** — `SnowFall` (world-anchored streaking flakes + far snow, deterministic) and `LensSnow` (a few defocused flakes melting on the lens, off the middle), `LightCondition` and `WindField.init_crosswind`, all on the course screen, remembered in `[game] snowfall`/`conditions`/`wind`, carried on a lobby room. The sky moves sun, ambient, fog, skybox, tints, ice, and shadows (`EnvironmentPreset.casts_shadows`). The wind blows from a side rolled per start and moves the trees, the snow, the HUD's rose and a racer in flight. The thunderstorm is ours, not ETR's (`Lightning`, see the deviations). `evening` and ETR's wind grades (`--wind=`) are not offered. |
| computer opponents | **done** (beyond ETR) — `RaceSetup` 1–9 opponents, each a `SimulatedRacer` + `AIInputSource` scoring nine candidate lines. Skill moves habits, never physics: 30 s on a 22° slope gives easy 231 m, medium 333 m, hard 422 m, a player holding straight 413 m. Deterministic from a seed. Solid via `RacerField`. |
| multiplayer foundation | **done** — fixed 60 Hz tick with interpolated presentation; `SimulatedRacer`/`PlaybackRacer`; `RacerState` is the only thing drawn and is the ghost and wire format. Ghosts end to end: record, keep from the results screen, race from `GhostMenu`. |
| network multiplayer | **done** (beyond ETR, plan §8.4), works in a browser — one dedicated server serves the web build over HTTP and races over WebSocket. Rooms with optional passwords, admin picks course and starts. Server relays snapshots; each peer simulates itself. Names unique server-wide. Countdown instead of intro; race ends when the last racer finishes. See the deviations. |

### Spikes

- **S1** ping-pong `SubViewport` RTs on web — **PASS** native + Chromium/WebGL2. Firefox untested.
- **S2** GDScript ODE loop — **PASS**: 0.045 ms/frame native, 0.073 ms in-browser. **Do not build
  the godot-rust GDExtension contingency.**
- **S6** web cold-load size — **done**: slim base (~65 MB, was 161 MB) + one `.pck` per course
  (268 KB–9.2 MB) + music (14 MB), mounted by `PackStream` on demand. `LoadingScreen` is in both
  `main_menu.tscn` and `race.tscn`, so it survives the scene swap and stays up until the hill is built.
- **S7** planar character reflection under Compatibility — **PASS** native; settled the design
  (see the ice-reflection deviation). **Web untested** — the one open risk on the feature.
- **S3–S5** open: dequantization eyeball per course, RGBA8 snow banding, asset licence audit.

### Known gaps

- Near-field terrain mesh too coarse (~0.5 m vertices vs a 0.45 m contact patch) — the trench
  shades but has no silhouette. Fix: denser mesh inside the deformation window, then delete
  `Racer._drawn_snow_lift`.
- The terrain slide sound has no speed term, and 12 of 43 terrains (incl. `snow`) name no sound —
  both faithful, both the obvious first improvement.
- Snow tone is **measured** only on Bunny Hill / `tuxracer_sunny`; the other six presets are
  **derived** from it in display space (history §25). All 44 courses select a sunny preset, so the
  fit reaches every course; each other sky would still benefit from one reference capture.
- The lit near field clips more than ETR's: upper half ~6 levels over (median G 254 vs 248; 53 %
  clipped vs 3.5 %). The reference is not a matched view (speed, trench, 70° FOV at 19° vs 60° at
  10°); closing it wants a matched-camera reference, not another scalar.
- **The character has no illumination clamp**, and fixing it is three parts, all needed — half of
  it is worse than none: `srgb_to_linear` on the migrated `[diff]` colours (stored linear, so Tux's
  back reads 89/255 vs ETR's 26), the clamp include, and a specular lobe from ETR's
  `[spec]`/`[exp]`. Measured together: back 22 vs 26, belly 199 vs 199. Needs a
  `character.gdshader` (+ a transparent variant for `Racer.make_translucent`) and a re-import.
- Ice is 16 levels darker under Compatibility than Mobile (`tuxway` mid-lake: 160.5 R vs 176.6)
  after the `EMISSION` fix; the residual is elsewhere in the ice branch. Snow agrees within a level.
- Asset licence audit not started — blocks Phase 5, long lead time.

## Architecture rules

1. **`RacePhysics` has zero node dependencies.** Plain `RefCounted` stepped against a
   `SurfaceProvider`. This is what makes headless golden tests possible — do not break it.
2. **Two renderers, and the web one is the floor.** Desktop runs **Mobile** (Vulkan), web runs
   **Compatibility** (WebGL2). Nothing may *depend* on a feature Compatibility lacks — no compute
   shaders, no `RenderingDevice`, no HDR (RGBA8 only), no decals/volumetrics/SSR/SDFGI/TAA, no
   manual particle emission — but the desktop may **add** one behind a gate, provided the web frame
   without it is still worth shipping. `Sun.shadow_enabled` is the one today, gated by
   `RenderBackend.supports_light_shadows()`; `race.tscn` ships it off because a scene file cannot
   ask which renderer loads it.
3. **Gameplay never reads back from the GPU.** Readback stalls the browser. Snow is dual-represented
   on purpose: `SnowFieldGPU` (1024², 64 m toroidal window, for pixels) and `SnowField` (128² CPU
   mirror, for feel). They deliberately do not match.
4. **The importer is one-way and re-runnable.** `etr-0.8.4/` is read-only. Output lands in
   `game/courses/` and `game/resources/`. A course or layer edited outside the importer no longer
   hashes to its `import_fingerprint` and is skipped without `--force`.
5. **Deviations from the original are marked `DEVIATION` in the source, each with a reason.**
6. GDScript only for gameplay — C# has no web export. Avoid GDExtension addons.
7. **The simulation runs on a fixed tick and the presentation interpolates.** `RaceScene.SIM_HZ`
   is 60, and `_process` ticks up to the frame, not to the last tick before it (trap list). Nothing
   that affects the race runs on frame time: input is polled per tick; only camera lag, streaming,
   particle rates and the deformation render target run at the screen's rate.
8. **A racer is whatever fills a `RacerState`.** The presentation reads that and nothing else, so
   it cannot tell the player from an AI, a ghost or a peer. Do not branch on `Racer.kind` in drawing
   code; add a subclass or an `InputSource`. The packed layout (18 floats: the pose plus four the
   rig poses its joints from) is a file and wire format — appending is a version bump, moving a
   field silently reinterprets every stored ghost.

## Traps found the hard way

Each entry is the rule; the discovery story is in `PROGRESS.md` or the cited `history.md` section.

### Methodology

- **Sweep a constant, do not reason about the formula.** Write a number into a shader output that
  cannot be confused with anything else and read what comes out. Several bugs below survived being
  reasoned about and fell to this.
- **A fit is only evidence at the angle, view and case it was taken at.** A term that is small
  where you fitted can grow 6.5x elsewhere (ice Fresnel). The variable that separates a good case
  from a bad one is one you have *measured in both*; a mechanism measured only in the broken frame
  is not a diagnosis.
- **When the presentation moves and the simulation provably does not**, look at whichever term
  reads the world rather than the racer, and measure it over time, not off a still frame — a still
  frame cannot show an oscillation.
- **Count the magnitude of a capture diff, not the pixels.** Any surface change perturbs the run
  at 1e-7, the adaptive ODE amplifies it, and view-dependent snow relief redithers a sixth of the
  frame by one level. A regression is few large deltas; chaotic divergence is many ±1s. Bisect by
  reverting one file at a time.
- **`GPUParticles3D` seeds itself per run**, so the spray is never byte-reproducible. Mask
  x 450–700, y 250–520 out of a Bunny Hill `carve` capture; everything else reproduces to the byte.
  Captures off the real GPU are not byte-reproducible run to run at all — measure the frame, not
  the md5.
- **A run on the real GPU can hang at random, so give every one a timeout.** A Mobile capture
  (`--light=night --snow=2`) sat for minutes on ~2 s of CPU and never wrote its PNG; the same
  command then passed on its own and again inside a loop, with no shader or code change in between.
  Nothing in `tools/shot.sh` or `godot` gives up by itself, so a hang stalls a whole batch. Wrap
  each run in `timeout -s KILL 90 …` (a headless suite run wants ~300), check that the PNG or the
  expected output line is there, and re-run a run that was killed before suspecting the change.
- **Pull the exposure down before concluding anything about a scene that clips.** `tonemap_exposure`
  0.25 shows *which* channel ran out of headroom, but the two exposures do not differ by a clean 4x
  at the bright end — fit at the shipped exposure.
- **`--resolution` is logical; this container's compositor scales it by 1.25.** `SHOT_RESOLUTION=1024x576`
  gives a true 1280x720. Also, under `aspect="expand"` a non-16:9 window is not a 1280x720 canvas.
  Check the PNG's size before trusting any documented region box (history §11/§22 boxes were hit).
- **`DebugCapture` counts frames from process start**, so any frame added on the way into a race
  renumbers every reference capture. The loading bar only yields frames when
  `PackStream.is_streamed()`; verify with `Engine.get_process_frames()` at `RACE_READY` (0 on native).
- **A git-stash A/B stashes your tooling too.** Commit tooling first, `git stash push -- game`, and
  where the change is one constant just toggle the constant. `git stash push -- game` leaves
  untracked files alone, so an unadded probe at `game/tests/_probe.gd` survives the stash.
- **The headless suite's own "N ObjectDB instances leaked" (34–37, wandering) is noise** —
  `run_tests.gd` quits without `AudioDirector`'s wait. Reproduce a real leak from the game
  (`--capture=` exits cleanly) and read it with `--verbose`.
- **An unreachable code path is an unmeasured one** (history §25), and **a migrated field is not
  ported until something reads it**: trace a new property to its consumer and test it there.

### Import and data

- **Godot's texture importer edits splat maps.** `process/fix_alpha_border` rewrites RGB where
  alpha < 30/255 — on a weight field that moved 19 % of penguins_cant_fly. The importer writes the
  `.import` sidecar itself (`ETRImport.write_splat_import`, also disabling `detect_3d/compress_to`);
  `tests/test_splat.gd` asserts the loaded weights still sum to one. Generated data sharing a
  container with art inherits the art pipeline's opinions. See `materials.md` §1.2.
- **Splat maps are data, not colour.** A `source_color` hint crushes a minority layer ~10×.
- **A splat map and a heightmap are vertex grids, not textures.** Grid-to-grid is
  `x · (n-1)/(target-1)`; reading as a texture means texel centres, `(uv · (n-1) + 0.5) / n`. With
  an even upsample factor, interpolate rather than round (ETR's per-vertex alpha does too). Errors
  here are invisible — every material just sits slightly wrong and disagrees with the friction.
- **Index maps are integer arithmetic**: `x * sw / target.x`, never `int(float(x)/n * n)`
  (`178/179.0*179.0` truncates to 177 — whole 50 cm stripes ran on the wrong friction).
  `TestSurface._splat_resample` guards it.
- **A course's splat channels are positional**: a layer that fails to load keeps its slot with a
  default, or every later layer plays the wrong friction.
- **A terrain's identity is its record, not its `[name]`.** `terrains.lst` has `pave04` three
  times. The importer keys on the record and disambiguates by texture stem; `legacy_name`/
  `legacy_index` point back. Two records name textures not in the tree — warned, as in ETR.
  Terrain colour keys also collide within ±30 (`snow`, `dirty_snow`, `thin_snow`, `strike_snow`);
  warned, not hidden. (history §17)
- **`env/environment.lst` needs `CSPList(true)`** or every environment merges into the first. It
  also spells a bool `[high_res] true`; `SPList.get_bool` accepts both forms like `Str_BoolN`.
- **`[vol]` in `sounds.lst` is dead data** — ETR never reads it; the live mix is
  `SetSoundVolumes` in `racing.cpp` (six of ten, different numbers). Both migrated:
  `SoundCue.race_gain` (live), `legacy_volume` (file). Volumes clip at 100, so at 90 a 1.5 gain is 1.11.
- **Record provenance; do not observe it.** `CourseData.modified_in_editor` never fired — nothing
  can see an Inspector edit. `import_fingerprint` hashes what the importer wrote and
  `edited_since_import()` recomputes it; hash rather than diff, or every importer change makes all
  layers look hand-edited.
- **An exported field nothing reads is an invitation.** Per-layer `normal`/`roughness` texture
  slots were dropped rather than left as silent no-ops, when the terrain's eight albedos were eight
  samplers; a per-layer map would now be a second `Texture2DArray` (trap list, texture units). Do
  not add a per-layer field the shader cannot consume.
- **An authored course is the importer's output shape, not its input.** `tools/gen_forest_trail.sh`
  (and `gen_mountain_forest.sh`) writes `courses/forest_trail/` and its catalog row directly; `imported_from` is empty and the row's
  group is `CourseListing.AUTHORED_GROUP`, so `import_all.sh` never visits it and its catalog merge
  keeps it. Re-run the generator, not the importer, after changing it — and re-take its preview
  only on purpose: a run keeps an existing `preview.png`. **`resources/terrain/` is
  `terrains.lst`, record for record** (`TestTerrainLibrary`): a layer of an authored course's own
  (Forest Trail's `conifer_needles`) lives in the course's directory with its texture — each
  course its own copy, since a web pack carries only its own directory. **An uneven fall line is
  relief too** (Mountain Forest's chutes and benches, integrated over the mean `base_angle`), so
  keep it out of the occlusion bake: `TerrainOcclusion` measures against a uniformly tilted plane,
  and a change of gradient is not a bank that shades anything.
- **A play area that follows a trail is a polygon, and everything reads it.** Physics clamps the
  racer to it and the AI plans inside it (an AI reads no terrain but friction, so without it the
  computer ran straight on at Forest Trail's first bend). **Keep it off a wall**: the AI reads no
  slope, and a corridor 3 m up Mountain Forest's banks had it carve up them on every bend and stall
  on the rock — at 1 m it holds the gully floor. **Build it from the narrowest width over each
  piece**: a 24 m piece drawn from the width at its ends cut across a slot's pinch, and the AI
  raced into the slot's wall. `CourseLights` stands a torch every 22 m
  along its long edges, so pieces shorter than that get none; outward is taken from the winding.
- **A generator's placements share one random stream, so a rejection moves everything after it.**
  `_scatter` draws an object's yaw only once it is placed, and a freed footprint lets a later try
  succeed that used to fail: keeping Mountain Forest's props off its first rock face moved every
  log, shrub and tree down the course. A placement newly refused (`_on_cliff`) still spends its
  draw and keeps its footprint, which left the rest of the course exactly where it was.
  Diff the markers by type and position after a generator change, not the file.
- **A conifer's collision cylinder is as wide as its crown** (the marker's X scale), so a tree
  whose trunk stands off the trail can still reach into the play area. Keep every collidable
  object's whole cylinder out of the play area plus slack (`PLAY_CLEARANCE` in
  `gen_mountain_forest.gd`), or a racer hugging the edge hits trunks it cannot see.
- **An obstacle on the trail needs a straight line round it.** The AI aims one straight line
  about 30 m ahead through nine lanes. On a bend, or with the open side on the outside of the
  next bend, every lane round a fallen trunk left the play area and it drove into it. Mountain
  Forest's obstacles stand where the trail is nearly straight from 40 m before to 30 m after,
  leave open the side the trail turns toward (`open_side`), widen the trail beside them, and sit
  early in a chute: a crash at a chute's foot leaves a racer crawling across the bench below.
  The headless probe that found all of this, the hard AI through the real grid and play area,
  logging speed by distance, is worth writing again before moving an obstacle.
- **`DirAccess` over `res://` finds nothing in an exported build.** Anything the shell enumerates
  needs a generated index (`resources/courses.tres`).
- **Re-importing for a character change also rewrites object prefabs and every `course.tscn`**, and
  not only ids: fresh `objects/*.tres` gain `shader_parameter/etr_ambient = null`. Revert everything
  outside `resources/characters/` after a character-only import until somebody settles which side
  is right.

### Rendering and tone

- **Under Compatibility a shadow-casting light is drawn in a second pass blended in sRGB**
  (godotengine/godot#77496, #90259). You get `srgb(sun·albedo) + srgb(ambient)`: the sun lands
  5–10× too bright and its N·L gradient is crushed flat. No shader or gain can reach a framebuffer
  blend. Zeroing an energy culls the light and its pass, so isolated-light frames sum correctly
  there while the full frame does not. The fix is the renderer split; `RenderBackend` holds the
  story (history §24). Under Mobile, isolating a light is an ordinary technique.
- **`EMISSION` differs between renderers; `DIFFUSE_LIGHT`/`SPECULAR_LIGHT` do not.**
  `EMISSION = 0.5` reads 0.500 under Mobile and 0.216 under Compatibility. Additive terms go on
  `SPECULAR_LIGHT` in `light()`. Never calibrate against a constant written to a colour output.
  **`ALBEDO` is the same**: Compatibility sRGB-decodes it and passes a `source_color` uniform or
  sampler through undecoded, so textures agree by accident and anything *computed in linear*
  (vertex colours, constants) is decoded twice — the props' unsnowed rock and bark went near black
  on the web (25 vs 76). Build it in linear and encode under Compatibility (`object_prop.gdshader`).
- **Godot multiplies `DIFFUSE_LIGHT` by `ALBEDO` once, after the light loop**, so
  `DIFFUSE_LIGHT += ALBEDO * ...` squares it.
- **An additive term outside the illumination clamp undoes the clamp.** Bound it as the energy
  split it physically is — take the mirror's share out of `ALBEDO`. (The ice Fresnel was invisible
  at chase-camera incidence and turned a gully white at F = 0.6.) The same constant can be right
  for one question and wrong for another: `fog_color` is a bad sky radiance and a good distant-
  terrain one, hence `ice_distant_tint` gated on distance.
- **ETR shades in display space; Godot in linear.** Close the spread with
  `EnvironmentPreset.ambient_gain`/`sun_gain` (per-channel `Color`s, fitted at two points). Do not
  fold them into the migrated colours.
- **Godot sRGB-decodes `light_color`/`ambient_light_color`, and `light.lst` is not colours.**
  Decoding stretched the channel ratios (blue/red 1.43 → 2.23) and turned snow cyan-mottled.
  `EnvironmentPreset.as_light_color` pre-encodes; `TestEnvironments` asserts the round trip. And
  **a scalar energy cannot reproduce a per-channel clamp** — ETR's snow blue sits at the ceiling.
- **`light.lst` is not the whole light state**: OpenGL's default `GL_LIGHT_MODEL_AMBIENT` 0.2 sits
  under every `[amb]`. The importer adds it.
- **`Environment.ambient_light_sky_contribution` defaults to 1.0**, handing the ambient to the sky
  even with `AMBIENT_SOURCE_COLOR`. Set 0 when the ambient comes from the data.
- **`Environment.fog_density` gates depth fog too** (default 0.01 ≈ off). Godot ramps depth fog
  with `smoothstep` where ETR's `GL_LINEAR` is linear.
- **Terrain `SPECULAR` at Godot's 0.5 default blows snow out** (F0 0.04; ETR's terrain has none).
- **Directional shadows stop at `directional_shadow_max_distance`**; derived from the fog range in
  `RaceScene._shadow_range_for` — keep it tied to visibility.
- **Godot gives a phone its own shadow defaults under the `mobile` tag**:
  `directional_shadow/soft_shadow_filter_quality.mobile` is 0 — Hard, one depth tap, every texel a
  stair on the snow — and `directional_shadow/size.mobile` is 2048. `project.godot` sets the filter
  for both, tagged and plain; read the atlas size with `get_setting_with_override`. Check
  `ProjectSettings` for a `.mobile` twin before trusting any rendering default on Android.
- **Godot's soft shadow filter dithers, and only TAA undoes it** — Mobile has none. The dithered
  band is as wide as the kernel, counted in shadow-map texels, so a small atlas shows it most.
  Shrinking the kernel alone trades the dither for texel stairs, and Hard has stairs and no dither.
  What cleared it: smaller near texels (first cascade at 4 % of the range,
  `RaceScene._apply_shadow_detail`), `shadow_blur` 0.75, and Soft Medium (quality 3) — more taps.
  `[quality] shadow_filter` (the *Shadow edges* row) overrides that at race start via
  `RenderingServer.directional_soft_shadow_filter_set_quality`; Medium is still the default, and
  the project setting is only what applies before a race.
- **`shadow_normal_bias` is in shadow-map texels, not metres** (Godot multiplies it by the
  cascade's texel size), and `shadow_bias` is multiplied by `shadow_blur`. Too little normal bias
  shows as stripes, one set per terrain triangle, on slopes the sun grazes — which the snow's wrap
  lighting puts on screen. Diagnose acne with `DIFFUSE_LIGHT = vec3(ATTENUATION)` in the terrain's
  `light()` and a contrast stretch; it is on the desktop too, just easy to miss.
- **A mesh without a colour array reads `COLOR` as white**, which is what lets a course imported
  before `ambient_occlusion.res` draw unoccluded. `TerrainRenderer` drops an occlusion image whose
  size is not the heightmap's without a word; `TestOcclusion` checks every course's.
- **The terrain's vertex stage has no spare varying component left.** `splat_uv` is worked out
  in `fragment()` from `world_pos` (`splat_uv_of`) — a linear function of it, so the same value —
  to make room for the baked tree shadow, and `v_bake_lip.y`, the last one free, carries a rock
  face's ledge snow. Vertex colour is R sky, G torchlight, B tree sun, A one minus the ledge
  weight (1 on every chunk): the next per-vertex term needs a new varying (the phone's slot
  budget, below) or a packing.
- **A varying costs a whole slot, and a phone has 28.** Godot's Mobile renderer charges one slot per
  declaration (a `float` is a `vec4`) on top of 15 of its own; the limit is the GPU's
  `maxFragmentInputComponents / 4` — 32 on the desktop's Radeon, 28 on an Adreno 650. Over it, the
  shader fails *only on the phone* ("Too many varyings" in `adb logcat`) and the mesh draws in the
  default material: the whole course went white. Pack small varyings into `vec4`s (`terrain.gdshader`
  names the components with `#define`); `TestShaderBudget` holds every spatial shader to 28.
- **A procedural relief strength is not a 0..1 knob.** The detail map stores gradient w.r.t. UV
  (peaks ~12). Uniforms are metres of relief; put the unit in the name.
- **`normalize()` of a mipped white-noise tap is NaN**, and NaN survives a zero fade. Add the raw
  vector to the normal instead.
- **A trail-map normal is added to the terrain normal, never mixed into it**, or the whole course
  flattens.
- **Godot imports textures without mipmaps, and `filter_linear` ignores them anyway.** Forced via
  `[importer_defaults]`; terrain/splat samplers are `filter_linear_mipmap_anisotropic`, whose level
  is the project's `default_filters/anisotropic_filtering_level` (4 = 16x; unset is 4x); mipmapped
  alpha needs an `fwidth` sharpen before the scissor test.
- **A tree in ETR is not a billboard**: two fixed crossed quads for collidable objects (split on
  `[coll]`), camera-facing quads only for items. `object_cross.gdshader` + `ETRImport._cross_quad_mesh`
  vs `object_billboard.gdshader` + `QuadMesh`; `TestObjects` asserts it on vertex data. **And
  not every item turns**: `[usenorm] 1 [norm] 0 0 1` pins the start and finish banners square to
  the course (`face_camera = false` on their material, in `objects/` and every `course.tscn`).
- **A conifer's cross is still on the prefab, and still ETR's** — `TestObjects` asserts it — but
  it is only the editor's picture and a fallback. `ObjectPrefab.conifer` hands the type to
  `Forest`, which draws `ConiferMesh` instead. The flag lives in `resources/objects/tree{,1}.tres`
  *and* in every `course.tscn`'s embedded copy, and the importer sets it (`CONIFER_TEXTURE`).
  The bare tree is the same with `ObjectPrefab.bare`, `tree_barren{,2}.tres` and
  `BARE_TREE_TEXTURE`, the shrub with `ObjectPrefab.shrub`, `shrub.tres` and `SHRUB_TEXTURE`;
  `TestForest` reads every course's copy.
- **The conifer impostor is baked under Compatibility, which converts nothing**: an unshaded
  material's `source_color` texture is not decoded and ALBEDO is not encoded (a constant 0.214
  reads back 0.212). `conifer_bake.gdshader` writes both atlases raw on that basis; baked under
  Mobile they would be an sRGB curve off. The normal atlas is an object-space normal, so it must
  never be sampled `hint_normal` or imported as a normal map (`compress/normal_map=2` in its
  `.import`) — the importer would rebuild blue as if it were tangent-space. **A first bake writes
  Godot's default sidecar** (`normal_map=0`, `compress_to=1`): copy a committed species' `.import`
  settings onto a new species' atlases and re-import.
- **`SurfaceTool.commit()` without `index()` writes no index array** — the mesh draws, but
  `surface_get_arrays()[ARRAY_INDEX]` is null. `ConiferMesh` indexes before committing.
- **Vertex colour is 8 bits a channel.** A value under 1/510 comes back 0: the bare tree's
  radius code (`COLOR.b`) rounded to "not a tube" at its twig tips. Code a flag at least 1/255.
- **A thin cutout vanishes with distance**: a one-texel twig averages to half the alpha a mip down
  and the scissor deletes it. `alpha_mip_boost` (`conifer_alpha`, mip level from UV derivatives —
  WebGL2 has no `textureQueryLod`) raises it per level. Not on the impostor or in its bake: edge-on
  cards there have huge derivatives and the boost fills the crown in solid.
- **A card cut from the middle of a dense picture shows its straight edges.** The conifer's
  cards end in the picture's rim; a bush's sprigs cross the solid heart of `shrub.png`, and drew
  as shards. `ShrubMesh` fades each sprig to its root and sides in `COLOR.a`, which
  `conifer.gdshader` (and the bake) multiply into the picture's alpha, so the scissor cuts along
  the picture's own gaps. Every other vertex carries 1. Sprigs a chase camera looks along (under
  ~20°) are left to the fins: flat, they are only ever seen as streaks.
- **A twig card stood upright on a stalk reads as a broom.** The bare tree's finest order was
  tubes with a spray card at every tip and middle, all leaning up: a crown of little trees. The
  finest order is now *only* the card, laid along its branch, root on the limb, facing out of the
  crown. Fewer triangles and a haze instead of bristles.
- **An impostor has to show the level it replaces**, not the finest one. The bare tree baked from
  LOD 0 (four times LOD 2's twig cards) was a dark blob replacing an airy tree at 75 m; it bakes
  from LOD 2 (`Forest.impostor_source_level`), with its limbs widened to what LOD 2 draws there.
- **A hand-over is a change of shape, so put it where it cannot be seen.** The levels differ in
  fins, tiers and trunk, not just density; at 22 / 45 / 75 m a tree ~140 px tall morphed right ahead
  of the racer. `Forest.LOD_ENDS` is 50 / 90 / 130 m — small and fogged — for ~0–5 % frame rate.
  **Those are pixel sizes at 720p**: at 2560x1440 the 60 m hand-over was a tree twice as tall,
  visibly grainy mid-dither right ahead of the racer. `Forest.screen_scale_for` pushes them out
  with the window's physical height (never in, capped at 2x), live on a resize.
  The bare impostor's limbs are widened for the last edge: re-bake it after moving that one.
- **Per-object LOD cannot be a Godot visibility range on a `MultiMesh`**: the range switches the
  whole batch. `Forest` picks the level per tree in the vertex shader (out of band → collapse to a
  point) and uses node visibility ranges only to cull whole cells, with slack for the cell's reach.
  Distances are from `lod_origin` (the main camera), not `CAMERA_POSITION_WORLD`, which is the sun
  in the shadow pass.
- **Never let a billboard's shading normal follow the billboard** — N·L tracks the camera and
  trees pulse. `object_billboard.gdshader` shades as a vertical cylinder.
- **Two axis-aligned cards on a grid are the same plane.** Grid-placed trees closer than their radii
  share exact planes and z-fight; coplanar is not a precision problem. `CourseRoot.decorrelating_yaw`
  fixes it. To measure flicker, capture at 1/10 speed (`--fixed-fps 600`).
- **ETR's skybox is three flat quads** (front, left, right). `etr_skybox.gdshader` intersects the
  cube and fades outside it — do not "fix" it into a panorama.
- **Compatibility's sky pass does not encode its output**, and does not decode a `source_color`
  sampler or uniform either — so the migrated skybox (sRGB in, sRGB out) matched Mobile by accident.
  A sky computed in linear lands an sRGB curve too dark on the web; `procedural_sky.gdshader`
  encodes for itself under `#if CURRENT_RENDERER == RENDERER_COMPATIBILITY`.
- **A written `FOG` is blended the same way by both renderers**, in linear, and replaces the
  engine's fog for that material (only while `Environment.fog_enabled`). Reproduce the engine's depth
  fog as `smoothstep(begin, end, dist)` and it matches to the level — that is how `--sky=etr` gives
  the pre-atmosphere frame back. Additive materials want `fog_disabled` and a manual fade instead.
- **A fully fogged surface becomes a shape cut out of whatever is behind it** unless the fog colour
  *is* what is behind it. That is why the distant ridges are a function of direction in
  `atmosphere.gdshaderinc` and not meshes: the fog function can ask the same question the sky does.
- **The fog reads the ridges from a map; the sky evaluates them.** `RidgeMap` bakes
  `atmo_ridge_layers` once per sky into `atmo_ridge_map` (4096 × 2·512, RGBA8), because evaluated
  behind every far fragment of every lit surface they cost ~1 ms a frame. It holds for a whole race
  only because everything in it is worked out *before* the drop (`atmo_ridges.w`, the one input that
  moves), and the haze colour — the one term that depends on the drop — is left out and added at
  lookup. Anything new in the ridges must keep to that, or be re-baked (`RidgeMap.bake`) when it
  changes. With no map (`atmo_ridge_baked` 0: the editor, `--sky=etr`) far slopes fade to bare sky.
- **A shader branch that is never taken still costs.** The GPU allocates registers for the
  widest path, so the ridge noise kept as a "fallback" behind `if (!baked)` left every lit shader
  0.6–0.9 ms slower on the iGPU than with it deleted — as slow as having no map at all. Measure
  an optimisation with its fallbacks compiled in, and prefer none in hot shaders.
- **A `global uniform` the project does not declare is a compile error**, and the shader then draws
  nothing — every lit surface includes `atmosphere.gdshaderinc`, so one missing `[shader_globals]`
  entry empties the course. Global uniforms cannot be arrays (hence `atmo_torch_0..7`).
  `TestAtmosphere` checks the include against `project.godot`.
- **A chase camera on a steep course sees nothing above the horizon.** Past about 21° it sits at its
  40° pitch clamp with 35° either side, so the top of the frame is at −5°. Ridges on the true
  horizon filled every pixel the terrain left (no sky at all on Bumpy Ride), and the sky below 0° is
  the grey ground colour. The whole backdrop is therefore drawn about a dipped horizon
  (`atmo_dip`, `Atmosphere.horizon_dip`, 0.7 × the course's slope, capped at 30°). Anything that
  samples the backdrop has to go through `atmo_backdrop_dir`, or the far fog stops matching it.
- **A screen-space effect derived from one object is wrong for every other**, and a guard on the
  shaded fragment does not bound it. The ice mirror's plane belongs to the watched racer; other
  racers need a per-object admission test (`IceReflection.admits`), with the source racer exempt.
  Check such effects against the objects they were *not* derived from.
- **Every camera that sees the sun redraws its shadow cascades.** A `SubViewport` sharing the
  `World3D` has no switch for it, and the cost is flat in the face size: the six 128² probe faces
  took 67 ms a frame on Forest Trail. But a camera's `cull_mask` culls directional lights too
  (`RendererSceneCull::_render_scene`), so the sun sits on `IceEnvironment.SUN_LAYER`, which the
  probe leaves out, and the probe sees a shadowless copy on `PROBE_SUN_LAYER`, which the main
  camera leaves out (`IceEnvironment.attach_sun`). Any new camera that draws the world has to pick
  one of the two, or it sees no sun or both. Budget a probe in renders, not pixels. And **do not
  save by re-taking a cube only every few metres**: at 3 m it was a sixth of the cost and read as
  a stutter, the reflection jumping each time the probe caught up — the cube is taken every frame.
- **One `MultiMesh` across a course is never culled**: its AABB is the course, so every view
  draws every instance. Forest Trail's 1397 stone clusters (~700k triangles) cost 9.6 ms in the
  probe alone. `CourseRoot` cuts every non-collectable object type into `Forest.CELL_SIZE` cells
  under a `Batch_<type>` node, which also halved the main view there (17 → 8.6 ms); a
  collectable type stays one `MultiMeshInstance3D`, since `hide_item` addresses its slots.
- **Texture units are the terrain shader's scarcest budget.** It binds 8 (7 + the global
  `atmo_ridge_map`), 9 with `ice_env_atlas`, which exists only in the variant
  `TerrainRenderer.ice_environment_shader()` builds (`#define ICE_ENV_ATLAS`) while the setting is
  on — a declared sampler is bound whether or not it is read, so the setting has to choose the
  shader, not a uniform. It was 15 and 16, with one sampler per layer albedo, and 16 crashed every
  Windows browser on the first race (below); the albedos are now one `Texture2DArray`
  (`TerrainRenderer.albedo_array`), built per course at load from the layers' textures read back
  and re-mipped. An array needs one size for every slice, so all of a course's layers are brought
  up to its largest — Forest Trail's 512² needle floor makes its 256² photographs 512² in memory.
  Upscaled, never down; the byte-identical capture of a course whose layers already agree is the
  check that nothing else moved. **The real budget is 15, not 16**, for any shader that reads a
  `global uniform` (every lit surface does, through `atmosphere.gdshaderinc`) under ANGLE's D3D11
  backend — what Chrome *and* Firefox run WebGL on under Windows, which reports 16 units whatever
  the GPU (the same Ryzen iGPU reports 32 through Mesa on Linux). Godot keeps the globals in one
  block holding a single `vec4[256]`; ANGLE rewrites any block whose only member is an array of 50
  or more into a structured buffer (`RecordUniformBlocksWithLargeArrayMember`), which takes a
  texture register *after* all the samplers (`ResourcesHLSL`), while its per-stage register cache
  is sized to the 16 units (`StateManager11`). WebGL's link check counts samplers only, so 16
  passes; the first draw then writes register 16, a release-build `ASSERT` fires and the browser's
  GPU process dies (`STATUS_ILLEGAL_INSTRUCTION`, `setShaderResourceInternal` ←
  `syncUniformBuffersForShader`), and the page sees only `CONTEXT_LOST_WEBGL`, preceded by shader
  compiles "failing" with an empty log. That is what the 16-sampler ice variant did to every
  Windows browser on the first race; 15 is the most any stage may bind. Godot's GLES3 scene shader adds its own counting
  down from the top of the range (`// texunit:-2` radiance, `-3` shadows, `-6`/`-7` screen and
  depth, and since 4.7 `-10`/`-11` `ltc_lut1`/`ltc_lut2` for area lights). The terrain reads none of
  the first four in a browser, but the area-light pair is in Godot's *default* specialization
  (`DISABLE_LIGHT_AREA = false`), compiled at load and never drawn while no area light exists. At
  15 samplers it logged "Program linking failed: … exceeds MAX_TEXTURE_IMAGE_UNITS(16)" twice at
  startup on Windows, harmless; at 9 + 2 it should link, so that message coming back means the
  count has crept up again. None of this shows here: headless
  Chromium's SwiftShader and Mesa both report 32, so test a Windows browser.
- **A cube map magnifies whatever is near its centre.** With a 0.1 m near plane a flag passed at
  a metre filled a wedge of a face and turned a stripe of ice red for a few frames, and a canyon
  wall at arm's length turned half of `inception`'s floor one flat colour. The probe's cameras clip
  at 5 m (`IceEnvironment.PROBE_NEAR`): nothing that close was ever in the right place in a lookup
  that assumes the world stands 60 m out.
- **Depth is reversed on both renderers in 4.7, Compatibility included**: its GLES3 scene clears
  depth to 0 and tests `GL_GEQUAL`, so the far plane — the sky, which writes none — reads 0 from
  `hint_depth_texture` under either. The textbook `>= 1.0` sky test found no sky at all under
  Compatibility (`sun_shafts.gdshader`'s `is_sky`). A post pass written as a spatial shader also
  reads `hint_screen_texture` in display values under Compatibility and in linear under Mobile,
  and its `blend_add` lands in those units — work in display space and convert per renderer
  (`to_output`). Compatibility blends into 8 bits, so a ray's faint tail under a level is lost
  there and kept on Mobile.
- **Reading the screen or the depth in a spatial shader costs a copy of each, every frame it is
  drawn.** One full-screen tap of `SunShafts` was 0.9 ms on the iGPU under Mobile, before any
  ray; the twenty taps added 0.4 more. Hide such a pass (`visible = false`) whenever it has
  nothing to add, or it pays for the copies anyway.
- **A pass that rewrites the frame from the screen copy goes first in the transparent pass**
  (`RENDER_PRIORITY_MIN`, `MotionBlur`): the copy is taken after the opaque pass, so whatever
  transparent was drawn before it is wiped, and whatever comes after (falling snow, spray, a
  ghost, the sun's rays) lands on top, untouched. Reading the copy and writing it back unchanged
  round-trips exactly under Mobile; under Compatibility it moves the frame by ±1 level (mean
  0.23, up to 7 in the darks) — the renderer's copy path, not the shader, since a bare
  `ALBEDO = texture(screen_tex, SCREEN_UV).rgb` does the same.
- **Compatibility does not decode a viewport texture, whatever the hint.** A `source_color` sampler
  over a `SubViewport`'s texture reads its display-encoded bytes as linear there (a mountain at
  119 came back mirrored at 184); Mobile decodes it. `terrain.gdshader` leaves the hint off under
  Compatibility and decodes by hand (`ice_env_sample`), so no driver can do it twice.
- **A shader can tell a probe face from the player's view by its lens**: `IceEnvironment` renders at
  a 90° square projection, which no window has, and `terrain.gdshader` drops its screen-space terms
  there (`probe_pass`). Keep the probe's `fov`/aspect if you change it, or last frame's probe and
  the mirror leak into the cube.
- **A planar reflection holds only while it stays behind its subject.** On a banked wall the image
  goes sideways and reads as a second penguin, at full Fresnel. Neither fragment distance nor
  grazing angle separates the cases (a chase camera is always near-grazing); screen-down fraction of
  the offset does — `IceReflection.attachment()`.
- **A MultiMesh instance's own non-uniform scale bends its normals.** Godot uses the
  inverse-transpose only when the *node* is non-uniformly scaled, on both renderers, so a
  per-instance stretch turns normals by the plain matrix. `object_prop.gdshader` is
  `skip_vertex_transform` and transforms `NORMAL` itself. Without that, a 15:1 trunk lights and
  snows in a checkerboard. Any new shader drawn over stretched instances needs the same. The
  geometry stretches too: anything meant to stay round on a log's surface (its branch stubs) is
  built pre-squashed along X in `PropMesh` (`LOG_STRETCH`, `TRUNK_STRETCH`).

### Characters and animation

- **ETR's model frame is +Y forward, +Z belly.** The importer bakes `ETRImport.MODEL_TO_GODOT`.
- **A skeleton with the right joint names can still be a statue**: check `ARRAY_BONES`/
  `ARRAY_WEIGHTS`, a `Skin`, the `skeleton` path, a real parent chain and parent-relative rests.
  Flat-list bugs draw correctly at rest — test by playing an animation.
- **A `[node]` id in `shape.lst` is not unique** (Trixi's bow, Beastie's horns reuse 72–79). The
  importer numbers records and keeps `slots` as a shadowing id→record map (ETR's `Index`).
  `TestCharacter._bound_near_its_bone` catches misbinding geometrically.
- **Four of five characters name the left elbow `joint`, and Samuel lacks several parts.** Import
  what the file says — ETR skips unnamed joints. Tux's joint list is Tux's; test the others
  against the weaker shared contract.
- **`[vis]` is a level of detail**: `clamp(3, round(tux_sphere_divisions · vis / 10), 16)` stacks
  (divisions ship at 10), poles on the node's **+Z**. The black body and white belly ellipsoids are ~0.07 apart, so coarse tessellation notches
  the seam. Godot's front face is clockwise: `(a, b, d)` for a +Z pole.
- **Bone tracks are absolute poses**: bake keys as `rest × R`. `[sh]`, `[hip]`, `[knee]`,
  `[ankle]`, `[neck]` turn about joint Z; `[head]`, `[arm]` about Y.
- **In a keyframe file a missing tag is zero**, not "hold".
- **Half of an ETR keyframe is root motion**, and it is most of the finish clips (`finish.lst`
  starts prone at pitch 109 and stands up on node 0). Body transform lives in `KeyframePath`, above
  the rig, with Y completed by terrain height; the `AnimationPlayer` runs
  `ANIMATION_CALLBACK_MODE_PROCESS_MANUAL` on the same clock. `RaceScene._apply_finish_pose` and
  `IntroSequence._apply_pose` apply it; `TestCharacter` asserts finish clips start prone and end
  upright. `start.lst` is authored upright, so it cannot catch this.
- **`TUX_Y_CORR` is the whole of how deep the penguin rides.** Snow depth is already in the point
  mass; the model origin should clear the **bare** heightmap by 0.185 m. A second sink buried two
  fifths of him. `TestMultiplayer._where_the_body_is_drawn` asserts it.
- **Simulation state read at frame time is a sawtooth.** `SnowField` changes on ticks, so the drawn
  snow lift is sampled on the tick and interpolated with the pose's `alpha`
  (`Racer.sample_snow_lift`, last in `RaceScene._simulation_tick`). `TestMultiplayer._the_lift_runs_on_the_tick`.
- **A deposit narrower than a texel reads back as a phase.** `SnowField` is 50 cm/texel against a
  45 cm patch; `SnowField.MIN_FOOTPRINT` widens it to 1.5 texels with the rate divided to match.
  Approach `max_trench` smoothly — a `min()` is the same bug again. `TestSurface._snow_is_band_limited`.

### Audio

- **ETR's mixer has one voice per sound, and the content relies on it** (a herring fires three
  cues). `Halt` ignores one-shots; only `HaltAll` stops them. Both reproduced in `AudioDirector`.
- **`AudioStreamWAV.loop_mode` is not the loop; `loop_end` is.** Godot leaves it 0 on samples
  imported without looping, so a looping cue plays silently while reporting `playing`.
  `AudioDirector._set_loop` sets both; `TestAudio` asserts the window. Assert the quantity the
  engine reads, not the flag; `get_playback_position()` works under the Dummy driver.
- **Quitting has to wait for the mixer, for the objects, with the gate shut.** A stopped playback is
  freed a frame or more later, `create_timer` is not a wall clock, and anything on a timer can
  restart a cue inside the wait. So every quit goes through `AudioDirector.quit_game()`
  (`auto_accept_quit = false` routes the window X too): `begin_shutdown()` makes `play` refuse,
  `await_settled` waits on weakrefs to the stopped playbacks, `QUIT_SETTLE_TIMEOUT` is only a
  backstop. Re-check the gate after any `await` (`PackStream.ensure` on the web). (history §18)
- **The web export mixes through the browser unless told otherwise.** Godot's
  `audio/general/default_playback_type.web` defaults to Sample, which cannot play Ogg and bypasses
  buses and `_set_loop`. `project.godot` sets it to `0` (Stream — the setting's enum, not
  `AudioServer.PlaybackType`); `TestAudio._web_playback_type` asserts it. A desktop run has no `.web`
  feature tag and cannot see this; measure bus peaks and the RMS at `AudioContext.destination`.

### Web and streaming

- **`HTTPRequest` reads one chunk per frame**, so throughput is `fps × chunk`. The music pack took
  117 s at the 64 KiB default; `PackStream.DOWNLOAD_CHUNK_SIZE` is 1 MiB.
- **`HTTPRequest.get_body_size()` is -1 throughout on the web** — the fetch wrapper hides
  `Content-Length`. `PackStream` sends a `fetch(url, {method: 'HEAD'})` through `JavaScriptBridge`
  for the total. Ask the page before building a manifest. `tools/webtest/server.js` sends
  `Content-Length` so the harness exercises the real path.
- **Streaming work has to be budgeted, not just gated.** `TerrainRenderer` queues chunks
  nearest-first and drains under `BUILD_BUDGET_MS` (`immediate` at course load). Threads are an
  open question: the `Web` base preset ships `variant/thread_support=true` (pack presets' `false`
  is inert — a `.pck` carries no engine variant).
- **A run that wants a rendered course has to name one** (`--course=` / `--auto-input=`, or
  `index.html?course=<dir>` on the web). A bare `--capture=` screenshots the menu, deliberately.

- **Godot 4's web platform does not feed the accelerometer** — `Input.get_gravity()` is zero in a
  browser. `MotionSensor` injects its own `devicemotion` listener; the reading is in the device's
  natural frame (turn it by `screen.orientation.angle`) and signed as the reaction force, except on
  iOS. iOS motion permission, fullscreen and orientation lock must be asked from a *page* touch
  handler: a Godot input event is dispatched off the gesture.
- **A deferred `add_child` is not done one `process_frame` later** when the caller is already in
  the frame's process step — the signal is emitted before the deferred calls are flushed, and an
  `HTTPRequest` outside the tree refuses to start. `PackStream.fetch_and_mount` waits on
  `is_inside_tree()`. Off the web, `get_body_size()` is -1 until the headers arrive: keep asking.
- **A `.pck` from an address is code** — it can carry scripts. `ExternalCourses` mounts with
  `replace_files = false` so it cannot replace a shipped file; nothing more stops it.
- **A phone's browser is `web_android` / `web_ios`, not `mobile`.** `mobile` is only a native
  Android/iOS build; ask `TouchScheme.platform_is_mobile()`.

### Godot engine and GDScript

- **`set_shader_parameter` with a packed array aliases the caller's array.** Pass `.duplicate()`.
- **`object.packed_array.push_back(x)` appends to a copy.** Build a local array and assign once.
- **Godot omits an exported property equal to its script default** — so a `format_version`
  defaulting to the current version is never written and every old file reads as current.
  Default to 0 and stamp the real version on write (`RaceRecorder.begin`).
- **`ResourceLoader.load(path, "ScriptClass")` always fails** — `ClassDB` does not know
  `class_name`. Pass `""` and cast. Use `CACHE_MODE_IGNORE` for `user://` files the game rewrites.
- **`ResourceLoader.load` returns a real `GDScript` for a file that failed to parse** — check
  `can_instantiate()`, not `!= null`. Never `CACHE_MODE_IGNORE` a script to force recompiles: it
  replaces the script under live instances and segfaults.
- **A new `class_name` does not exist until the filesystem is scanned.**
  `.godot/global_script_class_cache.cfg` is gitignored; run `godot --headless --path game --import`
  after adding a class, or everything reports *"Could not find type X"* — and scenes may silently
  keep the old script.
- **Autoloads and static calls make parse cycles.** Two autoloads naming each other's singleton fail
  as *"Nonexistent function 'new' in base 'GDScript'"*; calling any static member of a class
  resolves the whole class, so a test calling a static on a script that names `Config`/`Net` fails
  as *"Identifier not found: Config"*. And the `--script` entry file is compiled before autoloads
  register, so anything `run_tests.gd` names statically must not reach an autoload — a failure
  quietly halves the suite. Rules: anything a test calls statically lives on a script that names no
  autoload (`RaceOutcome`, `DisplayModes`); tests `load("res://scripts/shell/race_hud.gd")` rather
  than naming shell classes, and spell constants like `SIM_HZ` out; a script that needs an autoload
  at top level must be a scene. Take identity by injection (`RaceNetwork.configure()`).
- **Static typing does not catch a member moved off an `@export`-typed reference** across scenes —
  it becomes a per-frame runtime error. Grep when renaming.
- **A lambda captures by value** — a counter incremented inside never comes back. Capture a
  one-element `Array`.
- **GDScript's `%` has no `%g`**, and it is `String.join(array)`, not `array.join`.
- **A `SceneTree` script's `_initialize` runs before the root Window is in the tree**, so
  `run_tests.gd` runs everything on the first `_process`.
- **The scene path goes before `--`**, or Godot runs the main scene and hands the path over as an
  unread user argument.
- **`OS.get_cmdline_args()` never contains `--resolution`** (the engine consumes it).
  `GameConfig.apply_display` instead treats any startup window other than the base size (in logical
  pixels) as set by someone else, and leaves it alone.
- **`change_scene_to_file()` from `_ready` fails noisily** — use `.call_deferred`.
- **A scene handed to `change_scene_to_file()` leaves the tree at once but keeps hearing autoload
  signals until freed.** `RaceScene.leave_to_main_menu` disconnects `_network_links()` first; any
  new autoload connection on a swappable scene belongs in a list like that.
- **A `Control`'s theme does not reach a `CanvasLayer`'s children.** Each shell `CanvasLayer` screen
  carries `themes/etr_menu.tres` on its own top-level `Control`.
- **Nothing in Godot enumerates display modes.** `DisplayModes` derives them from the panel's size
  and shape.
- **`aspect="expand"` means the canvas is not a known size.** A 1024x768 window renders on a
  1280x960 canvas. Edge-anchored 2D is measured at paint time (`RaceHUD.gauge_center`), and the
  camera widens on narrow canvases (`ChaseCamera.fov_for_aspect`). Notes older than that change
  assume 1280x720 everywhere.
- **`MultiMesh.get_instance_transform` returns identity under `--headless`.** Assert against what
  feeds the batch (`TestObjects._no_two_trees_share_a_plane`).
- **Every `SceneTree` is already "connected"** via `OfflineMultiplayerPeer`. Ask whether the peer is
  the offline one. Transports are built through `ClassDB` (`RaceNetwork._new_peer`) so a stripped
  build loses multiplayer, not the game.
- **Compatibility can't `emit_particle()`.** Drive rate-based emitters (`amount_ratio`, direction,
  speed).
- **In a `canvas_item` fragment, `COLOR` already has the texture multiplied in.** The vertex
  colour (a modulate) is only in `vertex()`; carry it in a varying (`lens_snow.gdshader`) or its
  alpha comes back times the texture's.
- **A menu over a live race cannot be centred or dim the screen** — the penguin is in the middle.
  The results panel is anchored top-centre at 80 px like `CGameOver`, with no backdrop.

### Simulation, input and gameplay

- **A fixed timestep has a phase, and the textbook accumulator draws a tick behind** (at exactly
  60 fps it draws the previous tick forever). `RaceScene` tracks `_sim_lead`, ticks while negative,
  draws at `1 − lead / SIM_DT`. (history §20)
- **Airborne horizontal velocity is exactly constant**, so sideways camera motion in the air came
  from the ground normal. `ChaseCamera._lean_up` keeps only the pitch half of the lean;
  `TestCamera._fly` measures over the airborne window.
- **Don't slerp the chase camera's orientation** — interpolate position and aim point, rebuild the
  basis against world up.
- **`RacePhysics` ignores an analogue stick under 0.2**, silently falling through to the digital
  flags. `AIInputSource.stick_for` maps corrections into [`MIN_EFFECTIVE_STICK`, 1.0]. (history §21)
- **A velocity-only contact settles inside the contact distance** (0.57 of 0.6 m). Assert
  "beside, not inside", against the contact distance.
- **An obstacle moving with you is not scored like a tree**: score the lateral gap at the aim point,
  weighted by how close alongside the rival already is.
- **Dropping a state-machine exit and keeping only its force is a different deviation.** ETR leaves
  the racing loop at `speed < 3` after the finish; without that, gravity and the brake crept forever
  at camera-unsmoothed speed. `RacePhysics.FINISH_STOP_SPEED` ports the exit. Check what else a
  removed behaviour was quietly doing.
- **A per-element loop applying one scalar is a scalar.** `SnowField.decay` is a scale factor
  renormalised rarely (0.74 ms → 0.0002 ms a tick). **A chunk vertex sits exactly on a heightmap
  texel** — index `surface.heights`/`normals` directly (6.8 → 1.4 ms), which also keeps the live
  trench out of the mesh.
- **Sensors are opt-in in Godot 4**: without `input_devices/sensors/enable_gravity` /
  `enable_accelerometer` in `project.godot`, `Input.get_gravity()` reads zero on a phone too.
- **An `ItemList` cannot be scrolled by a finger** (Godot 4.7): a touch selects the row on
  touch-down and a drag drags the selection. `TouchListScroll.attach(list)` scrolls on drag, selects
  on a tap's release, and swallows the emulated mouse events in the list's `gui_input` signal (which
  runs before the control's own handler). Attach it to any new list; a `ScrollContainer` drags already.
- **Android's back button quits the app by default** (`application/config/quit_on_go_back`), from
  mid-race. It is off, and `GameConfig._notification` turns the go-back request into `menu`.
- **The renderer is fixed before any script runs**, so Android's renderer choice is a
  `project.godot` fragment at `user://renderer.cfg`, pulled in by
  `config/project_settings_override.android`, not a `penguinracer.cfg` key. The `.android` tag is
  what keeps the desktop and the browser on their own renderer; read the setting with
  `get_setting_with_override`, since plain `get_setting` does not see the tag. The file must set
  `rendering_method.mobile` as well as `rendering_method`: Godot has a built-in
  `rendering_method.mobile="mobile"`, a phone has the `mobile` tag, and a tagged key beats a plain
  one — the plain key alone is read and ignored, which only a phone shows. Godot derives the
  driver (OpenGL ES) from the method. A phone with no Vulkan still falls back to Compatibility
  whatever the file says, and the settings row then keeps reading "applies after a restart".
- **A touch also arrives as an emulated mouse click** (`emulate_mouse_from_touch`). The intro's
  skip relies on it; anything that also handles the mouse must ignore
  `InputEvent.DEVICE_ID_EMULATION` or a tap lands twice (a pause pressed twice is no pause).
- **`is_action_just_pressed()` stays true for a released key**, so a pulsed remote keyboard drives
  edge-triggered controls only. `KeyHoldFilter` detects it — only after a second pulse on the same
  action within `PULSE_WINDOW`, since one pulse is just a quick tap — and `--remote-keyboard`
  stretches presses to 100 ms. `key_log.tscn` shows what arrives. (history §14, §19)

## Deliberate deviations from ETR

### Rendering

- **The illumination is summed and clamped before it touches the albedo** — ETR's fixed-function
  order: `etr_illumination.gdshaderinc` is `texture × clamp(ambient + diffuse·N·L, 0, 1)`, in every
  lit shader, each `ambient_light_disabled` so both terms meet in `light()`. This makes `sun_gain`
  a derivation (`(1 − 0.591) / 0.210 = 1.95`), not a fit. Clamping the product instead sends
  slopes to flat white past `1/albedo`.
- **Light constants are migrated verbatim and corrected by a separate fitted gain.** `sun_color`/
  `ambient_color` are `light.lst`'s numbers; `sun_gain`/`ambient_gain` are per-channel `Color`s.
  Both applied in one place, `EnvironmentPreset.as_light_color`.
- **One preset is fitted and six are derived, in display space.** `EnvironmentPreset.fit_correction()`
  recovers the display-space factor from the `tuxracer_sunny` fit; `derive_ambient_gain`/
  `derive_sun_gain` apply it, written onto each resource by the importer. The sun derivation
  returns 1.948 against the fit's 1.95. Night near field: (140, 172, 238) → (78, 113, 209). (history §25)
- **Ambient comes from the migrated `[amb]`, not the sky** (`ambient_light_sky_contribution = 0`).
- **Linear tone mapper, no glow, no SSAO** — reproducing a fixed-function look means reproducing
  its transfer curve.
- **Fog is pushed out**: 40 m clear, 2x distance (40–150 m where `light.lst` says 0–75), because
  six presets ship `[fogstart] 0`. Tree-band contrast returns (p5 143 → 65); the fitted near field
  does not move. `start_distance = 0` + `distance_scale = 1` in `penguinracer.cfg` is ETR's fog.
- **The sky is drawn, not photographed** (`procedural_sky.gdshader`, `Atmosphere`): gradient from the
  migrated faces' averages (turned toward a clear blue per light at their own brightness, `Atmosphere.LOOKS`), sun disc, two drifting cloud
  decks, three low layers of distant ridges seeded per course; stars, a moon and an aurora at night,
  all about a horizon **dipped by the course's slope** so a chase camera sees open sky. **The
  moon stands 9° up ahead of the racer** (`MOON_DIRECTION`), not where ETR's night light comes from,
  because a chase camera never sees that part of the sky; nothing casts a shadow at night. **The
sun is drawn the same way** (`SUN_DIRECTION`, 52° right and 10.5° up: just out of frame riding
straight, in at the top right once the racer turns right), where every sunny `light.lst` has it due right at 45°, never in shot. The light,
the fitted tone and the shadows stay put; the disc's halo, the clouds' silver linings and the
ridges' light follow the disc (`atmo_sun_dir`). With the disc in shot the halo and the silver
lining were narrowed (they had clipped a fifth of the frame round it to white), and the zenith is
capped at `MAX_ZENITH_LUMINANCE`: `tuxracer_sunny`'s near-white zenith, lifted 1.8x, had clipped
the whole sky to cyan-white, against which no disc can show. The fog
  fades to the sky along the horizon (aerial perspective) and, as it reaches full, to the ridges
  behind; exponential **valley mist** settles 4 m under the course's lowest point, kept light under
  clear skies (it greys everything it lies over). Both start at the
  fog's clear distance, so the fitted near field does not move. **A course may shape its
  ridges** (`CourseData.backdrop_height`/`_forest`/`_near` → `atmo_ridge_shape`): taller,
  wooded to just under the crests (`atmo_ridge_firs`: staggered fir tops, no texture unit) and
  nearer — broader, less hazed. Only Mountain Forest does; the default `(1, 0, 0, 0)` is the old
  skyline term for term, and the ridge map's top row rises only for a taller range
  (`atmo_map_t_max`). `[display] sky = etr` / `--sky=etr`
  is ETR's skybox and flat `[fogcol]`, to the level.
- **Night courses are lit** (`CourseLights`): a torch in place of every flag (the flag batch is
  hidden while they burn; each shines at `FLAG_SHARE` 0.3 of an edge torch, since at full strength
  the mid-run torches warmed the whole piste) and one every 22 m down the play area's long edges
  (outside it, clear of trees, no collision). The terrain's pools are **baked** for every torch at load
  (`CourseLights.bake_terrain`, <50 ms) into vertex colour G, stored as a square root, and scaled
  by `atmo_torch_light` — so a flame seen 200 m off has its pool, and the terrain costs one
  multiply per pixel. Trees and objects still read the eight nearest the camera as globals. Both
  sum inside the illumination clamp — no `OmniLight3D`, which would run the one-light `light()`
  again and add the ambient twice. The bake has no flicker. Racers are not torch-lit.
  `[display] night_lights = false` is ETR's dark night, flags and all.
- **There is a thunderstorm**, a light ETR has not got (`LightCondition.Kind.THUNDERSTORM`, value
  4). No `light.lst` describes it, so it is not imported: `EnvironmentPreset.storm_from` derives
  `<location>_thunderstorm` from the location's cloudy preset at runtime, scaling `[diff]`/`[amb]`
  by `STORM_LIGHT` in display space and re-deriving the gains the importer's way (never scale a
  linear gain — the sRGB trap). `Lightning` flashes it: strikes every 3.5–11 s ahead of the camera,
  1–4 return strokes each, seeded by the course so captures reproduce. **The flash is the sun**,
  brightened and turned toward the strike — a second light would add the ambient twice inside
  ETR's clamp — so everything lit flashes together; the sky reads the same flash from `atmo_flash`
  / `atmo_bolt`, and because `atmo_sky` carries it the far fog flashes with the sky. The bolt is
  compiled only into the storm's sky (`ATMO_LIGHTNING`, `Atmosphere.sky_shader`). No thunder: ETR
  has no sound for it.
- **The sun casts a real shadow map on the desktop only**; ETR casts a character blob. Off by
  renderer (`RenderBackend`), sky (`EnvironmentPreset.casts_shadows`, ETR's `light_id` rule) and
  player (`GameConfig.shadows`, ETR's `perf_level`). The web has no shadow map, deliberately.
- **The trees' shadows can be baked instead** (`TreeShadowBake`), and on the web they always are:
  once per course and sun, at load, into the terrain's vertex colour B, which `terrain.gdshader`
  multiplies into the sun term wherever `ATTENUATION` goes (`tree_sun`, eased by
  `tree_shadow_strength`, 0 when the map draws the trees or the sky casts nothing). On the desktop it
  is `[quality] tree_shadow_kind = "baked"` (the *Tree shadow type* row, FAST's choice), which takes
  the trees out of the shadow map; racers keep theirs. A stamp per tree size, `blend_rect`ed into a
  half-float map; the ground's slope along the sun is folded into the height (`_stretch`), or the
  shadows down a bank came out 2–3 m short. Soft (0.25–1 m grid, blurred, then doubled so only the
  outer edge ramps — half a shadow is invisible on snow at the illumination clamp), still in the
  wind, no flags, no bare-tree limbs. Up to ~240 ms at load in a browser; nothing a frame. A new sun
  mid-race re-bakes and rebuilds the chunks. Racers are not shaded by it.
- **Snow and ice get view-dependent terms ETR lacks.** Snow: two octaves of micro-relief and a
  crystal glint. Ice: Fresnel sky reflection on `SPECULAR_LIGHT` (a two-colour ramp from the skybox
  — Compatibility cannot bind `Sky`), sun glare, albedo 0.82. **Fresnel is a split**
  (`1 - mirror_share`), capped at `1 - ice_roughness`. Distant grazing ice reflects `fog_color`
  (`ice_distant_tint`, gated on distance). `ice_albedo = 1.0`, `ice_horizon_terrain = 0` and
  `detail_relief_* = 0` restore the plain look.
- **Rock gets a detail texture** (`terrain.gdshader`'s `Detail_Texture` group). ETR draws each
  terrain photograph once at a 6 m repeat — 2.3 cm a texel, magnified into blocks at the racer's
  feet. A layer with `TerrainLayer.detail_strength` (the importer seeds 0.8 on `is_rock()`: ETR's
  friction ≥ 0.6, eleven terrains) multiplies in its own albedo 4.7x finer and turned, as a
  brightness ratio over the photograph's mean, within 30 m. Albedo, not light: sunlit rock sits at
  the illumination clamp, where a bump is invisible. `detail_strength = 0` is ETR's single read.
- **The ice reflects the racers**; ETR reflects nothing. `IceReflection` renders the racers through
  a `SubViewport` whose camera is the chase camera mirrored through the ice tangent plane under the
  watched racer; `terrain.gdshader` samples it by `SCREEN_UV`. Settled by spike S7: (1) it shares
  the main `World3D` with a narrowed `cull_mask` — no duplicate rigs, and ghosts/opponents/peers are
  reflected for free; (2) the renderer flips winding for the −1 determinant itself; (3) the
  reflection *occludes* the sky ramp rather than adding (Schlick is 0.02–0.09 at chase incidence).
  Bounds: `reflection_fade_distance` (8 m); other racers pass `IceReflection.admits` (within 0.6 m
  and 15° of the plane, 1.6x hysteresis; the watched racer exempt) or `Racer.reflected` clears
  their layer bit; the whole term fades by `IceReflection.attachment()` between 0.94 and 0.80.
  `[display] ice_reflections = false` or `character_reflection_opacity = 0` turns it off.
- **The ice reflects the hill too, as a setting** (`IceEnvironment`): six 128² faces
  from 0.5 m above the ice under the watched racer, drawn into one 3x2 atlas by a 2D pass (a
  `Cubemap` would need a readback), sampled by `ice_env_uv` along the mirror ray walked out to a
  60 m sphere, in place of the sky ramp; the racers' mirror still goes on top. Racers, spray and
  snowfall are on `NEAR_FIELD_LAYER`, not layer 1, so the probe leaves them out, and its cameras
  clip everything within 5 m (`PROBE_NEAR`, trap list). Runs only with ice
  within 90 m, all six faces every frame (~3 ms on Forest Trail on the iGPU under Mobile, lit by a shadowless copy of the sun;
  the web draws none). On every renderer; it is the terrain's 9th sampler, compiled in only while
  on (trap list). `[display] ice_world_reflections = false` is the ramp and the 8-unit shader
  again; off below the HIGH preset.
- **Conifers are 3D trees**, where ETR draws the same two crossed quads for every tree.
  `ConiferMesh` builds three levels from `snowy_tree1.png`, unchanged — radial fins carrying the
  picture's halves for the silhouette, drooping whorl cards for depth, a trunk at LOD 0 — and
  `Forest` hands them over at 50 / 90 / 130 m with a 4 m Bayer-dithered cross-fade per tree, then
  to a hemi-octahedral impostor (64 baked views, three blended, lit from a baked normal atlas).
  Upward faces are whitened in the shader by `[game] snowfall`; the tree sways with the watched
  racer's `WindField` and the snowfall. Same markers, same scale, same collision cylinder.
  Clearing `conifer` on a prefab (both copies — see the trap list) draws ETR's cross again.
- **Shrubs are 3D bushes**, the conifer's treatment with a bush's shape. `ShrubMesh` builds three
  levels from `shrub.png`, unchanged: radial fins for the silhouette, and sprigs — cards bursting
  from the root over the whole dome, 20–85° up, each carrying the strip of picture along its own
  ray to the rim and fading toward its root and sides (trap list). No trunk. Same `Forest`, bands,
  shaders and impostor scheme (baked from LOD 0). Clearing `shrub` on a prefab draws ETR's cross.
- **Bare trees are grown, not drawn from their picture.** ETR's is a 239² cutout on two quads —
  blocky close up, flat from the side — and on fins it would read as a tangle, since a bare tree
  is mostly air. `BareTreeMesh` grows a fixed-seed skeleton inside the picture's crown: the trunk
  and two orders of tapered tubes, and a third, finest order drawn only as twig cards laid along
  each branch (1276 / 684 / 394 triangles), with a texture it paints itself (four crooked twigs
  with side shoots + a bark strip, colours measured off `tree_barren2.png`, so nothing new for
  the licence audit). Same `Forest`, bands, shaders and impostor scheme as the
  conifer; the shader widens a limb to ≥ ~0.4 px (`min_radius_per_metre`, vertices coding a radius
  in `COLOR.b`) so far limbs stay lines, and holds more snow on round limbs
  (`snow_facing_offset`). Clearing `bare` on a prefab draws ETR's cross again.
- **Courses can carry solid props** — boulders, stone scatters, fallen logs, stumps — where ETR
  has only pictures on quads. `PropMesh` builds them (flat-shaded except a log's bark, colours in
  the vertex colours, nothing from a picture), `object_prop.gdshader` draws them inside ETR's
  clamp with patches of snow on upward faces, and `ObjectPrefab.ground_aligned` lays them square to the slope. A
  marker's Z scale is read (it was always X's), so a log is long in X and thin in Y and Z. **A
  marker's Y is a height above the ground and its X/Z rotations are read** (`CourseRoot`), for
  the one prop that is not on the ground: Mountain Forest's `lodged_log`, a long
  `PropMesh.Kind.TRUNK` wedged across the gully overhead, leaning bank to bank — level, not
  ground-aligned, and not collidable. The same trunk also lies fallen from a bank onto the trail,
  and there it is solid: the grid knows only upright cylinders, so a row of `trunk_collider`
  markers (a prefab with no mesh), each as tall as the trunk there, runs along the part over the
  trail. It can be hit or jumped. Only the two authored courses use props; every imported course
  has Y = 0, no tilt, and is unchanged.
- **There are courses ETR has not got**, and a fourth heading for them in the course list
  (*PenguinRacer*, `CourseListing.Category.PENGUINRACER`), each from a generator in
  `addons/course_gen/` sharing `CourseGenKit`. **Forest Trail** (`gen_forest_trail.gd`): a narrow
  trail that forks into two branches and rejoins, a drawn conifer-needle floor with snow where the
  crowns leave gaps (the forest is planted before the ground is painted), and the props below.
  **Mountain Forest** (`gen_mountain_forest.gd`): a narrower trail down a gully whose walls climb
  14–30 m, a fall line of chutes (24–31°) and benches (12–14°) eased into each other, two slots
  with a trunk lodged overhead, eight bumps and two kickers, three boulders and four fallen
  trunks on the trail, a pile of stones beside it halfway down, bare ice on the walls (nothing
  stands on it), and a near, wooded skyline (below).
- **Steep faces are textured from the side** (`terrain.gdshader`'s `Steep_Mapping` group), where
  ETR projects every photograph straight down — 2.4x stretched down a 65° bank, 3.2x down a slot's
  72° wall. Past |n.y| 0.85 (~32°) a non-snow layer is also read on the ZY and XY planes, weighted
  by the face's normal, taking over by 0.55 (~57°); gentler ground is the top projection alone.
  Same array, no unit, no varying. ~0.27 ms on the iGPU with a steep wall filling half the frame.
  `steep_mapping = 0` is ETR's projection.
- **Walls can carry real rock** (`CliffSet`, `CourseData.cliffs`), where ETR has only the
  heightmap. `CliffBuilder` lays a grid on the wall itself (0.25 m along the course and *along the
  slope*), pushes it out into beds that step back at level, snow-catching ledges, joints and
  roughness, bakes a cavity AO into R and a ledge weight into A, and sinks it 0.5 m under the
  heightmap wherever its mask is 0 — so the face comes up out of the ground where the rock is and
  needs no seam. `TerrainRenderer` draws it with the chunks' own material (one splat, photographs,
  light, fog), its other colour channels read off the terrain's grid; the shader lays snow on its
  ledges (`cliff_ledge_snow`). Kept ≥ 2.6 m off the trail's edge, so physics, the AI and the snow
  never see it; the chase camera reads `CliffSet.lift_at` on top of the heightmap. Kept lean:
  quads wholly under the ground are left out, attributes compressed (compression takes normals
  only with tangents, so it writes dummy ones), simplified levels generated with the course and
  stored beside each mesh (`CliffSet.lods` — the renderer rebuilds the mesh for its colours, and
  an `ArrayMesh` hands back arrays, not levels), and the heightmap quads the rock provably hides
  (`CliffSet.holes`: the rock's *lowest* surface ≥ 0.1 m over the ground at every half-cell
  sample, so the space between is shut in) are left out of the chunks. **Never cut a hole the
  rock does not close over**: the chunk is the only thing under it. One face on Mountain Forest
  so far (140–198 m, right bank): 18k vertices, 560 KB, ~0.55 ms in the same view.
- **Crossed-quad trees are shaded as a cylinder across both planes**, where ETR gives all eight vertices
  normal (0,0,1). Per-face normals would split each tree into bright and dark halves.
  `normal_roundness = 0` in `object_cross.gdshader` is the flat card.
- **Each collidable object gets a position-hashed yaw** (±20°, `CourseRoot.decorrelating_yaw`) so
  grid-placed forests do not share planes. Geometry, silhouette and collision unchanged.
  `YAW_JITTER = 0` is ETR's forest, flicker included.
- **The spray's puff atlas, the flake clumps and the snow curtain tiles are drawn procedurally**, not copied
  (licence audit): `SprayEmitter.make_puff_image` (ETR's 2×2 atlas, growth 0.035 → ≤0.18 m, linear
  fade, `FRandom()` s life) and `SnowFall.make_curtain_image` (ETR's measured coverage per tile,
  but in specks of 1–2 texels rather than its blobs of up to 22 px; white with alpha,
  edge-wrapped; `TestSnowFall` asserts coverage). All
  deterministic. `SprayEmitter.particle_color` is a setter so an environment applied later reaches
  existing emitters.
- **The falling snow is a `MultiMesh` moved in a vertex shader** (`snow_flakes.gdshader`), where
  ETR moves flakes on the CPU — which also makes snowing captures reproducible. **The flakes stay
  in the world**: ETR's `YDRIFT`/`ZDRIFT` half-follow made the snow read as an overlay, so the box
  follows and the flakes do not, and each is drawn as a streak of its motion against the camera
  over a 1/60 s shutter (previous view matrix as a uniform). Real fall speed (`FALL_SPEED`, ±30 %
  per flake, not size × 5), per-flake sway, level wind, fades at the box faces and the lens.
  **The lens fade reads the streak's closest approach, not its head**, and is gone by a metre:
  the tail is clamped 5 cm in front of the lens, so a flake beside or behind it drew a 5 cm quad
  at 5 cm — a white burst over half the frame whenever a crash jerked the camera.
  **Every flake is the same size in the world**, where ETR grows them with distance to hold their
  screen size: on screen, size and speed both go as 1/distance, so a far flake drawn as big as a
  near one is also slower than it, and reads as a round blob floating in front of the lens. A
  flake below `MIN_PIXELS` is drawn at that size and faded by the area it gained; the curtain
  tiles' specks are a pixel or so at far-snow range for the same reason.
  Every quad stays upright on screen and is *stretched* toward its tail, never turned along the
  streak — a turned far patch swings its sheet of specks round and reads as snow on rotating
  planes. The near flakes do not use the spray's round puffs (ETR's `SNOW_PART`): they draw
  `SnowFall.make_flake_image`, a 4×4 atlas of grown clumps (cell = index mod 16), and the fragment
  stage turns and tumbles each clump inside its cell (`tumble`, 0 for the far area, whose patches
  must never turn — see above). Clumps stay within `FLAKE_REACH` of the cell centre so a spun cell
  never reads its neighbour. Flakes are soft-alpha without
  depth write, where ETR alpha-tests and writes depth. **ETR's `CCurtain` rings are gone**: a ring
  centred on the player has no parallax and was the most overlay-like thing on screen. The far
  snow is a fourth area in the same shader (`FAR_AREAS`) — a 150 m square box of 6–8 m quads,
  each a random 160² patch of a curtain tile, drawn only 25–72 m from the camera (`FAR_FADE`).
  Each patch fades out over 40 % of its width from every edge (`FAR_WINDOW`, `patch_window`):
  hard-edged patches of even specks read as tiles in heavy snow against a flat sky, one step in
  density at every quad edge. The count and size are raised to keep the specks per square metre.
- **Snow lands on the lens** (`LensSnow`); ETR's camera stays clean. The one piece of snow that is
  deliberately on the camera, so it is kept small: a few out-of-focus blobs (the frame behind
  blurred and lifted toward `[partcol]`, `lens_snow.gdshader`), counted and timed by the grade and
  landing faster as the camera runs into the air, melting in 1–3 s, and never inside an ellipse
  round the penguin (`LensSnow.is_clear`). A `CanvasLayer` under the HUD, plain 2D, alike on both
  renderers. Grade 0 draws nothing.
- **The sun flares the lens** (`LensFlare`, `lens_flare.gdshader`); ETR has neither sun nor flare.
  Kept gentle: a warm glare round the disc, a faint streak and five faint ghosts on the line
  through the middle, added in display space on a `CanvasLayer` beside `LensSnow`. Only under a
  sky whose look has `flare` (sunny, evening), faded out just past the frame's edge. **Occlusion
  is read off the frame, on the GPU**: the shader probes seven taps inside the disc, which is
  white wherever it shows, and scales the flare by the white share — no readback, and a trunk
  or a slope in front of the sun dims it.
- **The sun sends rays through the air** (`SunShafts`, `sun_shafts.gdshader`), as a setting
  (`[display] sun_shafts`, the *Sun rays* row, off below HIGH; `--sun-shafts=` for one run).
  Screen space on every renderer — Forward+'s volumetric fog is Forward+ only and would lay a
  second fog over every shader's `FOG`. One full-screen quad in the 3D
  pass (on `NEAR_FIELD_LAYER`, so the ice's probe and mirror leave it out) walks 20 taps toward
  the disc and integrates the open, bright sky round it (`is_sky`: nothing drawn there, from the
  depth buffer — snow at the clamp is as white as that sky, so brightness alone would send rays
  out of every sunlit bank); a trunk, a crest or a racer in front breaks it into rays. Integrated, not averaged,
  so a ray is as bright far out as near and the middle does not swell into a second glare.
  Display space, a few levels to ~45 at most. Only under a look with `shafts` (sunny, evening),
  and only with the disc in shot: they fade in over its first 0.08 of the height inside the edge
  (`SunShafts.EDGE_FADE`). Riding straight the disc is ~0.03 past the right edge, and a fade
  reaching out there ran the pass most of a run for a corner beam of ≤ 7 levels — and moved
  Bunny Hill's reference capture. Hidden, and free, with the disc out of shot; in it ~1.3 ms
  under Mobile and ~1.1 under Compatibility on the iGPU.
- **The camera's motion blurs the frame** (`MotionBlur`, `motion_blur.gdshader`), as a setting
  (`[display] motion_blur`, the *Motion blur* row, on only at BEST — it moves every frame the
  camera moves in, so HIGH, the shipped frame, keeps every reference capture; `--motion-blur=` for
  one run). ETR draws stills. Camera motion only, on every renderer — neither hands a shader a
  velocity buffer: each pixel's point is rebuilt from the depth buffer, put through last frame's
  view (`previous_view`, with this frame's projection — the lens changes only on a resize) and
  the copy is gathered along the difference, 4–16 jittered taps (one per 4 px), capped at 0.1 of
  the height. **Travel is exposed five times as long as a turn** (`TRAVEL_SHUTTER_SECONDS` 5/120 s,
  `TURN_SHUTTER_SECONDS` 1/120 s, each over the frame's `delta`; `MotionBlur.exposed` builds the
  camera the shutter opened at): riding straight, everything streams out of the point ahead, where
  nothing moves, and at one 180° shutter that was a few pixels and read as no blur, while one
  long shutter for both turned a carve into a smudge. **The racers are spheres that move with
  themselves, under one shutter**: the chase camera holds the one it follows still by turning
  and travelling together, so exposing those apart smeared the penguin across a carve. A racer's
  pixels use `body_view` (turn and travel both at the turn's exposure) with the racer's own
  displacement, blended in by how much of the pixel is body; up to four racers in shot (nearest
  first, all alike), and a tap across a body's edge does not count, so the snow does not pick up
  the penguin. First in the transparent pass (trap list), so snowfall, spray and ghosts stay
  sharp; the HUD, lens snow and flare are canvas layers above it. Hidden while the camera is
  still, on a pause and on a cut (≥ 4 m or 25° in one frame: a restart). ~3 ms under Mobile on the
  iGPU at 1600x900 with the sun's rays off (with them on, the copies are shared).
- **The course screen's wind is a crosswind that pushes only in flight**, not ETR's `wind_id`
  (which drives the air drag everywhere and blows from anywhere — still `--wind=1..3`).
  `WindField.init_crosswind`: within 15° of square to the fall line, from a side rolled per start
  (server-rolled in a network race, pinned in a scripted one), gusting on `CWind`'s state machine.
  `RacePhysics.calc_flight_wind_force` adds `FLIGHT_ACCEL_PER_SPEED` × the wind while airborne —
  0.5 m of drift over a light-wind jump, ~2 m in a strong one; the ground run is bit-identical.
- **Which layers are ice is `TerrainLayer.is_ice()`, not `[shiny]`**: seven ice records, only three
  marked shiny. Every ETR ice is `[friction] 0.2`, and nothing else goes below 0.3.
- **The terrain's ambient is occluded and, on snow, tinted blue.** ETR lights every vertex alike.
  `TerrainOcclusion` bakes a horizon AO from the heightmap at import (vertex colour, not a
  texture — the unit budget), the trench adds its walls at fragment rate, and snow's ambient takes
  `snow_scatter_tint` as the sun leaves it, the relief closes over it or the carve deepens.
  Inside the illumination clamp, so lit snow keeps its fitted tone. `terrain_ao_strength`,
  `terrain_ao_sun`, `trench_wall_ao` and the `snow_scatter_*` gains at 0 restore the old frame.
- **The drawn body is lifted by the trench it stands in** (`Racer._drawn_snow_lift`, adding back
  what `SnowField.apply_to_sample` took off), because the terrain mesh is too coarse to carve.
  **Delete it, do not retune it, the day the near-field mesh carries the trench.**

### Physics and simulation

- Items/trees go through a **uniform spatial grid**; the original did an O(items) scan per substep.
- **Friction and compression depth are pre-blended per heightmap texel at load** (exact — both are
  linear).
- **The stage-3 force evaluation is reused as the next step's first stage** (3 evaluations per
  accepted step). Both of these bought the S2 headroom — keep them.
- **Packed snow lowers friction** (ice 0.2 fast … rock 0.7 slow), so a trench is faster and lines
  matter. Both coefficients are exported.
- **The finish keeps real gravity** instead of the flat 500 N hack, with ETR's `speed < 3` exit
  ported as `RacePhysics.FINISH_STOP_SPEED` (trap list).
- **The simulation runs on a fixed 60 Hz tick**; ETR steps with frame time. Ghosts and peers need
  a run to mean the same at 30 and 144 fps. The ODE's adaptive substepping is unchanged underneath.
- **A ghost is played back as poses, not re-simulated.** Input replay drifts between native and
  WebAssembly libm. The input trace is recorded too, for tests and re-derivation, with a hash of the
  force model.
- **A scripted run neither keeps a ghost nor races one**, or captures would grow a second penguin.
- **A shoulder with both `[sh]` and `[arm]` is one slerped quaternion key**; ETR interpolates the
  angles separately. They agree whenever one angle is constant (all of `start.lst`).

### Opponents and racers

- **There are computer opponents**; ETR races the clock. Skill (`AISkill`) moves habits only —
  lookahead, reaction, nerve, paddling, tree clearance, weave — never the 20 kg point mass or the
  §4.1 forces.
- **An opponent is told where the other racers are**, via the same `RacerField` the simulation
  bounces off. The racer penalty is soft and much weaker than a tree's.
- **Racers collide, each resolving it for itself**: `RacePhysics._adjust_racer_collision` is the
  tree collision made symmetrical — equal-mass impulse (restitution 0.35, horizontal) plus an
  overlap term, applied only to self against the others' published state. Symmetrical to the tick,
  not the bit; a remote peer is resolved against where it was `INTERPOLATION_DELAY` ago. **A ghost
  is not in the field** (`Racer.collides()`).
- **Herring are first come, first served** between simulated racers (one `ObjectGrid`); a ghost
  takes none, and over the network each machine removes only what its own racers collected.
- **A race against opponents draws no ghost** — the HUD's one status line is the standings.
- **An opponent's grooming counts**: a time set in a race is stored as a best time although packed
  snow made it faster.
- **Only the local player's slide and impacts are audible** (one voice per cue, no positional
  audio). Hitting a racer plays `tree_hit`.

### Network races

- **Client/server over WebSocket; the server relays, it does not simulate.** A browser has no UDP,
  so ENet could never serve the web. The server decides the room list, entry, start and race end —
  never a position. See `scripts/net/race_network.gd`.
- **A countdown replaces the start animation**: every peer reports the hill built
  (`RaceNetwork.report_ready`), the server waits for the last, one `cli_race_go` starts a
  3 s countdown everywhere (`RaceScene.COUNTDOWN_SECONDS`). Aligned to within a round trip.
- **The race is over when the last racer finishes.** After your finish the camera spectates
  (`RaceScene._update_spectate` via `RacerRoster.view_target`) and the results wait for
  `RaceNetwork.race_over`, showing the *server's* order. Backstop: `LobbyServer.ABANDON_AFTER_MSEC`
  (5 min after the first finisher).
- **Only the winner plays the finish-line clip**; others stay where they stopped. The outcome still
  picks the music sting. `RaceScene._on_network_race_over`.
- **Esc forfeits; `P` and `r` do nothing** — a pause or restart of one machine's clock is not a
  pause or restart of a shared race.
- **A player name is held by one player at a time** (case-insensitive, `LobbyServer.add_peer`).
  The peer is still seated under a free name; `RaceNetwork.cli_error` drops the session back to the
  CONNECT page with the name kept.

### Shell, HUD and content

- **A practice run ends on `wonrace`, not `finish`** — `finish` just stops in a flat stance, and
  ETR plays the win sting for any unaborted practice run anyway. `RaceOutcome.clip`; `finish` is
  only the fallback for a rig without the clip.
- **The start animation is skipped for scripted runs** (`--auto-input=`, `--no-intro`,
  `?nointro=1`), or it would move every reference capture.
- **The HUD says `PRESS ANY KEY TO START` over the start animation** (a migrated string ETR uses
  on its splash screen), low and centred over the ordinary HUD.
- **ETR's HUD art is upside down relative to the PNG** (`glOrtho` y-up + `glTexGen` t=0 at the PNG
  top): the speed ring starts at the lower left and sweeps clockwise over the top; its centre fits
  `ENERGY_GAUGE_CENTER` (71, 55) within half a pixel. `DrawCoursePosition` fills upward only because
  of two negatives. [RaceHUD] flips once, like [RacerState]'s `progress = -physics.pos.z`, and
  clamps.
- **The menus reproduce ETR's palette, not its art.** `themes/etr_menu.tres` is `src/common.cpp`'s
  colour table; corner ornaments, title logo and menu snow wait on the licence audit. The checkbox
  is redrawn (`themes/checkbox_{on,off}.png`) because Godot's switch vanishes on blue.
- **The button that goes on is the rightmost one; Back (or Cancel) is the leftmost.** Every
  button row, every screen — the order is the scene file's child order. The course screen's
  option rows are one `GridContainer` so their spinners share columns; add a row as five cells.
- **The chosen character is remembered** (`[game] character`) and picked from its own main-menu
  entry (`character_menu.tscn`, the character half of ETR's `CRegist`). `--character=`/
  `?character=` override one run. Horizontal arrows flanking the name; ETR's clamping and greyed
  end arrow; the `n / 5` counter is new.
- **The terrain slide sound resolves through the dominant splat layer**, where ETR needs ≥ half the
  blend or plays nothing. **The slide has no speed term** — ETR's `SlideVolume` ships commented out.
- **Numeric string IDs became semantic keys** (`PRESS_ANY_KEY_TO_START`); old IDs are in
  `i18n/legacy_string_ids.cfg`. Finishing places reuse `POSITION` and `1ST`..`10TH`, which is why
  the field stops at nine.
- **The interface speaks English and German, nothing else** (`Language`). ETR's 13 imported
  tables cover only its 111 strings, so the locale is pinned to `en` or `de` — the platform's
  (`OS.get_locale()`: `LANG`, Android's system language, `navigator.language`) when
  `[game] language = "auto"`, German only for a German locale, English for everything else. The
  settings screen, `--lang=`/`?lang=` override it. **Every string a player reads goes through the
  table**: ETR's key where one fits, else a row in the hand-written `i18n/ui.csv` (`keys,en,de`,
  never touched by the importer) — no English literals, and no key without both columns
  (`TestConfig` checks, and that `%` placeholders match). In a `.tscn`, put the **key** in `text`
  and let auto-translate draw it; in a script, `tr()` it; an `OptionButton` row can be a bare key.
  Text built with `tr()` does not follow a locale change, so the settings screen rebuilds the main
  menu scene when the language changes. Adding a row: edit the CSV, then
  `godot --headless --path game --import` to regenerate `ui.*.translation`. Course names and
  descriptions stay as ETR ships them — untranslated there too.
- **The course list is Tux Racer's five, then ETR's, then this project's, then the player's own**, each under a header
  row — not ETR's `default`/`extras` groups, since `default` holds seventeen courses ETR added.
  The five are `CourseCatalog.TUXRACER_ORIGINALS` (Jasmin Patry's, `[env] tuxracer`, the
  *Tux Racer Classics* event). **A course can be added by the http(s) address of its `.pck`**
  (`ExternalCourses`, *Add course…*), **or by a folder's**, whose `courses.json`
  (`ExternalCourses.parse_index`, written by `tools/gen_course_index.py`) lists its packs — each
  new one is added from the index alone. Every added course is filed under a server name the
  player types, and listed under a header of that name. The file name is the course dir, the
  entry is kept, the pack is fetched again each session. The shell lists `CourseCatalog.load_with_external()`; tests and
  the lobby use `load_default()` — a room cannot race a course only one machine has.
- **A phone races by tilt, by buttons, or by a mix** (`TouchScheme`, `TouchControls`,
  `TiltSteering`); ETR is keyboard-only. The tilt's two halves — roll steers, pitch paddles and
  brakes — are each the device's or a pair of buttons' (`TiltSteering.steers` / `.speeds`). The
  buttons press the ordinary actions; tilt is merged per tick in `LocalInputSource`. The physics sees a stick and flags, exactly as from a gamepad. A phone
  leaving the app pauses the race like `P` (`RaceScene._notification`), not in a network race.
  The start hint reads `TAP TO START` under the overlay.

## Commits

Commits and pull requests here carry **no agent attribution** — no `Co-Authored-By:` trailer
naming a model or a tool, no "Generated with ..." line or product link in a PR description. Turn
off any agent default that adds one; the history was rewritten once to strip them out.

Authorship is the repository's configured `user.name` / `user.email`. The project's use of LLMs
is disclosed once, in prose, in the README under *How this was built*.

## Licensing

ETR code is **GPL-2.0-or-later**. Physics *constants and the physical model* are facts about a
simulation and are the valuable part — implement from `etracer.md` §4.1 rather than translating
C++ line-for-line. Data assets have mixed authorship (`etr-0.8.4/data/credits.lst`, `AUTHORS`);
treat every reused asset as needing its own licence check.
