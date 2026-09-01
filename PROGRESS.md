# PenguinRacer — build progress

Companion to [`godot-port-plan.md`](./godot-port-plan.md). Records what exists, what the
de-risking spikes actually returned, and what the plan got wrong.

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

Four things turned up during implementation that change the plan's own §1 constraint table.

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
  looks a terrain up by name, so it keeps all three; the importer keys layer resources by name
  and the last record wins — which means two of those colour keys have been getting the wrong
  texture and friction since Phase 1. Left as it is, because disambiguating the names
  re-identifies every course's splat layers, but the importer now warns instead of collapsing
  them silently.
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
- **The test runner had to move off `_initialize`.** The tree's root Window is not yet inside the
  tree when a `SceneTree` script's `_initialize` runs, and an `AudioStreamPlayer` refuses to start
  outside one. Everything now runs on the first `_process` instead. The physics suite does not
  care; anything node-shaped added later will.

Ported 2026-09-01. 100 assertions cover the bank, the themes, the volume arithmetic, the
terrain → cue mapping and the three mixer behaviours above. Traced through a real run, a carve
down Frozen River moves snow → `ice_sound` → snow and drops the loop while airborne; the same
carve down Bunny Hill is silent from top to bottom, because Bunny Hill is snow.

## Built

### Phase 0 — physics core · **done**

`game/scripts/physics/` — `RacePhysics` is a plain `RefCounted` with zero node dependencies,
stepped against a `SurfaceProvider`. Every force from etracer.md §4.1 is ported: gravity, the
piecewise spring normal force, jump, steering-rotated friction, brake, Reynolds-table air drag,
paddle, and the roll normal. ODE23 (Bogacki–Shampine) with adaptive stepping, retry and the
`MAX_STEP_DIST` cap. Trees and herring go through a uniform spatial grid, fixing the original's
O(items) scan per substep.

**2293 assertions, 0 failures**, in 0.8 s headless. Per-force golden values are worked out by
hand from the constants — air drag at 20 m/s, each of the three spring bands, the 400 N lateral
friction cap, the 30°/55° bank angles, the paddle's fade to nothing at 60 km/h — so a change in
feel shows up as a test failure rather than as a vague complaint. Whole-simulation tests cover
terrain following, steering symmetry, bounds (including the new polygon play area), items,
trees, the finish, determinism under a replayed input trace, and stability at 10 fps.

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

`bunny_hill` is drivable end to end with chunked terrain, splat-blended PBR, instanced trees,
herring pickups, the chase camera and a HUD — **including in a browser**. The Phase 1 exit
criterion is met: a `WebOneCourse` export loads and runs bunny_hill under Chromium/WebGL2,
streaming 21 terrain chunks, on a 6.6 MB pck. Long courses work too — `wild_mountains`
(100×1000) runs, and the per-course pck size is the shape Phase 6's streaming needs.

### Phase 3 — snow · **mechanism proven, integration partial**

Both halves of the dual representation exist and are wired in:

- `SnowFieldGPU` — ping-pong `SubViewport`s, 1024² over a 64 m toroidally-scrolled window,
  stamped and decayed by one fragment pass per frame. Verified by S1.
- `SnowField` — the CPU mirror, 128² over the same window, read by `HeightmapSurface.sample()`.

The terrain shader displaces from the trail map, raises ridges at the trench lip from the
Laplacian of the depth field, and reconstructs normals from it. A carve leaves a visible track
down the slope in the running game — since §12, one with a self-occluded floor and a brighter
ploughed lip as well as a shaded wall.

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

---

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
  matches the original at both ends of its range (§11, still true after §12), but the fit is two
  scalars solved on two surfaces in one screenshot. The other seven environments — the three `etr` skyboxes are 1024²
  and much brighter, and `night` and `evening` invert the balance between sun and ambient — have
  not been compared against anything. Same method, one reference capture each.
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
  ships commented out (§16), and 12 of the 43 terrains — `snow` among them — name no sound at
  all. Both are faithful and both are the obvious first thing to improve; the mapping is one
  `StringName` per terrain resource and the volume is one call in `RaceScene`.
- **Web cold load gains 18 MB of audio** on top of the 161 MB, and music is the easiest part of
  the pack to stream rather than bundle — 14 MB of it, none needed before the first frame.
- **Heightmap dequantization has not been eyeballed per course** (risk S3). The pipeline runs on
  all 44; three courses of differing character should be compared against original screenshots.
- **The snow and ice shading terms are tuned by eye, not against a reference.** Unlike the tone
  fit, §12's relief amplitudes, glint sharpness and ice albedo have no measured target — the
  original has no equivalent to measure against. They are all uniforms with the neutral value
  documented, so backing any of them out is a one-line change.
- **`wind_direction` is a shader constant, not course data.** Every course's sastrugi run the same
  way. It wants to come off the environment preset, or at least be seeded per course.
- **Asset licence audit not started** (risk S5). Independent of engineering, long lead time,
  blocks Phase 5.
