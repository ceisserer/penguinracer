## One row of `char/characters.lst`: everything the shell needs to offer a
## character before anyone decides to race as one.
##
## Deliberately holds no [PackedScene] reference, for the same reason
## [CourseListing] holds no [CourseData]: a catalog that pointed at all five
## rigs would pull five skinned meshes and twenty baked animations into memory
## the moment the menu opened, for a screen that shows a 128x128 thumbnail and
## a name. Paths are resolved on demand instead.
@tool
class_name CharacterListing
extends Resource

## Directory under `res://resources/characters/`, and the identity used
## everywhere else — it is what `penguinracer.cfg` stores and what `--character=`
## names. ETR's `[dir]` column.
@export var dir: String = ""
## ETR's `[name]` column: "Tux", "Trixi", "Boris", "Samuel", "Beastie". Not
## translated — the original does not translate them either, they are names.
@export var display_name: String = ""
## ETR's `[type]` column, `spheres` or `3d`. All five shipped characters are
## `spheres`; nothing in the original reads the column, and nothing here does
## either. Migrated so that the file is not silently lossy.
@export var shape_type: String = "spheres"
@export var scene_path: String = ""
@export var preview_path: String = ""

func title() -> String:
	return display_name if not display_name.is_empty() else dir

## Load the thumbnail — `char/<dir>/preview.png`, 128x128 in all five cases.
## Called when a character is highlighted, not when the menu is built.
func preview() -> Texture2D:
	if preview_path.is_empty() or not ResourceLoader.exists(preview_path):
		return null
	return load(preview_path) as Texture2D
