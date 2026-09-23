# AGENTS.md — PenguinRacer

Godot 4.7 rebuild of **Extreme Tux Racer 0.8.4**: downhill penguin racing with the original's
physics model and real snow deformation. Ships to **web (WebGL2 / Compatibility)** and **desktop
native (Vulkan / Mobile renderer)** from one project; both targets matter equally — see
architecture rule 2 and [RenderBackend].

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
  scripts/course/         CourseData, TerrainLayer, prefabs, events, environments
                          (EnvironmentPreset + LightCondition: a course names a place,
                          a race names the time of day — ETR's light_id)
  scripts/render/         terrain chunks, GPU snow field, spray, SnowFall (falling flakes +
                          ETR's distant curtains), IceReflection (planar mirror for the ice)
  scripts/camera/         chase camera
  scripts/shell/          main/course/settings menus, HUD, LobbyMenu (connect → browse → room,
                          own CourseMenu instance), LoadingScreen (shared by menu and race)
  scripts/race/           RaceScene (tick loop + course), RacerRoster (who is on the hill, who
                          is winning), IntroSequence, the racer layer (Racer, SimulatedRacer,
                          PlaybackRacer, RacerState — the 18-float snapshot that is also the
                          ghost and wire format — RacerStateStream, InputSource kinds incl.
                          AIInputSource + AISkill), RaceSetup (practice or a field of 1..9),
                          RaceRecording, RaceRecorder, SavedRunStore, RaceOutcome
  scripts/net/            RaceNetwork autoload (`Net`: socket, lobby protocol, snapshots),
                          LobbyServer (rooms; the only thing on the wire that decides anything),
                          WebFileServer (web export over HTTP with COOP/COEP), ServerMain
  scripts/character/      CharacterRig, KeyframePath (root motion), CharacterCatalog/Listing
  scripts/audio/          AudioDirector autoload + generated sound/music banks
  scripts/config/         GameConfig autoload (settings file), RenderBackend (which renderer,
                          and shadows), LaunchArgs (command line + URL query), DisplayModes,
                          PackStream (streamed web packs, risk S6; no-op elsewhere)
  scripts/debug/          DebugCapture autoload (headless screenshots / scripted input), key_log
  shaders/                terrain, etr_skybox, object_billboard (items), object_cross (trees),
                          snow_trail, snow_flakes, s1_displace, etr_illumination.gdshaderinc
                          (ETR's sum-then-clamp, included by everything lit)
  addons/etr_import/      one-way, re-runnable importer from the ETR data tree
  courses/<name>/         GENERATED: course.tres, course.tscn, heightmap.res, splat_*.png
  resources/  i18n/       GENERATED: layers, prefabs, environments, events, course + character
                          catalogs, five rigs + previews, sound bank, music, 13 translations
  assets/sounds|music/    GENERATED: 10 effects, 10 pieces, copied verbatim
  scenes/                 main_menu.tscn (main scene), course/character/settings/ghost/lobby/
                          results menus, race.tscn, loading_screen.tscn, key_log.tscn,
                          server.tscn (the same project headless, no course)
  user://runs/            NOT in the repo: runs kept from the results screen (SavedRunStore),
                          raced as a translucent ghost from the main menu
  themes/                 etr_menu.tres — ETR's `common.cpp` palette + checkbox icons
  tests/                  headless suite + ODE benchmark + tone_report.gd (not a test)
  spikes/s1_pingpong/     ping-pong render-target spike (S1)
  spikes/s7_reflection/   planar reflection spike (S7)
etr-0.8.4/                original source + data — READ-ONLY, never write here
tools/                    import_all.sh; serve.sh (dedicated server + web export);
                          build_server.sh (Linux server export + build/web → build/server/);
                          shot.sh (deterministic screenshot, real GPU when present);
                          png.py, regionstats.py, linstats.py (slow pure-Python capture stats —
                          tests/tone_report.gd does the same in a second); webtest/ (COOP/COEP
                          server + puppeteer runner); gen_course_export_presets.py +
                          build_web_streamed.sh (streamed web export, S6)
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
godot --path game -- --fps                                         # ... with a frame-rate readout
godot --path game -- --wind=2                                      # ... with wind (and the wind rose)
godot --path game -- --snow=3                                      # ... snowing (0..3)
godot --path game -- --light=night                                 # ... under another sky (sunny|cloudy|night)
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

# headless verification
godot --path game -- --capture=/tmp/shot.png --capture-frames=200 \
    --auto-input=carve --camera=above --course=wild_mountains
# --auto-input= is carve | brake | paddle | jump (jump is the only way to capture the
# gauge's inner half). It also DISABLES the start animation, so those captures run on a
# different clock from a player's. To reproduce what a player saw in the first seconds,
# pass no input source — --capture= plus --course= plays the intro and steers nowhere:
godot --path game -- --capture=/tmp/shot.png --capture-frames=655 \
    --course=penguins_cant_fly --opponents=3 --character=trixi --no-audio

# web — streamed build: base + one .pck per course + one for music
./tools/build_web_streamed.sh
node tools/webtest/server.js build/web 8060 &
node tools/webtest/run_web_test.js \
    "http://127.0.0.1:8060/index.html?course=bunny_hill&nointro=1" /tmp/web.png RACE_READY

# what the browser renders, without a browser
godot --path game --rendering-method gl_compatibility --rendering-driver opengl3
SHOT_METHOD=gl_compatibility SHOT_RESOLUTION=1024x576 tools/shot.sh /tmp/web-look.png
```

**Settings** live in `user://penguinracer.cfg` (Linux: `~/.local/share/godot/app_userdata/PenguinRacer/`),
written with comments on first run; delete it for defaults. The **Configuration** screen edits
the display rows (window size, render scale, ice reflections, shadows, fog distance) and writes
the same commented file back. Elsewhere: `[multiplayer] player_name`/`server` on the **Network
multiplayer** screen, `port` file-only, `opponents`/`opponent_skill`/`snowfall`/`conditions` on
the course screen. Resolution offers the display's own modes (`DisplayModes`); resolution and
fullscreen are hidden on the web, where the page sizes the canvas. The shadows row is hidden
wherever `RenderBackend.supports_light_shadows()` is false but the value is still written back,
so a desktop preference survives a browser session. A ghost is not a setting: it is whichever
saved run the player picks from **Race against ghost**, or none.

**Export presets**: `Web` (streamed base — engine, shell, all 44 previews), one generated
`Course_<dir>` per course, `MusicPack`, `WebSpike`, `Server` (Linux dedicated server). The
generated presets belong to `tools/gen_course_export_presets.py` — re-run it when a course is
added, removed or renamed. The test server must set COOP/COEP and `.wasm`/`.pck` MIME types or
the export fails obscurely. Prerequisites: Godot 4.7.2 on `PATH` as `godot`, web export
templates, and **Vulkan** for the desktop (Mobile renderer).

**Captures**: `SHOT_METHOD` is `mobile` (desktop default), `gl_compatibility` (browser) or
`forward_plus`; the driver follows it. `tools/shot.sh` uses the container's real GPU (Wayland
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
| 1 — importer + first course | **done** — 44 courses, 43 layers, 14 prefabs, 8 environments, 5 characters, events, 111 strings × 13 languages. |
| 2 — rendering | partial — Mobile on the desktop, Compatibility on the web (trap list: *sRGB-blended shadow pass*). ETR's illumination clamp in every lit shader except the character's; desktop-only PSSM shadow. Splat PBR, chunked terrain, instanced objects (trees are ETR's two crossed planes with a hashed yaw; items are billboards), ETR's HUD redrawn as primitives ([RaceHUD]), migrated skyboxes. Tone matched on Bunny Hill at both ends in all three channels; no LightmapGI. Snow/ice micro-relief, glint, Fresnel sky, ice reflecting the racers (`IceReflection`), textured carve spray. |
| 3 — snow | mechanism proven, integration partial — GPU trail map + CPU mirror; a carve leaves a shaded trench with a ploughed lip. |
| 4 — character | **done for all five** — skinned mesh from `shape.lst`, keyframe clips as `AnimationLibrary` + `KeyframePath` root motion, start animation (`CIntro`), finish clips on the results screen (`RaceOutcome.clip`), racing pose layer (`CharacterRig.adjust_joints`, ETR's `AdjustJoints`) driven off `RacerState` alone so ghosts and peers animate. `GameConfig.character` picks one. |
| 5 — game shell | partial — main menu → Practice / Race the computer / Network multiplayer / Race against ghost / character / Configuration; results screen with named runs; ETR palette theme; course + character catalogs; 13 languages; audio (`AudioDirector`, ETR's one-voice-per-cue mixer). Missing: cups, medals, profiles (data imported), volume/language controls, ETR's menu art (licence audit). |
| 6 — polish/ship | not started. |
| weather | **snow (0–3) and sky (sunny/cloudy/night) done** — `SnowFall` (flakes + curtains, deterministic) and `LightCondition`, both on the course screen, remembered in `[game] snowfall`/`conditions`, carried on a lobby room. The sky moves sun, ambient, fog, skybox, tints, ice, and shadows (`EnvironmentPreset.casts_shadows`). `evening` is imported but not offered. Wind is still `--wind=` only. |
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
- Wind, ETR's third weather control, is only `--wind=`: it belongs to a cup race and there are no
  cups. `RaceSetup` is where it would go.
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
- **An exported field nothing reads is an invitation.** The terrain shader binds 13 of WebGL2's 16
  guaranteed texture units, so per-layer `normal`/`roughness` texture slots were dropped rather
  than left as silent no-ops. Do not add a per-layer field the shader cannot consume.
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
- **A procedural relief strength is not a 0..1 knob.** The detail map stores gradient w.r.t. UV
  (peaks ~12). Uniforms are metres of relief; put the unit in the name.
- **`normalize()` of a mipped white-noise tap is NaN**, and NaN survives a zero fade. Add the raw
  vector to the normal instead.
- **A trail-map normal is added to the terrain normal, never mixed into it**, or the whole course
  flattens.
- **Godot imports textures without mipmaps, and `filter_linear` ignores them anyway.** Forced via
  `[importer_defaults]`; terrain/splat samplers are `filter_linear_mipmap_anisotropic`; mipmapped
  alpha needs an `fwidth` sharpen before the scissor test.
- **A tree in ETR is not a billboard**: two fixed crossed quads for collidable objects (split on
  `[coll]`), camera-facing quads only for items. `object_cross.gdshader` + `ETRImport._cross_quad_mesh`
  vs `object_billboard.gdshader` + `QuadMesh`; `TestObjects` asserts it on vertex data.
- **Never let a billboard's shading normal follow the billboard** — N·L tracks the camera and
  trees pulse. `object_billboard.gdshader` shades as a vertical cylinder.
- **Two axis-aligned cards on a grid are the same plane.** Grid-placed trees closer than their radii
  share exact planes and z-fight; coplanar is not a precision problem. `CourseRoot.decorrelating_yaw`
  fixes it. To measure flicker, capture at 1/10 speed (`--fixed-fps 600`).
- **ETR's skybox is three flat quads** (front, left, right). `etr_skybox.gdshader` intersects the
  cube and fades outside it — do not "fix" it into a panorama.
- **A screen-space effect derived from one object is wrong for every other**, and a guard on the
  shaded fragment does not bound it. The ice mirror's plane belongs to the watched racer; other
  racers need a per-object admission test (`IceReflection.admits`), with the source racer exempt.
  Check such effects against the objects they were *not* derived from.
- **A planar reflection holds only while it stays behind its subject.** On a banked wall the image
  goes sideways and reads as a second penguin, at full Fresnel. Neither fragment distance nor
  grazing angle separates the cases (a chase camera is always near-grazing); screen-down fraction of
  the offset does — `IceReflection.attachment()`.

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
- **The sun casts a real shadow map on the desktop only**; ETR casts a character blob. Off by
  renderer (`RenderBackend`), sky (`EnvironmentPreset.casts_shadows`, ETR's `light_id` rule) and
  player (`GameConfig.shadows`, ETR's `perf_level`). The web has no shadows at all, deliberately;
  its unshadowed frame measures within a level of the desktop's on snow.
- **Snow and ice get view-dependent terms ETR lacks.** Snow: two octaves of micro-relief and a
  crystal glint. Ice: Fresnel sky reflection on `SPECULAR_LIGHT` (a two-colour ramp from the skybox
  — Compatibility cannot bind `Sky`), sun glare, albedo 0.82. **Fresnel is a split**
  (`1 - mirror_share`), capped at `1 - ice_roughness`. Distant grazing ice reflects `fog_color`
  (`ice_distant_tint`, gated on distance). `ice_albedo = 1.0`, `ice_horizon_terrain = 0` and
  `detail_relief_* = 0` restore the plain look.
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
- **Trees are shaded as a cylinder across both planes**, where ETR gives all eight vertices
  normal (0,0,1). Per-face normals would split each tree into bright and dark halves.
  `normal_roundness = 0` in `object_cross.gdshader` is the flat card.
- **Each collidable object gets a position-hashed yaw** (±20°, `CourseRoot.decorrelating_yaw`) so
  grid-placed forests do not share planes. Geometry, silhouette and collision unchanged.
  `YAW_JITTER = 0` is ETR's forest, flicker included.
- **The spray's puff atlas and the snow curtain tiles are redrawn procedurally**, not copied
  (licence audit): `SprayEmitter.make_puff_image` (ETR's 2×2 atlas, growth 0.035 → ≤0.18 m, linear
  fade, `FRandom()` s life) and `SnowFall.make_curtain_image` (ETR's measured blob counts per tile,
  cubed-uniform radius, white with alpha, edge-wrapped; `TestSnowFall` asserts coverage). Both
  deterministic. `SprayEmitter.particle_color` is a setter so an environment applied later reaches
  existing emitters.
- **The falling snow is a `MultiMesh` moved in a vertex shader** (`snow_flakes.gdshader`, two
  uniforms), where ETR moves flakes on the CPU — which also makes snowing captures reproducible.
  Every area billboards about Y (ETR only the near one); atlas quadrant is index mod 4; flakes are
  soft-alpha without depth write, where ETR alpha-tests and writes depth.
- **Which layers are ice is `TerrainLayer.is_ice()`, not `[shiny]`**: seven ice records, only three
  marked shiny. Every ETR ice is `[friction] 0.2`, and nothing else goes below 0.3.
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
- **The chosen character is remembered** (`[game] character`) and picked from its own main-menu
  entry (`character_menu.tscn`, the character half of ETR's `CRegist`). `--character=`/
  `?character=` override one run. Horizontal arrows flanking the name; ETR's clamping and greyed
  end arrow; the `n / 5` counter is new.
- **The terrain slide sound resolves through the dominant splat layer**, where ETR needs ≥ half the
  blend or plays nothing. **The slide has no speed term** — ETR's `SlideVolume` ships commented out.
- **Numeric string IDs became semantic keys** (`PRESS_ANY_KEY_TO_START`); old IDs are in
  `i18n/legacy_string_ids.cfg`. Strings for features ETR lacks (`ghost`, *Race the computer*,
  *Opponents* / *Skill* / *Easy, Medium, Hard*) are literals — a `tr()` key would resolve to nothing
  in all 13 languages. Finishing places reuse `POSITION` and `1ST`..`10TH`, which is why the field
  stops at nine.

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
