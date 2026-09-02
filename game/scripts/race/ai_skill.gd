## How well a computer opponent drives.
##
## [b]The three levels are not three physics models.[/b] [RacePhysics] is the
## same twenty-kilogram point mass for everyone on the hill — ETR has no
## per-character constants and neither does this, `characters.lst` carries no
## numbers and `[type]` is a column nothing reads — so the only thing a
## difficulty setting is allowed to move is the quality of the intent an
## [AIInputSource] produces. Everything below is therefore a driving habit
## rather than a multiplier: how far ahead the opponent looks, how often it
## looks, how much room it insists on around a tree, how fast it is willing to
## go, and how readily it scrubs speed off.
##
## That is what makes the ladder honest, and it is the same argument the whole
## racer layer rests on. An easy opponent is beatable because it brakes into
## corners it did not need to brake into and stops paddling at half the speed
## paddling still helps at — not because a force was divided by two behind the
## player's back. Race a hard one on a line it likes and it will beat a
## competent player; race it into a stand of trees and it loses the same time
## you do.
##
## Every field is public and every instance is a fresh copy, so a caller that
## wants a fourth level or one opponent with a habit of its own can build one
## without touching this table. [method AIInputSource.vary] does exactly that:
## it jitters a copy per seat so nine opponents at one level do not drive nine
## identical lines.
class_name AISkill
extends RefCounted

enum Level {
	## Looks a car's length ahead, reacts a sixth of a second late, gives up on
	## paddling at 25 km/h and brakes whenever the hill gets fast. Wanders.
	EASY,
	## Reads the slope properly and holds a line, but is cautious about speed
	## and takes a detour round a tree it could have carved past.
	MEDIUM,
	## Paddles for as long as paddling still does anything, brakes only when the
	## turn genuinely will not come round, and reads the terrain for the low
	## friction a packed or icy line offers.
	HARD,
}

## Names as `penguinracer.cfg` and `--difficulty=` spell them.
const NAMES: PackedStringArray = ["easy", "medium", "hard"]
## What the menus show. Not `tr()` keys: the original has no computer
## opponents, so there is nothing to migrate and a key would resolve to nothing
## in all thirteen languages — the same call already made for `ghost` and for
## the Configuration screen's *Race your best time*.
const LABELS: PackedStringArray = ["Easy", "Medium", "Hard"]

var level: Level = Level.MEDIUM

## Metres down the course the planner aims at. Short is not merely worse — it
## is late, which is what makes an easy opponent clip the tree it saw.
var lookahead: float = 20.0
## Simulation ticks between two plans, i.e. reaction time. Between plans the
## opponent steers at the aim point it last chose, so this is also how long it
## takes to notice that the aim point has become a bad idea.
var plan_interval: int = 5
## Heading error, in degrees, that asks for full lock. Smaller is more decisive.
var steer_span_deg: float = 26.0
## Metres of clear air the planner wants between its line and a trunk, on top of
## the tree's own radius. Too much is a detour; too little is a collision.
var tree_margin: float = 2.4
## Speed below which the opponent keeps paddling, m/s. Paddling stops helping at
## [constant PhysConst.MAX_PADDLING_SPEED] (16.67 m/s); anything lower than that
## is time given away.
var paddle_until: float = 12.0
## Speed above which the opponent brakes regardless, m/s. This is nerve, and it
## is the single biggest difference between the levels — an easy opponent is
## fast enough on the flat and loses the race on every steep pitch.
var comfort_speed: float = 19.0
## Heading error, in degrees, that makes the opponent brake to bring the nose
## round. Larger means it tries to carve the turn instead.
var brake_above_deg: float = 34.0
## Below this speed braking only costs time, so nobody does it. m/s.
var brake_floor: float = 6.0
## Metres of lateral weave the opponent adds to its own aim point. A racer that
## tracks a line to the millimetre reads as a machine, and the weave costs the
## time it looks like it costs.
var wander_metres: float = 1.6
## Seconds per weave cycle.
var wander_period: float = 7.0
## How much a low-friction line is worth. Packed snow and ice are faster here
## (see [SnowField]), and reading that off the terrain ahead is the last thing
## an opponent learns.
var line_greed: float = 0.5
## How far out of its way the opponent will go for a herring. Inverted on
## purpose: the fish are worth points and cost time, so it is the [i]easy[/i]
## opponent that chases them.
var herring_greed: float = 0.6

## A fresh, mutable copy of the table for [param level]. Fresh because
## [method AIInputSource.vary] jitters it per opponent and a shared instance
## would have every opponent jittering the same object.
static func for_level(level: Level) -> AISkill:
	var s := AISkill.new()
	s.level = level
	match level:
		Level.EASY:
			s.lookahead = 13.0
			s.plan_interval = 10
			s.steer_span_deg = 36.0
			s.tree_margin = 3.4
			s.paddle_until = 7.0
			s.comfort_speed = 12.0
			s.brake_above_deg = 20.0
			s.wander_metres = 3.4
			s.wander_period = 5.0
			s.line_greed = 0.0
			s.herring_greed = 1.0
		Level.MEDIUM:
			pass  # the defaults above are the middle of the ladder
		Level.HARD:
			s.lookahead = 28.0
			s.plan_interval = 3
			s.steer_span_deg = 18.0
			s.tree_margin = 1.9
			s.paddle_until = PhysConst.MAX_PADDLING_SPEED
			s.comfort_speed = 1e9
			s.brake_above_deg = 52.0
			s.wander_metres = 0.5
			s.wander_period = 9.0
			s.line_greed = 1.0
			s.herring_greed = 0.25
	return s

## `"hard"` → [constant Level.HARD]. Anything unrecognised is the middle of the
## ladder rather than an error: this reads a hand-edited settings file and a
## `--difficulty=` typo, and neither is worth refusing to race over.
static func parse(text: String) -> Level:
	match text.strip_edges().to_lower():
		"easy":
			return Level.EASY
		"hard":
			return Level.HARD
	return Level.MEDIUM

## The level at [param index] in [constant NAMES] / [constant LABELS], which is
## what a menu's [OptionButton] hands back. Spelled out rather than cast: an
## `int` that has been out of the enum and back is exactly how a widget id
## arrives, and there is no cast that also validates it.
static func level_at(index: int) -> Level:
	match index:
		0:
			return Level.EASY
		2:
			return Level.HARD
	return Level.MEDIUM

## The name [method parse] reads back, and what the settings file stores.
static func name_of(level: Level) -> String:
	return NAMES[clampi(level, 0, NAMES.size() - 1)]

## What a menu shows.
static func label_of(level: Level) -> String:
	return LABELS[clampi(level, 0, LABELS.size() - 1)]
