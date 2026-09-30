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

## Where a course came from, which is the order the menu lists them in: the
## five Tux Racer shipped, then everything Extreme Tux Racer added — ETR's
## `default` and `extras` groups alike, see [constant
## CourseCatalog.TUXRACER_ORIGINALS] — then this project's own
## ([constant AUTHORED_GROUP]), then courses the player added by address
## ([ExternalCourses]).
enum Category { TUXRACER, ETR, PENGUINRACER, EXTERNAL }

## [member group] of a course authored for this project rather than imported
## from ETR — written by its generator, never by the importer.
const AUTHORED_GROUP := "penguinracer"

## Directory under `res://courses/`, and the identity used everywhere else.
@export var dir: String = ""
## ETR course group it was imported from — `default` or `extras` — or
## [constant AUTHORED_GROUP]. Between the first two, provenance only: ETR's
## `default` holds seventeen courses it added itself, so the menu groups by
## [method category], not by this.
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

## The http(s) address of the course's `.pck` for a course the player added,
## empty for every course this build ships. Never written by the importer: an
## external listing is built by [ExternalCourses] from its own file.
@export var source_url: String = ""
## The name the player filed an added course under — the header it is listed
## beneath. Empty for the build's own courses.
@export var server_name: String = ""

func title() -> String:
	return display_name if not display_name.is_empty() else dir

## Load the thumbnail. Called when a course is highlighted, not when the menu
## is built — see the note above.
func preview() -> Texture2D:
	if preview_path.is_empty() or not ResourceLoader.exists(preview_path):
		return null
	return load(preview_path) as Texture2D

func is_external() -> bool:
	return not source_url.is_empty()

func category() -> Category:
	if is_external():
		return Category.EXTERNAL
	if CourseCatalog.TUXRACER_ORIGINALS.has(dir):
		return Category.TUXRACER
	if group == AUTHORED_GROUP:
		return Category.PENGUINRACER
	return Category.ETR
