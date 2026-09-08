## Fetches and mounts a `.pck` that a web export left out of the base
## bundle, so a course or the music library can be streamed on demand instead
## of shipping all 44 courses (128 MB) and every piece of music (14 MB) up
## front — see `tools/build_web_streamed.sh` and risk S6 in
## `godot-port-plan.md`.
##
## A no-op everywhere the resource is already present: a native build ships
## the full set in one pck, and every call here starts with the same
## [method ResourceLoader.exists] check the caller would have made anyway.
## Follows the platform-branching convention [LaunchArgs] already
## established (`OS.has_feature("web")`), rather than inventing a new one.
class_name PackStream
extends RefCounted

## `probe_path` already resolved this session, true or false — set once so a
## second `ensure()` for the same course does not refetch it every race.
static var _resolved: Dictionary = {}

## Ensures whatever resource lives at `probe_path` can be loaded, fetching
## `pck_url` (relative to the page) and mounting it first if not. `OK` if the
## resource is available afterward, an [enum Error] otherwise.
static func ensure(probe_path: String, pck_url: String) -> Error:
	if ResourceLoader.exists(probe_path):
		return OK
	if not OS.has_feature("web"):
		# A native build ships everything; a probe path nothing bundles is a
		# course or track that does not exist, not one to go fetch.
		return ERR_FILE_NOT_FOUND
	if _resolved.get(probe_path, false):
		return OK if ResourceLoader.exists(probe_path) else ERR_FILE_NOT_FOUND
	var err: Error = await _fetch_and_mount(pck_url)
	_resolved[probe_path] = true
	if err != OK:
		return err
	return OK if ResourceLoader.exists(probe_path) else ERR_FILE_NOT_FOUND

static func _fetch_and_mount(pck_url: String) -> Error:
	var url: String = _page_base_url() + pck_url
	var http := HTTPRequest.new()
	# Deferred: the very first call (menu music, on `_ready`) lands while the
	# root window is still busy adding the boot scene's own children, and a
	# direct add_child there fails outright — same shape as the
	# change_scene_to_file/_ready trap elsewhere in the shell.
	Engine.get_main_loop().root.add_child.call_deferred(http)
	await Engine.get_main_loop().process_frame
	var request_err: Error = http.request(url)
	if request_err != OK:
		http.queue_free()
		return request_err
	var result: Array = await http.request_completed
	http.queue_free()
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	if response_code != 200:
		return ERR_CANT_CONNECT

	DirAccess.make_dir_recursive_absolute("user://cache")
	var tmp_path: String = "user://cache/%s" % pck_url.get_file()
	var f: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(body)
	f.close()
	var mounted: bool = ProjectSettings.load_resource_pack(tmp_path)
	return OK if mounted else ERR_CANT_OPEN

## `HTTPRequest` wants an absolute URL; there is no command line to read one
## from in a browser, so this asks the page the same way [method
## LaunchArgs.url_query] does.
static func _page_base_url() -> String:
	var href: Variant = JavaScriptBridge.eval(
		"location.href.replace(/[^\\/]*$/, '')", true)
	return str(href) if href is String else ""
