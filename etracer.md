# Extreme Tux Racer (ETR) 0.8.4 — Source Analysis & Modern Port Research

**Purpose of this file:** hand-off notes so a later agent session can start work on porting the ETR
game idea to a modern engine targeting WebAssembly + WebGPU/WebGL without re-reading the whole
codebase. Written 2026-08-30.

**Source location:** `/workspaces/penguinracer/etr-0.8.4/` (extracted from `etr-0.8.4.tar.xz`,
39 MB compressed; ~20k lines of C++ source + ~40 MB of game data).

**Engine decision: Godot 4.7** (2026-08-30, §6). The rebuild plan lives in
[`godot-port-plan.md`](./godot-port-plan.md); §6 of that file lists the port phases and §7 the spikes
to run first. This file remains the reference for *what the original does* — especially §4.1
(physics constants) and §5 (legacy file formats), which the importer and the physics port both
depend on.

---

## 1. What the game is

Downhill arcade racer. You are a penguin sliding on your belly down a procedurally-lit,
heightmap-based snow slope. Core loop:

- **Movement:** gravity + terrain normal force + friction do the work. You steer left/right,
  *paddle* (flippers on snow, adds forward force, only effective below ~60 km/h), *brake*, and
  *charge + release a jump*. Airborne you can do flips and rolls (trick modifier key).
- **Objective:** reach the bottom of the course before a time limit while collecting herring
  (fish pickups). Cups grade you bronze/silver/gold on `(herring, time)` thresholds.
- **Hazards:** trees (two textured quads at 90°, fixed, with a polyhedron collision proxy) slow
  you and cost speed;
  terrain type changes friction (ice 0.2 → rock 0.7) and whether you leave track marks / kick up
  snow particles.
- **Feel:** the whole thing lives or dies on the terrain-following physics + camera lag. That is the
  part actually worth porting faithfully.

Modes: single race ("practicing"), cup racing (unlock chain), plus a built-in character/keyframe
editor tool mode (`--char`), which is dev tooling, not gameplay.

Courses are ~90 m wide × 260–4000 m long, played downhill along −Z.

---

## 2. Build, dependencies, licensing

| Item | Value |
|---|---|
| Build | GNU autotools (`configure.ac`, `Makefile.am`) + a VS project under `build/` |
| Language | C++14 |
| Windowing/input/audio/image/font | **SFML ≥ 2.4** (system, window, graphics, audio) |
| Graphics | **Fixed-function OpenGL 1.x** + GLU. `glBegin/glEnd`, `glLight*`, `glFog*`, `glTexGen*`, `glMatrixMode` |
| Code license | **GPL-2.0-or-later** (Tux Racer 1999–2001 Jasmin F. Patry; ETR team 2010–2024) |

**Licensing implication for a port:** the C++ is GPLv2+. If you write a new implementation from the
design and constants rather than translating code line-by-line, you have more license freedom; if
you port code, the derivative stays GPL. The *constants and physical model* (numbers in
§4.1) are facts about a simulation and are the genuinely valuable part. Data assets have mixed
authorship (see `data/credits.lst`, `AUTHORS`) — music by named artists, graphics by Kristian Picon
and Nicosmos, courses by many authors; treat asset reuse as needing a per-asset licence check.
Tux himself is Larry Ewing's.

---

## 3. Module map (`src/`, ~20k lines)

Everything is global singletons (`Course`, `Env`, `Sound`, `Music`, `Tex`, `FT`, `Players`, `Char`,
`Events`, `Wind`, `g_game`). No ECS, no dependency injection.

**Core simulation**
- `physics.{h,cpp}` (646 ln) — `CControl`. The whole player simulation. **Most important file.**
- `course.{h,cpp}` (1012 ln) — heightmap, terrain map, object/item lists, barycentric terrain queries.
- `quadtree.{h,cpp}` (1146 ln) — Thatcher/Patry CLOD quadtree terrain renderer. **Delete in a port.**
- `mathlib.{h,cpp}` (536 ln) — ODE23 solver (Bogacki–Shampine RK2(3) with adaptive step), interpolation.
- `vectors.{h,cpp}`, `matrices.{h,cpp}` — vec2/3/4, 4×4 matrices, quaternions.

**Presentation**
- `course_render.cpp` — terrain draw call, then `DrawTrees`: two loops, one over `CollArr`
  emitting eight fixed vertices per tree (a quad across X and a quad across Z, ground to
  `[height]`, never turned toward the camera) and one over `NocollArr` emitting four camera-facing
  vertices per item. Only the second half billboards. `[coll]` is what splits them.
- `particles.cpp` (1131 ln) — 4 separate snow systems (see §4.4).
- `track_marks.cpp` (305 ln) — ski/belly trail quad strip.
- `env.{h,cpp}` — skybox, 4 lights, linear fog, per-environment/time-of-day config.
- `view.cpp` — 3 camera modes + view frustum culling planes.
- `tux.{h,cpp}` (950 ln) — `CCharShape`: hierarchical sphere-based character model + IK-ish joint posing.
- `keyframe.{h,cpp}` — canned animations (start, finish, wonrace, lostrace).
- `hud.cpp`, `font.cpp`, `textures.cpp`, `ogl.cpp` — HUD, SFML font wrapper, texture cache, GL state.

**Shell / non-gameplay** (mostly discardable, reimplement as UI)
- `states.{h,cpp}` + `winsys.cpp` — state machine and main loop.
- `gui.cpp` (853 ln), `splash_screen`, `intro`, `race_select`, `event_select`, `game_type_select`,
  `config_screen`, `credits`, `help`, `newplayer`, `regist`, `paused`, `reset`, `game_over`, `loading`.
- `racing.cpp` (418 ln) — the in-race state: input handling + per-frame ordering. Short and worth reading.
- `game_ctrl.cpp`, `game_config.cpp`, `score.cpp`, `translation.cpp`, `spx.cpp` (config parser),
  `audio.cpp`, `tools.cpp` / `tool_char.cpp` / `tool_frame.cpp` (editor).

---

## 4. Systems worth porting, in detail

### 4.1 Physics — `physics.cpp` / `physics.h`

This is the heart. Player is a **point mass (20 kg)** integrated with adaptive ODE23; the character
model is purely cosmetic and is posed to follow the point.

Per substep, `CalcNetForce(pos, vel)` sums, **in this order** (order matters, they read shared
state in `TForce ff`):

1. **Gravity** — `(0, −9.81 × 20, 0)` N.
2. **Normal / spring force** — terrain acts as a piecewise-stiff spring once the point penetrates
   below `comp_depth` (terrain-dependent, 0.01–0.11 m). Stiffness ramps 1500 → 3000 → 10000 N/m
   in three bands, damped by `−springvel × (1500 | 500)`, clamped to 3000 N. Applied along the
   **roll normal**, not the surface normal.
3. **Jump force** — `294 + jump_amt × 294` N in +Y, for `JUMP_FORCE_DURATION = 0.20 s`.
   `jump_amt` = charge time clamped to 1.0 s.
4. **Friction** — `|N| × frict_coeff`, capped at 800 N, applied opposite velocity, then **rotated
   about the surface normal by `turn_fact × 45°`** — this is how steering works. Lateral component
   capped at `MAX_TURN_PERP = 400` N. Result scaled by `1 + MAX_TURN_PEN (0.15)`.
   Only active when grounded and `speed > MIN_FRICT_SPEED (2.8 m/s)`.
5. **Brake** — `frict_coeff × 200 N` opposing velocity, grounded only.
6. **Air drag** — Reynolds-number table lookup: `re = 34600 × windspeed`, `log10(re)` interpolated
   over `airlog[] = {-1..6}` → `airdrag[] = {2.25, 1.35, 0.6, 0, −0.35, −0.45, −0.33, −0.9}`,
   `dragcoeff = 10^interp`, force `= 0.104 × dragcoeff × windspeed × windvec`. Wind adds
   `1.5 × Wind.WindDrift()`.
7. **Paddle** — grounded: up to `122.5 N` forward, scaled by `(60/3.6 − speed)/(60/3.6)` so it
   stops helping past 60 km/h, and by `min(1, frict_coeff/0.35)` so it's useless on ice.
   Airborne: a small `−mass·g/4` push in local −Z (the flipper flap).

**Roll normal** (`CalcRollNormal`): the surface normal rotated about the projected velocity by
`turn_fact × 30°` (55° when braking), attenuated by both friction and speed ramps. This is what
makes carving feel banked.

**Integration** (`SolveOdeSystem`): Bogacki–Shampine ODE23, adaptive `h ∈ [0.01, 0.10] s`, additionally
capped so the player moves ≤ `MAX_STEP_DIST = 0.20 m` per step. Error tolerances
`MAX_POS_ERR = 0.005 m`, `MAX_VEL_ERR = 0.05 m/s`; step is retried on failure with the standard
`0.8·(tol/err)^(1/3)` shrink. Particles are generated *inside* the substep loop.

**Post-step:** velocity floored at `MIN_TUX_SPEED = 1.4 m/s`; position pushed out if penetration
exceeds `MAX_SURF_PEN = 0.2 m`; X clamped to the play-area boundary; crossing `play_length` triggers
finish.

**Collision:**
- *Trees* — broadphase by 2D distance vs `(diam/2 + 0.6)²`; narrowphase = character's sphere
  hierarchy vs an 8-face polyhedron scaled to tree diam/height. On hit: speed × 0.8, velocity
  reflected out of the tree normal with factor 1.5 grounded / 0.5 airborne. There is a 1-entry
  memo cache keyed on `MAG_SQD(Δpos) < 0.1`.
- *Items* — bounding-sphere test `(diam/2 + 0.7)²`, sets `collectable = 0`, increments herring.
  This is **O(items) per substep** — a linear scan over the entire course every physics step.
  Trivially fixable with a spatial grid in a port.

**Finish sequence** is a hack: `g_game.finish` swaps gravity to a flat 500 N, forces braking, and
plays a keyframe animation. Worth redesigning.

### 4.2 Course / terrain — `course.cpp`

Data-driven from PNGs, no mesh files:

- `elev.png` — grayscale heightmap, `nx × ny` = course grid (e.g. 90×260 for bunny_hill, 100×1000 for
  wild_mountains, 80×4000 for the_long_ride). Decoded as
  `elev = ((pixel − 127)/255) × scale − (row/ny) × length × tan(angle)`, i.e. the course's overall
  downhill slope is added analytically on top of a local height field. `scale` ≈ 7–10 m,
  `angle` ≈ 10–25°.
- `terrain.png` — per-vertex terrain type, matched to `terrains.lst` entries by RGB within ±30.
  ~45 terrain types (ice, snow variants, rock, sand, mud, pave, grass), each with
  `friction`, `depth`, `sound`, `particles`, `trackmarks`, `shiny`, and track-mark texture ids.
- `trees.png` — object placement by colour key (8 legacy colours), converted **once** at first load
  into `items.lst` (a text file, cached beside the course). Tree height/diam randomised from
  `g_game.treesize`/`treevar`.
- `course.dim` — width, length, play_width, play_length, angle, scale, startx/starty, env, theme,
  `use_keyframe`, `finish_brake`, author, localized name/description.
- `preview.png`.

**Terrain queries** (`FindBarycentricCoords`) pick one of two triangulations per quad depending on
`(x0+y0) % 2` — a checkerboard flip to avoid directional bias. `FindCourseNormal` blends the
smooth per-vertex normal with the flat triangle normal, weighted by distance from the triangle
edge (`NORM_INTERPOL = 0.05`), so the player doesn't feel faceted mid-triangle but still gets
crisp ridges. `GetSurfaceType` returns barycentric-weighted terrain weights, which is how friction
blends smoothly across terrain boundaries. **Keep this idea.**

`FindYCoord` has a 1-entry cache. Course mirroring flips the elevation/terrain/normal arrays in
place for a "mirrored" race variant.

### 4.3 Terrain rendering — `quadtree.cpp` (don't port)

Ulrich Thatcher's adaptive CLOD quadtree, adapted by Patry. Its own header admits the problems:
blurry blending at terrain boundaries, no detail texturing, and **performance degrades linearly with
the number of terrain types on a course** (it re-renders per terrain layer with alpha blending).
Interleaved VNC array (`8 floats + 4 bytes` stride) fed through fixed-function `glTexGen` object-plane
texture coordinate generation at `1/6` scale.

Replace with: a GPU-side heightmap (single vertex/index buffer or a clipmap), splatting via a terrain
weight texture in a fragment shader, and triplanar or virtual-texture detail mapping. This is a
solved problem in every modern engine and the single largest visual upgrade available.

### 4.4 Snow — four separate systems in `particles.cpp`

1. **`TGuiParticle`** — 2D screen-space snow for menus, up to 4000 SFML sprites, with a mouse "push"
   impulse field. Cosmetic; reimplement as a shader.
2. **Kick-up particles** (`generate_particles`) — the gameplay-relevant one. Spawned at two points
   `±TUX_WIDTH/2 = ±0.225 m` either side of the player, on the surface, when the terrain has
   `[part] 1` and the player is below the surface. Count = `dt × (brake + turn + roll rates) ×
   min(speed/PARTICLE_SPEED_FACTOR, 1)`, split left/right by the sign of `turn_fact` and
   `turn_animation`. Initial velocity = plane normal rotated about the travel direction by up to
   `±MAX_PARTICLE_ANGLE` scaled by speed, magnitude `min(MAX_PARTICLE_SPEED, speed × mult)`.
   **This asymmetric left/right spray keyed to carve direction is the signature visual — keep it.**
3. **`CFlakes` / `TFlakeArea`** — near-field 3D flakes in camera-relative boxes, recycled when they
   leave the box, drawn as camera-facing quads clipped against the left/right frustum planes.
4. **`CCurtain`** — far-field "snow curtains": a cylindrical shell of `≤16 × 8` billboards around the
   camera at fixed angular positions, giving cheap depth to heavy snowfall.

Plus **`CWind`** — a state machine that lerps wind speed and angle toward randomly chosen targets
(`SetParams(grade)` per snow/wind level 0–3); feeds both air drag and flake drift.

**Track marks** (`track_marks.cpp`): a ring buffer of up to 10 000 quads forming a quad strip,
`TRACK_WIDTH = 0.7 m`, raised `TRACK_HEIGHT = 0.08 m` above the surface, alpha derived from how deep
the player is in the snow. Broken into HEAD/MARK/TAIL segments so the strip can restart when the
player goes airborne or crosses onto a non-trackmark terrain. It is a **decal, not a deformation** —
the terrain geometry never changes. Modernising this is the other big win (see §7).

### 4.5 Camera — `view.cpp`

Three modes: `BEHIND` (chase, orbits with velocity direction), `FOLLOW` (chase with position and
orientation lag), `ABOVE` (fixed relative offset). Default distance 4.0 m.

The good part: **quaternion-interpolated orbit and orientation with `alpha = min(0.3, 1 − exp(−dt/τ))`,
`τ = 0.06 s`**, plus a `time_constant_mult` that *disables* interpolation below 2 m/s and ramps it in
by 4.5 m/s — so the camera is snappy when you're crawling and smooth at speed. Camera is also pushed
up to keep `MIN_CAMERA_HEIGHT = 1.5 m` above terrain and pitch clamped to 40°. Reproduce this
behaviour, not the code.

### 4.6 Character — `tux.{h,cpp}`, `keyframe.cpp`

`CCharShape` is a scene graph of up to 256 nodes, each an **ellipsoid** (a unit sphere with a
per-node scale/rotation/translation matrix), with named joints (`neck`, `head`, `left_shldr`,
`left_hip`, `left_knee`, …). Loaded from `shape.lst`. Rendering is `DrawCharSphere` with 3–16
subdivisions depending on detail level. Shadow is a projected-sphere silhouette.

`AdjustOrientation` builds the body orientation quaternion from velocity, surface normal and the roll
factor; `AdjustJoints` poses arms/legs/neck from `turn_animation`, braking, paddling factor, speed
and the local net force vector. Keyframe animations (`start.lst`, `finish.lst`, `wonrace.lst`,
`lostrace.lst`) are lists of `[time] [pos] [yaw] [pitch] [roll] [neck] [head] [arm] [hip] [knee] …`
interpolated linearly.

**In a port:** replace entirely with a skinned glTF character + a proper animation graph. Keep the
*procedural layer* (lean into turns, brace when braking, flap when paddling, ragdoll-ish on tree hit)
as additive bone offsets on top of authored animation.

### 4.7 Environment — `env.cpp`

Per-course `env` (e.g. `etr`, `tuxracer`) × one of 4 light conditions (`sunny`, `cloudy`, `evening`,
`night`). Each directory has a skybox (3 or 6 faces, optional `H` high-res variants) and `light.lst`
defining up to 4 fixed-function lights (ambient/diffuse/specular/position) plus linear fog
(`start`, `end`, colour, and a particle tint colour so snow matches the fog). Fog end defaults to
`forward_clip_distance`, so fog is doubling as a draw-distance hider.

Modern replacement: HDR sky (physical or cubemap), one directional sun + IBL, exponential height fog,
and real draw distance.

---

## 5. File formats

**"SP list" format** (`spx.cpp`) — used by every `.lst` and `.dim` file. Line-oriented; `*` starts a
new record, `#` comments, fields are `[tag] value` pairs, records may continue across lines until the
next `*`. Trivial to reimplement or convert to JSON/TOML in a port.

| File | Contents |
|---|---|
| `data/courses/groups.lst` | course groups (`default`, `extras`) |
| `data/courses/<group>/courses.lst` | course name + dir per group |
| `data/courses/<group>/<course>/` | `course.dim`, `elev.png`, `terrain.png`, `trees.png`, `items.lst`, `preview.png` |
| `data/courses/events.lst` | `[struct] 0` races, `[struct] 1` cups, `[struct] 2` events. Races bind course + light + snow + wind + `[herring] b s g` + `[time] b s g` + music theme |
| `data/terrains/terrains.lst` | ~45 terrain types (see §4.2) |
| `data/objects/object_types.lst` | herring, flag, start, finish, float(reset), tree, tree_barren, shrub + extras |
| `data/char/characters.lst`, `data/char/<name>/shape.lst` + 4 keyframe lists | 5 characters: tux, boris, samuel, trixi, beastie |
| `data/env/environment.lst`, `data/env/<env>/<light>/light.lst` | 2 envs × 4 light conditions |
| `data/textures/textures.lst` | fixed texture ids — **the code indexes these by number**, do not renumber |
| `data/sounds/sounds.lst`, `data/music/music.lst`, `racing_themes.lst` | audio |
| `data/translations/*.lst` | 15 languages, string-id indexed |

**Content inventory:** 23 default courses + 22 extra courses, 5 characters, ~45 terrains,
2 environments × 4 lighting conditions, 14 MB music (9 OGG tracks), 4 MB sound effects, 4.7 MB terrain
textures, 11 MB skyboxes.

---

## 6. Engine evaluation — WASM + WebGPU/WebGL targets

Requirements implied by the task: open source; ships to browser via WASM (or JS); WebGPU preferred
with WebGL2 fallback; needs **compute shaders** if we want GPU snow deformation and large particle
counts; needs decent terrain, PBR, and a particle system.

State of the platform (mid-2026): WebGPU is now baseline across Chrome/Edge/Safari/Firefox on
desktop with broad Android support; roughly 85–95 % of users depending on which tracker you believe.
Linux and Intel Macs are the notable stragglers, so **a WebGL2 fallback path is still worth having**.

### Serious candidates

| Engine | Lang | Web target | WebGPU | Compute | Licence | Verdict |
|---|---|---|---|---|---|---|
| **Bevy 0.19** | Rust | wasm32-unknown-unknown | via wgpu, feature-flagged | yes (native + WebGPU) | MIT/Apache-2.0 | **Top pick for a code-first port** |
| **PlayCanvas 2.x** | JS/TS | native web | first-class, production | yes | MIT | **Top pick for fastest time-to-playable** |
| **Babylon.js 8** | JS/TS | native web | mature, GLSL→WGSL auto-translation | yes | Apache-2.0 | Very strong; best docs |
| **Three.js (WebGPURenderer + TSL)** | JS/TS | native web | production-ready as of r171+, still labelled experimental | yes | MIT | Renderer, not an engine — you build the game layer |
| **Godot 4.7** | GDScript/C# | wasm, wasm64 since 4.7 | **no** — official web export is Compatibility/WebGL2 only. Unofficial "Godot WebGPU" fork in public beta since May 2026 | no on web | MIT | Great editor, but the web+WebGPU requirement is unmet officially |
| **Fyrox 1.0** | Rust | wasm32-unknown-unknown | WebGL2-era renderer; WebGPU not established | no | MIT | Has a real editor; smaller ecosystem, weaker web story |
| **Cocos Creator** | TS | web | yes | yes | MIT (engine) | Viable, but 2D/mobile-oriented culture |

### Ruled out
Unity / Unreal (not open source), O3DE / Flax / Stride / Wicked (no web target), Defold (source
available but not OSI-licensed, and 3D terrain is not its strength), Macroquad / ggez / raylib
(too low-level for the visual bar requested), rend3 (deprecated).

### Recommendation — **DECIDED: Godot 4.7** (2026-08-30)

> **Decision made.** The user clarified that WebGL2 and WebGPU need not coexist in one build, and
> that WebGPU is a preference rather than a requirement. That removed the main objection to both
> Bevy and Godot. **Godot 4.7 was chosen.** See [`godot-port-plan.md`](./godot-port-plan.md) for the
> rebuild plan. The alternatives below are retained for context if the decision is revisited.

**Why Godot won:** the deciding factors are not rendering. ETR's course "authoring" is painting three
PNGs by hand; a real editor is a larger productivity gain than any feature on the Compatibility cut
list. Godot's physics engine is irrelevant to us (we reimplement `CControl` as a point mass against
our own heightmap), so its limitations don't apply. Desktop native ships nearly free from the same
project.

**What Compatibility (WebGL2) actually costs us** — verified against the
[official feature matrix](https://raw.githubusercontent.com/godotengine/godot-docs/master/tutorials/rendering/renderers.rst):

- **Have:** PBR, shadows (8 dir / 8 omni+spot per mesh), SSAO, LightmapGI, depth+height fog,
  tonemapping + glow, MSAA/SSAA, screen+depth textures, GPUParticles.
- **Lost:** compute shaders and all `RenderingDevice` access, **HDR (`RGBA8` LDR only)**, SSR, SSIL,
  volumetric fog, SDFGI/VoxelGI, decals, subsurface scattering, DoF, CompositorEffects,
  TAA/FSR2/FXAA/SMAA, particle trails, particle SDF collision.
- **Three that matter here:** (1) **No HDR** is the real cost — snow is the worst subject for an LDR
  pipeline (sparkle, sun glare, bright-vs-trench contrast). (2) No decals is a non-issue; track marks
  become vertex displacement anyway. (3) **LightmapGI working is a genuine win** — courses are static,
  so bake GI on desktop and ship the lightmap; this offsets the lack of SDFGI.
- **No compute is survivable:** the snow deformation field uses ping-pong `SubViewport` render
  targets instead (pre-compute-era standard technique), and ports forward to compute unchanged.
- **Don't use Terrain3D** — its web export is self-described "very experimental" (GDExtension), and
  we need a custom deforming heightmap mesh regardless. Sidesteps the risk entirely.

**Hard constraint discovered:** **C# web export is not supported**
([godot#70796](https://github.com/godotengine/godot/issues/70796), still prototype as of late 2025).
Gameplay code is GDScript; GDExtension is the only fallback and is fragile on web.

**On the "Godot will eventually get WebGPU" bet:** architecturally sound and officially intended — a
maintainer in [proposal #4806](https://github.com/godotengine/godot-proposals/discussions/4806) states
WebGPU will sit behind `RenderingDevice` and *"the modern renderers (clustered/mobile) will target
WebGPU when exporting to web."* But that is from July 2022, floated for "Godot 5 or later", with
reservations about bundling Dawn — and four years on, official web export is still WebGL2-only
(4.7 shipped wasm64, not WebGPU). **Right direction, no committed date; do not schedule against it.**
Migration cost when it lands is a shader-review exercise, not a rewrite.

**Alternatives, if the decision is revisited:**

1. **Babylon.js 8 / PlayCanvas 2.x (JS/TS).** WebGPU + compute + HDR *today*, WebGL2 fallback in the
   same build, and an existing snow-deformation reference implementation
   (`github.com/Noniv/snowflow_demo` — GPU terrain with deformation in hand-written WGSL). Cost: you
   build the game and tooling layer yourself. **Pick this if the bar is HDR sparkle, volumetric
   snowfall, and SSR off ice** — Compatibility will not get you there.
2. **Bevy 0.19 (Rust).** Typed simulation, native + web from one source. Note
   [bevy#13168](https://github.com/bevyengine/bevy/issues/13168): WebGL2 and WebGPU can't share a
   build, so shipping both means two bundles and a feature-detect loader (moot given the clarified
   requirement). Larger WASM, slower iteration.

---

## 7. Snow simulation — what "good snow" should mean here

> **Superseded in part by [`godot-port-plan.md`](./godot-port-plan.md) §4.3.** This section describes
> the target regardless of engine. Under Godot's Compatibility renderer there are **no compute
> shaders**, so every "compute shader" below becomes a **ping-pong `SubViewport` fragment pass**, and
> the plan adds a **low-res CPU mirror** of the deformation field (GPU→CPU readback would stall the
> browser). The technique and the visual target are unchanged.

ETR has no snow simulation; it has a decal trail and billboard sprays. The upgrade, in rough order
of value-per-effort:

1. **Persistent deformation heightmap.** Keep a camera-following R16/R32F "trail map" texture
   (e.g. 1024², covering ~64 m, scrolling with the player). Each frame a compute shader stamps the
   player's contact footprint (and tree/object impacts) into it, with decay/refill over time and
   optional wind-driven drift. This is the Batman: Arkham Origins technique and the standard
   compute-shader approach in the literature.
2. **Displace the terrain from it.** Sample the trail map in the vertex/mesh shader and push snow
   vertices down inside trenches and up into the ridge on either side of the carve. WebGPU has no
   hardware tessellation, so use either a dense camera-centred clipmap ring or a mesh-shader-style
   subdivision in compute. Feed the same map into the normal calculation so lighting reads the trench.
3. **Physics reads the deformation.** Reduce `comp_depth` and raise friction where snow has already
   been packed down. This makes racing lines matter and closes the loop between visuals and gameplay —
   the thing the original never did.
4. **GPU particle spray.** Move the §4.4 kick-up system to a compute-driven particle buffer:
   10⁵–10⁶ particles instead of a few hundred, lit by the sun, with depth-buffer collision. Keep the
   asymmetric left/right emission keyed to carve direction.
5. **Snow shading.** Subsurface-ish wrap lighting, sparkle (view-dependent glint from a noise texture),
   and a proper BRDF instead of Lambert. Snow that looks right at grazing angles sells the whole scene.
6. **Volumetrics.** Snowfall as a raymarched volume or at minimum layered scrolling noise, replacing
   the `CCurtain` billboard shell.

---

## 8. Suggested port plan (not yet agreed with the user)

- **Phase 0 — data pipeline.** Write a converter: `elev.png` + `terrain.png` + `course.dim` +
  `items.lst` → a single JSON manifest + a terrain weight texture + a float heightmap (KTX2/EXR).
  This is a small standalone script and it de-risks everything downstream. Verify against
  `bunny_hill` (90×260) first, then `the_long_ride` (80×4000) for the long-course case.
- **Phase 1 — physics parity.** Port `CControl` faithfully (constants in §4.1), with terrain queries
  from the converted heightmap. Validate by recording a deterministic input trace in the original
  binary and comparing trajectories. Get the *feel* right before any art.
- **Phase 2 — renderer.** Clipmap terrain + splat shading, sun + IBL, height fog, glTF character with
  the procedural pose layer, instanced crossed-quad trees (or real tree models).
- **Phase 3 — snow.** §7 items 1–4.
- **Phase 4 — shell.** Course/cup/event selection, HUD, scores, i18n (15 translations already exist
  and are cheap to carry over).

Open questions for the user before committing:
- Rust/Bevy or TypeScript/Babylon.js?
- Reuse ETR's course and audio assets (licence audit needed), or new content?
- Is desktop-native a target too, or browser-only?
- Faithful remake, or is redesigning gameplay (multiplayer, ghosts, procedural courses) in scope?

---

## 9. Gotchas found in the original worth not repeating

- `CheckItemCollection` is a full linear scan of every item on the course, per ODE substep.
- `FindYCoord` / `CheckTreeCollisions` use function-static caches — not thread-safe, and they leak
  state across course loads.
- `param.perf_level` gates features by integer (particles need `> 2`, track marks need `≥ 3`,
  high-res skybox needs `> 3`) rather than by measured performance.
- The finish sequence overrides gravity with a magic 500 N and forces the brake on.
- Texture ids in `textures.lst` are hardcoded integers referenced from C++.
- `trees.png` → `items.lst` conversion writes back into the data directory on first run.
- Terrain type matching is RGB-distance-within-30 against a 45-entry list; new terrains can silently
  collide with existing ones.

## Sources

- [Bevy + WebGPU](https://bevy.org/news/bevy-webgpu/) · [Bevy 0.19](https://bevy.org/news/bevy-0-19/) · [WebGL2+WebGPU in one wasm (#13168)](https://github.com/bevyengine/bevy/issues/13168) · [Bevy Cheat Book: WASM](https://bevy-cheatbook.github.io/platforms/wasm.html)
- [PlayCanvas Engine](https://github.com/playcanvas/engine) · [PlayCanvas compute shaders](https://developer.playcanvas.com/user-manual/graphics/shaders/compute-shaders/)
- [Babylon.js compute shaders](https://doc.babylonjs.com/features/featuresDeepDive/materials/shaders/computeShader) · [Babylon.js GPU particles](https://doc.babylonjs.com/features/featuresDeepDive/particles/particle_system/gpu_particles/) · [snowflow_demo — WebGPU/Babylon.js snow deformation](https://github.com/Noniv/snowflow_demo)
- [three.js WebGPURenderer manual](https://threejs.org/manual/en/webgpurenderer.html)
- [Godot web platform export](https://deepwiki.com/godotengine/godot-docs/7.4-web-platform-export) · [Godot WebGPU fork (unofficial)](https://godotwebgpu.com/)
- [Fyrox 1.0.0](https://fyrox.rs/blog/post/fyrox-game-engine-1-0-0/)
- [Real-time Interactive Snow Simulation using Compute Shaders (FDG 2020)](https://dl.acm.org/doi/10.1145/3402942.3402995) · [GDC 2014 — Deformable Snow Rendering in Batman: Arkham Origins](https://www.slideshare.net/slideshow/gdc2014-deformable-snow-rendering-in-batman-arkham-origins/32839706)
