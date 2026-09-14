# PenguinRacer — Godot Port/Rebuild Plan

Companion to [`etracer.md`](./etracer.md) (source analysis of Extreme Tux Racer 0.8.4).
Written 2026-08-30.

**Mandate:** re-create the ETR game *idea* in Godot with modern visuals and real snow simulation.
Rescue what is genuinely valuable from the original; do not carry over its structural weaknesses.
Every legacy data format gets a replacement designed for the next decade plus a mechanical
migration path.

**This is a rebuild, not a port.** The only thing translated line-for-line is the physics model.
Everything else is redesigned and the old content is imported into the new shape.

---

## 1. Hard platform constraints

These are not preferences; they determine the architecture. All verified against Godot 4.7 (mid-2026).

| Constraint | Consequence |
|---|---|
| Web export requires the **Compatibility** renderer (WebGL2) | No compute shaders, no `RenderingDevice`, no HDR (`RGBA8` only), no decals, no volumetric fog, no SSR/SSIL, no SDFGI/VoxelGI, no SSS, no TAA/FSR2. **Do have:** PBR, shadows, SSAO, LightmapGI, depth+height fog, glow/tonemap, MSAA, GPUParticles (minus trails and SDF collision), screen+depth textures. |
| **C# web export is not supported** ([#70796](https://github.com/godotengine/godot/issues/70796), still prototype as of late 2025) | Gameplay code is **GDScript**. C# is not an escape hatch for performance. |
| GDExtension on web works but is fragile (thread-mode must match, weaker on Firefox) | Treat GDExtension as a *contingency* for the physics inner loop, not the default. Avoid GDExtension-based third-party addons. |
| No compute → GPU simulation must use **ping-pong render targets** | The snow deformation field is fragment-shader driven via `SubViewport`s. Standard pre-compute technique; ports forward to compute cleanly if Godot gains WebGPU. |
| GPU→CPU readback stalls the browser | Physics must **never** read the GPU trail map. Keep a low-res CPU mirror (§4.3). |
| **Compatibility cannot manually emit particles** (`GPUParticles3D.emit_particle` is a `RenderingDevice` path) — *found during implementation* | ETR's `generate_particles` cannot be ported as "spawn N particles with these velocities". Drive **rate-based emitters** instead: the per-frame count becomes `amount_ratio`, the spray velocity becomes the emitter direction (§4.4). |

**Implementation note added 2026-08-31:** `set_shader_parameter` with a packed array keeps a
reference to the caller's array — clearing it afterwards clears what the shader reads. This is
how the deformation field silently came out empty on the first pass at S1.

**Design rule that follows:** no system may depend on a feature Compatibility lacks. Where a
Forward+/WebGPU future would improve a system, isolate that system behind an interface so it can be
upgraded without touching callers.

**Correction, 2026-09-10 — the rule was right, its scope was not.** "Web export requires the
Compatibility renderer" is a constraint on the *web* export, and this plan quietly let it become a
constraint on the project: `project.godot` shipped `rendering_method = "gl_compatibility"` with no
per-platform override, so the desktop build spent five phases inside the browser's limits for no
reason anyone had written down. The table row above also overstates one entry — "**Do have:**
PBR, **shadows**, …" is true only in the sense that the renderer will draw them. Under
Compatibility a shadow-casting light is moved into a second, additive pass that is blended in
**sRGB** rather than linear (godotengine/godot#77496, #90259), so the sun arrives five to ten
times too bright with its N·L gradient crushed flat, and no shader or gain can reach a framebuffer
blend. Shadows are on the "do have" list and are not usable there.

The project now ships **Mobile on the desktop and Compatibility on the web**, and the rule reads:
nothing may *depend* on a feature Compatibility lacks, but a desktop build may **add** one behind
a gate as long as the web frame without it is still worth shipping. `RenderBackend` is the gate
and `Sun.shadow_enabled` is the only thing through it so far. See history §24.

---

## 2. What we rescue vs. discard

| From ETR | Decision | Why |
|---|---|---|
| **Physics model + constants** (`physics.cpp`) | **Rescue, port faithfully** | The game *is* these numbers. See `etracer.md` §4.1. |
| **Barycentric terrain-blended friction** | **Rescue as a concept** | Smooth friction across terrain boundaries; reimplement on the new splat weights. |
| **Camera lag model** (`view.cpp`) | **Rescue as a concept** | Quaternion interp, τ=0.06 s, disabled <2 m/s, ramped in by 4.5 m/s. Subtle and good. |
| **Particle emission logic** (`generate_particles`) | **Rescue as a concept** | Asymmetric left/right spray keyed to carve direction — the signature visual. |
| **45 course layouts** | **Rescue as content** | Real level design by many authors. Migrate, then re-polish in-editor. |
| **Terrain table** (45 types, friction/depth) | **Rescue as data** | Tuned balance data. |
| **Cup/race thresholds** (`events.lst`) | **Rescue as data** | Tuned difficulty curve — expensive to recreate. |
| **15 translations** | **Rescue as data** | Free content. |
| **Music + SFX** | **Rescue pending licence audit** | Named artists; see `data/credits.lst`. |
| Quadtree CLOD terrain (`quadtree.cpp`, 1146 ln) | **Discard** | Obsolete; its own header documents its flaws. |
| Fixed-function GL, SFML | **Discard** | Replaced by Godot. |
| **PNG-encoded course data** | **Discard format, migrate content** | §3 — the centrepiece of this plan. |
| SP list text format (`spx.cpp`) | **Discard** | Replaced by Godot `Resource`s. |
| Ellipsoid character model (`tux.cpp`) | **Discard, auto-convert as placeholder** | §3.4. |
| Global singletons, state machine, GUI | **Discard** | Replaced by Godot scenes/autoloads/Control. |
| `trees.png` → `items.lst` runtime conversion | **Discard** | Import-time only; never write to the data dir at runtime. |
| Finish sequence (gravity override to 500 N) | **Discard, redesign** | A hack. |
| `perf_level` integer feature gates | **Discard** | Replace with measured quality tiers. |

---

## 3. New data model

### 3.1 Why the PNG course format has to go

Concrete defects, each with a direct fix:

| Defect | Impact | Fix |
|---|---|---|
| **8-bit elevation** over `scale` 7–10 m | 2.7–3.9 cm quantization → visible terracing; the original masks it with normal smoothing | **float32 heightmap** |
| Heightmap resolution == terrain-type resolution == object placement grid | Everything locked to ~1 m; objects snap to grid | **Three decoupled resolutions** |
| Terrain type = RGB colour-key matched within ±30 | Silent collisions between types; hard per-vertex index; blending only *derived*, never authored | **Authored splat weight maps** |
| Objects = colour-keyed pixels, 8 legacy colours | No rotation, no per-instance scale, grid-snapped, hard type limit | **Real scene nodes** |
| Course is always an axis-aligned rectangle running −Z, play area a sub-rectangle | No branching routes, no alternate lines | **Play bounds as a polygon/curve** |
| Heightmap is the *only* surface | No overhangs, tunnels, bridges, rails, jumps as geometry | **Heightmap = base layer; extra meshes allowed** |
| No per-course metadata beyond `course.dim` | — | **Typed `Resource`** |

### 3.2 Course format v2

A course is a **Godot scene** (`.tscn`) plus a **`CourseData` resource** (`.tres`) plus binary assets.

```
courses/bunny_hill/
  course.tscn          # scene: terrain node, objects, markers, extra geometry
  course.tres          # CourseData resource
  heightmap.res        # Image, FORMAT_RF (float32)
  splat_0.png          # RGBA8 = terrain layers 0-3 weights
  splat_1.png          # RGBA8 = terrain layers 4-7 weights (optional)
  preview.png
```

```gdscript
class_name CourseData extends Resource

@export var display_name: String            # translation key
@export var author: String
@export var description: String             # translation key

# terrain
@export var heightmap: Image                # FORMAT_RF, float32, local height only
@export var heightmap_size: Vector2i        # texels
@export var world_size: Vector2             # metres (width, length)
@export var height_scale: float             # metres, local relief
@export var base_angle: float               # degrees; global downhill slope, applied ANALYTICALLY
@export var splat_maps: Array[Texture2D]    # 4 layer weights each
@export var terrain_layers: Array[TerrainLayer]   # max 8

# gameplay
@export var start_transform: Transform3D
@export var finish_line_z: float
@export var play_bounds: Curve2D            # was: a rectangle
@export var environment_preset: EnvironmentPreset
@export var music_theme: StringName
@export var finish_brake: float
```

**Keep `base_angle` analytic.** The original bakes the global slope into every elevation sample.
Storing only *local relief* in the heightmap and adding `-tan(base_angle) * z` at query time means
(a) the float32 range is used for detail rather than a 500 m ramp, (b) long courses stay precise,
(c) the slope can be edited without touching the heightmap.

**Terrain layers cap at 8 per course** (2 RGBA splat textures). Surveyed courses use 3–8 distinct
terrain types, so this is not binding in practice; the importer warns and merges least-used layers
if a course exceeds it. This also fixes the original's worst performance bug — ETR re-rendered the
terrain once per terrain type present.

```gdscript
class_name TerrainLayer extends Resource

@export var id: StringName
# gameplay (migrated verbatim from terrains.lst)
@export var friction: float                 # 0.2 ice .. 0.7 rock
@export var compression_depth: float        # 0.01 .. 0.11 m
@export var emits_particles: bool
@export var takes_trackmarks: bool
@export var footstep_sound: AudioStream
# rendering (new — old data is diffuse-only)
@export var albedo: Texture2D
@export var normal: Texture2D
@export var roughness: Texture2D
@export var uv_scale: float = 6.0           # ETR used 1/6 world units
@export var is_deformable: bool             # snow yes, rock no
```

**Correction, 2026-09-01.** Four fields of that sketch did not survive contact with the data or
with the renderer.
`footstep_sound` is a `slide_sound: StringName` resolved against a global `SoundBank`, because
`terrains.lst` names a cue exactly as `TerrList[i].sound` does and holding the stream here would
pull 4 MB of shared effects into all 44 course packs. And `id` is **the record, not the
`[name]`**: the file declares `pave04` three times with three textures and three colour keys,
which is legal because the original identifies a terrain by the colour a course paints and
`TTerrType` has no name field at all. One resource per name kept only the last of the three.
Layers are keyed per record, a repeated name is disambiguated by its texture stem, and
`legacy_name`/`legacy_index`/`legacy_color` point back at the source row. See history §17.

`normal` and `roughness` are gone as textures. The terrain shader already binds 13 of WebGL2's
guaranteed 16 fragment texture units — two splat maps, eight albedos, the trail map, the detail
map and the sparkle noise — so eight more of either does not fit under Compatibility, and both
had sat there for two phases as exports nothing sampled. `roughness` came back as a per-layer
float, which the shader's existing `layer_roughness` table can carry for free; relief comes from
the shared procedural detail field instead of per-layer normal maps. `uv_scale` was declared per
layer and uploaded as a single uniform from `terrain_layers[0]`, so every other layer silently
inherited layer 0's tiling — it is a table now too. See materials.md.

### 3.3 Objects as scene nodes

Trees and items become real `Node3D`s in `course.tscn`, instanced from prefabs. Gains: arbitrary
position (no grid snap), rotation, per-instance scale, prefab variants, and editor placement.
Rendering uses `MultiMeshInstance3D` batches built at load from the node transforms — so authoring
is per-instance but drawing is instanced.

Collision proxies stay simple and explicit (radius + height per prefab), matching ETR's cheap
cylinder-ish test rather than dragging in Godot's physics server for something we can do in ten lines.

### 3.4 Character

The ellipsoid hierarchy is discarded, but the importer **auto-generates a placeholder mesh** from
`shape.lst` — each node becomes a scaled UV sphere, welded into one `ArrayMesh` — plus a `Skeleton3D`
built from the named joints (`neck`, `head`, `left_shldr`, `left_hip`, `left_knee`, …).

This is the useful trick: **you have a recognisable, animating Tux on day one**, and when authored
skinned glTF art arrives later it drops in against the *same joint names*, so the procedural
animation layer and the migrated keyframe animations keep working unchanged.

`start/finish/wonrace/lostrace.lst` → Godot `Animation` resources on those joint names.

**Correction, 2026-09-02.** Two things this section takes for granted are not free, and both were
found by trying to play the start animation:

- "Placeholder mesh **plus** a `Skeleton3D`" has to be *skinned* to it, with bone indices and
  weights on the vertices and a `Skin` on the `MeshInstance3D`. Without that the joint names are
  right, the bones pose correctly, and nothing moves. Each sphere binds rigidly to the nearest
  joint above it, which is exact rather than approximate: in the original a sphere is a leaf under
  one chain of matrices.
- **A keyframe animation is not all animation.** `CKeyframe::Update` moves the body as well as the
  joints, and neither half of that fits an `Animation` track: the authored Y is a clearance above
  the terrain that `Course.FindYCoord` completes at runtime, and the yaw/pitch/roll goes to node 0,
  whose frame is the world. The joints migrate to the `AnimationLibrary`; the root motion migrates
  to a `KeyframePath` resource on the rig, sampled by whoever owns the clock.

The generated scene is therefore a `CharacterRig` (below) rather than a bare `Node3D`, and it is
that script — not just the joint names — that authored art has to keep.

**Addition, 2026-09-02.** This section says "Tux" throughout and the data says five: `characters.lst`
names Tux, Trixi, Boris, Samuel and Beastie, and each `[dir]` has its own `shape.lst` and its own
four keyframe lists. The importer already built all five; what was missing was any way to pick one.
`resources/characters.tres` is that index — a `CharacterCatalog` written at import time for the
same reason `resources/courses.tres` is, because `DirAccess` over `res://` finds nothing in an
exported build — and `GameConfig.character` names a row of it. Do not assume a joint list is
shared: four of the five spell the left elbow `[joint] joint` and Samuel has no right leg, and the
original's `RotateNode` skips a name it cannot find rather than failing.

---

## 4. Runtime architecture

### 4.1 Layering

```
Game shell (menus, cups, scoring, i18n)      ← Godot Control scenes
Race scene                                   fixed 60 Hz tick, interpolated presentation
  ├── Racer[]            everyone on the hill; the presentation reads RacerState and
  │   │                  cannot tell which kind filled it
  │   ├── SimulatedRacer RacePhysics + InputSource + SprayEmitter + snow stamps
  │   │                  → the local player; an AI opponent is a different InputSource
  │   └── PlaybackRacer  RacerStateStream, read by time
  │                      → a ghost, and a network peer
  ├── SurfaceProvider    (interface)  ← HeightmapSurface  [← CompositeSurface later]
  ├── SnowField          (CPU deformation mirror)
  ├── TerrainRenderer    (chunked ArrayMesh + splat/displacement shader)
  ├── SnowFieldGPU       (ping-pong SubViewports → trail map texture)
  ├── ChaseCamera
  └── CourseRoot         (heightmap, object grids, MultiMesh batches)

RacePhysics              (GDScript, headless-testable, no node deps) — one per SimulatedRacer
CharacterRig             (skinned skeleton, canned keyframes, the racing pose layer)
                         — one under each Racer
Net / RaceNetwork        (autoload) ENet session; snapshots in and out of PlaybackRacers
```

`RacePhysics` must have **zero node dependencies** — plain `RefCounted` operating on a
`SurfaceProvider`. That is what makes headless parity testing (§6, Phase 0) possible, and it is the
main structural improvement over ETR's `CControl`, which reached into six globals.

> **Correction, 2026-09-02.** The race scene held *the* player until the multiplayer foundation
> was built; it now holds a list of racers, and `RacePhysics` is one per simulated racer rather
> than one per scene. Nothing about the zero-node rule changed — it is what made a second
> simulation free — but §4.1 as originally drawn put the physics, the rig and the spray directly
> under the race scene, and they hang off a racer now. See §4.6.

### 4.2 Surface queries

```gdscript
class_name SurfaceSample
var height: float
var normal: Vector3
var friction: float            # blended across splat weights
var compression_depth: float   # blended
var terrain_id: int            # dominant, for sound/particles
```

`HeightmapSurface.sample(x, z)` does bilinear height + analytic slope, splat-weighted friction and
depth blending (ETR's barycentric blend generalised to the splat maps), and analytic normals from
height derivatives. `CompositeSurface` — raycasting extra geometry on top of the heightmap — is a
later addition the interface already allows.

Port ETR's `FindYCoord` caching idea but as an owned field, not a function-static.

**Fix ETR's O(n) item scan:** items go into a uniform spatial grid bucketed by Z. The original
scanned every item on the course on every ODE substep.

### 4.3 Snow deformation — the dual-representation design

The key decision. **Two representations, deliberately different resolutions, never synced by readback.**

**GPU side (visual)** — `SnowFieldGPU`
- Ping-pong pair of `SubViewport`s, `RGBAH` or `RGBA8`, 1024², covering a 64 m window
  (≈6.25 cm/texel) that follows the player with **toroidal scrolling** (wrap addressing, only the
  newly-exposed edge is cleared).
- Channels: `R` = trench depth, `G` = compaction, `B` = age/refill, `A` = spare (wind drift).
- Each frame a stamp pass draws the player's contact footprint (plus tree/object impacts) additively;
  a decay pass slowly refills.
- The terrain vertex shader samples it and displaces snow down in the trench and **up into ridges at
  the trench edges** (the ridge is what sells a carve). Normals recomputed from the trail map in the
  fragment shader.

**CPU side (gameplay)** — `SnowField`
- A plain `PackedFloat32Array`, 128² over the same 64 m window (50 cm/texel), stamped by the *same
  footprint logic* in GDScript.
- Read by `HeightmapSurface.sample()` to change `friction` and `compression_depth` where snow is
  already packed. **Correction, 2026-08-31:** this bullet originally said "raise friction", which
  contradicts the next paragraph. Friction here directly scales the retarding force (ice 0.2 fast
  .. rock 0.7 slow), so "packed snow is faster" means friction goes **down** in the trench. The
  implementation lowers it, and exports both coefficients so the call can be redone by feel.

They intentionally do not match exactly. The GPU one is for pixels; the CPU one is for feel. This
avoids readback stalls entirely and is cheap — a few dozen texel writes per frame.

**Closing the loop between visuals and gameplay is the thing ETR never did.** Packed snow is faster
than fresh powder, so racing lines start to matter and a second lap down the same trench plays
differently. This is the single biggest *design* upgrade available, not just a graphical one.

**Track marks are deleted as a separate system.** ETR's 10 000-quad decal ring buffer is subsumed by
the deformation field, which is strictly better — it's geometry, it's persistent, and it feeds physics.

**Migration note for a WebGPU future:** the stamp/decay passes become compute dispatches, and the CPU
mirror could be dropped in favour of a compute-side readback buffer. Nothing above it changes.

### 4.4 Terrain rendering

Chunked `ArrayMesh` (~64×64 vertices per chunk), frustum-culled, with a custom shader doing splat
blending + trail-map displacement + normal reconstruction.

Long courses are fine despite appearances: `the_long_ride` is 80×4000, upsampled ×2 → 160×8000
≈ 1.28 M vertices total, but fog culls to ~70–150 m, so the *visible* slice is roughly
160×300 ≈ 48 k vertices. Chunk streaming keeps memory flat. Distant chunks get a static LOD;
only chunks inside the deformation window need the displacement path.

### 4.5 Visual target

One `DirectionalLight3D` (sun) + baked `LightmapGI` (courses are static — bake on desktop, ship the
lightmap; this is the main compensation for no SDFGI) + SSAO + depth/height fog + glow.

Snow shading: wrap/half-Lambert diffuse to fake subsurface scattering, a view-dependent sparkle term
from a noise texture, and careful in-shader tonemapping to fight the `RGBA8` LDR ceiling. Sky from
`PhysicalSkyMaterial` or the migrated ETR skyboxes as panoramas.

**Corrected 2026-09-01.** Three things in this paragraph were wrong once it met the original:

- **SSAO and glow are off.** ETR has neither, and both work against the target — glow smears the
  clipped highlights snow is mostly made of, and SSAO is a Forward+ pass Compatibility does not
  run anyway. The tone mapper is `TONE_MAPPER_LINEAR`, not a filmic curve: the original clamps in
  display space, so a curve that redistributes the ends is a mismatch, not a refinement.
- **"In-shader tonemapping to fight the LDR ceiling" was the wrong goal.** ETR clips its lit snow
  to white; the near field is *meant* to sit in a narrow band just under the ceiling. What had to
  be fixed was everything pushing it past the ceiling — terrain `SPECULAR` at Godot's 0.5 default
  above all — not the ceiling itself.
- **The skyboxes are not panoramas.** Three flat cube faces (front/left/right); top, bottom and
  back do not exist in the data. `shaders/etr_skybox.gdshader` samples the cube directly. See
  history.md §10.

The fog range in §4.3 is the original's 75 m, not a stretched version of it: ETR's white haze is
load-bearing for how its snow reads, and the skybox is what sits behind it.

**Correction, 2026-09-08:** `EnvironmentPreset` no longer carries `sun_energy`/`ambient_energy`
as scalars. `light.lst`'s `[diff]` and `[amb]` are display-space multipliers and Godot
sRGB-decodes anything handed to it as a light colour, which bends the channel balance rather than
scaling it; and ETR clamps per channel, which a scalar cannot reproduce on a texture whose blue is
already at the ceiling. The migrated colours stay verbatim in `sun_color`/`ambient_color`; the
fitted correction is `sun_gain`/`ambient_gain`, a `Color` each, applied through
`EnvironmentPreset.as_light_color` for both the ambient and the sun. history.md §22.

**Correction, 2026-09-10 — the heading is now "the visual target", and Compatibility is the floor
rather than the ceiling.** The desktop runs the Mobile renderer (§4.1's correction), so the
directional shadow ETR only ever had as a blob under the character is real there, gated three ways
and absent on the web. Two more things in the paragraph above have moved:

- **The shading order is the original's, not a PBR renderer's.** Every lit shader includes
  `shaders/etr_illumination.gdshaderinc` and computes `texture × clamp(ambient + sun·N·L, 0, 1)`,
  with the engine's ambient disabled so the two terms can be summed before the albedo multiply.
  Multiplying first and clamping the product — what §4.5 assumed all along — sends a slope to flat
  255 white past `illum > 1/albedo`, which on snow is about 1.2, and is why the same sun that fit
  Bunny Hill blew Bumpy Ride out.
- **`sun_gain` is no longer fitted.** With the clamp in ETR's place it is derived from where the
  original's own red saturates: one scalar, 1.95, on the migrated `[diff]`. `ambient_gain` is
  still three fitted numbers, because a shaded fragment is ambient only and its channels sit at
  different fractions of their own ceiling. history.md §24.
- **No `LightmapGI` bake**, and there is not going to be one — it is still listed at the top of
  this section. The courses are static, but nothing in the frame wants bounced light: ETR has one
  ambient constant and clamps.


**Correction, 2026-09-01:** the *shipped default* is now 40–150 m, stretched from the migrated
0–75 by the settings file rather than by the data. Six of the eight presets carry
`[fogstart] 0`, which puts haze on the trees a couple of lengths in front of the player; the
paragraph above is still right about what the haze does, and it survives at the horizon. The
difference from the stretch that was backed out earlier the same day is that this one is
measured — the near field the tone fit was solved on does not move — and that
`penguinracer.cfg` restores the data exactly in two lines. Fog distance and window/render
resolution are the file's whole contents so far; see `scripts/config/game_config.gd`.

Accept as out of scope under Compatibility: volumetric snowfall (use layered scrolling noise +
GPUParticles instead), SSR on ice, real HDR glare.

### 4.6 More than one racer — ghosts, AI and network play

Added 2026-09-02. §8.4 says redesign beyond the original is in scope and should be taken into
account in the initial design; this is the design. Three features — network play, AI opponents,
racing a recorded run — look like three features and are one, if the seam is picked right.

**The seam is `RacerState`**: time, position, orientation, velocity, progress, flags, herring, as
14 float32s. It is the only thing the presentation reads. A racer simulated here fills it from
`RacePhysics`; a ghost fills it from a recorded stream; a peer fills it from a packet. One
presentation path serves all three, and the same floats are the ghost file format and the wire
format, so the two never drift apart.

> **Corrected 2026-09-07.** 18 float32s, not 14. The procedural character layer needs four values
> a pose does not imply — the steering lean, the paddle and flap phases, and the net force along
> the body's own up axis — and the rule above is what decides where they live: if the
> presentation may read nothing but `RacerState`, then everything the presentation needs is in
> `RacerState`, including for a racer that has no simulation behind it. `RaceRecording.FORMAT_VERSION`
> went to 2 with it.

**Two kinds of racer, not four.** `SimulatedRacer` owns a `RacePhysics` fed by an `InputSource`;
`PlaybackRacer` owns a `RacerStateStream` read by time. The player and an AI opponent are the
first; a ghost and a remote peer are the second. What decides the split is whether the motion has
to be *derived* here or only *shown* here — and a remote peer is emphatically the second, which is
what keeps eight opponents at eight skinned meshes rather than eight ODE solvers.

**An AI is an `InputSource`, not a kind of racer.** `poll()` is handed the `RacePhysics`, which
owns the position, the velocity, the `SurfaceProvider` under the racer and the tree grid ahead of
it. Nothing else is needed and nothing is reserved for it.

> Built 2026-09-02, and the prediction held with one correction. `AIInputSource` needed nothing
> added to `InputSource`, `SimulatedRacer` or the presentation — but it did need one thing the
> `RacePhysics` genuinely does not contain: **where the other racers are.** A second penguin is a
> body being integrated somewhere else on the same tick, so it can only arrive from outside, and
> two opponents that both wanted the same herring converged on it and rode the rest of the course
> as one blurred penguin. `RaceScene` therefore publishes one `RacerField` each tick and hands it
> to each opponent. It is presentation-quality rather than correctness: an opponent will still
> drive through another to miss a tree.
>
> **Corrected 2026-09-03: racers collide.** The same field is now read by `RacePhysics` as well as
> by the planner, and a contact between two racers is resolved by each of them independently — the
> equal-mass impulse applied to yourself against the other's published state, so what one body is
> paid the other pays without either writing to the other or any authority arbitrating. See
> the network-model correction below; a ghost is excluded (`Racer.collides()`).
>
> The other correction is that a difficulty setting had nowhere obvious to live and should not
> live in the physics. `AISkill` is a table of driving habits — lookahead, reaction, nerve, paddle
> discipline, tree clearance, weave — and every racer stays the same 20 kg point mass under the
> same §4.1 forces, because `characters.lst` carries no per-character constants and neither does
> this. See PROGRESS.md for the table and the measured ladder.

**A fixed 60 Hz tick with interpolated presentation is the precondition for all of it.** A run has
to mean the same thing at 30 fps and at 144 or a ghost is not a fair opponent and two peers cannot
agree who finished first. Phase 0's determinism test already asserted the property at a fixed
step; this is what makes the game itself honour it. The phase of the interpolation is subtle — see
history §20.

**Recording is both poses and intent, deliberately.** Poses are what a ghost plays back: exact,
free to replay, and independent of the physics still being what it was — which matters because
this game runs on native libm and on WebAssembly's, and an input replay across the two would drift.
The intent trace is a fortieth of the size and is for anything that must re-derive a run: a
regression test, a run replayed against a changed force constant, an AI corpus. It carries a hash
of the force model so a stale trace refuses rather than lying.

**Network model: everyone simulates themselves, nobody simulates anybody else.** Each peer
broadcasts a snapshot 20 times a second and shows everyone else 150 ms behind the local clock. No
authority over positions, no rollback, no prediction. Legitimate here because the surface is
identical on every machine and the only shared mutable state is the herring.

> **Corrected 2026-09-03.** This section said the model was legitimate *because racers do not
> collide*, and that pushing each other would need it replaced rather than extended. That was too
> strong. Players do push each other now, and the model survived, because the contact is symmetric
> and each body applies it to itself (`RacePhysics._adjust_racer_collision`) — nothing has to be
> arbitrated and nothing is sent that was not already in the snapshot stream. What does not
> survive is *agreement*: each end resolves against the other as it was 150 ms ago, so a bump is
> felt slightly differently on the two machines. An authority is what buys exact agreement, and it
> is still not worth its price here.

**Transport is ENet and therefore desktop-only.** A browser has no UDP socket. WebRTC delivers the
same `MultiplayerAPI` with the same RPCs behind one factory function, and additionally needs a
signalling server — hosted infrastructure, not repository content. Web multiplayer is blocked on
that, not on the game code. This is the one place the "no system may depend on a feature
Compatibility lacks" rule (§4.1 rule 2) is knowingly bent: the feature degrades to absent in the
browser rather than breaking anything there.

Not designed here and deliberately left open: the lobby (who is racing what, and a countdown
everyone starts on), a finishing-order screen, and whether cups are ever raced together. A field
of computer opponents needs none of the three, which is why it shipped first — it starts when the
player presses Race!, everyone shares one clock, and the place goes on the panel that already
comes up after the line.

---

## 5. Asset migration pipeline

Built as a **Godot `EditorPlugin` with `@tool` scripts** — one click per course, re-runnable, lives
in the repo, no external toolchain. (Note: no Python in this container; a Godot tool script avoids
that dependency entirely.)

### 5.1 Per-course importer

1. **`elev.png` → float32 heightmap.** Decode with ETR's formula but **separate the two terms**:
   store only local relief `((px − 127)/255) × scale`; keep the slope analytic in `CourseData`.
2. **Dequantize.** Naive 8-bit→float32 preserves the terracing. Apply Catmull-Rom upsample ×2 plus a
   light edge-preserving smooth to reconstruct a plausible continuous surface. **This must be
   eyeballed per course, not trusted blindly** — it is the one lossy, judgement-dependent step in the
   pipeline.
3. **`terrain.png` → splat maps.** Match RGB against `terrains.lst` (±30, as the original), collect
   the distinct types actually used by *this* course, assign to ≤8 layers, write one-hot weights,
   then blur the boundaries to produce authored-quality blending. Warn + merge if >8.
   **Correction 2026-09-11:** *bilinearly resample* the one-hot field onto the target grid rather
   than taking the nearest sample, and map corner to corner — both the splat and the heightmap are
   vertex grids, and the even upsample factor puts half the target samples exactly between two
   source vertices, where nearest has to invent a tie-break. Interpolating is also what the
   original draws (`quadsquare::MakeTri`). And write the `.import` sidecar with the texture
   importer's sprite-oriented defaults off: `process/fix_alpha_border` treats layer 3's weight as
   transparency and rewrites the other three layers around it. See `materials.md` §1.2.
4. **`items.lst` → scene nodes.** Prefer `items.lst` over `trees.png` — it carries float `height`/`diam`
   the pixel map lacks. Positions are grid-snapped in the source; **preserve them exactly on import**
   (tree placement is gameplay), leave de-gridding to a designer in-editor.
5. **`course.dim` → `CourseData`**, including localized name/description. `play_width`/`play_length`
   become a rectangular `Curve2D` — correct on import, free to reshape later.
6. **`preview.png`** copied.

### 5.2 Global importers (run once)

| Source | Target |
|---|---|
| `terrains.lst` | One `TerrainLayer` resource **per record** (§3.2 correction); old diffuse PNGs wired as `albedo`, `roughness` seeded from `is_ice()` (§3.2 correction, 2026-09-01) |
| `object_types.lst` + object textures | Object prefab scenes (`.tscn`) |
| `events.lst` | `Race` / `Cup` / `EventSet` resources — **keep the herring/time thresholds verbatim** |
| `char/<name>/shape.lst` | Placeholder `ArrayMesh` skinned to a `Skeleton3D` (§3.4) |
| `char/<name>/{start,finish,wonrace,lostrace}.lst` | `Animation` resources |
| `env/<env>/<light>/light.lst` + skyboxes | `EnvironmentPreset` resources + three-face cube skies |
| `sounds.lst`, `music.lst`, `racing_themes.lst` | Audio resource tables (OGG imports natively) |
| `translations/*.lst` (15 languages) | Godot CSV translations. **Map numeric IDs → semantic keys** using the English strings; opaque integer IDs are a legacy wart worth fixing during the move |
| `textures.lst` | Dropped — hardcoded integer texture IDs die with the old renderer |

### 5.3 Migration principle

The importer is **one-way and re-runnable**. Legacy files stay read-only under `legacy/`; generated
resources land in `courses/` and are committed. Once a course has been touched in-editor it is owned
by the new format and re-import would clobber it — so the importer writes a provenance marker and
refuses to overwrite a modified course without an explicit flag.

**Correction, 2026-09-01.** The provenance marker as built was a `modified_in_editor` bool that
nothing ever set: the importer was its only writer and it only ever wrote `false`, so the guard
had never once fired. It cannot be fixed by observing the editor — GDScript's `_set` is not called
for script-declared exports, a property setter cannot tell an Inspector edit from a `.tres` being
loaded, and there is no `EditorPlugin` here. Provenance is now recorded rather than observed: the
importer stores an `import_fingerprint` hash of what it wrote, and a file that no longer hashes to
it was changed by something else. This also covers what the original design missed entirely —
`resources/terrain/*.tres`, the one place a designer can tune a material, which every import used
to overwrite unconditionally. `modified_in_editor` survives as the manual override.

---

## 6. Phases

Sizes are relative (S/M/L), not calendar estimates.

### Phase 0 — Physics core, headless — **L**
No rendering. `RacePhysics` + `HeightmapSurface` against a synthetic slope.
Port every force from `etracer.md` §4.1: gravity, piecewise spring normal force, jump, steering-rotated
friction, brake, Reynolds-table air drag, paddle. ODE23 with adaptive stepping. Tree/item collision
with a spatial grid.
> **Exit:** golden unit tests per force function; a scripted input trace produces a stable, sane
> trajectory down a synthetic slope; **the ODE substep loop measured in GDScript on a web export
> budget** (this is the load-bearing performance question — see §7).

### Phase 1 — Data pipeline + first drivable course — **L**
Importer (§5). `CourseData`, `TerrainLayer`. Chunked terrain mesh, untextured. Chase camera.
> **Exit:** `bunny_hill` imports and is drivable end-to-end on grey terrain, in a browser.
> Then `the_long_ride` (80×4000) to prove the long-course path.

### Phase 2 — Rendering — **M**
Splat shader with PBR layers, sun + baked LightmapGI + SSAO, fog, sky, instanced trees, item pickups.

> **Corrected 2026-09-07.** A tree is not a billboard in the original, and reading it as one is
> the single most visible difference a hillside had. `DrawTrees` gives every `[coll] 1` object two
> fixed quads at 90° and only the item loop under it faces the camera. Both shapes are now
> generated, split on `[coll]`; see `PROGRESS.md` Phase 2.
> **Exit:** looks like a game; holds 60 fps in-browser on mid hardware.

### Phase 3 — Snow — **L** *(the differentiator)*
`SnowFieldGPU` ping-pong trail map, terrain displacement + ridge formation, normal reconstruction,
`SnowField` CPU mirror feeding friction, `GPUParticles3D` spray with ETR's asymmetric emission logic,
snow shading (wrap diffuse + sparkle).
> **Exit:** carving leaves a persistent trench with ridges; re-driving a trench measurably changes
> handling; spray reads correctly on hard turns and braking.

### Phase 4 — Character — **M**
Placeholder mesh from `shape.lst`, then authored skinned glTF. Procedural additive layer (lean into
turns, brace on brake, flap on paddle, impact reaction on tree hit) over migrated keyframe animations.
The rig and the canned clips are done for all five characters, including the pre-race start
animation (`CIntro`), and the shell can choose between them.

> **Corrected 2026-09-07.** "Additive layer" is the wrong shape and was not built as one.
> `AdjustJoints` is not an offset over the canned clips — it *replaces* them: `CRacing` resets
> every joint and writes an absolute pose from the racer's state, and `CIntro` plays a keyframe
> and never calls it. The two are exclusive by construction, so `CharacterRig.adjust_joints` is a
> no-op while a clip is playing rather than something blended over it. There is also no impact
> reaction on a tree hit in the original; that item is redesign, not port.
> Done as of this date, for all five characters, and for every racer on the hill rather than just
> the player — which is what added four floats to `RacerState`, above.
> **Exit:** the penguin sells speed and carve direction without the player looking at the HUD.

### Phase 5 — Game shell — **M**
Course/cup/event selection, HUD, timing, herring counting, medals from the migrated thresholds,
save/profiles, settings, 15-language i18n, audio mixing.
> **Exit:** the full Tux Racer Classics cup is playable start to finish.

> **Correction, 2026-08-31.** Course selection is built and it does *not* sit above the race
> scene the way §4.1 draws it. The menu is a `CanvasLayer` inside `race.tscn`, drawn over the
> loaded course, and swaps courses through `RaceScene.load_course`. Keeping the race resident is
> what makes opening the menu free and closing it a resume; the layering in §4.1 still applies to
> any screen that has to exist before a course is loaded. The course list itself is a generated
> index resource (`resources/courses.tres`) rather than a directory scan, because `DirAccess` over
> `res://` finds nothing once the exporter has remapped the text resources.
>
> **Correction to the correction, 2026-09-01.** A title screen is precisely the screen that has to
> exist before a course is loaded, so §4.1 stands as drawn: `main_menu.tscn` is the main scene and
> the race is a scene the shell changes to and back from. `Practice` opens the same course list,
> `Configuration` is a settings screen over `penguinracer.cfg`, and the chosen course is handed
> across the scene swap on `RaceScene.requested_course_path` — a static, because a scene change
> leaves nothing to set a property on. What survives from 2026-08-31 is the in-race half: Esc still
> draws the list over the live course and still swaps through `load_course`, so the menu that opens
> mid-race is free and closing it is still a resume. Verification changed with it: `--course=` or
> `--auto-input=` (and `?course=` in a browser) skips the shell, which is what keeps
> `--capture`/`RACE_READY` working.
>
> **Addition, 2026-09-02.** A third entry: `Select a character`, over the five rows of
> `characters.lst`. It is the half of ETR's `CRegist` that this shell has something to put in —
> the other half is the player profile, which arrives with save profiles later in this phase — and
> unlike the original the answer is kept, in `penguinracer.cfg`. `RaceScene.requested_character`
> carries a `--character=`/`?character=` override across the scene swap, the same shape as
> `requested_course_path` and for the same reason.

> **Addition, 2026-09-02 — multiplayer foundation.** Not a phase; §8.4 scope, designed in §4.6
> and built alongside Phase 5 because it reshapes the race scene and the later that happens the
> more there is to reshape. Ghosts ship; AI and network play have their seams and one of the two
> has a transport.
> **Exit (met):** a recorded run replays to within 1e-9 of the original trajectory; the player
> races their own best time on any course; two processes see each other on the hill.

> **Addition, 2026-09-02 — computer opponents.** Also not a phase, also §8.4 scope, and the first
> thing to be built *on* the racer layer rather than into it: a fourth main-menu entry, `Race the
> computer`, and a `RaceSetup` carrying 0–9 opponents and a skill across the scene swap the same
> way `requested_course_path` does. The course screen grew the two spinners rather than getting a
> screen of its own, because the choice belongs beside the course and because someone who has just
> been beaten should be able to change it without leaving the panel. Nothing in the racer layer
> changed to accept it — see the note in §4.6 for the one thing the design did not foresee.
> **Exit (met):** the three levels finish in order on the same slope with the ends of the ladder
> 190 m apart over 30 s; an opponent goes through a gap in a stand of trees a straight-line racer
> drives into; a field replays identically; a Practice capture is unchanged.

> **Correction, 2026-09-07.** "Closing it is still a resume" (2026-09-01, above) no longer holds:
> the course menu's Continue button is gone, so Esc mid-race only ever drops back to the course
> list — an abandon, not a toggle — and there is no keypress that reopens the same panel and
> returns to where the player was. That gap is filled by a new, unrelated key: `P` freezes the
> race in place behind a `PAUSED` label, with no panel and no course list, and unfreezes it again.
> The two are mutually exclusive on purpose, so a stray key cannot leave the freeze up with
> nothing on screen saying so. Steering, paddling and braking moved with it, off `A`/`D`/`W`/`S`
> and onto the arrow keys, freeing the letters for nothing in particular — there was no second use
> waiting for them, just a request that the two schemes not overlap.

### Phase 6 — Polish + ship — **M**
Quality tiers replacing `perf_level`, WASM size budget, loading/streaming, redesigned finish sequence
(no gravity hack), input remapping, gamepad, touch.
> **Exit:** hosted web build, cold-load budget met.

**Parallelisable:** Phase 2 and Phase 4 are independent of Phase 3. The importer (Phase 1) can be
built alongside Phase 0 by a second person.

---

## 7. Risks and de-risking spikes

Do these **before** committing to the phase plan.

| # | Risk | Severity | Spike |
|---|---|---|---|
| **S1** | **Ping-pong `SubViewport` render targets in a Godot *web* export.** The entire snow design rests on it. Standard technique and GLES3 has the pieces, but I have inferred this from the feature matrix, not seen it confirmed in a Godot web build. | **Critical** | Half-day: minimal ping-pong RT + vertex texture fetch displacement, exported to web, verified in Chrome and Firefox. **Do this first.** |
| **S2** | **GDScript performance of the ODE23 substep loop.** With C# unavailable on web, the only fallback is GDExtension, which is fragile on web. | **High** | Phase 0 exit criterion. Mitigation if slow: cap adaptive substeps, precompute terrain queries, hoist allocations. Contingency: godot-rust GDExtension, accepting web-export friction. |
| **S3** | Heightmap dequantization produces artefacts or changes course feel | Medium | Convert 3 courses of differing character early; compare against original screenshots. |
| **S4** | `RGBA8` LDR ceiling makes snow look flat or bands on gradients | Medium | Build the snow shader early in Phase 2, not Phase 3; test on a bright sunny course. |
| **S5** | Asset licence audit blocks reuse of music/courses | Medium | Audit before Phase 5. Independent of engineering — start now. |
| **S6** | Web cold-load size (ETR ships 14 MB music + 11 MB skyboxes) | Low | Stream per-course; compress skyboxes; music on demand. |

**Status, 2026-08-31 — see [`history.md`](./history.md):** S1 **retired, PASS** in a web export
under Chromium/WebGL2 (Firefox still unverified for want of a GPU in the build container). S2
**retired, PASS with margin** — 0.073 ms per frame in-browser, 0.44 % of a 16.7 ms budget, so the
GDExtension contingency should not be built. S3–S5 remain open; S6 retired 2026-09-08, below.

**S4, 2026-09-01.** The `RGBA8` ceiling was the wrong thing to have been worried about. Snow did
clip to flat white across the whole near field, but not because 8 bits could not hold it — because
the scene was being handed roughly twice as much light as it should have been, by four separate
Godot defaults that each looked reasonable in isolation (`SPECULAR` 0.5, sky-driven ambient,
environment reflections, a filmic tone curve). ETR clips its own lit snow too; the near field is
*meant* to sit in a narrow band just under the ceiling. Bunny Hill now matches the original at
both ends of that band. The mitigation that mattered was not "build the shader early" but
"capture the same frame from both games and measure it" — see history.md §11.

**S6, 2026-09-08.** Retired, done. `tools/build_web_streamed.sh` splits the web export into a
slim base (engine + shell + all 44 course preview thumbnails, ~65 MB against the old
monolithic 161 MB) plus one `.pck` per course and one for `assets/music/`, fetched over HTTP
and mounted at runtime by `PackStream` (`game/scripts/config/pack_stream.gd`) only when a
course is chosen or a track first plays. Built on Godot's own `--export-pack` per generated
preset (`tools/gen_course_export_presets.py`) rather than a hand-rolled packer, so texture
import-remapping is exactly what a normal export already produces. Skybox compression was not
needed to hit the budget and remains open if a future course pushes it back up.

**Explicitly not a risk:** Godot's physics engine. We do not use it — the simulation is a custom point
mass against our own heightmap, exactly as ETR did. Its limitations do not apply to us.

---

## 8. Open decisions with decisions:

1. **Godot version** — 4.7 stable
2. **Fidelity vs. improvement on course import** — preserve-on-import, improve in-editor per course.
4. **Scope beyond the original** — redesign (ghosts, time trials, multiplayer, procedural courses) is in scople, this features should be taken into account for the initial design and added later.
   > **Acted on, 2026-09-02.** The design is §4.6 and the foundation is built: a fixed-tick
   > simulation, a racer list split into simulated and played-back, `RacerState` as the one thing
   > the presentation reads, and recording in both poses and intent. Ghosts are finished; the ENet
   > session is a working scaffold with no lobby and no web; AI opponents need an `InputSource`
   > and nothing else. Time trials and procedural courses are untouched.
5. **Desktop native** — ship it? sure, desktop and web are equally important. therfore it is ok to develop and test against the native version.

---

## 9. First actions

1. Run spike **S1** (ping-pong RT on web export). Everything in Phase 3 is contingent on it.
2. Install Godot 4.7 in the devcontainer; scaffold the project with the §4.1 layering.
3. Start Phase 0 physics with golden tests transcribed from `etracer.md` §4.1.
4. Kick off the asset licence audit (§8.3) — it has a long lead time and blocks Phase 5, not Phase 0.
