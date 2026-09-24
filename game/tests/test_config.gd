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
	_resolution_choices(t)
	_window_match(t)
	_round_trip(t)
	_fog_range(t)
	_launch_args(t)

## The slack in [method GameConfig.window_sizes_match], which is how
## [method GameConfig.apply_display] tells a window the command line sized from
## one nobody has touched.
##
## It has to be that and not an exact comparison because the comparison is made
## in logical pixels: a fractional output scale hands back a window bigger than
## the one that was asked for, and dividing the scale back out does not land on
## a whole number. This container's session is at 1.25, where the untouched
## 1280x720 base is reported as 1600x900 and a `--resolution 1200x514` window
## comes back as 1500x643 — 514.4 logical, not 514.
static func _window_match(t: TestCase) -> void:
	t.begin("config/window match")
	var base := Vector2(1280.0, 720.0)
	t.ok(GameConfig.window_sizes_match(base, base), "a window nobody touched is the base")
	t.ok(GameConfig.window_sizes_match(Vector2(1600.0, 900.0) / 1.25, base),
		"and so is the same window seen through a 1.25 output scale")
	t.ok(GameConfig.window_sizes_match(Vector2(1500.0, 643.0) / 1.25, Vector2(1200.0, 514.0)),
		"a scaled size that does not divide back out evenly still matches itself")
	t.ok(not GameConfig.window_sizes_match(Vector2(1024.0, 768.0), base),
		"a 4:3 window from the command line is not the base")
	t.ok(not GameConfig.window_sizes_match(Vector2(1280.0, 800.0), base),
		"and neither is one 80 px taller, which is the closest a standard mode gets")

## A [GameConfig] that has not read a file: what a fresh install renders at.
static func _defaults(t: TestCase) -> void:
	t.begin("config/defaults")
	var c := GameConfig.new()
	t.ok(c.resolution == Vector2i(1280, 720), "the window matches project.godot")
	t.ok(not c.fullscreen, "windowed by default")
	t.eq_f(c.render_scale, 1.0, 1e-6, "3D renders at full resolution")
	t.ok(c.ice_reflections, "and the ice reflects the racers on it")
	# Wanting shadows is the default; getting them is also up to the renderer
	# and the sky. See [method RaceScene._shadows_wanted].
	t.ok(c.shadows, "and the racers and the trees cast a shadow")
	t.ok(not c.show_fps, "and the HUD shows no frame rate, as in ETR")
	t.eq_f(c.fog_start_distance, 40.0, 1e-6, "40 m of clear air in front of the camera")
	t.eq_f(c.fog_distance_scale, 2.0, 1e-6, "the migrated fog range is doubled")
	t.ok(c.character == "tux", "and you race as the first row of characters.lst")
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
	c = _read("[game]\ncharacter = \"trixi\"\n")
	t.ok(c.character == "trixi", "the chosen character is read")
	c.free()

	# Unvalidated on purpose: a character can be missing from a narrowed export,
	# and the fallback belongs to CharacterCatalog rather than to the file, so
	# that an absent rig does not get written back over the player's choice.
	c = _read("[game]\ncharacter = \" beastie \"\n")
	t.ok(c.character == "beastie", "and stripped, because a hand-edited file has spaces")
	c.free()
	c = _read("[game]\ncharacter = \"\"\n")
	t.ok(c.character == "tux", "an empty name is the default, not an empty rig")
	c.free()

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

## The other half of the resolution setting: the list [SettingsMenu] offers
## for it, which [DisplayModes] builds from the display rather than from a
## hardcoded six.
##
## [method DisplayModes.sizes_for] is static and pure so this can drive it from
## screens no test machine has. What is checked is that the list is the display's
## and not a fixed one — a 16:9 monitor is never offered 16:10, nothing is
## offered a mode larger than the panel it would open on, and a size already in
## the file survives whatever the display says.
static func _resolution_choices(t: TestCase) -> void:
	t.begin("config/resolution choices")

	# A 1080p desktop with a 40 px panel along the bottom.
	var full_hd: Array[Vector2i] = DisplayModes.sizes_for(Vector2i(1920, 1080),
		Vector2i(1920, 1040), Vector2i(1280, 720))
	t.ok(full_hd[0] == Vector2i.ZERO, "'Auto' is the first row whatever the screen is")
	t.ok(full_hd.has(Vector2i(1920, 1080)),
		"the screen's own resolution is offered even though a panel covers part of it")
	t.ok(full_hd.has(Vector2i(1280, 720)) and full_hd.has(Vector2i(1600, 900)),
		"and the 16:9 modes under it")
	t.ok(not full_hd.has(Vector2i(2560, 1440)), "nothing larger than the screen")
	t.ok(not full_hd.has(Vector2i(1024, 768)) and not full_hd.has(Vector2i(1280, 800)),
		"and no shape the display does not have — those two only letterbox")

	# A 16:10 laptop gets a 16:10 list, which is the whole point of asking.
	var laptop: Array[Vector2i] = DisplayModes.sizes_for(Vector2i(1920, 1200),
		Vector2i(1920, 1160), Vector2i.ZERO)
	t.ok(laptop.has(Vector2i(1680, 1050)) and laptop.has(Vector2i(1280, 800)),
		"a 16:10 panel is offered 16:10")
	t.ok(not laptop.has(Vector2i(1920, 1080)), "and not the 16:9 sizes of the same width")

	# 1366x768 is 0.05 % off 16:9 and is one of its modes; the tolerance exists
	# for it and must not stretch far enough to let 16:10 through.
	t.ok(full_hd.has(Vector2i(1366, 768)), "1366x768 counts as 16:9")

	# A hand-edited file the display disagrees with still opens on its own value,
	# because a drop-down that cannot show it would resize the window on Ok.
	var odd: Array[Vector2i] = DisplayModes.sizes_for(Vector2i(1920, 1080),
		Vector2i(1920, 1040), Vector2i(1111, 777))
	t.ok(odd.has(Vector2i(1111, 777)), "a size only the file knows about is added")

	# A panel no standard mode shares a shape with — portrait here, and a 21:9
	# desktop is the common one — is offered fractions of itself rather than a
	# page of 4:3. Every row still has the display's shape, which is the whole
	# invariant: `stretch/aspect="keep"` letterboxes anything else.
	var portrait: Array[Vector2i] = DisplayModes.sizes_for(Vector2i(1080, 1920),
		Vector2i(1080, 1920), Vector2i.ZERO)
	t.ok(portrait.size() > DisplayModes.MIN_OFFERED,
		"an unusual panel is offered its own resolution scaled down, not nothing")
	t.ok(portrait.has(Vector2i(1080, 1920)), "with its own resolution among it")
	var wrong_shape := 0
	var too_big := 0
	for size: Vector2i in portrait:
		if size == Vector2i.ZERO:
			continue
		if size.x > 1080 or size.y > 1920:
			too_big += 1
		if absf(float(size.x) / float(size.y) - 1080.0 / 1920.0) > 0.01:
			wrong_shape += 1
	t.ok(too_big == 0, "nothing that would not fit on it")
	t.ok(wrong_shape == 0, "and nothing that would letterbox on it")

	# 21:9 matches one row of the catalogue and scales to another 20 px from it.
	var ultrawide: Array[Vector2i] = DisplayModes.sizes_for(Vector2i(3440, 1440),
		Vector2i(3440, 1400), Vector2i.ZERO)
	t.ok(ultrawide.has(Vector2i(2560, 1080)), "a 21:9 desktop keeps the 21:9 standard mode")
	t.ok(not ultrawide.has(Vector2i(1024, 768)) and not ultrawide.has(Vector2i(1920, 1080)),
		"and is offered no 4:3 or 16:9 to letterbox in")
	t.ok(not ultrawide.has(Vector2i(2580, 1080)),
		"the scaled size twenty pixels off a real mode is not a second row")

	# No display to ask — the headless run this suite is, or a platform that will
	# not say. Offering the catalogue beats offering an empty drop-down.
	var unknown: Array[Vector2i] = DisplayModes.sizes_for(Vector2i.ZERO,
		Vector2i.ZERO, Vector2i(1280, 720))
	t.ok(unknown.size() == DisplayModes.STANDARD_SIZES.size() + 1,
		"a silent display offers every standard mode, plus 'Auto'")

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
	c.character = "boris"
	c.shadows = false
	c.snowfall = 2
	c.conditions = LightCondition.Kind.NIGHT
	c.show_fps = true

	var back: GameConfig = _read(c.file_text())
	t.ok(back.resolution == Vector2i(1920, 1080), "a chosen resolution comes back")
	t.ok(back.fullscreen, "so does fullscreen, written as a bare true")
	t.eq_f(back.render_scale, 0.65, 1e-6, "and the render scale")
	t.eq_f(back.fog_start_distance, 15.0, 1e-6, "and where fog starts")
	t.eq_f(back.fog_distance_scale, 1.3, 1e-6, "and how far it reaches")
	t.ok(back.character == "boris", "and who the next race is run as")
	t.ok(back.show_fps, "and whether the HUD shows the frame rate")
	# Zero is the default and a real answer, so a key that fails to round-trip
	# looks exactly like a player who asked for clear weather.
	t.ok(back.snowfall == 2, "and how hard it was snowing last time")
	# Stored as a name rather than as the enum's number, because the enum has a
	# gap in it — [constant LightCondition.Kind.NIGHT] is 3, the way ETR's
	# `lightcond` indexes it — and a hand-edited `conditions = 3` would be a
	# worse file than `conditions = "night"`.
	t.ok(c.file_text().contains('conditions = "night"'),
		"the sky is written by name, not by its index")
	t.ok(back.conditions == LightCondition.Kind.NIGHT, "and what the sky was doing")
	# A bool that is written as `false` and read back as its `true` default is
	# the failure mode here, and it looks exactly like a setting nobody wired up.
	t.ok(not back.shadows, "and a player who has turned the shadows off")

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

## [LaunchArgs] is where the command line and the URL query became one list.
##
## The point of the class is that the two transports agree, so that is what is
## asserted: the same run described both ways has to come out the same object.
## Before it, six scripts walked the command line for their own flags and the
## URL was read in one of them for four keys, so `?opponents=5` was silently
## nothing — which is the kind of gap only a table like this one catches.
static func _launch_args(t: TestCase) -> void:
	t.begin("launch arguments")
	var cli := LaunchArgs.new()
	cli.parse(PackedStringArray([
		"--course=bunny_hill", "--character=trixi", "--auto-input=carve",
		"--camera=above", "--opponents=5", "--difficulty=hard",
		"--remote-keyboard", "--no-audio", "--no-intro", "--fps", "--wind=2",
		"--snow=3", "--light=night",
		"--capture=/tmp/a.png", "--capture-frames=200",
	]), {})
	t.ok(cli.course == "bunny_hill", "the course is read")
	t.ok(cli.course_scene_path() == "res://courses/bunny_hill/course.tscn",
		"and resolves to a scene path")
	t.ok(cli.character == "trixi", "the character is read")
	t.ok(cli.auto_input == "carve", "the scripted input is read")
	t.ok(cli.is_scripted(), "which makes this a scripted run")
	t.ok(cli.camera == "above", "the camera mode is read")
	t.ok(cli.opponents == 5, "the field size is read")
	t.ok(cli.difficulty == "hard", "the difficulty is read, unparsed")
	t.ok(cli.remote_keyboard, "the remote-keyboard flag is read")
	t.ok(cli.no_audio and cli.no_intro, "the two silencing flags are read")
	t.ok(cli.show_fps, "the HUD's frame-rate readout is asked for")
	t.ok(cli.wind == 2, "the wind grade is read")
	t.ok(cli.snow == 3, "and so is the snowfall grade")
	t.ok(cli.light == "night", "and the sky, unparsed like the difficulty")
	t.ok(LightCondition.parse(cli.light) == LightCondition.Kind.NIGHT,
		"which parses to the condition it names")
	t.ok(cli.capture_path == "/tmp/a.png" and cli.capture_frames == 200,
		"the capture request is read")

	# The same run, described the way a browser has to describe it.
	var url := LaunchArgs.new()
	url.parse(PackedStringArray(), {
		"course": "bunny_hill", "character": "trixi", "auto-input": "carve",
		"camera": "above", "opponents": "5", "difficulty": "hard",
		"remotekeyboard": "", "noaudio": "", "nointro": "", "fps": "", "wind": "2",
		"snow": "3", "light": "night",
		"capture": "/tmp/a.png", "capture-frames": "200",
	})
	t.ok(url.course == cli.course and url.character == cli.character,
		"a URL names the same course and character")
	t.ok(url.auto_input == cli.auto_input and url.camera == cli.camera,
		"and the same scripted input and camera")
	t.ok(url.opponents == cli.opponents and url.difficulty == cli.difficulty,
		"and the same field — which the URL could not ask for at all before")
	t.ok(url.no_audio == cli.no_audio and url.no_intro == cli.no_intro
		and url.remote_keyboard == cli.remote_keyboard, "and the same flags")
	t.ok(url.show_fps == cli.show_fps and url.wind == cli.wind
		and url.snow == cli.snow and url.light == cli.light,
		"and the same HUD readout and weather")
	t.ok(url.capture_path == cli.capture_path
		and url.capture_frames == cli.capture_frames, "and the same capture")

	t.begin("launch arguments: what skips the menu")
	# `--auto-input=` alone is enough; a bare `--capture=` deliberately is not,
	# because that is how the shell itself gets screenshotted.
	var empty := LaunchArgs.new()
	empty.parse(PackedStringArray(), {})
	t.ok(not empty.wants_direct_race(), "a bare run opens the menu")
	t.ok(empty.opponents == LaunchArgs.NO_OPPONENTS,
		"an unset field is not zero, which is a real answer")
	t.ok(empty.snow == LaunchArgs.NO_SNOW,
		"and neither is an unset sky — 0 is `--snow=0`, which overrides the file")
	var shot := LaunchArgs.new()
	shot.parse(PackedStringArray(["--capture=/tmp/menu.png"]), {})
	t.ok(not shot.wants_direct_race(), "a bare capture screenshots the menu")
	t.ok(not shot.is_scripted(), "and is not a scripted run")
	for argv: PackedStringArray in [
			PackedStringArray(["--course=bunny_hill"]),
			PackedStringArray(["--auto-input=carve"])]:
		var a := LaunchArgs.new()
		a.parse(argv, {})
		t.ok(a.wants_direct_race(), "%s hands straight over to a race" % argv[0])
	var auto := LaunchArgs.new()
	auto.parse(PackedStringArray(), {"autostart": ""})
	t.ok(auto.wants_direct_race(), "?autostart does too, for a browser")

	t.begin("launch arguments: sessions")
	# A session no longer skips the menu — it opens the lobby, because the
	# course belongs to the room and not to the command line.
	var named := LaunchArgs.new()
	named.parse(PackedStringArray(["--server=penguin.example:27100"]), {})
	t.ok(named.server == "penguin.example:27100", "--server= is read")
	t.ok(named.wants_lobby() and not named.wants_direct_race(),
		"and opens the lobby rather than a course")
	var bare_lobby := LaunchArgs.new()
	bare_lobby.parse(PackedStringArray(["--lobby"]), {})
	t.ok(bare_lobby.wants_lobby() and bare_lobby.server.is_empty(),
		"--lobby takes the server the settings file names")
	var linked := LaunchArgs.new()
	linked.parse(PackedStringArray(), {"server": "ws://penguin.example:27015"})
	t.ok(linked.wants_lobby() and linked.server == "ws://penguin.example:27015",
		"?server= does the same from a link")
	var serving := LaunchArgs.new()
	serving.parse(PackedStringArray(["--port=27100", "--web-root=../build/web",
		"--web-port=8099"]), {})
	t.ok(serving.server_port == 27100 and serving.web_root == "../build/web"
		and serving.web_port == 8099, "the dedicated server reads its own three flags")
	t.ok(not serving.wants_lobby() and not serving.wants_direct_race(),
		"and none of them are a request to play anything")
