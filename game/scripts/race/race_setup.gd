## What kind of race the shell asked for: alone or against a field, and in what
## weather.
##
## Four numbers and nothing else, but they are the ones the shell has to carry
## across a scene swap and hand back afterwards, and a value object is cheaper
## to reason about than four more `static var`s on [RaceScene] beside
## [member RaceScene.requested_course_path].
##
## [b]Weather is here for the same reason the field is.[/b] ETR keeps
## `light_id`, `snow_id` and `wind_id` in `g_game` beside the course, all four
## set on the one screen (`CRaceSelect`) and read by whatever needs them; this
## is that object, and [CourseMenu] is that screen. All three are carried: the
## snow, the sky and the wind — the wind as the course screen's crosswind
## ([enum WindField.Strength]) rather than ETR's `events.lst` grade, which
## belongs to a cup race and is still `--wind=` only.
##
## Zero opponents is Practice — the mode the game had until now, and still the
## default. `--auto-input=` and every reference capture get it, which is what
## keeps a capture of Bunny Hill the same frame it was before opponents existed.
##
## [b]A network race is a third value and not a fourth object.[/b]
## [member networked] is a field on the same struct because everything the scene
## does with a field of opponents it also does with a field of peers — the
## standings, the place on the HUD, the finish-line clip chosen by place — and
## the one thing that differs (the opponents are [PlaybackRacer]s built from
## snapshots rather than [SimulatedRacer]s built here) is not a mode the scene
## has to know about. See [RaceNetwork].
class_name RaceSetup
extends RefCounted

## Nine, because the HUD shows a place out of the field and `1ST`..`10TH` is
## exactly what the imported string table has ordinals for. It is also about
## where the honest cost lands: ten simulated racers is ten [RacePhysics] on the
## tick, which the S2 benchmark puts at roughly half a millisecond a frame.
const MAX_OPPONENTS := 9

## Metres between two racers on the start line. The field is laid out either
## side of the course's own start point, so the player begins exactly where a
## practice run begins and the opponents fan out around them.
const LANE_SPACING := 3.0
## Metres of the play area kept clear at each edge when a lane is clamped into
## it, so a wide field on a narrow course does not start against the boundary.
const LANE_MARGIN := 2.5

var opponents: int = 0
var skill: AISkill.Level = AISkill.Level.MEDIUM
## Whether the field is other people rather than the computer. Set only by
## [LobbyMenu], through [member RaceScene.requested_setup]; never remembered in
## the settings file, because a network race is a room somebody is standing in
## and not a preference.
##
## Mutually exclusive with [member opponents] in practice — a race against real
## players does not also get computer ones — and nothing enforces it, because
## nothing needs to: [method networked_race] is the only constructor that sets
## it and it leaves the count at zero.
var networked: bool = false
## How hard it is snowing: ETR's `g_game.snow_id`, 0 (none) to
## [constant SnowFall.MAX_GRADE]. Presentation only — see [SnowFall]. Zero is
## the default and every reference capture, which is why the flag and the
## settings key both have to name a grade to get one.
var snowfall: int = 0
## What the sky is doing: ETR's `g_game.light_id`. Presentation only in the same
## way the snow is — see [LightCondition] — except that it also decides whether
## anything casts a shadow, which is the original's own rule rather than an
## addition.
##
## [constant LightCondition.Kind.SUNNY] is the default and every reference
## capture, and it is what all 44 courses select when nobody says otherwise.
var conditions: LightCondition.Kind = LightCondition.Kind.SUNNY
## How hard the crosswind blows — see [WindField]. Unlike the other two halves
## of the weather this one reaches the simulation, if only in flight, which is
## why it comes with a seed: every racer on the hill (and every machine in a
## network race) has to feel the same gusts from the same side.
##
## [constant WindField.Strength.NONE] is the default and every reference capture.
var wind: WindField.Strength = WindField.Strength.NONE
## What the wind is seeded with, or [constant ROLL_WIND_SEED] for a fresh roll
## — and so a fresh side — on every start. A network race is handed the
## server's; a scripted run a fixed one, or its captures would not reproduce.
var wind_seed: int = ROLL_WIND_SEED

const ROLL_WIND_SEED := -1

static func practice() -> RaceSetup:
	return RaceSetup.new()

static func against(count: int, level: AISkill.Level) -> RaceSetup:
	var s := RaceSetup.new()
	s.opponents = clampi(count, 0, MAX_OPPONENTS)
	s.skill = level
	return s

## A race against whoever else is in the room. The field is not built here —
## it arrives one [PlaybackRacer] per peer as the snapshots do.
static func networked_race() -> RaceSetup:
	var s := RaceSetup.new()
	s.networked = true
	return s

## The same setup with [member snowfall] set. A builder rather than an argument
## on the two constructors above, because the weather is orthogonal to the field
## and every caller that sets one leaves the other alone.
func in_snow(grade: int) -> RaceSetup:
	snowfall = clampi(grade, 0, SnowFall.MAX_GRADE)
	return self

## The same setup under [param kind]. A second builder for the second half of
## the weather, and chainable with [method in_snow] for the same reason: a
## caller that sets one usually leaves the other alone.
func under_sky(kind: LightCondition.Kind) -> RaceSetup:
	conditions = LightCondition.of(kind)
	return self

## The same setup in [param level] of wind, seeded by [param seed_value] — or
## rolled afresh on every start when it is [constant ROLL_WIND_SEED]. The third
## weather builder.
func in_wind(level: WindField.Strength, seed_value: int = ROLL_WIND_SEED) -> RaceSetup:
	wind = WindField.strength_of(level)
	wind_seed = seed_value
	return self

## Whether there is anyone else on the hill to beat. True for a network race
## before anybody has connected, which is deliberate: the HUD draws standings
## and the results screen reports a place, and both are right for a race of one
## that other people are about to join.
func is_race() -> bool:
	return opponents > 0 or networked

## Whether two setups would produce the same field. What [RaceScene] uses to
## decide whether picking a course from the in-race menu has to rebuild the
## opponents or can just put everyone back on the start line.
##
## The weather — [member snowfall], [member conditions], [member wind] — is deliberately not
## part of it: the weather is not the field, and rebuilding nine [RacePhysics]
## because the player asked for heavier snow or a darker sky would throw away
## the opponents for a change none of them can see.
func matches(other: RaceSetup) -> bool:
	return other != null and other.opponents == opponents and other.skill == skill \
		and other.networked == networked

func copy() -> RaceSetup:
	var s: RaceSetup = RaceSetup.against(opponents, skill).in_snow(snowfall) \
		.under_sky(conditions).in_wind(wind, wind_seed)
	s.networked = networked
	return s

## Where seat [param index] starts, relative to the course's own start point.
##
## Alternating out from the middle, so seat zero — the player — keeps the
## authored start position however many opponents there are, and the field is
## symmetrical about it. Here rather than on [RaceScene] because it is a
## property of the field and not of the scene, and because a headless test can
## reach it without dragging a [Node3D] full of autoload references in with it.
static func lane_offset(index: int) -> float:
	var step: float = float(index / 2 + 1) * LANE_SPACING
	return step if index % 2 == 0 else -step

## A start-line x pulled inside [param bounds].
##
## A field ten wide is twenty metres of start line, and not every course has
## twenty metres to spare either side of its start point. Clamping stacks the
## outermost seats against the edge rather than starting them out of bounds,
## which the simulation would fix on the first tick by teleporting them sideways.
static func lane_x(x: float, bounds: PackedVector2Array) -> float:
	if bounds.is_empty():
		return x
	var lo: float = INF
	var hi: float = -INF
	for p: Vector2 in bounds:
		lo = minf(lo, p.x)
		hi = maxf(hi, p.x)
	if hi - lo < LANE_MARGIN * 2.0:
		return (lo + hi) * 0.5
	return clampf(x, lo + LANE_MARGIN, hi - LANE_MARGIN)

## One line for the logs and the HUD's opening print.
func describe() -> String:
	var weather: String = "" if snowfall <= 0 else ", snow %d" % snowfall
	if conditions != LightCondition.Kind.SUNNY:
		weather += ", %s" % LightCondition.name_of(conditions)
	if wind != WindField.Strength.NONE:
		weather += ", %s wind" % WindField.strength_name(wind)
	if networked:
		return "network race%s" % weather
	if not is_race():
		return "practice%s" % weather
	return "%d opponents, %s%s" % [opponents, AISkill.name_of(skill), weather]
