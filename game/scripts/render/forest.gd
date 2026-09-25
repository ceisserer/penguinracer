## Draws one tree type across a course: three mesh levels and an octahedral
## impostor, handed over per tree with a dithered cross-fade, swaying in the
## wind and snowed on in the shader.
##
## Replaces [CourseRoot]'s single crossed-quad batch for every prefab marked
## [member ObjectPrefab.conifer] or [member ObjectPrefab.bare]. Which of the
## two it draws is its [enum Species]: [ConiferMesh] or [BareTreeMesh], and the
## same shaders serve both. Collision is untouched: the [ObjectGrid] is
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
## everything past the last. A hand-over is a change of shape — fins and tiers
## drop out, the trunk goes — so it has to happen where a tree is too small
## and too fogged to show it: at 22 / 45 / 75 m a tree morphed ~140 px tall
## right ahead of the racer. At 50 m a 6 m tree is ~60 px at 720p and 70°, at
## 90 m ~35 px and half fogged (fog runs 40–150 m), and the impostor starts
## where the fog has taken most of it.
##
## Those are pixel sizes, so the distances are for a 720-pixel-tall window
## ([constant REFERENCE_HEIGHT]) and move out with the window — see
## [method screen_scale_for].
const LOD_ENDS: PackedFloat32Array = [50.0, 90.0, 130.0]
## The window height [constant LOD_ENDS] was chosen at, in physical pixels.
const REFERENCE_HEIGHT := 720.0
## How far out a tall window may push the hand-overs, times [constant LOD_ENDS].
## At 2x the first one is already twice the fog's clear distance and the last
## past its end; beyond that a bigger window would only buy full-detail trees
## nobody can see, at full price.
const MAX_SCREEN_SCALE := 2.0
## Width of each hand-over, in metres, centred on the boundary: about a fifth
## of a second at racing speed. Wider reads as a tree going grainy, not as a
## smoother change.
const FADE_WIDTH := 4.0
const CELL_SIZE := 40.0

const MESH_SHADER := "res://shaders/conifer.gdshader"
const IMPOSTOR_SHADER := "res://shaders/conifer_impostor.gdshader"

enum Species { CONIFER, BARE }

## A bare tree's finest limbs are thinner than a pixel from a few metres out.
## `conifer.gdshader` fattens a tube to at least this radius per metre of
## distance — about 0.4 px at 720p and a 70° field of view — so a far limb
## stays a thin line instead of breaking into dashes.
const BARE_MIN_RADIUS_PER_METRE := 0.0008
## A bare crown is mostly air, and its mips average the twigs toward
## transparent; a lower threshold keeps the far crown from thinning away.
const BARE_IMPOSTOR_SCISSOR := 0.25
## See `alpha_mip_boost` in `conifer.gdshaderinc`: keeps the twigs from
## thinning out with distance.
const BARE_ALPHA_MIP_BOOST := 0.5

## Multiplies [constant LOD_ENDS] — the player's `[quality] tree_detail`,
## handed down by [CourseRoot]. Read by [method build], so set it first.
##
## Below 1 the hand-overs come closer, where they are easier to see, and the
## bare impostor — baked with its limbs widened to what LOD 2 draws at 130 m —
## takes over a little thicker than the level it replaces. That is the trade a
## slow machine is offered, not a default.
var lod_scale: float = 1.0
## [method screen_scale_for] the window the bands were last laid out for.
var _screen_scale: float = 1.0

## One material per level, last one the impostor's.
var _materials: Array[ShaderMaterial] = []
var _batches: Array[MultiMeshInstance3D] = []
## Each batch's level, in step with [member _batches].
var _batch_levels: PackedInt32Array = []
## How far each batch's farthest tree stands from the batch's origin, in step
## with [member _batches] — the slack its visibility range needs.
var _batch_reach: PackedFloat32Array = []
## How many levels, nearest first, cast into the shadow map when
## [member _shadow] is on. See [method set_shadow_casting].
var _shadow_levels: int = 1 << 16
var _wind: WindField
var _snow_grade: int = -1
var _shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Whether the baked impostor atlases are in the project. Without them the last
## mesh level simply runs to the horizon.
static func has_impostor(species: Species = Species.CONIFER) -> bool:
	var paths: PackedStringArray = atlases(species)
	return ResourceLoader.exists(paths[0]) and ResourceLoader.exists(paths[1])

## The impostor's albedo and normal atlas paths.
static func atlases(species: Species) -> PackedStringArray:
	if species == Species.BARE:
		return PackedStringArray([BareTreeMesh.ALBEDO_ATLAS, BareTreeMesh.NORMAL_ATLAS])
	return PackedStringArray([ConiferMesh.ALBEDO_ATLAS, ConiferMesh.NORMAL_ATLAS])

## The mesh level the impostor is baked from. The conifer's is its finest; the
## bare tree's is the level the impostor takes over from, since a bare crown
## seen side-on is only as airy as the twig cards it carries — LOD 0 has four
## times LOD 2's, and baked from it the impostor was a dark blob replacing an
## open tree.
static func impostor_source_level(species: Species) -> int:
	return ConiferMesh.LODS - 1 if species == Species.BARE else 0

## Mesh level [param level] of [param species].
static func level_mesh(species: Species, level: int) -> ArrayMesh:
	if species == Species.BARE:
		return BareTreeMesh.mesh(level)
	return ConiferMesh.mesh(level)

## How many levels are drawn: the meshes, plus the impostor if it is baked.
static func level_count(with_impostor: bool) -> int:
	return ConiferMesh.LODS + (1 if with_impostor else 0)

## How much further out the hand-overs go for a window [param height_px]
## physical pixels tall: a tree has to change shape at the same size *on
## screen*, and at 2560x1440 it is twice as tall at any distance as at 720p —
## the 50 m hand-over there read as a tree going grainy right ahead of the
## racer. Never nearer than [constant LOD_ENDS] (a small window keeps the
## distances they were chosen at), never further than [constant MAX_SCREEN_SCALE].
static func screen_scale_for(height_px: float) -> float:
	return clampf(height_px / REFERENCE_HEIGHT, 1.0, MAX_SCREEN_SCALE)

## Level [param level]'s band as `(begin, end)` metres, with every hand-over
## at [param scale] times [constant LOD_ENDS]. The nearest begins at -1e6 and
## the farthest ends at 1e6: no hand-over at either end.
static func band(level: int, levels: int, scale: float = 1.0) -> Vector2:
	var begin: float = -1.0e6 if level == 0 else LOD_ENDS[level - 1] * scale
	var end: float = 1.0e6 if level >= levels - 1 else LOD_ENDS[level] * scale
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
## `snowy_tree1.png`, unchanged — for a conifer; a bare tree draws its own
## ([method BareTreeMesh.texture]) and ignores it. [param transforms] are the
## per-tree world transforms [CourseRoot] would have given the cross.
func build(texture: Texture2D, transforms: Array[Transform3D],
		species: Species = Species.CONIFER) -> void:
	var bare: bool = species == Species.BARE
	var impostor: bool = has_impostor(species)
	var levels: int = level_count(impostor)
	var meshes: Array[Mesh] = []
	for level: int in levels:
		var mat := ShaderMaterial.new()
		if level < ConiferMesh.LODS:
			mat.shader = load(MESH_SHADER)
			mat.set_shader_parameter("albedo_texture", BareTreeMesh.texture() if bare else texture)
			if bare:
				mat.set_shader_parameter("min_radius_per_metre", BARE_MIN_RADIUS_PER_METRE)
			meshes.push_back(level_mesh(species, level))
		else:
			var paths: PackedStringArray = atlases(species)
			mat.shader = load(IMPOSTOR_SHADER)
			mat.set_shader_parameter("albedo_atlas", load(paths[0]))
			mat.set_shader_parameter("normal_atlas", load(paths[1]))
			if bare:
				mat.set_shader_parameter("alpha_scissor", BARE_IMPOSTOR_SCISSOR)
			meshes.push_back(ConiferMesh.impostor_mesh())
		mat.set_shader_parameter("lod_fade_width", FADE_WIDTH)
		if bare:
			# Bark is dark, so the same cover reads fainter on it than on
			# needles, and a limb is round, so less of it faces straight up;
			# the picture it replaces is a third snow.
			mat.set_shader_parameter("snow_calm", 0.85)
			mat.set_shader_parameter("snow_heavy", 1.0)
			mat.set_shader_parameter("snow_facing_offset", 0.5)
			# Not on the impostor: its atlas was baked with the limbs already
			# fattened to what LOD 2 draws at the hand-over, and boosting it too
			# fills the crown in solid — a dark blob replacing an airy tree.
			if level < ConiferMesh.LODS:
				mat.set_shader_parameter("alpha_mip_boost", BARE_ALPHA_MIP_BOOST)
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
			mmi.cast_shadow = _shadow_for(level)
			add_child(mmi)
			_batches.push_back(mmi)
			_batch_levels.push_back(level)
			_batch_reach.push_back(reach)
	_screen_scale = _window_scale()
	_lay_out_bands()

## The [method screen_scale_for] of the window this forest is drawn in.
func _window_scale() -> float:
	if not is_inside_tree():
		return 1.0
	var window: Window = get_viewport() as Window
	return screen_scale_for(float(window.size.y)) if window != null else 1.0

## Hand every level's material its band, and every batch the visibility range
## that culls its cell outside it, at [member lod_scale] × [member _screen_scale].
func _lay_out_bands() -> void:
	var levels: int = _materials.size()
	var scale: float = lod_scale * _screen_scale
	for level: int in levels:
		var b: Vector2 = band(level, levels, scale)
		_materials[level].set_shader_parameter("lod_begin", b.x)
		_materials[level].set_shader_parameter("lod_end", b.y)
	for i: int in _batches.size():
		var b: Vector2 = band(_batch_levels[i], levels, scale)
		var slack: float = FADE_WIDTH * 0.5 + _batch_reach[i]
		_batches[i].visibility_range_begin = maxf(0.0, b.x - slack)
		_batches[i].visibility_range_end = 0.0 if b.y >= 1.0e5 else b.y + slack

func _process(_delta: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var at: Vector3 = cam.global_position
	# A window dragged taller, or put fullscreen, mid-race.
	var screen: float = _window_scale()
	if absf(screen - _screen_scale) > 0.02:
		_screen_scale = screen
		_lay_out_bands()
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

## See [method CourseRoot.set_casting_shadows]. Only the nearest
## [param levels] cast: the far levels are many trees, drawn with cutouts, whose
## shadows the fog has mostly taken — and a shadow map draws each of them once
## per cascade.
func set_shadow_casting(setting: GeometryInstance3D.ShadowCastingSetting,
		levels: int = 1 << 16) -> void:
	_shadow = setting
	_shadow_levels = levels
	for i: int in _batches.size():
		_batches[i].cast_shadow = _shadow_for(_batch_levels[i])

func _shadow_for(level: int) -> GeometryInstance3D.ShadowCastingSetting:
	if level < _shadow_levels:
		return _shadow
	return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
