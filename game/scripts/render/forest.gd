## Draws one conifer type across a course: three mesh levels and an octahedral
## impostor, handed over per tree with a dithered cross-fade, swaying in the
## wind and snowed on in the shader.
##
## Replaces [CourseRoot]'s single crossed-quad batch for every prefab marked
## [member ObjectPrefab.conifer]. Collision is untouched: the [ObjectGrid] is
## still built from the same markers, so a tree is exactly as solid as before.
##
## [b]How a tree picks its level.[/b] Per tree, in the vertex shader, by its
## distance from the camera ([code]conifer.gdshaderinc[/code]): a tree outside a
## level's band collapses to a point in that level's batch, and inside a
## [constant FADE_WIDTH] hand-over both neighbours draw it on complementary
## halves of a Bayer pattern. Choosing per batch instead — Godot's own
## visibility ranges — would switch a whole batch at once, and a fade on it
## needs a renderer feature Compatibility does not have.
##
## [b]Why cells.[/b] Every level then runs its vertex stage over every tree it
## is handed, drawn or not. So the trees are cut into [constant CELL_SIZE]
## squares, one [MultiMeshInstance3D] per cell per level, and each carries a
## node visibility range wide enough for any tree in it: the near levels only
## ever run over the few cells near the camera. That is ordinary culling, and it
## works the same on both renderers.
class_name Forest
extends Node3D

## Where each mesh level hands over to the next, in metres; the impostor takes
## everything past the last. Inside the 40 m of fog-free view a racer sees the
## full mesh, and the impostor starts about half way into the fog.
const LOD_ENDS: PackedFloat32Array = [22.0, 45.0, 75.0]
## Width of each hand-over, in metres, centred on the boundary: about a fifth
## of a second at racing speed. Wider reads as a tree going grainy, not as a
## smoother change.
const FADE_WIDTH := 4.0
const CELL_SIZE := 40.0

const MESH_SHADER := "res://shaders/conifer.gdshader"
const IMPOSTOR_SHADER := "res://shaders/conifer_impostor.gdshader"

## One material per level, last one the impostor's.
var _materials: Array[ShaderMaterial] = []
var _batches: Array[MultiMeshInstance3D] = []
var _wind: WindField
var _snow_grade: int = -1
var _shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Whether the baked impostor atlases are in the project. Without them the last
## mesh level simply runs to the horizon.
static func has_impostor() -> bool:
	return ResourceLoader.exists(ConiferMesh.ALBEDO_ATLAS) \
		and ResourceLoader.exists(ConiferMesh.NORMAL_ATLAS)

## How many levels are drawn: the meshes, plus the impostor if it is baked.
static func level_count(with_impostor: bool) -> int:
	return ConiferMesh.LODS + (1 if with_impostor else 0)

## Level [param level]'s band as `(begin, end)` metres. The nearest begins
## at -1e6 and the farthest ends at 1e6: no hand-over at either end.
static func band(level: int, levels: int) -> Vector2:
	var begin: float = -1.0e6 if level == 0 else LOD_ENDS[level - 1]
	var end: float = 1.0e6 if level >= levels - 1 else LOD_ENDS[level]
	return Vector2(begin, end)

## The trees grouped by the [constant CELL_SIZE] square their origin stands in.
static func cells_of(transforms: Array[Transform3D]) -> Dictionary[Vector2i, PackedInt32Array]:
	var out: Dictionary[Vector2i, PackedInt32Array] = {}
	for i: int in transforms.size():
		var o: Vector3 = transforms[i].origin
		var key := Vector2i(floori(o.x / CELL_SIZE), floori(o.z / CELL_SIZE))
		var list: PackedInt32Array = out.get(key, PackedInt32Array())
		list.push_back(i)
		out[key] = list
	return out

## Build every batch. [param texture] is the prefab's own picture —
## `snowy_tree1.png`, unchanged — and [param transforms] the per-tree world
## transforms [CourseRoot] would have given the cross.
func build(texture: Texture2D, transforms: Array[Transform3D]) -> void:
	var impostor: bool = has_impostor()
	var levels: int = level_count(impostor)
	var meshes: Array[Mesh] = []
	for level: int in levels:
		var mat := ShaderMaterial.new()
		var b: Vector2 = band(level, levels)
		if level < ConiferMesh.LODS:
			mat.shader = load(MESH_SHADER)
			mat.set_shader_parameter("albedo_texture", texture)
			meshes.push_back(ConiferMesh.mesh(level))
		else:
			mat.shader = load(IMPOSTOR_SHADER)
			mat.set_shader_parameter("albedo_atlas", load(ConiferMesh.ALBEDO_ATLAS))
			mat.set_shader_parameter("normal_atlas", load(ConiferMesh.NORMAL_ATLAS))
			meshes.push_back(ConiferMesh.impostor_mesh())
		mat.set_shader_parameter("lod_begin", b.x)
		mat.set_shader_parameter("lod_end", b.y)
		mat.set_shader_parameter("lod_fade_width", FADE_WIDTH)
		_materials.push_back(mat)

	var cells: Dictionary[Vector2i, PackedInt32Array] = cells_of(transforms)
	for key: Vector2i in cells:
		var members: PackedInt32Array = cells[key]
		# The node sits at the middle of its trees, so its visibility range is
		# measured from there, and [code]reach[/code] bounds how far any one
		# tree's origin — what the shader measures from — can be from it.
		var box := AABB(transforms[members[0]].origin, Vector3.ZERO)
		for i: int in members:
			box = box.expand(transforms[i].origin)
		var centre: Vector3 = box.get_center()
		var reach: float = 0.0
		for i: int in members:
			reach = maxf(reach, centre.distance_to(transforms[i].origin))
		for level: int in levels:
			var b: Vector2 = band(level, levels)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = meshes[level]
			mm.instance_count = members.size()
			for k: int in members.size():
				var xf: Transform3D = transforms[members[k]]
				xf.origin -= centre
				mm.set_instance_transform(k, xf)
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "L%d_%d_%d" % [level, key.x, key.y]
			mmi.multimesh = mm
			mmi.material_override = _materials[level]
			mmi.position = centre
			mmi.cast_shadow = _shadow
			var slack: float = FADE_WIDTH * 0.5 + reach
			mmi.visibility_range_begin = maxf(0.0, b.x - slack)
			mmi.visibility_range_end = 0.0 if b.y >= 1.0e5 else b.y + slack
			add_child(mmi)
			_batches.push_back(mmi)

func _process(_delta: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var at: Vector3 = cam.global_position
	var wind_dir := Vector2(1.0, 0.0)
	var wind_strength: float = 0.0
	if _wind != null and _wind.windy:
		var v := Vector2(_wind.vector.x, _wind.vector.z)
		if v.length() > 1e-3:
			wind_dir = v.normalized()
		wind_strength = clampf(_wind.speed() / 100.0, 0.0, 1.0)
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("lod_origin", at)
		mat.set_shader_parameter("wind_direction", wind_dir)
		mat.set_shader_parameter("wind_strength", wind_strength)

## The weather the trees stand in: [param wind] is the watched racer's
## [WindField] (null when calm), [param snow_grade] the snowfall, 0..3.
## Called every frame; the materials are only touched when the grade moves.
func set_weather(wind: WindField, snow_grade: int) -> void:
	_wind = wind
	if snow_grade == _snow_grade:
		return
	_snow_grade = snow_grade
	var level: float = clampf(float(snow_grade) / float(SnowFall.MAX_GRADE), 0.0, 1.0)
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("snow_level", level)

## See [method CourseRoot.set_ambient].
func set_ambient(ambient: Vector3) -> void:
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("etr_ambient", ambient)

## See [method CourseRoot.set_casting_shadows].
func set_shadow_casting(setting: GeometryInstance3D.ShadowCastingSetting) -> void:
	_shadow = setting
	for mmi: MultiMeshInstance3D in _batches:
		mmi.cast_shadow = setting
