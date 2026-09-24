## Torches down both edges of the course and in place of every flag, under a
## night sky.
##
## DEVIATION: ETR lights nothing at night but the sky. Here each torch is a
## pole, a flame ([code]shaders/torch_flame.gdshader[/code]) and a pool of warm
## light on the snow and the trees round it. A flag gives its place up to a
## torch while they burn: the flag's batch is hidden and a torch stands where
## it stood. No [OmniLight3D]: the lit shaders here are ETR's one-light
## sum-then-clamp, and a second engine light would add the ambient to every
## fragment a second time. The racers use the engine's material and are not
## lit by it.
##
## Two paths to the shaders. The terrain's pools are **baked** once, for every
## torch on the course, into the terrain's vertex colour
## ([method bake_terrain], [member terrain_light]) — a flame seen 200 m down
## the hill has its pool under it. Trees and objects still read the eight
## nearest the camera, as global uniforms through [code]atmo_torch_glow[/code]
## in [code]atmosphere.gdshaderinc[/code]. Both are scaled by the same
## [code]atmo_torch_light[/code], which is zero whenever the torches are out.
##
## Presentation only: a torch has no collision. An edge torch stands a metre
## outside the play area so no racer ever rides through one; a flag's torch
## stands where the (equally intangible) flag did. Placed deterministically
## from the course, so a capture reproduces. `[display] night_lights = false`
## ([member GameConfig.night_lights]) is ETR's dark night, flags and all.
class_name CourseLights
extends Node3D

## Metres between torches along an edge of the play area.
const SPACING := 22.0
## How far outside the play area a torch stands.
const OUTSET := 1.2
## How close a tree may stand before a torch gives its place up.
const TREE_CLEARANCE := 1.6
const POLE_HEIGHT := 0.9
## Flame quad height, metres.
const FLAME_SIZE := 0.75
## Reach of a torch's light on the snow, metres.
const REACH := 8.0
## The torchlight's colour times strength, linear; a flag's torch gives this
## share, since it stands in the middle of the run rather than at its edge and
## at full strength warms the whole piste.
const LIGHT := Color(1.0, 0.7, 0.32) * 1.1
const FLAG_SHARE := 0.3
## The object type a torch replaces at night.
const FLAG_TYPE := "flag"
## Globals written per frame, see `atmosphere.gdshaderinc`.
const SLOTS := 8

## Every light, as position (the flame) and brightness.
var lights: Array[Vector4] = []
## Every light's pool on the terrain, one byte per heightmap vertex — see
## [method bake_terrain]. Empty when the course has no torches.
var terrain_light: PackedByteArray = PackedByteArray()
var _root: CourseRoot
var _flames: MultiMeshInstance3D
var _poles: MultiMeshInstance3D
var _active: bool = false

## Place the torches for [param root]'s course and bake their light into
## [member terrain_light]. Call once, after [method CourseRoot.build_runtime],
## and before the terrain builds its first chunk.
func build(root: CourseRoot) -> void:
	_root = root
	lights.clear()
	var flames: Array[Transform3D] = []
	var poles: Array[Transform3D] = []
	var course: CourseData = root.course_data
	var surface: SurfaceProvider = root.surface

	# A torch where every flag stands, then the two edges.
	var flags: Array = root.object_transforms.get(FLAG_TYPE, [])
	var feet := PackedVector3Array()
	for xf: Transform3D in flags:
		feet.push_back(xf.origin)
	feet.append_array(torch_positions(course, surface, root.trees, flags))
	for k: int in feet.size():
		var p: Vector3 = feet[k]
		var flame := p + Vector3(0.0, POLE_HEIGHT + FLAME_SIZE * 0.25, 0.0)
		var share: float = FLAG_SHARE if k < flags.size() else 1.0
		lights.push_back(Vector4(flame.x, flame.y, flame.z, share))
		flames.push_back(Transform3D(Basis().scaled(Vector3.ONE * FLAME_SIZE), flame))
		poles.push_back(Transform3D(Basis(), p + Vector3(0.0, POLE_HEIGHT * 0.5, 0.0)))

	terrain_light = bake_terrain(lights, root.surface, REACH)
	_flames = _batch("Flames", _flame_mesh(), flames, _flame_material())
	_poles = _batch("Poles", _pole_mesh(), poles, _pole_material())
	set_active(false)

## Every light in [param from] summed onto each vertex of [param surface]'s
## grid, as one byte per vertex in the grid's row-major order — or empty for no
## lights. The same falloff and wrapped facing as `atmo_torch_one` in
## `atmosphere.gdshaderinc`, at full brightness (no flicker), against the
## vertex's smooth normal: the terrain mesh puts a vertex on every texel of
## this grid ([method TerrainRenderer._build_chunk]), so it reads these bytes
## straight into its vertex colour.
##
## Stored as the square root of the sum, clamped to 1, and squared back by
## `terrain.gdshader`: a pool's edge is where the value is small, and a linear
## byte there steps by 1/255 of full torchlight — a visible contour on dark
## night snow. Pools stand 22 m apart and reach 8 m, so the clamp is never met
## in practice.
static func bake_terrain(from: Array[Vector4], surface: HeightmapSurface,
		reach: float) -> PackedByteArray:
	if from.is_empty() or surface == null or reach <= 0.0:
		return PackedByteArray()
	var w: int = surface.size.x
	var h: int = surface.size.y
	var sx: float = surface.world_size.x / maxf(1.0, float(w - 1))
	var sz: float = surface.world_size.y / maxf(1.0, float(h - 1))
	var heights: PackedFloat32Array = surface.heights
	var normals: PackedVector3Array = surface.normals
	var sum := PackedFloat32Array()
	sum.resize(w * h)
	for light: Vector4 in from:
		var at := Vector3(light.x, light.y, light.z)
		# Grid x runs along +X, grid y along -Z.
		var i0: int = maxi(0, floori((at.x - reach) / sx))
		var i1: int = mini(w - 1, ceili((at.x + reach) / sx))
		var j0: int = maxi(0, floori((-at.z - reach) / sz))
		var j1: int = mini(h - 1, ceili((-at.z + reach) / sz))
		for j: int in range(j0, j1 + 1):
			var wz: float = -float(j) * sz
			var base_y: float = surface.slope * wz
			for i: int in range(i0, i1 + 1):
				var idx: int = j * w + i
				var l: Vector3 = at - Vector3(float(i) * sx, heights[idx] + base_y, wz)
				var d: float = maxf(l.length(), 1e-3)
				var fall: float = 1.0 - d / reach
				if fall <= 0.0:
					continue
				var facing: float = maxf(normals[idx].dot(l / d), 0.0) * 0.75 + 0.25
				sum[idx] += light.w * fall * fall * facing
	var out := PackedByteArray()
	out.resize(w * h)
	for idx: int in w * h:
		out[idx] = roundi(sqrt(clampf(sum[idx], 0.0, 1.0)) * 255.0)
	return out

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

## Show the torches and light the course by them, or put both out. The flags
## step aside while the torches burn and come back when they go out.
func set_active(on: bool) -> void:
	_active = on and not lights.is_empty()
	visible = _active
	if _root != null:
		_root.set_type_visible(FLAG_TYPE, not _active)
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
