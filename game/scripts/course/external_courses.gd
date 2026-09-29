## Courses the player added by address: an http(s) URL of a course `.pck`, the
## same pack the streamed web build fetches for its own courses
## (`build/web/courses/<dir>.pck`, one `Course_<dir>` export preset each — see
## `tools/gen_course_export_presets.py`).
##
## [b]The entry is kept, the course is not.[/b] What survives a restart is one
## section of [constant PATH] per course — the address and the few lines the
## menu shows — never the pack. It is fetched again the first time the course
## is raced in a session, into [constant CACHE_DIR], which is emptied before
## the first fetch of every session. A course taken down at its address is
## therefore gone from the next session on, and one updated there is new.
##
## [b]The file name is the course.[/b] A pack built from `Course_<dir>` holds
## `res://courses/<dir>/…`, and nothing in a `.pck` can be listed before it is
## mounted, so the directory is read off the address: `…/tuxway.pck` must
## carry `res://courses/tuxway/course.tscn`, and [method add] refuses one that
## does not. A name this build ships is refused before anything is fetched.
##
## [b]A pack is code.[/b] A `.pck` can carry scripts, and a course scene can
## attach one, so adding an address trusts whoever serves it the way installing
## a mod does. Packs are mounted with `replace_files` off so that one cannot
## replace a file the build ships; that is the whole of the protection.
##
## Static and autoload-free, so the suite can call it (see the trap list on
## parse cycles).
class_name ExternalCourses
extends RefCounted

const PATH := "user://external_courses.cfg"
const CACHE_DIR := "user://cache/external"

## Why [method check_url] or [method add] refused: translation keys from
## `i18n/ui.csv`, empty for no problem.
const BAD_URL := "EXTERNAL_BAD_URL"
const BUILT_IN := "EXTERNAL_BUILT_IN"
const ALREADY_ADDED := "EXTERNAL_ALREADY_ADDED"
const NOT_A_COURSE := "EXTERNAL_NOT_A_COURSE"
const DOWNLOAD_FAILED := "EXTERNAL_DOWNLOAD_FAILED"

## Where the entries are kept. A variable only so the suite can point it at a
## scratch file and leave the player's own list alone.
static var store_path: String = PATH

## Course directories whose pack is mounted in this session.
static var _mounted: Dictionary[String, bool] = {}
static var _cache_cleared: bool = false

## Every course the player has added, as menu rows, in the order added.
static func listings() -> Array[CourseListing]:
	var out: Array[CourseListing] = []
	var cfg := _load_store()
	for dir: String in cfg.get_sections():
		var url: String = str(cfg.get_value(dir, "url", ""))
		if url.is_empty() or dir_for_url(url) != dir:
			continue
		var listing := _listing(dir, url)
		listing.display_name = str(cfg.get_value(dir, "name", ""))
		listing.author = str(cfg.get_value(dir, "author", ""))
		listing.description = str(cfg.get_value(dir, "description", ""))
		listing.world_size = cfg.get_value(dir, "world_size", Vector2.ZERO)
		listing.base_angle = float(cfg.get_value(dir, "base_angle", 0.0))
		out.push_back(listing)
	return out

## The course directory `url` names — its file name without `.pck` — or empty
## if it is not an http(s) address of a `.pck` with a plain name.
static func dir_for_url(url: String) -> String:
	var u: String = url.strip_edges()
	var lower: String = u.to_lower()
	if not (lower.begins_with("http://") or lower.begins_with("https://")):
		return ""
	u = u.get_slice("#", 0).get_slice("?", 0)
	# `get_file` of `https://host` is the host itself; a pack needs a path.
	if u.substr(u.find("://") + 3).find("/") < 0:
		return ""
	var file: String = u.get_file()
	if file.get_extension().to_lower() != "pck":
		return ""
	var dir: String = file.get_basename()
	var name_re := RegEx.create_from_string("^[A-Za-z0-9_-]+$")
	return dir if name_re.search(dir) != null else ""

## What is wrong with adding `url` before anything is fetched: one of the
## refusal keys above, or empty.
static func check_url(url: String) -> String:
	var dir: String = dir_for_url(url)
	if dir.is_empty():
		return BAD_URL
	if CourseCatalog.load_default().find(dir) != null:
		return BUILT_IN
	if _load_store().has_section(dir):
		return ALREADY_ADDED
	return ""

## Fetch the pack at `url`, check it is the course its name says, and keep the
## entry. Returns the new row, or a refusal key (String) — one of the constants
## above. `on_progress` as in [method PackStream.ensure].
static func add(url: String, on_progress: Callable = Callable()) -> Variant:
	var refusal: String = check_url(url)
	if not refusal.is_empty():
		return refusal
	url = url.strip_edges()
	var dir: String = dir_for_url(url)
	var listing := _listing(dir, url)
	var err: Error = await ensure(listing, on_progress)
	if err == ERR_FILE_UNRECOGNIZED:
		return NOT_A_COURSE
	if err != OK:
		return DOWNLOAD_FAILED
	var course: CourseData = load(listing.course_path) as CourseData
	if course == null:
		return NOT_A_COURSE
	listing.display_name = course.display_name
	listing.author = course.author
	listing.description = course.description
	listing.world_size = course.world_size
	listing.base_angle = course.base_angle

	var cfg := _load_store()
	cfg.set_value(dir, "url", url)
	cfg.set_value(dir, "name", listing.display_name)
	cfg.set_value(dir, "author", listing.author)
	cfg.set_value(dir, "description", listing.description)
	cfg.set_value(dir, "world_size", listing.world_size)
	cfg.set_value(dir, "base_angle", listing.base_angle)
	cfg.save(store_path)
	return listing

## Forget a course. Its pack stays mounted until the game quits — Godot cannot
## unmount one — and its cached copy goes with the next session's clear-out.
static func remove(dir: String) -> void:
	var cfg := _load_store()
	if not cfg.has_section(dir):
		return
	cfg.erase_section(dir)
	cfg.save(store_path)

## Make the course behind `listing` loadable: fetch and mount its pack unless
## this session already has. `OK`, [constant ERR_FILE_UNRECOGNIZED] for a pack
## that is not the course its name says, or the download's error.
static func ensure(listing: CourseListing, on_progress: Callable = Callable()) -> Error:
	if _mounted.get(listing.dir, false):
		return OK
	_clear_cache_once()
	var err: Error = await PackStream.fetch_and_mount(listing.source_url,
		CACHE_DIR.path_join("%s.pck" % listing.dir), on_progress, false)
	if err != OK:
		return err
	if not (ResourceLoader.exists(listing.scene_path)
			and ResourceLoader.exists(listing.course_path)):
		return ERR_FILE_UNRECOGNIZED
	_mounted[listing.dir] = true
	return OK

## Whether this session has the course's pack mounted — the menu shows a
## preview only then.
static func is_mounted(dir: String) -> bool:
	return _mounted.get(dir, false)

static func _listing(dir: String, url: String) -> CourseListing:
	var listing := CourseListing.new()
	listing.dir = dir
	listing.group = "external"
	listing.source_url = url
	listing.scene_path = "res://courses/%s/course.tscn" % dir
	listing.course_path = "res://courses/%s/course.tres" % dir
	listing.preview_path = "res://courses/%s/preview.png" % dir
	return listing

static func _load_store() -> ConfigFile:
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(store_path):
		cfg.load(store_path)
	return cfg

## Packs from an earlier session are not kept (see the class note). Once per
## session and before the first fetch, so nothing mounted is ever deleted.
static func _clear_cache_once() -> void:
	if _cache_cleared:
		return
	_cache_cleared = true
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return
	for file: String in dir.get_files():
		dir.remove(file)
