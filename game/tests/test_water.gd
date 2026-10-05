## Standing water ([member CourseData.water]): what the surface says about it,
## what it does to a racer, what an opponent thinks of it, how Forest Trail's
## puddles lie, and what is built to draw it.
##
## Headless, so the picture is asserted through what feeds it — the grid, the
## mesh arrays, the shader's text — never the frame.
class_name TestWater
extends RefCounted

const COURSE_DIR := "forest_trail"
const GENERATOR := "res://addons/course_gen/gen_forest_trail.gd"
## Degrees: steep enough that a racer on 0.35 friction picks up speed
## (tan 20° is 0.36, which only creeps).
const WET_SLOPE := 28.0

static func run(t: TestCase) -> void:
	_the_surface_reads_the_grid(t)
	_a_dry_course_is_dry(t)
	_the_water_slows_a_racer(t)
	_flying_over_it_costs_nothing(t)
	_an_opponent_steers_round_it(t)
	_forest_trail_has_four_puddles(t)
	_earth_under_ice_round(t)
	_nothing_stands_in_the_water(t)
	_the_water_is_built(t)
	_the_wind_raises_waves(t)
	_the_splash(t)

## A slope with a band of water [param depth] deep across it from
## [param from] to [param to] metres down, the grid signed as a course's is:
## dry vertices carry the ground's height over the water, here 5 cm.
static func _wet_slope(from: float, to: float, depth: float,
		lane: Vector2 = Vector2(-INF, INF)) -> HeightmapSurface:
	var s: HeightmapSurface = SlopeFixture.flat_slope(WET_SLOPE)
	var water := PackedFloat32Array()
	water.resize(s.size.x * s.size.y)
	var dx: float = s.world_size.x / float(s.size.x - 1)
	var dz: float = s.world_size.y / float(s.size.y - 1)
	for gy: int in s.size.y:
		for gx: int in s.size.x:
			var d: float = gy * dz
			var x: float = gx * dx
			var wet: bool = d >= from and d <= to and x >= lane.x and x <= lane.y
			water[gy * s.size.x + gx] = depth if wet else -0.05
	s.set_water(water)
	return s

static func _the_surface_reads_the_grid(t: TestCase) -> void:
	t.begin("water/the surface")
	var s: HeightmapSurface = _wet_slope(100.0, 110.0, 0.2)
	t.ok(s.has_water(), "a course with a water grid has water")
	t.eq_f(s.water_depth_at(45.0, -105.0), 0.2, 1e-5, "inside the band, its depth")
	t.eq_f(s.water_depth_at(45.0, -50.0), 0.0, 1e-9, "outside it, none — never negative")
	var sample := SurfaceSample.new()
	s.sample_into(45.0, -105.0, sample)
	t.eq_f(sample.water_depth, 0.2, 1e-5, "the physics' sample carries the same depth")
	s.sample_into(45.0, -50.0, sample)
	t.eq_f(sample.water_depth, 0.0, 1e-9, "and none on dry ground")
	# The shore is where the bilinear value crosses zero: part way across the
	# cell between a wet vertex and a dry one, the same for every reader.
	var dz: float = s.world_size.y / float(s.size.y - 1)
	var last_wet: float = floorf(110.0 / dz) * dz
	var mid: float = s.water_depth_at(45.0, -(last_wet + dz * 0.5))
	t.between(mid, 0.05, 0.1, "half a cell past the last wet vertex the water thins out (%.3f)"
		% mid)
	var wrong := PackedFloat32Array([0.1, 0.2])
	s.set_water(wrong)
	t.ok(not s.has_water(), "a grid of the wrong size is no water rather than a crash")

static func _a_dry_course_is_dry(t: TestCase) -> void:
	t.begin("water/a dry course")
	var s: HeightmapSurface = SlopeFixture.flat_slope(WET_SLOPE)
	t.ok(not s.has_water(), "no grid, no water")
	t.eq_f(s.water_depth_at(45.0, -105.0), 0.0, 1e-9, "and the depth is zero")
	for dir: String in ["bunny_hill", "mountain_forest"]:
		var course: CourseData = load("res://courses/%s/course.tres" % dir)
		if course != null:
			t.ok(course.water == null, "%s carries no water" % dir)
	# Bit for bit: the water force is zero on a dry course, so a run there is
	# exactly the run it was before water existed — the same as a run on a
	# course whose grid is wholly dry.
	var a: RacePhysics = _run(SlopeFixture.flat_slope(WET_SLOPE), 6.0)
	var b: RacePhysics = _run(_wet_slope(1000.0, 1001.0, 0.2), 6.0)
	t.ok(a.pos == b.pos and a.vel == b.vel,
		"a run that never meets water is bit-identical to one on a course without any")

static func _run(s: HeightmapSurface, seconds: float, input_name: String = "") -> RacePhysics:
	var sim := RacePhysics.new()
	sim.surface = s
	sim.init_at(45.0, -5.0)
	var src := ScriptedInputSource.new(input_name)
	var input := RaceInput.new()
	for tick: int in int(seconds * 60.0):
		src.poll(input, sim, 1.0 / 60.0)
		sim.step(input, 1.0 / 60.0)
	return sim

## Speed at [param at] metres down, riding straight down [param s].
static func _speed_at(s: HeightmapSurface, at: float) -> float:
	var sim := RacePhysics.new()
	sim.surface = s
	sim.init_at(45.0, -5.0)
	var input := RaceInput.new()
	for tick: int in 60 * 60:
		sim.step(input, 1.0 / 60.0)
		if -sim.pos.z >= at:
			return sim.vel.length()
	return -1.0

static func _the_water_slows_a_racer(t: TestCase) -> void:
	t.begin("water/drag")
	var dry: float = _speed_at(SlopeFixture.flat_slope(WET_SLOPE), 47.0)
	var wet: float = _speed_at(_wet_slope(40.0, 47.0, 0.2), 47.0)
	t.ok(dry > 8.0, "a racer reaches the water at speed (%.1f m/s)" % dry)
	var loss: float = 1.0 - wet / dry
	t.between(loss, 0.15, 0.35,
		"seven metres of puddle take a fifth to a third of the speed (%.0f %%)" % (loss * 100.0))
	var shallow: float = _speed_at(_wet_slope(40.0, 47.0, 0.03), 47.0)
	t.ok(shallow > wet and shallow < dry,
		"a shallower puddle slows less (%.1f, against %.1f and %.1f dry)" % [shallow, wet, dry])
	# And it is the water, not a change of ground: the force is along the
	# velocity, quadratic in it, zero without water.
	var sim := RacePhysics.new()
	sim.surface = _wet_slope(0.0, 500.0, 0.2)
	sim.init_at(45.0, -20.0)
	var v := Vector3(0.0, -3.0, -10.0)
	var p: Vector3 = sim.pos
	sim.calc_net_force(p, v)
	var f: Vector3 = sim.calc_water_force(p, v, v.length())
	t.ok(f.normalized().dot(-v.normalized()) > 0.999, "the drag opposes the motion")
	var f2: Vector3 = sim.calc_water_force(p, v * 2.0, v.length() * 2.0)
	t.eq_f(f2.length() / f.length(), 4.0, 1e-4, "and goes as the square of the speed")

static func _flying_over_it_costs_nothing(t: TestCase) -> void:
	t.begin("water/flying over")
	var sim := RacePhysics.new()
	sim.surface = _wet_slope(0.0, 500.0, 0.2)
	sim.init_at(45.0, -20.0)
	var v := Vector3(0.0, 0.0, -10.0)
	var above: Vector3 = sim.pos + Vector3(0.0, 0.5, 0.0)
	sim.calc_net_force(above, v)
	t.ok(sim.calc_water_force(above, v, 10.0) == Vector3.ZERO,
		"a racer half a metre over the water feels none of it")
	var skimming: Vector3 = sim.pos + Vector3(0.0, 0.15, 0.0)
	sim.calc_net_force(skimming, v)
	var part: float = sim.calc_water_force(skimming, v, 10.0).length()
	var under: Vector3 = sim.pos
	sim.calc_net_force(under, v)
	var full: float = sim.calc_water_force(under, v, 10.0).length()
	t.ok(part > 0.0 and part < full, "one skimming through its top feels some (%.0f of %.0f N)"
		% [part, full])

## Two candidate lines from the same point, one through a puddle and one beside
## it: an opponent who cares about its line scores the dry one higher.
static func _an_opponent_steers_round_it(t: TestCase) -> void:
	t.begin("water/an opponent")
	var s: HeightmapSurface = _wet_slope(55.0, 80.0, 0.2, Vector2(40.0, 50.0))
	var sim := RacePhysics.new()
	sim.surface = s
	sim.init_at(45.0, -40.0)
	var ai := AIInputSource.new(AISkill.for_level(AISkill.Level.HARD), 0, 0)
	ai.preferred_x = 45.0
	var from := Vector3(45.0, 0.0, -40.0)
	var through: float = ai._score(sim, from, 45.0, -90.0, 0.0)
	var beside: float = ai._score(sim, from, 56.0, -90.0, 0.0)
	var dry_course := RacePhysics.new()
	dry_course.surface = SlopeFixture.flat_slope(WET_SLOPE)
	var through_dry: float = ai._score(dry_course, from, 45.0, -90.0, 0.0)
	var beside_dry: float = ai._score(dry_course, from, 56.0, -90.0, 0.0)
	t.ok(through_dry > beside_dry, "on dry ground the straight line wins")
	t.ok(beside > through, "with a puddle on it, the line beside it wins (%.1f vs %.1f)"
		% [beside, through])

static func _forest_trail_has_four_puddles(t: TestCase) -> void:
	t.begin("water/forest trail's puddles")
	var gen: GDScript = load(GENERATOR)
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	if gen == null or course == null:
		t.ok(false, "the generator and the course load")
		return
	t.ok(course.water != null and course.water.get_format() == Image.FORMAT_RF,
		"the course carries a float water grid")
	var s: HeightmapSurface = HeightmapSurface.from_course(course)
	t.ok(s.has_water(), "and its surface reads it")
	if not s.has_water():
		return
	# Walk the grid row by row, splitting the wet rows into puddles where a
	# run of dry rows separates them, and measure each.
	var w: int = s.size.x
	var grid: PackedFloat32Array = s.water_grid()
	var dx: float = s.world_size.x / float(w - 1)
	var dz: float = s.world_size.y / float(s.size.y - 1)
	var puddles: Array[Dictionary] = []
	var current: Dictionary = {}
	var dry_rows: int = 0
	for gy: int in s.size.y:
		var d: float = gy * dz
		var wet: int = 0
		var on_trail: float = 0.0
		var off_trail_only: bool = true
		var lo: float = INF
		var hi: float = -INF
		for gx: int in w:
			if grid[gy * w + gx] <= 0.0:
				continue
			var x: float = gx * dx
			wet += 1
			lo = minf(lo, x)
			hi = maxf(hi, x)
			if gen.beyond_edge(x, -d) < 0.0:
				off_trail_only = false
		if wet == 0:
			dry_rows += 1
			if dry_rows > 6 and not current.is_empty():
				puddles.push_back(current)
				current = {}
			continue
		dry_rows = 0
		var cx: float = gen.centre_x(d)
		var hw: float = gen.lateral_half_width(d)
		on_trail = maxf(0.0, minf(hi, cx + hw) - maxf(lo, cx - hw)) / (2.0 * hw)
		if current.is_empty():
			current = {"from": d, "to": d, "area": 0.0, "reach": 0.0, "off": true}
		current["to"] = d
		current["area"] = float(current["area"]) + wet * dx * dz
		current["reach"] = maxf(float(current["reach"]), on_trail)
		current["off"] = bool(current["off"]) and off_trail_only
	if not current.is_empty():
		puddles.push_back(current)
	t.ok(puddles.size() == 4, "four puddles (%d)" % puddles.size())
	var trail: Array[Dictionary] = []
	var forest: Array[Dictionary] = []
	for p: Dictionary in puddles:
		(forest if bool(p["off"]) else trail).push_back(p)
	t.ok(trail.size() == 2, "two reach onto the trail (%d)" % trail.size())
	t.ok(forest.size() == 2, "two lie wholly beside it (%d)" % forest.size())
	for p: Dictionary in trail:
		t.between(float(p["reach"]), 0.3, 0.5,
			"the one at %.0f m reaches %.0f %% of the way across"
			% [float(p["from"]), float(p["reach"]) * 100.0])
	var biggest_trail: float = 0.0
	for p: Dictionary in trail:
		biggest_trail = maxf(biggest_trail, float(p["area"]))
	for p: Dictionary in forest:
		t.ok(float(p["area"]) > biggest_trail * 1.5,
			"the one beside the trail at %.0f m is the larger kind (%.0f m² against %.0f)"
			% [float(p["from"]), float(p["area"]), biggest_trail])
	# Shallow: a puddle, not a pond.
	var deepest: float = 0.0
	for v: float in grid:
		deepest = maxf(deepest, v)
	t.between(deepest, 0.1, 0.35, "the deepest water is shallow (%.2f m)" % deepest)
	# Kept off the kickers and out of the fork, where the line is the race.
	for p: Dictionary in trail:
		for k: Vector2 in gen.KICKERS:
			t.ok(absf(float(p["from"]) - k.x) > 30.0 and absf(float(p["to"]) - k.x) > 30.0,
				"the puddle at %.0f m is clear of the kicker at %.0f m" % [float(p["from"]), k.x])
		t.ok(gen.split(float(p["from"])) == 0.0 and gen.split(float(p["to"])) == 0.0,
			"the puddle at %.0f m is where the trail is one" % float(p["from"]))

## Under the water the ground is earth; round it, a rim of ice.
static func _earth_under_ice_round(t: TestCase) -> void:
	t.begin("water/earth under it, ice round it")
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	if course == null:
		t.ok(false, "the course loads")
		return
	var s: HeightmapSurface = HeightmapSurface.from_course(course)
	var grid: PackedFloat32Array = s.water_grid()
	var w: int = s.size.x
	var dx: float = s.world_size.x / float(w - 1)
	var dz: float = s.world_size.y / float(s.size.y - 1)
	var sample := SurfaceSample.new()
	var wet: int = 0
	var wet_earth: int = 0
	var rim: int = 0
	var rim_ice: int = 0
	for i: int in grid.size():
		if grid[i] <= CourseData.NO_WATER * 0.5:
			continue
		var x: float = (i % w) * dx
		@warning_ignore("integer_division")
		var z: float = -float(i / w) * dz
		s.sample_into(x, z, sample)
		var id: StringName = course.terrain_layers[sample.terrain_id].id
		if grid[i] > 0.0:
			wet += 1
			wet_earth += 1 if id == &"dirt" else 0
		elif grid[i] > -0.2 and s.water_depth_at(x + dx, z) + s.water_depth_at(x - dx, z) \
				+ s.water_depth_at(x, z + dz) + s.water_depth_at(x, z - dz) > 0.0:
			# A dry vertex beside a wet one: the shore.
			rim += 1
			rim_ice += 1 if id == &"ice1" else 0
	t.ok(wet > 500 and float(wet_earth) / wet > 0.95,
		"the ground under the water is earth (%d of %d)" % [wet_earth, wet])
	t.ok(rim > 100 and float(rim_ice) / rim > 0.9,
		"the shore round it is ice (%d of %d)" % [rim_ice, rim])

## Nothing that stands stands in a puddle, and no torch either.
static func _nothing_stands_in_the_water(t: TestCase) -> void:
	t.begin("water/nothing stands in it")
	var scene: PackedScene = load("res://courses/%s/course.tscn" % COURSE_DIR)
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	if scene == null or course == null:
		t.ok(false, "the course loads")
		return
	var s: HeightmapSurface = HeightmapSurface.from_course(course)
	var root: Node = scene.instantiate()
	var wet: PackedStringArray = []
	for group: Node in root.get_node("Objects").get_children():
		if not ["tree", "shrub", "boulder", "stones", "log", "stump"].has(String(group.name)):
			continue
		for marker: Node3D in group.get_children():
			if s.water_depth_at(marker.position.x, marker.position.z) > 0.0:
				wet.push_back("%s/%s" % [group.name, marker.name])
	root.free()
	t.ok(wet.is_empty(), "no tree, bush or prop stands in water %s" % str(wet.slice(0, 6)))
	var torches: PackedVector3Array = CourseLights.torch_positions(course, s, null, [])
	var drowned: int = 0
	for p: Vector3 in torches:
		if s.water_depth_at(p.x, p.z) > 0.0:
			drowned += 1
	t.ok(not torches.is_empty() and drowned == 0,
		"no night torch stands in a puddle (%d torches)" % torches.size())

static func _the_water_is_built(t: TestCase) -> void:
	t.begin("water/the surface is built")
	var course: CourseData = load("res://courses/%s/course.tres" % COURSE_DIR)
	if course == null:
		t.ok(false, "the course loads")
		return
	var s: HeightmapSurface = HeightmapSurface.from_course(course)
	var tree := Engine.get_main_loop() as SceneTree
	var water := WaterRenderer.new()
	tree.root.add_child(water)
	water.setup(course, s)
	t.ok(water.has_water() and water.tile_count() >= 4,
		"Forest Trail's puddles are drawn (%d tiles)" % water.tile_count())
	t.ok(water.material != null and water.material.shader != null
		and water.material.shader.resource_path == WaterRenderer.SHADER_PATH,
		"with the water shader")
	var wet_vertices: int = 0
	var lowest_depth: float = INF
	for child: Node in water.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		t.ok(mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"%s casts no shadow" % mi.name)
		var arrays: Array = mi.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var up: bool = true
		for i: int in verts.size():
			# The depth the shader reads is the grid's at that point, and the
			# surface stands that far over the ground.
			var depth: float = uvs[i].x
			lowest_depth = minf(lowest_depth, depth)
			if depth > 0.0:
				wet_vertices += 1
				var ground: float = s.height_at(verts[i].x, verts[i].z)
				if absf(verts[i].y - (ground + depth)) > 0.02:
					up = false
			up = up and normals[i].y > 0.8
		t.ok(up, "%s stands its depth over the ground, facing up" % mi.name)
	t.ok(wet_vertices > 1000, "a surface fine enough to move (%d wet vertices)" % wet_vertices)
	t.ok(lowest_depth < 0.0, "and it runs on under the bank, where the ground hides it")
	water.free()
	# A dry course builds nothing.
	var dry := WaterRenderer.new()
	tree.root.add_child(dry)
	dry.setup(course, SlopeFixture.flat_slope(WET_SLOPE))
	t.ok(not dry.has_water() and dry.tile_count() == 0, "a dry course builds no water")
	dry.free()
	# The terrain hands the water everything it hands the ice.
	var text: String = FileAccess.get_file_as_string(WaterRenderer.SHADER_PATH)
	for uniform: String in ["sky_zenith", "sky_horizon", "ice_distant_tint",
			"character_reflection", "reflection_plane_point", "ice_env_atlas",
			"ice_env_strength"]:
		t.ok(text.contains(uniform), "water.gdshader takes the terrain's %s" % uniform)
	# The ice's rule (`TestLighting`): Fresnel splits the light, it does not add
	# to it — the murk under the mirror gets what the mirror does not.
	t.ok(text.contains("(1.0 - fresnel)"), "the reflection's share comes out of the murk")

static func _the_wind_raises_waves(t: TestCase) -> void:
	t.begin("water/the wind")
	t.eq_f(WaterRenderer.wave_steepness_for(null), 0.0, 1e-9, "no wind, a mirror")
	var calm := WindField.new()
	calm.init_crosswind(WindField.Strength.NONE, 1)
	t.eq_f(WaterRenderer.wave_steepness_for(calm), 0.0, 1e-9, "a calm day, a mirror")
	var light := WindField.new()
	light.init_crosswind(WindField.Strength.LIGHT, 1)
	var strong := WindField.new()
	strong.init_crosswind(WindField.Strength.STRONG, 1)
	var l: float = WaterRenderer.wave_steepness_for(light)
	var s: float = WaterRenderer.wave_steepness_for(strong)
	t.ok(l > 0.0 and s > l, "a light wind raises less than a strong one (%.3f < %.3f)" % [l, s])
	t.ok(s <= WaterRenderer.MAX_STEEPNESS, "and never more than small waves")
	# The waves' height: steepness over wavenumber, the longest train's.
	var tallest: float = WaterRenderer.MAX_STEEPNESS * 1.31 / TAU
	t.ok(tallest < 0.02, "the tallest is under two centimetres (%.3f m)" % tallest)
	var d: Vector2 = WaterRenderer.wind_direction(strong)
	t.eq_f(d.length(), 1.0, 1e-5, "the wind's direction is a unit vector")
	t.ok(signf(d.x) == float(strong.side), "blowing across the hill from its side")

static func _the_splash(t: TestCase) -> void:
	t.begin("water/the splash")
	var img: Image = WaterSplash.make_droplet_image()
	t.ok(img.get_width() == 32 and img.has_mipmaps(), "a mipmapped droplet")
	var centre: Color = img.get_pixel(16, 16)
	t.ok(centre.r > 0.99 and centre.a > 0.8, "white, and solid in the middle")
	t.ok(img.get_pixel(0, 0).a == 0.0 and img.get_pixel(31, 16).a < 0.05,
		"and gone by its rim")
	t.ok(WaterSplash.make_droplet_image().get_data() == img.get_data(),
		"the same picture every time")
	# How deep a racer wades, from its pose alone — so a ghost splashes too.
	var s: HeightmapSurface = _wet_slope(0.0, 500.0, 0.2)
	var ground: float = s.height_at(45.0, -100.0)
	t.eq_f(WaterRenderer.wade_at(s, Vector3(45.0, ground - 0.05, -100.0)), 1.0, 1e-5,
		"a body riding on the floor wades at full depth")
	t.eq_f(WaterRenderer.wade_at(s, Vector3(45.0, ground + 1.0, -100.0)), 0.0, 1e-9,
		"one flying over it not at all")
	t.eq_f(WaterRenderer.wade_at(SlopeFixture.flat_slope(WET_SLOPE), Vector3(45.0, 0.0, -100.0)),
		0.0, 1e-9, "and nobody wades on a dry course")
