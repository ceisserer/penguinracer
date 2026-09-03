# AGENTS.md — PenguinRacer

Godot 4.7 rebuild of **Extreme Tux Racer 0.8.4**: downhill penguin racing with the original's
physics model and real snow deformation. Ships to **web (WebGL2 / Compatibility)** and **desktop
native** from one project; both targets matter equally.

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
game/                     Godot project (project.godot, gl_compatibility)
  scripts/physics/        RacePhysics + surface + snow — plain RefCounted, zero node deps
  scripts/course/         CourseData, TerrainLayer, prefabs, events, environments
  scripts/render/         terrain chunks, GPU snow field, spray
  scripts/camera/         chase camera        scripts/shell/  main menu, course menu,
                                                              settings screen, HUD
  scripts/race/           RaceScene (the tick loop and the course) + RacerRoster
                          (who is on the hill, and who is winning) +
                          IntroSequence (the start animation) + the racer
                          layer: Racer + SimulatedRacer +
                          PlaybackRacer, RacerState (the 14-float snapshot that is
                          also the ghost file format and the wire format),
                          RacerStateStream, InputSource and its kinds — including
                          AIInputSource + AISkill, the computer opponents —
                          RaceSetup (practice or a field of 1..9),
                          RaceRecording + RaceRecorder + GhostStore
  scripts/net/            RaceNetwork autoload (`Net`) — ENet session, snapshot RPCs
  scripts/character/      CharacterRig + KeyframePath — the rig the importer writes
                          and the root motion a keyframe animation cannot carry —
                          plus CharacterCatalog/CharacterListing, the generated
                          index of the five playable characters
  scripts/audio/          AudioDirector autoload + generated sound/music banks
  scripts/config/         GameConfig autoload — the player's settings file —
                          plus LaunchArgs, the command line and the URL query
                          parsed once into one list
  scripts/debug/          DebugCapture autoload (headless screenshots / scripted input),
                          key_log (what a remote desktop is doing to the keyboard)
  shaders/                terrain (splat + snow/ice shading), etr_skybox,
                          snow_trail, s1_displace
  addons/etr_import/      one-way, re-runnable importer from the ETR data tree
  courses/<name>/         GENERATED: course.tres, course.tscn, heightmap.res, splat_*.png
  resources/  i18n/       GENERATED: layers, prefabs, environments, events, course
                          catalog, character catalog + the five rigs and their
                          previews, sound bank + music library, 13 translations
  assets/sounds|music/    GENERATED: the 10 effects and 10 pieces, copied verbatim
  scenes/                 main_menu.tscn (the main scene), course_menu.tscn,
                          character_menu.tscn, settings_menu.tscn, race.tscn,
                          key_log.tscn
  user://ghosts/          NOT in the repo: the player's best run per course, written
                          by GhostStore and replayed as a translucent second penguin
  themes/                 etr_menu.tres — ETR's `common.cpp` palette as a Godot
                          theme, and the checkbox icons it binds
  tests/                  headless suite (physics, surface, input, audio, imported
                          terrain library, character rig, racer layer, computer
                          opponents) + ODE benchmark
  spikes/s1_pingpong/     ping-pong render-target spike (risk S1)
etr-0.8.4/                original source + data — READ-ONLY, never write here
tools/                    import_all.sh, shot.sh (deterministic screenshot, real GPU
                          when there is one),
                          png.py + regionstats.py + linstats.py (compare a
                          capture against a reference numerically),
                          webtest/ (COOP/COEP server + puppeteer runner)
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
godot --path game spikes/s1_pingpong/s1_spike.tscn                 # snow RT spike

./tools/import_all.sh [--course=bunny_hill] [--force]              # 4-pass importer

# headless verification without a display
godot --path game -- --capture=/tmp/shot.png --capture-frames=200 \
    --auto-input=carve --camera=above --course=wild_mountains

# web
godot --headless --path game --export-release "Web" build/web/index.html
node tools/webtest/server.js build/web 8060 &
node tools/webtest/run_web_test.js \
    "http://127.0.0.1:8060/index.html?course=bunny_hill&nointro=1" /tmp/web.png RACE_READY
```

Settings live in `user://penguinracer.cfg` — on Linux
`~/.local/share/godot/app_userdata/PenguinRacer/`, written with its comments on first run.
Window size, render scale, fog distance, whether ghosts are drawn, the size and skill of the
computer field, and the two multiplayer keys; delete it to get the defaults back. The main menu's
**Configuration** screen moves the six a player can act on — `[multiplayer] player_name` and
`port` are file-only until there is a lobby, and `opponents`/`opponent_skill` are set from the
course screen instead, where the choice is actually made — and writes the same commented file back.

Export presets: `Web` (all 44 courses), `WebOneCourse` (bunny_hill, 6.6 MB pck), `WebSpike`.
The test server must set COOP/COEP and `.wasm`/`.pck` MIME types or the export fails obscurely.
Prerequisite: Godot 4.7.2 on `PATH` as `godot`, plus export templates for web.

`tools/shot.sh` renders on the container's real GPU (Wayland socket + `/dev/dri/renderD128`),
which needs `libegl1 libegl-mesa0 libdecor-0-0` installed; without them Godot reports it as
"your video card drivers seem not to support the required OpenGL version" and silently falls
back. 120 frames of Bunny Hill: ~3 s on the GPU, ~2 min under llvmpipe. `SHOT_FORCE_SOFTWARE=1`
takes the slow path, which is worth doing before trusting a small tone measurement.

## Current state

| Phase | State |
|---|---|
| 0 — physics core | **done** — every §4.1 force, ODE23 adaptive, spatial grids. 3254 assertions, 0 failures, 0.9 s headless. |
| 1 — importer + first course | **done** — all 44 courses, 43 layers, 14 prefabs, 8 environments, 5 characters, events, 111 strings × 13 languages. bunny_hill drivable in a browser; wild_mountains (100×1000) runs. |
| 2 — rendering | partial — splat PBR, chunked terrain, instanced trees, HUD, migrated skyboxes. Tone matched to the original on Bunny Hill; no LightmapGI bake. Snow and ice carry procedural micro-relief, a twinkling crystal glint and a Fresnel sky reflection. |
| 3 — snow | mechanism proven, integration partial — GPU trail map + CPU mirror both wired; a carve leaves a track with a shaded trench, a self-occluded floor and a bright ploughed lip. |
| 4 — character | rig + canned clips done for **all five characters**, procedural layer not started — welded ArrayMesh from `shape.lst` **skinned** to a Skeleton3D with ETR joint names, the four keyframe lists as an AnimationLibrary plus a `KeyframePath` of root motion each, and the pre-race start animation (`CIntro`) wired into the race. Tux, Trixi, Boris, Samuel and Beastie each carry their own shape and their own clips; `resources/characters.tres` indexes them and `GameConfig.character` picks one. No additive layer over racing (`AdjustJoints`); finish/wonrace/lostrace imported but not played. |
| 5 — game shell | partial — `main_menu.tscn` is the main scene: Practice opens the course list, *Race the computer* opens the same list with a field of 1–9 opponents behind it, Configuration edits `penguinracer.cfg` graphically, and a race is a scene the shell hands over to and takes back. `character_menu.tscn` is the character half of `CRegist` — arrows over a framed name with the migrated 128x128 preview under it. Every screen wears `themes/etr_menu.tres`, so the shell reads as the original's: the flat `colBackgr` blue, white text, `colDYell` on whatever has focus, square white-outlined frames. Generated course and character catalogs, 13 languages wired to `tr()`, audio (10 effects + 10 pieces + 3 racing themes on an `AudioDirector` autoload that reproduces ETR's one-voice-per-cue mixer). No cups, medals or profiles (data is imported and waiting; the player half of `CRegist` waits on them); no volume or language controls on the settings screen; none of ETR's menu art (corner ornaments, title logo), which waits on the licence audit. |
| 6 — polish/ship | not started. |
| computer opponents | **done** — beyond the original, which has nobody on the hill. `RaceSetup` is the whole mode switch: 0 opponents is Practice and 1–9 is a race, chosen on the course screen and remembered in `penguinracer.cfg`. An opponent is a `SimulatedRacer` driven by an `AIInputSource` — the seam the racer layer was built for, used with no change to it. It plans an aim point every `AISkill.plan_interval` ticks by scoring nine candidate lines against trees, the play bounds, swerve cost, its own lane, the friction ahead, herring and the other racers. **The three levels move driving habits and never the physics**: lookahead, reaction, nerve, how long they paddle, how readily they brake. Measured over 30 s of a 22° slope: easy 231 m, medium 333 m, hard 422 m, a player holding the accelerator straight 413 m. Deterministic — the only randomness is a per-seat personality drawn once from a seed. Opponents are solid: everyone on the hill bounces off everyone else through the shared `RacerField` (see the deviations), which is why the steering term only has to keep them out of each other's way rather than out of each other. No jumps, no tricks, no cups. |
| multiplayer foundation | seams built, ghosts working, network scaffold desktop-only — beyond the original, plan §8.4. The simulation runs on a fixed 60 Hz tick with interpolated presentation; `RaceScene` owns a list of `Racer`s, split into `SimulatedRacer` (a `RacePhysics` fed by an `InputSource`) and `PlaybackRacer` (a `RacerStateStream` read by time). Ghosts are finished end to end: every run is recorded, a completed best is written to `user://ghosts/<course>.res`, and the next race draws it translucent with the gap in seconds on the HUD. `Net` hosts/joins an ENet session over `--host`/`--join=` and each peer broadcasts 20 snapshots a second. A peer is a body like any other — the local player collides with it against the snapshot stream, and the machine that owns it resolves the same contact from its side. No lobby, no countdown, no web (ENet is UDP). |

### Spikes

- **S1** ping-pong `SubViewport` RTs on web — **PASS** native + Chromium/WebGL2, numerically
  verified. Firefox untested (no GPU in this container; it refuses WebGL2 under software rendering).
- **S2** GDScript ODE loop — **PASS with margin**: 0.045 ms/frame native, 0.073 ms in-browser
  (0.44 % of 16.7 ms). **The godot-rust GDExtension contingency should not be built.**
- **S3–S6** open: dequantization eyeball per course, RGBA8 snow banding, asset licence audit,
  web cold-load size.

### Known gaps

- Near-field terrain mesh too coarse (~0.5 m vertices vs a 0.45 m contact patch) — the trench reads
  in lighting but not in silhouette. Fix: denser mesh for chunks inside the deformation window.
- Web cold load 161 MB (128 MB pck) — all 44 courses bundled, plus 18 MB of audio. Needs
  per-course streaming (Phase 6); the 14 MB of music is the easiest part to load on demand.
- The terrain slide sound is on/off with no speed term, and 12 of the 43 terrains (including
  `snow`) name no sound — both faithful, both the obvious first improvement. See the deviations.
- Snow tone is matched on one course under one environment (Bunny Hill / `tuxracer_sunny`).
  The other seven presets and the evening/night curves have not been compared against the
  original. The snow/ice/roughness tables now cover all eight splat layers.
- Asset licence audit not started — blocks Phase 5, long lead time.

## Architecture rules

1. **`RacePhysics` has zero node dependencies.** Plain `RefCounted` stepped against a
   `SurfaceProvider`. This is what makes headless golden tests possible — do not break it.
2. **No system may depend on a feature Compatibility lacks**: no compute shaders, no
   `RenderingDevice`, no HDR (RGBA8 only), no decals/volumetrics/SSR/SDFGI/TAA, no manual particle
   emission. Where Forward+ would help, isolate behind an interface.
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
   `Racer.kind` in drawing code; add a subclass or an `InputSource` instead. The 14-float layout
   is a file format and a wire format at once — appending a field is a version bump, moving one
   silently reinterprets every stored ghost.

## Traps found the hard way

- **`set_shader_parameter` with a packed array aliases the caller's array.** Clearing your local
  array clears what the shader reads. Pass `.duplicate()`. Cost a whole debugging pass at S1.
- **Compatibility can't `emit_particle()`.** Drive rate-based emitters instead: ETR's per-frame
  count becomes `amount_ratio`, its spray velocity becomes emitter direction and speed.
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
  `EnvironmentPreset.ambient_energy` and `sun_energy` together — two scalars solved against two
  measured points on one captured frame, because one scalar cannot place both ends. Do not fold
  them back into the migrated colours.
- **`Environment.ambient_light_sky_contribution` defaults to 1.0**, which hands the ambient term
  to the sky even when `ambient_light_source` is `AMBIENT_SOURCE_COLOR`. On a snow course the sky
  is a wall of sunlit snow — far brighter than the migrated `[amb]` it displaces, and scaled by
  nothing in `light.lst`. Set it to 0 when the ambient is supposed to come from the data.
- **Pull the exposure down before concluding anything about a scene that clips.** Snow saturates
  the whole frame, and at 255 every hypothesis looks the same. Rendering once with
  `tonemap_exposure` at 0.25 makes the pre-tonemap value readable straight off the PNG.
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
- **`AudioServer` frees a stopped playback a frame later, so a quit has to wait for it.** `stop()`
  only marks the playback for deletion; the mixer thread has to fade it out and the object is
  freed by the `AudioServer::update()` at the end of a later main-loop iteration. Neither happens
  once the tree is coming down, so silencing from `tree_exiting` — or in the same breath as
  `SceneTree.quit()` — releases nothing and Godot reports "4 ObjectDB instances were leaked at
  exit" plus "2 resources still in use at exit", the music stream and its Ogg packet sequence.
  Every quit goes through `AudioDirector.quit_game()` for that reason: it silences, waits
  `QUIT_SETTLE`, then quits, and it owns the window's close button (`auto_accept_quit = false`)
  so the X and Alt+F4 get the same wait. **The wait is wall-clock, not frames** — it is the mixer
  thread that has to run, and 30 frames of an idle scene went by in 19 ms and still lost the race.
  This was read as a dummy-driver artefact for a phase, which it is not: the driver only makes it
  reproduce everywhere, since a container with no sound card falls back to it.
- **A `SceneTree` script's `_initialize` runs before the root Window is inside the tree**, and an
  `AudioStreamPlayer` refuses to start outside one. `tests/run_tests.gd` runs everything on the
  first `_process` for that reason — do not move it back.
- **A window size from a settings file is not the size anything renders at.** `project.godot`
  ships `window/stretch/mode="canvas_items"`, so the root viewport keeps the 1280x720 base
  aspect: ask for a 1024x768 window and the capture comes out 1024x576, letterboxed. The window
  really is the size that was asked for — do not go looking for a bug in the sizing code. Godot's
  own `--resolution`/`--fullscreen` also outrank the file, deliberately, which is what keeps
  `tools/shot.sh` capturing at 1280x720 whatever the developer's own settings say.
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
- **`ResourceLoader.load(path, "SomeScriptClass")` always fails.** The type hint is checked against
  `ClassDB`, which knows nothing about `class_name`, and the load errors out rather than falling
  back. Pass `""` and cast the result — `GhostStore.load_for` does. Also pass
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

## Deliberate deviations from ETR

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
- **Which layers are ice is `TerrainLayer.is_ice()`, not `[shiny]`.** Seven records are ice and
  the data marks only three of them shiny — `ice1`, `ice2`, `greenice`. `hockey_ice`,
  `snowy_ice`, `snowy_greenice` and `snowy_hockey_ice` ship without it, so the friction clause
  carries most of the set rather than a couple of stragglers. It catches them because every ETR
  ice terrain is `[friction] 0.2` and nothing else goes below 0.3.
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
- **The character sinks 0.1 m along its own up axis**, which the original does not do at all: it
  draws at `cpos.y + TUX_Y_CORR` and stops. This used to be a local offset on the rig node, which
  is the same thing while the body's up axis is the surface normal — during the start animation it
  is not, and an offset along a standing penguin's local Y walked him sideways out of his own
  footprints. It is `Racer.CHARACTER_SINK` now, applied by `Racer.present` — which is the only
  place a body transform is written, for every racer, whoever is driving it.
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
