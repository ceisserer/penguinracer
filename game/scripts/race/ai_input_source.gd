## A computer opponent: an [InputSource] that looks at the simulation and
## decides what a player would have pressed.
##
## This is the seam [InputSource] was written for, arriving. Nothing else in the
## game changed shape to accommodate it — an opponent is a [SimulatedRacer] with
## one of these instead of a [LocalInputSource], it runs the same
## [RacePhysics] against the same [SurfaceProvider] and the same two
## [ObjectGrid]s, and [method Racer.present] cannot tell it from the player. It
## has no privileged access to anything: [method poll] is handed the simulation,
## which is the position, the velocity, the terrain and the trees, and it
## returns the same seven fields the keyboard fills.
##
## [b]How it drives.[/b] Once every [member AISkill.plan_interval] ticks it
## chooses an aim point — a world x it wants to be at [member AISkill.lookahead]
## metres further down the hill — by scoring nine candidate lines against four
## things:
##
## - [b]trees[/b], by how far each line intrudes into the clearance the skill
##   insists on, with a much larger penalty for a line that actually collides;
## - [b]the play bounds[/b], which reject a candidate outright;
## - [b]swerving[/b], because the fastest line through nothing is a straight one,
##   plus a gentle pull back toward the lane the opponent started in so that
##   nine of them do not converge into one column;
## - [b]the terrain[/b], where a skill that has [member AISkill.line_greed]
##   prefers the low friction of ice or a packed trench, and
##   [member AISkill.herring_greed] detours for fish.
##
## Between plans it steers at the aim point it last chose, which is what makes
## [member AISkill.plan_interval] a reaction time rather than only a saving.
## Paddling, braking and the weave are decided every tick from the skill.
##
## [b]The one thing it is told rather than shown[/b] is where the other racers
## are ([member rivals]). Everything else on this list is course furniture that
## was loaded with the course; another penguin is a body being integrated
## somewhere else on the same tick, and it reaches a racer through the
## [RacerField] the scene publishes. The simulation reads that field too, and
## bounces off it — so unlike a tree, a rival is something an opponent can
## survive hitting.
##
## What is scored here is therefore a [i]soft[/i] penalty, and deliberately much
## weaker than the tree's: an opponent will drive through another to avoid a
## trunk, because the trunk is the one that actually costs a race. Without any
## penalty at all, two opponents that both want the same herring converge on it
## and spend the rest of the course shouldering each other down the hill.
##
## [b]It is deterministic.[/b] The only randomness is a per-opponent personality
## drawn once from a seeded [RandomNumberGenerator] at construction; nothing is
## rolled per tick, and the simulation underneath runs on a fixed 60 Hz tick. So
## a race against opponents replays identically, which is what lets it be
## recorded like any other run and asserted on in the headless suite.
##
## [b]What it does not do.[/b] It never jumps, never charges a jump and never
## does a trick: the jump force is a fixed 294 N impulse that costs contact with
## the snow, and nothing in this force model makes leaving the ground faster.
## Nor does it race anybody as opposed to avoiding them: it will not block a
## line, will not lean on a racer alongside it, and does not know it has been
## leaned on — a contact reaches it only as the position it ends up in.
class_name AIInputSource
extends InputSource

## Candidate lines, and how far either side of the current position the outermost
## two sit. Nine at ±6 m is one every 1.5 m, which is finer than the 0.9 m the
## collision proxy is wide, so no gap between two trees is missed for being
## between two candidates.
const LANES := 9
const LANE_SPAN := 6.0

## Down-course spacing of the tree lookups, and how far either side of the
## racer they are made. [method ObjectGrid.query] returns a 3x3 neighbourhood of
## 4 m cells, so one lookup covers roughly ±6 m; stepping by 11 m and probing
## ±5 m in x tiles the corridor the candidates span with a little overlap.
const PROBE_STEP := 11.0
const PROBE_HALF := 5.0
## Rows of lookups, whatever the lookahead. Three covers 33 m, which is past the
## longest lookahead any skill asks for.
const MAX_PROBE_ROWS := 3

## Score charged per metre of sideways deviation from carrying straight on.
const SWERVE_COST := 1.0
## Per metre away from the lane this opponent started in. Deliberately weak — it
## is what spreads a field out, not what steers it.
const LANE_COST := 0.5
## How near a line has to pass another racer to be worth avoiding, metres, and
## what it costs. A penguin is about 0.9 m across, so this is roughly a length
## of clear air either side — enough that two of them read as two.
const RIVAL_REACH := 1.8
const RIVAL_COST := 20.0
## Per metre a line intrudes into the clearance the skill wants round a trunk.
const TREE_COST := 24.0
## Flat charge for a line that actually hits. Larger than any sum of the others,
## so a survivable line always wins over a fast one.
const COLLISION_COST := 600.0
## How near a line has to pass a herring to count as collecting it, metres. The
## simulation's own pickup radius is `diameter/2 + 0.7`; this is a little wider,
## because the line is a plan and the racer only approximately follows it.
const HERRING_REACH := 2.5
const HERRING_BONUS := 8.0
## Per unit of friction coefficient sampled on the candidate line. The spread
## that matters is ice at 0.2 against snow at 0.35 — about nine points of score
## at full [member AISkill.line_greed], i.e. worth a nine-metre detour.
const FRICTION_COST := 60.0
## The smallest stick reading the simulation will act on at all.
##
## [method RacePhysics._calc_steering_controls] ignores an analogue stick under
## 0.2 — the deadzone a real thumbstick needs — and falls back to the digital
## turn flags, which this source deliberately does not set: they are full lock
## or nothing, and an opponent that could only steer flat out would saw at every
## line it took. So any correction worth making has to come out past the
## deadzone. Getting this wrong is silent and total: the aim point is chosen
## correctly, the error is computed correctly, the stick is set correctly, and
## the racer holds whatever heading it had, because everything under 0.2 was
## rounded to "not steering".
const MIN_EFFECTIVE_STICK := 0.21
## Fraction of [member AISkill.steer_span_deg] below which the opponent leaves
## the line alone. Skill-relative, so a better one notices a smaller error.
const IGNORE_FRACTION := 0.04

## Metres the bounds probe is pulled back inside the polygon's own z extent, so
## that a candidate reaching past the finish line is judged on its x rather than
## rejected for being off the end of the course.
const BOUNDS_INSET := 1.0

var skill: AISkill
## Which of the opponents this is. Seeds the personality, and nothing else.
var seat: int = 0

## The world x this opponent aims for, [member AISkill.lookahead] metres down
## the hill. Held between plans.
var target_x: float = 0.0
## The lane it started in and is gently pulled back toward. Taken from the first
## poll after a reset rather than plumbed in from [RaceScene]: at that instant
## the racer is still on the start line, which is exactly the answer.
var preferred_x: float = 0.0

## Where every body on the hill is, refreshed once a tick by
## [method RaceScene._refresh_rivals] — [member RacerField.positions] itself,
## which the simulation resolves its contacts against, so the racer this
## opponent steers around is exactly the one it would bounce off. Ghosts are not
## in it; see [method Racer.collides].
##
## Deliberately an [Array] and not a [PackedVector3Array]: a packed array is
## copy-on-write, so handing one to nine opponents would hand out nine snapshots
## that stop tracking the moment the scene writes to its own. An [Array] is
## shared by reference and this one is written in place.
##
## Empty is a valid answer and is what a headless test and a solo race both get.
var rivals: Array[Vector3] = []
## This racer's own slot in [member rivals], so it does not swerve to avoid
## itself. Written alongside the positions rather than fixed at construction,
## because a racer leaving the session renumbers everyone behind it.
var rival_index: int = -1

var _wander_phase: float = 0.0
var _time: float = 0.0
var _ticks_since_plan: int = 0
var _planned: bool = false
var _lane_known: bool = false

# --- reused per plan, so a field of nine allocates nothing on the hot path ---
var _sample := SurfaceSample.new()
var _query := PackedInt32Array()
var _seen: Dictionary[int, bool] = {}
var _tree_x := PackedFloat32Array()
var _tree_z := PackedFloat32Array()
var _tree_r := PackedFloat32Array()
var _item_x := PackedFloat32Array()
var _item_z := PackedFloat32Array()

# --- the course, read once per run ---
var _bounds := PackedVector2Array()
var _bounds_ready: bool = false
var _bounds_z_min: float = -INF
var _bounds_centre_x: float = 0.0
var _min_x: float = -INF
var _max_x: float = INF

## [param p_seat] is the opponent's index in the field and [param p_seed] makes
## a race reproducible: the same seat at the same skill always draws the same
## personality.
func _init(p_skill: AISkill = null, p_seat: int = 0, p_seed: int = 0) -> void:
	skill = p_skill if p_skill != null else AISkill.for_level(AISkill.Level.MEDIUM)
	seat = p_seat
	vary(p_seed)

## Give this opponent a personality of its own.
##
## Nine opponents built from one skill table would drive nine identical lines
## and arrive in a column — visibly wrong, and it would make the field feel like
## one racer drawn nine times. A few per cent either way on the habits that
## decide a lap, plus a weave phase nobody shares, is enough to break that up
## without moving the level apart from its neighbours.
func vary(p_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d:%d:%d" % [skill.level, seat, p_seed])
	_wander_phase = rng.randf_range(0.0, TAU)
	skill.lookahead *= rng.randf_range(0.92, 1.08)
	skill.comfort_speed *= rng.randf_range(0.94, 1.06)
	skill.paddle_until *= rng.randf_range(0.94, 1.06)
	skill.tree_margin *= rng.randf_range(0.9, 1.1)
	skill.wander_period *= rng.randf_range(0.85, 1.15)

# ==================================================================
#                              driving
# ==================================================================

func poll(out: RaceInput, physics: RacePhysics, delta: float) -> void:
	out.clear()
	if physics == null or physics.surface == null:
		return
	_time += delta
	# Past the line `_calc_finish_controls` steers the racer down the fall line
	# itself and the brake ramp is the only thing that matters. There is nothing
	# left to race for, so the opponent takes its hands off.
	if physics.finished:
		return
	if not _lane_known:
		preferred_x = physics.pos.x
		_lane_known = true
	_ticks_since_plan += 1
	if not _planned or _ticks_since_plan >= skill.plan_interval:
		_plan(physics)
		_ticks_since_plan = 0

	var speed: float = physics.vel.length()
	var err: float = heading_error(physics)
	out.stick_turn = stick_for(err)
	out.braking = _wants_brake(physics, speed, err)
	# Paddling into the brake is what a player does by accident and it only
	# wastes the flipper stroke — the two forces are directly opposed.
	out.paddling = not out.braking and not physics.airborne and speed < skill.paddle_until

func reset() -> void:
	_time = 0.0
	_ticks_since_plan = 0
	_planned = false
	_lane_known = false
	# A restart may be a different course. The bounds are re-read on the next
	# plan rather than kept, which costs one polygon copy per race.
	_bounds_ready = false

func describe() -> String:
	return "ai:%s" % AISkill.name_of(skill.level)

## Signed angle from where the racer is going to where it wants to be, radians.
## Positive is "turn right", which is the sign [member RaceInput.stick_turn]
## uses: steering rotates the friction force about the surface normal, and a
## positive angle throws it toward +X for a racer heading down −Z.
##
## Public because it is the whole steering law and the suite asserts on it
## directly; nothing else calls it.
func heading_error(physics: RacePhysics) -> float:
	var heading := Vector2(physics.vel.x, physics.vel.z)
	# Below walking pace the velocity direction is noise — on the start line it
	# is whatever `init_at` made of the surface normal. Fall line instead.
	if heading.length_squared() < 0.25:
		heading = Vector2(0.0, -1.0)
	var weave: float = skill.wander_metres * sin(TAU * _time / skill.wander_period + _wander_phase)
	return heading.angle_to(Vector2(target_x + weave - physics.pos.x, -skill.lookahead))

## The heading error as a stick reading, past the simulation's deadzone.
##
## Public alongside [method heading_error] for the same reason: between them
## they are the whole steering law, and a suite that cannot see them can only
## assert on where a racer ended up. See [constant MIN_EFFECTIVE_STICK].
func stick_for(err: float) -> float:
	var span: float = deg_to_rad(skill.steer_span_deg)
	if absf(err) < span * IGNORE_FRACTION:
		return 0.0
	return signf(err) * lerpf(MIN_EFFECTIVE_STICK, 1.0,
		clampf(absf(err) / span, 0.0, 1.0))

## Braking is nerve, and it is where most of the difference between the levels
## ends up. Two reasons to do it: the hill has become faster than this opponent
## is willing to go, or the nose is so far off the line that the turn will not
## come round without scrubbing speed — braking widens the roll angle from 30°
## to 55° and multiplies the steering force by the friction coefficient.
func _wants_brake(physics: RacePhysics, speed: float, err: float) -> bool:
	if physics.airborne or speed < skill.brake_floor:
		return false
	if speed > skill.comfort_speed:
		return true
	return absf(err) > deg_to_rad(skill.brake_above_deg)

# ==================================================================
#                            the planner
# ==================================================================

func _plan(physics: RacePhysics) -> void:
	_planned = true
	if not _bounds_ready:
		_read_course(physics)
	var pos: Vector3 = physics.pos
	var target_z: float = pos.z - skill.lookahead
	_gather(physics, pos)

	var best_x: float = pos.x
	var best_score: float = -INF
	var found: bool = false
	for i: int in LANES:
		var offset: float = lerpf(-LANE_SPAN, LANE_SPAN, float(i) / float(LANES - 1))
		var x: float = pos.x + offset
		if not _in_bounds(x, target_z):
			continue
		var score: float = _score(physics, pos, x, target_z, offset)
		if score > best_score:
			best_score = score
			best_x = x
			found = true
	# Every candidate outside the course means the racer is already against a
	# boundary the physics is holding it inside. Aim at the middle and let the
	# next plan, a few metres later, find a real line.
	target_x = best_x if found else _bounds_centre_x

func _score(physics: RacePhysics, pos: Vector3, x: float, target_z: float,
		offset: float) -> float:
	var score: float = -absf(offset) * SWERVE_COST - absf(x - preferred_x) * LANE_COST
	var a := Vector2(pos.x, pos.z)
	var b := Vector2(x, target_z)

	for i: int in _tree_x.size():
		var trunk := Vector2(_tree_x[i], _tree_z[i])
		var gap: float = Geometry2D.get_closest_point_to_segment(trunk, a, b).distance_to(trunk)
		var clearance: float = _tree_r[i] + skill.tree_margin
		if gap >= clearance:
			continue
		score -= (clearance - gap) * TREE_COST
		if gap < _tree_r[i] + physics.character_radius:
			score -= COLLISION_COST

	if skill.herring_greed > 0.0:
		for i: int in _item_x.size():
			var fish := Vector2(_item_x[i], _item_z[i])
			var gap: float = Geometry2D.get_closest_point_to_segment(fish, a, b).distance_to(fish)
			if gap < HERRING_REACH:
				score += skill.herring_greed * HERRING_BONUS * (1.0 - gap / HERRING_REACH)

	# A rival is scored by column rather than by distance to the line, which is
	# what a tree gets. The difference is that a tree stands still and a rival is
	# going the same way you are at about the same speed: by the time you reach
	# the aim point they will have moved down the hill with you, so what decides
	# whether you meet is the x you both pick, not how near they are now. Scoring
	# the line instead measures the distance from your own start point — the same
	# for every candidate, which discriminates between none of them.
	for i: int in rivals.size():
		if i == rival_index:
			continue
		var them: Vector3 = rivals[i]
		# Only what is alongside or in front. Somebody behind you is their
		# problem; somebody a hundred metres down the hill is not in this race
		# with you yet.
		if them.z > pos.z + 1.0 or them.z < target_z - 5.0:
			continue
		var lateral: float = absf(x - them.x)
		if lateral >= RIVAL_REACH:
			continue
		# Weighted by how close alongside they already are, so overtaking
		# somebody a lookahead down the hill costs nothing and riding into the
		# penguin next to you costs the most.
		var nearness: float = 1.0 - clampf(absf(them.z - pos.z) / skill.lookahead, 0.0, 1.0)
		score -= (RIVAL_REACH - lateral) * RIVAL_COST * nearness

	if skill.line_greed > 0.0:
		# One sample, at the midpoint of the candidate. The friction field is
		# splat-blended and varies over metres, so a second tap buys precision
		# the aim point cannot use.
		physics.surface.sample_into((pos.x + x) * 0.5, (pos.z + target_z) * 0.5, _sample)
		score -= skill.line_greed * FRICTION_COST * _sample.friction

	return score

## Collect the trees and herring in the corridor ahead into flat arrays, so that
## scoring nine candidates against them is nine passes over a packed array
## rather than nine trips through the spatial grid.
func _gather(physics: RacePhysics, pos: Vector3) -> void:
	_tree_x.clear()
	_tree_z.clear()
	_tree_r.clear()
	_item_x.clear()
	_item_z.clear()
	var rows: int = clampi(ceili(skill.lookahead / PROBE_STEP), 1, MAX_PROBE_ROWS)

	if physics.trees != null and physics.trees.size() > 0:
		_seen.clear()
		for row: int in rows:
			var z: float = pos.z - PROBE_STEP * (0.5 + float(row))
			for side: int in 2:
				var x: float = pos.x + (PROBE_HALF if side == 1 else -PROBE_HALF)
				_query = physics.trees.query(x, z, _query)
				for index: int in _query:
					if _seen.has(index):
						continue
					_seen[index] = true
					var p: Vector3 = physics.trees.positions[index]
					_tree_x.push_back(p.x)
					_tree_z.push_back(p.z)
					_tree_r.push_back(physics.trees.diameters[index] * 0.5)

	if skill.herring_greed <= 0.0 or physics.items == null or physics.items.size() == 0:
		return
	_seen.clear()
	for row: int in rows:
		var z: float = pos.z - PROBE_STEP * (0.5 + float(row))
		for side: int in 2:
			var x: float = pos.x + (PROBE_HALF if side == 1 else -PROBE_HALF)
			_query = physics.items.query(x, z, _query)
			for index: int in _query:
				if _seen.has(index) or physics.items.collectable[index] != 1:
					continue
				_seen[index] = true
				var p: Vector3 = physics.items.positions[index]
				_item_x.push_back(p.x)
				_item_z.push_back(p.z)

# ==================================================================
#                             the course
# ==================================================================

## Read the play area once per run. [RaceScene] always hands the simulation a
## polygon; the headless fixtures use the rectangle, and both are answered.
func _read_course(physics: RacePhysics) -> void:
	_bounds_ready = true
	_bounds = physics.bounds_polygon
	_min_x = physics.play_min_x
	_max_x = physics.play_max_x
	if _bounds.is_empty():
		_bounds_z_min = -INF
		_bounds_centre_x = 0.0 if is_inf(_min_x) or is_inf(_max_x) \
			else (_min_x + _max_x) * 0.5
		return
	var lo: float = INF
	var hi: float = -INF
	var sum_x: float = 0.0
	for p: Vector2 in _bounds:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
		sum_x += p.x
	_bounds_z_min = lo
	_bounds_centre_x = sum_x / float(_bounds.size())

## Whether an aim point is somewhere the racer is allowed to be.
##
## The probe's z is pulled back inside the polygon's own extent, because a
## candidate aimed [member AISkill.lookahead] metres past the finish line is off
## the end of the play area and would be rejected for the one reason that does
## not matter — the last thirty metres of every course would otherwise be raced
## by an opponent with no opinion about where to go.
func _in_bounds(x: float, z: float) -> bool:
	if _bounds.is_empty():
		return x >= _min_x and x <= _max_x
	return Geometry2D.is_point_in_polygon(
		Vector2(x, maxf(z, _bounds_z_min + BOUNDS_INSET)), _bounds)
