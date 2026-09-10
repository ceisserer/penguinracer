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

Twenty things turned up during implementation, in the order they were found. The first four
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

**Correction, 2026-09-08.** The conclusion above is right about the mechanism and wrong about the
tool. What has to elapse *is* wall-clock, and `SceneTree.create_timer` does not measure it: it
counts down by the frame delta, so the interval it delivers is however many whole frames fit,
each measured with the previous frame's length. The frame that asks to quit is the one that just
wrote a PNG or tore down a course, so that delta is nothing like the frames after it. Instrumented
on the real path, the 100 ms timer returned after 43 ms and four frames and the music playback was
released on the fifth — every quit from the menu still leaked the four instances this section was
written to stop, 7 runs in 8. The 5 ms row in the table above is measuring the same confound from
the other side. `AudioDirector.await_settled` now waits for the objects themselves — a `weakref`
per playback, yield until they are all gone, `QUIT_SETTLE_TIMEOUT` as a backstop — and the same
window-manager check comes up clean on the menu, mid-race, and on the results screen. The
verification below missed it because it was run under `--fixed-fps`, which makes the countdown
synthetic and generous. See the trap list.

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

### 20. A fixed timestep has a phase, and the obvious one is a tick behind

Preparing for more than one racer meant moving the simulation off the frame time and onto a fixed
60 Hz tick: a run has to mean the same thing at 30 fps and at 144, or a recorded ghost is not a
fair opponent and two peers cannot agree who reached the line first. The tick rate was easy to
pick — every reference capture is taken with `--fixed-fps 60`, so at 60 the accumulator would take
exactly one tick a frame and nothing would move.

Nothing moved *in the simulation*. A sixth of the frame moved anyway.

The loop was written the way every article writes it. Add the frame time to an accumulator, take a
tick for each whole `SIM_DT` in it, and draw between the last two states by `accumulator / SIM_DT`
— which at exactly 60 fps is zero, every frame, forever, so the game drew the *previous* tick and
never the live one. A constant 16.7 ms of latency, and against a procedural relief field that is
computed per fragment from the view, a fifteen-centimetre camera shift repaints everything:
1.0 M of 2.2 M bytes differed from the baseline capture, 15 % of them by more than one level.

The bug is in the phase, not in the interpolation. `accumulator / SIM_DT` renders at simulation
time `(n−1)·dt + accumulator`, which is a full `dt` behind the frame's own instant of
`n·dt + accumulator`. Rendering the live state instead would be only `accumulator` behind — better
at 60 fps and jerky everywhere else, since at 144 Hz some frames get a tick and some get none.

The formulation that is neither: run the simulation *up to* the frame rather than up to the last
tick before it. Keep how far the simulation is ahead of the drawn instant, subtract the frame time
from it, tick while it is negative, and draw at `1 − lead / SIM_DT`. At 60 fps the lead comes out
at exactly zero, the draw is the live tick, and the capture is the old one bit for bit. At 144 Hz
the three frames between two ticks land at 0.417, 0.833 and 0.25 of the way through their
respective intervals — which is 1/144, 2/144 and 3/144 of simulated time, exactly where the frames
are.

Verified by re-running `tools/shot.sh` against the pre-change tree: outside the spray — which was
never bit-reproducible, because `GPUParticles3D` seeds itself per run, and two runs of the
*unchanged* code differ there by the same 20 kB — the 200-frame Bunny Hill capture is pixel
identical. The other thing that had to move to get there was the CPU snow field: it used to be
recentred and then decayed after the step, and the first draft had the decay on the tick and the
recentre on the frame, which is a different order.

Written 2026-09-02.

---

### 21. Steering that was ignored because it was too polite

The first field of computer opponents drove down the hill perfectly happily and would not move
sideways. Not sluggishly — not at all. The planner picked an aim point six metres to the left, the
heading error came out at four degrees, the stick was set to −0.16, and the racer held its heading
for the rest of the course.

It was found by the one assertion that could find it. Two opponents were given the same lane and
the same personality and told to give each other room; the test said they had to end up more than
a metre apart, and they ended the run 0.40 m apart, which is exactly where they started. Every
other assertion — that each level gets down the hill, that hard out-drives easy, that an opponent
goes through the gap in a stand of trees — passed, because all of those are satisfied by driving
in a straight line down a fall line that happens to point at the finish.

`RacePhysics._calc_steering_controls` is a faithful port of `CalcSteeringControls`, and the
original reads the joystick like this:

```gdscript
if absf(input.stick_turn) > 0.2:
    turn_fact = input.stick_turn
elif input.left_turn != input.right_turn:
    turn_fact = -1.0 if input.left_turn else 1.0
else:
    turn_fact = 0.0
```

0.2 is a thumbstick's deadzone, and it is correct: a stick at rest reads a few per cent off centre
and a game that steered on that would be unplayable. What it also means is that an input source
which steers *proportionally*, and does not set the digital flags, is silently rounded to "not
steering" for every error inside a fifth of full lock. The AI set only the stick, on purpose — the
flags are full lock or nothing, and an opponent that could only steer flat out saws at every line
it takes.

Nothing warns. The intent is well-formed, the field is in range, the sign is right, and the value
is thrown away one function later.

The fix is a sentence: anything worth correcting has to come out past the deadzone. `stick_for`
maps a heading error to `[0.21, 1.0]` with a small dead band of its own — four per cent of the
level's own full-lock angle, so a hard opponent notices a smaller error than an easy one — and
returns zero below it. The ladder moved when it landed, which is the other half of the evidence:
easy dropped from 236 m to 231 m over thirty seconds (it now actually steers to the fish it wants)
and hard rose from 418 m to 422 m.

The generalisation is worth keeping. A faithfully ported input path has the *player's* hardware
baked into it, and a synthetic driver is not a player: it has no drift to reject, no dead zone to
survive and no fingers. Deadzones, latch windows, autorepeat and edge detection are all places
where the port is correct and a non-human caller is quietly filtered out. This is the second one
of those in the repository — §14 is the same shape from the other direction, an edge detector that
fires for a key that was never held.

Two smaller things fell out of the same session and are in the trap list rather than here. A
GDScript lambda captures by value, so `func(): hits += 1` counts into a copy and the tree-collision
assertion passed on every run including the failing ones. And an obstacle that moves with you is
not scored like one that stands still: the rival-avoidance penalty was first written as
distance-from-the-candidate-line, which is the test a tree gets, and since every candidate line
starts at the racer's own position it came out about equal for all nine of them — a penalty that
discriminates between nothing.

Written 2026-09-02.

### 22. The snow was not too bright, it was two channels short of a range

*2026-09-08.* Reported as "snow, and the scene overall to a lesser extent, is much brighter than
the original". Measured against `/tmp/etr_ref.png` — the same Bunny Hill frame §11 was fitted on
— the level was not the problem. Red matched to a level at the lit end. What was wrong was
everything else about the distribution:

| Bunny Hill, region mean | ETR 0.8.4 | before | after |
|---|---|---|---|
| lit near field R | 239.2 | 238.2 | **238.5** |
| lit near field G | 247.1 | 253.1 | **251.1** |
| lit near field G, clipped | 3.5 % | 75.8 % | **53.0 %** |
| shaded bank R | 191.7 | 168.9 | **191.7** |
| shaded bank G | 214.0 | 193.6 | **214.2** |
| shaded bank B | 253.8 | 248.6 | **253.5** |

Two causes, both the same class as §11's and both invisible.

**`light.lst` is not colours, and Godot decodes colours.** `Light3D.light_color` and
`Environment.ambient_light_color` are authored values, so Godot sRGB-decodes them before the
shader sees them. `[diff] 1.0 0.9 1.0` and `[amb] 0.45 0.53 0.75` are not authored values — they
are the numbers ETR multiplies its display-space texture by — and the decode does not scale them,
it *bends* them: 1.0 stays 1.0 and 0.7025 becomes 0.449, so the migrated ambient's blue-to-red
ratio went from 1.43 in the file to 2.23 in the shader. Nothing fails. The frame renders, and a
level fit on one channel still lands, which is exactly what §11's did — it solved two scalars
against a *red* measurement at each end and never looked at the other two. Underneath, blue sat
at 1.80 pre-tonemap against a ceiling of 1.0, green pinned at 255 across three quarters of the
near field, and red was the only channel with headroom left. That is what the complaint was: with
two of three channels on the ceiling, every bit of shading variation reaches the frame through red
alone, and a white sheet with cyan in the hollows is what that looks like.

**A scalar energy cannot reproduce a per-channel clamp.** With the decode undone, the shaded bank
landed on the reference and the lit end blew out, and no pair of scalars could hold both — because
`snow.png` is (236, 245, **255**) and `[amb]` is (0.70, 0.78, **1.00**). Blue is at the ceiling
*before any light is applied* and ETR never leaves it; any scalar under 1.0 that puts red on the
reference takes blue off a ceiling that is where the original's shaded snow gets its colour.
`sun_energy` and `ambient_energy` are therefore now `sun_gain` and `ambient_gain`, `Color`s, and
their blue components are near 1.0 for precisely that reason. Three numbers per end, six
measurements, solved the same way §11 prescribes: move one, measure the gradient, solve. The
migrated colours stay verbatim on the resource and the correction stays in its own field, which is
the constraint §11 set and is why the fix was a rename rather than a rewrite.

Both halves of the conversion now go through `EnvironmentPreset.as_light_color`, because the
version that shipped had the ambient built in `to_environment()` and the sun assigned straight onto
the light in `RaceScene` — so a fix applied to one of them would have left the other wrong and the
frame would still have rendered. `TestEnvironments` asserts the round trip rather than the look:
whatever a preset hands Godot has to come back out of `srgb_to_linear` as the file's number times
its gain.

#### Three methodology notes

**The exposure-0.25 trick from §11 is an instrument, not a measurement.** It answers "has this
channel any headroom left" and it does that well — blue reading 1.80 against a ceiling of 1.0 is
what found the whole thing. It does not answer "how much", because the two exposures are not
related by a factor of four at the bright end: a pixel that reads 0.913 linear at exposure 1.0
comes back as 0.812 at 0.25 while a mid-tone agrees to 1 %. A fit taken on the dim render landed
several levels off and had to be redone at the shipping exposure, which is where the reference
frame lives anyway.

**Fit on the surface the reference does not clip.** The shaded bank carries the fit now, and the
lit near field only confirms it. ETR's own blue is at 255 over the whole lit region and 66 % of the
bank, so at the lit end there are one and a half channels of information and at the shaded end
there are nearly three.

**The two frames are not the same view, and that is the floor on this fit.** After the fit our lit
region's upper half still runs about six levels over ETR's. It is not the relief or the glint from
§12 — turning both off made the region *brighter*, since what they mostly add is darkening
variance — nor the trench lip's albedo boost nor the half-Lambert wrap, each worth two levels. It
is most likely the framing: ETR's reference is at 25 km/h on undisturbed snow, ours at 44 km/h over
a fresh trench, with a 70° FOV at 19° above the slope against the original's 60° at 10°. Closing it
wants a reference captured at a matched camera, not another number.

An aside worth recording: the *old* pipeline's double bend was load-bearing for the dark presets by
accident. Undoing an sRGB decode raises a dark value far more than a bright one, so `night`'s
`[amb] 0.2` goes from a shaded snow of about 45/255 to about 105/255 against the original's 47 —
the buggy path happened to mimic ETR's display-space arithmetic down there. No shipped course
selects a night or evening preset, so nothing regressed, but a preset is not tuned until it has
been fitted and none of the other seven has been.

Written 2026-09-08.

---

### 24. Two renderers, because one of them blends a shadow in sRGB

*2026-09-10.* Reported as "snow is still way too bright — the left snow-hill at Bumpy Ride, right
from the start". Measured on frame 30 of that course, the left bank read R 250 / G 255 / B 255 with
60 % / 97 % / 100 % of it clipped: a flat white sheet with no texture left in it. The right bank,
turned away from the sun, read 188 / 211 / 253 and was fine. So it was the *sun* term, and it was
not a level — the bank had no form at all.

#### What it was

Zeroing each energy in turn and rendering the full frame gave, in linear red over the same region:

| | linear R |
|---|---|
| ambient only (sun energy 0) | 0.4815 |
| sun only (ambient black) | 0.0624 |
| both, shadows **off** | 0.5441 — the sum |
| both, shadows **on** | 0.9622 |

(That table and the sweep below it are the first attempt's measurements, kept because they are
what identified the pass; everything from *the clamp* onward was re-measured against the split.)

`Sun.shadow_enabled` was worth +0.42 linear on a lit slope and nothing at all on a shaded one.
Nothing about the shadow *map* explains that, and the shadow mode did not matter — orthogonal, two
splits, four splits, blended or not, all measured identically. What pinned it was replacing the
whole of `light()` with `DIFFUSE_LIGHT += vec3(c)` and sweeping `c`: the extra term came back as
**`srgb(c · albedo)` added to `srgb(ambient)`**, predicted 0.0519 / 0.0876 / 0.2237 in display for
c = 0.005 / 0.01 / 0.05 against 0.0514 / 0.0875 / 0.2232 measured.

**In the Compatibility renderer a light that casts shadows is drawn in a second, additive pass, and
that pass is blended in sRGB space rather than linear.** It is a deliberate engine trade-off
(godotengine/godot#77496, #90259) — a shadowed light has to be in a pass of its own so it cannot
flicker between the two blend spaces — and `use_hdr_2d` does not change it (0.9593 against 0.9622).
Two things follow. The sun lands five to ten times too bright, and worse, the sRGB curve *crushes
its N·L gradient*: srgb is steepest near zero, so a dim sun term arrives compressed into the top of
the range and every slope facing the sun ends up at the same value. That is the flat white bank.

It also explains §11's methodology note, which observed the symptom and drew the wrong conclusion
from it. "Rendering with the sun at zero and again with the ambient at zero gives two frames whose
values do not sum to the full frame — the full frame is roughly twice their sum" is exactly this:
setting the sun's energy to zero culls the light, which removes the additive pass, which removes the
sRGB blend. The sum was fine. The full frame was wrong. §11 and §22 then fitted `sun_gain` against
the distorted path and got 0.103 — an order of magnitude under what a linear pipeline wants, and
correct only on the one frame it was solved on.

#### The first answer, and why it was not kept

The first pass at this took the fix that stays inside one renderer: turn `shadow_enabled` off,
which puts the sun back in the base pass, and replace the engine's shadow map with one the terrain
shader applies itself — a coverage mask baked from the trees at course load, plus an analytic
ellipse per racer, both multiplied into the sun term inside `light()` where the clamp still holds.
It worked, and it was rejected as the answer to the wrong question. (It is
`git stash` entry *"lightning experiment"* on `perf-and-structure-pass`, and the diagnosis section
above is its measurements, carried forward. Two unrelated things are still in there and were
**not** brought over: exponential height fog driven by a migrated `[fogheight]`, and a skybox
whose ground direction goes to the fog colour rather than to the front face's nadir average.
Neither has anything to do with shadows and both are worth a second look on their own.) The whole apparatus exists to route around a blend space. Two hundred and
ninety lines of `CourseShadows`, a second `SubViewport` with a world of its own, a shader whose
only job is to lay a tree flat along the sun ray — none of it is about how this game should look,
and all of it would have to be maintained forever on both targets.

**The renderer was the variable nobody had moved.** `project.godot` had said `gl_compatibility`
since the first commit, on the entirely reasonable ground that the web build has no choice — and
the desktop build had been quietly inheriting the browser's constraint for five phases. Godot's
Mobile renderer has one light loop, in linear, with the shadow arriving as `ATTENUATION` inside it.
That is not a workaround for the bug; it is the absence of the bug.

So: `rendering_method` is `mobile`, `rendering_method.web` is `gl_compatibility`, and
`RenderBackend` is the seam. It asks `RenderingServer.get_rendering_device()` rather than reading
the project setting, because the setting is a per-platform override with a `--rendering-method` on
top of it and neither is visible from its value — a desktop run passing `gl_compatibility`, which
is how the web look gets checked without a browser, has to answer the same as the browser does.

#### The clamp, which the split made necessary and the split made cheap

Removing the sRGB pass does not fix the report on its own. It cannot: ETR computes
`texture × clamp(ambient + sun·N·L, 0, 1)`, so a fully sunlit slope reads exactly its texture —
(236, 245, 255) for `snow.png` — with all of it intact. Multiplying first and clamping the product,
which is what a PBR renderer does, sends anything past `illum > 1/albedo` to flat 255 white, and no
choice of gain avoids that. Measured, with the pipeline linear:

| `sun_gain` | Bunny Hill lit near field | Bumpy Ride left bank |
|---|---|---|
| (1.05, 0.78, 1.05) | 239.1 / 247.2 — matches the reference exactly | 254.0 / 255.0, 85 % clipped |
| (0.60, 0.45, 0.60) | 219.4 / 233.4 — 20 levels dark | 236.4 / 246.4, 6 % clipped |

The two courses wanted gains a factor of 1.75 apart, which is the shape of a missing clamp and not
of a constant that needs nudging. `shaders/etr_illumination.gdshaderinc` is that clamp, and every
lit shader includes it: the terrain and both object shaders, each `ambient_light_disabled` and
each taking the ambient as `etr_ambient` instead, so that the two terms can meet inside `light()`
where the engine's ambient cannot reach them.

Putting it in a shared include rather than in `terrain.gdshader` was not tidiness. For one
afternoon only the terrain had it, and the sun that the terrain's clamp was holding at the ceiling
went straight into the forest instead: ETR clamps a tree exactly as it clamps a slope, because
`DrawTrees` goes through the same fixed-function pipeline as everything else.

#### What the clamp bought

`sun_gain` stopped being a fit. ETR saturates red at `0.2 + 0.45 + 1.0·ndl >= 1`, i.e. `ndl = 0.35`,
where the half-Lambert `shaped` is 0.210 — so `sun = (1 − 0.591) / 0.210 = 1.95` puts the ceiling at
the same angle, and green crosses within 5 % of that at the same number. One scalar on the migrated
`[diff]`, derived rather than solved. The three-numbers-per-end argument from §22 was always an
argument about a per-channel *clamp*; with the clamp where ETR puts it, only the shaded end still
needs three, and `ambient_gain` is §22's verbatim — a shaded fragment is ambient only, the ambient
was always in the base pass, and that end of the fit was never distorted.

| Bunny Hill, lit near field | ETR 0.8.4 | before (Compat + shadows) | after, Mobile | after, Compat |
|---|---|---|---|---|
| R | 239.2 | 238.3 | **234.9** | **235.5** |
| G | 247.1 | 251.4 | **244.3** | **245.0** |
| G clipped | 3.5 % | 53.2 % | **2.9 %** | **7.2 %** |

Bumpy Ride's left bank — the report — goes from 251.0 R with 60 % clipped to 233.4 with 1.2 %.
§22's closing note, "our lit region's upper half still runs about six levels over ETR's, and
closing it wants a reference captured at a matched camera", is answered: it was not the camera, it
was the clamp.

The two renderers now agree to within a level on snow, which is the property that matters more
than any of the numbers above — it means one fit serves both targets, and that a look tuned on the
desktop is the look the browser gets, minus the shadows.

#### The second bug, found on the way out

With the sun back in the base pass and the gain re-solved, the lit near field came out 19 levels
under the reference. `DIFFUSE_LIGHT += vec3(0.5)` over a surface of albedo 0.5 came back as
**0.25**: Godot multiplies the accumulated diffuse light by `ALBEDO` once, after the light loop.
The shader had been writing `DIFFUSE_LIGHT += ALBEDO * ...` on top of that and squaring it. On snow
that is a 16 % darkening of the sun term and nothing at all to the ambient — which took the
engine's single multiply — so it produced a perfectly plausible frame and was absorbed into
`sun_gain` along with everything else.

#### The third, found while checking the ice

The same constant sweep against the two renderers turned up a channel that does *not* agree.
`EMISSION = vec3(0.5)` reads back as 0.500 linear under Mobile and 0.216 under Compatibility, which
is `srgb_to_linear(0.5)` to three places. `DIFFUSE_LIGHT` and `SPECULAR_LIGHT` have no such split,
and neither does an `ALBEDO` that arrived through a `source_color` sampler — which is why the
terrain matched between renderers all along and the ice did not. The ice's Fresnel sky reflection,
with the mirrored racers composited into it, was the one term in the game going through `EMISSION`:
`tuxway` mid-lake measured 176.6 R on the desktop and 151.9 in the browser, and the reflected
penguin was half as visible there. Moving it to `SPECULAR_LIGHT`, added in `light()` and attenuated
by nothing, leaves Mobile bit-identical and takes Compatibility to 160.5. Sixteen levels are still
unaccounted for somewhere else in the ice branch and are in the known gaps.

#### The shadow, once there was a renderer that could draw one

Godot's directional defaults are `shadow_bias` 0.1 and `shadow_normal_bias` **2.0**, and a normal
bias is world metres along the surface normal. Two of them, on a penguin 0.6 m across, erase his
shadow completely — which is what "the racer casts nothing" was, with the shadow map containing him
the entire time. Rendering `vec3(ATTENUATION)` straight out of the terrain shader is what showed
it: the trees, the start banner and the hill were all in there, and the penguin was a blob three
pixels wide. 0.4 and 0.03 put it back with no acne on the snow, which is the surface that would
show acne first — a near-white Lambertian sheet at a grazing angle is the worst case for both
biases at once.

The three gates on `shadow_enabled` are not defensive programming; two of them are migrated.
`CCharShape::DrawShadow` opens with `if (light_id == 1 || light_id == 3) return;` — no shadow under
a cloudy or a night sky — and it is drawn at all only above `param.perf_level > 2`. Those are
`EnvironmentPreset.casts_shadows` and `GameConfig.shadows`. The third is `RenderBackend`, and
`race.tscn` ships `shadow_enabled = false` because a scene file cannot ask which renderer it is
about to be loaded into.

#### Methodology

**A term that only appears when two others are both non-zero is a pass-structure problem, not a
shading one.** Ambient alone was right, sun alone was right, and together they were nearly double.
No compositing model does that, so the thing to question was not the arithmetic in the shader but
how many times the renderer was running it — which is what the constant-in-`light()` sweep answered
in one render each.

**Sweep the constant, do not reason about the formula.** All three bugs here were found by writing
a number into a shader output that could not be confused with anything else and reading what came
out: `vec3(c)` for the pass structure, `vec3(0.5)` for the albedo multiply, the same against both
renderers for `EMISSION`. All three had survived being reasoned about for at least a phase. The
counterpart warning is in the same technique: a constant written to `ALBEDO` does *not* read back
the way a sampled albedo does, so the sweep answers questions about the pipeline and not about the
material.

**Correct §11's note rather than leaving it.** "Do not tune by turning one light off" was a real
instruction derived from a real measurement, and it was a bug report the whole time. A methodology
note that says "the renderer evidently does something we do not understand here" is a lead, not a
rule.

**Check which variable you have been treating as fixed.** The renderer had been `gl_compatibility`
since the first commit for a reason that only ever applied to one of the two targets, and five
phases of rendering work were spent inside that constraint without anyone writing down that it was
a choice. The trap-list entry that came out of the first attempt — "a shadowed light under
Compatibility blends in sRGB, so no shader can reach it" — was true, complete, and pointed at a
workaround because the sentence stopped one word short of "under Compatibility, *which is only the
web build*".

Written 2026-09-10.
