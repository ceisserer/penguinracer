## Golden tests for every force function in [RacePhysics], with expected values
## worked out by hand from the constants in etracer.md §4.1 / ETR physics.cpp.
## These are the contract: if one of these moves, the game's feel has changed.
class_name TestForces
extends RefCounted

static func run(t: TestCase) -> void:
	_gravity(t)
	_air_drag(t)
	_spring(t)
	_normal(t)
	_friction(t)
	_brake(t)
	_paddle(t)
	_jump(t)
	_roll_normal(t)
	_interp(t)

static func _make() -> RacePhysics:
	var p := RacePhysics.new()
	p.surface = SlopeFixture.flat_slope(0.0)
	p.init_at(45.0, -5.0)
	return p

static func _gravity(t: TestCase) -> void:
	t.begin("gravity")
	var p := _make()
	# 20 kg × 9.81 m/s², straight down. No other term touches Y at rest.
	t.eq_v(p.calc_gravitation_force(), Vector3(0.0, -196.2, 0.0), 1e-6, "gravity is -m*g in Y")

static func _air_drag(t: TestCase) -> void:
	t.begin("air drag")
	var p := _make()
	p.wind = null
	p._ff_vel = Vector3(0.0, 0.0, -20.0)
	# Re = 34600 × 20 = 692000; log10 = 5.84010.
	# Table segment 5→6: slope -0.57, so log10(Cd) = -0.80886, Cd = 0.155268.
	# |F| = 0.104 × Cd × v² = 0.104 × 0.155268 × 400 = 6.4592 N, opposing motion.
	var f: Vector3 = p.calc_air_force()
	t.eq_v(f, Vector3(0.0, 0.0, 6.4592), 0.01, "drag at 20 m/s opposes motion")

	# Drag is superlinear in this régime: doubling speed more than triples it.
	p._ff_vel = Vector3(0.0, 0.0, -40.0)
	var f2: Vector3 = p.calc_air_force()
	# Force goes as v² times a drag coefficient that itself falls with Reynolds
	# number, so doubling speed multiplies drag by about 2.7 — superlinear, but
	# well short of the naive 4×.
	t.between(f2.z / f.z, 2.0, 3.5, "drag grows superlinearly but sub-quadratically")

	# At rest there is no wind and no drag.
	p._ff_vel = Vector3.ZERO
	t.eq_v(p.calc_air_force(), Vector3.ZERO, 1e-9, "no drag at rest")

static func _spring(t: TestCase) -> void:
	t.begin("spring force")
	var p := _make()
	p._ff_rollnml = Vector3.UP
	p._ff_vel = Vector3(0.0, 0.0, -10.0)   # no motion along the normal

	# Band 1: 1500 N/m up to 5 cm.
	p._ff_compression = 0.03
	t.eq_v(p.calc_spring_force(), Vector3(0.0, 45.0, 0.0), 1e-6, "band 1 = 1500 N/m")

	# Band 2: +3000 N/m from 5 cm to 17 cm.
	p._ff_compression = 0.10
	t.eq_v(p.calc_spring_force(), Vector3(0.0, 225.0, 0.0), 1e-6, "band 2 = +3000 N/m")

	# Band 3: +10000 N/m beyond 17 cm.
	p._ff_compression = 0.25
	t.eq_v(p.calc_spring_force(), Vector3(0.0, 1235.0, 0.0), 1e-6, "band 3 = +10000 N/m")

	# Damping: -springvel × 1500 in the shallow band, and the 3000 N clamp.
	p._ff_compression = 0.03
	p._ff_vel = Vector3(0.0, -2.0, 0.0)
	t.eq_v(p.calc_spring_force(), Vector3(0.0, 3000.0, 0.0), 1e-6, "damped force clamps at 3000 N")

	# Moving away from the surface, damping can null the force out entirely.
	p._ff_vel = Vector3(0.0, 2.0, 0.0)
	t.eq_v(p.calc_spring_force(), Vector3.ZERO, 1e-6, "force floors at zero, never pulls down")

static func _normal(t: TestCase) -> void:
	t.begin("normal force")
	var p := _make()
	p._ff_rollnml = Vector3.UP
	p._ff_vel = Vector3.ZERO
	p._ff_comp_depth = 0.05

	# Above the compression depth the terrain does not push back at all.
	p._ff_surfdistance = -0.04
	t.eq_v(p.calc_normal_force(), Vector3.ZERO, 1e-9, "no force within comp_depth")

	# 3 cm past it → band 1.
	p._ff_surfdistance = -0.08
	t.eq_v(p.calc_normal_force(), Vector3(0.0, 45.0, 0.0), 1e-6, "penetration past comp_depth springs")

static func _friction(t: TestCase) -> void:
	t.begin("friction force")
	var p := _make()
	p._ff_surfnml = Vector3.UP
	p._ff_frict_coeff = 0.35
	p.airborne = false
	p.turn_fact = 0.0
	p._ff_frictdir = Vector3(0.0, 0.0, 1.0)   # opposing -Z travel

	# |N| × µ = 196.2 × 0.35 = 68.67, scaled by (1 + MAX_TURN_PEN).
	var f: Vector3 = p.calc_friction_force(20.0, Vector3(0.0, 196.2, 0.0))
	t.eq_v(f, Vector3(0.0, 0.0, 78.9705), 1e-3, "straight-line friction")

	# Below MIN_FRICT_SPEED friction switches off entirely — this is why the
	# player keeps creeping instead of sticking.
	t.eq_v(p.calc_friction_force(2.0, Vector3(0.0, 196.2, 0.0)), Vector3.ZERO, 1e-9,
		"no friction under 2.8 m/s")

	# Airborne: nothing to rub against.
	p.airborne = true
	t.eq_v(p.calc_friction_force(20.0, Vector3(0.0, 196.2, 0.0)), Vector3.ZERO, 1e-9,
		"no friction while airborne")
	p.airborne = false

	# Steering rotates the friction vector about the surface normal by
	# turn_fact × 45°. This *is* the steering model.
	p.turn_fact = 1.0
	var turned: Vector3 = p.calc_friction_force(20.0, Vector3(0.0, 196.2, 0.0))
	t.eq_f(turned.length(), f.length(), 1e-4, "steering rotates friction, preserving magnitude")
	t.eq_f(rad_to_deg(turned.signed_angle_to(f, Vector3.UP)), -45.0, 1e-3,
		"full steering rotates by 45°")

	# The lateral component is capped at MAX_TURN_PERP = 400 N: at a large
	# normal force the steer angle shrinks to asin(400/|F|).
	var big := Vector3(0.0, 4000.0, 0.0)      # µ|N| = 1400 → capped to 800
	var capped: Vector3 = p.calc_friction_force(20.0, big)
	t.eq_f(capped.length(), 800.0 * (1.0 + PhysConst.MAX_TURN_PEN), 1e-3,
		"friction magnitude caps at 800 N")
	var lateral: float = absf(capped.x)
	t.eq_f(lateral, 400.0 * (1.0 + PhysConst.MAX_TURN_PEN), 1e-2,
		"lateral component caps at 400 N")

static func _brake(t: TestCase) -> void:
	t.begin("brake force")
	var p := _make()
	p._ff_frict_coeff = 0.35
	p._ff_frictdir = Vector3(0.0, 0.0, 1.0)
	p.airborne = false
	p.is_braking = true
	t.eq_v(p.calc_brake_force(20.0), Vector3(0.0, 0.0, 70.0), 1e-6, "brake = µ × 200 N")

	p.is_braking = false
	t.eq_v(p.calc_brake_force(20.0), Vector3.ZERO, 1e-9, "no brake force unless braking")

	p.is_braking = true
	p.airborne = true
	t.eq_v(p.calc_brake_force(20.0), Vector3.ZERO, 1e-9, "no braking in mid-air")

static func _paddle(t: TestCase) -> void:
	t.begin("paddle force")
	var p := _make()
	p._ff_frict_coeff = 0.35
	p._ff_frictdir = Vector3(0.0, 0.0, 1.0)
	p.airborne = false
	p.is_paddling = true
	p.paddle_time = 0.0
	p.time = 0.1

	# At a standstill the paddle gives its full 122.5 N, forward (-Z here).
	t.eq_v(p.calc_paddle_force(0.0), Vector3(0.0, 0.0, -122.5), 1e-4, "full paddle force at rest")

	# It fades linearly to nothing at 60 km/h — paddling is a low-speed tool.
	t.eq_v(p.calc_paddle_force(PhysConst.MAX_PADDLING_SPEED), Vector3.ZERO, 1e-6,
		"paddle useless at 60 km/h")
	t.eq_v(p.calc_paddle_force(PhysConst.MAX_PADDLING_SPEED * 0.5),
		Vector3(0.0, 0.0, -61.25), 1e-4, "paddle scales linearly with speed")

	# And it is useless on ice: scaled by min(1, µ/0.35).
	p._ff_frict_coeff = 0.2
	t.eq_v(p.calc_paddle_force(0.0), Vector3(0.0, 0.0, -70.0), 1e-4, "paddle is weak on ice")

	# It expires after PADDLING_DURATION whether or not the key is held.
	p.time = 0.5
	t.eq_v(p.calc_paddle_force(0.0), Vector3.ZERO, 1e-9, "paddle stops after 0.4 s")
	t.ok(not p.is_paddling, "paddle state clears itself")

static func _jump(t: TestCase) -> void:
	t.begin("jump force")
	var p := _make()
	p.airborne = false
	p.time = 0.0
	p.jump_amt = 0.0
	p.begin_jump = true
	t.eq_v(p.calc_jump_force(), Vector3(0.0, 294.0, 0.0), 1e-6, "uncharged jump = 294 N")
	t.ok(p.jumping, "jump latches")
	t.ok(not p.begin_jump, "begin_jump is consumed once")

	p.jump_amt = 1.0
	t.eq_v(p.calc_jump_force(), Vector3(0.0, 588.0, 0.0), 1e-6, "fully charged jump doubles the force")

	# The impulse lasts exactly JUMP_FORCE_DURATION.
	p.time = 0.25
	t.eq_v(p.calc_jump_force(), Vector3.ZERO, 1e-9, "jump force ends after 0.2 s")
	t.ok(not p.jumping, "jump clears itself")

	# You cannot start a jump in mid-air.
	p.time = 0.0
	p.airborne = true
	p.begin_jump = true
	t.eq_v(p.calc_jump_force(), Vector3.ZERO, 1e-9, "no jump while airborne")

static func _roll_normal(t: TestCase) -> void:
	t.begin("roll normal")
	var p := _make()
	p._ff_surfnml = Vector3.UP
	p._ff_vel = Vector3(0.0, 0.0, -20.0)
	p._ff_frict_coeff = 0.35
	p.is_braking = false
	p.min_speed = PhysConst.MIN_TUX_SPEED

	# Not steering: the roll normal is just the surface normal.
	p.turn_fact = 0.0
	t.eq_v(p.calc_roll_normal(20.0), Vector3.UP, 1e-6, "no bank when going straight")

	# Full steer at speed: banked by MAX_ROLL_ANGLE = 30° about the travel direction.
	p.turn_fact = 1.0
	var rolled: Vector3 = p.calc_roll_normal(20.0)
	t.eq_f(rad_to_deg(rolled.angle_to(Vector3.UP)), 30.0, 1e-3, "full steer banks 30°")
	t.ok(rolled.x > 0.0, "banking leans into the turn")

	# Braking banks harder — 55°.
	p.is_braking = true
	t.eq_f(rad_to_deg(p.calc_roll_normal(20.0).angle_to(Vector3.UP)), 55.0, 1e-3,
		"braking banks 55°")
	p.is_braking = false

	# The bank ramps in with speed and is off at a crawl, so the camera and the
	# character do not snap around when the player is barely moving.
	t.eq_v(p.calc_roll_normal(PhysConst.MIN_TUX_SPEED), Vector3.UP, 1e-6, "no bank at min speed")
	var half: Vector3 = p.calc_roll_normal(
		PhysConst.MIN_TUX_SPEED + (PhysConst.IDEAL_ROLL_SPEED - PhysConst.MIN_TUX_SPEED) * 0.5)
	t.eq_f(rad_to_deg(half.angle_to(Vector3.UP)), 15.0, 1e-3, "bank ramps linearly to 6 m/s")

	# On ice there is not enough grip to bank fully: scaled by µ/0.35.
	p._ff_frict_coeff = 0.175
	t.eq_f(rad_to_deg(p.calc_roll_normal(20.0).angle_to(Vector3.UP)), 15.0, 1e-3,
		"bank scales with friction")

static func _interp(t: TestCase) -> void:
	t.begin("linear interp")
	# ETR's LinearInterp extrapolates off both ends rather than clamping — the
	# air-drag table relies on it at very low and very high Reynolds numbers.
	t.eq_f(PhysConst.linear_interp(PhysConst.AIRLOG, PhysConst.AIRDRAG, 0.5), 0.975, 1e-9,
		"interpolates within the table")
	t.eq_f(PhysConst.linear_interp(PhysConst.AIRLOG, PhysConst.AIRDRAG, -1.0), 2.25, 1e-9,
		"exact at the first knot")
	t.eq_f(PhysConst.linear_interp(PhysConst.AIRLOG, PhysConst.AIRDRAG, 6.0), -0.9, 1e-9,
		"exact at the last knot")
	t.eq_f(PhysConst.linear_interp(PhysConst.AIRLOG, PhysConst.AIRDRAG, -2.0), 3.15, 1e-9,
		"extrapolates below the table")
	t.eq_f(PhysConst.linear_interp(PhysConst.AIRLOG, PhysConst.AIRDRAG, 7.0), -1.47, 1e-9,
		"extrapolates above the table")

	t.begin("etr clamp")
	t.eq_f(PhysConst.etr_clamp(0.0, 0.5, 1.0), 0.5, 1e-9, "value inside bounds")
	t.eq_f(PhysConst.etr_clamp(0.0, -1.0, 1.0), 0.0, 1e-9, "clamps to minimum")
	t.eq_f(PhysConst.etr_clamp(0.0, 2.0, 1.0), 1.0, 1e-9, "clamps to maximum")
	# The original macro is max(min(x, hi), lo): when the bounds cross, lo wins.
	t.eq_f(PhysConst.etr_clamp(1.0, 0.5, 0.2), 1.0, 1e-9, "minimum wins when bounds cross")
