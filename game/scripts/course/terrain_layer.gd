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
## The looping slide effect this terrain plays under the player, named against
## [SoundBank]. ETR `[sound]`, which is a cue name there too — `TerrList[i].sound`
## is `Sound.GetSoundIdx` of it, resolved once at course load.
##
## Empty for 12 of the 43 records, including `snow` itself: the original rides
## the commonest surface in the game in silence, and only `dirty_snow` ever
## reaches `snow_sound`. `ice2` is silent while `ice1` is not. Migrated as it
## stands — it is one string per terrain to change, and inventing the missing
## ones is a design decision, not a port.
@export var slide_sound: StringName = &""

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
##
## This, not [member id], is what identifies a terrain in the original: a course
## paints colours and `CCourse::GetTerrainIdx` resolves them within ±30.
@export var legacy_color: Color = Color.MAGENTA
## The `[name]` this record carries in `terrains.lst`. Differs from [member id]
## only where the file declares one name twice — `pave04`, three times — which
## is legal there because nothing looks a terrain up by name.
@export var legacy_name: StringName = &""
## Position of the record in `terrains.lst`, which is the original's real terrain
## index (`TerrList[i]`). Kept for re-import diffing; nothing here indexes by it.
@export var legacy_index: int = -1

## Whether this layer should be shaded as ice rather than as snow or rock.
##
## ETR has no such flag: `[shiny]` is the closest thing, but the data only sets
## it on three of the five ice terrains — `hockey_ice` and `snowy_ice` are ice
## by every other measure and ship without it. The friction clause catches them:
## ETR gives every ice terrain `[friction] 0.2`, and nothing else in
## `terrains.lst` goes below 0.3. `icy_pave`/`icy_grass03` sit at 0.4 and are
## correctly excluded — they are frozen ground, not a frozen surface.
func is_ice() -> bool:
	return shiny or (friction <= 0.25 and not is_deformable)
