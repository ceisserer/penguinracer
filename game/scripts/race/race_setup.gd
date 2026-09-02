## What kind of race the shell asked for: alone, or against a field.
##
## Two numbers and nothing else, but they are the two the shell has to carry
## across a scene swap and hand back afterwards, and a value object is cheaper
## to reason about than a second and third `static var` on [RaceScene] beside
## [member RaceScene.requested_course_path].
##
## Zero opponents is Practice — the mode the game had until now, and still the
## default. `--auto-input=` and every reference capture get it, which is what
## keeps a capture of Bunny Hill the same frame it was before opponents existed.
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

static func practice() -> RaceSetup:
	return RaceSetup.new()

static func against(count: int, level: AISkill.Level) -> RaceSetup:
	var s := RaceSetup.new()
	s.opponents = clampi(count, 0, MAX_OPPONENTS)
	s.skill = level
	return s

## Whether there is anyone else on the hill to beat.
func is_race() -> bool:
	return opponents > 0

## Whether two setups would produce the same field. What [RaceScene] uses to
## decide whether picking a course from the in-race menu has to rebuild the
## opponents or can just put everyone back on the start line.
func matches(other: RaceSetup) -> bool:
	return other != null and other.opponents == opponents and other.skill == skill

func copy() -> RaceSetup:
	return RaceSetup.against(opponents, skill)

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
	if not is_race():
		return "practice"
	return "%d opponents, %s" % [opponents, AISkill.name_of(skill)]
