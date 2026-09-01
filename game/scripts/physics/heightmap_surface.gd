## Heightmap-backed [SurfaceProvider]: bilinear height with an analytic base
## slope, splat-weighted friction and compression depth, and smooth normals.
##
## Friction and depth are [b]pre-blended per texel at build time[/b]. Because
## both the splat blend and bilinear filtering are linear, interpolating
## pre-blended scalars is exactly equal to interpolating the weights and then
## dotting with the layer table — but it turns up to 32 multiply-adds per query
## into 4. This is ETR's barycentric friction blend (etracer.md §4.2)
## generalised to splat weights, minus its cost.
class_name HeightmapSurface
extends SurfaceProvider

## Local relief in metres, row-major, `size.x * size.y` samples.
var heights: PackedFloat32Array = PackedFloat32Array()
var size: Vector2i = Vector2i.ZERO
## Course extent in metres: width along +X, length along -Z.
var world_size: Vector2 = Vector2.ONE
## Global downhill slope, degrees.
var base_angle: float = 0.0

var _slope: float = 0.0
var _friction: PackedFloat32Array = PackedFloat32Array()
var _depth: PackedFloat32Array = PackedFloat32Array()
var _dominant: PackedByteArray = PackedByteArray()
var _particles: PackedByteArray = PackedByteArray()
var _normals: PackedVector3Array = PackedVector3Array()
var _dx: float = 1.0
var _dz: float = 1.0

## CPU mirror of the snow deformation field. When set, packed snow raises
## friction and lowers compression depth, which is what makes racing lines
## matter (godot-port-plan.md §4.3).
var snow_field: SnowField = null

## Cheap 1-entry memo, as in ETR's `FindYCoord` — but owned state, not a
## function-static that leaks across course loads (etracer.md §9).
var _cache_x: float = INF
var _cache_z: float = INF
var _cache_y: float = 0.0

# ------------------------------------------------------------------ build

## Build from raw arrays. Used by the importer, by tests, and by anything that
## wants a synthetic slope without a [CourseData] round-trip.
func build(p_heights: PackedFloat32Array, p_size: Vector2i, p_world_size: Vector2,
		p_base_angle: float) -> void:
	heights = p_heights
	size = p_size
	world_size = p_world_size
	base_angle = p_base_angle
	_slope = tan(deg_to_rad(base_angle))
	_dx = world_size.x / maxf(1.0, float(size.x - 1))
	_dz = world_size.y / maxf(1.0, float(size.y - 1))
	_build_normals()
	if _friction.size() != heights.size():
		set_uniform_terrain(0.35, 0.05, 0, true)

## Uniform terrain everywhere — the synthetic-slope case for Phase 0 tests.
func set_uniform_terrain(friction: float, depth: float, terrain_id: int, particles: bool) -> void:
	var n: int = heights.size()
	_friction.resize(n)
	_depth.resize(n)
	_dominant.resize(n)
	_particles.resize(n)
	_friction.fill(friction)
	_depth.fill(depth)
	for i: int in n:
		_dominant[i] = terrain_id
		_particles[i] = 1 if particles else 0

## Pre-blend the per-texel gameplay scalars from splat weights.
## `weights` is `size.x * size.y * layer_count` bytes, 0..255 per layer.
func set_splat(weights: PackedByteArray, layers: Array[TerrainLayer]) -> void:
	var n: int = size.x * size.y
	var lc: int = layers.size()
	assert(lc > 0, "a course needs at least one terrain layer")
	assert(weights.size() >= n * lc, "splat weight buffer too small")
	_friction.resize(n)
	_depth.resize(n)
	_dominant.resize(n)
	_particles.resize(n)

	var fr: PackedFloat32Array = PackedFloat32Array()
	var dp: PackedFloat32Array = PackedFloat32Array()
	var pa: PackedByteArray = PackedByteArray()
	fr.resize(lc); dp.resize(lc); pa.resize(lc)
	for l: int in lc:
		fr[l] = layers[l].friction
		dp[l] = layers[l].compression_depth
		pa[l] = 1 if layers[l].emits_particles else 0

	for i: int in n:
		var base: int = i * lc
		var total: float = 0.0
		var f: float = 0.0
		var d: float = 0.0
		var best: int = 0
		var best_w: int = -1
		for l: int in lc:
			var w: int = weights[base + l]
			if w == 0:
				continue
			total += float(w)
			f += float(w) * fr[l]
			d += float(w) * dp[l]
			if w > best_w:
				best_w = w
				best = l
		if total <= 0.0:
			_friction[i] = fr[0]
			_depth[i] = dp[0]
			_dominant[i] = 0
			_particles[i] = pa[0]
		else:
			_friction[i] = f / total
			_depth[i] = d / total
			_dominant[i] = best
			_particles[i] = pa[best]

## Per-texel smooth normals from central differences, including the analytic
## base slope. Interpolated bilinearly at query time.
func _build_normals() -> void:
	var w: int = size.x
	var h: int = size.y
	_normals.resize(w * h)
	for y: int in h:
		for x: int in w:
			var xm: int = maxi(x - 1, 0)
			var xp: int = mini(x + 1, w - 1)
			var ym: int = maxi(y - 1, 0)
			var yp: int = mini(y + 1, h - 1)
			var hx: float = (heights[y * w + xp] - heights[y * w + xm]) / (float(xp - xm) * _dx)
			# +y in the grid is -z in the world, so the world-space dh/dz flips sign.
			var hz: float = -(heights[yp * w + x] - heights[ym * w + x]) / (float(yp - ym) * _dz)
			hz += _slope
			_normals[y * w + x] = Vector3(-hx, 1.0, -hz).normalized()

# ------------------------------------------------------------------ query

func _grid_coords(x: float, z: float) -> Vector2:
	return Vector2(x / _dx, -z / _dz)

func _local_height(gx: float, gz: float) -> float:
	var w: int = size.x
	var h: int = size.y
	var x0: int = clampi(int(floor(gx)), 0, w - 1)
	var y0: int = clampi(int(floor(gz)), 0, h - 1)
	var x1: int = mini(x0 + 1, w - 1)
	var y1: int = mini(y0 + 1, h - 1)
	var fx: float = clampf(gx - float(x0), 0.0, 1.0)
	var fy: float = clampf(gz - float(y0), 0.0, 1.0)
	var h00: float = heights[y0 * w + x0]
	var h10: float = heights[y0 * w + x1]
	var h01: float = heights[y1 * w + x0]
	var h11: float = heights[y1 * w + x1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)

func height_at(x: float, z: float) -> float:
	if x == _cache_x and z == _cache_z:
		return _cache_y
	var g: Vector2 = _grid_coords(x, z)
	var y: float = _local_height(g.x, g.y) + _slope * z
	if snow_field != null:
		y -= snow_field.depth_at(x, z)
	_cache_x = x
	_cache_z = z
	_cache_y = y
	return y

func sample_into(x: float, z: float, out: SurfaceSample) -> void:
	var w: int = size.x
	var h: int = size.y
	var g: Vector2 = _grid_coords(x, z)
	var x0: int = clampi(int(floor(g.x)), 0, w - 1)
	var y0: int = clampi(int(floor(g.y)), 0, h - 1)
	var x1: int = mini(x0 + 1, w - 1)
	var y1: int = mini(y0 + 1, h - 1)
	var fx: float = clampf(g.x - float(x0), 0.0, 1.0)
	var fy: float = clampf(g.y - float(y0), 0.0, 1.0)

	var i00: int = y0 * w + x0
	var i10: int = y0 * w + x1
	var i01: int = y1 * w + x0
	var i11: int = y1 * w + x1

	out.height = lerpf(
		lerpf(heights[i00], heights[i10], fx),
		lerpf(heights[i01], heights[i11], fx), fy) + _slope * z
	out.normal = lerp(
		_normals[i00].lerp(_normals[i10], fx),
		_normals[i01].lerp(_normals[i11], fx), fy).normalized()
	out.friction = lerpf(
		lerpf(_friction[i00], _friction[i10], fx),
		lerpf(_friction[i01], _friction[i11], fx), fy)
	out.compression_depth = lerpf(
		lerpf(_depth[i00], _depth[i10], fx),
		lerpf(_depth[i01], _depth[i11], fx), fy)

	var nearest: int = i00
	if fx >= 0.5:
		nearest = i11 if fy >= 0.5 else i10
	elif fy >= 0.5:
		nearest = i01
	out.terrain_id = _dominant[nearest]
	out.emits_particles = _particles[nearest] == 1

	if snow_field != null:
		snow_field.apply_to_sample(x, z, out)

# ------------------------------------------------------------- from course

## Build from an imported [CourseData]. Decodes the FORMAT_RF heightmap and the
## RGBA8 splat maps into the flat CPU arrays used by the query path.
static func from_course(course: CourseData) -> HeightmapSurface:
	var s := HeightmapSurface.new()
	var img: Image = course.heightmap
	assert(img != null, "CourseData has no heightmap")
	assert(img.get_format() == Image.FORMAT_RF, "heightmap must be FORMAT_RF (float32)")
	var hs: PackedFloat32Array = img.get_data().to_float32_array()
	s.build(hs, Vector2i(img.get_width(), img.get_height()), course.world_size, course.base_angle)

	if not course.splat_maps.is_empty() and not course.terrain_layers.is_empty():
		s.set_splat(_decode_splat(course, Vector2i(img.get_width(), img.get_height())),
			course.terrain_layers)
	return s

## Resample the splat textures onto the heightmap grid. The two resolutions are
## deliberately decoupled in v2 (§3.1), so nearest-resample here rather than
## assuming they match.
static func _decode_splat(course: CourseData, target: Vector2i) -> PackedByteArray:
	var lc: int = course.terrain_layers.size()
	var out := PackedByteArray()
	out.resize(target.x * target.y * lc)
	out.fill(0)
	for m: int in course.splat_maps.size():
		var tex: Texture2D = course.splat_maps[m]
		if tex == null:
			continue
		var img: Image = tex.get_image()
		if img == null:
			continue
		if img.is_compressed():
			img.decompress()
		var sw: int = img.get_width()
		var sh: int = img.get_height()
		for y: int in target.y:
			var sy: int = clampi(int(float(y) / float(target.y) * float(sh)), 0, sh - 1)
			for x: int in target.x:
				var sx: int = clampi(int(float(x) / float(target.x) * float(sw)), 0, sw - 1)
				var c: Color = img.get_pixel(sx, sy)
				var base: int = (y * target.x + x) * lc
				for ch: int in 4:
					var layer: int = m * 4 + ch
					if layer >= lc:
						break
					out[base + layer] = int(round(c[ch] * 255.0))
	return out
