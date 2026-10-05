## The second authored course, Mountain Forest
## (`addons/course_gen/gen_mountain_forest.gd`): a narrow trail down a walled
## gully whose fall line alternates chutes and benches, with trunks lodged
## across it overhead, bumps to jump and boulders and fallen trunks on it to
## steer round.
##
## Headless, so every check is on what the race is handed — the heightmap as
## [HeightmapSurface] reads it, the markers, the course's fields — never on
## the frame.
class_name TestMountainForest
extends RefCounted

const COURSE_DIR := "mountain_forest"
const GENERATOR := "res://addons/course_gen/gen_mountain_forest.gd"
## The least room under a lodged trunk, anywhere over the trail: the chase
## camera rides about 1.6 m over the snow and must pass under it too.
const MIN_HEADROOM := 3.0

static func run(t: TestCase) -> void:
	var gen: GDScript = load(GENERATOR)
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	var scene: PackedScene = load("res://courses/%s/course.tscn" % COURSE_DIR)
	t.begin("mountain forest/loads")
	t.ok(gen != null and course != null and scene != null,
		"the generator, the course and its scene load")
	if gen == null or course == null or scene == null:
		return
	var surface: HeightmapSurface = HeightmapSurface.from_course(course)
	_the_course_is_listed(t, course)
	_the_backdrop_is_near(t, course)
	_the_fall_line_steps(t, gen, surface)
	_the_trail_runs_in_a_gully(t, gen, surface)
	_the_markers(t, gen, scene)
	_nothing_stands_on_wall_ice(t, gen, course, scene)
	_the_trunks_are_overhead(t, gen, surface, scene)
	_the_obstacles_leave_a_line(t, gen, scene)
	_the_bumps(t, gen, surface)
	_a_marker_can_stand_off_the_ground(t, course, surface)
	_the_rock_faces(t, gen, course, surface, scene)

static func _the_course_is_listed(t: TestCase, course: CourseData) -> void:
	t.begin("mountain forest/catalog")
	var listing: CourseListing = CourseCatalog.load_default().find(COURSE_DIR)
	t.ok(listing != null, "Mountain Forest is in the course catalog")
	if listing == null:
		return
	t.ok(listing.category() == CourseListing.Category.PENGUINRACER,
		"listed under this project's own courses")
	t.ok(ResourceLoader.exists(listing.preview_path), "it has a preview")
	t.ok(course.imported_from.is_empty(), "it is authored, so the importer never rewrites it")
	var needles: TerrainLayer = course.terrain_layers[4]
	t.ok(needles != null and needles.albedo != null
		and needles.resource_path.begins_with("res://courses/%s/" % COURSE_DIR)
		and needles.albedo.resource_path.begins_with("res://courses/%s/" % COURSE_DIR),
		"its needle floor is its own, in its own directory (a web pack carries only that)")

## The sky over a gully is the next range over, tall and wooded.
static func _the_backdrop_is_near(t: TestCase, course: CourseData) -> void:
	t.begin("mountain forest/backdrop")
	var shape: Vector4 = Atmosphere.ridge_shape(course)
	t.ok(shape.x > 1.5, "the ranges stand taller than the usual skyline (%.2f)" % shape.x)
	t.ok(shape.y > 0.5, "wooded up their flanks (%.2f)" % shape.y)
	t.ok(shape.z > 0.5, "and near (%.2f)" % shape.z)

## Down the trail's middle, measured on the heightmap the race reads: chutes
## well over the analytic slope and benches well under it, several of each,
## and nowhere uphill.
static func _the_fall_line_steps(t: TestCase, gen: GDScript, surface: HeightmapSurface) -> void:
	t.begin("mountain forest/fall line")
	var steep: int = 0
	var bench: int = 0
	var uphill: int = 0
	var was: int = 0
	var d: float = 20.0
	while d < 1400.0:
		var a: float = surface.height_at(gen.centre_x(d - 5.0), -(d - 5.0))
		var b: float = surface.height_at(gen.centre_x(d + 5.0), -(d + 5.0))
		var deg: float = rad_to_deg(atan((a - b) / 10.0))
		# Count each run once, as it starts.
		var now: int = 1 if deg > 24.0 else (-1 if deg < 16.0 else 0)
		if now == 1 and was != 1:
			steep += 1
		if now == -1 and was != -1:
			bench += 1
		if now != 0:
			was = now
		if deg < 0.0:
			uphill += 1
		d += 5.0
	t.ok(steep >= 5, "%d chutes steeper than 24°" % steep)
	t.ok(bench >= 5, "%d benches under 16°" % bench)
	t.ok(uphill == 0, "the trail never climbs (%d places)" % uphill)
	var base: float = gen.base_angle()
	t.between(base, 18.0, 26.0, "the base slope is their mean (%.2f°)" % base)

## Both walls stand over the trail all the way down, higher the further out.
static func _the_trail_runs_in_a_gully(t: TestCase, gen: GDScript,
		surface: HeightmapSurface) -> void:
	t.begin("mountain forest/gully")
	var low: PackedStringArray = []
	var widths := PackedFloat32Array()
	var d: float = 80.0
	while d < 1380.0:
		var cx: float = gen.centre_x(d)
		var hl: float = gen.lateral_half_width(d)
		if gen.obstacle_room(d) == 0.0:
			widths.push_back(2.0 * gen.half_width(d))
		var floor_y: float = surface.height_at(cx, -d)
		for side: float in [-1.0, 1.0]:
			var near: float = surface.height_at(cx + side * (hl + 8.0), -d) - floor_y
			var far: float = surface.height_at(cx + side * (hl + 25.0), -d) - floor_y
			if near < 4.0 or far < 10.0:
				low.push_back("%.0f m %s (%.1f, %.1f)" % [d, "left" if side < 0.0 else "right",
					near, far])
		d += 10.0
	t.ok(low.is_empty(), "the walls stand 4 m up 8 m out and 10 m up 25 m out: %s"
		% ", ".join(low.slice(0, 6)))
	var widest: float = 0.0
	for w: float in widths:
		widest = maxf(widest, w)
	t.ok(widest <= 9.0, "the trail is never wider than 9 m between the gates, but beside an "
		+ "obstacle (%.1f)" % widest)

## Trees, bushes and props off the trail; herring and banners on it.
static func _the_markers(t: TestCase, gen: GDScript, scene: PackedScene) -> void:
	t.begin("mountain forest/markers")
	var root: Node = scene.instantiate()
	var off_trail: Array[String] = ["tree", "shrub", "boulder", "stones", "log", "stump",
		"stone_pile"]
	var on_trail: Array[String] = ["herring", "start", "finish", "trail_boulder"]
	var counts: Dictionary[String, int] = {}
	var misplaced: PackedStringArray = []
	for group: Node in root.get_node("Objects").get_children():
		var type_name: String = group.name
		counts[type_name] = group.get_child_count()
		# Trunks, lodged overhead or fallen, reach from bank to trail.
		if type_name in ["lodged_log", "fallen_trunk", "trunk_collider"]:
			continue
		for marker: Node3D in group.get_children():
			var beyond: float = gen.beyond_edge(marker.position.x, marker.position.z)
			if (off_trail.has(type_name) and beyond <= 0.0) \
					or (on_trail.has(type_name) and beyond > 0.0):
				misplaced.push_back(marker.name)
			# A pile's upper stones rest on its lower ones.
			if (marker.position.y != 0.0 and type_name != "stone_pile") \
					or marker.rotation.x != 0.0 or marker.rotation.z != 0.0:
				misplaced.push_back("%s (off the ground)" % marker.name)
	root.free()
	for type_name: String in off_trail + on_trail:
		t.ok(counts.get(type_name, 0) > 0, "the course has %s" % type_name)
	t.ok(misplaced.is_empty(), "every marker on the right side of the edge: %s"
		% ", ".join(misplaced.slice(0, 8)))
	t.eq_f(float(counts.get("lodged_log", 0)), float(gen.LOGS.size()), 0.0,
		"a trunk at every slot")
	t.eq_f(float(counts.get("trail_boulder", 0)), float(gen.TRAIL_BOULDERS.size()), 0.0,
		"every boulder on the trail")
	t.eq_f(float(counts.get("fallen_trunk", 0)), float(gen.FALLEN_TRUNKS.size()), 0.0,
		"every fallen trunk")
	t.ok(counts.get("stone_pile", 0) >= 5, "a pile of stones beside the trail")

## The walls' ice is bare: no tree, bush, stone, stump or log stands on it.
## Read off the splat map the race draws, not the generator's noise.
static func _nothing_stands_on_wall_ice(t: TestCase, gen: GDScript, course: CourseData,
		scene: PackedScene) -> void:
	t.begin("mountain forest/wall ice is bare")
	var splat: Image = course.splat_maps[0].get_image()
	var ice_channel: int = gen.L_ICE
	var root: Node = scene.instantiate()
	var on_ice: PackedStringArray = []
	var checked: int = 0
	for type_name: String in ["tree", "shrub", "boulder", "stones", "log", "stump",
			"stone_pile"]:
		var group: Node = root.get_node_or_null("Objects/%s" % type_name)
		if group == null:
			continue
		for marker: Node3D in group.get_children():
			var p: Vector3 = marker.position
			# Only the walls: the trail's own ice patches are not the question.
			if gen.beyond_edge(p.x, p.z) <= 1.0:
				continue
			var px: int = clampi(roundi(p.x / course.world_size.x * (splat.get_width() - 1)),
				0, splat.get_width() - 1)
			var py: int = clampi(roundi(-p.z / course.world_size.y * (splat.get_height() - 1)),
				0, splat.get_height() - 1)
			checked += 1
			if splat.get_pixel(px, py)[ice_channel] > 0.5:
				on_ice.push_back(marker.name)
	root.free()
	t.ok(checked > 0, "markers on the walls to check")
	t.ok(on_ice.is_empty(), "nothing on the walls' ice: %s" % ", ".join(on_ice.slice(0, 8)))

## Each trunk, built as [CourseRoot] builds it: clear of the snow by
## [constant MIN_HEADROOM] everywhere over the trail, and both ends in a bank.
static func _the_trunks_are_overhead(t: TestCase, gen: GDScript, surface: HeightmapSurface,
		scene: PackedScene) -> void:
	t.begin("mountain forest/lodged trunks")
	var prefab: ObjectPrefab = load("res://resources/objects/lodged_log.tres")
	t.ok(prefab != null and prefab.mesh != null, "the lodged trunk has a mesh")
	if prefab != null:
		t.ok(not prefab.collidable and prefab.decorative and not prefab.ground_aligned,
			"it is scenery, level, not something to hit")
	var root: Node = scene.instantiate()
	for marker: Node3D in root.get_node("Objects/lodged_log").get_children():
		var p: Vector3 = marker.position
		var origin := Vector3(p.x, surface.height_at(p.x, p.z) + p.y, p.z)
		var basis := Basis.from_euler(Vector3(marker.rotation.x, marker.rotation.y,
			marker.rotation.z))
		var length: float = marker.scale.x
		var thick: float = marker.scale.y
		var headroom: float = INF
		var over_trail: int = 0
		for i: int in 101:
			var s: float = -0.5 + i / 100.0
			var at: Vector3 = origin + basis * Vector3(s * length,
				PropMesh.LOG_AXIS_Y * thick, 0.0)
			if gen.beyond_edge(at.x, at.z) <= 0.0:
				over_trail += 1
				headroom = minf(headroom, at.y - thick * 0.5 - surface.height_at(at.x, at.z))
		t.ok(over_trail > 10, "%s spans the trail (%d of 101 samples over it)"
			% [marker.name, over_trail])
		t.ok(headroom >= MIN_HEADROOM, "%s leaves %.2f m under it" % [marker.name, headroom])
		for s: float in [-0.5, 0.5]:
			var end: Vector3 = origin + basis * Vector3(s * length,
				PropMesh.LOG_AXIS_Y * thick, 0.0)
			t.ok(surface.height_at(end.x, end.z) > end.y,
				"%s's %s end is in the bank" % [marker.name, "left" if s < 0.0 else "right"])
	root.free()

## Every obstacle on the trail blocks part of it and leaves a clear line past
## it — measured on the collision cylinders the race gets, against a racer's
## own contact radius either side — on the side the trail turns toward.
static func _the_obstacles_leave_a_line(t: TestCase, gen: GDScript, scene: PackedScene) -> void:
	t.begin("mountain forest/obstacles")
	var root: Node = scene.instantiate()
	var solid: Array[Vector3] = []
	for type_name: String in ["trail_boulder", "trunk_collider"]:
		var prefab: ObjectPrefab = load("res://resources/objects/%s.tres"
			% gen.PREFAB_OF.get(type_name, type_name))
		t.ok(prefab != null and prefab.collidable, "%s is something to hit" % type_name)
		for m: Node3D in root.get_node("Objects/%s" % type_name).get_children():
			solid.push_back(Vector3(m.position.x, m.position.z, m.scale.x * 0.5))
	var collider: ObjectPrefab = load("res://resources/objects/trunk_collider.tres")
	t.ok(collider != null and collider.mesh == null, "a trunk's collider draws nothing")
	var trunks: Array[Node] = root.get_node("Objects/fallen_trunk").get_children()
	root.free()
	const RACER := 0.6
	var obstacles: Array[float] = []
	obstacles.append_array(gen.TRAIL_BOULDERS)
	obstacles.append_array(gen.FALLEN_TRUNKS)
	for d: float in obstacles:
		# Across the trail at every 0.5 m from 3 m before to 3 m after: the
		# widest run of positions a racer's contact circle fits through, and
		# which side of the middle it is on.
		var blocked: bool = false
		var worst: float = INF
		var dd: float = d - 3.0
		while dd <= d + 3.0:
			var cx: float = gen.centre_x(dd)
			var hl: float = gen.lateral_half_width(dd)
			var run: float = 0.0
			var best: float = 0.0
			var best_mid: float = 0.0
			var x: float = cx - hl
			while x <= cx + hl:
				var free: bool = true
				for o: Vector3 in solid:
					if Vector2(o.x - x, o.y + dd).length() < o.z + RACER:
						free = false
						blocked = true
						break
				run = run + 0.1 if free else 0.0
				if run > best:
					best = run
					best_mid = x - run * 0.5 - cx
				x += 0.1
			if best < worst:
				worst = best
				t.ok(signf(best_mid) == gen.open_side(d) or best >= 2.0 * hl - 0.2,
					"at %.0f m the open line is on the side the trail turns toward" % d)
			dd += 0.5
		t.ok(blocked, "the obstacle at %.0f m is in the way" % d)
		t.ok(worst >= 2.5, "and leaves %.1f m of line past it" % worst)
	t.ok(trunks.size() == gen.FALLEN_TRUNKS.size(), "a fallen trunk drawn over each row")

## The bumps are on the trail as built: at each, the trail's middle stands
## over the line from 12 m before to 8 m after by about the bump's height.
static func _the_bumps(t: TestCase, gen: GDScript, surface: HeightmapSurface) -> void:
	t.begin("mountain forest/bumps")
	for b: Vector2 in gen.BUMPS:
		var d: float = b.x
		var before: float = surface.height_at(gen.centre_x(d - 12.0), -(d - 12.0))
		var after: float = surface.height_at(gen.centre_x(d + 8.0), -(d + 8.0))
		var top: float = surface.height_at(gen.centre_x(d), -d)
		var line: float = lerpf(before, after, 12.0 / 20.0)
		t.between(top - line, b.y * 0.6, b.y * 1.6,
			"the bump at %.0f m stands %.2f m proud" % [d, top - line])

## [CourseRoot] stands an object its marker's Y above the ground, leaning by
## its X and Z rotations — the lodged trunk is the only thing that asks.
static func _a_marker_can_stand_off_the_ground(t: TestCase, course: CourseData,
		surface: HeightmapSurface) -> void:
	t.begin("mountain forest/marker lift")
	var root := CourseRoot.new()
	root.course_data = course
	root.object_prefabs = {"lodged_log": load("res://resources/objects/lodged_log.tres")}
	var objects := Node3D.new()
	objects.name = "Objects"
	root.add_child(objects)
	var group := Node3D.new()
	group.name = "lodged_log"
	objects.add_child(group)
	var marker := Marker3D.new()
	marker.position = Vector3(50.0, 4.0, -300.0)
	marker.rotation = Vector3(0.0, 0.3, 0.1)
	marker.scale = Vector3(10.0, 0.7, 0.7)
	group.add_child(marker)
	root.build_runtime()
	var xf: Transform3D = root.object_transforms["lodged_log"][0]
	t.eq_f(xf.origin.y, surface.height_at(50.0, -300.0) + 4.0, 1e-3,
		"stood 4 m above the ground")
	var along: Vector3 = xf.basis.x.normalized()
	t.eq_f(asin(along.y), 0.1, 1e-3, "leaning by its roll")
	t.eq_f(xf.basis.x.length(), 10.0, 1e-3, "as long as its X scale")
	root.free()

## The rock faces laid over the walls ([CliffSet]): out of reach of anything
## that races, under the heightmap wherever they are not standing out of it,
## under the camera's floor wherever they are, and with nothing placed on them.
static func _the_rock_faces(t: TestCase, gen: GDScript, course: CourseData,
		surface: HeightmapSurface, scene: PackedScene) -> void:
	t.begin("mountain forest/rock faces")
	var cliffs: CliffSet = course.cliffs
	t.ok(cliffs != null and not cliffs.meshes.is_empty(), "the course has rock faces")
	if cliffs == null or cliffs.meshes.is_empty():
		return
	t.ok(cliffs.grid_size == course.heightmap_size and cliffs.world_size == course.world_size,
		"their camera lift is on the heightmap's grid")
	var bounds: PackedVector2Array = course.effective_play_bounds()
	var standing: int = 0
	var buried: int = 0
	var in_play: int = 0
	var nearest_edge: float = INF
	var worst_lift: float = 0.0
	# Where the rock stands, on a 1 m grid, for the markers below.
	var rock_cells: Dictionary[Vector2i, bool] = {}
	for mesh: ArrayMesh in cliffs.meshes:
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v: Vector3 in verts:
			var ground: float = surface.height_at(v.x, v.z)
			if v.y <= ground:
				buried += 1
				continue
			standing += 1
			if Geometry2D.is_point_in_polygon(Vector2(v.x, v.z), bounds):
				in_play += 1
			nearest_edge = minf(nearest_edge, gen.beyond_edge(v.x, v.z))
			worst_lift = maxf(worst_lift, v.y - (ground + cliffs.lift_at(v.x, v.z)))
			rock_cells[Vector2i(floori(v.x), floori(v.z))] = true
	t.ok(standing > 1000 and buried > 100,
		"they stand out of the wall (%d vertices) and sink under it at the edges (%d)"
		% [standing, buried])
	# What lies wholly under the ground is left out: only the edge quads that
	# carry the rock down under it are buried, not whole strips of grid.
	t.ok(buried < standing,
		"no more buried than standing: the quads wholly under the ground are left out")
	t.ok(in_play == 0, "none of the rock is in the play area (%d vertices)" % in_play)
	t.ok(nearest_edge > gen.CORRIDOR_MARGIN + 0.5,
		"the rock keeps %.2f m off the trail's edge" % nearest_edge)
	# The lift is read off grid vertices round a point; between them the
	# heightmap itself bends, which a few centimetres covers.
	t.ok(worst_lift < 0.15,
		"the camera's floor is over the rock everywhere (worst %.3f m under it)" % worst_lift)
	_the_rock_is_lean(t, cliffs)
	_the_ground_under_the_rock_is_left_out(t, gen, course, surface, cliffs)
	var root: Node = scene.instantiate()
	var on_rock: PackedStringArray = []
	for type_name: String in ["tree", "shrub", "boulder", "stones", "log", "stump",
			"stone_pile"]:
		var group: Node = root.get_node_or_null("Objects/%s" % type_name)
		if group == null:
			continue
		for marker: Node3D in group.get_children():
			var p: Vector3 = marker.position
			if rock_cells.has(Vector2i(floori(p.x), floori(p.z))):
				on_rock.push_back(marker.name)
	root.free()
	t.ok(on_rock.is_empty(), "nothing stands on the rock: %s" % ", ".join(on_rock.slice(0, 8)))

## Each piece compressed, with simplified levels that index its own vertices.
static func _the_rock_is_lean(t: TestCase, cliffs: CliffSet) -> void:
	t.ok(cliffs.lods.size() == cliffs.meshes.size(), "every piece has its levels")
	var compressed: bool = true
	var levels_ok: bool = true
	var simpler: bool = true
	for m: int in cliffs.meshes.size():
		var mesh: ArrayMesh = cliffs.meshes[m]
		compressed = compressed and (mesh.surface_get_format(0)
			& Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0
		var count: int = mesh.surface_get_array_len(0)
		var full: int = mesh.surface_get_array_index_len(0)
		var lods: Dictionary = cliffs.lods[m] if m < cliffs.lods.size() else {}
		levels_ok = levels_ok and not lods.is_empty()
		for key: Variant in lods:
			var indices: PackedInt32Array = lods[key]
			simpler = simpler and indices.size() < full and indices.size() % 3 == 0
			for i: int in indices:
				levels_ok = levels_ok and i >= 0 and i < count
	t.ok(compressed, "every piece's attributes are compressed")
	t.ok(levels_ok, "every piece has simplified levels, indexing its own vertices")
	t.ok(simpler, "and each level has fewer triangles than the piece")

## The heightmap quads left out of the terrain under the rock: some, none in
## or beside the play area, and the rock standing over every one of them.
static func _the_ground_under_the_rock_is_left_out(t: TestCase, gen: GDScript,
		course: CourseData, surface: HeightmapSurface, cliffs: CliffSet) -> void:
	t.ok(not cliffs.holes.is_empty(), "the ground the rock hides is left out of the terrain")
	var w: int = course.heightmap_size.x
	var step := Vector2(course.world_size.x / float(w - 1),
		course.world_size.y / float(course.heightmap_size.y - 1))
	var bounds: PackedVector2Array = course.effective_play_bounds()
	var near_play: int = 0
	var bare: int = 0
	for q: int in cliffs.holes:
		var gx: int = q % w
		var gz: int = q / w
		for corner: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			var x: float = float(gx + corner.x) * step.x
			var z: float = -float(gz + corner.y) * step.y
			if Geometry2D.is_point_in_polygon(Vector2(x, z), bounds) \
					or gen.beyond_edge(x, z) < gen.CORRIDOR_MARGIN + 0.5:
				near_play += 1
			if cliffs.lift_at(x, z) < CliffBuilder.HOLE_CLEARANCE:
				bare += 1
	t.ok(near_play == 0, "no ground is left out in or beside the play area (%d corners)"
		% near_play)
	t.ok(bare == 0, "the rock stands over every quad left out (%d corners not)" % bare)
	# And the terrain does leave them out: the chunk holding the first one has
	# exactly that many quads fewer, and the rock is drawn.
	var renderer := TerrainRenderer.new()
	renderer.setup(course, surface)
	var span: int = TerrainRenderer.CHUNK_VERTS - 1
	var first: int = cliffs.holes[0]
	var key := Vector2i((first % w) / span, (first / w) / span)
	var inside: int = 0
	for q: int in cliffs.holes:
		var gx: int = q % w
		var gz: int = q / w
		if gx / span == key.x and gz / span == key.y \
				and gx < (key.x + 1) * span and gz < (key.y + 1) * span:
			inside += 1
	renderer._build_chunk(key)
	var chunk: MeshInstance3D = renderer._chunks.get(key)
	var nx: int = mini(TerrainRenderer.CHUNK_VERTS, w - key.x * span)
	var nz: int = mini(TerrainRenderer.CHUNK_VERTS, course.heightmap_size.y - key.y * span)
	var drawn: int = chunk.mesh.surface_get_array_index_len(0) / 6 \
		if chunk != null and chunk.mesh != null else -1
	t.ok(drawn == (nx - 1) * (nz - 1) - inside,
		"the chunk under the rock draws %d of its %d quads (%d left out)"
		% [drawn, (nx - 1) * (nz - 1), inside])
	t.ok(renderer.cliff_count() == cliffs.meshes.size(), "and every piece of rock is drawn")
	renderer.free()
