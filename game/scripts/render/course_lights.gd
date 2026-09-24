## Torches down both edges of the course and a lantern on every flag, under a
## night sky.
##
## DEVIATION: ETR lights nothing at night but the sky. Here each torch is a
## pole, a flame ([code]shaders/torch_flame.gdshader[/code]) and a pool of warm
## light on the snow and the trees round it — the eight nearest the camera, as
## global uniforms every lit shader reads through
## [code]atmo_torch_glow[/code] in [code]atmosphere.gdshaderinc[/code]. No
## [OmniLight3D]: the lit shaders here are ETR's one-light sum-then-clamp, and a
## second engine light would add the ambient to every fragment a second time.
## The racers use the engine's material and are not lit by it.
##
## Presentation only: a torch has no collision, and stands a metre outside the
## play area so no racer ever rides through one. Placed deterministically from
## the course, so a capture reproduces. `[display] night_lights = false`
## ([member GameConfig.night_lights]) is ETR's dark night.
class_name CourseLights
extends Node3D

## Metres between torches along an edge of the play area.
const SPACING := 22.0
## How far outside the play area a torch stands.
const OUTSET := 1.2
## How close a tree may stand before a torch gives its place up.
const TREE_CLEARANCE := 1.6
const POLE_HEIGHT := 1.5
## Flame quad height, metres.
const FLAME_SIZE := 0.75
const LANTERN_SIZE := 0.55
## Reach of a torch's light on the snow, metres.
const REACH := 8.0
## The torchlight's colour times strength, linear; a lantern gives this share.
const LIGHT := Color(1.0, 0.7, 0.32) * 1.1
const LANTERN_SHARE := 0.3
## Globals written per frame, see `atmosphere.gdshaderinc`.
const SLOTS := 8

## Every light, as position (the flame) and brightness.
var lights: Array[Vector4] = []
var _flames: MultiMeshInstance3D
var _poles: MultiMeshInstance3D
var _active: bool = false

## Place the torches for [param root]'s course. Call once, after
## [method CourseRoot.build_runtime].
func build(root: CourseRoot) -> void:
	lights.clear()
	var flames: Array[Transform3D] = []
	var poles: Array[Transform3D] = []
	var course: CourseData = root.course_data
	var surface: SurfaceProvider = root.surface

	# A lantern at the top of every flag.
	var flags: Array = root.object_transforms.get("flag", [])
	for xf: Transform3D in flags:
		var top: Vector3 = xf.origin + Vector3(0.0, xf.basis.y.length() + LANTERN_SIZE * 0.3, 0.0)
		lights.push_back(Vector4(top.x, top.y, top.z, LANTERN_SHARE))
		flames.push_back(Transform3D(Basis().scaled(Vector3.ONE * LANTERN_SIZE), top))

	for p: Vector3 in torch_positions(course, surface, root.trees, flags):
		var flame := p + Vector3(0.0, POLE_HEIGHT + FLAME_SIZE * 0.25, 0.0)
		lights.push_back(Vector4(flame.x, flame.y, flame.z, 1.0))
		flames.push_back(Transform3D(Basis().scaled(Vector3.ONE * FLAME_SIZE), flame))
		poles.push_back(Transform3D(Basis(), p + Vector3(0.0, POLE_HEIGHT * 0.5, 0.0)))

	_flames = _batch("Flames", _flame_mesh(), flames, _flame_material())
	_poles = _batch("Poles", _pole_mesh(), poles, _pole_material())
	set_active(false)

## Where the torches stand: every [constant SPACING] metres along each edge of
## the play area, [constant OUTSET] outside it, dropped where a tree or a flag
## is already standing.
static func torch_positions(course: CourseData, surface: SurfaceProvider,
		trees: ObjectGrid, flags: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	if course == null or surface == null:
		return out
	var bounds: PackedVector2Array = course.effective_play_bounds()
	if bounds.size() < 3:
		return out
	var centre := Vector2.ZERO
	for v: Vector2 in bounds:
		centre += v
	centre /= float(bounds.size())
	var near := PackedInt32Array()
	for i: int in bounds.size():
		var a: Vector2 = bounds[i]
		var b: Vector2 = bounds[(i + 1) % bounds.size()]
		var edge: Vector2 = b - a
		var length: float = edge.length()
		# The start and finish edges run across the course; torches there would
		# stand in the racers' way at the gate. Only the long sides are lit.
		if length < 1.0 or absf(edge.y) < 0.7 * length:
			continue
		var outward := Vector2(edge.y, -edge.x).normalized()
		if outward.dot((a + b) * 0.5 - centre) < 0.0:
			outward = -outward
		var count: int = floori(length / SPACING)
		for k: int in range(1, count + 1):
			var at: Vector2 = a + edge * (float(k) - 0.5) / float(count) + outward * OUTSET
			if not _clear_of(at, trees, near, flags):
				continue
			out.push_back(Vector3(at.x, surface.height_at(at.x, at.y), at.y))
	return out

static func _clear_of(at: Vector2, trees: ObjectGrid, near: PackedInt32Array,
		flags: Array) -> bool:
	if trees != null:
		for i: int in trees.query(at.x, at.y, near):
			var t: Vector3 = trees.positions[i]
			if Vector2(t.x, t.z).distance_to(at) < TREE_CLEARANCE + trees.diameters[i] * 0.5:
				return false
	for xf: Transform3D in flags:
		if Vector2(xf.origin.x, xf.origin.z).distance_to(at) < SPACING * 0.3:
			return false
	return true

## Show the torches and light the course by them, or put both out.
func set_active(on: bool) -> void:
	_active = on and not lights.is_empty()
	visible = _active
	if not _active:
		RenderingServer.global_shader_parameter_set("atmo_torch_light", Vector4.ZERO)

## Hand the shaders the [constant SLOTS] lights nearest [param camera], each
## flickering on its own phase at [param time] seconds.
func update(camera: Vector3, time: float) -> void:
	if not _active:
		return
	var picked: Array[Vector4] = nearest(lights, camera, SLOTS)
	for i: int in SLOTS:
		var v := Vector4(0.0, -1.0e6, 0.0, 0.0)
		if i < picked.size():
			v = picked[i]
			var phase: float = fposmod(v.x * 0.37 + v.z * 0.71, TAU)
			v.w *= 0.86 + 0.08 * sin(time * 7.3 + phase) + 0.06 * sin(time * 12.9 + phase * 2.0)
		RenderingServer.global_shader_parameter_set("atmo_torch_%d" % i, v)
	RenderingServer.global_shader_parameter_set("atmo_torch_light",
		Vector4(LIGHT.r, LIGHT.g, LIGHT.b, REACH))

## The [param count] entries of [param from] nearest [param to].
static func nearest(from: Array[Vector4], to: Vector3, count: int) -> Array[Vector4]:
	var scored: Array = []
	for v: Vector4 in from:
		var d := Vector3(v.x, v.y, v.z).distance_squared_to(to)
		scored.push_back([d, v])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array[Vector4] = []
	for i: int in mini(count, scored.size()):
		out.push_back(scored[i][1])
	return out

func _batch(node_name: String, mesh: Mesh, transforms: Array[Transform3D],
		material: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i: int in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi

static func _flame_mesh() -> Mesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	return quad

static func _flame_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/torch_flame.gdshader")
	return mat

static func _pole_mesh() -> Mesh:
	var pole := CylinderMesh.new()
	pole.top_radius = 0.035
	pole.bottom_radius = 0.045
	pole.height = POLE_HEIGHT
	pole.radial_segments = 6
	pole.rings = 1
	pole.cap_bottom = false
	return pole

static func _pole_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.1, 0.06)
	mat.roughness = 1.0
	return mat
