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
  scripts/character/      CharacterRig + KeyframePath — the rig the importer writes
                          and the root motion a keyframe animation cannot carry
  scripts/audio/          AudioDirector autoload + generated sound/music banks
  scripts/config/         GameConfig autoload — the player's settings file
  scripts/debug/          DebugCapture autoload (headless screenshots / scripted input),
                          key_log (what a remote desktop is doing to the keyboard)
  shaders/                terrain (splat + snow/ice shading), etr_skybox,
                          snow_trail, s1_displace
  addons/etr_import/      one-way, re-runnable importer from the ETR data tree
  courses/<name>/         GENERATED: course.tres, course.tscn, heightmap.res, splat_*.png
  resources/  i18n/       GENERATED: layers, prefabs, environments, events, course
                          catalog, sound bank + music library, 13 translations
  assets/sounds|music/    GENERATED: the 10 effects and 10 pieces, copied verbatim
  scenes/                 main_menu.tscn (the main scene), course_menu.tscn,
                          settings_menu.tscn, race.tscn, key_log.tscn
  tests/                  headless suite (physics, surface, input, audio, imported
                          terrain library, character rig) + ODE benchmark
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
godot --path game -- --remote-keyboard                             # ... over a pulsed remote keyboard
godot --path game -- --no-audio                                    # ... silent, for captures
godot --path game -- --no-intro                                    # ... skipping the start animation
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
Window size, render scale and fog distance; delete it to get the defaults back. The main menu's
**Configuration** screen moves the same five keys and writes the same commented file back.

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
| 4 — character | rig + canned clips done, procedural layer not started — welded ArrayMesh from `shape.lst` **skinned** to a Skeleton3D with ETR joint names, the four keyframe lists as an AnimationLibrary plus a `KeyframePath` of root motion each, and the pre-race start animation (`CIntro`) wired into the race. No additive layer over racing (`AdjustJoints`); finish/wonrace/lostrace imported but not played. |
| 5 — game shell | partial — `main_menu.tscn` is the main scene: Practice opens the course list, Configuration edits `penguinracer.cfg` graphically, and a race is a scene the shell hands over to and takes back. Generated course catalog, 13 languages wired to `tr()`, audio (10 effects + 10 pieces + 3 racing themes on an `AudioDirector` autoload that reproduces ETR's one-voice-per-cue mixer). No cups, medals or profiles (data is imported and waiting); no volume or language controls on the settings screen. |
| 6 — polish/ship | not started. |

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
- **Directional shadows stop at `directional_shadow_max_distance`**, on a sphere around the camera.
  Set shorter than the visible slope it reads as an arc of shadow travelling in front of the
  player. It is derived from the environment's fog range in `RaceScene._shadow_range_for` — keep it
  tied to visibility rather than hardcoding a number.

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
  footprints. It is `RaceScene.CHARACTER_SINK` now, applied by whoever writes the body transform.
- **A shoulder carrying both `[sh]` and `[arm]` is one quaternion key interpolated by slerp**, where
  the original interpolates the two angles separately and rebuilds both matrices. The two agree
  exactly whenever one angle is constant across a segment, which covers all of `start.lst` (no
  `[arm]` at all). A `Skeleton3D` rotation track offers no per-axis alternative.
- Numeric string IDs became semantic keys (`PRESS_ANY_KEY_TO_START`); old IDs are traceable via
  `i18n/legacy_string_ids.cfg`.

## Licensing

ETR code is **GPL-2.0-or-later**. Physics *constants and the physical model* are facts about a
simulation and are the valuable part — implement from `etracer.md` §4.1 rather than translating
C++ line-for-line. Data assets have mixed authorship (`etr-0.8.4/data/credits.lst`, `AUTHORS`);
treat every reused asset as needing its own licence check.
