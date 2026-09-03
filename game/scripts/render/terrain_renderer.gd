## Chunked terrain mesh with frustum culling and streaming.
##
## Replaces ETR's CLOD quadtree (`quadtree.cpp`, 1146 lines), whose own header
## documents its problems: blurry terrain-boundary blending, no detail texturing
## and performance that degrades linearly with the number of terrain types,
## because it re-rendered the whole terrain once per layer (etracer.md §4.3).
## Here every layer is blended in one pass by the splat shader.
##
## Long courses are fine despite appearances: `the_long_ride` upsamples to
## 159×7999, but fog culls to 70–150 m, so the visible slice is a few tens of
## thousands of vertices. Chunk streaming keeps memory flat.
class_name TerrainRenderer
extends Node3D

## Vertices per chunk edge. 64 keeps each chunk under the 16-bit index limit
## and small enough that culling is meaningful.
const CHUNK_VERTS := 64
## Milliseconds of chunk building a single frame may do once a race is running.
## Under one chunk, so the usual frame builds exactly one; see
## [method update_streaming].
const BUILD_BUDGET_MS := 1.0

var course: CourseData
var surface: HeightmapSurface
## Chunks further than this from the camera are not instantiated.
var stream_radius: float = 400.0

var _material: ShaderMaterial
var _chunks: Dictionary[Vector2i, MeshInstance3D] = {}
var _chunk_world: Dictionary[Vector2i, AABB] = {}
var _chunks_x: int = 0
var _chunks_z: int = 0
var _last_center: Vector3 = Vector3(INF, INF, INF)
## Chunks that should exist and do not yet, nearest first. Drained under a
## budget by [method _build_pending].
var _pending: Array[Vector2i] = []

func setup(p_course: CourseData, p_surface: HeightmapSurface) -> void:
	course = p_course
	surface = p_surface
	_material = _build_material()
	var size: Vector2i = Vector2i(surface.size.x, surface.size.y)
	_chunks_x = maxi(1, ceili(float(size.x - 1) / float(CHUNK_VERTS - 1)))
	_chunks_z = maxi(1, ceili(float(size.y - 1) / float(CHUNK_VERTS - 1)))
	for cz: int in _chunks_z:
		for cx: int in _chunks_x:
			_chunk_world[Vector2i(cx, cz)] = _chunk_bounds(cx, cz)

func _build_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain.gdshader")
	var layers: Array[TerrainLayer] = course.terrain_layers
	mat.set_shader_parameter("layer_count", maxi(1, layers.size()))
	mat.set_shader_parameter("world_size", course.world_size)
	if course.splat_maps.size() > 0:
		mat.set_shader_parameter("splat_0", course.splat_maps[0])
	if course.splat_maps.size() > 1:
		mat.set_shader_parameter("splat_1", course.splat_maps[1])

	# Four-wide tables in two halves: the shader indexes `layer_*` with the first
	# splat texture's weights and `layer_*_hi` with the second's. Filling only
	# the first four was a real gap — an eight-layer course got "rough, not
	# snow, not ice" for its last four terrains.
	var roughness := [0.85, 0.85, 0.85, 0.85, 0.85, 0.85, 0.85, 0.85]
	var snowness := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var iceness := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	# Unused slots keep a legal repeat length: the shader divides by these, and
	# `layer_count` gates the sample but not the uniform.
	var uv_scales := [6.0, 6.0, 6.0, 6.0, 6.0, 6.0, 6.0, 6.0]
	for i: int in mini(layers.size(), 8):
		if layers[i].albedo != null:
			mat.set_shader_parameter("albedo_%d" % i, layers[i].albedo)
		var ice: bool = layers[i].is_ice()
		# Authored on the layer, not derived here. The importer seeds it from
		# `is_ice()` with the 0.25/0.85 this line used to hardcode, so the
		# migrated library lands on exactly the values it always had — but a
		# terrain that wants to be rougher than its neighbours can now say so.
		roughness[i] = layers[i].roughness
		uv_scales[i] = layers[i].uv_scale
		iceness[i] = 1.0 if ice else 0.0
		# `is_deformable` is the migrated "snow deforms, rock does not" flag,
		# which is exactly the distinction the wrap, micro-relief and glint
		# terms want: shade snow as a translucent medium, rock as rock. Ice is
		# non-deformable too, so the ice test has to come first — it does, in
		# the sense that nothing here is deformable *and* ice.
		snowness[i] = 1.0 if layers[i].is_deformable else 0.0
	_set_layer_table(mat, "layer_roughness", roughness)
	_set_layer_table(mat, "layer_snowness", snowness)
	_set_layer_table(mat, "layer_iceness", iceness)
	_set_layer_table(mat, "layer_uv_scale", uv_scales)
	mat.set_shader_parameter("sparkle_noise", _sparkle_texture())
	mat.set_shader_parameter("detail_map", _detail_texture())
	mat.set_shader_parameter("detail_gradient_scale", _detail_gradient_scale)
	return mat

static func _set_layer_table(mat: ShaderMaterial, name: String, v: Array) -> void:
	mat.set_shader_parameter(name, Vector4(v[0], v[1], v[2], v[3]))
	mat.set_shader_parameter(name + "_hi", Vector4(v[4], v[5], v[6], v[7]))

## Tell the terrain what the ice is reflecting.
##
## Compatibility does not bind the `Sky` to a spatial shader and the environment
## reflection is deliberately off (it was pinning the snow at white — PROGRESS
## §11), so ice gets a two-colour vertical ramp instead of a real reflection.
## The horizon end is the fog colour rather than the skybox's nadir: near the
## horizon, which is where a grazing chase camera reflects, ETR's sky *is* its
## fog — the skybox is a wall of the same white haze.
func set_sky_tint(zenith: Color, horizon: Color) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("sky_zenith", zenith)
	_material.set_shader_parameter("sky_horizon", horizon)

# ------------------------------------------------------------------
#                        procedural noise bakes
# ------------------------------------------------------------------
#
# Both textures are course-independent, so they are baked once and shared. They
# are generated rather than authored because they have to tile exactly: the
# detail map repeats every 1.1 m of world, and a seam at that pitch is a grid
# drawn across the whole course. `FastNoiseLite` does not tile, so the lattice
# below wraps its own indices instead.

const DETAIL_SIZE := 128
const SPARKLE_SIZE := 256

static var _detail_tex: ImageTexture
static var _detail_gradient_scale: float = 1.0
static var _sparkle_tex: ImageTexture

## White noise, one facet direction per texel, for the crystal glint.
##
## Mipmapped on purpose: as the texels shrink below a pixel the chain averages
## the facets back toward the surface normal, which is what a field of
## sub-pixel crystals does. The explicit distance fade in the shader then
## retires the term before the averaging leaves a smooth sheen behind.
static func _sparkle_texture() -> ImageTexture:
	if _sparkle_tex != null:
		return _sparkle_tex
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260901
	var bytes := PackedByteArray()
	bytes.resize(SPARKLE_SIZE * SPARKLE_SIZE * 3)
	for i: int in bytes.size():
		bytes[i] = rng.randi_range(0, 255)
	var img := Image.create_from_data(
		SPARKLE_SIZE, SPARKLE_SIZE, false, Image.FORMAT_RGB8, bytes)
	img.generate_mipmaps()
	_sparkle_tex = ImageTexture.create_from_image(img)
	return _sparkle_tex

## Tiling micro-relief: RG = the gradient of a height field with respect to UV,
## packed around 0.5 and divided by [member _detail_gradient_scale]; B = the
## height. One tap per octave instead of the three a heightmap would need.
static func _detail_texture() -> ImageTexture:
	if _detail_tex != null:
		return _detail_tex
	var n: int = DETAIL_SIZE
	var height := PackedFloat32Array()
	height.resize(n * n)
	# (lattice period in cells, amplitude). Every period divides DETAIL_SIZE,
	# which is what makes all three octaves wrap on the same boundary.
	var octaves: Array[Vector2] = [Vector2(4, 1.0), Vector2(8, 0.5), Vector2(16, 0.25)]
	var seed: int = 1337
	for oct: Vector2 in octaves:
		var period: int = int(oct.x)
		var amp: float = oct.y
		var lattice := PackedFloat32Array()
		lattice.resize(period * period)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		seed += 101
		for i: int in lattice.size():
			lattice[i] = rng.randf()
		var cell: float = float(n) / float(period)
		for y: int in n:
			for x: int in n:
				height[y * n + x] += amp * _lattice_value(
					lattice, period, float(x) / cell, float(y) / cell)

	# Normalise to 0..1 first: the shader's relief uniforms are metres of relief
	# for a unit-amplitude field, so the amplitude has to be known here rather
	# than being whatever three octaves happened to sum to.
	var lo: float = height[0]
	var hi: float = height[0]
	for v: float in height:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span: float = maxf(hi - lo, 1e-4)
	for i: int in height.size():
		height[i] = (height[i] - lo) / span

	# Central differences, wrapped, in texels; then to per-UV by multiplying by
	# the texel count, which is the derivative of texel index against UV.
	var gx := PackedFloat32Array()
	var gy := PackedFloat32Array()
	gx.resize(n * n)
	gy.resize(n * n)
	var peak: float = 0.0
	for y: int in n:
		for x: int in n:
			var i: int = y * n + x
			var half_n: float = 0.5 * float(n)
			gx[i] = (height[y * n + (x + 1) % n]
				- height[y * n + (x + n - 1) % n]) * half_n
			gy[i] = (height[((y + 1) % n) * n + x]
				- height[((y + n - 1) % n) * n + x]) * half_n
			peak = maxf(peak, maxf(absf(gx[i]), absf(gy[i])))
	_detail_gradient_scale = maxf(peak, 1e-4)

	var bytes := PackedByteArray()
	bytes.resize(n * n * 3)
	for i: int in n * n:
		bytes[i * 3] = _pack_signed(gx[i] / _detail_gradient_scale)
		bytes[i * 3 + 1] = _pack_signed(gy[i] / _detail_gradient_scale)
		bytes[i * 3 + 2] = int(clampf(height[i], 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGB8, bytes)
	img.generate_mipmaps()
	_detail_tex = ImageTexture.create_from_image(img)
	return _detail_tex

static func _pack_signed(v: float) -> int:
	return int(clampf(v * 0.5 + 0.5, 0.0, 1.0) * 255.0)

## Value noise on a `period`-wide wrapping lattice, quintic-interpolated.
##
## Quintic rather than cubic because the shader differentiates this field: a
## smoothstep has a discontinuous second derivative at the lattice lines, and a
## normal built from its gradient creases along them.
static func _lattice_value(lattice: PackedFloat32Array, period: int,
		u: float, v: float) -> float:
	var x0: int = int(floor(u))
	var y0: int = int(floor(v))
	var fx: float = u - float(x0)
	var fy: float = v - float(y0)
	x0 = ((x0 % period) + period) % period
	y0 = ((y0 % period) + period) % period
	var x1: int = (x0 + 1) % period
	var y1: int = (y0 + 1) % period
	var sx: float = fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
	var sy: float = fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0)
	var a: float = lerpf(lattice[y0 * period + x0], lattice[y0 * period + x1], sx)
	var b: float = lerpf(lattice[y1 * period + x0], lattice[y1 * period + x1], sx)
	return lerpf(a, b, sy)

## Point the shader at the live snow trail map.
func set_trail_map(tex: Texture2D, origin: Vector2, extent: float, depth_scale: float) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("trail_enabled", tex != null)
	_material.set_shader_parameter("trail_map", tex)
	_material.set_shader_parameter("trail_origin", origin)
	_material.set_shader_parameter("trail_extent", extent)
	# The trail map stores depth normalised against the field's maximum so an
	# RGBA8 target still resolves sub-millimetre steps; convert back to metres.
	_material.set_shader_parameter("trail_depth_scale", depth_scale)

## Instantiate chunks near `center` and drop the ones that fell behind.
##
## [param immediate] builds the whole backlog before returning, which is what a
## course load wants — the shell has already drawn its "please wait" panel and
## nothing is on screen to stutter. Every later call is budgeted: a chunk costs
## about 1.4 ms and a row of them entering the stream radius at once was a
## 26 ms frame every second and a half, at a cadence regular enough to read as
## the game hitching rather than as the machine being busy.
##
## Arriving late is free. `stream_radius` is 400 m and the camera's far plane is
## fog-limited to 70–150 m, so a chunk has hundreds of metres in which to be
## built and cannot be seen arriving.
func update_streaming(center: Vector3, immediate: bool = false) -> void:
	if immediate or center.distance_squared_to(_last_center) >= 25.0:
		_last_center = center
		_rescan(center)
	_build_pending(immediate)

## Work out what should exist. Chunks that fell out of range go now — freeing is
## cheap and holding them is memory — and what is missing is queued.
func _rescan(center: Vector3) -> void:
	var r2: float = stream_radius * stream_radius
	_pending.clear()
	for cz: int in _chunks_z:
		for cx: int in _chunks_x:
			var key := Vector2i(cx, cz)
			var bounds: AABB = _chunk_world[key]
			var near: bool = _distance_squared_to_aabb_xz(center, bounds) <= r2
			if near and not _chunks.has(key):
				_pending.push_back(key)
			elif not near and _chunks.has(key):
				_chunks[key].queue_free()
				_chunks.erase(key)
	# Nearest first: what the player is about to ride onto is worth more than
	# what is 400 m down the hill, and on a long course the queue is long enough
	# for the difference to matter.
	if _pending.size() > 1:
		_pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return _distance_squared_to_aabb_xz(center, _chunk_world[a]) \
				< _distance_squared_to_aabb_xz(center, _chunk_world[b]))

## Build from the queue, at least one and then until the budget is spent. One
## chunk always goes over the budget, deliberately — a queue that can refuse to
## make progress is a queue that never empties.
func _build_pending(immediate: bool) -> void:
	if _pending.is_empty():
		return
	var deadline: int = Time.get_ticks_usec() + int(BUILD_BUDGET_MS * 1000.0)
	while not _pending.is_empty():
		_build_chunk(_pending.pop_front())
		if not immediate and Time.get_ticks_usec() >= deadline:
			return

static func _distance_squared_to_aabb_xz(p: Vector3, box: AABB) -> float:
	var dx: float = maxf(maxf(box.position.x - p.x, 0.0), p.x - box.end.x)
	var dz: float = maxf(maxf(box.position.z - p.z, 0.0), p.z - box.end.z)
	return dx * dx + dz * dz

func _chunk_bounds(cx: int, cz: int) -> AABB:
	var step := Vector2(
		course.world_size.x / float(surface.size.x - 1),
		course.world_size.y / float(surface.size.y - 1))
	var x0: float = float(cx * (CHUNK_VERTS - 1)) * step.x
	var z0: float = -float(cz * (CHUNK_VERTS - 1)) * step.y
	var w: float = float(CHUNK_VERTS - 1) * step.x
	var d: float = float(CHUNK_VERTS - 1) * step.y
	# Generous in Y: the exact extent is computed when the chunk is built.
	return AABB(Vector3(x0, -10000.0, z0 - d), Vector3(w, 20000.0, d))

func _build_chunk(key: Vector2i) -> void:
	var w: int = surface.size.x
	var h: int = surface.size.y
	var x_start: int = key.x * (CHUNK_VERTS - 1)
	var z_start: int = key.y * (CHUNK_VERTS - 1)
	var nx: int = mini(CHUNK_VERTS, w - x_start)
	var nz: int = mini(CHUNK_VERTS, h - z_start)
	if nx < 2 or nz < 2:
		return

	var step := Vector2(
		course.world_size.x / float(w - 1),
		course.world_size.y / float(h - 1))

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(nx * nz)
	normals.resize(nx * nz)
	uvs.resize(nx * nz)

	var min_y: float = INF
	var max_y: float = -INF
	# A chunk vertex sits exactly on a heightmap texel — `step` is the surface's
	# own texel pitch — so `sample_into` would run a bilinear filter between a
	# texel and itself, four times over five arrays, 4096 times a chunk. Read
	# the grid. That is the whole of the 13x here (6.8 ms a chunk to 0.5 ms).
	#
	# It also stops the CPU snow mirror being baked into the mesh. `sample_into`
	# subtracts the live trench, so a chunk built while the player was carving
	# nearby froze a 50 cm-resolution dent into the terrain for the rest of the
	# race — invisible in practice, since chunks stream in ahead of the player
	# and the deformation window trails behind, but it made a mesh depend on
	# when it happened to be built. The trench belongs to the trail map and the
	# vertex shader.
	var grid_heights: PackedFloat32Array = surface.heights
	var grid_normals: PackedVector3Array = surface.normals
	var slope: float = surface.slope
	var inv_world_x: float = 1.0 / course.world_size.x
	var inv_world_z: float = 1.0 / course.world_size.y
	for j: int in nz:
		var row: int = (z_start + j) * w + x_start
		var wz: float = -float(z_start + j) * step.y
		var base_y: float = slope * wz
		var v: float = -wz * inv_world_z
		for i: int in nx:
			var y: float = grid_heights[row + i] + base_y
			var wx: float = float(x_start + i) * step.x
			var idx: int = j * nx + i
			verts[idx] = Vector3(wx, y, wz)
			normals[idx] = grid_normals[row + i]
			uvs[idx] = Vector2(wx * inv_world_x, v)
			min_y = minf(min_y, y)
			max_y = maxf(max_y, y)

	var indices := PackedInt32Array()
	indices.resize((nx - 1) * (nz - 1) * 6)
	var k: int = 0
	for j: int in nz - 1:
		for i: int in nx - 1:
			var a: int = j * nx + i
			var b: int = a + 1
			var c: int = a + nx
			var d: int = c + 1
			# Alternate the diagonal in a checkerboard, as ETR did, so a slope
			# has no directional bias baked into its triangulation.
			if (i + j) % 2 == 0:
				indices[k] = a; indices[k + 1] = c; indices[k + 2] = b
				indices[k + 3] = b; indices[k + 4] = c; indices[k + 5] = d
			else:
				indices[k] = a; indices[k + 1] = c; indices[k + 2] = d
				indices[k + 3] = a; indices[k + 4] = d; indices[k + 5] = b
			k += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.name = "Chunk_%d_%d" % [key.x, key.y]
	mi.mesh = mesh
	mi.material_override = _material
	# Displacement happens in the vertex shader, so pad the culling box by the
	# deepest trench the trail map can carve.
	mi.custom_aabb = AABB(
		Vector3(verts[0].x, min_y - 1.0, verts[verts.size() - 1].z),
		Vector3(float(nx - 1) * step.x, (max_y - min_y) + 2.0, float(nz - 1) * step.y))
	add_child(mi)
	_chunks[key] = mi

func chunk_count() -> int:
	return _chunks.size()
