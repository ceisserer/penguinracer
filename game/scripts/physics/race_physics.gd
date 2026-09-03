## The player simulation: a 20 kg point mass integrated with adaptive ODE23
## against a [SurfaceProvider]. Faithful port of ETR 0.8.4 `CControl`
## (src/physics.cpp); see etracer.md §4.1 for the force model.
##
## Deliberately has [b]zero node dependencies[/b] — it is a plain [RefCounted]
## so it can be stepped headlessly in tests and driven from a recorded input
## trace. This is the main structural fix over the original, whose `CControl`
## reached into six global singletons.
##
## Deviations from the original are marked DEVIATION and each has a reason.
class_name RacePhysics
extends RefCounted

## Emitted once per accepted ODE substep, inside the integration loop, exactly
## where ETR called `generate_particles`. The spray emitter listens to this.
signal substep_advanced(h: float, pos: Vector3, speed: float)
## Emitted when an item's bounding sphere is entered. `index` indexes [member items].
signal item_collected(index: int)
## Emitted on each new tree impact (not re-emitted while still overlapping).
signal tree_hit(tree_pos: Vector3)
## Emitted on each new contact with another racer, carrying their slot in
## [member rivals] (not re-emitted while the two are still touching).
##
## DEVIATION: the original has nobody else on the hill to hit. See
## [method _adjust_racer_collision].
signal racer_hit(rival: int)
## Emitted when the player crosses the finish line.
signal race_finished()

# ---------------------------------------------------------------- world

var surface: SurfaceProvider
var items: ObjectGrid
var trees: ObjectGrid
var wind: WindField = WindField.new()

## Rectangular play area, used when [member bounds_polygon] is empty.
var play_min_x: float = -INF
var play_max_x: float = INF
## Course length in metres; the finish line sits at z = -play_length.
var play_length: float = INF
## Optional non-rectangular play area in world XZ. Empty means use the rectangle.
## New in v2 — the original could only ever describe an axis-aligned box.
var bounds_polygon: PackedVector2Array = PackedVector2Array()

## Effective collision radius of the character, replacing ETR's sphere-hierarchy
## vs. polyhedron narrowphase (see godot-port-plan.md §3.3).
var character_radius: float = 0.3
var character_height: float = 0.6

## Everyone on the hill this tick, or null when there is nobody to hit — a
## practice run, a headless test, the racer being replayed from a trace.
##
## DEVIATION: the original races the clock, so a body never had a body to hit.
## Set once a tick by [method RaceScene._refresh_rivals], before anybody
## advances, so every racer resolves its contacts against the same instant. See
## [RacerField] for why the ghost is not in it.
var rivals: RacerField = null
## This body's own slot in [member rivals], so it cannot collide with itself.
## -1 when it is not in the list at all.
##
## Written alongside the positions rather than fixed at construction, because a
## peer leaving the session renumbers everyone behind it — and an index left
## pointing at the wrong racer is a body permanently colliding with a ghost of
## where it used to be.
var rival_index: int = -1

# ---------------------------------------------------------------- state

var pos: Vector3 = Vector3.ZERO
var vel: Vector3 = Vector3.ZERO
var last_pos: Vector3 = Vector3.ZERO
var net_force: Vector3 = Vector3.ZERO
var direction: Vector3 = Vector3.FORWARD
var orientation: Quaternion = Quaternion.IDENTITY
var plane_nml: Vector3 = Vector3.UP
## Distance travelled along the course, metres.
var way: float = 0.0
## Simulation clock. The original read a global; here it is owned state.
var time: float = 0.0

# steering
var turn_fact: float = 0.0
var turn_animation: float = 0.0
var paddle_time: float = 0.0
var jump_amt: float = 0.0
var jump_start_time: float = 0.0
var is_paddling: bool = false
var is_braking: bool = false
var begin_jump: bool = false
var jumping: bool = false
var jump_charging: bool = false
var airborne: bool = false

# tricks
var front_flip: bool = false
var back_flip: bool = false
var roll_left: bool = false
var roll_right: bool = false
var roll_factor: float = 0.0
var flip_factor: float = 0.0

# finish
var finished: bool = false
var finish_brake: float = 20.0
var _finish_speed: float = 0.0

# pseudo-constants, lowered during the finish sequence
var min_speed: float = PhysConst.MIN_TUX_SPEED
var min_frict_speed: float = PhysConst.MIN_FRICT_SPEED

# ---------------------------------------------- force-evaluation scratch
# Mirrors ETR's `TForce ff`: shared state the force functions read in order.
# Kept as members (not locals) both for fidelity and to avoid per-substep
# allocation in the ODE inner loop — see godot-port-plan.md §7 risk S2.

var _ff_surfnml: Vector3 = Vector3.UP
var _ff_rollnml: Vector3 = Vector3.UP
var _ff_vel: Vector3 = Vector3.ZERO
var _ff_frictdir: Vector3 = Vector3.ZERO
var _ff_frict_coeff: float = 0.35
var _ff_comp_depth: float = 0.05
var _ff_surfdistance: float = 0.0
var _ff_compression: float = 0.0

var _sample: SurfaceSample = SurfaceSample.new()
var _ode_time_step: float = -1.0
var _charge_start_time: float = 0.0

# tree-collision memo (ETR used function-static state; owned here so it cannot
# leak across course loads — etracer.md §9)
var _last_collision: bool = false
var _last_collision_tree: Vector3 = Vector3(-999, -999, -999)
var _last_collision_pos: Vector3 = Vector3(-999, -999, -999)
var _was_colliding: bool = false
## Which rival this body was touching on the previous substep, so a contact is
## announced when it begins rather than sixty times a second while it lasts.
## -1 is "touching nobody".
var _touching_rival: int = -1
var _query_buf: PackedInt32Array = PackedInt32Array()

## Diagnostic counter: net-force evaluations since construction. The ODE inner
## loop costs three per accepted substep plus three per rejected retry, so this
## is the number that actually predicts frame cost (risk S2).
var force_evals: int = 0

const MAX_JUMP_AMT := 1.0
const ROLL_DECAY := 0.2

# --- racer-against-racer contact (DEVIATION; see _adjust_racer_collision) ---

## How bouncy a penguin is. Zero would have two racers ride along glued
## together at the same speed; one would make the hill a snooker table. A third
## is a shoulder-barge: you both get moved, and neither of you gets launched.
const RACER_RESTITUTION := 0.35
## Fastest the overlap term alone may push two bodies apart, m/s. This is a
## position error being corrected through the velocity — the only channel this
## simulation has — so it has to be small enough that being nudged never reads
## as being fired.
const RACER_PUSH_SPEED := 1.2
const JUMP_MAX_START_HEIGHT := 0.30
const FIN_AIR_BRAKE := 20.0

# ====================================================================
#                              setup
# ====================================================================

## Place the player at the start. Mirrors `CControl::Init`: the initial velocity
## is the surface normal rotated -90° about X, i.e. straight down the fall line.
func init_at(start_x: float, start_z: float) -> void:
	surface.sample_into(start_x, start_z, _sample)
	var nml: Vector3 = _sample.normal
	var init_vel: Vector3 = Basis(Vector3(1, 0, 0), -PI / 2.0) * nml
	init_vel = init_vel.normalized() * PhysConst.INIT_TUX_SPEED

	pos = Vector3(start_x, _sample.height, start_z)
	vel = init_vel
	last_pos = pos
	net_force = Vector3.ZERO
	plane_nml = nml
	direction = init_vel
	orientation = Quaternion.IDENTITY

	turn_fact = 0.0
	turn_animation = 0.0
	is_braking = false
	jump_amt = 0.0
	is_paddling = false
	jumping = false
	jump_charging = false
	begin_jump = false
	airborne = false
	way = 0.0
	time = 0.0
	finished = false

	front_flip = false
	back_flip = false
	roll_left = false
	roll_right = false
	roll_factor = 0.0
	flip_factor = 0.0

	_ode_time_step = -1.0
	_last_collision = false
	_last_collision_pos = Vector3(-999, -999, -999)
	_was_colliding = false
	_touching_rival = -1

# ====================================================================
#                              input
# ====================================================================

## Translate one frame of player intent into simulation state.
## Port of `CalcSteeringControls` / `CalcTrickControls` / `CalcJumpEnergy`.
func apply_input(input: RaceInput, timestep: float) -> void:
	var ycoord: float = surface.height_at(pos.x, pos.z)
	var trick_airborne: bool = pos.y > ycoord + JUMP_MAX_START_HEIGHT
	_calc_trick_controls(input, timestep, trick_airborne)
	if finished:
		_calc_finish_controls(timestep)
	else:
		_calc_steering_controls(input, timestep)

func _calc_steering_controls(input: RaceInput, timestep: float) -> void:
	if absf(input.stick_turn) > 0.2:
		turn_fact = input.stick_turn
		turn_animation = clampf(turn_animation + turn_fact * 2.0 * timestep, -1.0, 1.0)
	elif input.left_turn != input.right_turn:
		turn_fact = -1.0 if input.left_turn else 1.0
		turn_animation = clampf(turn_animation + turn_fact * 2.0 * timestep, -1.0, 1.0)
	else:
		turn_fact = 0.0
		if timestep < ROLL_DECAY:
			turn_animation *= 1.0 - timestep / ROLL_DECAY
		else:
			turn_animation = 0.0

	if input.paddling and not is_paddling:
		is_paddling = true
		paddle_time = time

	is_braking = input.braking

	_calc_jump_energy()
	if input.charging and not jump_charging and not jumping:
		jump_charging = true
		_charge_start_time = time
	if not input.charging and jump_charging:
		jump_charging = false
		begin_jump = true

func _calc_jump_energy() -> void:
	if jump_charging:
		jump_amt = minf(MAX_JUMP_AMT, time - _charge_start_time)
	elif jumping:
		jump_amt *= 1.0 - (time - jump_start_time) / PhysConst.JUMP_FORCE_DURATION
	else:
		jump_amt = 0.0

func _calc_trick_controls(input: RaceInput, timestep: float, trick_airborne: bool) -> void:
	if trick_airborne and input.trick_modifier:
		if input.left_turn: roll_left = true
		if input.right_turn: roll_right = true
		if input.paddling: front_flip = true
		if input.braking: back_flip = true

	if roll_left or roll_right:
		roll_factor += (-1.0 if roll_left else 1.0) * 0.15 * timestep / 0.05
		if roll_factor > 1.0 or roll_factor < -1.0:
			roll_factor = 0.0
			roll_left = false
			roll_right = false
	if front_flip or back_flip:
		flip_factor += (-1.0 if back_flip else 1.0) * 0.15 * timestep / 0.05
		if flip_factor > 1.0 or flip_factor < -1.0:
			flip_factor = 0.0
			front_flip = false
			back_flip = false

## After the finish line the player steers itself straight down the fall line.
func _calc_finish_controls(timestep: float) -> void:
	var speed: float = vel.length()
	var dir_angle: float = rad_to_deg(atan(vel.x / vel.z)) if absf(vel.z) > 1e-6 else 0.0
	if absf(dir_angle) > 5.0 and speed > 5.0:
		turn_fact = clampf(dir_angle / 20.0, -1.0, 1.0)
		turn_animation += turn_fact * 2.0 * timestep
	else:
		turn_fact = 0.0
		if timestep < ROLL_DECAY:
			turn_animation *= 1.0 - timestep / ROLL_DECAY
		else:
			turn_animation = 0.0

# ====================================================================
#                              forces
# ====================================================================

## Surface normal rotated about the projected velocity by up to ±30° (±55° when
## braking), attenuated by friction and speed ramps. This is what makes carving
## feel banked. ETR `CalcRollNormal`.
func calc_roll_normal(speed: float) -> Vector3:
	var v: Vector3 = (_ff_vel - _ff_surfnml * _ff_surfnml.dot(_ff_vel))
	v = v.normalized()
	if v.length_squared() < 0.5:
		return _ff_surfnml

	var roll_angle: float = PhysConst.BRAKING_ROLL_ANGLE if is_braking else PhysConst.MAX_ROLL_ANGLE
	var angle: float = turn_fact * roll_angle \
		* minf(1.0, maxf(0.0, _ff_frict_coeff) / PhysConst.IDEAL_ROLL_FRIC) \
		* minf(1.0, maxf(0.0, speed - min_speed) / (PhysConst.IDEAL_ROLL_SPEED - min_speed))
	return Basis(v, deg_to_rad(angle)) * _ff_surfnml

## Reynolds-table air drag. ETR `CalcAirForce`.
func calc_air_force() -> Vector3:
	var windvec: Vector3 = -_ff_vel
	if wind != null and wind.windy:
		windvec += PhysConst.WIND_FACTOR * wind.vector
	var windspeed: float = windvec.length()
	if windspeed < 1e-9:
		return Vector3.ZERO
	var re: float = 34600.0 * windspeed
	var interpol: float = PhysConst.linear_interp(PhysConst.AIRLOG, PhysConst.AIRDRAG, log(re) / log(10.0))
	var dragcoeff: float = pow(10.0, interpol)
	return (0.104 * dragcoeff * windspeed) * windvec

## Piecewise-stiff spring: 1500 / 3000 / 10000 N/m in three compression bands,
## damped, clamped to 3000 N, applied along the [b]roll[/b] normal.
func calc_spring_force() -> Vector3:
	var springvel: float = _ff_vel.dot(_ff_rollnml)
	var springfact: float = minf(_ff_compression, 0.05) * 1500.0
	springfact += PhysConst.etr_clamp(0.0, _ff_compression - 0.05, 0.12) * 3000.0
	springfact += maxf(0.0, _ff_compression - 0.12 - 0.05) * 10000.0
	springfact -= springvel * (1500.0 if _ff_compression <= 0.05 else 500.0)
	springfact = PhysConst.etr_clamp(0.0, springfact, 3000.0)
	return springfact * _ff_rollnml

func calc_normal_force() -> Vector3:
	if _ff_surfdistance <= -_ff_comp_depth:
		_ff_compression = -_ff_surfdistance - _ff_comp_depth
		return calc_spring_force()
	_ff_compression = 0.0
	return Vector3.ZERO

func calc_jump_force() -> Vector3:
	if begin_jump:
		begin_jump = false
		if not airborne:
			jumping = true
			jump_start_time = time
		else:
			jumping = false
	if jumping and time - jump_start_time < PhysConst.JUMP_FORCE_DURATION:
		return Vector3(0.0, 294.0 + jump_amt * 294.0, 0.0)
	jumping = false
	return Vector3.ZERO

## Friction opposing velocity, then [b]rotated about the surface normal by
## turn_fact × 45°[/b] — this rotation is how steering works in this game.
func calc_friction_force(speed: float, nmlforce: Vector3) -> Vector3:
	if (not airborne and speed > min_frict_speed) or finished:
		var fric_f_mag: float = minf(PhysConst.MAX_FRICT_FORCE, nmlforce.length() * _ff_frict_coeff)
		var frictforce: Vector3 = fric_f_mag * _ff_frictdir
		var steer_angle: float = turn_fact * PhysConst.MAX_TURN_ANGLE
		if fric_f_mag > 1e-9 and absf(fric_f_mag * sin(deg_to_rad(steer_angle))) > PhysConst.MAX_TURN_PERP:
			steer_angle = rad_to_deg(asin(clampf(PhysConst.MAX_TURN_PERP / fric_f_mag, -1.0, 1.0))) \
				* signf(turn_fact)
		frictforce = Basis(_ff_surfnml, deg_to_rad(steer_angle)) * frictforce
		return (1.0 + PhysConst.MAX_TURN_PEN) * frictforce
	return Vector3.ZERO

func calc_brake_force(speed: float) -> Vector3:
	if not finished:
		if not airborne and speed > min_frict_speed and speed > min_speed and is_braking:
			return _ff_frict_coeff * PhysConst.BRAKE_FORCE * _ff_frictdir
		return Vector3.ZERO
	# DEVIATION: the original's finish sequence also swapped gravity for a flat
	# 500 N (etracer.md §4.1, called out as a hack). Gravity stays real here;
	# only the braking ramp is retained, which is what actually stops the player.
	if not airborne:
		is_braking = true
		return _finish_speed * finish_brake * _ff_frictdir
	return _finish_speed * FIN_AIR_BRAKE * _ff_frictdir

## Flipper paddling: forward push that fades out by 60 km/h and is useless on ice.
func calc_paddle_force(speed: float) -> Vector3:
	if is_paddling and time - paddle_time >= PhysConst.PADDLING_DURATION:
		is_paddling = false
	if not is_paddling:
		return Vector3.ZERO

	var paddleforce: Vector3
	if airborne:
		paddleforce = Vector3(0.0, 0.0, -PhysConst.TUX_MASS * PhysConst.EARTH_GRAV / 4.0)
		paddleforce = orientation * paddleforce
	else:
		var factor: float = -minf(PhysConst.MAX_PADD_FORCE, PhysConst.MAX_PADD_FORCE
			* (PhysConst.MAX_PADDLING_SPEED - speed) / PhysConst.MAX_PADDLING_SPEED
			* minf(1.0, _ff_frict_coeff / PhysConst.IDEAL_PADD_FRIC))
		paddleforce = factor * _ff_frictdir
	return PhysConst.PADDLE_FACT * paddleforce

func calc_gravitation_force() -> Vector3:
	return Vector3(0.0, -PhysConst.EARTH_GRAV * PhysConst.TUX_MASS, 0.0)

## Sum of all forces at a trial (pos, vel). The order matters: each function
## reads shared `_ff_*` state written by the ones before it.
func calc_net_force(p: Vector3, v: Vector3) -> Vector3:
	force_evals += 1
	_ff_vel = v
	var speed: float = v.length()
	_ff_frictdir = -v.normalized() if speed > 1e-9 else Vector3.ZERO

	surface.sample_into(p.x, p.z, _sample)
	_ff_frict_coeff = _sample.friction
	_ff_comp_depth = _sample.compression_depth
	_ff_surfnml = _sample.normal
	_ff_rollnml = calc_roll_normal(speed)
	_ff_surfdistance = _ff_surfnml.dot(p - Vector3(p.x, _sample.height, p.z))
	airborne = _ff_surfdistance > 0.0

	# don't change this order
	var gravforce: Vector3 = calc_gravitation_force()
	var nmlforce: Vector3 = calc_normal_force()
	var jumpforce: Vector3 = calc_jump_force()
	var frictforce: Vector3 = calc_friction_force(speed, nmlforce)
	var brakeforce: Vector3 = calc_brake_force(speed)
	var airforce: Vector3 = calc_air_force()
	var paddleforce: Vector3 = calc_paddle_force(speed)

	return jumpforce + gravforce + nmlforce + frictforce + airforce + brakeforce + paddleforce

# ====================================================================
#                           ODE solver
# ====================================================================
# Bogacki–Shampine RK2(3) with adaptive step, ported from ETR mathlib.cpp.
# Written against Vector3 rather than six independent scalar channels: the
# coefficients are per-component identical, so this is numerically the same
# integrator with a quarter of the bookkeeping.

const _BS_C1 := 0.5          # k0 weight at stage 1
const _BS_C2 := 0.75         # k1 weight at stage 2
const _BS_B0 := 2.0 / 9.0
const _BS_B1 := 1.0 / 3.0
const _BS_B2 := 4.0 / 9.0
const _BS_E0 := -5.0 / 72.0
const _BS_E1 := 1.0 / 12.0
const _BS_E2 := 1.0 / 9.0
const _BS_E3 := -1.0 / 8.0
const _BS_EXP := 1.0 / 3.0

func adjust_time_step(h: float, v: Vector3) -> float:
	var speed: float = v.length()
	var max_h: float = PhysConst.MAX_STEP_DIST / speed if speed > 1e-9 else PhysConst.MAX_TIME_STEP
	h = PhysConst.etr_clamp(PhysConst.MIN_TIME_STEP, h, max_h)
	return minf(h, PhysConst.MAX_TIME_STEP)

func _solve_ode_system(timestep: float) -> void:
	var h: float = _ode_time_step
	if h < 0.0:
		h = adjust_time_step(timestep, vel)
	var t: float = 0.0
	var tfinal: float = timestep

	var new_pos: Vector3 = pos
	var new_vel: Vector3 = vel
	var new_f: Vector3 = net_force

	var err: float = 0.0
	var tol: float = PhysConst.MAX_POS_ERR
	var done: bool = false
	var guard: int = 0

	while not done:
		guard += 1
		if t >= tfinal or guard > 512:
			break
		if 1.1 * h > tfinal - t:
			h = tfinal - t
			done = true

		var saved_pos: Vector3 = new_pos
		var saved_vel: Vector3 = new_vel
		var saved_f: Vector3 = new_f

		var failed: bool = false
		var f_end: Vector3 = new_f
		while true:
			var kp0: Vector3 = h * new_vel
			var kv0: Vector3 = h * (new_f / PhysConst.TUX_MASS)

			var p1: Vector3 = new_pos + _BS_C1 * kp0
			var v1: Vector3 = new_vel + _BS_C1 * kv0
			var kp1: Vector3 = h * v1
			var f1: Vector3 = calc_net_force(p1, v1)
			var kv1: Vector3 = h * (f1 / PhysConst.TUX_MASS)

			var p2: Vector3 = new_pos + _BS_C2 * kp1
			var v2: Vector3 = new_vel + _BS_C2 * kv1
			var kp2: Vector3 = h * v2
			var f2: Vector3 = calc_net_force(p2, v2)
			var kv2: Vector3 = h * (f2 / PhysConst.TUX_MASS)

			var p3: Vector3 = new_pos + _BS_B0 * kp0 + _BS_B1 * kp1 + _BS_B2 * kp2
			var v3: Vector3 = new_vel + _BS_B0 * kv0 + _BS_B1 * kv1 + _BS_B2 * kv2
			var kp3: Vector3 = h * v3
			var f3: Vector3 = calc_net_force(p3, v3)
			var kv3: Vector3 = h * (f3 / PhysConst.TUX_MASS)
			f_end = f3

			var pos_err: float = (_BS_E0 * kp0 + _BS_E1 * kp1 + _BS_E2 * kp2 + _BS_E3 * kp3).length()
			var vel_err: float = (_BS_E0 * kv0 + _BS_E1 * kv1 + _BS_E2 * kv2 + _BS_E3 * kv3).length()

			if pos_err / PhysConst.MAX_POS_ERR > vel_err / PhysConst.MAX_VEL_ERR:
				err = pos_err
				tol = PhysConst.MAX_POS_ERR
			else:
				err = vel_err
				tol = PhysConst.MAX_VEL_ERR

			if err > tol and h > PhysConst.MIN_TIME_STEP + 1e-9:
				done = false
				if not failed:
					failed = true
					h *= maxf(0.5, 0.8 * pow(tol / err, _BS_EXP))
				else:
					h *= 0.5
				h = adjust_time_step(h, saved_vel)
				new_pos = saved_pos
				new_vel = saved_vel
				new_f = saved_f
			else:
				new_pos = p3
				new_vel = v3
				break

		t += h
		var speed: float = new_vel.length()
		substep_advanced.emit(h, new_pos, speed)

		# The original re-evaluated the force here. The stage-3 evaluation was
		# already made at exactly (new_pos, new_vel) and calc_net_force has no
		# state left to consume, so reusing it is identical and drops the
		# per-step force evaluations from 4 to 3 (risk S2 headroom).
		new_f = f_end

		if not failed:
			var temp: float = 1.25 * pow(err / tol, _BS_EXP)
			if temp > 0.2:
				h = h / temp
			else:
				h = 5.0 * h
		h = adjust_time_step(h, new_vel)
		new_vel = _adjust_tree_collision(new_pos, new_vel)
		# After the tree, so a racer pinned between the two comes out of the
		# contact going where the trunk allows: the tree is scenery and does not
		# move, and the other racer can be shoved.
		new_vel = _adjust_racer_collision(new_pos, new_vel)
		_check_item_collection(new_pos)

	_ode_time_step = h
	net_force = new_f
	vel = new_vel
	last_pos = pos
	pos = new_pos
	way += (pos - last_pos).length()

# ====================================================================
#                            collision
# ====================================================================

## Broadphase by 2D distance against `(diam/2 + 0.6)²`, narrowphase a cylinder
## test. DEVIATION: the original ran the character's ellipsoid hierarchy against
## an 8-face polyhedron; the cheap proxy is explicit here (plan §3.3).
func _check_tree_collision(p: Vector3) -> bool:
	if trees == null or trees.size() == 0:
		return false
	if p.distance_squared_to(_last_collision_pos) < PhysConst.COLL_TOLERANCE:
		return _last_collision and not airborne

	var hit: bool = false
	var loc: Vector3 = Vector3.ZERO
	_query_buf = trees.query(p.x, p.z, _query_buf)
	for i: int in _query_buf:
		var diam: float = trees.diameters[i]
		var height: float = trees.heights[i]
		loc = trees.positions[i]
		var dx: float = loc.x - p.x
		var dz: float = loc.z - p.z
		var broad: float = diam * 0.5 + 0.6
		if dx * dx + dz * dz > broad * broad:
			continue
		var narrow: float = diam * 0.5 + character_radius
		if dx * dx + dz * dz > narrow * narrow:
			continue
		if p.y + character_height * 0.5 < loc.y or p.y - character_height * 0.5 > loc.y + height:
			continue
		hit = true
		break

	_last_collision_tree = loc
	_last_collision_pos = p
	_last_collision = hit
	return hit

func _adjust_tree_collision(p: Vector3, v: Vector3) -> Vector3:
	if not _check_tree_collision(p):
		_was_colliding = false
		return v
	if not _was_colliding:
		tree_hit.emit(_last_collision_tree)
	_was_colliding = true

	var tree_nml: Vector3 = Vector3(p.x - _last_collision_tree.x, 0.0, p.z - _last_collision_tree.z)
	if tree_nml.length_squared() < 1e-12:
		return v
	tree_nml = tree_nml.normalized()

	var speed: float = v.length() * 0.8
	var out_vel: Vector3 = v.normalized() if v.length_squared() > 1e-12 else Vector3.ZERO
	var costheta: float = out_vel.dot(tree_nml)
	if costheta < 0.0:
		var factor: float = 0.5 if airborne else 1.5
		out_vel = (out_vel + (-factor * costheta) * tree_nml).normalized()
	return out_vel * maxf(speed, min_speed)

## Bounce off the other racers. Returns the velocity to carry on with.
##
## DEVIATION: ETR races the clock and has nobody on the hill to hit, so there is
## nothing to port here — this is the same shape as the tree above, made
## symmetrical.
##
## [b]Two equal masses, resolved twice.[/b] There is no arbiter of a collision
## between two racers and deliberately no authority anywhere in this game (see
## [RaceNetwork]): each body sees the other in its own [member rivals] and
## applies the [i]same[/i] impulse to itself, with the normal reversed — so what
## one body is paid the other pays, and neither ever writes to the other. That
## is what keeps this working unchanged when the other body is a remote peer
## being played back from snapshots and is not being simulated on this machine
## at all.
##
## It is symmetrical to the tick and not to the bit: each body resolves against
## the other's velocity as it was published at the start of the tick and its own
## as it is right now, mid-substep, so the two halves are computed from slightly
## different instants. Two racers shoved apart from rest come out even to within
## a few centimetres over five seconds, which is the accuracy this needs.
##
## The impulse is the textbook equal-mass one — remove the closing component of
## the relative velocity and give back [constant RACER_RESTITUTION] of it — and
## it is horizontal, because a shoulder-barge should move you across the hill
## and not into the air. On top of it sits an overlap term, which is a position
## error being corrected through the only channel this simulation has: without
## it two bodies that start inside each other (a narrow course clamps its start
## lanes together) have no closing velocity to remove and stay inside each other
## for the whole run.
func _adjust_racer_collision(p: Vector3, v: Vector3) -> Vector3:
	if rivals == null or rivals.is_empty():
		_touching_rival = -1
		return v
	var contact: float = character_radius * 2.0
	var out_vel: Vector3 = v
	var hit: int = -1
	for i: int in rivals.size():
		if i == rival_index:
			continue
		var other: Vector3 = rivals.position_of(i)
		# A body height apart vertically is a miss: somebody landing a jump on
		# top of you is a contact, somebody sailing over you is not. Same
		# measure the tree test uses, and the same one for both bodies.
		if absf(other.y - p.y) > character_height:
			continue
		var dx: float = p.x - other.x
		var dz: float = p.z - other.z
		var d2: float = dx * dx + dz * dz
		if d2 > contact * contact:
			continue

		# Two racers exactly on top of each other have no normal to separate
		# along. Break the tie by index rather than by anything measured, so the
		# result is the same on every machine and in every replay.
		var n: Vector3
		var dist: float
		if d2 < 1e-8:
			n = Vector3.RIGHT if rival_index < i else Vector3.LEFT
			dist = 0.0
		else:
			dist = sqrt(d2)
			n = Vector3(dx / dist, 0.0, dz / dist)

		var relative: Vector3 = out_vel - rivals.velocity_of(i)
		var closing: float = relative.dot(n)
		if closing < 0.0:
			out_vel += n * (-(1.0 + RACER_RESTITUTION) * 0.5 * closing)
		# Whatever the impulse did, leave the pair separating at a rate that
		# scales with how far inside each other they are.
		var push: float = RACER_PUSH_SPEED * clampf((contact - dist) / contact, 0.0, 1.0)
		var outward: float = out_vel.dot(n)
		if outward < push:
			out_vel += n * (push - outward)
		hit = i

	# Announced once per contact spell, not once per rival: a racer squeezed
	# between two others alternates between them substep by substep, and a cue
	# per alternation is a machine gun rather than a bump.
	if hit >= 0 and _touching_rival < 0:
		racer_hit.emit(hit)
	_touching_rival = hit
	return out_vel

func _check_item_collection(p: Vector3) -> void:
	if items == null or items.size() == 0:
		return
	_query_buf = items.query(p.x, p.z, _query_buf)
	for i: int in _query_buf:
		if items.collectable[i] != 1:
			continue
		var r: float = items.diameters[i] * 0.5 + 0.7
		if items.positions[i].distance_squared_to(p) <= r * r:
			items.collectable[i] = 0
			item_collected.emit(i)

# ====================================================================
#                          frame update
# ====================================================================

## Advance the simulation by `timestep` seconds. Port of `UpdatePlayerPos`.
func update(timestep: float) -> void:
	if finished:
		min_speed = 0.0
		min_frict_speed = 0.0
	else:
		min_speed = PhysConst.MIN_TUX_SPEED
		min_frict_speed = PhysConst.MIN_FRICT_SPEED

	if wind != null:
		wind.update(timestep)

	if timestep > 2e-9:
		_solve_ode_system(timestep)

	surface.sample_into(pos.x, pos.z, _sample)
	var surf_nml: Vector3 = _sample.normal
	var dist_from_surface: float = surf_nml.dot(pos - Vector3(pos.x, _sample.height, pos.z))
	plane_nml = surf_nml

	var speed: float = vel.length()
	_adjust_velocity()
	_adjust_position(surf_nml, dist_from_surface)
	_apply_bounds(speed)
	_update_orientation(timestep, dist_from_surface, surf_nml)

	time += timestep

## Convenience: one frame of input plus one frame of simulation.
func step(input: RaceInput, timestep: float) -> void:
	apply_input(input, timestep)
	update(timestep)

func _adjust_velocity() -> void:
	var speed: float = maxf(min_speed, vel.length())
	vel = vel.normalized() * speed if vel.length_squared() > 1e-12 else Vector3.ZERO

func _adjust_position(surf_nml: Vector3, dist_from_surface: float) -> void:
	if dist_from_surface < -PhysConst.MAX_SURF_PEN:
		pos += (-PhysConst.MAX_SURF_PEN - dist_from_surface) * surf_nml

func _apply_bounds(speed: float) -> void:
	if bounds_polygon.is_empty():
		pos.x = clampf(pos.x, play_min_x, play_max_x)
	else:
		var p2: Vector2 = Vector2(pos.x, pos.z)
		if not Geometry2D.is_point_in_polygon(p2, bounds_polygon):
			var nearest: Vector2 = _closest_point_on_polygon(p2)
			pos.x = nearest.x
			pos.z = nearest.y
	if pos.z > 0.0:
		pos.z = 0.0
	if not finished and -pos.z >= play_length:
		finished = true
		_finish_speed = speed
		race_finished.emit()

func _closest_point_on_polygon(p: Vector2) -> Vector2:
	var best: Vector2 = bounds_polygon[0]
	var best_d: float = INF
	var n: int = bounds_polygon.size()
	for i: int in n:
		var a: Vector2 = bounds_polygon[i]
		var b: Vector2 = bounds_polygon[(i + 1) % n]
		var c: Vector2 = Geometry2D.get_closest_point_to_segment(p, a, b)
		var d: float = c.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = c
	return best

## Body orientation from velocity, surface normal and the roll factor.
## Replaces ETR `CCharShape::AdjustOrientation`, which mixed the maths with
## the ellipsoid scene graph; here it is pure state the rig reads.
func _update_orientation(timestep: float, dist_from_surface: float, surf_nml: Vector3) -> void:
	var v: Vector3 = vel
	if v.length_squared() < 1e-9:
		return
	var new_dir: Vector3 = v.normalized()

	# On the ground the body lies along the surface; airborne it keeps its
	# heading and slowly levels out. Ramp between the two over 0..0.3 m.
	var ground_blend: float = clampf(1.0 - dist_from_surface / 0.3, 0.0, 1.0)
	var up: Vector3 = (surf_nml * ground_blend + Vector3.UP * (1.0 - ground_blend)).normalized()
	var right: Vector3 = new_dir.cross(up)
	if right.length_squared() < 1e-9:
		return
	right = right.normalized()
	up = right.cross(new_dir).normalized()

	var target := Quaternion(Basis(right, up, -new_dir).orthonormalized())
	if roll_factor != 0.0:
		target *= Quaternion(Vector3(0, 0, 1), roll_factor * TAU)
	if flip_factor != 0.0:
		target *= Quaternion(Vector3(1, 0, 0), flip_factor * TAU)

	var alpha: float = minf(1.0, 1.0 - exp(-timestep / 0.06))
	orientation = orientation.slerp(target, alpha) if orientation.is_normalized() else target
	direction = new_dir
