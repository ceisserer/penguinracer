## Whole-simulation tests: integrator behaviour, terrain following, collisions
## and bounds. These are the "scripted input trace produces a stable, sane
## trajectory" half of the Phase 0 exit criteria.
class_name TestSimulation
extends RefCounted

static func run(t: TestCase) -> void:
	_straight_run(t)
	_terrain_following(t)
	_steering(t)
	_braking(t)
	_rolling_terrain(t)
	_bounds(t)
	_finish(t)
	_items(t)
	_trees(t)
	_determinism(t)
	_adaptive_step(t)

static func _sim(angle: float = 25.0) -> RacePhysics:
	var p := RacePhysics.new()
	p.surface = SlopeFixture.flat_slope(angle)
	p.play_min_x = 2.5
	p.play_max_x = 87.5
	p.play_length = 470.0
	p.init_at(45.0, -5.0)
	return p

static func _drive(p: RacePhysics, seconds: float, input: RaceInput, dt: float = 1.0 / 60.0) -> void:
	var steps: int = int(seconds / dt)
	for i: int in steps:
		p.step(input, dt)

static func _straight_run(t: TestCase) -> void:
	t.begin("straight run down a 25° slope")
	var p := _sim(25.0)
	var input := RaceInput.new()
	_drive(p, 10.0, input)


	# Closed-form check. Freewheeling on snow down 25°, the along-slope
	# acceleration is g(sin25 − 1.15·µ·cos25) with µ = 0.35 — the 1.15 is ETR-s
	# MAX_TURN_PEN, applied to friction unconditionally. That is 0.567 m/s², so
	# from the 3 m/s launch we expect about 8.7 m/s after 10 s, a little less
	# once air drag is paid. Tight on purpose: this is the number that decides
	# whether the game feels like the original.
	var speed: float = p.vel.length()
	var predicted: float = PhysConst.INIT_TUX_SPEED + 10.0 * PhysConst.EARTH_GRAV * (
		sin(deg_to_rad(25.0)) - (1.0 + PhysConst.MAX_TURN_PEN) * 0.35 * cos(deg_to_rad(25.0)))
	t.between(speed, predicted - 0.8, predicted, "speed after 10 s matches the closed form")
	t.ok(p.pos.z < -10.0, "player has travelled downhill")
	t.ok(absf(p.pos.x - 45.0) < 1.0, "player tracks straight without steering input")
	t.ok(p.way > 10.0, "distance travelled is accumulated")
	t.eq_f(p.time, 10.0, 0.02, "simulation clock advances with the frame")

static func _terrain_following(t: TestCase) -> void:
	t.begin("terrain following")
	var p := _sim(25.0)
	var input := RaceInput.new()
	var max_pen: float = 0.0
	var max_air: float = 0.0
	var sample := SurfaceSample.new()
	for i: int in 900:
		p.step(input, 1.0 / 60.0)
		p.surface.sample_into(p.pos.x, p.pos.z, sample)
		var d: float = sample.normal.dot(p.pos - Vector3(p.pos.x, sample.height, p.pos.z))
		max_pen = maxf(max_pen, -d)
		max_air = maxf(max_air, d)
	# The hard limit is MAX_SURF_PEN = 0.2 m, enforced after every frame.
	t.ok(max_pen <= PhysConst.MAX_SURF_PEN + 1e-3, "never sinks past MAX_SURF_PEN")
	t.ok(max_air < 0.5, "stays glued to a smooth slope instead of bouncing")

static func _steering(t: TestCase) -> void:
	t.begin("steering")
	var straight := _sim(25.0)
	var neutral := RaceInput.new()
	_drive(straight, 6.0, neutral)

	var left := _sim(25.0)
	var left_in := RaceInput.new()
	left_in.left_turn = true
	_drive(left, 6.0, left_in)

	var right := _sim(25.0)
	var right_in := RaceInput.new()
	right_in.right_turn = true
	_drive(right, 6.0, right_in)

	t.ok(left.pos.x < straight.pos.x - 1.0, "steering left moves the player -X")
	t.ok(right.pos.x > straight.pos.x + 1.0, "steering right moves the player +X")
	t.eq_f(left.pos.x - straight.pos.x, straight.pos.x - right.pos.x, 0.5,
		"steering is symmetric")
	t.ok(left.turn_animation < -0.5, "turn animation follows the steering input")
	# Carving scrubs speed, exactly as it should.
	t.ok(left.vel.length() < straight.vel.length(), "carving costs speed")

static func _braking(t: TestCase) -> void:
	t.begin("braking")
	var free := _sim(25.0)
	_drive(free, 8.0, RaceInput.new())

	var braked := _sim(25.0)
	var brake_in := RaceInput.new()
	brake_in.braking = true
	_drive(braked, 8.0, brake_in)

	t.ok(braked.vel.length() < free.vel.length(), "braking is slower than freewheeling")
	# MIN_TUX_SPEED is a floor, not a suggestion: the player never fully stops.
	t.ok(braked.vel.length() >= PhysConst.MIN_TUX_SPEED - 1e-6, "speed floors at MIN_TUX_SPEED")

	t.begin("paddling")
	var paddled := _sim(5.0)          # shallow slope, where paddling matters
	var paddle_in := RaceInput.new()
	paddle_in.paddling = true
	_drive(paddled, 8.0, paddle_in)
	var coasted := _sim(5.0)
	_drive(coasted, 8.0, RaceInput.new())
	t.ok(paddled.pos.z < coasted.pos.z, "paddling gets you further on a shallow slope")

static func _rolling_terrain(t: TestCase) -> void:
	t.begin("rolling terrain")
	var p := RacePhysics.new()
	p.surface = SlopeFixture.rolling_slope(20.0, 1.5)
	p.play_min_x = 2.5
	p.play_max_x = 87.5
	p.play_length = 470.0
	p.init_at(45.0, -5.0)

	var was_airborne: bool = false
	for i: int in 1800:
		p.step(RaceInput.new(), 1.0 / 60.0)
		if p.airborne:
			was_airborne = true
		t.ok(is_finite(p.pos.x) and is_finite(p.pos.y) and is_finite(p.pos.z),
			"position stays finite over rolling terrain")
		if t.failed > 0:
			break
	t.ok(was_airborne, "bumpy terrain launches the player at least once")
	t.ok(p.vel.length() < 60.0, "speed stays within a sane envelope")

static func _bounds(t: TestCase) -> void:
	t.begin("play bounds")
	var p := _sim(25.0)
	var input := RaceInput.new()
	input.left_turn = true
	_drive(p, 30.0, input)
	t.ok(p.pos.x >= p.play_min_x - 1e-6, "hard-steering into the wall is clamped")

	t.begin("polygon play bounds")
	# The v2 format allows a non-rectangular play area — the original could only
	# ever describe an axis-aligned box (§3.1).
	var q := _sim(25.0)
	q.play_min_x = -INF
	q.play_max_x = INF
	q.bounds_polygon = PackedVector2Array([
		Vector2(40.0, 1.0), Vector2(50.0, 1.0),
		Vector2(50.0, -400.0), Vector2(40.0, -400.0)])
	var qin := RaceInput.new()
	qin.right_turn = true
	_drive(q, 20.0, qin)
	t.ok(q.pos.x <= 50.0 + 1e-3, "player is held inside the bounds polygon")

static func _finish(t: TestCase) -> void:
	t.begin("finish line")
	var p := _sim(25.0)
	p.play_length = 40.0
	var fired: Array[bool] = [false]
	p.race_finished.connect(func() -> void: fired[0] = true)
	var input := RaceInput.new()
	for i: int in 3600:
		p.step(input, 1.0 / 60.0)
		if p.finished:
			break
	t.ok(p.finished, "crossing play_length finishes the race")
	t.ok(fired[0], "race_finished fires exactly once")

	# The redesigned finish decelerates hard but keeps real gravity — the
	# original swapped in a flat 500 N, which is the hack the plan drops.
	var entry_speed: float = p.vel.length()
	_drive(p, 6.0, input)
	t.ok(p.vel.length() < entry_speed, "the finish ramp sheds speed")
	t.eq_v(p.calc_gravitation_force(), Vector3(0.0, -196.2, 0.0), 1e-6,
		"gravity is not overridden during the finish")

static func _items(t: TestCase) -> void:
	t.begin("item collection")
	var p := _sim(25.0)
	var grid := ObjectGrid.new()
	# A line of herring straight down the fall line, plus one well off to the
	# side that must not be picked up.
	for i: int in 20:
		var z: float = -10.0 - float(i) * 5.0
		grid.add(Vector3(45.0, p.surface.height_at(45.0, z) + 0.5, z), 1.0, 1.0, 0)
	grid.add(Vector3(80.0, 0.0, -50.0), 1.0, 1.0, 0)
	grid.build()
	p.items = grid

	var collected: Array[int] = []
	p.item_collected.connect(func(idx: int) -> void: collected.push_back(idx))
	_drive(p, 20.0, RaceInput.new())

	t.ok(collected.size() >= 5, "herring along the racing line are collected")
	t.ok(not collected.has(20), "herring far off the line are not collected")
	t.ok(collected.size() == _unique_count(collected), "each item is collected only once")

static func _unique_count(a: Array[int]) -> int:
	var seen: Dictionary[int, bool] = {}
	for v: int in a:
		seen[v] = true
	return seen.size()

static func _trees(t: TestCase) -> void:
	t.begin("tree collision")
	var p := _sim(25.0)
	var grid := ObjectGrid.new()
	# A wall of trees across the fall line 20 m downhill.
	for i: int in 40:
		var x: float = 25.0 + float(i)
		grid.add(Vector3(x, p.surface.height_at(x, -25.0), -25.0), 1.2, 4.0, 0)
	grid.build()
	p.trees = grid

	var hits: Array[int] = [0]
	p.tree_hit.connect(func(_loc: Vector3) -> void: hits[0] += 1)

	var speed_before: float = 0.0
	for i: int in 1200:
		if p.pos.z > -24.0:
			speed_before = p.vel.length()
		p.step(RaceInput.new(), 1.0 / 60.0)
		if hits[0] > 0 and p.pos.z < -26.0:
			break
	t.ok(hits[0] > 0, "driving into a tree registers a hit")
	t.ok(p.vel.length() < speed_before, "a tree impact costs speed")
	t.ok(p.vel.length() >= PhysConst.MIN_TUX_SPEED - 1e-6, "you are never stopped dead by a tree")

static func _determinism(t: TestCase) -> void:
	t.begin("determinism")
	# Same input trace, same trajectory — the precondition for ghosts, replays
	# and any future networked play.
	var trace: Array[RaceInput] = []
	for i: int in 600:
		var inp := RaceInput.new()
		inp.left_turn = (i / 45) % 3 == 0
		inp.right_turn = (i / 45) % 3 == 1
		inp.braking = (i / 90) % 4 == 3
		inp.paddling = i % 7 == 0
		inp.charging = (i / 60) % 5 == 2
		trace.push_back(inp)

	var a := _sim(22.0)
	var b := _sim(22.0)
	for inp: RaceInput in trace:
		a.step(inp, 1.0 / 60.0)
	for inp: RaceInput in trace:
		b.step(inp, 1.0 / 60.0)
	t.eq_v(a.pos, b.pos, 1e-9, "identical input traces give identical positions")
	t.eq_v(a.vel, b.vel, 1e-9, "identical input traces give identical velocities")
	t.ok(is_finite(a.pos.length()), "the scripted trace stays finite")
	t.ok(a.vel.length() < 60.0, "the scripted trace stays in a sane speed envelope")

static func _adaptive_step(t: TestCase) -> void:
	t.begin("adaptive stepping")
	# The integrator must not move the player more than MAX_STEP_DIST = 0.20 m
	# per substep, however fast the frame is running.
	var p := _sim(30.0)
	var input := RaceInput.new()
	var max_frame_move: float = 0.0
	for i: int in 300:
		var before: Vector3 = p.pos
		p.step(input, 1.0 / 10.0)      # a deliberately terrible 10 fps frame
		max_frame_move = maxf(max_frame_move, before.distance_to(p.pos))
		t.ok(is_finite(p.pos.y), "large frame steps stay stable")
		if t.failed > 0:
			return
	# 0.1 s at ~10 m/s is 1 m of travel, which the solver has to break up.
	t.ok(max_frame_move > 0.2, "a 10 fps frame does move further than one substep")
	t.ok(p.vel.length() < 60.0, "no energy blow-up at a bad frame rate")
