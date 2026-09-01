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

---

## 4. Runtime architecture

### 4.1 Layering

```
Game shell (menus, cups, scoring, i18n)      ← Godot Control scenes
Race scene
  ├── RacePhysics        (GDScript, headless-testable, no node deps)
  ├── SurfaceProvider    (interface)  ← HeightmapSurface  [← CompositeSurface later]
  ├── SnowField          (CPU deformation mirror)
  ├── TerrainRenderer    (chunked ArrayMesh + splat/displacement shader)
  ├── SnowFieldGPU       (ping-pong SubViewports → trail map texture)
  ├── SprayEmitter       (GPUParticles3D)
  ├── ChaseCamera
  └── CharacterRig       (skeleton + procedural additive layer)
```

`RacePhysics` must have **zero node dependencies** — plain `RefCounted` operating on a
`SurfaceProvider`. That is what makes headless parity testing (§6, Phase 0) possible, and it is the
main structural improvement over ETR's `CControl`, which reached into six globals.

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

### 4.5 Visual target under Compatibility

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
  PROGRESS.md §10.

The fog range in §4.3 is likewise the original's 75 m, not a stretched version of it: ETR's white
haze is load-bearing for how its snow reads, and the skybox is what sits behind it.

Accept as out of scope under Compatibility: volumetric snowfall (use layered scrolling noise +
GPUParticles instead), SSR on ice, real HDR glare.

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
4. **`items.lst` → scene nodes.** Prefer `items.lst` over `trees.png` — it carries float `height`/`diam`
   the pixel map lacks. Positions are grid-snapped in the source; **preserve them exactly on import**
   (tree placement is gameplay), leave de-gridding to a designer in-editor.
5. **`course.dim` → `CourseData`**, including localized name/description. `play_width`/`play_length`
   become a rectangular `Curve2D` — correct on import, free to reshape later.
6. **`preview.png`** copied.

### 5.2 Global importers (run once)

| Source | Target |
|---|---|
| `terrains.lst` | `TerrainLayer` resources; old diffuse PNGs wired as `albedo`, normal/roughness left null for later authoring |
| `object_types.lst` + object textures | Object prefab scenes (`.tscn`) |
| `events.lst` | `Race` / `Cup` / `EventSet` resources — **keep the herring/time thresholds verbatim** |
| `char/<name>/shape.lst` | Placeholder `ArrayMesh` + `Skeleton3D` (§3.4) |
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

**Status, 2026-08-31 — see [`PROGRESS.md`](./PROGRESS.md):** S1 **retired, PASS** in a web export
under Chromium/WebGL2 (Firefox still unverified for want of a GPU in the build container). S2
**retired, PASS with margin** — 0.073 ms per frame in-browser, 0.44 % of a 16.7 ms budget, so the
GDExtension contingency should not be built. S3–S6 remain open.

**S4, 2026-09-01.** The `RGBA8` ceiling was the wrong thing to have been worried about. Snow did
clip to flat white across the whole near field, but not because 8 bits could not hold it — because
the scene was being handed roughly twice as much light as it should have been, by four separate
Godot defaults that each looked reasonable in isolation (`SPECULAR` 0.5, sky-driven ambient,
environment reflections, a filmic tone curve). ETR clips its own lit snow too; the near field is
*meant* to sit in a narrow band just under the ceiling. Bunny Hill now matches the original at
both ends of that band. The mitigation that mattered was not "build the shader early" but
"capture the same frame from both games and measure it" — see PROGRESS.md §11.

**Explicitly not a risk:** Godot's physics engine. We do not use it — the simulation is a custom point
mass against our own heightmap, exactly as ETR did. Its limitations do not apply to us.

---

## 8. Open decisions with decisions:

1. **Godot version** — 4.7 stable
2. **Fidelity vs. improvement on course import** — preserve-on-import, improve in-editor per course.
4. **Scope beyond the original** — redesign (ghosts, time trials, multiplayer, procedural courses) is in scople, this features should be taken into account for the initial design and added later.
5. **Desktop native** — ship it? sure, desktop and web are equally important. therfore it is ok to develop and test against the native version.

---

## 9. First actions

1. Run spike **S1** (ping-pong RT on web export). Everything in Phase 3 is contingent on it.
2. Install Godot 4.7 in the devcontainer; scaffold the project with the §4.1 layering.
3. Start Phase 0 physics with golden tests transcribed from `etracer.md` §4.1.
4. Kick off the asset licence audit (§8.3) — it has a long lead time and blocks Phase 5, not Phase 0.
