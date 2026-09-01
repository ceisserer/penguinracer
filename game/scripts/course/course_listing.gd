## One row of the course menu: everything the shell needs to draw a course
## before anyone decides to load it.
##
## Deliberately holds no [CourseData] reference. A catalog that pointed at all
## 44 courses would pull every heightmap and splat texture into memory the
## moment the menu opened — the whole 128 MB pack, for a screen that shows a
## 192x144 thumbnail and a paragraph. Paths are resolved on demand instead.
@tool
class_name CourseListing
extends Resource

## Directory under `res://courses/`, and the identity used everywhere else.
@export var dir: String = ""
## ETR course group it was imported from — `default` or `extras`.
@export var group: String = "default"
@export var display_name: String = ""
@export var author: String = ""
@export var description: String = ""
@export var scene_path: String = ""
@export var course_path: String = ""
@export var preview_path: String = ""
## Course extent in metres (width along +X, length along -Z).
@export var world_size: Vector2 = Vector2.ZERO
## Global downhill slope in degrees.
@export var base_angle: float = 0.0

func title() -> String:
	return display_name if not display_name.is_empty() else dir

## Load the thumbnail. Called when a course is highlighted, not when the menu
## is built — see the note above.
func preview() -> Texture2D:
	if preview_path.is_empty() or not ResourceLoader.exists(preview_path):
		return null
	return load(preview_path) as Texture2D
