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

## What [method HTTPRequest.download_chunk_size] is set to for every fetch
## here, against the default 64 KiB. See [method _fetch_and_mount]: the chunk
## is read once a frame, so this is what decides whether a pack arrives at the
## speed of the link or at the speed of the renderer.
const DOWNLOAD_CHUNK_SIZE := 1 << 20

## `probe_path` already resolved this session, true or false — set once so a
## second `ensure()` for the same course does not refetch it every race.
static var _resolved: Dictionary = {}

## Whether [method ensure] would go to the network for `probe_path`: a web
## build that has not fetched this pack yet.
##
## Asked before the call, not after, because the answer decides how the caller
## behaves for the whole of the load and not just the fetch — [RaceScene] only
## spends frames painting a progress bar on a build that has something to put
## in one. False everywhere a native build runs, and false the second time a
## course is raced in the same session.
static func is_streamed(probe_path: String) -> bool:
	return (not ResourceLoader.exists(probe_path)
		and OS.has_feature("web")
		and not _resolved.get(probe_path, false))

## Ensures whatever resource lives at `probe_path` can be loaded, fetching
## `pck_url` (relative to the page) and mounting it first if not. `OK` if the
## resource is available afterward, an [enum Error] otherwise.
##
## `on_progress`, when valid, is called once a frame for the length of the
## download with `(downloaded_bytes, total_bytes)` — and never at all when
## there is no download, which is every native call. `total_bytes` is 0 until
## the size is known and -1 if it never becomes known (see [method
## _begin_size_probe]); what to draw for either is the caller's business, not
## this file's.
static func ensure(probe_path: String, pck_url: String,
		on_progress: Callable = Callable()) -> Error:
	if ResourceLoader.exists(probe_path):
		return OK
	if not OS.has_feature("web"):
		# A native build ships everything; a probe path nothing bundles is a
		# course or track that does not exist, not one to go fetch.
		return ERR_FILE_NOT_FOUND
	if _resolved.get(probe_path, false):
		return OK if ResourceLoader.exists(probe_path) else ERR_FILE_NOT_FOUND
	var err: Error = await _fetch_and_mount(pck_url, on_progress)
	_resolved[probe_path] = true
	if err != OK:
		return err
	return OK if ResourceLoader.exists(probe_path) else ERR_FILE_NOT_FOUND

static func _fetch_and_mount(pck_url: String, on_progress: Callable) -> Error:
	var url: String = _page_base_url() + pck_url
	var http := HTTPRequest.new()
	# `HTTPRequest` reads exactly one chunk per poll and it polls once a frame,
	# so the default 64 KiB makes a download's speed the *frame rate* times
	# 64 KiB and nothing to do with the link. The 14 MB music pack is 215
	# chunks: fetched from the menu, where nothing is being drawn, that is half
	# a second, but the pack the race asks for is fetched while the hill is
	# rendering — measured at 117 s to arrive under a software GL browser, and
	# a hard 215 frames however fast the connection is. A megabyte a poll makes
	# the download bandwidth-bound again (14 polls) and costs the progress bar
	# a granularity it never spends, since the bar is drawn over the loading
	# screen, where frames are cheap.
	http.download_chunk_size = DOWNLOAD_CHUNK_SIZE
	# Deferred: the very first call (menu music, on `_ready`) lands while the
	# root window is still busy adding the boot scene's own children, and a
	# direct add_child there fails outright — same shape as the
	# change_scene_to_file/_ready trap elsewhere in the shell.
	Engine.get_main_loop().root.add_child.call_deferred(http)
	await Engine.get_main_loop().process_frame
	_begin_size_probe(url)
	var request_err: Error = http.request(url)
	if request_err != OK:
		http.queue_free()
		return request_err
	# Polled rather than a plain `await http.request_completed`, because the
	# caller wants a number every frame and the signal only arrives once, at the
	# end. A course pack is a few megabytes over a link nobody here controls;
	# a bar that moves only when it is already finished says nothing.
	var completed: Array = []
	http.request_completed.connect(
		func(res: int, code: int, headers: PackedStringArray,
				body: PackedByteArray) -> void:
			completed.push_back([res, code, headers, body]))
	# 0 while the page has not answered yet, -1 once it has said it cannot.
	var total: int = 0
	while completed.is_empty():
		if total == 0:
			total = _probed_size(url)
		if on_progress.is_valid():
			on_progress.call(http.get_downloaded_bytes(), total)
		await Engine.get_main_loop().process_frame
	var result: Array = completed[0]
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

## Ask the page how big `url` is, in the background.
##
## [b][method HTTPRequest.get_body_size] is -1 for the whole of a download on
## the web export[/b], which is the only platform that gets here — Godot's web
## [HTTPClient] is a thin wrapper over `fetch` and never surfaces
## `Content-Length`, so the bytes arriving can be counted but not divided by
## anything. The one component on this platform that can read the header is the
## page itself, and this file already talks to it (see [method
## _page_base_url]). A `HEAD` against a server that has just served the page
## costs one round trip and buys the difference between a progress bar and a
## byte counter.
##
## Fired and not awaited: the real download starts in the same frame and the
## answer is picked up by [method _probed_size] whenever it lands, so a slow or
## missing `HEAD` delays nothing.
##
## Kept per URL rather than in one global, because two packs really can be in
## flight at once: a `?course=` boot starts the race while [AudioDirector] is
## still fetching `music.pck` for the menu theme, and a single slot would show
## one download the other one's size.
static func _begin_size_probe(url: String) -> void:
	# `JSON.stringify` rather than plain interpolation: it is the quoting a JS
	# string literal actually wants, where `uri_encode` would escape the `://`
	# and hand `fetch` a relative path.
	JavaScriptBridge.eval("""
		(function (u) {
			window.__pr_pack_size = window.__pr_pack_size || {};
			window.__pr_pack_size[u] = 0;
			fetch(u, { method: "HEAD" })
				.then(r => {
					window.__pr_pack_size[u] =
						parseInt(r.headers.get("content-length") || "-1");
				})
				.catch(() => { window.__pr_pack_size[u] = -1; });
		})(%s);
	""" % JSON.stringify(url), true)

## The size [method _begin_size_probe] went to look for: 0 until the answer
## lands, then the byte count, or -1 if the page could not get one — a host
## that sends no `Content-Length`, or one that refuses `HEAD`. Callers treat
## anything but a positive number as "no total", and count bytes instead.
static func _probed_size(url: String) -> int:
	var v: Variant = JavaScriptBridge.eval(
		"(window.__pr_pack_size || {})[%s] || 0" % JSON.stringify(url), true)
	if v == null:
		return 0
	return int(v)

## `HTTPRequest` wants an absolute URL; there is no command line to read one
## from in a browser, so this asks the page the same way [method
## LaunchArgs.url_query] does.
static func _page_base_url() -> String:
	var href: Variant = JavaScriptBridge.eval(
		"location.href.replace(/[^\\/]*$/, '')", true)
	return str(href) if href is String else ""
