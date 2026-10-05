## The third authored course, Snow Park (`addons/course_gen/gen_snow_park.gd`):
## a terrain park down an open slope — rollers, table-tops and fun boxes, a
## banked slalom, a half-pipe, moguls and a big jump — with herring in the air
## over the jumps and a chairlift beside it all.
##
## Headless, so every check is on what the race is handed — the heightmap as
## [HeightmapSurface] reads it, the markers, the course's fields, one run of
## the simulation — never on the frame.
class_name TestSnowPark
extends RefCounted

const COURSE_DIR := "snow_park"
const GENERATOR := "res://addons/course_gen/gen_snow_park.gd"
const DT := 1.0 / 60.0
## The park's prefabs, each a [PropMesh] kind of its own.
const FURNITURE: Array[String] = ["snowman", "igloo", "lift_tower", "lift_cable", "lift_chair",
	"lift_station"]

static func run(t: TestCase) -> void:
	var gen: GDScript = load(GENERATOR)
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	var scene: PackedScene = load("res://courses/%s/course.tscn" % COURSE_DIR)
	t.begin("snow park/loads")
	t.ok(gen != null and course != null and scene != null,
		"the generator, the course and its scene load")
	if gen == null or course == null or scene == null:
		return
	var surface: HeightmapSurface = HeightmapSurface.from_course(course)
	_the_course_is_listed(t, course)
	_the_big_jump(t, gen, surface)
	_the_rollers(t, gen, surface)
	_the_table_tops(t, gen, surface)
	_the_boxes(t, gen, course, surface)
	_the_berms(t, gen, surface)
	_the_half_pipe(t, gen, surface)
	_the_moguls(t, gen, surface)
	var root: CourseRoot = scene.instantiate()
	root.build_runtime()
	_the_furniture(t)
	_the_markers(t, gen, course, root)
	_herring_in_the_air(t, gen, root)
	_the_lift(t, root)
	_a_race_down_it(t, course, root)
	root.free()

static func _the_course_is_listed(t: TestCase, course: CourseData) -> void:
	t.begin("snow park/catalog")
	var listing: CourseListing = CourseCatalog.load_default().find(COURSE_DIR)
	t.ok(listing != null, "Snow Park is in the course catalog")
	if listing == null:
		return
	t.ok(listing.category() == CourseListing.Category.PENGUINRACER,
		"listed under this project's own courses")
	t.ok(ResourceLoader.exists(listing.preview_path), "it has a preview")
	t.ok(course.imported_from.is_empty(), "it is authored, so the importer never rewrites it")
	t.ok(not course.trail_bounds.is_empty(), "it names its run, narrower than the play area")
	# A torch stands per 22 m of the run's edge, so its pieces must be that long.
	var lit: int = CourseLights.torch_positions(course, HeightmapSurface.from_course(course),
		null, []).size()
	t.ok(lit > 100, "its edges are lit at night (%d torches)" % lit)
	for layer: TerrainLayer in course.terrain_layers:
		t.ok(layer != null and layer.resource_path.begins_with("res://resources/terrain/"),
			"its layers are ETR's own (%s)" % (layer.id if layer != null else &"<null>"))

## The angle down the run's middle over [param span] metres either side of
## [param d], on the heightmap the race reads.
static func _angle(gen: GDScript, surface: HeightmapSurface, d: float, span: float) -> float:
	var a: float = surface.height_at(gen.centre_x(d - span), -(d - span))
	var b: float = surface.height_at(gen.centre_x(d + span), -(d + span))
	return rad_to_deg(atan((a - b) / (2.0 * span)))

## The fall line never climbs, and the big jump is a take-off table, a sharp
## lip and a landing hill steeper than anything else on the course.
static func _the_big_jump(t: TestCase, gen: GDScript, surface: HeightmapSurface) -> void:
	t.begin("snow park/big jump")
	var climbs: int = 0
	var d: float = 0.0
	while d < gen.WORLD.y:
		climbs += 1 if gen.gradient(d) <= 0.0 else 0
		d += 1.0
	t.ok(climbs == 0, "the fall line never climbs (%d metres)" % climbs)
	var lip: float = gen.BIG_LIP
	t.between(_angle(gen, surface, lip - 5.0, 1.5), 10.0, 14.0, "a take-off table of ~12°")
	t.between(_angle(gen, surface, lip + 30.0, 5.0), 35.0, 39.0, "a landing hill of ~37°")
	t.ok(_angle(gen, surface, lip + 4.0, 1.5) - _angle(gen, surface, lip - 4.0, 1.5) > 18.0,
		"the lip turns over within a few metres, so a racer leaves the ground there")
	t.between(_angle(gen, surface, gen.BIG_LANDING_END + 40.0, 5.0), 9.0, 16.0,
		"and the landing bends out into the outrun")
	t.between(gen.base_angle(), 18.0, 24.0, "the base slope is the sections' mean (%.2f°)"
		% gen.base_angle())

## Each roller's crest stands about its height over the troughs either side.
static func _the_rollers(t: TestCase, gen: GDScript, surface: HeightmapSurface) -> void:
	t.begin("snow park/rollers")
	var wave: float = gen.ROLLERS.y
	for d: float in gen.roller_crests():
		var x: float = gen.centre_x(d)
		var crest: float = surface.height_at(x, -d)
		var trough: float = (surface.height_at(gen.centre_x(d - wave * 0.5), -(d - wave * 0.5))
			+ surface.height_at(gen.centre_x(d + wave * 0.5), -(d + wave * 0.5))) * 0.5
		t.between(crest - trough, gen.ROLLER_HEIGHT * 0.8, gen.ROLLER_HEIGHT * 1.2,
			"the roller at %.0f m stands %.2f m proud" % [d, crest - trough])

## Measured across the slope at [param d]: the height at [param a] off the
## middle over the height at [param b] off it.
static func _rise(gen: GDScript, surface: HeightmapSurface, d: float, a: float,
		b: float) -> float:
	var cx: float = gen.centre_x(d)
	return surface.height_at(cx + a, -d) - surface.height_at(cx + b, -d)

## Each table stands its height over the chicken line beside it from lip to
## landing, and its lip kicks up over the slope.
static func _the_table_tops(t: TestCase, gen: GDScript, surface: HeightmapSurface) -> void:
	t.begin("snow park/table-tops")
	var line: float = (gen.TABLE_SPAN.x + gen.TABLE_SPAN.y) * 0.5
	for table: Vector2 in gen.TABLES:
		var top: float = gen.table_top_length(table)
		t.between(_rise(gen, surface, table.x + top * 0.5, line, 4.5), table.y * 0.85,
			table.y * 1.15, "the table at %.0f m stands %.1f m over the chicken line"
			% [table.x, table.y])
		var foot: float = gen.table_extent(table).x
		t.ok(absf(_rise(gen, surface, foot - 2.0, line, 4.5)) < 0.4,
			"and nothing of it before its ramp at %.0f m" % foot)
		# The ramp's last metre, against the slope: the kick.
		var kick: float = rad_to_deg(atan(gen.table_profile(table.x, table)
			- gen.table_profile(table.x - 1.0, table)))
		t.between(kick, 18.0, 30.0, "its lip kicks %.0f° over the slope" % kick)

## The boxes stand on the chicken line, glazed on top.
static func _the_boxes(t: TestCase, gen: GDScript, course: CourseData,
		surface: HeightmapSurface) -> void:
	t.begin("snow park/boxes")
	var splat: Image = course.splat_maps[0].get_image()
	for box: Vector3 in gen.BOXES:
		var d: float = box.x + box.y * 0.5
		t.between(_rise(gen, surface, d, box.z, box.z + 4.0), gen.BOX_HEIGHT * 0.8,
			gen.BOX_HEIGHT * 1.2, "the box at %.0f m stands %.1f m" % [box.x, gen.BOX_HEIGHT])
		var x: float = gen.centre_x(d) + box.z
		var px: int = roundi(x / course.world_size.x * (splat.get_width() - 1))
		var py: int = roundi(d / course.world_size.y * (splat.get_height() - 1))
		t.ok(splat.get_pixel(px, py)[gen.L_BOX] > 0.5, "its top is ice")
		var layer: TerrainLayer = course.terrain_layers[gen.L_BOX]
		t.ok(layer.is_ice(), "the box's top slides like ice")

## At every apex of the slalom the outside edge stands well over the inside
## one, and the run has no straight line through the bends.
static func _the_berms(t: TestCase, gen: GDScript, surface: HeightmapSurface) -> void:
	t.begin("snow park/berms")
	var apexes: Array[float] = gen.apexes()
	t.ok(apexes.size() >= 4, "%d turns" % apexes.size())
	for d: float in apexes:
		var outside: float = -signf(gen.bend(d))
		var hl: float = gen.lateral_half_width(d)
		var bank: float = _rise(gen, surface, d, outside * hl * 0.95, -outside * hl * 0.5)
		t.ok(bank > gen.BERM_HEIGHT * 0.7, "the turn at %.0f m banks %.1f m up its outside"
			% [d, bank])
	var lo: float = INF
	var hi: float = -INF
	var d_s: float = gen.SLALOM.x
	while d_s <= gen.SLALOM.y:
		lo = minf(lo, gen.centre_x(d_s) + gen.lateral_half_width(d_s))
		hi = maxf(hi, gen.centre_x(d_s) - gen.lateral_half_width(d_s))
		d_s += 1.0
	t.ok(hi > lo, "no straight line runs through the slalom (%.1f m apart)" % (hi - lo))

## Down the half-pipe's middle the floor is flat and both walls stand to the
## coping; at either end they are gone.
static func _the_half_pipe(t: TestCase, gen: GDScript, surface: HeightmapSurface) -> void:
	t.begin("snow park/half-pipe")
	var coping: float = gen.pipe_coping()
	var full: float = gen.pipe_height()
	t.between(full, 4.0, 5.0, "the walls stand %.1f m" % full)
	var low: PackedStringArray = []
	var d: float = gen.PIPE.x + gen.PIPE_RISE + 2.0
	while d < gen.PIPE.y - gen.PIPE_FALL - 2.0:
		var floor_tilt: float = absf(_rise(gen, surface, d, -gen.PIPE_FLOOR + 0.5,
			gen.PIPE_FLOOR - 0.5))
		for side: float in [-1.0, 1.0]:
			var wall: float = _rise(gen, surface, d, side * (coping - 0.1), 0.0)
			if wall < full * 0.85 or floor_tilt > 0.2:
				low.push_back("%.0f m" % d)
		d += 5.0
	t.ok(low.is_empty(), "the walls stand to the coping all the way down: %s"
		% ", ".join(low.slice(0, 6)))
	t.ok(absf(_rise(gen, surface, gen.PIPE.x - 5.0, coping, 0.0)) < 0.8,
		"and they rise out of the run, not out of nowhere")

static func _the_moguls(t: TestCase, gen: GDScript, surface: HeightmapSurface) -> void:
	t.begin("snow park/moguls")
	var lo: float = INF
	var hi: float = -INF
	var d: float = gen.MOGULS.x + 20.0
	while d < gen.MOGULS.y - 20.0:
		var r: float = _rise(gen, surface, d, -3.0, 0.0)
		lo = minf(lo, r)
		hi = maxf(hi, r)
		d += 0.5
	t.ok(hi - lo > gen.MOGUL_HEIGHT * 0.8, "the field is bumpy across (%.2f m)" % (hi - lo))

## The furniture's prefabs: drawn from [PropMesh], lit like every prop, and the
## lift's parts not solid — a solid object is turned by a hashed yaw
## ([method CourseRoot.decorrelating_yaw]), which would twist a tower off its
## cable.
static func _the_furniture(t: TestCase) -> void:
	t.begin("snow park/furniture")
	for id: String in FURNITURE:
		var p: ObjectPrefab = load("res://resources/objects/%s.tres" % id)
		t.ok(p != null and p.mesh != null, "%s has a mesh" % id)
		if p == null:
			continue
		var mat: ShaderMaterial = p.material as ShaderMaterial
		t.ok(mat != null and mat.shader != null
			and mat.shader.resource_path == "res://shaders/object_prop.gdshader",
			"%s is drawn with object_prop.gdshader" % id)
		if id.begins_with("lift_"):
			t.ok(not p.collidable and not p.ground_aligned, "%s is not turned or tilted" % id)

## Nothing solid within reach of the play area, the herring on the run or over
## it, a flag at every turn, and everything else outside the play area.
static func _the_markers(t: TestCase, gen: GDScript, course: CourseData,
		root: CourseRoot) -> void:
	t.begin("snow park/markers")
	var play: PackedVector2Array = course.effective_play_bounds()
	var trail: PackedVector2Array = course.effective_trail_bounds()
	var counts: Dictionary[String, int] = {}
	var misplaced: PackedStringArray = []
	for type_name: String in root.object_transforms:
		var prefab: ObjectPrefab = root.object_prefabs.get(type_name, null)
		var list: Array = root.object_transforms[type_name]
		counts[type_name] = list.size()
		for xf: Transform3D in list:
			var at := Vector2(xf.origin.x, xf.origin.z)
			match type_name:
				"herring":
					if not Geometry2D.is_point_in_polygon(at, trail):
						misplaced.push_back("herring at %.0f m" % -at.y)
				"start", "finish", "flag":
					pass
				_:
					var reach: float = (xf.basis.x.length() * 0.5 + 1.0) \
						if prefab != null and prefab.collidable else 0.0
					if CourseGenKit.near_polygon(at, play, reach) and type_name != "lift_cable":
						misplaced.push_back("%s at %.0f m" % [type_name, -at.y])
	for type_name: String in ["tree", "shrub", "boulder", "snowman", "igloo", "herring",
			"flag", "lift_tower", "lift_cable", "lift_chair", "lift_station"]:
		t.ok(counts.get(type_name, 0) > 0, "the course has %s (%d)"
			% [type_name, counts.get(type_name, 0)])
	t.ok(misplaced.is_empty(), "every marker where it belongs: %s"
		% ", ".join(misplaced.slice(0, 8)))
	t.eq_f(float(counts.get("lift_station", 0)), 2.0, 0.0, "a station at either end")
	var flags: Array = root.object_transforms.get("flag", [])
	for d: float in gen.apexes():
		var near: bool = false
		for xf: Transform3D in flags:
			near = near or absf(-xf.origin.z - d) < 1.0
		t.ok(near, "a gate flag at the turn at %.0f m" % d)

## Over every table-top and the big jump, herring hang in the air on the way
## down the flight, their middles (half a herring over the marker) more than
## the 1.2 m a racer reaches ([method RacePhysics._check_item_collection]) off
## the ground: only a racer in the air takes one.
static func _herring_in_the_air(t: TestCase, gen: GDScript, root: CourseRoot) -> void:
	t.begin("snow park/herring in the air")
	var lips: Array[float] = []
	for table: Vector2 in gen.TABLES:
		lips.push_back(table.x)
	lips.push_back(gen.BIG_LIP)
	for lip: float in lips:
		var high: int = 0
		for xf: Transform3D in root.object_transforms["herring"]:
			var d: float = -xf.origin.z
			var up: float = xf.origin.y + xf.basis.y.length() * 0.5 \
				- root.surface.height_at(xf.origin.x, xf.origin.z)
			if d > lip and d < lip + 40.0 and up > 1.3:
				high += 1
		t.ok(high >= 3, "%d herring in the air past the lip at %.0f m" % [high, lip])

## Each cable span runs from tower to tower (or a station's wheel) and clears
## the ground all along; each chair hangs from a cable.
static func _the_lift(t: TestCase, root: CourseRoot) -> void:
	t.begin("snow park/lift")
	var surface: HeightmapSurface = root.surface
	var ends := PackedVector3Array()
	var least: float = INF
	for xf: Transform3D in root.object_transforms["lift_cable"]:
		var half: Vector3 = xf.basis.x * 0.5
		ends.push_back(xf.origin - half)
		ends.push_back(xf.origin + half)
		for i: int in range(1, 20):
			var at: Vector3 = xf.origin - half + xf.basis.x * (i / 20.0)
			least = minf(least, at.y - surface.height_at(at.x, at.z))
	t.ok(least > 4.0, "the cable clears the ground by %.1f m at least" % least)
	var loose: int = 0
	for e: Vector3 in ends:
		var joined: int = 0
		for f: Vector3 in ends:
			joined += 1 if e.distance_to(f) < 0.05 else 0
		loose += 1 if joined < 2 else 0
	# Four ends are loose: each line's at the two stations' wheels.
	t.eq_f(float(loose), 4.0, 0.0, "the spans join end to end, but at the wheels")
	var tops := PackedVector3Array()
	for xf: Transform3D in root.object_transforms["lift_tower"]:
		tops.push_back(xf.origin + Vector3(0.0, xf.basis.y.length() * PropMesh.TOWER_CABLE_SHARE,
			0.0))
	var unsupported: int = 0
	for e: Vector3 in ends:
		var best: float = INF
		for top: Vector3 in tops:
			best = minf(best, Vector2(e.x - top.x, e.z - top.z).length()
				+ absf(e.y - top.y))
		unsupported += 1 if best > PropMesh.LIFT_LINE_OFFSET + 0.1 else 0
	t.eq_f(float(unsupported), 4.0, 0.0, "every other end is on a tower")
	var hanging: int = 0
	var chairs: Array = root.object_transforms["lift_chair"]
	for xf: Transform3D in chairs:
		var grip: Vector3 = xf.origin + Vector3(0.0, PropMesh.CHAIR_HANG, 0.0)
		for c: Transform3D in root.object_transforms["lift_cable"]:
			var a: Vector3 = c.origin - c.basis.x * 0.5
			var b: Vector3 = c.origin + c.basis.x * 0.5
			if Geometry3D.get_closest_point_to_segment(grip, a, b).distance_to(grip) < 0.05:
				hanging += 1
				break
	t.ok(chairs.size() > 50 and hanging == chairs.size(),
		"every chair hangs from a cable (%d of %d)" % [hanging, chairs.size()])

## The hard computer opponent, through the course's own grids and the run it is
## held to, gets down without hitting anything, flies the big jump and catches
## herring.
static func _a_race_down_it(t: TestCase, course: CourseData, root: CourseRoot) -> void:
	t.begin("snow park/a race down it")
	var source := AIInputSource.new(AISkill.for_level(AISkill.Level.HARD), 0, 0)
	var sim := RacePhysics.new()
	sim.surface = root.surface
	sim.trees = root.trees
	sim.items = root.items
	sim.bounds_polygon = RaceSetup.bounds_for(source, course)
	sim.play_length = course.play_size.y
	sim.finish_brake = course.finish_brake
	var hits: Array[int] = [0]
	var herring: Array[int] = [0]
	sim.tree_hit.connect(func(_p: Vector3) -> void: hits[0] += 1)
	sim.item_collected.connect(func(_i: int) -> void: herring[0] += 1)
	# The race's snow mirror, as the probe attaches it: packed snow is faster.
	var snow: SnowField = load("res://tests/probe_course.gd").attach_snow(sim)
	sim.init_at(course.start_position.x, -course.start_position.y)
	var input := RaceInput.new()
	var longest: float = 0.0
	var took_off: float = 0.0
	var flying: bool = false
	for i: int in int(150.0 / DT):
		source.poll(input, sim, DT)
		sim.step(input, DT)
		snow.recenter(sim.pos.x, sim.pos.z)
		snow.decay(DT)
		if sim.airborne and not flying:
			took_off = -sim.pos.z
		elif not sim.airborne and flying:
			longest = maxf(longest, -sim.pos.z - took_off)
		flying = sim.airborne
		if sim.finished:
			break
	sim.items.reset_collectables()
	(root.surface as HeightmapSurface).snow_field = null
	t.ok(sim.finished, "it finishes inside 150 s (%.1f s, %.0f m down)" % [sim.time, -sim.pos.z])
	t.ok(hits[0] == 0, "without hitting anything (%d)" % hits[0])
	t.ok(longest > 30.0, "its longest flight is %.0f m" % longest)
	t.ok(herring[0] >= 5, "and it catches herring (%d)" % herring[0])
