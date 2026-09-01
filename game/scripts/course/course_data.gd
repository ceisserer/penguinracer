## Course format v2. Replaces ETR's three colour-keyed PNGs plus `course.dim`.
##
## The heightmap is float32 and stores [b]local relief only[/b]; the global
## downhill slope is applied analytically at query time from [member base_angle].
## That keeps the float range on detail rather than a 500 m ramp, keeps long
## courses precise, and lets the slope be edited without touching the heightmap.
## See godot-port-plan.md §3.2.
@tool
class_name CourseData
extends Resource

@export_group("Identity")
## Display text, from the group's `courses.lst`. Course names and descriptions
## are authored per course and are not part of the translated UI string set —
## ETR does not translate them either.
@export var display_name: String = ""
@export var author: String = ""
@export var description: String = ""
@export var preview: Texture2D

@export_group("Terrain")
## FORMAT_RF float32 local relief in metres. Decoupled from the splat and
## object-placement resolutions, which the original locked together at ~1 m.
@export var heightmap: Image
@export var heightmap_size: Vector2i = Vector2i.ZERO
## Course extent in metres (width along +X, length along -Z).
@export var world_size: Vector2 = Vector2(90.0, 520.0)
## Peak-to-trough local relief in metres, for reference and re-import.
@export var height_scale: float = 7.0
## Global downhill slope in degrees, applied analytically.
@export var base_angle: float = 25.0
## RGBA8 layer weights; texture N covers layers 4N..4N+3.
@export var splat_maps: Array[Texture2D] = []
@export var splat_size: Vector2i = Vector2i.ZERO
@export var terrain_layers: Array[TerrainLayer] = []

@export_group("Gameplay")
@export var start_position: Vector2 = Vector2(45.0, 3.5)
## Metres from the start along -Z.
@export var finish_line_z: float = -470.0
## Play area in world XZ. Empty means "rectangle inset from world_size".
@export var play_bounds: PackedVector2Array = PackedVector2Array()
## Fallback rectangle when [member play_bounds] is empty.
@export var play_size: Vector2 = Vector2(85.0, 470.0)
@export var environment_preset: Resource
@export var music_theme: StringName = &"normal"
## Deceleration ramp after the finish line.
@export var finish_brake: float = 20.0
## Legacy `[use_keyframe]` — plays the canned finish animation.
@export var use_keyframe: bool = true

@export_group("Provenance")
## Set by the importer. Cleared when a designer edits the course in-editor,
## after which re-import refuses to overwrite without an explicit flag.
@export var imported_from: String = ""
@export var import_version: int = 0
@export var modified_in_editor: bool = false

## Rectangular play bounds as a polygon, matching the original's inset box.
func default_play_bounds() -> PackedVector2Array:
	var margin: float = (world_size.x - play_size.x) * 0.5
	var x0: float = margin
	var x1: float = world_size.x - margin
	return PackedVector2Array([
		Vector2(x0, 1.0),
		Vector2(x1, 1.0),
		Vector2(x1, -play_size.y - 20.0),
		Vector2(x0, -play_size.y - 20.0),
	])

func effective_play_bounds() -> PackedVector2Array:
	return play_bounds if not play_bounds.is_empty() else default_play_bounds()
