## The other half of the server: the static host the web build is fetched from.
##
## [b]Why this is in the game and not in `tools/`.[/b] `tools/webtest/server.js`
## already serves the export for the browser harness, and it needs Node. The
## thing being shipped here is *one server a player can run* — it hands out the
## WebAssembly build over HTTP and accepts the race sessions those pages then
## open, from one process, on one machine, with no second runtime installed. A
## desktop player connects to the same process and skips the first half.
##
## [b]COOP/COEP are not optional.[/b] The `Web` export preset has
## `variant/thread_support=true`, so the page needs `SharedArrayBuffer`, so the
## browser needs cross-origin isolation — without both headers the export dies
## in the console with an error that names neither. The MIME types matter for
## the same reason: `.wasm` served as `application/octet-stream` skips
## `instantiateStreaming` and `.pck` served as HTML is a load failure with no
## explanation. Both were learnt in `tools/webtest/server.js` and are repeated
## here rather than referred to, because this file has to work on a machine
## that never checked the repository out.
##
## [b]Deliberately small.[/b] `GET` and `HEAD`, one optional byte range, no
## keep-alive, no compression, no directory listing, no TLS. A page served over
## plain HTTP may open a `ws://` socket, which is the pairing this server
## exists to provide; anything facing the open internet wants a real reverse
## proxy in front of it, terminating TLS and forwarding `wss://` to the game
## port, and then this becomes the origin behind it.
class_name WebFileServer
extends Node

## Bytes moved per connection per frame, at most. The base bundle is ~65 MB and
## reading it into memory per client would be the only allocation in this
## program worth caring about; it is streamed off disk a chunk at a time
## instead, as fast as each socket will take it.
const CHUNK := 256 * 1024
## Longest request head accepted, headers and all. A request that has not
## finished by then is not a browser.
const MAX_REQUEST := 16 * 1024

const TYPES: Dictionary[String, String] = {
	"html": "text/html; charset=utf-8",
	"js": "text/javascript; charset=utf-8",
	"json": "application/json",
	"wasm": "application/wasm",
	"pck": "application/octet-stream",
	"png": "image/png",
	"jpg": "image/jpeg",
	"svg": "image/svg+xml",
	"ico": "image/x-icon",
	"css": "text/css; charset=utf-8",
	"webmanifest": "application/manifest+json",
}

## One browser, mid-request or mid-download.
class Conn extends RefCounted:
	var socket: StreamPeerTCP
	var head: PackedByteArray = PackedByteArray()
	var out: PackedByteArray = PackedByteArray()
	var sent: int = 0
	## The file still to be streamed after [member out] drains, or null.
	var file: FileAccess = null
	var remaining: int = 0
	var opened_msec: int = Time.get_ticks_msec()
	## What was asked for, kept only so a refusal can name it.
	var target: String = ""

var root: String = ""
var port: int = 8060

var _server := TCPServer.new()
var _conns: Array[Conn] = []

## Open the socket. [param web_root] is a directory on this machine, not a
## `res://` path — the thing being served is an exported build, which is not
## part of this project's own filesystem.
##
## [b]A relative path is relative to the project directory, not to the shell's.[/b]
## Godot exposes no process working directory, and `DirAccess` resolves a bare
## relative path against the project — so `--web-root=../build/web` started from
## anywhere means `game/../build/web`, and `--web-root=build/web` means
## `game/build/web`, which is nobody's build. It is made explicit here rather
## than inherited, and the resolved path is what the warning and the startup
## banner print, because "does not exist" about a path you did not type is the
## kind of message that costs an afternoon. `tools/serve.sh` passes an absolute
## one and sidesteps the whole question.
func listen(web_root: String, listen_port: int) -> Error:
	port = listen_port
	var wanted: String = ProjectSettings.globalize_path(web_root)
	if not wanted.is_absolute_path():
		wanted = ProjectSettings.globalize_path("res://").path_join(wanted)
	wanted = wanted.simplify_path()
	# Opened rather than tested: opening is also what resolves the `..` in it,
	# and a traversal guard comparing against an unresolved prefix is no guard.
	var dir: DirAccess = DirAccess.open(wanted)
	if dir == null:
		push_warning("web root %s does not exist — not serving files" % wanted)
		return ERR_FILE_NOT_FOUND
	root = dir.get_current_dir().simplify_path()
	if root.ends_with("/"):
		root = root.left(root.length() - 1)
	var err: Error = _server.listen(port)
	if err != OK:
		push_warning("could not listen on port %d (error %d)" % [port, err])
		return err
	return OK

func stop() -> void:
	for conn: Conn in _conns:
		conn.socket.disconnect_from_host()
	_conns.clear()
	_server.stop()

func _process(_delta: float) -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		var conn := Conn.new()
		conn.socket = _server.take_connection()
		conn.socket.set_no_delay(true)
		_conns.push_back(conn)
	var live: Array[Conn] = []
	for conn: Conn in _conns:
		if _pump(conn):
			live.push_back(conn)
		else:
			conn.socket.disconnect_from_host()
	_conns = live

## Move one connection along by one frame. Returns whether it is still alive.
func _pump(conn: Conn) -> bool:
	conn.socket.poll()
	if conn.socket.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	if conn.out.is_empty() and conn.file == null:
		return _read_request(conn)
	return _write(conn)

## Collect the request head, and answer it once the blank line arrives.
func _read_request(conn: Conn) -> bool:
	var available: int = conn.socket.get_available_bytes()
	if available > 0:
		var chunk: Array = conn.socket.get_partial_data(available)
		if int(chunk[0]) != OK:
			return false
		conn.head.append_array(chunk[1] as PackedByteArray)
	if conn.head.size() > MAX_REQUEST:
		return false
	var text: String = conn.head.get_string_from_utf8()
	if not text.contains("\r\n\r\n"):
		# Nothing yet and nothing coming: a socket opened and abandoned is not
		# worth holding a slot for.
		return Time.get_ticks_msec() - conn.opened_msec < 10_000
	_respond(conn, text.split("\r\n\r\n", true, 1)[0])
	return true

## Send what is queued, then refill from the file, until the socket says no
## more this frame.
func _write(conn: Conn) -> bool:
	var budget: int = CHUNK
	while budget > 0:
		if conn.sent >= conn.out.size():
			conn.out = PackedByteArray()
			conn.sent = 0
			if conn.file == null or conn.remaining <= 0:
				_close_file(conn)
				# No keep-alive: the response is the connection.
				return false
			conn.out = conn.file.get_buffer(mini(CHUNK, conn.remaining))
			conn.remaining -= conn.out.size()
			if conn.out.is_empty():
				_close_file(conn)
				return false
		var result: Array = conn.socket.put_partial_data(conn.out.slice(conn.sent))
		if int(result[0]) != OK:
			_close_file(conn)
			return false
		var wrote: int = int(result[1])
		if wrote <= 0:
			return true
		conn.sent += wrote
		budget -= wrote
	return true

func _close_file(conn: Conn) -> void:
	if conn.file != null:
		conn.file.close()
		conn.file = null

# ------------------------------------------------------------------

func _respond(conn: Conn, head: String) -> void:
	var lines: PackedStringArray = head.split("\r\n")
	var request: PackedStringArray = lines[0].split(" ")
	if request.size() < 2:
		conn.target = lines[0]
		_send_error(conn, 400, "bad request")
		return
	var method: String = request[0].to_upper()
	conn.target = request[1]
	if method != "GET" and method != "HEAD":
		_send_error(conn, 405, "method not allowed")
		return
	var path: String = resolve(root, request[1])
	if path.is_empty():
		_send_error(conn, 404, "not found")
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_send_error(conn, 404, "not found")
		return
	var length: int = file.get_length()
	var from: int = 0
	var to: int = length - 1
	var partial: bool = false
	for line: String in lines:
		if not line.to_lower().begins_with("range:"):
			continue
		var span: Vector2i = parse_range(line, length)
		if span.x < 0:
			file.close()
			_send_error(conn, 416, "range not satisfiable")
			return
		from = span.x
		to = span.y
		partial = true
	var headers := PackedStringArray()
	headers.push_back("HTTP/1.1 %s" % ("206 Partial Content" if partial else "200 OK"))
	headers.push_back("Content-Type: %s" % mime_type(path))
	headers.push_back("Content-Length: %d" % (to - from + 1))
	if partial:
		headers.push_back("Content-Range: bytes %d-%d/%d" % [from, to, length])
	headers.push_back("Accept-Ranges: bytes")
	# The two that make `SharedArrayBuffer` — and so the threaded export — work
	# at all. See the class note.
	headers.push_back("Cross-Origin-Opener-Policy: same-origin")
	headers.push_back("Cross-Origin-Embedder-Policy: require-corp")
	headers.push_back("Cache-Control: no-store")
	headers.push_back("Connection: close")
	conn.out = ("%s\r\n\r\n" % "\r\n".join(headers)).to_utf8_buffer()
	conn.sent = 0
	if method == "HEAD":
		file.close()
		return
	file.seek(from)
	conn.file = file
	conn.remaining = to - from + 1

## A refusal, and a line saying so. The log is one line per request that did
## [i]not[/i] work, which on a static host is the only kind worth printing: a
## missing `.pck` or a mistyped web root is an export that fails in the browser
## with nothing actionable in its own console, and this is where it shows.
func _send_error(conn: Conn, code: int, text: String) -> void:
	print("[web] %d %s" % [code, conn.target])
	var body: PackedByteArray = text.to_utf8_buffer()
	conn.out = ("HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
		% [code, text, body.size(), text]).to_utf8_buffer()
	conn.sent = 0
	conn.file = null
	conn.remaining = 0

# ------------------------------------------------------------------

## Turn a request target into a readable file under [param web_root], or `""`.
##
## Static and pure so the traversal guard is testable: `..` in the path, an
## encoded `%2e%2e`, an absolute path and a symlink-shaped one all have to come
## back empty, and "it looked right in a browser" is not a test of that.
static func resolve(web_root: String, target: String) -> String:
	var path: String = target.split("?")[0].split("#")[0].uri_decode()
	if not path.begins_with("/"):
		return ""
	if path.ends_with("/"):
		path += "index.html"
	# `simplify_path` is what resolves `..`; the prefix check afterwards is what
	# makes resolving it safe. Doing it the other way round — rejecting `..`
	# textually — misses every encoding of it.
	var full: String = ("%s%s" % [web_root, path]).simplify_path()
	if full != web_root and not full.begins_with("%s/" % web_root):
		return ""
	if not FileAccess.file_exists(full):
		return ""
	return full

## `Range: bytes=100-199` → `(100, 199)`, clamped to [param length].
## `(-1, -1)` for a range this server will not answer.
static func parse_range(header: String, length: int) -> Vector2i:
	var spec: String = header.split(":", true, 1)[1].strip_edges()
	if not spec.begins_with("bytes="):
		return Vector2i(-1, -1)
	var span: String = spec.trim_prefix("bytes=").strip_edges()
	# One range only. A multi-range request is legal and nothing the Godot web
	# export makes; answering the whole file is the correct fallback.
	if span.contains(","):
		return Vector2i(0, length - 1)
	var parts: PackedStringArray = span.split("-")
	if parts.size() != 2:
		return Vector2i(-1, -1)
	var from: int = 0
	var to: int = length - 1
	if parts[0].is_empty():
		# `-500`: the last 500 bytes.
		if not parts[1].is_valid_int():
			return Vector2i(-1, -1)
		from = maxi(0, length - parts[1].to_int())
	else:
		if not parts[0].is_valid_int():
			return Vector2i(-1, -1)
		from = parts[0].to_int()
		if not parts[1].is_empty():
			if not parts[1].is_valid_int():
				return Vector2i(-1, -1)
			to = parts[1].to_int()
	to = mini(to, length - 1)
	if from > to or from < 0 or from >= length:
		return Vector2i(-1, -1)
	return Vector2i(from, to)

## What to call the bytes. Anything not named here is served as an opaque
## download, which is the safe answer: the four types that actually have to be
## right for a Godot web export — `.html`, `.js`, `.wasm`, `.pck` — are all in
## the table.
static func mime_type(path: String) -> String:
	return str(TYPES.get(path.get_extension().to_lower(), "application/octet-stream"))
