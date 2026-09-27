# Course editor plan — new tracks, placed props

Written 2026-09-26. A plan, not state: what is built goes in `PROGRESS.md`.

**Goal.** Let a designer create a new course from a heightmap and place arbitrary assets on it —
houses, rocks, huts — not only ETR's trees, shrubs, herring and flags. The heightmap stays the
base surface; it is proven and the physics depends on it.

## 1. Lessons from the `editor` branch (`52457fb`)

That branch is one commit on a `main` 20 commits older than today's. Do not merge it; it predates
`Forest`, `CourseLights` and the current `CourseRoot`. Take the lessons instead.

**Why the objects all stood at one height.** The heightmap stores local relief only; the fall line
is added analytically (`HeightmapSurface.height_at` = local + `slope * z`). The importer writes
every marker at `y = 0` (`tree_0` at `(45.5, 0, -520)` on Bunny Hill), and
`CourseRoot.build_runtime()` discards the stored Y and takes it from the surface. The branch's
`course_preview.gd` parented each preview mesh to its marker, so objects drew at the stored
`y = 0` while the terrain drew with the slope: ~240 m apart at the bottom of a 25°, 520 m course,
over 2 km on `the_long_ride` (30°, 4 km). **Snap markers to ground** was a one-off manual button;
any drag or new marker brought the bug back.

1. **Two code paths for placement drift.** Height, yaw and species were derived separately by the
   race and the preview. The preview even drew conifers as ETR's crossed cards, because `Forest`
   is skipped under `Engine.is_editor_hint()`.
2. **Y is derived, so the editor must enforce it on every change**, not offer it as a button.
3. **Hand edits were not protected.** `_protected()` fingerprints `course.tres` only; a re-import
   rewrites a hand-edited `course.tscn`.
4. **A node per object does not scale.** `the_long_ride` has ~8 000 `Marker3D`s; the preview added
   a `MeshInstance3D` to each.
5. **Scope was too wide and had no acceptance test.** 29 files, including editor side effects
   nobody asked for (`etr_menu.tres` lost its comments, `bumpy_ride/course.tscn` was rewritten,
   `.import` files churned). Nothing asserted "an object placed in the editor stands where the race
   draws it".

What it got right, and should be kept: preview nodes added with `INTERNAL_MODE_BACK` and no
`owner` are never packed into the scene; `course_preview.gd` loaded by path keeps the rendering
half out of `CourseRoot`'s compile-time class graph.

## 2. Phases

Each phase is small enough for one focused prompt and ends in a headless test.

### Phase 0 — ownership

- A course is **imported** (the importer owns it) or **authored** (`imported_from = ""`; the
  importer never touches it).
- For an imported ETR course that gets hand-edited, record provenance rather than observe it:
  hash the `Objects` subtree when the importer writes it, recompute on import, skip on mismatch
  without `--force` — the `import_fingerprint` pattern, extended to the scene.
- **The authoring surface is the Godot editor** (`EditorPlugin` + `@tool` scripts). An in-game
  editor for players (which would also work on the web) can come later on the same data format;
  it is a much bigger job and not needed to prove the format.

### Phase 1 — one placement function

- `CourseRoot.resolve_placement(node, prefab) -> Transform3D`: surface height + `ground_offset`,
  yaw (including `decorrelating_yaw`), scale, optional tilt to the slope. `build_runtime()`, the
  editor preview and every tool call only this.
- Objects become a small `@tool` `PlacedObject` node (`ground_offset`, `align_to_slope`, `sink`)
  that re-snaps its own Y on `NOTIFICATION_TRANSFORM_CHANGED` in the editor. The heightmap stays
  the authority; the saved file always agrees with it.
- **Test:** for all 44 courses, the editor path's transform equals the race's to within 1 mm.

### Phase 2 — a preview that is the race's picture

- The preview reuses `TerrainRenderer` and the Phase 1 batching, `Forest` included, streamed
  around the editor camera. Internal and unowned, as on the branch.
- The bulk of objects stay in batches; only the selection is drawn as a live proxy that follows
  the gizmo — not a node per object.
- Click-to-place: `EditorPlugin._forward_3d_gui_input`, ray-marched against
  `HeightmapSurface.height_at` (there is no terrain collider in the editor). A brush scatters
  trees over an area.
- **Test:** open, preview and save a course; the file is unchanged except for real edits. Check
  `git status` after every editor pass.

### Phase 3 — new course from a heightmap

- Input: 16-bit PNG, EXR or RAW, world size, base angle. Fit and subtract the slope plane to get
  local relief (float32, as `CourseData` expects).
- Write `heightmap.res`, bake `ambient_occlusion.res` (`TerrainOcclusion`), a default splat (all
  snow), start and finish, a skeleton `course.tscn`.
- Regenerate `resources/courses.tres` (`DirAccess` finds nothing in an export) and re-run
  `tools/gen_course_export_presets.py`.
- Sculpting and splat painting stay outside for now: round-trip through external tools (Krita,
  Gaea, …) and re-import. Much cheaper than in-editor brushes.

### Phase 4 — generic props

- Extend `ObjectPrefab` (or add a `PropPrefab`): mesh or `.glb` scene, collision shape
  (`CYLINDER` | `BOX`), footprint, `sink`, `snow_cover`.
- A glTF post-import script **replaces every imported material** with the prop shader (§3).
- Batches are cut into spatial cells with visibility ranges (reuse `Forest.cells_of`). Today
  `_add_batch` builds one course-wide `MultiMesh` per type: fine for quads, but a 5 000-triangle
  house batched that way is never culled.
- **Test:** every prop material's shader is in the allowed set, and every prop shader includes
  `atmosphere.gdshaderinc` (like `TestAtmosphere`).

### Phase 5 — collision for non-round objects

- `ObjectGrid` is cylinder-only. Add oriented boxes, and a box test in `RacePhysics` beside
  `_check_tree_collision` / `_adjust_tree_collision`, still with zero node dependencies (rule 1).
- The cylinder path stays bit-identical; the golden tests must not move.
- Riding *on* a roof, ramp or bridge needs `CompositeSurface` and is out of scope here.

### Phase 6 — props in the ground

- **Flatten under footprints:** bake a stamp into the heightmap at save time, so physics and
  pixels agree.
- **Contact AO:** bake footprints into the terrain's AO vertex colour, as the torches are baked.
  It matters most on the web, which has no shadows and where a house otherwise floats.
- **Snow on roofs:** whiten upward faces by snowfall grade, as the conifer shader does.

### Phase 7 — distribution

- Props go into a shared web pack (S6 streaming); each course pack names the props it needs.
- Multiplayer: the lobby carries a course hash so peers detect a mismatched custom course.

## 3. Shaders and scalability

**No shader-count explosion, provided every prop shares one shader family.** Godot compiles per
`Shader` (times a fixed set of internal variants: shadow pass, instancing, …), not per
`ShaderMaterial`. A hundred props differing only in textures and uniforms are one shader.

Today there is one custom shader per *kind of behaviour*, not per asset: the trees have bespoke
LOD cross-fades, impostors, sway and snow. Props are one more kind: `prop.gdshaderinc` (the
illumination clamp, `FOG`, torch glow, roof snow) included by `prop_opaque` and `prop_cutout`.
Opaque stays separate so a solid mesh skips the alpha test and keeps early depth.

The real risks:

1. **Unconverted glTF materials.** Each distinct feature combination of `StandardMaterial3D`
   generates its own shader — that is where an explosion would come from. Worse, they skip ETR's
   clamp and take the engine's flat fog instead of the atmosphere's `FOG`: they bleach in sun and
   become cut-out shapes against the far ridges (trap list, *a fully fogged surface*). Conversion
   at import is mandatory.
2. **Draw calls**, with the web as the floor: materials × surfaces × visible cells × passes. Keep
   one material per prop (atlas per prop set, or merge surfaces at import).
3. **Uber-shader branches.** Do not pile per-asset features (a turning windmill, a smoking
   chimney) into `if` branches of one shader — *a shader branch that is never taken still costs*.
   Use a few include-based variants.
4. **First-sight compile hitch** under Compatibility. Bounded with 2–3 prop shaders; draw each
   once during loading to warm it.
5. **Download size on the web**, from textures and meshes per prop.

Take a Compatibility draw-call and frame-time capture on a prop-heavy test course before building
a large prop library.
