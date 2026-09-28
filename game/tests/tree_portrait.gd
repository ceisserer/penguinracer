## A close look at one tree species, outside any course: a few trees of the
## type on a flat white ground under Bunny Hill's sunny preset, drawn by the real
## [Forest] with the real shaders, and the frame saved. Not a test.
##
##     tools/tree_portrait.sh /tmp/bare.png bare [--dist=8] [--level=0..3]
##         [--eye=1.6] [--snow=0..3] [--count=5] [--fov=60]
##
## A race frame shows a tree at whatever distance the run put it; this puts it
## where the question is — a shrub 3 m off, the bare tree's LOD 2 at arm's
## length, the impostor next to the mesh it replaces. `--level` forces a level
## to the chosen distance by squeezing [member Forest.lod_scale] so that
## level's band holds it; 3 is the impostor. `--count` trees stand in a shallow
## arc across the view at that distance, each turned by its own yaw, the way
## [CourseRoot] turns them. A narrow `--fov` looks at a far level at its own
## distance, where the shaders widen the limbs and fade the twigs as they do
## in a race, rather than forcing it close.
extends SceneTree

const SIZES := {
	"conifer": Vector2(3.0, 6.0),
	"bare": Vector2(4.5, 5.5),
	"shrub": Vector2(2.0, 2.0),
}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: tree_portrait.gd -- out.png conifer|bare|shrub [--dist=] [--level=] ...")
		quit(2)
		return
	var out: String = args[0]
	var kind: String = args[1]
	var opts := {"dist": 8.0, "level": -1.0, "eye": 1.6, "snow": 0.0, "count": 5.0, "fov": 60.0}
	for a: String in args.slice(2):
		var kv: PackedStringArray = a.trim_prefix("--").split("=")
		if kv.size() == 2 and opts.has(kv[0]):
			opts[kv[0]] = float(kv[1])
	var species: Forest.Species = Forest.Species.CONIFER
	var texture: Texture2D = load("res://assets/objects/snowy_tree1.png")
	match kind:
		"bare":
			species = Forest.Species.BARE
		"shrub":
			species = Forest.Species.SHRUB
			texture = load("res://assets/objects/shrub.png")
	# No fog and no mist: every lit shader writes its own `FOG` from these
	# globals whatever the Environment says, and a far level compared through
	# fog is a comparison of fog.
	RenderingServer.global_shader_parameter_set("atmo_fog", Vector4(1.0e5, 2.0e5, 0.0, 0.0))
	RenderingServer.global_shader_parameter_set("atmo_mist", Vector4(0.0, 1.0, 0.0, 1.0e5))
	var preset: EnvironmentPreset = load("res://resources/environments/tuxracer_sunny.tres")
	var env: Environment = preset.to_environment()
	env.fog_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	preset.apply_sun(sun)
	sun.shadow_enabled = RenderingServer.get_current_rendering_method() != "gl_compatibility"
	root.add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.92, 0.95, 1.0)
	ground.material_override = gm
	root.add_child(ground)

	var d: float = opts["dist"]
	var size: Vector2 = SIZES[kind]
	var n: int = int(opts["count"])
	var xfs: Array[Transform3D] = []
	for i: int in n:
		# A shallow arc, one tree per ~1.3 diameters, the middle one nearest.
		var x: float = (float(i) - float(n - 1) * 0.5) * size.x * 1.3
		var p := Vector3(x, 0.0, -d - absf(x) * 0.3)
		var yaw: float = float(i) * 1.9
		xfs.push_back(Transform3D(Basis().rotated(Vector3.UP, yaw), p)
			.scaled_local(Vector3(size.x, size.y, size.x)))
	var forest := Forest.new()
	var level: int = int(opts["level"])
	if level >= 0:
		# The middle of the forced level's band lands on the distance.
		var mids: Array[float] = [0.0, 70.0, 110.0, 200.0]
		forest.lod_scale = 1.0 if level == 0 else d / mids[level]
	root.add_child(forest)
	forest.build(texture, xfs, species)
	forest.lod_scale /= forest._screen_scale
	forest._lay_out_bands()
	forest.set_ambient(preset.ambient_illumination())
	forest.set_weather(null, int(opts["snow"]))
	forest.set_shadow_casting(GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED)

	var cam := Camera3D.new()
	cam.fov = opts["fov"]
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0.0, opts["eye"], 0.0),
		Vector3(0.0, size.y * 0.45, -d), Vector3.UP)
	cam.make_current()

	for f: int in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	img.save_png(out)
	print("portrait: %s (%dx%d)" % [out, img.get_width(), img.get_height()])
	quit(0)
