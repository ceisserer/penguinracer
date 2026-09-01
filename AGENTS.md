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
| `PROGRESS.md` | Detailed build state, spike results, and what the plan got wrong. |
| `README.md` | Commands, prerequisites, layout. |

Keep all four current when you change things. `PROGRESS.md` is the running log; corrections to the
plan go in `godot-port-plan.md` marked with a date.

## Layout

```
game/                     Godot project (project.godot, gl_compatibility)
  scripts/physics/        RacePhysics + surface + snow — plain RefCounted, zero node deps
  scripts/course/         CourseData, TerrainLayer, prefabs, events, environments
  scripts/render/         terrain chunks, GPU snow field, spray
  scripts/camera/         chase camera        scripts/shell/  HUD, course menu
  scripts/debug/          DebugCapture autoload (headless screenshots / scripted input),
                          key_log (what a remote desktop is doing to the keyboard)
  shaders/                terrain (splat + snow/ice shading), etr_skybox,
                          snow_trail, s1_displace
  addons/etr_import/      one-way, re-runnable importer from the ETR data tree
  courses/<name>/         GENERATED: course.tres, course.tscn, heightmap.res, splat_*.png
  resources/  i18n/       GENERATED: layers, prefabs, environments, events, course
                          catalog, 13 translations
  scenes/                 race.tscn, course_menu.tscn, key_log.tscn
  tests/                  headless physics suite + ODE benchmark
  spikes/s1_pingpong/     ping-pong render-target spike (risk S1)
etr-0.8.4/                original source + data — READ-ONLY, never write here
tools/                    import_all.sh, shot.sh (deterministic screenshot, real GPU
                          when there is one),
                          png.py + regionstats.py + linstats.py (compare a
                          capture against a reference numerically),
                          webtest/ (COOP/COEP server + puppeteer runner)
```

Not a git repository.

## Commands

```bash
godot --path game                                                  # play (Esc = course menu)
godot --path game -- --remote-keyboard                             # ... over a pulsed remote keyboard
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
node tools/webtest/run_web_test.js http://127.0.0.1:8060/index.html /tmp/web.png RACE_READY
```

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
| 0 — physics core | **done** — every §4.1 force, ODE23 adaptive, spatial grids. 2293 assertions, 0 failures, 0.8 s headless. |
| 1 — importer + first course | **done** — all 44 courses, 43 layers, 14 prefabs, 8 environments, 5 characters, events, 111 strings × 13 languages. bunny_hill drivable in a browser; wild_mountains (100×1000) runs. |
| 2 — rendering | partial — splat PBR, chunked terrain, instanced trees, HUD, migrated skyboxes. Tone matched to the original on Bunny Hill; no LightmapGI bake. Snow and ice carry procedural micro-relief, a twinkling crystal glint and a Fresnel sky reflection. |
| 3 — snow | mechanism proven, integration partial — GPU trail map + CPU mirror both wired; a carve leaves a track with a shaded trench, a self-occluded floor and a bright ploughed lip. |
| 4 — character | placeholder done — welded ArrayMesh from `shape.lst` + Skeleton3D with ETR joint names + keyframe AnimationLibrary. |
| 5 — game shell | partial — course-select menu over the live race, generated course catalog, 13 languages wired to `tr()`. No cups, medals, profiles or audio (data is imported and waiting). |
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
- Web cold load 161 MB (128 MB pck) — all 44 courses bundled. Needs per-course streaming (Phase 6).
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
   in `game/courses/` and `game/resources/`. A course touched in-editor carries a provenance flag
   and is skipped without `--force`.
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
  leaving the work stashed. Commit tooling changes first, then `git stash push -- game`.
- **`Input.is_action_just_pressed()` stays true for a key that has already been released.** It
  compares the latched press frame to the current frame and never looks at the key state, so a
  keyboard forwarded as zero-length down/up pulses (RustDesk's Legacy/Translate mode, some VNC
  clients) drives every edge-triggered control and none of the held ones — `r` restarts the race
  while WASD and space do nothing. `KeyHoldFilter` notices the pulse and says so once; passing
  `-- --remote-keyboard` makes it stretch such a press to 100 ms, which is opt-in because the
  stretch costs a local keyboard its frame-exact release. `godot --path game
  res://scenes/key_log.tscn` prints what the link is actually delivering.
- **A migrated field is not ported until something reads it.** `[trackmarks]` was imported onto
  `TerrainLayer` and written into all 41 layer resources, but never reached `SurfaceSample`, so the
  deformation stamp gated on `[part]` instead. The two agree on every terrain a shipped course
  uses, and the tests passed because they asserted only what the consumer consumed. When adding a
  surface property, trace it to its consumer and test it there.
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
- **Which layers are ice is `TerrainLayer.is_ice()`, not `[shiny]`.** The data only marks three of
  the five ice terrains shiny; `hockey_ice` and `snowy_ice` ship without it. The friction clause
  catches them, because every ETR ice terrain is `[friction] 0.2` and nothing else goes below 0.3.
- **Linear tone mapper, no glow, no SSAO.** ETR clamps in display space and has neither effect;
  a filmic curve redistributes both ends of the snow's range and glow smears the highlights that
  snow is mostly made of. Reproducing a fixed-function look means reproducing its transfer curve.
- **Fog stays at the original's 75 m range** (`fog_distance_scale` 1.0). Stretching it to 2.5x to
  recover draw distance was a wording-level "improvement" that removed the white haze ETR's snow
  sits inside — corrected 2026-09-01, once there was a sky behind the fog to see.
- **`Environment.fog_density` gates depth fog too**, not just the exponential mode, and defaults
  to 0.01. Set `fog_mode = FOG_MODE_DEPTH` and a range and leave density alone and you get fog at
  one per cent — indistinguishable from fog switched off, and the migrated `[fogstart]`/`[fogend]`
  quietly do nothing. Godot also ramps depth fog with a `smoothstep`, where ETR's `GL_LINEAR` fog
  is linear in distance, so the near field stays clearer here than it does there even at the
  migrated range.
- **Ambient comes from the migrated `[amb]`, not from the sky** —
  `Environment.ambient_light_sky_contribution` has to be set to 0 for that to be true. See the
  trap list.
- Numeric string IDs became semantic keys (`PRESS_ANY_KEY_TO_START`); old IDs are traceable via
  `i18n/legacy_string_ids.cfg`.

## Licensing

ETR code is **GPL-2.0-or-later**. Physics *constants and the physical model* are facts about a
simulation and are the valuable part — implement from `etracer.md` §4.1 rather than translating
C++ line-for-line. Data assets have mixed authorship (`etr-0.8.4/data/credits.lst`, `AUTHORS`);
treat every reused asset as needing its own licence check.
