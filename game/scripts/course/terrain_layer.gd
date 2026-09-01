## One terrain material: gameplay parameters migrated verbatim from ETR's
## `data/terrains/terrains.lst`, plus the PBR maps the original never had.
##
## Up to 8 layers per course (2 RGBA splat textures). Surveyed ETR courses use
## 3–8 distinct terrain types, so the cap is not binding in practice — and it
## fixes the original's worst rendering bug, which re-rendered the whole terrain
## once per terrain type present (etracer.md §4.3).
@tool
class_name TerrainLayer
extends Resource

@export var id: StringName = &""

@export_group("Gameplay")
## 0.2 ice .. 0.7 rock. Migrated from `[friction]`.
@export_range(0.0, 1.0, 0.01) var friction: float = 0.35
## Metres the point mass sinks before the terrain spring engages. `[depth]`.
@export_range(0.0, 0.3, 0.001) var compression_depth: float = 0.05
## Whether carving throws up snow spray. `[part]`.
@export var emits_particles: bool = true
## Whether the surface deforms and holds a trench. `[trackmarks]`.
@export var takes_trackmarks: bool = true
@export var footstep_sound: AudioStream

@export_group("Rendering")
@export var albedo: Texture2D
@export var normal: Texture2D
@export var roughness: Texture2D
## World units per texture repeat. ETR generated UVs at 1/6 world scale.
@export var uv_scale: float = 6.0
## Snow deforms; rock does not.
@export var is_deformable: bool = true
## Migrated `[shiny]` flag — drives the specular/sparkle term.
@export var shiny: bool = false
## Original RGB colour key from terrain.png, kept for re-import diffing only.
@export var legacy_color: Color = Color.MAGENTA
