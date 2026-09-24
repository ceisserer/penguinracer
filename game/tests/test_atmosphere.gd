## The sky and the air: [Atmosphere], `atmosphere.gdshaderinc`, the procedural
## sky and the night torches ([CourseLights]).
##
## The headless suite cannot see a pixel, and the renderer it runs on is a
## dummy that hands no global uniform back. So this holds what can go wrong in
## writing: a global the shaders read that the project never declares (the
## shader then fails to compile, and every lit surface with it), a lit shader
## that forgets the atmosphere and fades to the old flat fog in front of the new
## sky, torchlight added outside ETR's clamp, and — the revert switch — whether
## `[display] sky = etr` still asks for exactly ETR's fog.
class_name TestAtmosphere
extends RefCounted

const INCLUDE := "res://shaders/atmosphere.gdshaderinc"
## Every shader that lights a surface in the race and so has to fade the way
## the sky behind it does.
const LIT_SHADERS: Array[String] = [
	"res://shaders/terrain.gdshader",
	"res://shaders/conifer.gdshader",
	"res://shaders/conifer_impostor.gdshader",
	"res://shaders/object_cross.gdshader",
	"res://shaders/object_billboard.gdshader",
]

static func run(t: TestCase) -> void:
	_every_global_is_declared(t)
	_every_lit_surface_fades_into_the_sky(t)
	_torchlight_is_inside_the_clamp(t)
	_the_sky_encodes_on_compatibility(t)
	_every_light_has_a_look(t)
	_etr_sky_is_etr_fog(t)
	_the_procedural_sky(t)
	_the_valley_floor(t)
	_the_ridges_sink_as_you_climb(t)
	_the_backdrop_dips_with_the_slope(t)
	_torches(t)
	_nearest_lights(t)
	_settings(t)

static func _read(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""

## A `global uniform` the project does not declare is a compile error, and a
## shader that fails to compile draws nothing — the whole course would vanish
## over one missing line in `project.godot`. [Atmosphere] writes them by name
## too, so a name here has to be a name there.
static func _every_global_is_declared(t: TestCase) -> void:
	t.begin("atmosphere/globals")
	var include: String = _read(INCLUDE)
	t.ok(not include.is_empty(), "atmosphere.gdshaderinc is on disk")
	var project: String = _read("res://project.godot")
	var re := RegEx.create_from_string("global uniform \\w+ (\\w+);")
	var names: PackedStringArray = PackedStringArray()
	for m: RegExMatch in re.search_all(include):
		names.push_back(m.get_string(1))
	t.ok(names.size() >= 12, "the include reads its state from globals (%d)" % names.size())
	for name: String in names:
		t.ok(project.contains("\n%s={" % name), "project.godot declares `%s`" % name)
	var g: Dictionary = Atmosphere.globals_for(_preset("etr_sunny"), 40.0, 150.0, true,
		0.0, 1.0, true)
	for name: String in g:
		t.ok(names.has(name), "Atmosphere writes `%s`, which the include reads" % name)
	for i: int in CourseLights.SLOTS:
		t.ok(names.has("atmo_torch_%d" % i), "and the torch slot %d exists" % i)

static func _every_lit_surface_fades_into_the_sky(t: TestCase) -> void:
	t.begin("atmosphere/every lit surface")
	for path: String in LIT_SHADERS:
		var text: String = _read(path)
		var name: String = path.get_file()
		t.ok(text.contains("#include \"%s\"" % INCLUDE), "%s includes the atmosphere" % name)
		# Without it the engine's flat fog colour is drawn in front of a sky
		# that is no longer flat — a far slope turns into a pale cut-out.
		t.ok(text.contains("FOG = atmo_fog_at("), "%s writes its own fog" % name)

## A torch is one more light in ETR's sum, so it goes inside the `min`. Added
## after it, a torch would lift snow past its own albedo — the exact thing the
## clamp exists to stop (see `etr_illumination.gdshaderinc`).
static func _torchlight_is_inside_the_clamp(t: TestCase) -> void:
	t.begin("atmosphere/torchlight is clamped")
	var re := RegEx.create_from_string(
		"DIFFUSE_LIGHT \\+= min\\(etr_illumination\\([^;]*\\+ torch_glow,\\s*vec3\\(1\\.0\\)\\);")
	for path: String in LIT_SHADERS:
		var text: String = _read(path)
		t.ok(re.search(text) != null,
			"%s sums the torchlight with the ambient and sun, then clamps" % path.get_file())
		t.ok(text.contains("torch_glow = atmo_torch_glow("),
			"%s works the torchlight out in fragment()" % path.get_file())

## Compatibility's sky pass does not encode its output, and this sky is built
## in linear; without the encode the web build's backdrop is an sRGB curve too
## dark and no longer the colour the far terrain fades to.
static func _the_sky_encodes_on_compatibility(t: TestCase) -> void:
	t.begin("atmosphere/the sky on the web")
	var text: String = _read("res://shaders/procedural_sky.gdshader")
	t.ok(text.contains("#if CURRENT_RENDERER == RENDERER_COMPATIBILITY"),
		"the sky asks which renderer it is on")
	t.ok(text.count("COLOR = display_encoded(") == 2,
		"and both passes it draws go through the encode")

static func _every_light_has_a_look(t: TestCase) -> void:
	t.begin("atmosphere/looks")
	for light: String in LightCondition.ALL_NAMES:
		t.ok(Atmosphere.LOOKS.has(light), "there is a look for `%s`" % light)
		var look: Dictionary = Atmosphere.LOOKS.get(light, {})
		for key: String in ["cover", "disc", "glow", "night", "mist", "ridge_light", "ridge_haze", "blue", "zenith_lift"]:
			t.ok(look.has(key), "`%s` says %s" % [light, key])
	for id: String in ["etr_sunny", "tuxracer_cloudy", "etr_evening", "tuxracer_night"]:
		var preset: EnvironmentPreset = _preset(id)
		t.ok(preset != null and Atmosphere.light_name(preset) == id.get_slice("_", 1),
			"%s is read as its own light" % id)
	var authored := EnvironmentPreset.new()
	authored.id = &"my_course"
	t.ok(Atmosphere.light_name(authored) == "sunny", "an authored preset is day")
	# A clear sky reads by its colour: the mist on it is lighter than under
	# overcast, and its zenith is blue rather than the grey-lavender average of
	# a photograph that is half mountain.
	for light: String in ["sunny", "night"]:
		t.ok(float(Atmosphere.LOOKS[light]["mist"]) < float(Atmosphere.LOOKS["cloudy"]["mist"]),
			"%s has less mist than an overcast day" % light)
	var zenith: Color = Atmosphere.sky_colours(_preset("etr_sunny"))["zenith"]
	t.ok(zenith.b > 2.5 * zenith.r and zenith.b > 1.8 * zenith.g,
		"a sunny zenith is blue (%.3f, %.3f, %.3f)" % [zenith.r, zenith.g, zenith.b])
	t.ok(float(Atmosphere.LOOKS["night"]["night"]) > 0.0
		and float(Atmosphere.LOOKS["sunny"]["night"]) == 0.0,
		"only the night has stars, a moon and torches")

## The revert switch. Aerial perspective, mist and ridges all off, and the fog
## colour ETR's own `[fogcol]` — which with Godot's `smoothstep` ramp is the
## fog the engine used to draw, to the level (measured: a Bunny Hill capture
## under `--sky=etr` matches the pre-atmosphere frame on both renderers).
static func _etr_sky_is_etr_fog(t: TestCase) -> void:
	t.begin("atmosphere/sky = etr")
	for id: String in ["etr_sunny", "etr_night", "tuxracer_cloudy"]:
		var preset: EnvironmentPreset = _preset(id)
		var g: Dictionary = Atmosphere.globals_for(preset, 40.0, 150.0, true, -200.0, 3.0, false)
		var fog: Vector4 = g["atmo_fog"]
		t.ok(is_equal_approx(fog.x, 40.0) and is_equal_approx(fog.y, 150.0),
			"%s: the fog range is the one handed in" % id)
		t.ok(fog.z == 0.0 and fog.w == 0.0, "%s: no aerial perspective, no ridges" % id)
		t.ok((g["atmo_mist"] as Vector4).z == 0.0, "%s: no mist" % id)
		var c: Color = preset.fog_color.srgb_to_linear()
		t.eq_v(g["atmo_fog_color"], Vector3(c.r, c.g, c.b), 1e-6,
			"%s: the fog fades to `[fogcol]`, as the engine's did" % id)

static func _the_procedural_sky(t: TestCase) -> void:
	t.begin("atmosphere/sky = procedural")
	var sunny: EnvironmentPreset = _preset("etr_sunny")
	var g: Dictionary = Atmosphere.globals_for(sunny, 40.0, 150.0, true, -200.0, 3.0, true)
	var fog: Vector4 = g["atmo_fog"]
	t.ok(fog.z == 1.0 and fog.w == 1.0, "the far field fades into the sky and the ridges")
	var mist: Vector4 = g["atmo_mist"]
	t.ok(mist.z > 0.0, "there is mist in the valley")
	t.ok(mist.x < -200.0, "and it settles below the course's lowest point")
	# The near field was fitted against a reference capture at 40 m of clear
	# air; the mist must not reach inside that.
	t.ok(mist.w >= fog.x, "the mist starts no nearer than the fog does")
	t.eq_v(g["atmo_sun_dir"], sunny.sun_direction.normalized(), 1e-6,
		"by day the disc is where the light comes from")
	var night: Dictionary = Atmosphere.globals_for(_preset("etr_night"), 40.0, 150.0, true,
		0.0, 0.0, true)
	var moon: Vector3 = night["atmo_sun_dir"]
	t.ok(moon.z < -0.8 and moon.y > 0.05 and moon.y < 0.3,
		"by night the moon stands low ahead of a racer, where a chase camera can see it")
	t.ok(float(night["atmo_night"]) == 1.0, "and the night is night")
	var no_fog: Dictionary = Atmosphere.globals_for(sunny, 40.0, 150.0, false, 0.0, 0.0, true)
	t.ok((no_fog["atmo_mist"] as Vector4).z == 0.0, "fog switched off takes the mist with it")

	# The Environment side, which needs no renderer.
	var env: Environment = sunny.to_environment()
	var atmo := Atmosphere.new()
	atmo.apply(env, sunny, null, null, true)
	var mat: ShaderMaterial = env.sky.sky_material as ShaderMaterial
	t.ok(mat != null and mat.shader.resource_path == "res://shaders/procedural_sky.gdshader",
		"the sky is the procedural one")
	t.ok(env.fog_sky_affect == 0.0, "and the flat fog is kept off it")
	var etr_env: Environment = sunny.to_environment()
	Atmosphere.new().apply(etr_env, sunny, null, null, false)
	var etr_mat: ShaderMaterial = etr_env.sky.sky_material as ShaderMaterial
	t.ok(etr_mat != null and etr_mat.shader.resource_path == "res://shaders/etr_skybox.gdshader",
		"sky = etr keeps the migrated faces")
	t.ok(is_equal_approx(etr_env.fog_sky_affect, sunny.fog_sky_affect),
		"and their fog")

static func _the_valley_floor(t: TestCase) -> void:
	t.begin("atmosphere/valley floor")
	var course: CourseData = load("res://courses/bunny_hill/course.tres")
	var surface := HeightmapSurface.from_course(course)
	var floor_y: float = Atmosphere.valley_floor(course, surface)
	var start: Vector2 = course.start_position
	t.ok(floor_y < surface.height_at(start.x, -start.y),
		"the valley floor is below the start")
	t.ok(floor_y <= surface.height_at(course.world_size.x * 0.5, course.finish_line_z) + 0.01,
		"and no higher than the finish")
	t.ok(Atmosphere.ridge_seed(course) == Atmosphere.ridge_seed(course),
		"the skyline is the same every time for one course")

## The ridges are a few kilometres off: a racer high above the valley looks
## down on them, but never so far down that they leave the frame.
static func _the_ridges_sink_as_you_climb(t: TestCase) -> void:
	t.begin("atmosphere/ridge drop")
	var atmo := Atmosphere.new()
	atmo.apply(_preset("etr_sunny").to_environment(), _preset("etr_sunny"), null, null, true)
	atmo.advance(0.0, 0.0)
	var low: float = atmo._ridges.w
	atmo.advance(0.0, 200.0)
	var high: float = atmo._ridges.w
	atmo.advance(0.0, 5000.0)
	t.ok(low == 0.0 and high > 0.0, "higher up, the ridges sit lower")
	t.eq_f(atmo._ridges.w, Atmosphere.MAX_RIDGE_DROP, 1e-6, "but only so far")

static func _torches(t: TestCase) -> void:
	t.begin("atmosphere/torches")
	var scene: PackedScene = load("res://courses/bunny_hill/course.tscn")
	var root: CourseRoot = scene.instantiate() as CourseRoot
	root.build_runtime()
	var flags: Array = root.object_transforms.get("flag", [])
	t.ok(not flags.is_empty(), "Bunny Hill's flags are on record for their lanterns")
	var course: CourseData = root.course_data
	var placed: PackedVector3Array = CourseLights.torch_positions(course, root.surface,
		root.trees, flags)
	t.ok(placed.size() >= 4, "the course has torches along it (%d)" % placed.size())
	t.ok(placed == CourseLights.torch_positions(course, root.surface, root.trees, flags),
		"in the same places every time")
	var bounds: PackedVector2Array = course.effective_play_bounds()
	var near := PackedInt32Array()
	var inside: int = 0
	var crowded: int = 0
	var floating: int = 0
	for p: Vector3 in placed:
		if Geometry2D.is_point_in_polygon(Vector2(p.x, p.z), bounds):
			inside += 1
		for i: int in root.trees.query(p.x, p.z, near):
			var tree: Vector3 = root.trees.positions[i]
			if Vector2(tree.x, tree.z).distance_to(Vector2(p.x, p.z)) \
					< CourseLights.TREE_CLEARANCE + root.trees.diameters[i] * 0.5 - 1e-3:
				crowded += 1
		if absf(p.y - root.surface.height_at(p.x, p.z)) > 1e-3:
			floating += 1
	t.ok(inside == 0, "no torch stands where a racer can ride (%d did)" % inside)
	t.ok(crowded == 0, "and none stands in a tree (%d did)" % crowded)
	t.ok(floating == 0, "and every one stands on the snow")

	var lights := CourseLights.new()
	root.add_child(lights)
	lights.build(root)
	t.eq_f(float(lights.lights.size()), float(flags.size() + placed.size()), 0.0,
		"a light per lantern and per torch")
	lights.set_active(true)
	t.ok(lights.visible, "lit, they show")
	lights.set_active(false)
	t.ok(not lights.visible, "out, they do not")
	root.free()

static func _nearest_lights(t: TestCase) -> void:
	t.begin("atmosphere/nearest torches")
	var from: Array[Vector4] = []
	for i: int in 20:
		from.push_back(Vector4(float(i) * 10.0, 0.0, 0.0, 1.0))
	var picked: Array[Vector4] = CourseLights.nearest(from, Vector3(52.0, 0.0, 0.0), 3)
	t.ok(picked.size() == 3, "as many as asked for")
	t.ok(picked[0].x == 50.0 and picked[1].x == 60.0 and picked[2].x == 40.0,
		"nearest first")
	t.ok(CourseLights.nearest(from.slice(0, 2), Vector3.ZERO, 8).size() == 2,
		"and no more than there are")

static func _settings(t: TestCase) -> void:
	t.begin("atmosphere/settings")
	var c := GameConfig.new()
	t.ok(c.procedural_sky and c.night_lights, "the drawn sky and the torches by default")
	c.procedural_sky = false
	c.night_lights = false
	var cfg := ConfigFile.new()
	t.ok(cfg.parse(c.file_text()) == OK, "the settings file parses")
	t.ok(str(cfg.get_value("display", "sky", "")) == "etr", "the sky is written by name")
	var back := GameConfig.new()
	back.read(cfg)
	t.ok(not back.procedural_sky and not back.night_lights, "and both come back")
	c.free()
	back.free()
	var args := LaunchArgs.new()
	args.parse(PackedStringArray(["--sky=etr"]), {})
	t.ok(args.sky == "etr", "--sky= is read")
	var url := LaunchArgs.new()
	url.parse(PackedStringArray(), {"sky": "etr"})
	t.ok(url.sky == "etr", "and so is ?sky=")

## A chase camera at its pitch clamp sees nothing above -5 degrees, so the
## backdrop's horizon is lowered with the course's slope — and only under the
## procedural sky: `sky = etr` is the migrated faces, untouched.
static func _the_backdrop_dips_with_the_slope(t: TestCase) -> void:
	t.begin("atmosphere/horizon dip")
	t.ok(Atmosphere.horizon_dip(null) == 0.0, "no course, no dip")
	var gentle := CourseData.new()
	gentle.base_angle = 20.0
	var steep := CourseData.new()
	steep.base_angle = 30.0
	var sheer := CourseData.new()
	sheer.base_angle = 60.0
	var top_of_frame: float = tan(deg_to_rad(ChaseCamera.MAX_PITCH_DEGREES - 35.0))
	t.ok(Atmosphere.horizon_dip(steep) > top_of_frame,
		"on a 30 degree course the backdrop's horizon is below the top of the frame")
	t.ok(Atmosphere.horizon_dip(steep) < tan(deg_to_rad(30.0)),
		"and above where the fall line meets the fog, so the ridges show")
	t.ok(Atmosphere.horizon_dip(gentle) < Atmosphere.horizon_dip(steep),
		"a gentler course dips it less")
	t.ok(is_equal_approx(Atmosphere.horizon_dip(sheer),
		tan(deg_to_rad(Atmosphere.MAX_DIP_DEGREES))), "and a sheer one no further than the cap")
	var sunny: EnvironmentPreset = _preset("etr_sunny")
	var g: Dictionary = Atmosphere.globals_for(sunny, 40.0, 150.0, true, 0.0, 0.0, true, 0.4)
	t.ok(is_equal_approx(float(g["atmo_dip"]), 0.4), "the procedural sky takes the dip")
	var etr: Dictionary = Atmosphere.globals_for(sunny, 40.0, 150.0, true, 0.0, 0.0, false, 0.4)
	t.ok(float(etr["atmo_dip"]) == 0.0, "sky = etr does not")

static func _preset(id: String) -> EnvironmentPreset:
	return load("res://resources/environments/%s.tres" % id) as EnvironmentPreset
