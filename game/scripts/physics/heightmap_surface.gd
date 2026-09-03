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

## Tangent of [member base_angle] — the analytic fall line that
## [member heights] is relief *against*, so a world height is
## `heights[i] + slope * z`.
##
## Public alongside [member heights] and [member normals] for one reader:
## [method TerrainRenderer._build_chunk] puts its vertices exactly on the
## texels of this grid, so it reads the grid rather than paying for a bilinear
## filter between a texel and itself. Nothing writes any of the three.
var slope: float = 0.0
## Per-texel smooth normals, row-major alongside [member heights].
var normals: PackedVector3Array = PackedVector3Array()

var _friction: PackedFloat32Array = PackedFloat32Array()
var _depth: PackedFloat32Array = PackedFloat32Array()
var _dominant: PackedByteArray = PackedByteArray()
var _particles: PackedByteArray = PackedByteArray()
var _trackmarks: PackedByteArray = PackedByteArray()
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
	slope = tan(deg_to_rad(base_angle))
	_dx = world_size.x / maxf(1.0, float(size.x - 1))
	_dz = world_size.y / maxf(1.0, float(size.y - 1))
	_build_normals()
	if _friction.size() != heights.size():
		set_uniform_terrain(0.35, 0.05, 0, true)

## Uniform terrain everywhere — the synthetic-slope case for Phase 0 tests.
func set_uniform_terrain(friction: float, depth: float, terrain_id: int, particles: bool,
		trackmarks: bool = true) -> void:
	var n: int = heights.size()
	_friction.resize(n)
	_depth.resize(n)
	_dominant.resize(n)
	_particles.resize(n)
	_trackmarks.resize(n)
	_friction.fill(friction)
	_depth.fill(depth)
	for i: int in n:
		_dominant[i] = terrain_id
		_particles[i] = 1 if particles else 0
		_trackmarks[i] = 1 if trackmarks else 0

## Pre-blend the per-texel gameplay scalars from splat weights.
##
## `weights` is `size.x * size.y * stride` bytes, 0..255 per layer, with layer
## `l` at `texel * stride + l`. [param stride] defaults to the layer count —
## tightly packed, which is what a test fixture builds by hand — but
## [method _decode_splat] passes four per splat map instead, so that the common
## case of one RGBA8 splat map is the image's own bytes and needs no repacking
## at all. Layers past `layers.size()` are simply never read.
func set_splat(weights: PackedByteArray, layers: Array[TerrainLayer],
		stride: int = 0) -> void:
	var n: int = size.x * size.y
	var lc: int = layers.size()
	if stride <= 0:
		stride = lc
	assert(lc > 0, "a course needs at least one terrain layer")
	assert(stride >= lc, "splat stride cannot be narrower than the layer table")
	assert(weights.size() >= n * stride, "splat weight buffer too small")
	_friction.resize(n)
	_depth.resize(n)
	_dominant.resize(n)
	_particles.resize(n)
	_trackmarks.resize(n)

	var fr: PackedFloat32Array = PackedFloat32Array()
	var dp: PackedFloat32Array = PackedFloat32Array()
	var pa: PackedByteArray = PackedByteArray()
	var tm: PackedByteArray = PackedByteArray()
	fr.resize(lc); dp.resize(lc); pa.resize(lc); tm.resize(lc)
	for l: int in lc:
		fr[l] = layers[l].friction
		dp[l] = layers[l].compression_depth
		pa[l] = 1 if layers[l].emits_particles else 0
		tm[l] = 1 if layers[l].takes_trackmarks else 0

	for i: int in n:
		var base: int = i * stride
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
			_trackmarks[i] = tm[0]
		else:
			_friction[i] = f / total
			_depth[i] = d / total
			_dominant[i] = best
			_particles[i] = pa[best]
			_trackmarks[i] = tm[best]

## Per-texel smooth normals from central differences, including the analytic
## base slope. Interpolated bilinearly at query time.
func _build_normals() -> void:
	var w: int = size.x
	var h: int = size.y
	normals.resize(w * h)
	for y: int in h:
		for x: int in w:
			var xm: int = maxi(x - 1, 0)
			var xp: int = mini(x + 1, w - 1)
			var ym: int = maxi(y - 1, 0)
			var yp: int = mini(y + 1, h - 1)
			var hx: float = (heights[y * w + xp] - heights[y * w + xm]) / (float(xp - xm) * _dx)
			# +y in the grid is -z in the world, so the world-space dh/dz flips sign.
			var hz: float = -(heights[yp * w + x] - heights[ym * w + x]) / (float(yp - ym) * _dz)
			hz += slope
			normals[y * w + x] = Vector3(-hx, 1.0, -hz).normalized()

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
	var y: float = _local_height(g.x, g.y) + slope * z
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
		lerpf(heights[i01], heights[i11], fx), fy) + slope * z
	out.normal = lerp(
		normals[i00].lerp(normals[i10], fx),
		normals[i01].lerp(normals[i11], fx), fy).normalized()
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
	out.takes_trackmarks = _trackmarks[nearest] == 1

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
		var target := Vector2i(img.get_width(), img.get_height())
		s.set_splat(_decode_splat(course, target), course.terrain_layers,
			course.splat_maps.size() * 4)
	return s

## Resample the splat textures onto the heightmap grid, four weights per map per
## texel. The two resolutions are deliberately decoupled in v2 (§3.1), so
## nearest-resample here rather than assuming they match.
static func _decode_splat(course: CourseData, target: Vector2i) -> PackedByteArray:
	var lc: int = course.terrain_layers.size()
	var stride: int = course.splat_maps.size() * 4

	# [b]The shipped case is a copy.[/b] The importer writes one RGBA8 splat map
	# at exactly the heightmap's resolution for all 44 courses, and this
	# function's output is defined as four weights per texel in channel order —
	# which is that image, byte for byte. Recognising it turns the longest
	# course's splat decode from 1.3 s into a memcpy.
	#
	# The general path below still exists and still has to: §3.1 decouples the
	# two resolutions deliberately, so a hand-authored course at a different
	# splat resolution is legal and is resampled. This is a fast path, not an
	# assumption.
	if course.splat_maps.size() == 1 and course.splat_maps[0] != null:
		var only: Image = course.splat_maps[0].get_image()
		if only != null and not only.is_compressed() \
				and only.get_format() == Image.FORMAT_RGBA8 \
				and only.get_width() == target.x and only.get_height() == target.y:
			return only.get_data()

	var out := PackedByteArray()
	out.resize(target.x * target.y * stride)
	out.fill(0)
	for m: int in course.splat_maps.size():
		var channels: int = mini(4, lc - m * 4)
		if channels <= 0:
			break
		var tex: Texture2D = course.splat_maps[m]
		if tex == null:
			continue
		var img: Image = tex.get_image()
		if img == null:
			continue
		if img.is_compressed():
			img.decompress()
		# One `get_data()` rather than a `get_pixel()` per texel. The old inner
		# loop was 1.27 M bound-method calls on `the_long_ride`, each returning
		# a Color Variant so that four bytes could be read back out of it, and
		# it was 1.3 s of a 1.8 s course load — the clearest case in the tree of
		# GDScript's per-call overhead being the entire cost. The arithmetic is
		# unchanged: `get_pixel` on an RGBA8 image is `byte / 255.0`, and the
		# old code multiplied it straight back by 255.
		if img.get_format() != Image.FORMAT_RGBA8:
			img = img.duplicate()
			img.convert(Image.FORMAT_RGBA8)
		var data: PackedByteArray = img.get_data()
		var sw: int = img.get_width()
		var sh: int = img.get_height()
		# The source column for each target column, resolved once instead of a
		# float divide and a clamp per texel.
		#
		# [b]Integer arithmetic, deliberately.[/b] This was
		# `int(float(x) / float(target.x) * float(sw))`, which is not an
		# identity map even when the two resolutions are equal: `178 / 179.0 *
		# 179.0` is 177.99999999999997 in double, and `int` truncates it to 177.
		# Eleven of bunny_hill's 179 columns and eight of its 519 rows were
		# reading the neighbouring texel's splat weights — whole 50 cm stripes
		# of the course playing on the wrong terrain's friction, silently, since
		# the shading comes from the splat texture directly and only the physics
		# went through here. `x * sw / target.x` in integers is exact.
		var col := PackedInt32Array()
		col.resize(target.x)
		for x: int in target.x:
			@warning_ignore("integer_division")
			var sx: int = x * sw / target.x
			col[x] = clampi(sx, 0, sw - 1)
		for y: int in target.y:
			@warning_ignore("integer_division")
			var sy_raw: int = y * sh / target.y
			var sy: int = clampi(sy_raw, 0, sh - 1)
			var src_row: int = sy * sw
			var dst_row: int = y * target.x * stride + m * 4
			for x: int in target.x:
				var src: int = (src_row + col[x]) * 4
				var dst: int = dst_row + x * stride
				for ch: int in channels:
					out[dst + ch] = data[src + ch]
	return out
