## Phase 0 exit criterion: measure the ODE substep loop in GDScript against a
## web-export frame budget (godot-port-plan.md §7, risk S2).
##
## The question is not "is GDScript fast" but "does one frame of simulation fit
## in a small slice of 16.6 ms with the browser's ~2-3× penalty applied". The
## benchmark reports substeps per simulated second and the real-time factor, so
## the margin is explicit rather than inferred.
class_name BenchPhysics
extends RefCounted

## The load a frame of a full race actually is: ten simulated racers on one
## hill, nine of them planning lines, all against a live snow field.
##
## Reported alongside the single-racer number because that one stopped
## predicting a frame the moment there was a field on the hill — and because the
## thing S2 was afraid of turned out not to be the thing that costs. See
## [method bench_snow].
static func run_field(count: int = 10) -> Dictionary:
	var field := RacerField.new()
	field.resize(count)
	var sims: Array[RacePhysics] = []
	var brains: Array[AIInputSource] = []
	var snow := SnowField.new()
	for seat: int in count:
		var p := _fixture()
		(p.surface as HeightmapSurface).snow_field = snow
		var ai := AIInputSource.new(AISkill.for_level(AISkill.Level.HARD), seat, 0)
		ai.rivals = field.positions
		ai.rival_index = seat
		p.rivals = field
		p.rival_index = seat
		sims.push_back(p)
		brains.push_back(ai)

	var input := RaceInput.new()
	var dt: float = 1.0 / 60.0
	var frames: int = 900
	for i: int in 60:
		for seat: int in count:
			brains[seat].poll(input, sims[seat], dt)
			sims[seat].step(input, dt)

	var start: int = Time.get_ticks_usec()
	for i: int in frames:
		# The order [method RaceScene._simulation_tick] uses: everyone is
		# published before anyone advances, so every racer resolves the tick
		# against the same instant.
		for seat: int in count:
			field.set_state(seat, sims[seat].pos, sims[seat].vel)
		for seat: int in count:
			brains[seat].poll(input, sims[seat], dt)
			sims[seat].step(input, dt)
		snow.recenter(sims[0].pos.x, sims[0].pos.z)
		snow.decay(dt)
	var elapsed_us: int = Time.get_ticks_usec() - start
	var per_frame_ms: float = float(elapsed_us) / float(frames) / 1000.0
	return {
		"racers": count,
		"per_frame_ms": per_frame_ms,
		"budget_fraction": per_frame_ms / 16.667,
	}

## The CPU snow mirror's per-tick maintenance, on its own.
##
## Here because it was for a long time the most expensive thing in a frame and
## nothing measured it: a 16 384-texel loop decaying the field by 0.018 % cost
## 0.74 ms a tick, fifteen times the whole simulation. It is a scalar now, and
## this is the line that stops it quietly becoming a loop again.
static func bench_snow() -> Dictionary:
	var f := SnowField.new()
	f.recenter(0.0, 0.0)
	var dt: float = 1.0 / 60.0
	var ticks: int = 3600
	for i: int in 60:
		f.decay(dt)
	var start: int = Time.get_ticks_usec()
	for i: int in ticks:
		f.decay(dt)
	var decay_us: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	for i: int in ticks:
		f.recenter(float(i) * 0.2, -float(i) * 0.4)
	var recenter_us: int = Time.get_ticks_usec() - start
	return {
		"decay_ms": float(decay_us) / float(ticks) / 1000.0,
		"recenter_ms": float(recenter_us) / float(ticks) / 1000.0,
	}

## The fixture both benchmarks race on: a fast, bumpy 35° run with trees and
## herring spread over it, so the collision queries are exercised rather than
## short-circuited.
static func _fixture() -> RacePhysics:
	var p := RacePhysics.new()
	p.surface = SlopeFixture.rolling_slope(35.0, 1.2)
	p.play_min_x = 2.5
	p.play_max_x = 87.5
	p.play_length = 100000.0
	p.init_at(45.0, -5.0)

	var trees := ObjectGrid.new()
	var items := ObjectGrid.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i: int in 4000:
		var x: float = rng.randf_range(0.0, 90.0)
		var z: float = -rng.randf_range(0.0, 4000.0)
		trees.add(Vector3(x, p.surface.height_at(x, z), z), 1.2, 4.0, 0)
	for i: int in 500:
		var x: float = rng.randf_range(0.0, 90.0)
		var z: float = -rng.randf_range(0.0, 4000.0)
		items.add(Vector3(x, p.surface.height_at(x, z) + 0.5, z), 1.0, 1.0, 0)
	trees.build()
	items.build()
	p.trees = trees
	p.items = items
	return p

## One racer, no snow field. The original S2 measurement, kept exactly as it
## was so the number stays comparable to every one recorded in the docs — but
## no longer the number that predicts a frame. See [method run_field].
static func run() -> Dictionary:
	# A fast, bumpy 35° run: high speed drives the substep count up (the solver
	# caps travel at MAX_STEP_DIST = 0.20 m per step) and the bumps force
	# error-control retries. Occasional carving, so the trajectory is a race
	# line rather than a slalom that scrubs all the speed off. Trees and herring
	# are spread over it, so the collision queries are exercised rather than
	# short-circuited.
	var p := _fixture()

	var substeps: Array[int] = [0]
	p.substep_advanced.connect(func(_h: float, _pos: Vector3, _speed: float) -> void:
		substeps[0] += 1)

	var input := RaceInput.new()
	var dt: float = 1.0 / 60.0
	var frames: int = 3600                      # 60 s of simulated racing

	# Warm up so the measurement is not dominated by first-call overhead.
	for i: int in 60:
		p.step(input, dt)
	substeps[0] = 0

	var evals_at_start: int = p.force_evals
	var start: int = Time.get_ticks_usec()
	for i: int in frames:
		input.left_turn = (i / 120) % 6 == 0
		input.right_turn = (i / 120) % 6 == 3
		input.braking = (i / 240) % 12 == 11
		p.step(input, dt)
	var elapsed_us: int = Time.get_ticks_usec() - start

	var simulated: float = float(frames) * dt
	var per_frame_ms: float = float(elapsed_us) / float(frames) / 1000.0
	return {
		"frames": frames,
		"simulated_seconds": simulated,
		"wall_ms": float(elapsed_us) / 1000.0,
		"per_frame_ms": per_frame_ms,
		"substeps": substeps[0],
		"substeps_per_frame": float(substeps[0]) / float(frames),
		"force_evals": p.force_evals - evals_at_start,
		"evals_per_frame": float(p.force_evals - evals_at_start) / float(frames),
		"realtime_factor": simulated / (float(elapsed_us) / 1_000_000.0),
		"budget_fraction": per_frame_ms / 16.667,
		"final_speed": p.vel.length(),
		"distance": p.way,
	}
