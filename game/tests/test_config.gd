## The settings file: parsing, clamping, and the fog range it produces.
##
## [GameConfig] is instantiated directly rather than through the `Config`
## autoload — the same reason [TestAudio] builds its own [AudioDirector]. What
## is checked here is the arithmetic between a hand-edited file and an
## [Environment], because that is what a typo in the file breaks silently.
class_name TestConfig
extends RefCounted

static func run(t: TestCase) -> void:
	_defaults(t)
	_parsing(t)
	_round_trip(t)
	_fog_range(t)

## A [GameConfig] that has not read a file: what a fresh install renders at.
static func _defaults(t: TestCase) -> void:
	t.begin("config/defaults")
	var c := GameConfig.new()
	t.ok(c.resolution == Vector2i(1280, 720), "the window matches project.godot")
	t.ok(not c.fullscreen, "windowed by default")
	t.eq_f(c.render_scale, 1.0, 1e-6, "3D renders at full resolution")
	t.eq_f(c.fog_start_distance, 40.0, 1e-6, "40 m of clear air in front of the camera")
	t.eq_f(c.fog_distance_scale, 2.0, 1e-6, "the migrated fog range is doubled")
	c.free()

static func _read(text: String) -> GameConfig:
	var cfg := ConfigFile.new()
	cfg.parse(text)
	var c := GameConfig.new()
	c.read(cfg)
	return c

static func _parsing(t: TestCase) -> void:
	t.begin("config/parsing")

	var c: GameConfig = _read("""[display]
resolution = "1920x1080"
fullscreen = true
render_scale = 0.75
[fog]
start_distance = 10.0
distance_scale = 1.0
""")
	t.ok(c.resolution == Vector2i(1920, 1080), "a full line of display settings is read")
	t.ok(c.fullscreen, "fullscreen is a bool, not a 0/1 like ETR's file")
	t.eq_f(c.render_scale, 0.75, 1e-6, "render scale survives")
	t.eq_f(c.fog_start_distance, 10.0, 1e-6, "fog start survives")
	t.eq_f(c.fog_distance_scale, 1.0, 1e-6, "the original's fog is one line away")
	c.free()

	# A file that says nothing keeps every default: adding a key must never
	# require every existing file to grow it.
	c = _read("[display]\n")
	t.ok(c.resolution == Vector2i(1280, 720), "an empty section changes nothing")
	t.eq_f(c.fog_distance_scale, 2.0, 1e-6, "a missing key keeps its default")
	c.free()

	# Out-of-range values are clamped rather than obeyed. A render scale of 0
	# is a viewport with no pixels and a fog scale of 0 is fog at the camera.
	c = _read("[display]\nrender_scale = 12.0\n[fog]\ndistance_scale = 0.0\nstart_distance = -5.0\n")
	t.eq_f(c.render_scale, 2.0, 1e-6, "render scale is clamped to 2x")
	t.eq_f(c.fog_distance_scale, 0.1, 1e-6, "fog scale is clamped away from zero")
	t.eq_f(c.fog_start_distance, 0.0, 1e-6, "a negative fog start floors at zero")
	c.free()

	t.begin("config/resolution strings")
	t.ok(GameConfig.parse_resolution("1024x768") == Vector2i(1024, 768), "WIDTHxHEIGHT")
	t.ok(GameConfig.parse_resolution(" 1024 X 768 ") == Vector2i(1024, 768),
		"case and spacing are forgiven")
	t.ok(GameConfig.parse_resolution("auto") == Vector2i.ZERO,
		"'auto' hands the window back to the platform")
	t.ok(GameConfig.parse_resolution("") == Vector2i.ZERO, "so does an empty string")
	# A typo must not open a window nobody can see or click on.
	t.ok(GameConfig.parse_resolution("1024*768", Vector2i(800, 600)) == Vector2i(800, 600),
		"the wrong separator keeps the fallback")
	t.ok(GameConfig.parse_resolution("64x48", Vector2i(800, 600)) == Vector2i(800, 600),
		"an unusably small window keeps the fallback")

## What [SettingsMenu] does when Ok is pressed: move the values, write the file,
## read it back next launch. The file is generated as commented text rather than
## through [ConfigFile.save], so nothing checks the two halves agree except this.
static func _round_trip(t: TestCase) -> void:
	t.begin("config/round trip")
	var c := GameConfig.new()
	c.resolution = Vector2i(1920, 1080)
	c.fullscreen = true
	c.render_scale = 0.65
	c.fog_start_distance = 15.0
	c.fog_distance_scale = 1.3

	var back: GameConfig = _read(c.file_text())
	t.ok(back.resolution == Vector2i(1920, 1080), "a chosen resolution comes back")
	t.ok(back.fullscreen, "so does fullscreen, written as a bare true")
	t.eq_f(back.render_scale, 0.65, 1e-6, "and the render scale")
	t.eq_f(back.fog_start_distance, 15.0, 1e-6, "and where fog starts")
	t.eq_f(back.fog_distance_scale, 1.3, 1e-6, "and how far it reaches")

	# "auto" is the one value that is not a size, and writing it as 0x0 would
	# come back through parse_resolution as the fallback instead.
	c.resolution = Vector2i.ZERO
	t.ok(c.file_text().contains('resolution = "auto"'), "an unsized window writes 'auto'")
	back.free()
	back = _read(c.file_text())
	t.ok(back.resolution == Vector2i.ZERO, "and reads back as 'leave the window alone'")

	# The comments are the reason this is not ConfigFile.save, so they are part
	# of what the round trip has to preserve.
	t.ok(c.file_text().begins_with("; PenguinRacer settings."),
		"the file it writes is still the one a player can read")
	back.free()
	c.free()

static func _fog_range(t: TestCase) -> void:
	t.begin("config/fog range")
	var sunny := EnvironmentPreset.new()
	sunny.fog_start = 0.0
	sunny.fog_end = 75.0
	var cloudy := EnvironmentPreset.new()
	cloudy.fog_start = 30.0
	cloudy.fog_end = 80.0

	var c := GameConfig.new()
	var r: Vector2 = c.fog_range(sunny)
	t.eq_f(r.x, 40.0, 1e-4, "the sunny preset's [fogstart] 0 is lifted to the floor")
	t.eq_f(r.y, 150.0, 1e-4, "and its 75 m white-out doubles")
	r = c.fog_range(cloudy)
	t.eq_f(r.x, 60.0, 1e-4, "a preset that ships a start keeps it, scaled, when it is further")
	t.eq_f(r.y, 160.0, 1e-4, "the end scales with it")

	# The whole point of the knob: one line restores the original.
	c.fog_start_distance = 0.0
	c.fog_distance_scale = 1.0
	r = c.fog_range(sunny)
	t.eq_f(r.x, 0.0, 1e-4, "ETR's fog starts at the camera")
	t.eq_f(r.y, 75.0, 1e-4, "and reaches white at 75 m")

	# The preset's own scale is a second, independent knob.
	sunny.fog_distance_scale = 2.0
	r = c.fog_range(sunny)
	t.eq_f(r.y, 150.0, 1e-4, "the preset's scale multiplies the player's")
	sunny.fog_distance_scale = 1.0

	# A start pushed past the end would be a wall of fog switching on at once.
	c.fog_start_distance = 500.0
	r = c.fog_range(sunny)
	t.ok(r.x < r.y, "an absurd start still leaves a band to ramp across")
	t.eq_f(r.x, 75.0 * GameConfig.MAX_START_FRACTION, 1e-4, "clamped to a fraction of the end")

	# Fog switched off in the data stays off, whatever the file says.
	var no_fog := EnvironmentPreset.new()
	no_fog.fog_enabled = false
	var env: Environment = no_fog.to_environment()
	c.apply_fog(env, no_fog)
	t.ok(not env.fog_enabled, "apply_fog does not switch fog on")
	c.free()
