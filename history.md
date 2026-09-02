# PenguinRacer — build history

The record of how the rebuild got here: the two de-risking spikes as they were actually run, and
the discoveries that changed the plan. Kept for the reasoning, not as a status report — every
entry below is settled, and several describe a state the code is no longer in.

For what is true now: [`PROGRESS.md`](./PROGRESS.md) is the current build state and the open
gaps, [`AGENTS.md`](./AGENTS.md) carries the distilled trap list and the deliberate deviations,
and [`godot-port-plan.md`](./godot-port-plan.md) is the plan with its corrections marked.

---

## Spike results

### S1 — ping-pong `SubViewport` render targets in a web export · **PASS**

The plan rated this Critical: the whole snow design rests on it, and it had been inferred from
the feature matrix rather than observed.

`game/spikes/s1_pingpong/` stamps a moving footprint into a real `SnowFieldGPU`, displaces a
plane from the result by vertex texture fetch, then reads the render target back **once** and
checks the field numerically — stamped texels non-zero, untouched texels still zero, and the
trail accumulated across frames, which is what proves the ping-pong is feeding back rather than
clearing. It prints `S1_DONE PASS|FAIL`, so it is a test rather than a screenshot to squint at.

| Environment | Result |
|---|---|
| Native, GL Compatibility, Mesa llvmpipe | **PASS** — 3410 ring texels, peak depth 1.000 |
| Web export, Chromium, WebGL2 via SwiftShader | **PASS** — 3608 ring texels, peak depth 1.000 |
| Web export, Firefox | **not verified** — see below |

The browser reports `MAX_VERTEX_TEXTURE_IMAGE_UNITS = 32` and `EXT_color_buffer_float`
available, so the vertex-stage sampling the design needs is comfortably within budget, and a
float trail map is an option later if `RGBA8` precision becomes the limit.

Chromium also logged `GPU stall due to ReadPixels` for the spike's one diagnostic readback —
the exact stall the plan predicted, and the reason gameplay keeps a separate CPU mirror.

**Firefox is untested, not failing.** This container has no GPU, and Firefox refuses a WebGL2
context under software rendering even with `webgl.force-enabled` and
`webgl.disable-fail-if-major-performance-caveat` set; Godot then reports "WebGL2 - Check web
browser configuration and hardware support" before any of our code runs. Nothing was observed
about Godot or about the technique. Run `BROWSER=firefox node tools/webtest/run_web_test.js`
on a machine with a GPU to close this out.

### S2 — GDScript performance of the ODE23 substep loop · **PASS, with margin**

Measured by `game/tests/bench_physics.gd`: 60 s of simulated racing on bumpy 35° terrain with
4000 trees and 500 herring in the spatial grids.

| Environment | Per frame | Share of a 16.7 ms budget |
|---|---|---|
| Native | 0.045 ms | 0.27 % |
| In-browser (WebGL2/SwiftShader, single-threaded wasm) | 0.073 ms | 0.44 % |

1.2 ODE substeps and 3.6 net-force evaluations per frame at race speed. The contingency plan —
a godot-rust GDExtension for the inner loop, accepting web-export friction — is not needed and
should not be built. Two things bought most of the headroom, both worth keeping:

- Friction and compression depth are **pre-blended per heightmap texel** at load. Both the splat
  blend and bilinear filtering are linear, so interpolating pre-blended scalars is exactly equal
  to interpolating weights and then dotting with the layer table — at 4 multiply-adds per query
  instead of up to 32.
- The **stage-3 force evaluation is reused** as the next step's first stage. The original
  re-evaluated at the identical `(pos, vel)`; dropping that takes force evaluations per accepted
  step from 4 to 3.

---

## What the plan did not know

Nineteen things turned up during implementation, in the order they were found. The first four
change the plan's own §1 constraint table; the rest are the original's behaviour, Godot's, or
the difference between the two. Each is kept whole — the wrong turns are the useful part.

### 1. Compatibility cannot manually emit particles

`GPUParticles3D.emit_particle()` is a `RenderingDevice` path and logs
*"The Compatibility renderer does not support manually emitting particles"*. The obvious port of
ETR's `generate_particles` — compute N particles with per-particle velocities and spawn them —
is therefore not available on the web target at all.

`SprayEmitter` instead steers **two rate-driven emitters**, one per side: ETR's per-frame count
becomes an emission rate via `amount_ratio`, and its spray velocity becomes the emitter's
direction and initial speed. The logic that matters — which side, how much, how fast, how wide,
keyed to the sign of `turn_fact` — is unchanged.

### 2. `set_shader_parameter` with a packed array aliases the caller's array

Setting a `PackedVector4Array` uniform and then calling `.clear()` on the local array clears what
the shader reads. This silently produced an empty deformation field for the whole first pass at
S1 — the shader was correct, the render targets were correct, and the stamps simply never
arrived. `SnowFieldGPU` now passes `.duplicate()` and rebuilds its stamp list each frame.

Worth knowing generally: it applies to any packed array handed to a material.

### 3. Slerping a chase camera's orientation puts roll in the horizon

The plan says to reproduce `view.cpp`'s "quaternion-interpolated orbit and orientation". Doing
that literally tilts the horizon permanently: the shortest arc between two look-at orientations
passes through orientations with roll, and while the target keeps moving the lag never settles,
so the roll never washes out. `ChaseCamera` interpolates the camera **position and aim point** as
vectors and rebuilds the basis against world up each frame — identical lag, no roll.

### 4. `env/environment.lst` needs the other SP-list parsing mode

`CSPList` has two modes and exactly one file uses the second: `env.cpp` loads
`environment.lst` with `CSPList list(true)`, where every line is its own record. That file's
records carry no leading `*`, so parsing it in the default mode silently merges every
environment into the first — which is how `tuxracer` (used by `bunny_hill` among others) came
out missing while `etr` imported fine.

### 5. A trail-map normal is a perturbation, not a replacement

The terrain shader reconstructed its normal from the snow trail map and mixed the geometric
normal 85 % of the way toward it. But the trail map is empty on undisturbed snow and outside its
own 64 m window, so the reconstructed normal is `(0, 1, 0)` almost everywhere — the mix flattened
the entire hill into a fake horizontal plane. Every slope lit as though it faced straight up,
which on a snow course clips to white, and the only shaded relief left on the course was the
trench under the player. It reads as detail that exists only within a few metres of the camera.

Adding the depth gradient to the existing normal instead is a no-op where there is no trail, which
is the correct behaviour, and costs the same four taps.

### 6. A billboard's shading normal must not follow the billboard

`BILLBOARD_FIXED_Y` turns a quad to face the camera, and a `QuadMesh`'s normal is its own +Z — so
the shading normal turns with it and N·L swings as the player rides past. Because the quad is
flat, the whole cutout brightens and darkens together: every tree on the course visibly changes
brightness with the view angle.

`StandardMaterial3D` cannot billboard and hold a stable normal at the same time, so course objects
now use `shaders/object_billboard.gdshader`, which does the same fixed-Y turn and then shades the
quad as a **vertical cylinder**. A cylinder under a directional light presents the same aggregate
brightness from every azimuth, so orbiting a tree no longer changes its tone, while the
across-quad gradient still gives it volume.

### 7. Godot imports textures without mipmaps, and `filter_linear` ignores the ones you do have

Two separate halves of the same problem, both of which alias into a crawling speckle on a surface
as oblique as a ski slope:

- `mipmaps/generate` defaults to **false**. Right for 2D, wrong for every texture here. Now set in
  `project.godot` under `[importer_defaults]` so a re-run of the importer cannot undo it.
- The splat samplers were declared `filter_linear`, which never touches the mip chain even when the
  texture has one. A splat map carries about one texel per half metre and is read across the whole
  course; unmipped, it scrambled layer weights from pixel to pixel. Terrain albedo and splat maps
  are now `filter_linear_mipmap_anisotropic` — anisotropic because the grazing angle is the whole
  problem.

Mipmapped alpha then needs the cutout sharpened back to a one-pixel edge before the scissor test
(`fwidth` rescale), or blurred alpha ramps turn thin branches into chunky blobs that change shape
with distance.

### 8. ETR's character model frame is +Y forward, +Z belly

`CCharShape::AdjustOrientation` builds the body basis with `new_y` = the direction of travel and
`new_z` = −surface normal. So in model space **+Y is forward and +Z is the belly** — and
`shape.lst` agrees: breast, neck and head stack along +Y, the legs sit at −Y, the tail at −Y −Z,
and every white underside part is offset toward +Z.

Godot's convention is +Y up, −Z forward. Feeding one to the other leaves Tux riding down the hill
standing bolt upright. The rotation between them maps +Y → −Z, +Z → −Y and +X → −X: a 180° turn
about `(0, 1, −1)`. It is baked into the generated character scene root by the importer
(`ETRImport.MODEL_TO_GODOT`) rather than applied by the race scene, because authored glTF art is
already Y-up/−Z-forward and must not need the same fixup.

### 9. Directional shadow range has to reach as far as the terrain is legible

`directional_shadow_max_distance` was a fixed 120 m while the camera drew to 400 m and fog only
closed in at 187 m — so roughly 90 m of plainly visible slope carried no shadows at all. Godot
also fades shadows out over the last tenth of that range, and the cutoff is a sphere around the
camera, so on open terrain it lands as an **arc of shadowed ground travelling in front of the
player** with bare white hillside beyond it.

The range is now derived from the environment's own fog distance
(`RaceScene._shadow_range_for`), which puts the cutoff where the terrain has already washed out
and keeps it consistent across the sunny/cloudy/evening/night presets rather than tuned for one.
Four PSSM splits with blending replace two, so the longer range costs no near-field resolution.

### 10. ETR's sky is three flat quads on a cube, and nothing was importing them

The plan said "`PhysicalSkyMaterial` or the migrated ETR skyboxes as panoramas" (§4.3) and the
importer did neither: `import_environments` created the output directory for them and never
wrote a file into it, so every preset had a null sky and fell back to a physical sky the
Compatibility renderer draws as flat grey. The background was not stylised or unfinished — it
was **absent**, and it is half of what "does not look like the original" meant.

They are also not panoramas. `env.cpp DrawSkybox` draws a unit cube centred on the camera's
position but never rotated with it, and with `param.full_skybox` off — the shipped default —
binds three of its six faces: front at z = -1, left at x = -1, right at x = +1. Top, bottom and
back were never authored, for any of the eight environments. Reprojecting three flat faces into
an equirectangular panorama would resample every pixel to fill two thirds of a sphere that has
no content; `shaders/etr_skybox.gdshader` instead does the same cube-face intersection the
fixed-function pipeline did per vertex, per pixel, and fades to two flat colours the importer
averages off the front face's edge rows for the directions ETR left blank.

Two smaller things fell out of it:

- `env/environment.lst` writes `[high_res] true`, and `SPList.get_bool` parsed its value with
  `to_int()`, which is 0. The original's `Str_BoolN` accepts `true`/`false` as well as integers.
  The `etr` location was silently getting its 512² skyboxes instead of the 1024² ones it ships.
  It is the only tag in the whole data tree that spells a bool out — which is exactly why it
  went unnoticed.
- The side faces are 256², the front 512² (1024² high-res). ETR's own asymmetry, not a bug.

### 11. Matching a fixed-function look means matching its transfer curve

The snow read as high-contrast blue-and-blown-white against the original's narrow bright band,
and the reason was not the migrated light constants. ETR multiplies light by texture in **display
space** and clamps; Godot decodes the same texture to linear first, multiplies there, and then
ran a filmic tone curve over the result. Same numbers, different answer at both ends.

Everything below is measured on one frame of Bunny Hill captured from both games at the same
moment — 2.3 s from the start, the penguin still in the valley (`tools/shot.sh` renders the Godot
side under llvmpipe; `--fixed-fps` is what makes two runs comparable at all, and
`tools/regionstats.py` reads a rectangle of it back). Two surfaces carry the fit: the lit
near-field snow in front of the player, and the shaded bank on the right of the course.

| Bunny Hill, median R | ETR 0.8.4 | before | after |
|---|---|---|---|
| lit near-field snow | 240 | 254, half the region clipped | **238** |
| shaded bank | 192 | 112 | **192** |

The "before" column is measured off the side-by-side that started this, so the two ends were wrong
in opposite directions: the lit snow was over the ceiling with no texture left in it, and the
shaded snow was nowhere near it. That is the shape of a transfer-curve mismatch, not of a
constant that needs nudging.

What moved it, in the order it was found:

1. **Linear tone mapper instead of ACES.** ETR clips; reproducing it means clipping. A filmic
   curve pulls the shaded side of a slope down and rolls the lit side off, which is the
   high-contrast look this build had.
2. **Terrain `SPECULAR` was Godot's 0.5 default.** Snow is a dielectric at about 0.02. Half a
   unit of F0 puts the sun's highlight and the environment reflection on top of an already bright
   surface.
3. **The environment reflection is off** (`REFLECTION_SOURCE_DISABLED`). ETR's terrain has no
   reflective term. Godot's is Fresnel-weighted, so at the grazing angle a chase camera spends
   all its time at, a sky made of sunlit snow was worth roughly a fifth of a unit — and no amount
   of `sun_energy` tuning touches it, because it does not come from the sun.
4. **`Environment.ambient_light_sky_contribution` defaults to 1.0**, which hands the ambient term
   to the sky even when `ambient_light_source` is `AMBIENT_SOURCE_COLOR`. Once the skybox existed
   (§10) that meant the ambient came from a wall of sunlit snow instead of from `[amb]`.
5. **The GL light model's own ambient was never migrated.** `light.lst` gives a per-light
   `[amb]`, and the importer took it at face value — but ETR never calls `glLightModel`, so
   OpenGL's default `GL_LIGHT_MODEL_AMBIENT` of (0.2, 0.2, 0.2) is added to every surface on top
   of it. It is the floor under the original's snow; without it the shaded side of every slope is
   about a third too dark, which no tone curve fixes because the *ratio* between a lit slope and
   a shaded one is wrong. It is added in the importer, where it shows up in the generated preset,
   rather than folded into an energy scalar.
6. **`Environment.fog_density` gates depth fog too**, not just the exponential mode, and defaults
   to 0.01 — so the migrated `[fogstart]`/`[fogend]` were being applied to a fog that was, to the
   eye, off. `fog_distance_scale` is back at 1.0 as well; the 2.5x stretch had been added to
   "recover draw distance", which only looked like an improvement while there was no sky behind
   the fog to see. Both are real bugs, but neither turned out to be large on this frame: with
   everything else fixed, fog is worth under 1 % of the near field and about 4 % of the far bank,
   because Godot ramps depth fog with a `smoothstep` where ETR's `GL_LINEAR` fog is linear in
   distance.
7. **`ambient_energy` and `sun_energy`, solved as a pair.** One scalar cannot place both ends of
   a range, and the ends are what "looks like the original" means. The shaded bank is almost
   entirely ambient and the near field is a mix, so the two surfaces give two equations.

#### Two methodology notes, both learned the expensive way

**Isolating one term at a time does not work here.** Rendering with the sun at zero and again with
the ambient at zero gives two frames whose values do not sum to the full frame — the full frame is
roughly *twice* their sum, and no compositing model can make a sum smaller than its parts. Zeroing
an energy evidently drops the renderer into a different path. The fit has to be done on the full
render: move one energy a little, measure, and solve the local gradient. Two wrong conclusions
were drawn from isolated frames before that was noticed.

**Pull the exposure down before concluding anything about a scene that clips.** Snow saturates the
whole frame, and at 255 every hypothesis looks identical — there is no way to tell 0.9 linear from
1.8. Rendering once with `tonemap_exposure` at 0.25 makes the pre-tonemap value readable straight
off the PNG (`tools/linstats.py`). The near field turned out to be sitting at 1.8 linear against
the original's 0.90, which is a factor of two, not a nudge.

---

### 12. Snow and ice needed the terms a splat-blended albedo cannot carry

*2026-09-01.* With the transfer curve matched (§11), the remaining problem with the snow was not
its tone — it was that it had no surface. ETR's albedo is roughly one texel per metre of terrain,
so from the chase camera the near field was a flat pale sheet, and the only shading variation
anywhere on the course came from the heightmap. Ice had the same problem and a worse one: nothing
in the shader distinguished it from snow except a roughness of 0.25.

Five things went into `shaders/terrain.gdshader`, all inside the Compatibility feature set and all
behind uniforms:

1. **Procedural micro-relief**, two octaves. A baked 128² map stores the *gradient* of a tiling
   height field (RG) and the height (B), so a normal perturbation costs one tap per octave instead
   of the three a heightmap needs. Fine (1.1 m/repeat, 25 mm) is wind crust; coarse (9 m, 0.35 m)
   is drift structure, stretched 3.4× along a wind axis so it forms sastrugi ridges rather than
   isotropic lumps — the chain rule carries the stretch, or the ridges light as though they ran
   the other way. Both fade with distance, fine first. `FastNoiseLite` does not tile and a seam
   every 1.1 m is a grid drawn across the course, so the noise is a wrapping quintic value lattice
   generated in `TerrainRenderer`.
2. **A crystal glint that twinkles.** The old term was `pow(noise, 24)` written into `SPECULAR` —
   static, so it survived being looked at but not being ridden past. Now each texel of a white-
   noise map is a facet direction, and `light()` asks whether that facet bisects eye and sun
   through a sharp lobe. A different scatter fires every frame you move. The mip chain averages
   the facets back toward the surface normal with distance, which is what sub-pixel crystals do.
3. **The trench shades itself.** Ambient-only AO from the trail-map depth (`AO_LIGHT_AFFECT` 0 —
   the sun is already handled by the tilted normal), and the ridge the vertex stage raises now
   also brightens the albedo, because snow that was turned over a moment ago has not crusted yet.
4. **Ice as a reflective dielectric.** A Schlick-weighted sky reflection through `EMISSION`, a
   tight sun glare on the same weight, and diffuse albedo scaled to 0.82.
5. **The per-layer tables now cover all eight layers.** `layer_roughness` / `layer_snowness` were
   four-wide, so an eight-layer course got "rough, not snow, not ice" for its last four terrains.

**The ice albedo cut is the load-bearing part, and it is a deviation.** Fresnel at the ~65°
incidence a chase camera sits at is only about 0.09. Laid over ETR's ice albedo — already
three-quarters of the way to white, and clipping in blue — that is four levels nobody sees, which
is why the first version of the reflection measured a mean difference of 1.0/255 over a whole
frame of `inception`, a course made entirely of ice. Lowering the diffuse gives the additive terms
somewhere to land, and it is also the physics: a smooth dielectric reflects the light a snowpack
would have scattered back at you. On `follow_white_rabbit` the near-field ice goes from
(R 192, G 212, B 255-clipped) to (145, 162, 217) and stops clipping at all.

**The Bunny Hill fit survives.** The fitted near-field region moves from median R 236 to 238
against ETR's 240 — inside the noise of the original fit, because relief adds variance rather than
level. No measurable frame-time cost either: 900 frames at 3840×2160 take 26–30 s before and
after, which is run-to-run noise on a windowed compositor.

**Two mistakes worth not repeating**, both now in `AGENTS.md`: a relief "strength" of 0.18 is a
71° tilt when the stored gradient peaks near 12 (write the unit in the uniform name), and
`normalize()` of a mipped white-noise tap is a NaN that survives being multiplied by a zero fade.

### 13. The container had a GPU the whole time

*2026-09-01.* `tools/shot.sh` ran under Xvfb and llvmpipe because Godot said "your video card
drivers seem not to support the required OpenGL version". It does. The container has a Wayland
socket at `$XDG_RUNTIME_DIR/wayland-0` and a DRI render node, and the only thing missing was
`libegl1`/`libegl-mesa0`/`libdecor-0-0` — the real error, one line higher, is "Can't load EGL
dynamic library", and the OpenGL complaint is the fallback misdiagnosing it.

With those installed and `--display-driver wayland`, a 120-frame Bunny Hill capture takes 3 s
against radeonsi instead of a little over two minutes. `shot.sh` picks the GPU path when both the
socket and the render node exist; `SHOT_FORCE_SOFTWARE=1` forces llvmpipe, which is still the
right call before trusting a small tone measurement, since the two rasterisers do not agree to
the last level.

### 14. `is_action_just_pressed()` does not mean the key is still down

*2026-09-01.* Over a RustDesk session, WASD steering and the space-bar jump did nothing while `r`
restarted the race normally. The input map was not the difference — every action is mapped by
keycode with `physical_keycode` 0, `r` (82) shaped exactly like `a` (65). The difference is how
each one is read: `r` goes through `Input.is_action_just_pressed()`, everything the player holds
goes through `Input.is_action_pressed()` and `Input.get_axis()`.

Godot latches the press *frame*, not the press *state*. Injecting a down and an up into one
inter-frame gap and polling on the next frame gives `pressed=false just_pressed=true axis=0.00`;
a genuinely held key gives `pressed=true just_pressed=true axis=-1.00`. So a keyboard forwarded
as zero-length pulses — RustDesk's Legacy/Translate mode synthesises keystrokes from characters
and repeats the down/up pair at the autorepeat rate — fires every edge-triggered control and is
invisible to every polled one. Nothing is dropped; the presses just have no duration left by the
time the frame poll runs.

Switching the session to RustDesk's Map mode is the real fix. `KeyHoldFilter` can paper over it
instead: `-- --remote-keyboard` stretches a press that did not survive to the next poll to 100 ms,
which bridges the ~33 ms between autorepeat pulses and turns the train of them back into a hold.
That is opt-in and off by default, because the stretch is not free — a release lingers a tenth of
a second, which is the difference between a trick landing and a crash, and paying that on every
local keyboard to fix a transport almost nobody is on is the wrong trade. What is always on is the
*detection*: a pulse prints one line naming itself and the flag, so the next person to hit this
reads the answer off the console instead of re-deriving it. `scenes/key_log.tscn` prints how long
each key was actually held and states which keyboard it is looking at — run it over the link
rather than guessing.

### 15. `[part]` and `[trackmarks]` are two flags, and one terrain disagrees

Terrain surface properties were ported in Phase 0 and are load-bearing: `[friction]` and
`[depth]` are pre-blended per heightmap texel and read by `calc_friction_force`,
`calc_brake_force`, `calc_paddle_force`, `calc_roll_normal` and `calc_normal_force`, so ice at
0.2 and rock at 0.7 genuinely play differently. But only three of the four gameplay fields
reached the physics query path. `TerrainLayer.takes_trackmarks` was imported from
`[trackmarks]`, saved into all 41 layer resources, and then read by nothing except the importer's
own `is_deformable` assignment — the deformation stamp in `RaceScene._on_substep` gated on
`emits_particles` instead.

For every terrain any shipped course actually uses the two flags agree, so nothing was visibly
wrong. They disagree on exactly one terrain in `terrains.lst`: `strike_snow` is
`[part] 1 [trackmarks] 0` — snow that sprays but packs too hard to hold a trench. It is currently
unreachable anyway, because ETR's own ±30 colour matching lets `snow` (255,255,255) swallow it
(255,230,255) before the lookup gets there, which is why no course references it.

Fixed by carrying `takes_trackmarks` through `SurfaceSample` and `HeightmapSurface` alongside
`emits_particles` — same dominant-texel rule, one more `PackedByteArray` — and gating the stamp on
it. Corrected 2026-09-01. The lesson is that a migrated field is not ported until something reads
it: the resources looked complete and the tests passed because the tests only asserted what the
consumer happened to consume.

Still not ported from `terrains.lst`: `[starttex]`/`[tracktex]`/`[stoptex]`, which are the
original's trackmark decal atlas indices and have no analogue here — the GPU trail map replaced
them. `[sound]` followed in §16.

### 16. The sound system is small, and most of it is the original's mixer being odd

Audio was the last unported subsystem: 10 effects, 10 music pieces and three racing themes, all
of it sitting in `data/sounds/` and `data/music/` behind two `.lst` files. The code that plays
them (`audio.cpp`, 289 lines) took longer to read than to rebuild, because almost every part of
it behaves in a way a modern mixer does not — and each of those is load-bearing somewhere.

**One voice per cue, not a pool.** `TSound` owns a single `sf::Sound` and `Play` returns early
while it is still playing, so a sound can never overlap itself. That is not a limitation the game
works around, it is a thing the content depends on: collecting a herring fires `pickup1`,
`pickup2` *and* `pickup3` together, three separate cues for one event, because one cue could not
have layered with itself. `AudioDirector` keeps one `AudioStreamPlayer` per cue for the same
reason — a voice pool would silently change how a burst of pickups sounds.

**`Halt` only stops looping sounds.** `CSound::Halt` checks `getLoop()` first, so a one-shot
cannot be cut off by anything except `HaltAll`. Reproduced, because the terrain slide is the only
looped cue and that check is what stops a terrain change from clipping a pickup.

**Volumes are percentages clipped at 100, and `[vol]` is dead.** `sounds.lst` carries a `[vol]`
column that nothing reads: `LoadChunk` builds every chunk at `param.sound_volume` and the only
code that ever revisits a volume is `SetSoundVolumes` in `racing.cpp`, which overrides six of the
ten by name with different numbers. `snow_sound` is `[vol] 0.2` in the file and gain 1.5 in the
code. Both are migrated — the live one onto `SoundCue.race_gain`, the dead one onto
`legacy_volume` next to it, the way `TerrainLayer.legacy_color` is kept — because a re-import
should be diffable against the source and because the discrepancy is worth being able to see.
The ceiling matters too: `MIX_MAX_VOLUME` is 100 and `CalcSoundVol` clips there, so at the
default effects volume of 90 the snow slide's 1.5 gain is really 1.11.

**The slide sound has no speed term.** There is a `SlideVolume` in `racing.cpp` that scales with
speed, lean, braking and jumping — commented out, above the line "this function is not used yet".
So the terrain slide is on or off and nothing else, and that is what was ported. It is the single
most obvious thing to improve and the single easiest thing to get wrong by assuming.

**And the commonest terrain in the game is silent.** 12 of the 43 records in `terrains.lst` have
no `[sound]`, `snow` among them — only `dirty_snow` ever reaches `snow_slide.wav`. `ice2` is
silent while `ice1` is not. Migrated as it stands: it is one string per terrain to change, but
choosing which terrains should make a noise is a design decision, not a port, and doing it
quietly would have buried the fact that the original does not. `test_audio.gd` asserts the
silence so that filling it in later is a visible change.

Music is simpler and has one behaviour worth keeping: `CMusic::Play` compares against the
currently playing piece and returns without restarting if they match. That is what lets a menu
open over a race without cutting the track, and it is why `AudioDirector` tracks the stream
rather than just calling `play()`.

Three things came out of the port that were not about audio:

- **`terrains.lst` declares `pave04` three times**, with three different textures, three colour
  keys and a `[sound]` on only the first. The original indexes `TerrList` by position and never
  looks a terrain up by name, so it keeps all three; the importer keyed layer resources by name
  and the last record won — which means two of those colour keys had been resolving to another
  record's texture since Phase 1. Left as it was here, on the grounds that disambiguating the
  names re-identifies every course's splat layers, with a warning added so it was at least not
  silent. Fixed properly the next day — §17, which also corrects this bullet: the three records
  share a friction and a depth, so what the collapse actually cost was the texture and the
  slide sound.
- **`TerrainLayer.footstep_sound` was the wrong shape.** It held an `AudioStream`, so every
  course would have referenced the slide effects through its terrain layers and pulled 4 MB of
  shared streams into each course pack. ETR stores a *name* resolved against the global bank, and
  so does `slide_sound: StringName` now.
- **A stopped playback is never reaped under the dummy audio driver.** This container has no
  sound card, so every run falls back to it — and it never mixes, so `AudioServer` never retires
  a playback that has been stopped. Godot then reports "4 ObjectDB instances were leaked at exit"
  over every screenshot. It is not the streams being held: stopping on `tree_exiting`, clearing
  the player's stream and freeing the node all happen and change nothing, and a bare
  play-then-stop of a single WAV in a five-line script reproduces it. `tools/shot.sh` passes
  `--no-audio` now, which is right on its own terms — a capture has nothing to hear — and the
  capture it produces is byte-identical to the one from before this change.

  **Corrected 2026-09-02, and it was not the driver.** `AudioServer` retires a stopped playback on
  a *later* main-loop iteration on any driver: `stop()` marks it, the mixer fades it out, and
  `AudioServer::update()` frees it after that. `tree_exiting` runs after the last iteration, so
  there is no later one — which is why stopping there changed nothing, and why the five-line
  repro reproduced it. The dummy driver's only contribution is making it happen on every machine
  without a sound card, and the reasoning above stopped at that correlation. Fixed properly in
  §18: every quit now goes through `AudioDirector.quit_game()`, which silences, waits out one
  mixer buffer and only then brings the tree down.
- **The test runner had to move off `_initialize`.** The tree's root Window is not yet inside the
  tree when a `SceneTree` script's `_initialize` runs, and an `AudioStreamPlayer` refuses to start
  outside one. Everything now runs on the first `_process` instead. The physics suite does not
  care; anything node-shaped added later will.

Ported 2026-09-01. 100 assertions cover the bank, the themes, the volume arithmetic, the
terrain → cue mapping and the three mixer behaviours above. Traced through a real run, a carve
down Frozen River moves snow → `ice_sound` → snow and drops the loop while airborne; the same
carve down Bunny Hill is silent from top to bottom, because Bunny Hill is snow.

### 17. `terrains.lst` declares `pave04` three times, and the importer kept one

Terrain layers were imported into one resource per `[name]`, which is the obvious key right up
until the data uses a name twice. `terrains.lst` uses `pave04` for records 24, 29 and 30 —
three textures (`pave04.png`, `icy_rock06.png`, `icy_pave04.png`), three colour keys
(90,0,0 · 255,60,60 · 255,120,120), and a `[sound] rock_sound` on the first and none on the
other two. Writing all three to `resources/terrain/pave04.tres` left the last one standing, so
two colour keys resolved to a layer belonging to a third, and the one record with a slide sound
lost it. All three happen to carry `[friction] 0.5 [depth] 0.05`, so the cost was the texture and
the sound rather than the feel. That had been true since Phase 1.

It is not a fault in the data. Nothing in the original looks a terrain up by name: courses paint
a colour, `CCourse::GetTerrainIdx` resolves it to a *position* in `TerrList`, and `TTerrType`
has no name field at all — `LoadTerrainTypes` reads `[texture]`, `[sound]`, `[col]`, `[friction]`
and the rest, and drops `[name]` on the floor. A repeated name costs the original nothing. It
cost us two of three records, because a file per name is a stricter identity than the format has.

Fixed by keying on the record instead. The first holder of a repeated name keeps it; a later one
takes its texture stem, which is unique across all 43 records and is what actually tells them
apart — and is how the file already names `icy_pave05` after `icy_pave05.png`. So the three are
now `pave04`, `icy_rock06` and `icy_pave04`. `TerrainLayer` carries `legacy_name` and
`legacy_index` alongside `legacy_color` so the record it came from stays traceable, and
`legacy_color` is documented as the identity that matters: it is what a course paints.

Two smaller things fell out of the same pass:

- **A missing layer resource would silently shift every later splat channel.** The resources
  stage resolves `layer_names` from `import_meta.cfg` and skipped any that would not load, which
  slides layer 3 onto channel 2: the course still loads and plays the wrong friction under the
  right texture. Latent rather than live — every name resolved — but it is the failure mode that
  turns a renamed layer into a mystery, so the slot is now kept, filled with a default, warned
  about.
- **Two records name a texture that is not in the tree.** `pave04` wants a `pave04.png` nobody
  shipped, and `snowy_hockey_ice` writes `snowy_ice02` without the extension. `TTexture::Load`
  concatenates directory and filename and guesses nothing, so both are untextured in the
  original as well — migrated as they stand, but the importer says so now instead of quietly
  producing a layer with no albedo.

No shipped course paints any of the three `pave04` colour keys, or `snowy_hockey_ice`'s, so
nothing that has ever been rendered or measured was wrong. That is exactly why it survived a
phase: there was no capture to look odd and no assertion to go red. `tests/test_terrain_library.gd`
now checks the generated library back against `terrains.lst` record by record — one resource per
record, unique ids, unique colour keys, and friction, depth, sound and colour matching the file —
which is the level the bug lived at. Fixed 2026-09-01.

### 18. Three lines on the console when the game closes

Closing the game printed a keyboard diagnostic and two engine complaints:

```
KeyHoldFilter: pulsed keyboard confirmed; held controls are being stretched.
WARNING: 4 ObjectDB instances were leaked at exit
ERROR: 2 resources still in use at exit
```

`--verbose` named the two engine ones straight away: `OggPacketSequence`,
`AudioStreamOggVorbis`, `AudioStreamPlaybackOggVorbis`, `OggPacketSequencePlayback`, and
`res://assets/music/race1-jt.ogg` twice. Only the music — not one of the ten WAV effects, because
music is the one thing still playing when a player quits.

The standing explanation (§16) was that the dummy audio driver never mixes and so never retires a
stopped playback, and that a container with no sound card was the whole story. That was a
correlation. `AudioServer` retires a stopped playback on *any* driver a frame later than you stop
it: `stop()` marks it for deletion, the mixer thread has to fade it out, and the object is freed
by the `AudioServer::update()` at the end of a subsequent main-loop iteration. `AudioDirector`
silenced everything from `tree_exiting`, which runs *after* the last iteration — so there was no
subsequent one, and the "stopping the player, clearing its stream and freeing the node change
nothing" observation from §16 was exactly right and pointed at the wrong culprit.

Two things came out of measuring it rather than reasoning about it. The first is that stopping in
the same breath as `SceneTree.quit()` does not work either — the leak needs a *gap*, not merely a
stop that happens before the quit. The second is that the gap is wall-clock and not frames. A
sweep of the two units in an idle scene, five runs each:

| wait after silencing | leaks |
|---|---|
| yield only, no wall-clock wait | 5/5 |
| 5 ms | 0/5 |

while a frame-counted wait was pure noise at the same measurement — the scene idled at about
1500 fps, so thirty frames went by in 19 ms and lost the race that five milliseconds won. What has
to elapse is one mixer buffer on the audio thread; the renderer's frame rate has nothing to do
with it, and a frame count tuned on a slow machine is a frame count that comes apart on a fast one.

So every quit in the game now goes through `AudioDirector.quit_game()`: silence, wait
`QUIT_SETTLE` (100 ms — several buffers at any plausible latency, and nothing a player feels on
the way out), then `SceneTree.quit()`. The window's close button and Alt+F4 reach it because the
director sets `auto_accept_quit = false` and handles `NOTIFICATION_WM_CLOSE_REQUEST`, which Godot
propagates to every node under the root window, autoloads included. `tree_exiting` still silences
as a backstop for a tree that comes down some other way; it just is not the mechanism any more.

Verified by closing the real game from a window manager — Xvfb plus openbox plus `wmctrl -c`,
which is the only way to exercise the path a player actually takes — on the menu with its music
running and mid-race with the slide loop as well. Both exit clean. `tools/shot.sh` keeps
`--no-audio`, which is still right on its own terms (a capture has nothing to hear, and it saves
loading 18 MB of streams), but it is no longer load-bearing: a capture run *with* sound now exits
clean too.

An aside on method. An early attempt at a "before" run stashed `game/scripts` — and reverted a
working tree with a phase of uncommitted work in it, so what came back was a pile of parse errors
rather than the old behaviour. The trap list already carried this as `git stash` swallowing the
test harness, with the lesson "narrow the stash to `game/`"; narrowing is not what makes it safe.
A stash-based A/B assumes the tree is committed, and this one is not. Toggling the one constant
under test (`QUIT_SETTLE`) is what a before-and-after wanted, and is what produced the table
above.

### 19. One zero-length pulse is also what a quick tap looks like

The keyboard line above was not about closing the game at all — it is printed once, the first time
`KeyHoldFilter` decides the transport is pulsed, and it happened to still be on screen at the end
of a session. It was also, at least some of the time, wrong.

§14 built the detector on the shape of the sample: a press whose `is_action_just_pressed()` edge
arrived with `is_action_pressed()` already false was pressed and released inside one frame, which
is what RustDesk's Legacy/Translate mode does to every held key. The shape is right and the
inference from a single one is not. An ordinary finger on an ordinary local keyboard produces the
same sample whenever a tap is shorter than a frame — `xdotool key w` against a windowed build
reproduces it every single time — and one flick of the steering was enough to print a paragraph
telling the player to go and reconfigure a remote desktop they were not using.

What separates the two is cadence. A pulsed transport does not send one pulse; it repeats the
down/up pair at the keyboard's autorepeat rate for as long as the key is held, which X11 defaults
to every 25–33 ms. A hand cannot produce two of those inside 150 ms *and* have both halves of both
taps land inside a frame each. So `KeyHoldFilter.PULSE_WINDOW` is 150 ms and nothing is reported
until a second pulse on the *same* action lands inside it — one control tapped and another tapped
alongside it is two hands, not a transport.

The compensation was never gated on the diagnosis (it is gated on `--remote-keyboard`, which the
player passes), so this changed no gameplay behaviour, only what gets printed. Confirmed against
the real game under the same window-manager harness: a single `xdotool key w` now says nothing,
and ten of them 30 ms apart — a translating remote desktop, near enough — still reports.

Fixed 2026-09-02, both sections.
