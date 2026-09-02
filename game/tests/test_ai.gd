## The computer opponents: the skill table, the setup value object, and — the
## part worth having — that an [AIInputSource] actually drives.
##
## Everything here runs the real [RacePhysics] against a real
## [HeightmapSurface], because an AI that steers correctly against a stub is not
## evidence of anything. The load-bearing assertions are [method _ladder], which
## says the three levels finish in the order they claim to, and
## [method _trees], which says an opponent goes round a stand of trees a
## straight-line racer would drive into.
class_name TestAI
extends RefCounted

## The rate [RaceScene] ticks at, written out for the same reason
## [TestMultiplayer] writes it out — a headless test has no business loading a
## scene with a course in it.
const DT := 1.0 / 60.0

static func run(t: TestCase) -> void:
	_skill_table(t)
	_skill_names(t)
	_setup(t)
	_lanes(t)
	_steering(t)
	_descends(t)
	_ladder(t)
	_trees(t)
	_rivals(t)
	_determinism(t)
	_finish(t)

# ------------------------------------------------------------------
#                          the tuning table
# ------------------------------------------------------------------

static func _skill_table(t: TestCase) -> void:
	t.begin("skill table")
	var easy: AISkill = AISkill.for_level(AISkill.Level.EASY)
	var medium: AISkill = AISkill.for_level(AISkill.Level.MEDIUM)
	var hard: AISkill = AISkill.for_level(AISkill.Level.HARD)

	# Every habit has to move the same way up the ladder. A level that looked
	# further ahead but braked earlier would not be "better", it would be
	# different, and the ladder the menu offers would stop meaning anything.
	t.ok(easy.lookahead < medium.lookahead and medium.lookahead < hard.lookahead,
		"a better opponent looks further ahead")
	t.ok(easy.plan_interval > medium.plan_interval
		and medium.plan_interval > hard.plan_interval,
		"and replans more often, i.e. reacts sooner")
	t.ok(easy.paddle_until < medium.paddle_until and medium.paddle_until < hard.paddle_until,
		"and keeps paddling for longer")
	t.ok(easy.comfort_speed < medium.comfort_speed and medium.comfort_speed < hard.comfort_speed,
		"and is willing to go faster")
	t.ok(easy.brake_above_deg < medium.brake_above_deg
		and medium.brake_above_deg < hard.brake_above_deg,
		"and carves a turn where a worse one brakes into it")
	t.ok(easy.wander_metres > medium.wander_metres and medium.wander_metres > hard.wander_metres,
		"and holds a straighter line")
	t.ok(easy.tree_margin > medium.tree_margin and medium.tree_margin > hard.tree_margin,
		"and passes a tree closer")
	# Paddling stops helping at MAX_PADDLING_SPEED; nobody should waste strokes
	# past it, and the best opponent should use every one of them.
	t.eq_f(hard.paddle_until, PhysConst.MAX_PADDLING_SPEED, 1e-6,
		"the best opponent paddles exactly as long as paddling helps")
	# The fish are points, and points cost time. It is the weakest opponent that
	# gets distracted by them.
	t.ok(easy.herring_greed > hard.herring_greed,
		"and is the least distracted by herring")

	# Each call has to hand out its own table, or per-opponent variation would
	# jitter one shared object and every opponent would drift together.
	var again: AISkill = AISkill.for_level(AISkill.Level.HARD)
	t.ok(again != hard, "each call returns its own copy")

static func _skill_names(t: TestCase) -> void:
	t.begin("skill names")
	for level: int in AISkill.NAMES.size():
		var parsed: AISkill.Level = AISkill.parse(AISkill.NAMES[level])
		t.ok(parsed == AISkill.level_at(level),
			"'%s' round-trips" % AISkill.NAMES[level])
		t.ok(not AISkill.label_of(AISkill.level_at(level)).is_empty(),
			"'%s' has something to show a player" % AISkill.NAMES[level])
	t.ok(AISkill.parse("HARD") == AISkill.Level.HARD, "the name is case-insensitive")
	t.ok(AISkill.parse("  easy ") == AISkill.Level.EASY, "and is trimmed")
	# A hand-edited settings file and a `--difficulty=` typo both arrive here,
	# and neither is worth refusing to race over.
	t.ok(AISkill.parse("impossible") == AISkill.Level.MEDIUM,
		"an unknown name is the middle of the ladder, not an error")

static func _setup(t: TestCase) -> void:
	t.begin("race setup")
	var practice: RaceSetup = RaceSetup.practice()
	t.ok(not practice.is_race(), "no opponents is practice")
	t.ok(practice.opponents == 0, "and is what the default constructs")

	var race: RaceSetup = RaceSetup.against(4, AISkill.Level.HARD)
	t.ok(race.is_race() and race.opponents == 4, "four opponents is a race")
	t.ok(RaceSetup.against(99, AISkill.Level.EASY).opponents == RaceSetup.MAX_OPPONENTS,
		"a field larger than the maximum is clamped, not refused")
	t.ok(RaceSetup.against(-3, AISkill.Level.EASY).opponents == 0,
		"and a negative one is practice")

	t.ok(race.matches(race.copy()), "a copy is the same field")
	t.ok(not race.matches(RaceSetup.against(4, AISkill.Level.EASY)),
		"the same count at another skill is a different field")
	t.ok(not race.matches(RaceSetup.against(5, AISkill.Level.HARD)),
		"and so is another count at the same skill")
	t.ok(not race.matches(null), "and nothing at all is not a match")

static func _lanes(t: TestCase) -> void:
	t.begin("start line")
	# The player's seat is the course's own start point, which is what keeps a
	# practice run — and every reference capture — where it has always been.
	t.eq_f(RaceSetup.lane_offset(0), RaceSetup.LANE_SPACING, 1e-6,
		"the first opponent starts one lane out")
	var seen: Array[float] = []
	for seat: int in RaceSetup.MAX_OPPONENTS:
		var offset: float = RaceSetup.lane_offset(seat)
		t.ok(not seen.has(offset), "seat %d has a lane of its own" % seat)
		seen.push_back(offset)
	# Symmetrical about the start point, so a field is not strung out to one side
	# of the course. An odd field has one unpaired lane and cannot sum to zero;
	# every even prefix can, and has to.
	for count: int in range(2, RaceSetup.MAX_OPPONENTS + 1, 2):
		var sum: float = 0.0
		for seat: int in count:
			sum += RaceSetup.lane_offset(seat)
		t.eq_f(sum, 0.0, 1e-6, "a field of %d is balanced about the start point" % count)

	# A narrow course cannot seat a wide field, and the outermost lanes have to
	# stack against the edge rather than start outside the play area.
	var narrow := PackedVector2Array([Vector2(20.0, 1.0), Vector2(30.0, 1.0),
		Vector2(30.0, -400.0), Vector2(20.0, -400.0)])
	for seat: int in RaceSetup.MAX_OPPONENTS:
		var x: float = RaceSetup.lane_x(25.0 + RaceSetup.lane_offset(seat), narrow)
		t.between(x, 20.0 + RaceSetup.LANE_MARGIN, 30.0 - RaceSetup.LANE_MARGIN,
			"seat %d is clamped into a narrow course" % seat)
	t.eq_f(RaceSetup.lane_x(25.0, PackedVector2Array()), 25.0, 1e-6,
		"and a course with no bounds leaves the lane alone")

# ------------------------------------------------------------------
#                              driving
# ------------------------------------------------------------------

static func _sim(surface: SurfaceProvider = null) -> RacePhysics:
	var p := RacePhysics.new()
	p.surface = surface if surface != null else SlopeFixture.rolling_slope(22.0)
	p.play_min_x = 2.5
	p.play_max_x = 87.5
	p.play_length = 470.0
	p.init_at(45.0, -5.0)
	return p

static func _ai(level: AISkill.Level, seat: int = 0) -> AIInputSource:
	return AIInputSource.new(AISkill.for_level(level), seat, 0)

## Drive `seconds` of simulation and hand back the physics, so a caller can ask
## it anything. Ticked exactly as [method RaceScene._simulation_tick] does.
static func _drive(source: InputSource, physics: RacePhysics, seconds: float) -> RacePhysics:
	var input := RaceInput.new()
	for i: int in int(seconds / DT):
		source.poll(input, physics, DT)
		physics.step(input, DT)
	return physics

static func _steering(t: TestCase) -> void:
	t.begin("steering law")
	var ai: AIInputSource = _ai(AISkill.Level.HARD)
	# No weave in the way of the reading: the sign is what is under test.
	ai.skill.wander_metres = 0.0
	var physics: RacePhysics = _sim()
	physics.vel = Vector3(0.0, 0.0, -12.0)

	ai.target_x = physics.pos.x
	t.eq_f(ai.heading_error(physics), 0.0, 1e-6, "an aim point dead ahead asks for no steering")
	ai.target_x = physics.pos.x + 8.0
	t.ok(ai.heading_error(physics) > 0.0, "an aim point to the right asks for a right turn")
	ai.target_x = physics.pos.x - 8.0
	t.ok(ai.heading_error(physics) < 0.0, "and one to the left for a left turn")

	# `stick_turn` positive is a right turn: steering rotates the friction force
	# about the surface normal, and a positive angle throws it toward +X for a
	# racer heading down −Z. Assert it against the simulation rather than
	# against the comment, because the comment cannot be wrong loudly.
	var right: RacePhysics = _sim(SlopeFixture.flat_slope(20.0))
	var straight: RacePhysics = _sim(SlopeFixture.flat_slope(20.0))
	var turn := RaceInput.new()
	turn.stick_turn = 1.0
	var none := RaceInput.new()
	for i: int in 180:
		right.step(turn, DT)
		straight.step(none, DT)
	t.ok(right.pos.x > straight.pos.x + 1.0,
		"a positive stick really does steer toward +X")

static func _descends(t: TestCase) -> void:
	t.begin("an opponent drives the hill")
	var physics: RacePhysics = _drive(_ai(AISkill.Level.MEDIUM), _sim(), 20.0)
	# Twenty seconds of a 22° slope is a long way down it. A racer that only
	# fell off the start line would be a fraction of this.
	t.ok(physics.pos.z < -60.0,
		"twenty seconds gets a medium opponent well down the course (%.0f m)" % -physics.pos.z)
	t.between(physics.pos.x, physics.play_min_x + 1.0, physics.play_max_x - 1.0,
		"and leaves it inside the play area rather than scraping a boundary")
	t.ok(physics.vel.length() > 6.0, "and still carrying speed")

	# Every level has to at least get down the hill; a difficulty that stalls is
	# not an easy opponent, it is a broken one.
	for level: int in 3:
		var run: RacePhysics = _drive(_ai(AISkill.level_at(level)), _sim(), 20.0)
		t.ok(run.pos.z < -40.0,
			"%s gets down the hill too" % AISkill.NAMES[level])

static func _ladder(t: TestCase) -> void:
	t.begin("the difficulty ladder")
	# The whole promise of the feature, on one slope with nothing in the way:
	# the levels differ only in driving habits, so the ordering has to come out
	# of the physics rather than out of a multiplier.
	var distance: Array[float] = []
	for level: int in 3:
		distance.push_back(-_drive(_ai(AISkill.level_at(level)), _sim(), 30.0).pos.z)
	t.ok(distance[1] > distance[0],
		"medium out-drives easy (%.0f m vs %.0f m)" % [distance[1], distance[0]])
	t.ok(distance[2] > distance[1],
		"and hard out-drives medium (%.0f m vs %.0f m)" % [distance[2], distance[1]])
	# A ladder whose rungs are a metre apart is not a difficulty setting anyone
	# can feel.
	t.ok(distance[2] - distance[0] > 25.0,
		"and the two ends of the ladder are far apart (%.0f m)" % (distance[2] - distance[0]))

static func _trees(t: TestCase) -> void:
	t.begin("tree avoidance")
	# A wall of trees across the fall line with one gap in it, ten metres below
	# the start. A racer that goes straight hits the wall; one that looks ahead
	# goes through the gap.
	var surface: HeightmapSurface = SlopeFixture.flat_slope(20.0)
	var trees := ObjectGrid.new()
	for i: int in 21:
		var x: float = 35.0 + float(i)
		if absf(x - 41.0) < 2.5:
			continue  # the gap
		# On the terrain, not at y = 0: the trunk test is a cylinder in world
		# space, and a stand of trees floating eight metres over a 20 degree
		# slope is a stand of trees nobody can hit.
		trees.add(Vector3(x, surface.height_at(x, -22.0), -22.0), 1.0, 6.0, 0)
	trees.build()

	var physics: RacePhysics = _sim(surface)
	physics.trees = trees
	# A one-element array, not an int: a GDScript lambda captures by value, so a
	# counter incremented inside one never reaches the caller and the assertion
	# passes on every run including the ones that should fail.
	var hits: Array[int] = [0]
	physics.tree_hit.connect(func(_pos: Vector3) -> void: hits[0] += 1)
	var ai: AIInputSource = _ai(AISkill.Level.HARD)
	ai.skill.wander_metres = 0.0
	_drive(ai, physics, 8.0)
	t.ok(physics.pos.z < -24.0,
		"the opponent got past the wall (reached %.0f m)" % -physics.pos.z)
	t.ok(hits[0] == 0, "without hitting any of it (%d hits)" % hits[0])

	# The control: the same eight seconds paddling straight ahead does hit it.
	# Without this the assertion above would pass on a course with no wall.
	var blind: RacePhysics = _sim(surface)
	blind.trees = trees
	var blind_hits: Array[int] = [0]
	blind.tree_hit.connect(func(_pos: Vector3) -> void: blind_hits[0] += 1)
	_drive(ScriptedInputSource.new("paddle"), blind, 8.0)
	t.ok(blind_hits[0] > 0, "and a racer that does not look ahead hits it")

## Two opponents that both want the same thing have to end up beside each other
## rather than inside each other. Nobody on this hill collides, so nothing else
## would keep them apart.
static func _rivals(t: TestCase) -> void:
	t.begin("opponents give each other room")
	var shared: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var sims: Array[RacePhysics] = [_sim(SlopeFixture.flat_slope(20.0)),
		_sim(SlopeFixture.flat_slope(20.0))]
	var sources: Array[AIInputSource] = []
	# Both seats given the same lane and the same personality, so the only thing
	# that can separate them is that each can see the other.
	for i: int in 2:
		var ai: AIInputSource = _ai(AISkill.Level.MEDIUM, 0)
		ai.skill.wander_metres = 0.0
		ai.rivals = shared
		ai.rival_index = i
		sources.push_back(ai)
	sims[1].init_at(45.4, -5.0)

	var input := RaceInput.new()
	for tick: int in int(10.0 / DT):
		for i: int in 2:
			shared[i] = sims[i].pos
		for i: int in 2:
			sources[i].poll(input, sims[i], DT)
			sims[i].step(input, DT)
	var apart: float = Vector2(sims[0].pos.x - sims[1].pos.x,
		sims[0].pos.z - sims[1].pos.z).length()
	t.ok(apart > 1.0, "two racers on one line separate (%.2f m apart)" % apart)

	# And the avoidance must not be self-avoidance: an opponent that read its own
	# entry would swerve away from where it already is, forever.
	var alone: AIInputSource = _ai(AISkill.Level.MEDIUM, 0)
	alone.skill.wander_metres = 0.0
	var solo: RacePhysics = _sim(SlopeFixture.flat_slope(20.0))
	var lonely: Array[Vector3] = [Vector3.ZERO]
	alone.rivals = lonely
	alone.rival_index = 0
	for tick: int in int(10.0 / DT):
		lonely[0] = solo.pos
		alone.poll(input, solo, DT)
		solo.step(input, DT)
	var blind: RacePhysics = _drive(_no_rivals(), _sim(SlopeFixture.flat_slope(20.0)), 10.0)
	t.eq_v(solo.pos, blind.pos, 1e-6,
		"a racer that can see only itself drives exactly as one that sees nobody")

static func _no_rivals() -> AIInputSource:
	var ai: AIInputSource = _ai(AISkill.Level.MEDIUM, 0)
	ai.skill.wander_metres = 0.0
	return ai

static func _determinism(t: TestCase) -> void:
	t.begin("a race replays the same way")
	# A field has to be reproducible for the same reason a ghost does: the
	# simulation is on a fixed tick and the only randomness an opponent has is
	# drawn once, from a seed, at construction.
	var a: RacePhysics = _drive(_ai(AISkill.Level.MEDIUM, 3), _sim(), 12.0)
	var b: RacePhysics = _drive(_ai(AISkill.Level.MEDIUM, 3), _sim(), 12.0)
	t.eq_v(a.pos, b.pos, 1e-9, "the same seat at the same skill drives the same line")

	# And two seats must not, or a field of nine is one racer drawn nine times.
	var other: RacePhysics = _drive(_ai(AISkill.Level.MEDIUM, 4), _sim(), 12.0)
	t.ok(other.pos.distance_to(a.pos) > 0.5,
		"and two seats drive different ones (%.2f m apart)" % other.pos.distance_to(a.pos))

	# A reset has to put the source back to the start of a run, or the second
	# race of an evening is not the first one.
	var source: AIInputSource = _ai(AISkill.Level.MEDIUM, 3)
	_drive(source, _sim(), 4.0)
	source.reset()
	t.eq_v(_drive(source, _sim(), 12.0).pos, a.pos, 1e-9, "and a reset rewinds it")

static func _finish(t: TestCase) -> void:
	t.begin("an opponent past the line")
	var physics: RacePhysics = _sim(SlopeFixture.flat_slope(20.0))
	physics.play_length = 30.0
	var ai: AIInputSource = _ai(AISkill.Level.HARD)
	_drive(ai, physics, 20.0)
	t.ok(physics.finished, "a short course is finished inside twenty seconds")

	# Past the line the simulation steers itself down the fall line and the
	# brake ramp is all that matters, so the opponent takes its hands off. An AI
	# still steering there would fight `_calc_finish_controls` for the wheel.
	var out := RaceInput.new()
	ai.poll(out, physics, DT)
	t.eq_f(out.stick_turn, 0.0, 1e-6, "and the opponent hands out no steering after it")
	t.ok(not out.paddling and not out.braking, "and neither paddles nor brakes")
