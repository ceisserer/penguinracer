## Everything this run was asked for on the way in, parsed once.
##
## [b]Two transports, one list.[/b] A desktop build is told things on the
## command line and a browser build is told them in the URL query, and those are
## the same set of questions asked twice. They had drifted: six scripts each
## walked [method OS.get_cmdline_user_args] for their own flags, the URL was
## read in one of them and only for four keys, and the result was that
## `?opponents=5&difficulty=hard` silently did nothing — not as a decision, but
## because no line of code anywhere said so. Parsing both sources into one
## object makes the matrix something you can read.
##
## [b]Parsed once, at first use.[/b] `location.search` is a
## [JavaScriptBridge] round trip and [MainMenu] used to make four of them; the
## command line cannot change while the game is running, and neither can the
## URL. [method current] builds the object on the first call and hands the same
## one out afterwards.
##
## [b]Deliberately dumb.[/b] Fields are strings, ints and bools — nothing here
## resolves a course directory to a scene path or a difficulty name to an
## [AISkill], because that is the caller's vocabulary and this is the transport.
## It also means this class depends on nothing, which is what keeps it safe to
## reach for from an autoload (see [RaceNetwork] for the parse cycle two
## autoloads can be).
class_name LaunchArgs
extends RefCounted

## Unset opponents. Zero is a real answer — it is Practice — so the sentinel
## cannot be zero.
const NO_OPPONENTS := -1
## Unset snowfall, for the same reason: zero is "clear sky", which is a thing a
## command line can legitimately ask for over a settings file that says
## otherwise.
const NO_SNOW := -1

## Course directory name, e.g. `bunny_hill`. Empty means "ask the shell".
var course: String = ""
## Character directory name, for this run only.
var character: String = ""
## `--auto-input=carve|brake|paddle`: a stand-in for a player.
var auto_input: String = ""
## `--camera=above|trail`. Empty means the racing default.
var camera: String = ""
## Field size for a race started without the menu, or [constant NO_OPPONENTS].
var opponents: int = NO_OPPONENTS
## Difficulty name, unparsed. Empty means "whatever the default is".
var difficulty: String = ""

var remote_keyboard: bool = false
var no_audio: bool = false
var no_intro: bool = false
## `--fps` — the HUD's frame-rate readout, which is `param.display_fps` in the
## original's config file. A flag rather than a setting because it is a debug
## number you turn on for a session, not a preference worth keeping.
var show_fps: bool = false
## `--wind=1..3` — the wind grade, ETR's `[wind]` column in `events.lst`.
## Nothing else sets it: wind belongs to a cup race and there are no cups yet,
## so this is how the [WindField] and the HUD's rose are reachable at all.
var wind: int = 0
## `--snow=0..3` — how hard it is snowing, ETR's `g_game.snow_id`. Unlike the
## wind this is also a settings key and a control on the course screen; the flag
## is how a capture names the weather without going through either.
var snow: int = NO_SNOW
## `--light=sunny|cloudy|night` — ETR's `g_game.light_id`, unparsed, for the
## same reason [member difficulty] is a string: naming a [LightCondition] here
## would make the transport know the caller's vocabulary. Empty means "whatever
## the settings file says".
var light: String = ""
## `?autostart` — the browser's way of saying "skip the menu" without naming a
## course, since it has no `--auto-input=` either.
var autostart: bool = false

## `--capture=<png>` and how many frames to wait first.
var capture_path: String = ""
var capture_frames: int = 120

## `--server=<address>` / `?server=`: the lobby server to connect to, replacing
## whatever the settings file names, and a request to open the lobby on the way
## in. Empty means "ask the shell".
var server: String = ""
## `--lobby` / `?lobby`: open the lobby on the server the settings file already
## names, without naming another one.
var lobby: bool = false
## `--port=` on the dedicated server (`scenes/server.tscn`), or 0 for the
## default. Not read anywhere else.
var server_port: int = 0
## `--web-root=<dir>` and `--web-port=`: the exported web build the dedicated
## server hands out over HTTP, and where. Empty means it serves races only.
var web_root: String = ""
var web_port: int = 8060

static var _current: LaunchArgs

## The arguments this run was started with.
static func current() -> LaunchArgs:
	if _current == null:
		_current = LaunchArgs.new()
		_current.parse(OS.get_cmdline_user_args(), url_query())
	return _current

## Replace what [method current] returns. For the headless suite, which has to
## be able to ask what a given command line would have meant without being
## started with it.
static func override(args: LaunchArgs) -> void:
	_current = args

## Whether this run wants a course rather than the main menu.
##
## `--auto-input=` alone is enough: it is a run with a stand-in for a player, so
## the default course is the right one. A bare `--capture=` is not — that one
## captures whatever is on screen, which is how the shell itself gets
## screenshotted.
##
## A multiplayer session is [i]not[/i] one of these. It used to be, when a
## session was two command lines naming the same course at both ends because
## there was no lobby; now there is one, the course is the room's and its
## admin's, and a run started with `--server=` lands on the lobby rather than on
## a hill.
func wants_direct_race() -> bool:
	return not course.is_empty() or not auto_input.is_empty() or autostart

## Whether this run was told to open the lobby rather than the root menu.
func wants_lobby() -> bool:
	return lobby or not server.is_empty()

## Whether a stand-in is driving rather than a person. Every reference capture
## and the whole headless verification path is one of these.
func is_scripted() -> bool:
	return not auto_input.is_empty()

## The course as a scene path, or `""` for "whatever the shell defaults to".
func course_scene_path() -> String:
	return "" if course.is_empty() else "res://courses/%s/course.tscn" % course

func parse(argv: PackedStringArray, query: Dictionary) -> void:
	for arg: String in argv:
		if arg.begins_with("--course="):
			course = arg.trim_prefix("--course=")
		elif arg.begins_with("--character="):
			character = arg.trim_prefix("--character=")
		elif arg.begins_with("--auto-input="):
			auto_input = arg.trim_prefix("--auto-input=")
		elif arg.begins_with("--camera="):
			camera = arg.trim_prefix("--camera=")
		elif arg.begins_with("--opponents="):
			opponents = arg.trim_prefix("--opponents=").to_int()
		elif arg.begins_with("--difficulty="):
			difficulty = arg.trim_prefix("--difficulty=")
		elif arg == "--remote-keyboard":
			remote_keyboard = true
		elif arg == "--no-audio":
			no_audio = true
		elif arg == "--no-intro":
			no_intro = true
		elif arg == "--fps":
			show_fps = true
		elif arg.begins_with("--wind="):
			wind = arg.trim_prefix("--wind=").to_int()
		elif arg.begins_with("--snow="):
			snow = arg.trim_prefix("--snow=").to_int()
		elif arg.begins_with("--light="):
			light = arg.trim_prefix("--light=")
		elif arg.begins_with("--capture="):
			capture_path = arg.trim_prefix("--capture=")
		elif arg.begins_with("--capture-frames="):
			capture_frames = arg.trim_prefix("--capture-frames=").to_int()
		elif arg.begins_with("--server="):
			server = arg.trim_prefix("--server=")
		elif arg == "--lobby":
			lobby = true
		elif arg.begins_with("--port="):
			server_port = arg.trim_prefix("--port=").to_int()
		elif arg.begins_with("--web-root="):
			web_root = arg.trim_prefix("--web-root=")
		elif arg.begins_with("--web-port="):
			web_port = arg.trim_prefix("--web-port=").to_int()

	# The URL says the same things, spelled the way a query string spells them:
	# no leading dashes, and a bare key is true. It is read second and only
	# fills what the command line left empty, which matters not at all in a
	# browser — there is no command line there — and keeps a desktop run from
	# being surprised if one ever grows a URL.
	if query.is_empty():
		return
	course = _str(query, "course", course)
	character = _str(query, "character", character)
	auto_input = _str(query, "auto-input", auto_input)
	camera = _str(query, "camera", camera)
	if opponents == NO_OPPONENTS and query.has("opponents"):
		opponents = str(query["opponents"]).to_int()
	difficulty = _str(query, "difficulty", difficulty)
	remote_keyboard = remote_keyboard or query.has("remotekeyboard")
	no_audio = no_audio or query.has("noaudio")
	no_intro = no_intro or query.has("nointro")
	show_fps = show_fps or query.has("fps")
	if wind == 0 and query.has("wind"):
		wind = str(query["wind"]).to_int()
	if snow == NO_SNOW and query.has("snow"):
		snow = str(query["snow"]).to_int()
	light = _str(query, "light", light)
	autostart = autostart or query.has("autostart")
	# The lobby, from a link. `?server=` names one and `?lobby` takes the one
	# the page's own host implies — see [method RaceNetwork.default_address],
	# which is what makes a URL handed to a friend enough on its own.
	server = _str(query, "server", server)
	lobby = lobby or query.has("lobby")
	capture_path = _str(query, "capture", capture_path)
	if query.has("capture-frames"):
		capture_frames = str(query["capture-frames"]).to_int()

static func _str(query: Dictionary, key: String, fallback: String) -> String:
	if fallback.is_empty() and query.has(key):
		return str(query[key])
	return fallback

## The web build's `?a=b&c=d`, since there is no command line in a browser.
## Empty everywhere else — [JavaScriptBridge] exists on every platform but only
## evaluates anything on web.
static func url_query() -> Dictionary:
	if not OS.has_feature("web"):
		return {}
	var search: Variant = JavaScriptBridge.eval("location.search", true)
	if not (search is String):
		return {}
	var out: Dictionary = {}
	for pair: String in str(search).trim_prefix("?").split("&", false):
		var eq: int = pair.find("=")
		if eq < 0:
			out[pair.uri_decode()] = ""
		else:
			out[pair.left(eq).uri_decode()] = pair.substr(eq + 1).uri_decode()
	return out
