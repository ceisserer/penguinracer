## What the authored-course generators share: the splat maps written the way
## the importer writes them, a grid for keeping objects apart, the drawn
## conifer-needle floor, and the course's row in the menu's catalog.
##
## Static and stateless, so each generator stays a plain `SceneTree` script
## that says what its course is and leaves how a course is written to here.
class_name CourseGenKit
extends RefCounted

## One-hot material index → RGBA8 weight maps (four layers each), blurred
## across boundaries exactly as the importer blurs a `terrain.png`, each texel
## summing to 255.
static func splat_maps(index: PackedByteArray, w: int, h: int, layers: int) -> Array[Image]:
	var weights := PackedFloat32Array()
	weights.resize(w * h * layers)
	weights.fill(0.0)
	for i: int in index.size():
		weights[i * layers + index[i]] = 1.0
	weights = ETRImport._blur_weights(weights, w, h, layers)
	# Two locals, not an array of two: writing through `planes[m][i]` would
	# copy a whole plane per texel.
	var plane0 := PackedByteArray()
	var plane1 := PackedByteArray()
	plane0.resize(w * h * 4)
	plane1.resize(w * h * 4)
	plane0.fill(0)
	plane1.fill(0)
	var bytes := PackedInt32Array()
	bytes.resize(layers)
	for i: int in w * h:
		var total: int = 0
		var biggest: int = 0
		for l: int in layers:
			bytes[l] = roundi(weights[i * layers + l] * 255.0)
			total += bytes[l]
			if bytes[l] > bytes[biggest]:
				biggest = l
		# Rounding error goes to the dominant layer, so every texel is exact.
		bytes[biggest] += 255 - total
		for l: int in mini(layers, 4):
			plane0[i * 4 + l] = bytes[l]
		for l: int in range(4, layers):
			plane1[i * 4 + l - 4] = bytes[l]
	return [Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, plane0),
		Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, plane1)]

## Round footprints on a 4 m hash grid, for keeping things apart.
class Occupancy:
	const CELL_M := 4.0
	var _cells: Dictionary[Vector2i, Array] = {}

	func _key(x: float, z: float) -> Vector2i:
		return Vector2i(floori(x / CELL_M), floori(z / CELL_M))

	func add(x: float, z: float, r: float) -> void:
		var k: Vector2i = _key(x, z)
		if not _cells.has(k):
			_cells[k] = []
		_cells[k].push_back(Vector3(x, z, r))

	func is_free(x: float, z: float, r: float) -> bool:
		var k: Vector2i = _key(x, z)
		for dz: int in range(-2, 3):
			for dx: int in range(-2, 3):
				for o: Vector3 in _cells.get(k + Vector2i(dx, dz), []):
					if Vector2(o.x - x, o.y - z).length() < o.z + r:
						return false
		return true

# ================================================================ logs

## Spacing of a fallen log's colliders along it.
const LOG_COLLIDER_STEP := 0.5
## How far outside the play area a log's collision still matters: a racer's
## contact radius ([member RacePhysics.character_radius]) and some slack.
const LOG_REACH := 0.5

## A fallen log's collision, as `trunk_collider` markers pushed onto
## [param into]. A log prop draws only; the grid knows only upright
## cylinders, so a log is a row of them every [constant LOG_COLLIDER_STEP],
## each as wide as the log and as tall as its top stands over the ground — it
## can be hit or jumped, like Mountain Forest's fallen trunks. Only where a
## racer can get to: inside [param play] or within reach of its edge. A log
## deep in the trees needs nothing. [param placed] is a placement,
## `[x, z, Vector3(length, thick, thick), yaw]`; no random draws, so adding
## them moves nothing else on the course.
static func log_colliders(placed: Array, play: PackedVector2Array, into: Array) -> void:
	var size: Vector3 = placed[2]
	var thick: float = size.y
	# The marker's +X, turned by the yaw about +Y; the ends inset by half a
	# thickness, so the round ends of the row stop where the cut ends do.
	var dir := Vector2(cos(placed[3]), -sin(placed[3]))
	var span: float = maxf(size.x - thick, 0.0)
	var n: int = ceili(span / LOG_COLLIDER_STEP)
	# [PropMesh]'s log: radius half the thickness, axis at LOG_AXIS_Y of it.
	var top: float = (PropMesh.LOG_AXIS_Y + 0.5) * thick
	for i: int in n + 1:
		var at: Vector2 = Vector2(placed[0], placed[1]) + dir * span * (float(i) / maxi(n, 1) - 0.5)
		if near_polygon(at, play, thick * 0.5 + LOG_REACH):
			into.push_back([at.x, at.y, Vector3(thick, top, thick), 0.0])

## Whether [param at] is inside [param polygon] or within [param margin] of
## its edge.
static func near_polygon(at: Vector2, polygon: PackedVector2Array, margin: float) -> bool:
	if Geometry2D.is_point_in_polygon(at, polygon):
		return true
	for i: int in polygon.size():
		var q: Vector2 = Geometry2D.get_closest_point_to_segment(at, polygon[i],
			polygon[(i + 1) % polygon.size()])
		if at.distance_squared_to(q) < margin * margin:
			return true
	return false

## The prefab every row of log colliders shares: nothing to draw, only
## something to hit. Overwritten each run like the props.
static func write_trunk_collider_prefab() -> void:
	var collider := ObjectPrefab.new()
	collider.id = &"trunk_collider"
	collider.collidable = true
	ResourceSaver.save(collider, "res://resources/objects/trunk_collider.tres")

# ================================================================ needles

## Tileable conifer litter, [param n]² texels: dark humus, thousands of fallen
## needles — rust, tan and dark brown, a few still green — each with a soft
## shadow, a scatter of twigs and a few spruce cones. Drawn, not photographed,
## so nothing for the licence audit. Deterministic from [param seed].
static func needle_texture(n: int, seed: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var noise := FastNoiseLite.new()
	noise.seed = seed + 1
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / 90.0
	noise.fractal_octaves = 4
	var ground: Image = noise.get_seamless_image(n, n)
	# Display-space colours throughout, as a photographed texture would hold.
	var px := PackedColorArray()
	px.resize(n * n)
	var humus_dark := Color(0.13, 0.09, 0.06)
	var humus := Color(0.27, 0.18, 0.11)
	for i: int in n * n:
		var v: float = ground.get_pixel(i % n, i / n).r
		px[i] = humus_dark.lerp(humus, v)
	var palette: Array[Color] = [Color(0.55, 0.33, 0.17), Color(0.47, 0.28, 0.14),
		Color(0.64, 0.47, 0.29), Color(0.33, 0.21, 0.12), Color(0.24, 0.16, 0.10),
		Color(0.36, 0.37, 0.21)]
	var weights: Array[float] = [0.26, 0.2, 0.16, 0.2, 0.13, 0.05]
	var shadow := Color(0.05, 0.03, 0.02)
	for i: int in 16000:
		var at := Vector2(rng.randf() * n, rng.randf() * n)
		var dir := Vector2.from_angle(rng.randf() * TAU)
		var length: float = rng.randf_range(6.0, 13.0)
		var col: Color = palette[_pick(rng, weights)] * rng.randf_range(0.85, 1.15)
		_stroke(px, n, at + Vector2(1.0, 1.0), dir, length, 1.0, shadow, 0.35)
		_stroke(px, n, at, dir, length, 1.0, col, 0.9)
	for i: int in 45:
		var at := Vector2(rng.randf() * n, rng.randf() * n)
		var dir := Vector2.from_angle(rng.randf() * TAU)
		var length: float = rng.randf_range(20.0, 60.0)
		var col := Color(0.30, 0.24, 0.18) * rng.randf_range(0.8, 1.1)
		_stroke(px, n, at + Vector2(1.5, 1.5), dir, length, 2.0, shadow, 0.4)
		_stroke(px, n, at, dir, length, 2.0, col, 1.0)
	for i: int in 6:
		_cone(px, n, Vector2(rng.randf() * n, rng.randf() * n),
			Vector2.from_angle(rng.randf() * TAU), rng.randf_range(16.0, 24.0), rng)
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGB8)
	for i: int in n * n:
		img.set_pixel(i % n, i / n, px[i])
	return img

## The needle floor as a [TerrainLayer] over [param texture]: forest-floor
## friction and sound, like ETR's `forest_floor1/2`, no snow physics, and a
## finer repeat than ETR's 6 m so a needle is a needle at the racer's feet.
static func needles_layer(texture: Texture2D) -> TerrainLayer:
	var layer := TerrainLayer.new()
	layer.id = &"conifer_needles"
	layer.friction = 0.5
	layer.compression_depth = 0.02
	layer.emits_particles = false
	layer.takes_trackmarks = false
	layer.is_deformable = false
	layer.slide_sound = &"leaves_sound"
	layer.albedo = texture
	layer.roughness = 0.9
	layer.uv_scale = 3.0
	layer.detail_strength = 0.5
	return layer

static func _pick(rng: RandomNumberGenerator, weights: Array[float]) -> int:
	var r: float = rng.randf()
	for i: int in weights.size():
		r -= weights[i]
		if r <= 0.0:
			return i
	return weights.size() - 1

## A straight stroke [param width] texels wide, wrapped at the edges so the
## tile repeats, blended at [param alpha] and tapered at both ends.
static func _stroke(px: PackedColorArray, n: int, at: Vector2, dir: Vector2, length: float,
		width: float, col: Color, alpha: float) -> void:
	var side := Vector2(-dir.y, dir.x)
	var steps: int = ceili(length / 0.6)
	for s: int in steps + 1:
		var t: float = float(s) / steps
		var taper: float = minf(1.0, minf(t, 1.0 - t) * 6.0 + 0.3)
		var p: Vector2 = at + dir * (t * length)
		var w: float = width * taper
		var off: float = -w * 0.5
		while off <= w * 0.5:
			# Bilinear: the sample shares itself between the four texels round
			# it, so a needle's edge is soft rather than a staircase.
			var q: Vector2 = p + side * off - Vector2(0.5, 0.5)
			var x0: int = floori(q.x)
			var y0: int = floori(q.y)
			var fx: float = q.x - x0
			var fy: float = q.y - y0
			for k: int in 4:
				var wx: float = fx if k & 1 else 1.0 - fx
				var wy: float = fy if k & 2 else 1.0 - fy
				var i: int = posmod(y0 + (k >> 1), n) * n + posmod(x0 + (k & 1), n)
				px[i] = px[i].lerp(col, alpha * wx * wy * 1.6)
			off += 0.7

## A spruce cone lying on its side: a tapered brown body in rows of scales.
static func _cone(px: PackedColorArray, n: int, at: Vector2, dir: Vector2, length: float,
		rng: RandomNumberGenerator) -> void:
	var side := Vector2(-dir.y, dir.x)
	var rows: int = int(length / 2.5)
	for r: int in rows:
		var t: float = (float(r) + 0.5) / rows
		var radius: float = length * 0.2 * sin(PI * clampf(t * 1.1, 0.0, 1.0)) + 1.0
		var centre: Vector2 = at + dir * (t * length)
		var col := Color(0.42, 0.26, 0.13) * rng.randf_range(0.85, 1.1)
		_stroke(px, n, centre - side * radius + Vector2(1.0, 1.0), side, radius * 2.0, 2.2,
			Color(0.05, 0.03, 0.02), 0.5)
		_stroke(px, n, centre - side * radius, side, radius * 2.0, 2.0, col, 1.0)

# ================================================================ scene

## `course.tscn` under [param out]: the [CourseRoot] named [param dir] and one
## marker per object, as the importer writes them, with each type's prefab from
## `res://resources/objects/`. [param objects] is `{type: [[x, z, scale, yaw],
## …]}`; an entry may go on with a height above the ground and a roll about
## the marker's own X (a lodged trunk, leaning from bank to bank).
## [param prefab_of] draws a type with another type's prefab (a boulder on the
## trail is a `boulder`); every other type is its own.
static func write_scene(dir: String, out: String, objects: Dictionary[String, Array],
		prefab_of: Dictionary[String, String] = {}) -> void:
	var prefabs: Dictionary[String, ObjectPrefab] = {}
	for t: String in objects:
		prefabs[t] = load("res://resources/objects/%s.tres" % prefab_of.get(t, t))
	var root := Node3D.new()
	root.name = dir
	root.set_script(load("res://scripts/course/course_root.gd"))
	root.set("course_data", load(out.path_join("course.tres")))
	root.set("object_prefabs", prefabs)
	var objects_root := Node3D.new()
	objects_root.name = "Objects"
	root.add_child(objects_root)
	objects_root.owner = root
	for t: String in objects:
		if objects[t].is_empty():
			continue
		var group := Node3D.new()
		group.name = t
		objects_root.add_child(group)
		group.owner = root
		var n: int = 0
		for o: Array in objects[t]:
			var marker := Marker3D.new()
			marker.name = "%s_%d" % [t, n]
			n += 1
			# Y is resolved against the surface at load, as for every course;
			# what is stored is a height above it.
			marker.position = Vector3(o[0], o[4] if o.size() > 4 else 0.0, o[1])
			marker.rotation = Vector3(0.0, o[3], o[5] if o.size() > 5 else 0.0)
			marker.scale = o[2]
			group.add_child(marker)
			marker.owner = root
	var packed := PackedScene.new()
	if packed.pack(root) == OK:
		ResourceSaver.save(packed, out.path_join("course.tscn"))
	root.free()

# ================================================================ catalog

## Add or replace [param dir]'s row in the menu index, keeping every other.
static func write_listing(dir: String, out: String, course: CourseData) -> void:
	var listing := CourseListing.new()
	listing.dir = dir
	listing.group = CourseListing.AUTHORED_GROUP
	listing.display_name = course.display_name
	listing.author = course.author
	listing.description = course.description
	listing.scene_path = out.path_join("course.tscn")
	listing.course_path = out.path_join("course.tres")
	listing.preview_path = out.path_join("preview.png")
	listing.world_size = course.world_size
	listing.base_angle = course.base_angle
	var catalog: CourseCatalog = load(CourseCatalog.PATH)
	var entries: Array[CourseListing] = []
	for e: CourseListing in catalog.entries:
		if e.dir != dir:
			entries.push_back(e)
	entries.push_back(listing)
	catalog.entries = entries
	catalog.sort()
	ResourceSaver.save(catalog, CourseCatalog.PATH)
