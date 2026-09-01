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

	var roughness := Vector4(0.85, 0.85, 0.85, 0.85)
	var snowness := Vector4.ZERO
	for i: int in mini(layers.size(), 8):
		if layers[i].albedo != null:
			mat.set_shader_parameter("albedo_%d" % i, layers[i].albedo)
		if i < 4:
			# Shiny terrains — the original's `[shiny]` flag — are ice.
			roughness[i] = 0.25 if layers[i].shiny else 0.85
			# `is_deformable` is the migrated "snow deforms, rock does not"
			# flag, which is exactly the distinction the wrap and sparkle
			# terms want: shade snow as a translucent medium, rock as rock.
			snowness[i] = 1.0 if layers[i].is_deformable else 0.0
	mat.set_shader_parameter("layer_roughness", roughness)
	mat.set_shader_parameter("layer_snowness", snowness)
	mat.set_shader_parameter("uv_scale", layers[0].uv_scale if layers.size() > 0 else 6.0)
	mat.set_shader_parameter("sparkle_noise", _sparkle_texture())
	return mat

## Small tiling value-noise texture for the snow glint term.
static func _sparkle_texture() -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_VALUE
	noise.frequency = 0.35
	noise.seed = 7
	var img := Image.create_empty(128, 128, true, Image.FORMAT_R8)
	for y: int in 128:
		for x: int in 128:
			var v: float = noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			img.set_pixel(x, y, Color(v, v, v))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

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
func update_streaming(center: Vector3) -> void:
	if center.distance_squared_to(_last_center) < 25.0:
		return
	_last_center = center
	var r2: float = stream_radius * stream_radius
	for cz: int in _chunks_z:
		for cx: int in _chunks_x:
			var key := Vector2i(cx, cz)
			var bounds: AABB = _chunk_world[key]
			var near: bool = _distance_squared_to_aabb_xz(center, bounds) <= r2
			if near and not _chunks.has(key):
				_build_chunk(key)
			elif not near and _chunks.has(key):
				_chunks[key].queue_free()
				_chunks.erase(key)

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
	var sample := SurfaceSample.new()
	for j: int in nz:
		for i: int in nx:
			var wx: float = float(x_start + i) * step.x
			var wz: float = -float(z_start + j) * step.y
			surface.sample_into(wx, wz, sample)
			var idx: int = j * nx + i
			verts[idx] = Vector3(wx, sample.height, wz)
			normals[idx] = sample.normal
			uvs[idx] = Vector2(wx / course.world_size.x, -wz / course.world_size.y)
			min_y = minf(min_y, sample.height)
			max_y = maxf(max_y, sample.height)

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
