## Phase 0 exit criterion: measure the ODE substep loop in GDScript against a
## web-export frame budget (godot-port-plan.md §7, risk S2).
##
## The question is not "is GDScript fast" but "does one frame of simulation fit
## in a small slice of 16.6 ms with the browser's ~2-3× penalty applied". The
## benchmark reports substeps per simulated second and the real-time factor, so
## the margin is explicit rather than inferred.
class_name BenchPhysics
extends RefCounted

static func run() -> Dictionary:
	# A fast, bumpy 35° run: high speed drives the substep count up (the solver
	# caps travel at MAX_STEP_DIST = 0.20 m per step) and the bumps force
	# error-control retries. Occasional carving, so the trajectory is a race
	# line rather than a slalom that scrubs all the speed off.
	var p := RacePhysics.new()
	p.surface = SlopeFixture.rolling_slope(35.0, 1.2)
	p.play_min_x = 2.5
	p.play_max_x = 87.5
	p.play_length = 100000.0
	p.init_at(45.0, -5.0)

	# A realistic load: trees and herring spread over the course, so the
	# collision queries are exercised rather than short-circuited.
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
