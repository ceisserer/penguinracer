## What the sky is doing: ETR's `g_game.light_id`, and the first of the three
## weather controls its race-select screen offers.
##
## [b]A course names a place, not a time of day.[/b] `courses.lst` carries
## `[env] etr` or `[env] tuxracer` — a location, with three or four skies
## authored under it in `env/<location>/<light>/` — and the light is chosen per
## race: from `events.lst` in a cup, and from the race screen everywhere else.
## The importer therefore selects `<location>_sunny` for a course and this
## class swaps in one of the others, which is why [member CourseData.environment_preset]
## is the course's *default* sky rather than its only one.
##
## Three of the original's four are offered. `evening` is imported, fitted by
## the same rule as the other two and reachable by hand from the Inspector; it
## is not on the course screen because nothing asked for it, and adding it is
## one entry in [constant NAMES] and one in [constant LABELS].
##
## [b]Presentation only[/b], exactly like [SnowFall]: no racer drives
## differently under a night sky, the surface is the same surface, and the
## simulation never hears which of these is set. What it does move is the
## lighting — and, through [member EnvironmentPreset.casts_shadows], whether
## anything on the hill casts a shadow at all, which is the original's own rule
## (`CCharShape::DrawShadow` returns immediately under `light_id` 1 and 3).
class_name LightCondition
extends RefCounted

## Indexed the way ETR's `lightcond` is, so [constant Kind.CLOUDY] is 1 and
## [constant Kind.NIGHT] is 3 there as well. `EVENING` is the gap at 2: the
## data is imported, the menu does not offer it.
enum Kind {
	## `light.lst`'s brightest: a white sun over a blue sky, the only one all 44
	## shipped courses select, and the one the tone match was measured on.
	SUNNY = 0,
	## Grey and flat. The sun is a fill light rather than a source — `[diff]`
	## drops to 0.45 and the ambient rises to meet it — and nothing casts a
	## shadow, which is the original's rule and not a simplification.
	CLOUDY = 1,
	## Blue, dark and clipped: `[amb] 0 0.09 0.34` under a `[diff]` of
	## 0.39/0.51/0.88, so lit snow saturates in blue while red is still at half
	## scale. No shadows here either.
	NIGHT = 3,
}

## The order the three are offered in, which is the order they are named in
## `env/environment.lst` and in the settings file.
const KINDS: Array[Kind] = [Kind.SUNNY, Kind.CLOUDY, Kind.NIGHT]

## As `penguinracer.cfg` and `--light=` spell them — the original's own
## directory names under `env/<location>/`.
const NAMES: PackedStringArray = ["sunny", "cloudy", "night"]
## What the course screen shows. Not `tr()` keys: ETR says this with a
## four-state icon and has no words for it in any of the thirteen translations,
## so a key would resolve to nothing everywhere. Same standing as the snowfall
## grades beside them.
const LABELS: PackedStringArray = ["Sunny", "Cloudy", "Night"]

## Every light a location can have authored under it, including the one that is
## not offered. Used to read the location back off a preset id.
const ALL_NAMES: PackedStringArray = ["sunny", "cloudy", "evening", "night"]

const PRESET_DIR := "res://resources/environments"

## `"night"` → [constant Kind.NIGHT]. Anything unrecognised is sunny rather than
## an error: this reads a hand-edited settings file, a `--light=` typo and a
## number off the wire, and none of the three is worth refusing to race over.
static func parse(text: String) -> Kind:
	var index: int = NAMES.find(text.strip_edges().to_lower())
	return KINDS[index] if index >= 0 else Kind.SUNNY

## A [enum Kind] that has been out of the enum and back — a widget id, a
## settings int, a field on a room. Spelled out rather than cast, for the reason
## [method AISkill.level_at] gives: there is no cast that also validates.
static func of(value: int) -> Kind:
	match value:
		Kind.CLOUDY:
			return Kind.CLOUDY
		Kind.NIGHT:
			return Kind.NIGHT
	return Kind.SUNNY

## The position of [param kind] in [constant NAMES] / [constant LABELS] — where
## a list offers it, which is not its value, since [constant Kind.NIGHT] is 3.
static func index_of(kind: Kind) -> int:
	var at: int = KINDS.find(of(kind))
	return at if at >= 0 else 0

## The name [method parse] reads back, and what the settings file stores.
static func name_of(kind: Kind) -> String:
	return NAMES[index_of(kind)]

## What the course screen shows.
static func label_of(kind: Kind) -> String:
	return LABELS[index_of(kind)]

## The same sky as [param preset], at time of day [param kind].
##
## [param preset] is the course's own — `<location>_sunny`, as the importer set
## it — and this returns the preset for the same location under another light,
## or [param preset] itself when there is nothing to change or nothing to change
## it to. A missing file is a legitimate answer rather than a warning: a
## narrowed export ships what it needs, and a course lit by the wrong time of
## day is a far better outcome than a race that will not load.
static func preset_for(preset: EnvironmentPreset, kind: Kind) -> EnvironmentPreset:
	if preset == null:
		return null
	var location: String = location_of(preset)
	if location.is_empty():
		return preset
	var wanted: String = "%s_%s" % [location, name_of(kind)]
	if wanted == String(preset.id):
		return preset
	var path: String = PRESET_DIR.path_join("%s.tres" % wanted)
	if not ResourceLoader.exists(path):
		return preset
	var found: EnvironmentPreset = load(path) as EnvironmentPreset
	return found if found != null else preset

## `etr_sunny` → `etr`. Empty for an id that names no light at all, which is an
## authored preset rather than a migrated one and has no siblings to swap to.
static func location_of(preset: EnvironmentPreset) -> String:
	var id: String = String(preset.id)
	for light: String in ALL_NAMES:
		var suffix: String = "_%s" % light
		if id.ends_with(suffix):
			return id.trim_suffix(suffix)
	return ""
