## The solid props ([PropMesh]: boulder, stones, log, stump) and the authored
## course that stands them in its forest, Forest Trail
## (`addons/course_gen/gen_forest_trail.gd`).
##
## Headless, so every check is on what feeds the GPU and the simulation — the
## mesh arrays, the prefabs, the markers against the trail — never the frame.
class_name TestProps
extends RefCounted

const PROPS: Array[String] = ["boulder", "stones", "log", "stump"]
const COURSE_DIR := "forest_trail"
const GENERATOR := "res://addons/course_gen/gen_forest_trail.gd"

static func run(t: TestCase) -> void:
	_meshes_face_out(t)
	_meshes_fill_the_unit_box(t)
	_prefabs_are_on_disk(t)
	_the_ground_normal(t)
	_the_course_is_listed(t)
	_nothing_stands_on_the_trail(t)
	_the_trail_forks(t)
	_the_forest_is_open(t)
	_the_logs_are_solid(t)
	_the_forest_floor(t)

## Every face wound so its normal points away from the mesh's middle — the
## winding is what the renderer culls on, and a rock turned inside out draws
## only its far side.
static func _meshes_face_out(t: TestCase) -> void:
	t.begin("props/faces point out")
	for kind: int in PropMesh.Kind.values():
		var mesh: ArrayMesh = PropMesh.build(kind)
		var arrays: Array = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null \
			else PackedInt32Array()
		t.ok(not index.is_empty(), "kind %d is indexed" % kind)
		t.ok(arrays[Mesh.ARRAY_COLOR] != null, "kind %d carries its colours" % kind)
		var middle := Vector3.ZERO
		for v: Vector3 in verts:
			middle += v
		middle /= float(maxi(verts.size(), 1))
		var outward: int = 0
		var faces: int = index.size() / 3
		for f: int in faces:
			var a: Vector3 = verts[index[f * 3]]
			var b: Vector3 = verts[index[f * 3 + 1]]
			var c: Vector3 = verts[index[f * 3 + 2]]
			var n: Vector3 = normals[index[f * 3]]
			if n.dot((a + b + c) / 3.0 - middle) > 0.0:
				outward += 1
		# Stones are a cluster, whose middle is between the stones, and a log's
		# stubs and end caps lean every way — most, not all, for those.
		var wanted: float = 0.97 if kind == PropMesh.Kind.BOULDER else 0.75
		t.ok(float(outward) / faces >= wanted,
			"kind %d: %d of %d faces point away from its middle" % [kind, outward, faces])

## Unit-sized, as the marker scale assumes: ±0.5 across and 1 up, and a little
## below 0 so it sits in the ground. A stump's roots and a log's branch stubs
## are allowed past the box, by a fraction of the object.
static func _meshes_fill_the_unit_box(t: TestCase) -> void:
	t.begin("props/unit box")
	for kind: int in PropMesh.Kind.values():
		var box: AABB = PropMesh.build(kind).get_aabb()
		t.ok(box.position.x >= -0.7 and box.end.x <= 0.7
			and box.position.z >= -0.7 and box.end.z <= 0.7,
			"kind %d is ±0.5 across (%s)" % [kind, box])
		t.ok(box.end.y <= 1.25 and box.end.y > 0.1, "kind %d is about 1 tall (%s)" % [kind, box])
		t.ok(box.position.y < 0.0 and box.position.y > -0.3,
			"kind %d reaches a little into the ground (%s)" % [kind, box])

static func _prefabs_are_on_disk(t: TestCase) -> void:
	t.begin("props/prefabs")
	for id: String in PROPS:
		var p: ObjectPrefab = load("res://resources/objects/%s.tres" % id)
		t.ok(p != null and p.mesh != null, "%s has a mesh" % id)
		if p == null:
			continue
		t.ok(p.ground_aligned, "%s lies on the slope" % id)
		t.ok(not (p.conifer or p.bare or p.shrub), "%s is not a tree" % id)
		var mat: ShaderMaterial = p.material as ShaderMaterial
		t.ok(mat != null and mat.shader != null
			and mat.shader.resource_path == "res://shaders/object_prop.gdshader",
			"%s is drawn with object_prop.gdshader" % id)
	var boulder: ObjectPrefab = load("res://resources/objects/boulder.tres")
	var stones: ObjectPrefab = load("res://resources/objects/stones.tres")
	t.ok(boulder != null and boulder.collidable, "a boulder is something to hit")
	t.ok(stones != null and not stones.collidable and stones.decorative,
		"a scatter of stones is not")
	for id: String in ["tree", "shrub", "herring"]:
		var p: ObjectPrefab = load("res://resources/objects/%s.tres" % id)
		t.ok(p != null and not p.ground_aligned, "%s still stands upright" % id)

## [method CourseRoot.ground_normal] on a plain slope is the slope's normal.
static func _the_ground_normal(t: TestCase) -> void:
	t.begin("props/ground normal")
	var size := Vector2i(41, 41)
	var heights := PackedFloat32Array()
	heights.resize(size.x * size.y)
	heights.fill(0.0)
	var surface := HeightmapSurface.new()
	surface.build(heights, size, Vector2(40.0, 40.0), 20.0)
	var root := CourseRoot.new()
	root.surface = surface
	var n: Vector3 = root.ground_normal(Vector3(20.0, 0.0, -20.0))
	# Downhill is −Z, so the normal leans that way.
	var expected := Vector3(0.0, cos(deg_to_rad(20.0)), -sin(deg_to_rad(20.0)))
	t.ok(n.distance_to(expected) < 1e-3,
		"a 20° fall line tilts the prop 20° down it (%v vs %v)" % [n, expected])
	root.free()

static func _the_course_is_listed(t: TestCase) -> void:
	t.begin("props/forest trail in the catalog")
	var listing: CourseListing = CourseCatalog.load_default().find(COURSE_DIR)
	t.ok(listing != null, "Forest Trail is in the course catalog")
	if listing == null:
		return
	t.ok(listing.category() == CourseListing.Category.PENGUINRACER,
		"listed under this project's own courses, not ETR's")
	t.ok(ResourceLoader.exists(listing.preview_path), "it has a preview")
	var course: CourseData = load(listing.course_path)
	t.ok(course != null and course.imported_from.is_empty(),
		"it is authored, so the ETR importer never rewrites it")

## Trees, bushes and props stand in the forest and not on the trail, on earth
## and not on snow or ice; the herring and the banners are on the trail.
static func _nothing_stands_on_the_trail(t: TestCase) -> void:
	t.begin("props/forest trail's markers")
	var gen: GDScript = load(GENERATOR)
	var scene: PackedScene = load("res://courses/%s/course.tscn" % COURSE_DIR)
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	if gen == null or scene == null or course == null:
		t.ok(false, "the generator and the course load")
		return
	var surface: HeightmapSurface = HeightmapSurface.from_course(course)
	var sample := SurfaceSample.new()
	var root: Node = scene.instantiate()
	var off_trail: Array[String] = ["tree", "shrub", "boulder", "stones", "log", "stump"]
	var counts: Dictionary[String, int] = {}
	var misplaced: PackedStringArray = []
	var on_snow: PackedStringArray = []
	for group: Node in root.get_node("Objects").get_children():
		var type_name: String = group.name
		counts[type_name] = group.get_child_count()
		for marker: Node3D in group.get_children():
			var p: Vector3 = marker.position
			var beyond: float = gen.beyond_edge(p.x, p.z)
			# A log's colliders lie under it, off the trail; what is under
			# them is the log's business (_the_logs_are_solid).
			if type_name == "trunk_collider":
				if beyond <= 0.0:
					misplaced.push_back(marker.name)
				continue
			if off_trail.has(type_name):
				if beyond <= 0.0:
					misplaced.push_back(marker.name)
				surface.sample_into(p.x, p.z, sample)
				var layer: StringName = course.terrain_layers[sample.terrain_id].id
				if layer == &"snow" or layer == &"ice1":
					on_snow.push_back("%s (%s)" % [marker.name, layer])
			elif beyond > 0.0:
				misplaced.push_back(marker.name)
	root.free()
	for type_name: String in off_trail + ["herring", "start", "finish"]:
		t.ok(counts.get(type_name, 0) > 0, "the course has %s" % type_name)
	t.ok(counts.get("tree", 0) > 1000, "a forest of conifers (%d)" % counts.get("tree", 0))
	t.ok(misplaced.is_empty(), "everything is on its side of the trail's edge %s"
		% str(misplaced.slice(0, 8)))
	t.ok(on_snow.is_empty(), "nothing in the forest stands on snow or ice %s"
		% str(on_snow.slice(0, 8)))
	# The trail has ice on it, and the play area follows it.
	var ice: int = course.terrain_layers.find(load("res://resources/terrain/ice1.tres"))
	t.ok(ice >= 0, "the course carries the ice layer")
	var start := Vector2(course.start_position.x, -course.start_position.y)
	t.ok(Geometry2D.is_point_in_polygon(start, course.effective_play_bounds()),
		"the start is inside the play area")
	t.ok(not Geometry2D.is_point_in_polygon(Vector2(2.0, -800.0), course.effective_play_bounds()),
		"the deep forest is not")

## One trail at the top and the bottom, two in the middle with forest between.
static func _the_trail_forks(t: TestCase) -> void:
	t.begin("props/forest trail forks")
	var gen: GDScript = load(GENERATOR)
	if gen == null:
		t.ok(false, "the generator loads")
		return
	var top: float = gen.SPLIT_START - 20.0
	var middle: float = (gen.SPLIT_START + gen.SPLIT_END) * 0.5
	var bottom: float = gen.SPLIT_END + 20.0
	for d: float in [top, bottom]:
		t.ok(is_equal_approx(gen.centre_x(d, 0), gen.centre_x(d, 1)),
			"one trail %.0f m down" % d)
	var left: float = gen.centre_x(middle, 0)
	var right: float = gen.centre_x(middle, 1)
	t.ok(gen.beyond_edge(left, -middle) < 0.0 and gen.beyond_edge(right, -middle) < 0.0,
		"two trails %.0f m down, at x %.1f and %.1f" % [middle, left, right])
	t.ok(gen.beyond_edge((left + right) * 0.5, -middle) > 5.0,
		"with forest between them")
	# Both are inside the play area, which spans the fork.
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	for x: float in [left, right]:
		t.ok(Geometry2D.is_point_in_polygon(Vector2(x, -middle), course.effective_play_bounds()),
			"the branch at x %.1f is in the play area" % x)

## A racer may leave the trail and ride the forest beside it, well past the
## tree line, but not out to the edge of the world. The trail itself is a
## narrower polygon of its own: the computer plans inside it and the torches
## stand along it.
static func _the_forest_is_open(t: TestCase) -> void:
	t.begin("props/forest trail's forest is open to ride")
	var gen: GDScript = load(GENERATOR)
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	var play: PackedVector2Array = course.effective_play_bounds()
	var trail: PackedVector2Array = course.effective_trail_bounds()
	t.ok(course.trail_bounds.size() >= 3 and trail != play, "the course names a trail of its own")
	# Only a player has the woods: an opponent let into them ran wide on the
	# bends, so the simulation holds it to the trail.
	t.ok(RaceSetup.bounds_for(LocalInputSource.new(), course) == play,
		"a player may go anywhere in the play area")
	t.ok(RaceSetup.bounds_for(AIInputSource.new(), course) == trail,
		"a computer opponent is held to the trail")
	var imported: CourseData = load("res://courses/bunny_hill/course.tres")
	t.ok(imported.effective_trail_bounds() == imported.effective_play_bounds(),
		"an imported course's trail is its play area")
	var short: PackedStringArray = []
	var wide: PackedStringArray = []
	var d: float = 20.0
	while d < gen.PLAY.y:
		for b: int in gen.BRANCHES:
			var c: float = gen.centre_x(d, b)
			var edge: float = gen.lateral_half_width(d, b)
			for side: float in [-1.0, 1.0]:
				var far := Vector2(c + side * (edge + 15.0), -d)
				if not Geometry2D.is_point_in_polygon(far, play):
					short.push_back("%.0f m, x %.1f" % [d, far.x])
				# Past the trail's own margin is off the trail, but for the
				# island in the fork, which is inside both.
				var off := Vector2(c + side * (edge + gen.CORRIDOR_MARGIN + 3.0), -d)
				if gen.split(d) < 0.01 and Geometry2D.is_point_in_polygon(off, trail):
					wide.push_back("%.0f m, x %.1f" % [d, off.x])
		d += 10.0
	t.ok(short.is_empty(), "the play area reaches 15 m into the forest either side: %s"
		% ", ".join(short.slice(0, 8)))
	t.ok(wide.is_empty(), "the trail does not: %s" % ", ".join(wide.slice(0, 8)))
	var near_edge: int = 0
	for p: Vector2 in play:
		if p.x < gen.WORLD_EDGE_FOREST - 1e-3 or p.x > gen.WORLD.x - gen.WORLD_EDGE_FOREST + 1e-3:
			near_edge += 1
	t.ok(near_edge == 0, "and keeps forest between it and the world's edge (%d)" % near_edge)
	# The torches stand along the trail, not out at the play area's edge.
	var flat := HeightmapSurface.new()
	flat.build(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]), Vector2i(2, 2), course.world_size, 0.0)
	var torches: PackedVector3Array = CourseLights.torch_positions(course, flat, null, [])
	var astray: int = 0
	for at: Vector3 in torches:
		var p := Vector2(at.x, at.z)
		var gap: float = INF
		for i: int in trail.size():
			gap = minf(gap, p.distance_to(Geometry2D.get_closest_point_to_segment(p, trail[i],
				trail[(i + 1) % trail.size()])))
		if absf(gap - CourseLights.OUTSET) > 0.05 or not Geometry2D.is_point_in_polygon(p, play):
			astray += 1
	t.ok(torches.size() > 100 and astray == 0,
		"the torches line the trail, inside the play area (%d of %d astray)"
		% [astray, torches.size()])

## A fallen log within a racer's reach of the play area is something to hit,
## along its whole length: a row of `trunk_collider` cylinders under it, as wide
## as it and as tall as its top, and a racer sliding at one is turned away. The
## log prefab itself stays uncollidable — its one cylinder would be as wide as
## the log is long.
static func _the_logs_are_solid(t: TestCase) -> void:
	t.begin("props/forest trail's logs are solid")
	var log_prefab: ObjectPrefab = load("res://resources/objects/log.tres")
	var collider: ObjectPrefab = load("res://resources/objects/trunk_collider.tres")
	t.ok(log_prefab != null and not log_prefab.collidable, "a log draws only")
	t.ok(collider != null and collider.collidable and collider.mesh == null,
		"its collider is only something to hit")
	var packed: PackedScene = load("res://courses/%s/course.tscn" % COURSE_DIR)
	var root: CourseRoot = packed.instantiate()
	root.build_runtime()
	var play: PackedVector2Array = root.course_data.effective_play_bounds()
	var logs: Array = []
	for marker: Node3D in root.get_node("Objects/log").get_children():
		logs.push_back(marker)
	var cols: Array[Node3D] = []
	for marker: Node3D in root.get_node("Objects/trunk_collider").get_children():
		cols.push_back(marker)
	t.ok(cols.size() > 100, "the logs in reach have colliders (%d)" % cols.size())
	# Every collider lies along a log, as wide as it and no taller.
	var stray: PackedStringArray = []
	for c: Node3D in cols:
		var on: bool = false
		for l: Node3D in logs:
			var axis := Vector2(cos(l.rotation.y), -sin(l.rotation.y))
			var rel := Vector2(c.position.x - l.position.x, c.position.z - l.position.z)
			on = on or (absf(rel.dot(axis)) <= l.scale.x * 0.5 + 1e-3
				and absf(rel.cross(axis)) < 1e-3
				and is_equal_approx(c.scale.x, l.scale.y)
				and c.scale.y <= (PropMesh.LOG_AXIS_Y + 0.5) * l.scale.y + 1e-3)
		if not on:
			stray.push_back(c.name)
	t.ok(stray.is_empty(), "every collider lies along a log: %s" % ", ".join(stray.slice(0, 8)))
	# Every log with its middle in the play area has a collider there.
	var bare: PackedStringArray = []
	for l: Node3D in logs:
		if not Geometry2D.is_point_in_polygon(Vector2(l.position.x, l.position.z), play):
			continue
		var found: bool = false
		for c: Node3D in cols:
			found = found or Vector2(c.position.x - l.position.x,
				c.position.z - l.position.z).length() < CourseGenKit.LOG_COLLIDER_STEP
		if not found:
			bare.push_back(l.name)
	t.ok(bare.is_empty(), "no log in the play area without one: %s"
		% ", ".join(bare.slice(0, 8)))
	# Slide straight down at a log in the play area: a hit, and turned away.
	var target: Node3D = null
	for c: Node3D in cols:
		if Geometry2D.is_point_in_polygon(Vector2(c.position.x, c.position.z + 6.0), play):
			target = c
			break
	t.ok(target != null, "a log in the play area to slide at")
	if target != null:
		var sim := RacePhysics.new()
		sim.surface = root.surface
		root.surface.snow_field = SnowField.new()
		sim.trees = root.trees
		sim.bounds_polygon = play
		sim.play_length = root.course_data.play_size.y
		sim.init_at(target.position.x, target.position.z + 6.0)
		var hits: Array[Vector3] = []
		sim.tree_hit.connect(func(pos: Vector3) -> void: hits.push_back(pos))
		var input := RaceInput.new()
		for i: int in 180:
			sim.step(input, 1.0 / 60.0)
		var on_log: bool = false
		for h: Vector3 in hits:
			for c: Node3D in cols:
				on_log = on_log or Vector2(h.x - c.position.x, h.z - c.position.z).length() < 0.01
		t.ok(on_log, "a racer sliding at %s hits it (%d hits)" % [target.name, hits.size()])
	root.free()

## The floor is the course's own needle layer under the crowns, with snow in
## the gaps between them.
static func _the_forest_floor(t: TestCase) -> void:
	t.begin("props/forest floor")
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	var ids: Array[StringName] = []
	for layer: TerrainLayer in course.terrain_layers:
		ids.push_back(layer.id)
	var needles: int = ids.find(&"conifer_needles")
	t.ok(needles >= 0, "the course carries its needle layer %s" % ids)
	if needles < 0:
		return
	var layer: TerrainLayer = course.terrain_layers[needles]
	t.ok(layer.resource_path.begins_with("res://courses/%s/" % COURSE_DIR),
		"kept with the course, not in the imported library (%s)" % layer.resource_path)
	t.ok(layer.albedo != null and layer.albedo.get_width() == 512, "with its drawn texture")
	t.ok(not layer.is_deformable and not layer.is_ice(), "and it is ground, not snow")
	# Where the dominant layer falls across the whole forest.
	var surface: HeightmapSurface = HeightmapSurface.from_course(course)
	var sample := SurfaceSample.new()
	var counts: Dictionary[StringName, int] = {}
	var forest: int = 0
	var gen: GDScript = load(GENERATOR)
	for gz: int in range(2, 1598, 4):
		for gx: int in range(2, 118, 4):
			if gen.beyond_edge(float(gx), -float(gz)) < 3.0:
				continue
			surface.sample_into(float(gx), -float(gz), sample)
			var id: StringName = ids[sample.terrain_id]
			counts[id] = counts.get(id, 0) + 1
			forest += 1
	var litter: float = float(counts.get(&"conifer_needles", 0)) / forest
	var snowy: float = float(counts.get(&"thin_snow", 0)) / forest
	t.ok(litter > 0.5, "most of the forest floor is needles (%.0f %%)" % (litter * 100.0))
	t.ok(snowy > 0.1 and snowy < 0.4,
		"and some of it is snow, where the crowns leave gaps (%.0f %%)" % (snowy * 100.0))
	t.ok(counts.get(&"snow", 0) == 0, "the trail's own snow stays on the trail")
