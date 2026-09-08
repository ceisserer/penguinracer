# materials.md — how a terrain material works

A *material* here is one entry from ETR's `data/terrains/terrains.lst`: snow, dirty snow, ice1,
rock, mud, pave04. It carries both halves of a surface's identity — how it drives and how it
looks — and every one of the 43 of them is a single [`TerrainLayer`](game/scripts/course/terrain_layer.gd)
resource on disk.

The two halves take different routes. Friction never reaches the GPU, and no shader uniform is
ever read by the simulation; the only thing the two paths share is the splat map that says which
material is where. This document traces both routes end to end, then answers whether Godot's
editor can be used to author them.

Companion to [`godot-port-plan.md`](./godot-port-plan.md) §3.2 (course format), §4.2 (surface
queries) and §4.4 (terrain rendering). Behaviour that is a deliberate departure from the original
is marked **DEVIATION**, as in the source.

---

## 1. Where a material lives

```
etr-0.8.4/data/terrains/terrains.lst      43 records, read-only
        │  addons/etr_import/etr_import.gd :: import_terrains()
        ▼
game/resources/terrain/<id>.tres          43 TerrainLayer resources — ONE GLOBAL LIBRARY
        │                                  shared by reference across all 44 courses
        ├─────────────────────────────┐
        ▼                             ▼
game/courses/<name>/course.tres      game/courses/<name>/splat_0.png [, splat_1.png]
  terrain_layers: Array[TerrainLayer]   RGBA8 weights, channel N = terrain_layers[N]
  (≤ 8, POSITIONAL)                     built by etr_import.gd :: build_splat()
        │
        ├──────────────────────────────────────────┐
        ▼ physics                                  ▼ rendering
HeightmapSurface.set_splat()                TerrainRenderer._build_material()
  pre-blends friction + depth per texel       per-layer uniform tables + 8 albedo samplers
  → SurfaceSample → RacePhysics               → shaders/terrain.gdshader
```

Three properties of this layout matter and are easy to get wrong:

- **A layer is identified by its record, not by its `[name]`.** `terrains.lst` declares `pave04`
  three times with three textures and three colour keys. The importer keys on the record and
  disambiguates by texture stem; `legacy_name` and `legacy_index` point back at the file. See the
  trap list in [`AGENTS.md`](./AGENTS.md).
- **The library is global.** `course.tres` holds `ExtResource` references to
  `res://resources/terrain/snow.tres`. There is no per-course copy and no override mechanism:
  changing snow's friction changes it on all 44 courses.
- **A course's layer array is positional.** `terrain_layers[3]` is the alpha channel of
  `splat_0.png` and nothing else. Reordering the array repaints the course.

### 1.1 Why 43 records and not three

Asked from the other direction: three types — snow, ice, rock — would cover everything the game
actually simulates, so why does the file carry seven kinds of ice?

Because a record in `terrains.lst` is not a material *class*. It is one colour key bound to one
texture, plus the handful of numbers that colour key drives. ETR's `TTerrType` has no name field
and no notion of a family: a course paints RGB into `terrain.png`, `GetTerrainIdx` scans the list
for the first entry within ±30 on every channel, and whatever it lands on supplies both the
friction and the picture. So the only way to offer a course author a second ice texture is to
declare a second ice record. Seven ice records means seven ice *textures* — `ice.png`, `ice01`,
`ice02`, `ice03`, and the three `snowy_ice*` variants, which are the same surfaces with snow
dusted over them for courses set in deeper winter.

The simulation behind them is much smaller than the list:

| | records | distinct gameplay |
|---|---|---|
| the file | 43 | 22 tuples of `[friction] [depth] [sound] [part] [trackmarks]`, over 7 friction values |
| ice | 7 | **1** — all seven are `[friction] 0.2 [depth] 0.03`, no spray, no trackmarks; only `ice2`'s missing `[sound]` tells any of them apart |
| rock | 8 | **1** — all `[friction] 0.7 [depth] 0.01 [sound] rock_sound` |
| snow | 4 | 4 — the one family the numbers really do separate (0.35/0.11, 0.4/0.07, 0.4/0.05, 0.3/0.04) |

Two more things fall out of the colour-key design and are easy to mistake for a taxonomy:

- **`icy_*` is not ice.** `icy_pave`, `icy_grass03`, `icy_grass04` and `icy_forest_floor` are at
  0.4–0.5 — frozen *ground*, not a frozen surface — which is why `is_ice()` (§4.2) keys on
  friction ≤ 0.25 and correctly leaves them out. `snowy_*` is the same idea: a dusted repaint of
  an existing surface, usually one friction step slipperier.
- **Some records are barely addressable.** `snow`, `dirty_snow`, `thin_snow` and `strike_snow` sit
  within ±30 of each other, and the scan is first-match-wins, so a course that paints
  `230 230 255` gets `snow` rather than the `dirty_snow` it named. That is the original's
  behaviour, reproduced in `match_terrain()`, warned about at import.

And the shipped content bears the question out. Of the 43 records, **10 are painted by any of the
44 courses**, and the distribution is exactly the three-type intuition:

```
ice1  42 courses     snow        41     rock    35   rock06  18   rock04  16
                     dirty_snow   1     rock01  13   rock02   1   rock05   1   snowy_rock06  1
```

One ice record. One snow record plus a near-twin. Four rock textures. The other 33 records are
texture options no shipped course took up.

They are all migrated anyway, one `TerrainLayer` each. The cost is 33 unreferenced 1 KB resources
— they are not loaded by any course, so they cost nothing at runtime — and the return is that
`terrains.lst` stays traceable record for record (§1), that a hand-made or third-party course
painting `0 90 120` still gets green ice, and that the importer never has to decide which of two
records with the same friction is "the real one". Collapsing by name is precisely the bug that
cost a phase: three different records are all called `pave04`.

Meanwhile the renderer *does* collapse them, to exactly the three the question proposes:
`layer_snowness` and `layer_iceness` are the only per-layer classification the shader has (§4.3),
everything else is albedo, and the physics reduces the whole file to one continuous friction
scalar. The 43 is the lookup table; the three are what the game runs on.

---

## 2. The fields, and who reads them

| `TerrainLayer` field | ETR source | How it blends | Consumer |
|---|---|---|---|
| `friction` | `[friction]` | weighted mean | `SurfaceSample.friction` → four forces |
| `compression_depth` | `[depth]` | weighted mean | `SurfaceSample.compression_depth` → normal force |
| `emits_particles` | `[part]` | dominant layer | `SprayEmitter.emit_for_substep()` |
| `takes_trackmarks` | `[trackmarks]` | dominant layer | `RaceScene._on_substep()` — the deformation stamp |
| `slide_sound` | `[sound]` | dominant layer | `RaceScene._update_slide_sound()` |
| `albedo` | `[texture]` | weighted mean of texels | `albedo_0..7` samplers |
| `is_deformable` | `= [trackmarks]` | weighted mean of the flag | `layer_snowness` → wrap, micro-relief, glint |
| `shiny` + `friction` | `[shiny]`, via `is_ice()` | weighted mean of the flag | `layer_iceness` → reflection, gloss, albedo cut |
| `roughness` | new, seeded from `is_ice()` | weighted mean | `layer_roughness` |
| `uv_scale` | new (ETR hardcoded 1/6) | per layer | `layer_uv_scale` |
| `legacy_color` | `[col]` | — | importer only: colour-key matching, re-import diffing |
| `legacy_name`, `legacy_index` | `[name]`, position | — | importer and `test_terrain_library.gd` |

Everything in the "Gameplay" group is migrated verbatim in `import_terrains()` — those numbers
are tuned balance data and are the part of ETR worth being exact about. The "Rendering" group has
no source at all: ETR draws every terrain as flat textured diffuse, so `roughness` and `uv_scale`
are authored here and seeded by the importer with values that reproduce what the renderer used to
hardcode.

---

## 3. The friction path (CPU)

### 3.1 Pre-blending at load

`HeightmapSurface.set_splat()` runs once per course load. For every heightmap texel it collapses
the whole layer table down to two floats and three bytes:

```
friction[i] = Σ w_l · layer_l.friction / Σ w_l
depth[i]    = Σ w_l · layer_l.compression_depth / Σ w_l
dominant[i] = argmax_l w_l          # and its particles/trackmarks flags
```

**DEVIATION (and the one that bought Phase 0 its headroom):** ETR blends friction *per query*,
barycentrically across the triangle under the player (`etracer.md` §4.2). Pre-blending is exactly
equal — splat blending and bilinear filtering are both linear, so interpolating the pre-blended
scalar equals interpolating the weights and then dotting with the table — but it turns up to 32
multiply-adds per query into 4. The ODE solver makes three force evaluations per accepted step and
each one samples the surface, so this is on the hottest path in the game.

The weights come from `_decode_splat()`, which nearest-resamples the RGBA8 splat textures onto the
heightmap grid. Today the importer writes both at the same resolution, so the resample is an
identity; the code does not assume that, because the v2 format deliberately decouples them.

### 3.2 Per-query

`sample_into()` bilinearly interpolates the four pre-blended texels around the query point for
`friction` and `compression_depth`, and takes the *nearest* texel for `terrain_id`,
`emits_particles` and `takes_trackmarks`. Continuous quantities blend; discrete ones snap. A
half-and-half blend of ice and snow has a meaningful friction and does not have a meaningful
slide sound.

Then `SnowField.apply_to_sample()` modulates what the material declared, by how packed the snow
under the player is:

```
friction          = max(0.05, friction + packed_friction_delta · pack)   # delta = -0.10
compression_depth = compression_depth · lerp(1, packed_depth_scale, pack)
```

**DEVIATION:** packed snow *lowers* friction, so a trench is fast and racing lines matter. Plan
§4.3 originally said "raise", which was a wording error — in this force model friction scales a
retarding force, so lower is faster. Corrected 2026-08-31.

### 3.3 What actually reads it

`RacePhysics.calc_net_force()` copies the sample into `_ff_frict_coeff` / `_ff_comp_depth` before
the fixed force order runs. Four forces then read the coefficient:

| Force | Use |
|---|---|
| `calc_friction_force` | `min(MAX_FRICT_FORCE, ‖N‖ · μ)` opposing velocity, then rotated about the surface normal by `turn_fact × 45°` — **this rotation is how steering works**, so friction is also the steering authority |
| `calc_brake_force` | `μ · BRAKE_FORCE` along the friction direction |
| `calc_roll_normal` | banking angle is attenuated by `min(1, μ / IDEAL_ROLL_FRIC)` — you cannot carve on ice |
| `calc_paddle_force` | paddling scales by `min(1, μ / IDEAL_PADD_FRIC)` — flippers need something to push against |

`compression_depth` has one consumer, `calc_normal_force()`: it is how far the point mass sinks
before the piecewise terrain spring engages at all. Snow's 0.11 m against ice's 0.03 m is most of
why the two feel different before any friction is involved.

Nothing on this path knows about textures, and nothing on the rendering path knows about friction —
except indirectly, through `is_ice()`, which uses the friction value as evidence about what a
surface *is*.

---

## 4. The shading path (GPU)

### 4.1 One material, built in code

`TerrainRenderer._build_material()` constructs a single `ShaderMaterial` per course load and
assigns it as `material_override` on every terrain chunk. It is never serialised; it exists only
while a race is loaded. What it uploads from the layer table:

- `albedo_0` … `albedo_7` — the per-layer `albedo` textures. This is the only per-layer *texture*
  the shader has.
- `layer_count`, `world_size`, `splat_0`, `splat_1`, `uv_scale`.
- three per-layer scalar tables, each split into a `vec4` low half and a `vec4` `_hi` half:

| Uniform | Source | Values |
|---|---|---|
| `layer_roughness` / `_hi` | `TerrainLayer.roughness` | authored; importer seeds `0.25` for ice, `0.85` otherwise |
| `layer_uv_scale` / `_hi` | `TerrainLayer.uv_scale` | metres per texture repeat, `6.0` throughout the migrated set |
| `layer_snowness` / `_hi` | `is_deformable` | `1.0` / `0.0` |
| `layer_iceness` / `_hi` | `is_ice()` | `1.0` / `0.0` |

The split exists because GLSL ES 3.0 gives no `float[8]` uniform worth relying on, and a pair of
`vec4`s indexes for free against the two splat textures' weights. Filling only the low half was a
real bug: eight-layer courses got "rough, not snow, not ice" for their last four terrains, visible
as a slope that stops sparkling halfway across a blend.

Two of the four are authored and two are derived. "Snowness" is `is_deformable`, which the
importer sets equal to `[trackmarks]`; "iceness" is `TerrainLayer.is_ice()`. Roughness and the UV
scale come off the layer, so a terrain that wants to be rougher than its neighbours, or to tile at
a different rate, can say so without a code change.

### 4.2 `is_ice()` — why it is not `[shiny]`

```gdscript
func is_ice() -> bool:
    return shiny or (friction <= 0.25 and not is_deformable)
```

**DEVIATION.** ETR has no ice concept: `[shiny]` is the closest thing, and it is set on three of
the seven ice terrains — `ice1`, `ice2`, `greenice`. `hockey_ice`, `snowy_ice`, `snowy_greenice`
and `snowy_hockey_ice` ship without it, so the friction clause is carrying the majority of the
set, not a couple of stragglers. It catches them because all seven are `[friction] 0.2` and the
next lowest terrain in the file is 0.3 — there is nothing in the gap for the `≤ 0.25` threshold to
pick up by accident. `icy_pave` and `icy_grass03` sit at 0.4 and are correctly excluded: they are
frozen ground, not a frozen surface. This is the one place where a gameplay number feeds a
rendering decision, and `test_terrain_library.gd` pins the counts so the clause cannot quietly
stop working.

### 4.3 Blending in the fragment shader

```glsl
w0 = texture(splat_0, splat_uv);  w1 = layer_count > 4 ? texture(splat_1, splat_uv) : 0;
w0 /= total;  w1 /= total;                       // renormalise

ALBEDO     = Σ texture(albedo_N, world_pos.xz / layer_uv_scale[N]) · w[N];
snow_mask  = clamp(dot(layer_snowness, w0) + dot(layer_snowness_hi, w1), 0, 1);
ice_mask   = clamp(dot(layer_iceness,  w0) + dot(layer_iceness_hi,  w1), 0, 1);
ROUGHNESS  = mix(dot(layer_roughness, w0) + dot(layer_roughness_hi, w1), ice_roughness, ice_mask);
```

Two masks, computed once, and everything material-dependent downstream is gated on them:

| Term | Gate | What it does |
|---|---|---|
| micro-relief, fine octave | `snow_mask + ice_mask · ice_relief_scale` | wind crust, ~8 mm, faded by 22 m |
| micro-relief, coarse octave | `snow_mask` | wind-stretched drifts (sastrugi), ~5 cm, faded by 90 m |
| crystal glint | `snow_mask` | per-texel facet normals + a sharp lobe in `light()` |
| wrap lighting | `snow_mask` | half-Lambert, standing in for the subsurface scattering Compatibility has no SSS for |
| sky reflection (`EMISSION`) | `ice_mask` | Fresnel-weighted two-colour ramp |
| sun glare | `ice_mask` | tight lobe on the same Fresnel weight |
| albedo cut (`ice_albedo` 0.82) | `ice_mask` | makes the additive ice terms visible at all |
| trench albedo/roughness/AO/ridge | `snow_mask` | the trail map only affects snow |

Note that roughness reaches the surface twice: through the per-layer table (0.25 for ice) and
again through `mix(..., ice_roughness, ice_mask)`, which pulls it to 0.12. The table value is what
a *partial* ice blend contributes; the mix is what full ice ends at.

Because the masks are dot products of the splat weights, a blend behaves sensibly: 40 % ice over
rock gets 40 % of a reflection, not a hard switch.

### 4.4 The discrete three

`slide_sound`, `emits_particles` and `takes_trackmarks` are not blended and never reach the GPU.
They resolve through `SurfaceSample.terrain_id`, the dominant layer at the contact point:

- **Sound** — `RaceScene._update_slide_sound()` looks the cue up in
  `course_data.terrain_layers[terrain_id]`. **DEVIATION:** ETR used
  `Course.GetTerrainIdx(x, z, 0.5)`, the type holding at least half the blend *or nothing*. Ours
  always resolves to a layer, so the cue changes slightly earlier across a boundary and a blend of
  two noisy terrains is never silent. The slide has no speed or lean term, faithfully: ETR wrote
  `SlideVolume` and shipped it commented out. 12 of the 43 records name no `[sound]` at all,
  `snow` included.
- **Spray** — `SprayEmitter.emit_for_substep()` returns early unless `emits_particles`.
- **Deformation** — `RaceScene._on_substep()` stamps the snow field only where
  `takes_trackmarks`. These are two different flags and `strike_snow` is where they disagree: it
  sprays but holds no track. Gating the stamp on `[part]` instead was a real bug that no test
  caught, because the tests asserted only what the consumer consumed.

---

## 5. What looks per-material but is not

- **`albedo` is the only per-layer texture, and the only one there is room for.** WebGL2 guarantees
  16 fragment texture units and `terrain.gdshader` binds 13: two splat maps, eight albedos, the
  trail map, the detail map and the sparkle noise. Eight per-layer normal maps would need 21.
  `TerrainLayer` used to carry `normal` and `roughness` as `Texture2D` exports that no importer
  wrote and no sampler read — assigning one in the Inspector did nothing at all. Both are gone;
  relief comes from the shared procedural detail field, and roughness from the scalar table.
- **Every tuning uniform in the `Surface_Detail`, `Snow_Shading` and `Ice_Shading` groups** is
  global to the course: relief amplitudes, fade distances, wind direction and stretch, sparkle
  scale/spread/sharpness, `specular_f0`, `ice_reflection`, `ice_gloss`, `ice_albedo`. Snow is snow
  everywhere. Per-layer versions would mean four more `vec4` pairs each.
- **`sky_zenith` / `sky_horizon`**, what the ice reflects, come from the course's
  `EnvironmentPreset` via `TerrainRenderer.set_sky_tint()`, not from any layer.
- **`shiny`** has no independent effect; its only reader is `is_ice()`.
- **`[starttex]`, `[tracktex]`, `[stoptex]`** — ETR's per-terrain track-mark decal textures — are
  not migrated at all. The trench here is geometry plus a shader, not a decal atlas.

### The 8-layer cap

Two RGBA8 splat textures is a hard format limit. `build_splat()` counts how many terrain types a
course actually paints, sorts them by area, and gives the top 8 a channel each. Anything past that
is merged into the nearest-coloured surviving layer, with a warning — the course then plays
approximately right instead of silently becoming its dominant terrain. Surveyed ETR courses use
3–8 types, so the cap has not yet bound.

At resource-build time, a layer whose `.tres` fails to load **keeps its slot** and gets a default,
with a warning. Dropping it would slide every later layer onto the wrong channel, and the course
would load, render fine, and play the wrong friction under the right texture.

---

## 6. Can Godot's editor be used to assign these?

Partly. The **Inspector** is a first-class authoring surface for the material parameters
themselves. The **3D viewport** is not, for terrain — there is nothing there to click.

### What works today

**Editing a material's parameters — yes.** `TerrainLayer` is `@tool` with `@export` on every
field, so `res://resources/terrain/snow.tres` opens in the FileSystem dock and edits in the
Inspector like any resource: friction, compression depth, the particle/trackmark flags, the slide
sound, `shiny`, and the albedo texture. Two caveats:

- It is **global**. That file is referenced by every course that paints snow. There is no
  per-course override.
- Nothing updates live. `HeightmapSurface.set_splat()` pre-blends and
  `TerrainRenderer._build_material()` uploads at course load, so a change takes effect the next
  time the course is loaded — press Play, or reselect the course from the in-game menu.

**Choosing which materials a course uses — yes, with care.** `courses/<name>/course.tres` opens in
the Inspector and `terrain_layers` is an editable `Array[TerrainLayer]`. Swapping element 2 from
`rock` to `mud` repaints and re-frictions every pixel that splat channel 2 covers, which is a
legitimate and cheap way to re-theme a course. Reordering the array is almost never what you want:
the array index *is* the splat channel.

**Course objects — yes, fully.** `courses/<name>/course.tscn` opens in the 3D viewport with an
`Objects` subtree of `Marker3D`s, one per tree and herring, with editable position, rotation and
scale; `CourseRoot.build_runtime()` bakes them into `MultiMesh` batches and `ObjectGrid`s at load.
The per-object `ShaderMaterial`s are sub-resources saved *in that scene*, so their uniforms —
`albedo_tint`, `alpha_scissor`, `normal_roundness` — do appear in the Inspector and are editable.
There are two shaders behind them and which one an object gets is decided by `[coll]`, not by
taste: a collidable type (every tree, and the shrub) is `object_cross.gdshader` over the two fixed
planes at 90° the original draws, and everything else is `object_billboard.gdshader` over a single
camera-facing quad. Pointing a tree at the billboard makes it swivel with the camera; pointing a
herring at the cross makes it vanish edge-on. Terrain has no equivalent, which is the next point.

**And an edit survives the next import — yes, now.** This used to be the reason not to author
anything here. `CourseData.modified_in_editor` existed and `import_course()` checked it, but
nothing ever set it to `true`: the importer was its only writer and only ever wrote `false`, so
the guard had never fired once. `import_terrains()` had no check at all and `ResourceSaver.save`d
all 43 layers unconditionally, which meant an Inspector edit to a material survived exactly until
somebody ran `import_all.sh`.

It cannot be fixed by watching the editor. GDScript's `_set` is never called for script-declared
exports, a property setter cannot tell an Inspector edit from a `.tres` being loaded, and there is
no `EditorPlugin` in this project. So provenance is recorded rather than observed: both
`TerrainLayer` and `CourseData` carry an `import_fingerprint`, a hash of everything the importer
wrote, and `edited_since_import()` recomputes it. A file that no longer matches was changed by
something that was not the importer, and `_keep_edited()` leaves it alone:

```
$ ./tools/import_all.sh
  terrain layer 'snow': kept, edited outside the importer (use --force to overwrite)
$ ./tools/import_all.sh --force
  ... overwritten
```

This protects any edit route, not just the Inspector — an external text edit or a merge is caught
the same way. Storing the hash, rather than comparing the file against a freshly imported record,
is what separates "a human edited this" from "the importer's own migration logic changed": the
latter would otherwise make all 43 layers look hand-edited on every importer improvement.
`modified_in_editor` remains as an explicit hands-off flag for a course whose edits are not made
yet. An empty fingerprint means unknown provenance and counts as unedited, so the mechanism
adopted the existing tree instead of freezing it.

### What does not work

**There is no terrain in the editor viewport.** Opening `course.tscn` shows the object markers
floating in empty space. `TerrainRenderer` is not a node in any scene: `RaceScene.load_course()`
constructs it in code, and it builds its chunk meshes from `HeightmapSurface` at runtime. So you
cannot select the ground, cannot see the splat blend, and cannot judge a material change without
running the game. `tools/shot.sh` and the `--capture=` flag exist precisely because this is the
only way to look at the terrain.

**Terrain shader uniforms are not exposed anywhere.** The `ShaderMaterial` is built in
`_build_material()` and thrown away at course unload; it is never saved to a `.tres` or a `.tscn`,
so it has no Inspector row. Tuning `detail_relief_coarse`, `sparkle_sharpness`, `ice_albedo`,
`wrap_amount` or `trail_normal_strength` means editing the default in
[`shaders/terrain.gdshader`](game/shaders/terrain.gdshader) — every one of them is documented in
place with its units — or adding a `set_shader_parameter` in `terrain_renderer.gd`. There is no
material asset to drag onto anything.

**The splat map cannot be painted.** `splat_0.png` is generated by `build_splat()` from ETR's
colour-keyed `terrain.png` — one-hot at the heightmap resolution, then boundary-blurred so a
designer inherits something paintable rather than an index map. But nothing in this project paints
it. Editing means an external image editor and a re-import that respects the change, and there is
no such guard for splat PNGs today.

**Per-layer visual overrides beyond roughness and tiling are not expressible.** The shader has four
per-layer slots and two of them are computed. Making a layer, say, glint harder than other snow
needs a new table: an export on `TerrainLayer`, a fifth `vec4`/`vec4 _hi` pair, a line in
`_set_layer_table()` and a dot product in the fragment shader. That is the extension point, and
`layer_roughness` is the worked example of it.

### Recipes

*Make ice slipperier everywhere:* open `res://resources/terrain/ice1.tres`, set `friction`, repeat
for the other six ice layers. The edit now survives re-import on its own; if you want it to be the
*migrated* value rather than an override, change `import_terrains()` too and re-import with
`--force`. Either way run the suite — `test_forces.gd` asserts per-force golden values against
friction, and `test_terrain_library.gd` cross-checks every layer against `terrains.lst`.

*Make an existing layer shade as ice:* set `shiny = true` on its `.tres`, or give it
`friction ≤ 0.25` with `takes_trackmarks = false`, which also clears `is_deformable`. Both routes
go through `is_ice()`; the flag is the honest one, since the friction route changes how it drives.

*Add a genuinely new material:* write a `TerrainLayer` `.tres` into `resources/terrain/`, append
it to a course's `terrain_layers` (≤ 8), and write weights into the matching splat channel. The
importer will not do the last step for you — there is no ETR colour key for a terrain ETR does not
have.

---

## 7. Known gaps

- No **per-course** material overrides. The terrain library is global by reference, so a course
  cannot have its own snow without its own `TerrainLayer` resource, and nothing generates one.
- No per-layer control over the snow/ice shading uniforms — micro-relief, glint and the ice terms
  are course-global. `layer_roughness` and `layer_uv_scale` show what adding one costs.
- Per-layer **normal maps** are out of reach under Compatibility (§5), so all surface relief on the
  terrain comes from one shared procedural field. Every snow layer therefore has identical
  micro-structure; only the albedo distinguishes them close up.
- The splat map is generated and unpaintable, and unlike the resources it has no provenance guard —
  an edited `splat_*.png` is still overwritten silently by a re-import.
- Snow tone is matched on one course under one environment (Bunny Hill / `tuxracer_sunny`). The
  material tables cover all eight splat slots; the *tuning* behind them has been compared against
  the original in exactly one lighting condition. All 44 shipped courses do select a sunny preset
  and the two sunny presets carry identical light values, so the one condition is the shipped one
  — but see PROGRESS.md's known gaps for what the other four presets are worth now.
