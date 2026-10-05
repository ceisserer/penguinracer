## Not a test: one racer down a real course, headless, logging what a course
## designer needs to place a feature — speed by distance, every flight (where
## it left the ground, where it came down, how high it flew), every herring
## taken, every tree hit, and the time. The computer's driver (`--driver=easy
## | medium | hard`) or no hands at all (`straight`), through the course's own
## grids and the bounds a race hands that driver ([method RaceSetup.bounds_for]).
##
##     tools/probe_course.sh --course=snow_park --driver=hard
##
## Ticked exactly as [method RaceScene._simulation_tick] does, at 60 Hz, on
## the race's snow mirror ([method attach_snow]): packed snow and the trench
## change the friction, and a run without them is another run.
extends SceneTree

const DT := 1.0 / 60.0

func _initialize() -> void:
	var course_dir: String = "snow_park"
	var driver: String = "hard"
	var seconds: float = 240.0
	var every: float = 25.0
	var follow: float = NAN
	var span := Vector2(-INF, INF)
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--course="):
			course_dir = a.trim_prefix("--course=")
		elif a.begins_with("--driver="):
			driver = a.trim_prefix("--driver=")
		elif a.begins_with("--seconds="):
			seconds = float(a.trim_prefix("--seconds="))
		elif a.begins_with("--every="):
			every = float(a.trim_prefix("--every="))
		elif a.begins_with("--follow="):
			follow = float(a.trim_prefix("--follow="))
			driver = "follow"
		elif a.begins_with("--from="):
			span.x = float(a.trim_prefix("--from="))
		elif a.begins_with("--to="):
			span.y = float(a.trim_prefix("--to="))
	var course: CourseData = load("res://courses/%s/course.tres" % course_dir)
	var scene: PackedScene = load("res://courses/%s/course.tscn" % course_dir)
	if course == null or scene == null:
		printerr("no course '%s'" % course_dir)
		quit(2)
		return
	var root: CourseRoot = scene.instantiate()
	root.build_runtime()

	var source: InputSource = null
	match driver:
		"easy":
			source = AIInputSource.new(AISkill.for_level(AISkill.Level.EASY), 0, 0)
		"medium":
			source = AIInputSource.new(AISkill.for_level(AISkill.Level.MEDIUM), 0, 0)
		"hard":
			source = AIInputSource.new(AISkill.for_level(AISkill.Level.HARD), 0, 0)
	var gen: GDScript = null
	if not is_nan(follow):
		gen = load("res://addons/course_gen/gen_%s.gd" % course_dir)
	var sim := RacePhysics.new()
	sim.surface = root.surface
	sim.trees = root.trees
	sim.items = root.items
	sim.bounds_polygon = RaceSetup.bounds_for(source, course) if source != null \
		else course.effective_play_bounds()
	sim.play_length = course.play_size.y
	sim.finish_brake = course.finish_brake
	var herring: Array[int] = [0]
	var hits: Array[int] = [0]
	sim.item_collected.connect(func(i: int) -> void:
		herring[0] += 1
		var p: Vector3 = sim.items.positions[i]
		print("  herring at %.0f m, %.1f m up" % [-p.z, p.y - root.surface.height_at(p.x, p.z)]))
	sim.tree_hit.connect(func(p: Vector3) -> void:
		hits[0] += 1
		print("  HIT at %.0f m (x %.1f)" % [-p.z, p.x]))
	var snow: SnowField = attach_snow(sim)
	sim.init_at(course.start_position.x, -course.start_position.y)

	print("%s, driver %s%s" % [course_dir, driver, "" if gen == null else " %.2f" % follow])
	var input := RaceInput.new()
	var next_log: float = every
	var flying: bool = false
	var took_off := Vector3.ZERO
	var take_off_speed: float = 0.0
	var peak: float = 0.0
	var finish_time: float = -1.0
	var slowest: float = INF
	for i: int in int(seconds / DT):
		if source != null:
			source.poll(input, sim, DT)
		elif gen != null:
			var ahead: float = -sim.pos.z + 12.0
			_hold_line(input, sim, gen.centre_x(ahead)
				+ (follow if ahead >= span.x and ahead <= span.y else 0.0))
		sim.step(input, DT)
		snow.recenter(sim.pos.x, sim.pos.z)
		snow.decay(DT)
		var d: float = -sim.pos.z
		var ground: float = root.surface.height_at(sim.pos.x, sim.pos.z)
		var above: float = sim.pos.y - ground
		if sim.airborne and not flying:
			flying = true
			took_off = sim.pos
			take_off_speed = sim.vel.length()
			peak = above
		elif sim.airborne:
			peak = maxf(peak, above)
		elif flying:
			flying = false
			var length: float = -sim.pos.z + took_off.z
			if length > 2.0:
				print("  flight %.1f..%.1f m (%.1f m), off at %.1f m/s, %.2f m up at most"
					% [-took_off.z, d, length, take_off_speed, peak])
		if d >= next_log:
			print("%6.0f m  %5.1f m/s  x %6.1f  t %6.2f s" % [d, sim.vel.length(), sim.pos.x,
				sim.time])
			next_log += every
		if d > 30.0 and not sim.finished:
			slowest = minf(slowest, sim.vel.length())
		if sim.finished and finish_time < 0.0:
			finish_time = sim.time
			print("finished in %.2f s" % finish_time)
			break
	if finish_time < 0.0:
		print("NOT finished: %.0f m down after %.0f s" % [-sim.pos.z, seconds])
	print("herring %d of %d, %d hits, slowest %.1f m/s" % [herring[0], sim.items.size(), hits[0],
		slowest])
	root.free()
	quit(0)

## Give [param sim]'s surface the CPU snow mirror a race gives it, stamped
## from every substep as [method SimulatedRacer._on_substep] stamps it. The
## caller recentres and decays it after each tick, as [RaceScene] does.
static func attach_snow(sim: RacePhysics) -> SnowField:
	var field := SnowField.new()
	var surface: HeightmapSurface = sim.surface
	surface.snow_field = field
	var sample := SurfaceSample.new()
	sim.substep_advanced.connect(func(h: float, pos: Vector3, speed: float) -> void:
		if sim.airborne:
			return
		surface.sample_into(pos.x, pos.z, sample)
		if not sample.takes_trackmarks or sample.water_depth > 0.0:
			return
		var sink: float = clampf(sample.height - pos.y, 0.0, sample.compression_depth * 2.0)
		var amount: float = maxf(sink, 0.01) * minf(1.0, speed / 6.0)
		field.stamp(pos.x, pos.z, PhysConst.TUX_WIDTH * 0.5, amount * h * 20.0))
	return field

## Steer for a point 12 m ahead at [param x]: the computer's steering law
## ([method AIInputSource.stick_for]) without its planning, paddling as the hard one does.
static func _hold_line(input: RaceInput, sim: RacePhysics, x: float) -> void:
	var heading := Vector2(sim.vel.x, sim.vel.z)
	if heading.length_squared() < 0.25:
		heading = Vector2(0.0, -1.0)
	var err: float = heading.angle_to(Vector2(x - sim.pos.x, -12.0))
	input.paddling = not sim.airborne and sim.vel.length() < PhysConst.MAX_PADDLING_SPEED
	input.stick_turn = 0.0 if absf(err) < 0.03 \
		else signf(err) * lerpf(AIInputSource.MIN_EFFECTIVE_STICK, 1.0, clampf(absf(err) / 0.35, 0.0, 1.0))
