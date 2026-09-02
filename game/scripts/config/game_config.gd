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

## Whether a race shows the player's best recorded run beside them.
##
## Recording happens either way and costs about 4 kB a run — see [RaceRecorder].
## This is only whether the ghost is drawn, so turning it off and back on again
## does not lose the times set in between.
var ghosts: bool = true

# --- multiplayer ---

## What other racers see this player called. ETR has `players.lst` and an avatar
## picture behind its registration screen; there are no profiles here yet, so
## the name is a settings key until there is somewhere better for it to live.
var player_name: String = "Racer"
## Port a hosted session listens on, and the one `--join=` assumes when the
## address does not carry its own.
var multiplayer_port: int = RaceNetwork.DEFAULT_PORT

func _ready() -> void:
	load_or_create()
	apply_display()

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
	fog_start_distance = maxf(float(cfg.get_value("fog", "start_distance",
		fog_start_distance)), 0.0)
	fog_distance_scale = clampf(float(cfg.get_value("fog", "distance_scale",
		fog_distance_scale)), 0.1, 10.0)
	character = str(cfg.get_value("game", "character", character)).strip_edges()
	if character.is_empty():
		character = CharacterCatalog.DEFAULT_DIR
	ghosts = bool(cfg.get_value("game", "ghosts", ghosts))
	player_name = str(cfg.get_value("multiplayer", "player_name",
		player_name)).strip_edges()
	if player_name.is_empty():
		player_name = "Racer"
	multiplayer_port = clampi(int(cfg.get_value("multiplayer", "port",
		multiplayer_port)), 1024, 65535)

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

; Race against your own best run on each course, drawn as a translucent
; penguin. Times are recorded either way; this only draws them.
ghosts = %s

[multiplayer]

; What other racers see you called.
player_name = "%s"

; Port a hosted session listens on. Multiplayer is desktop-only and is started
; from the command line for now:
;     godot --path game -- --host --course=bunny_hill
;     godot --path game -- --join=192.168.1.20 --course=bunny_hill
port = %d
""" % [_resolution_text(), str(fullscreen).to_lower(), render_scale,
		fog_start_distance, fog_distance_scale, character,
		str(ghosts).to_lower(), player_name, multiplayer_port]

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
## window, the web build's canvas is sized by the page, and an explicit
## `--resolution`/`--fullscreen` on the command line outranks the file — which
## is what keeps `tools/shot.sh` capturing at 1280x720 whatever this file says.
func apply_display() -> void:
	var root: Window = get_tree().root
	root.scaling_3d_scale = render_scale

	if DisplayServer.get_name() == "headless" or OS.has_feature("web"):
		return
	var argv: PackedStringArray = OS.get_cmdline_args()
	if argv.has("--resolution") or argv.has("-w") or argv.has("--windowed") \
			or argv.has("-f") or argv.has("--fullscreen"):
		return
	if fullscreen:
		root.mode = Window.MODE_FULLSCREEN
		return
	if root.mode == Window.MODE_FULLSCREEN or root.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		root.mode = Window.MODE_WINDOWED
	if resolution != Vector2i.ZERO:
		root.size = resolution
