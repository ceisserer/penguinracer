## A close look at one solid prop, outside any course: the prefab on a flat
## white ground under Bunny Hill's sunny preset, drawn with the real
## `object_prop.gdshader` as [CourseRoot] batches it, and the frame saved. Not
## a test.
##
##     tools/prop_portrait.sh /tmp/hut.png mountain_hut [--dist=14] [--eye=1.6]
##         [--orbit=0] [--textures=1] [--fov=60] [--size=x,y,z] [--snow=1]
##
## [code]--orbit[/code] walks the camera round the prop, in degrees from its
## front (+Z). [code]--textures=0[/code] draws it procedurally, 1 from the
## photographs ([member GameConfig.prop_textures]). [code]--size[/code] is the
## marker's scale; a park prop defaults to [method PropMesh.park_size], a rock
## or log to a typical one. [code]--snow[/code] is how snowy the ground round
## its foot is, 0..1 (`INSTANCE_CUSTOM.r`).
extends SceneTree

## A marker's scale for the props that are not built in metres: how big
## Mountain Forest makes them, about.
const SIZES := {
	"boulder": Vector3(2.2, 1.6, 2.2),
	"stones": Vector3(1.6, 1.0, 1.6),
	"log": Vector3(4.5, 0.5, 0.5),
	"stump": Vector3(0.8, 0.6, 0.8),
	"lodged_log": Vector3(10.0, 0.7, 0.7),
}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: prop_portrait.gd -- out.png <prefab> [--dist=] [--orbit=] ...")
		quit(2)
		return
	var out: String = args[0]
	var prefab: ObjectPrefab = load("res://resources/objects/%s.tres" % args[1])
	if prefab == null or prefab.mesh == null:
		push_error("no prop prefab %s" % args[1])
		quit(2)
		return
	var opts := {"dist": 14.0, "eye": 1.6, "orbit": 0.0, "textures": 1.0, "fov": 60.0,
		"snow": 1.0}
	var size: Vector3 = SIZES.get(args[1], Vector3.ONE)
	for kind: String in PropMesh.Kind.keys():
		if kind.to_lower() == args[1].trim_suffix("_b"):
			var park: Vector3 = PropMesh.park_size(PropMesh.Kind[kind])
			if park != Vector3.ONE:
				size = park
	for a: String in args.slice(2):
		var kv: PackedStringArray = a.trim_prefix("--").split("=")
		if kv.size() != 2:
			continue
		if kv[0] == "size":
			var v: PackedFloat64Array = kv[1].split_floats(",")
			size = Vector3(v[0], v[1], v[2])
		elif opts.has(kv[0]):
			opts[kv[0]] = float(kv[1])
	# No fog and no mist, as in the tree portrait.
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

	# One instance, batched as CourseRoot batches a prop: custom data for the
	# snow at its foot, white instance colours beside it.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.use_colors = true
	mm.mesh = prefab.mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D.IDENTITY.scaled_local(size))
	mm.set_instance_custom_data(0, Color(opts["snow"], 0.0, 0.0, 0.0))
	mm.set_instance_color(0, Color.WHITE)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var material: Material = prefab.material
	if opts["textures"] > 0.5:
		var textured: ShaderMaterial = CourseRoot.textured_prop_material(material as ShaderMaterial)
		if textured == null:
			push_warning("no photographed materials — drawing procedurally")
		else:
			material = textured
	(material as ShaderMaterial).set_shader_parameter("etr_ambient", preset.ambient_illumination())
	mmi.material_override = material
	root.add_child(mmi)

	var cam := Camera3D.new()
	cam.fov = opts["fov"]
	root.add_child(cam)
	var orbit: float = deg_to_rad(opts["orbit"])
	var d: float = opts["dist"]
	cam.look_at_from_position(Vector3(sin(orbit) * d, opts["eye"], cos(orbit) * d),
		Vector3(0.0, size.y * 0.4, 0.0), Vector3.UP)
	cam.make_current()

	for f: int in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	img.save_png(out)
	print("portrait: %s (%dx%d)" % [out, img.get_width(), img.get_height()])
	quit(0)
