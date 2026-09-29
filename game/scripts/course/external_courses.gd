## Courses the player added by address, each filed under a server name the
## player gives. An address is one of two things:
##
## - [b]a course[/b]: the http(s) URL of a course `.pck`, the same pack the
##   streamed web build fetches for its own courses (`build/web/courses/<dir>.pck`,
##   one `Course_<dir>` export preset each — see
##   `tools/gen_course_export_presets.py`). It is fetched on the spot and checked.
## - [b]a folder[/b]: any other http(s) URL. The folder's [constant INDEX_FILE]
##   (or the `.json` named outright) lists its courses — see [method
##   parse_index] for the format, and `tools/gen_course_index.py`, which writes
##   one for a directory of packs. Every course it lists that this game does
##   not have yet is added from the index alone; no pack is fetched until the
##   course is raced.
##
## [b]The entry is kept, the course is not.[/b] What survives a restart is one
## section of [constant PATH] per course — the address, the server name and the
## few lines the menu shows — never the pack. It is fetched again the first time
## the course is raced in a session, into [constant CACHE_DIR], which is emptied
## before the first fetch of every session. A course taken down at its address
## is therefore gone from the next session on, and one updated there is new.
##
## [b]The file name is the course.[/b] A pack built from `Course_<dir>` holds
## `res://courses/<dir>/…`, and nothing in a `.pck` can be listed before it is
## mounted, so the directory is read off the address: `…/tuxway.pck` must
## carry `res://courses/tuxway/course.tscn`, and [method ensure] refuses one
## that does not. The directory is also the course's identity everywhere, so a
## name this build ships, or one already added from any server, is not added.
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
## What a folder address is asked for.
const INDEX_FILE := "courses.json"
## Longest server name kept; the menu shows it on a header row.
const MAX_SERVER_NAME := 40

## Why [method check] or [method add] refused: translation keys from
## `i18n/ui.csv`, empty for no problem.
const NO_SERVER_NAME := "EXTERNAL_NO_SERVER_NAME"
const BAD_URL := "EXTERNAL_BAD_URL"
const BUILT_IN := "EXTERNAL_BUILT_IN"
const ALREADY_ADDED := "EXTERNAL_ALREADY_ADDED"
const NOT_A_COURSE := "EXTERNAL_NOT_A_COURSE"
const DOWNLOAD_FAILED := "EXTERNAL_DOWNLOAD_FAILED"
const BAD_INDEX := "EXTERNAL_BAD_INDEX"
const NO_NEW_COURSES := "EXTERNAL_NO_NEW_COURSES"

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
		var listing := _listing(dir, url, str(cfg.get_value(dir, "server", "")))
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
	var u: String = _bare(url)
	if u.is_empty() or u.substr(u.find("://") + 3).find("/") < 0:
		# `get_file` of `https://host` is the host itself; a pack needs a path.
		return ""
	var file: String = u.get_file()
	if file.get_extension().to_lower() != "pck":
		return ""
	var dir: String = file.get_basename()
	var name_re := RegEx.create_from_string("^[A-Za-z0-9_-]+$")
	return dir if name_re.search(dir) != null else ""

## Whether `url` names one course (`true`) rather than a folder of them.
static func is_pack_url(url: String) -> bool:
	return _bare(url).get_extension().to_lower() == "pck"

## The index a folder address stands for: the `.json` itself if it names one,
## else [constant INDEX_FILE] inside it. Empty if `url` is not http(s).
static func index_url_for(url: String) -> String:
	var u: String = _bare(url)
	if u.is_empty():
		return ""
	if u.get_extension().to_lower() == "json":
		return url.strip_edges()
	return u.trim_suffix("/") + "/" + INDEX_FILE

## What is wrong with adding `url` under `server_name` before anything is
## fetched: one of the refusal keys above, or empty.
static func check(server_name: String, url: String) -> String:
	if server_name.strip_edges().is_empty():
		return NO_SERVER_NAME
	if _bare(url).is_empty():
		return BAD_URL
	if not is_pack_url(url):
		return ""
	var dir: String = dir_for_url(url)
	if dir.is_empty():
		return BAD_URL
	return _refusal_for(dir, _load_store())

## Add what `url` names under `server_name`: one course, fetched and checked
## now, or every new course in a folder's index. Returns
## `{"error": <refusal key or "">, "added": Array[CourseListing], "skipped": int}`
## — `skipped` counting the index's courses this game already had. A folder
## with nothing new is the refusal [constant NO_NEW_COURSES]. `on_progress` as
## in [method PackStream.ensure].
static func add(server_name: String, url: String,
		on_progress: Callable = Callable()) -> Dictionary:
	var refusal: String = check(server_name, url)
	if not refusal.is_empty():
		return _result(refusal)
	server_name = server_name.strip_edges().left(MAX_SERVER_NAME)
	url = url.strip_edges()
	if is_pack_url(url):
		return await _add_pack(server_name, url, on_progress)
	return await _add_folder(server_name, url, on_progress)

static func _add_pack(server_name: String, url: String, on_progress: Callable) -> Dictionary:
	var listing := _listing(dir_for_url(url), url, server_name)
	var err: Error = await ensure(listing, on_progress)
	if err == ERR_FILE_UNRECOGNIZED:
		return _result(NOT_A_COURSE)
	if err != OK:
		return _result(DOWNLOAD_FAILED)
	var course: CourseData = load(listing.course_path) as CourseData
	if course == null:
		return _result(NOT_A_COURSE)
	listing.display_name = course.display_name
	listing.author = course.author
	listing.description = course.description
	listing.world_size = course.world_size
	listing.base_angle = course.base_angle
	var cfg := _load_store()
	_store(cfg, listing)
	cfg.save(store_path)
	return _result("", [listing])

static func _add_folder(server_name: String, url: String, on_progress: Callable) -> Dictionary:
	var index_url: String = index_url_for(url)
	var fetched: Array = await PackStream.fetch(index_url, on_progress)
	if fetched[0] != OK:
		return _result(DOWNLOAD_FAILED)
	var found: Array[CourseListing] = parse_index(
		(fetched[1] as PackedByteArray).get_string_from_utf8(), index_url, server_name)
	if found.is_empty():
		return _result(BAD_INDEX)
	var cfg := _load_store()
	var added: Array[CourseListing] = []
	var skipped: int = 0
	for listing: CourseListing in found:
		if not _refusal_for(listing.dir, cfg).is_empty():
			skipped += 1
			continue
		_store(cfg, listing)
		added.push_back(listing)
	if added.is_empty():
		return _result(NO_NEW_COURSES, [], skipped)
	cfg.save(store_path)
	return _result("", added, skipped)

## The courses a server's index lists, as rows under `server_name`; empty if
## `text` is not an index. `index_url` is where it came from, which relative
## file names resolve against. The format:
##
## [codeblock]
## { "courses": [
##     { "file": "tuxway.pck", "name": "TuXway", "author": "Crazywater",
##       "description": "…", "width": 100, "length": 1500, "angle": 25 } ] }
## [/codeblock]
##
## Only `file` is needed — a name relative to the index, or a whole http(s)
## address. The rest is what the menu shows before the pack is fetched; a
## missing `name` reads as the directory. An entry whose `file` is not a
## `.pck` with a plain name is left out.
static func parse_index(text: String, index_url: String,
		server_name: String) -> Array[CourseListing]:
	var out: Array[CourseListing] = []
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary and data.get("courses") is Array):
		return out
	var folder: String = _bare(index_url).get_base_dir() + "/"
	for entry: Variant in data["courses"]:
		if not entry is Dictionary:
			continue
		var file: String = str(entry.get("file", ""))
		var url: String = file if not _bare(file).is_empty() else folder + file
		var dir: String = dir_for_url(url)
		if dir.is_empty():
			continue
		var listing := _listing(dir, url, server_name)
		listing.display_name = str(entry.get("name", dir))
		listing.author = str(entry.get("author", ""))
		listing.description = str(entry.get("description", ""))
		listing.world_size = Vector2(float(entry.get("width", 0.0)),
			float(entry.get("length", 0.0)))
		listing.base_angle = float(entry.get("angle", 0.0))
		out.push_back(listing)
	return out

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

## `url` trimmed of spaces, query and fragment if it is http(s), else empty.
static func _bare(url: String) -> String:
	var u: String = url.strip_edges()
	var lower: String = u.to_lower()
	if not (lower.begins_with("http://") or lower.begins_with("https://")):
		return ""
	u = u.get_slice("#", 0).get_slice("?", 0)
	return u if u.length() > u.find("://") + 3 else ""

static func _refusal_for(dir: String, cfg: ConfigFile) -> String:
	if CourseCatalog.load_default().find(dir) != null:
		return BUILT_IN
	if cfg.has_section(dir):
		return ALREADY_ADDED
	return ""

static func _result(error: String, added: Array[CourseListing] = [],
		skipped: int = 0) -> Dictionary:
	return {"error": error, "added": added, "skipped": skipped}

static func _listing(dir: String, url: String, server_name: String) -> CourseListing:
	var listing := CourseListing.new()
	listing.dir = dir
	listing.group = "external"
	listing.source_url = url
	listing.server_name = server_name
	listing.scene_path = "res://courses/%s/course.tscn" % dir
	listing.course_path = "res://courses/%s/course.tres" % dir
	listing.preview_path = "res://courses/%s/preview.png" % dir
	return listing

static func _store(cfg: ConfigFile, listing: CourseListing) -> void:
	var dir: String = listing.dir
	cfg.set_value(dir, "url", listing.source_url)
	cfg.set_value(dir, "server", listing.server_name)
	cfg.set_value(dir, "name", listing.display_name)
	cfg.set_value(dir, "author", listing.author)
	cfg.set_value(dir, "description", listing.description)
	cfg.set_value(dir, "world_size", listing.world_size)
	cfg.set_value(dir, "base_angle", listing.base_angle)

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
