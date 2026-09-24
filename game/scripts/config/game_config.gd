## The player's settings file: everything that is a preference rather than
## migrated data.
##
## Modelled on ETR's `options.txt` (`game_config.cpp`): a plain text file in the
## user directory, written with its comments the first time the game runs, read
## once at startup, and editable either by hand or from the settings screen —
## [SettingsMenu] moves these same values and calls [method save], which
## rewrites the file comments and all rather than letting [ConfigFile.save]
## strip them.
##
##     Linux    ~/.local/share/godot/app_userdata/PenguinRacer/penguinracer.cfg
##     Windows  %APPDATA%\Godot\app_userdata\PenguinRacer\penguinracer.cfg
##     Web      IndexedDB, per origin
##
## The path is printed once when the file is created. Delete the file to get the
## defaults and the comments back.
##
## Nothing here is course data. A value that comes out of `etr-0.8.4/data` and
## is migrated belongs on a resource; this file is for the knobs a player turns
## and for the two defaults that are deliberately not the original's number.
class_name GameConfig
extends Node

const PATH := "user://penguinracer.cfg"

## Fog has to keep a band to ramp across, whatever the file asks for: a start
## pushed past the end is fog that switches on like a wall.
const MAX_START_FRACTION := 0.75

## How far apart two window sizes may be and still be the same window, in
## logical pixels. A fractional output scale does not divide back out exactly —
## 1500 physical at 1.25 is 1200 logical, but 643 is 514.4 — so an exact
## comparison would call every scaled window somebody else's doing.
const WINDOW_MATCH_SLACK := 2.0

# --- display ---

## Window size in pixels. `Vector2i.ZERO` means "leave it alone" — the project
## default, or whatever `--resolution` asked for on the command line.
var resolution: Vector2i = Vector2i(1280, 720)
var fullscreen: bool = false
## Fraction of the window the 3D viewport is rendered at, then upscaled. The
## cheapest framerate knob under Compatibility, and the one that matters on a
## laptop GPU running a browser; 2D and the HUD stay at full resolution.
## ETR had no equivalent — it scaled by picking a smaller window.
var render_scale: float = 1.0
## Whether the ice reflects the racers standing on it.
##
## DEVIATION: ETR reflects nothing at all, so this is a knob on an addition
## rather than on anything migrated. It costs a second render of the character
## rigs into a half-resolution target every frame — cheap next to the terrain,
## but it is a whole extra 3D pass on a WebGL2 budget, and the lowest tier
## should be able to say no. See [IceReflection].
var ice_reflections: bool = true
## Whether the racers and the standing course objects cast a shadow on the snow.
##
## Half migrated, half DEVIATION. `CCharShape::DrawShadow` draws the character's
## shadow only above `param.perf_level > 2`, so a shadow being the first thing a
## slow machine gives up is the original's own policy and this is that switch.
## Trees casting one is the deviation: `DrawTrees` emits eight vertices per
## object and no shadow geometry at all.
##
## It is not the only gate, and the other two are not the player's:
## [member EnvironmentPreset.casts_shadows] carries ETR's own per-sky rule, and
## [method RenderBackend.supports_light_shadows] answers no on the web build,
## where a shadow-casting light is drawn in an sRGB-blended second pass and
## wrecks the frame. Wanting shadows is what this says; getting them needs all
## three. Nothing writes it back to `false` when the renderer refuses — the file
## records the preference, not what the hardware made of it.
var shadows: bool = true
## Which sky is drawn: the procedural one ([Atmosphere]: sun disc, drifting
## clouds, distant ridges, aerial perspective, valley mist, and stars, a moon
## and an aurora at night), or ETR's three photographed faces with its flat fog.
##
## DEVIATION, and the revert switch for it: `false` is the frame as it was
## before the atmosphere existed, to the level — the fog is ETR's flat
## `[fogcol]`, there is no mist, and the sky is `etr_skybox.gdshader`.
var procedural_sky: bool = true
## Whether a night course has torches along its edges and lanterns on its
## flags ([CourseLights]). ETR lights nothing but the sky; off is its night.
var night_lights: bool = true

# --- fog ---

## Metres of clear air in front of the camera before fog starts to build.
##
## DEVIATION, and the reason this file exists. `light.lst` ships `[fogstart] 0`
## for the sunny and night environments — six of the eight courses' worth of
## presets — so haze begins at the camera and the near field is already washed
## toward white a couple of tree-lengths ahead. That is faithful, but it is also
## the first thing anyone notices; the floor lifts it off the player without
## touching the migrated numbers. Set to 0 to render exactly what the file says.
var fog_start_distance: float = 40.0
## Multiplies the migrated `[fogstart]`/`[fogend]` range.
##
## DEVIATION: 2.0, not 1.0. ETR reaches full white at 75 m and that haze is
## load-bearing for how its snow reads — stretching it was called out as a
## wording-level "improvement" once already, and this is the same change made
## deliberately and made revertible. `fog_distance_scale = 1.0` with
## `fog_start_distance = 0.0` is the original's fog, exactly.
var fog_distance_scale: float = 2.0

# --- game ---

## Directory name of the character raced as — a row of
## [member CharacterCatalog.entries], which is a row of `char/characters.lst`.
##
## DEVIATION: ETR asks on its registration screen, once per launch, and does not
## remember the answer — `g_game.character` is a pointer set from a `TUpDown`
## that opens on index 0 every time, and `players.lst` stores a name and an
## avatar but no character. There is no registration screen here, because there
## are no player profiles yet (Phase 5), so the question is asked from its own
## menu entry and the answer is kept. Storing an unvalidated directory name is
## deliberate: a character can be missing from a narrowed export, and
## [method CharacterCatalog.scene_path_for] falls back rather than the file
## being rewritten behind the player's back.
var character: String = CharacterCatalog.DEFAULT_DIR

## How many computer opponents the main menu's *Race the computer* entry offers
## next time, 1..[constant RaceSetup.MAX_OPPONENTS].
##
## Not on the Configuration screen, unlike the six keys above it. This is a
## choice made in the flow of racing — it is on the course screen, next to the
## course — and it is stored so that the choice survives quitting the game
## rather than only the scene. Three is a field you can see all of.
var opponents: int = 3
## How well those opponents drive. See [AISkill]: the levels move driving
## habits, never the physics.
var opponent_skill: AISkill.Level = AISkill.Level.MEDIUM

## How hard it is snowing, 0 (clear) to [constant SnowFall.MAX_GRADE]. ETR's
## `g_game.snow_id`, and on the same screen it is on there: the course screen
## sets it and this is where the answer is kept between sessions.
##
## Zero by default, which is both the original's `main.cpp` and the reason every
## reference capture in the repository still means what it meant — snow in front
## of the camera would move the frame on all 44 courses.
var snowfall: int = 0

## What the sky is doing: ETR's `g_game.light_id`, kept for the same reason and
## on the same screen as [member snowfall]. See [LightCondition].
##
## Sunny by default, which is the original's `main.cpp` and what every one of
## the 44 courses names an environment for; it is also why every reference
## capture in the repository still means what it meant.
var conditions: LightCondition.Kind = LightCondition.Kind.SUNNY

## How hard the crosswind blows: none, light or strong — see [WindField]. The
## third of the course screen's weather, kept beside the other two. The side it
## blows from is not a setting: it is rolled on every start.
##
## None by default, for the same reason as the other two.
var wind: WindField.Strength = WindField.Strength.NONE

# --- multiplayer ---

## What other racers see this player called. ETR has `players.lst` and an avatar
## picture behind its registration screen; there are no profiles here yet, so
## the name is a settings key until there is somewhere better for it to live.
var player_name: String = "Racer"
## Port the lobby server listens on, and the one an address without a port of
## its own is assumed to be using.
var multiplayer_port: int = RaceNetwork.DEFAULT_PORT
## The lobby server the **Network multiplayer** screen connects to. Empty means
## "work it out" — the host that served the page in a browser, the loopback
## everywhere else. See [method RaceNetwork.default_address].
##
## Kept in the settings file rather than only on the screen because a player who
## races on one server races on it again next week, and typing an address into a
## game every time is the kind of friction that ends a multiplayer mode.
var multiplayer_server: String = ""

## Set once, before the file has touched anything: true when the window we were
## handed is not the one `project.godot` asks for, which on the desktop means
## `--resolution` or `--fullscreen` was on the command line. [method
## apply_display] then leaves the window alone, so a capture comes out the size
## it was asked for whatever this file says. A bare `-w`/`--windowed` is the one
## flag this cannot see, since it changes no size — a file asking for fullscreen
## still gets it.
##
## It is [i]measured[/i] rather than read off the command line because
## [method OS.get_cmdline_args] does not carry `--resolution`: the engine
## consumes the arguments it recognises and hands the script only what is left.
## The `argv.has("--resolution")` that used to stand here was therefore never
## once true, and a settings file naming a size silently won every
## `tools/shot.sh`. See the trap list.
var _window_preset: bool = false

func _ready() -> void:
	load_or_create()
	_window_preset = _window_already_chosen()
	apply_display()

## Whether something other than this file has already decided the window's size
## or mode. Only meaningful before the first [method apply_display] — after one,
## the window is whatever we last set it to and this would always be true.
##
## The comparison is in logical pixels, because a compositor running a
## fractional output scale hands back a window bigger than the size anyone
## asked for: this container's Wayland session is at 1.25, where the untouched
## 1280x720 base is reported as 1600x900. The same scale is what makes
## `--resolution` logical for `tools/shot.sh`, so dividing it out compares like
## with like. [constant WINDOW_MATCH_SLACK] is the rounding that survives. This
## assumes `display/window/dpi/allow_hidpi`, Godot's default and what makes
## [method DisplayServer.window_get_size] a real pixel count on a Retina panel
## as well as on a scaled Wayland one.
func _window_already_chosen() -> bool:
	if DisplayServer.get_name() == "headless" or OS.has_feature("web"):
		return false
	var root: Window = get_tree().root
	if root.mode == Window.MODE_FULLSCREEN or root.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		return true
	var base := Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 0)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 0)))
	if base.x <= 0.0 or base.y <= 0.0:
		return false
	var screen: int = DisplayServer.window_get_current_screen()
	var scale: float = maxf(DisplayServer.screen_get_scale(screen), 0.01)
	var logical: Vector2 = Vector2(DisplayServer.window_get_size()) / scale
	return not window_sizes_match(logical, base)

## Whether [param a] and [param b] are the same window size to within
## [constant WINDOW_MATCH_SLACK]. Static and pure so [TestConfig] can check the
## rounding without a display server.
static func window_sizes_match(a: Vector2, b: Vector2) -> bool:
	return absf(a.x - b.x) <= WINDOW_MATCH_SLACK and absf(a.y - b.y) <= WINDOW_MATCH_SLACK

# ------------------------------------------------------------------
#                              the file
# ------------------------------------------------------------------

func load_or_create() -> void:
	if not FileAccess.file_exists(PATH):
		if save():
			print("wrote default settings to %s" % ProjectSettings.globalize_path(PATH))
		return
	var cfg := ConfigFile.new()
	var err: Error = cfg.load(PATH)
	if err != OK:
		push_warning("could not read %s (error %d) — using defaults" % [PATH, err])
		return
	read(cfg)

## Pull every known key out of [param cfg], leaving the default in place where
## the file is silent. Pure, so the tests can drive it from a string.
func read(cfg: ConfigFile) -> void:
	resolution = parse_resolution(str(cfg.get_value("display", "resolution",
		"%dx%d" % [resolution.x, resolution.y])), resolution)
	fullscreen = bool(cfg.get_value("display", "fullscreen", fullscreen))
	render_scale = clampf(float(cfg.get_value("display", "render_scale",
		render_scale)), 0.25, 2.0)
	ice_reflections = bool(cfg.get_value("display", "ice_reflections",
		ice_reflections))
	shadows = bool(cfg.get_value("display", "shadows", shadows))
	procedural_sky = str(cfg.get_value("display", "sky",
		"procedural" if procedural_sky else "etr")).strip_edges().to_lower() != "etr"
	night_lights = bool(cfg.get_value("display", "night_lights", night_lights))
	fog_start_distance = maxf(float(cfg.get_value("fog", "start_distance",
		fog_start_distance)), 0.0)
	fog_distance_scale = clampf(float(cfg.get_value("fog", "distance_scale",
		fog_distance_scale)), 0.1, 10.0)
	character = str(cfg.get_value("game", "character", character)).strip_edges()
	if character.is_empty():
		character = CharacterCatalog.DEFAULT_DIR
	opponents = clampi(int(cfg.get_value("game", "opponents", opponents)),
		1, RaceSetup.MAX_OPPONENTS)
	opponent_skill = AISkill.parse(str(cfg.get_value("game", "opponent_skill",
		AISkill.name_of(opponent_skill))))
	snowfall = clampi(int(cfg.get_value("game", "snowfall", snowfall)),
		0, SnowFall.MAX_GRADE)
	conditions = LightCondition.parse(str(cfg.get_value("game", "conditions",
		LightCondition.name_of(conditions))))
	wind = WindField.parse_strength(str(cfg.get_value("game", "wind",
		WindField.strength_name(wind))))
	player_name = str(cfg.get_value("multiplayer", "player_name",
		player_name)).strip_edges()
	if player_name.is_empty():
		player_name = "Racer"
	multiplayer_port = clampi(int(cfg.get_value("multiplayer", "port",
		multiplayer_port)), 1024, 65535)
	multiplayer_server = str(cfg.get_value("multiplayer", "server",
		multiplayer_server)).strip_edges()

## `"1280x720"` → `Vector2i(1280, 720)`; `"auto"` → [constant Vector2i.ZERO],
## meaning the window is left as the platform sized it. Anything unparseable
## keeps [param fallback], because a typo in a hand-edited file should not open
## a 0×0 window.
static func parse_resolution(text: String, fallback: Vector2i = Vector2i.ZERO) -> Vector2i:
	var trimmed: String = text.strip_edges().to_lower()
	if trimmed == "auto" or trimmed.is_empty():
		return Vector2i.ZERO
	var parts: PackedStringArray = trimmed.split("x", false)
	if parts.size() != 2 or not parts[0].strip_edges().is_valid_int() \
			or not parts[1].strip_edges().is_valid_int():
		push_warning("resolution '%s' is not WIDTHxHEIGHT — ignoring" % text)
		return fallback
	var size := Vector2i(parts[0].strip_edges().to_int(), parts[1].strip_edges().to_int())
	if size.x < 320 or size.y < 240:
		push_warning("resolution %s is too small — ignoring" % size)
		return fallback
	return size

## Write the current values out, comments and all. Returns whether it landed.
##
## [ConfigFile.save] would drop every comment, and a settings file nobody can
## read is a settings file nobody edits — ETR's `SaveConfigFile` interleaves
## `AddComment` and `AddItem` for the same reason. Written by hand here, and
## re-read through [ConfigFile] like any other. Which means the comments are
## regenerated on every save: editing the prose in the file does not survive
## the settings screen, editing the values does.
func save() -> bool:
	var f: FileAccess = FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("could not write %s (error %d)" % [PATH, FileAccess.get_open_error()])
		return false
	f.store_string(file_text())
	f.close()
	return true

## The exact text [method save] writes. Split out so the tests can read it back
## through [ConfigFile] without touching the user directory.
func file_text() -> String:
	return """; PenguinRacer settings.
; Plain text, read once at startup. Delete this file to get the defaults back.

[display]

; Window size, "WIDTHxHEIGHT" or "auto" to let the platform decide.
; Ignored on the web build, where the page sizes the canvas.
resolution = "%s"
fullscreen = %s

; Fraction of the window the 3D scene is rendered at before upscaling
; [0.25...2.0]. Below 1.0 buys framerate; the HUD stays sharp either way.
render_scale = %.2f

; Whether ice reflects the racers standing on it. The original reflects
; nothing; this is a second, half-resolution render of the characters every
; frame, so it is the first thing to turn off on a slow machine.
ice_reflections = %s

; Whether the racers and the trees cast a shadow on the snow. The original
; draws the character's shadow only at its highest detail level and never
; draws one for a tree; both are off under a cloudy or a night sky either way,
; and off entirely on the web build, whose renderer cannot draw one without
; blowing the whole frame out.
shadows = %s

; Which sky: "procedural" (sun, drifting clouds, distant mountains, haze that
; takes the sky's colour, mist in the valley, and stars, a moon and an aurora at
; night) or "etr" (the original's three photographed faces and its flat fog).
sky = "%s"

; Torches along the course and lanterns on the flags, under a night sky.
; The original lights nothing at night but the sky.
night_lights = %s

[fog]

; Metres of clear air before fog starts to build.
; The original's sunny and night environments start theirs at 0, which puts
; haze a few metres in front of the player. 0.0 renders what the data says.
start_distance = %.1f

; Multiplies the fog range migrated from the environment's light.lst.
; 1.0 is the original's 75 m white-out; larger sees further into the valley.
distance_scale = %.2f

[game]

; Who you race as: one of the directories under char/ in the original data —
; tux, trixi, boris, samuel or beastie. The Character screen sets this.
; A name that is not installed falls back to tux.
character = "%s"

; How many computer opponents the main menu's "Race the computer" entry starts
; with [1...9], and how well they drive: easy, medium or hard. The course
; screen sets both, and writes them back here.
; They are also `--opponents=N --difficulty=hard` on the command line, which is
; how a race is started without going through the menu.
opponents = %d
opponent_skill = "%s"

; How hard it is snowing [0...3]: none, a little, more, a lot. The original
; offers the same four on its race screen, and so does the course screen here.
; It is weather and nothing else — no racer drives differently in it.
; Also `--snow=2` on the command line, which outranks this for one run.
snowfall = %d

; What the sky is doing: sunny, cloudy or night. The original offers the same
; choice on its race screen, next to the snow, and so does the course screen
; here. Weather again — nobody drives differently under a night sky — but it
; is also the original's own rule about what casts a shadow: nothing does,
; under a cloudy or a night sky.
; Also `--light=night` on the command line, which outranks this for one run.
conditions = "%s"

; How hard the wind blows across the hill: none, light or strong. It comes from
; the left or the right — picked afresh at every start — sways the trees, blows
; the snow sideways and, a little, pushes a penguin in the air downwind. On
; the ground it changes nothing.
; Also `--crosswind=strong` on the command line, which outranks this for one run.
wind = "%s"

[multiplayer]

; What other racers see you called.
player_name = "%s"

; The lobby server "Network multiplayer" connects to: a host name, a host:port,
; or a full ws:// or wss:// URL. Leave it empty and the game works one out —
; the host that served the page in a browser, 127.0.0.1 on the desktop. The
; Network multiplayer screen writes back whatever you last connected to.
;     godot --headless --path game res://scenes/server.tscn -- --port=27015
server = "%s"

; Port the server listens on, and the one an address with no port of its own is
; assumed to use.
port = %d
""" % [_resolution_text(), str(fullscreen).to_lower(), render_scale,
		str(ice_reflections).to_lower(), str(shadows).to_lower(),
		"procedural" if procedural_sky else "etr", str(night_lights).to_lower(),
		fog_start_distance, fog_distance_scale, character,
		opponents, AISkill.name_of(opponent_skill), snowfall,
		LightCondition.name_of(conditions), WindField.strength_name(wind),
		player_name, multiplayer_server, multiplayer_port]

## `"auto"` when the window is the platform's to size, `"1280x720"` otherwise.
## The round trip through [method parse_resolution] has to survive: a saved
## `"0x0"` would be read back as a fallback and silently stop being "auto".
func _resolution_text() -> String:
	if resolution == Vector2i.ZERO:
		return "auto"
	return "%dx%d" % [resolution.x, resolution.y]

# ------------------------------------------------------------------
#                            what it drives
# ------------------------------------------------------------------

## Where fog begins and where it reaches full strength, for [param preset].
##
## Two scales multiply here on purpose and they are not the same knob:
## [member EnvironmentPreset.fog_distance_scale] is per environment and belongs
## to whoever authors the preset, while this one is global and belongs to the
## player.
func fog_range(preset: EnvironmentPreset) -> Vector2:
	var scale: float = preset.fog_distance_scale * fog_distance_scale
	var far_m: float = preset.fog_end * scale
	var near_m: float = maxf(preset.fog_start * scale, fog_start_distance)
	return Vector2(minf(near_m, far_m * MAX_START_FRACTION), far_m)

## Overwrite the fog distances on an [Environment] built by
## [method EnvironmentPreset.to_environment], which knows the data but not the
## player's preferences.
func apply_fog(env: Environment, preset: EnvironmentPreset) -> void:
	if not env.fog_enabled:
		return
	var range_m: Vector2 = fog_range(preset)
	env.fog_depth_begin = range_m.x
	env.fog_depth_end = range_m.y

## Size the window and the 3D viewport. Called at startup and again whenever
## [SettingsMenu] accepts a change, so it has to be able to put a value back as
## well as set it — `scaling_3d_scale` is assigned unconditionally for that
## reason, and leaving fullscreen is as explicit as entering it.
##
## Skipped wherever the setting is not ours to make: a headless run has no
## window, the web build's canvas is sized by the page, and a window the command
## line has already sized or fullscreened outranks the file — which is what
## keeps `tools/shot.sh` capturing at the size it asked for whatever this file
## says. See [member _window_preset] for why that last one is measured rather
## than read off `OS.get_cmdline_args()`.
##
## [param forced] is the settings screen pressing Ok: the player has just named
## a size, and a window the command line chose at launch stops outranking them
## the moment they do.
func apply_display(forced: bool = false) -> void:
	var root: Window = get_tree().root
	root.scaling_3d_scale = render_scale

	if DisplayServer.get_name() == "headless" or OS.has_feature("web"):
		return
	if forced:
		_window_preset = false
	if _window_preset:
		return
	if fullscreen:
		root.mode = Window.MODE_FULLSCREEN
		return
	if root.mode == Window.MODE_FULLSCREEN or root.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		root.mode = Window.MODE_WINDOWED
	if resolution != Vector2i.ZERO:
		root.size = resolution
