## Minimal in-race HUD: time, speed, herring, and who else is on the hill.
## Enough to read the simulation while the shell (Phase 5) is still to come.
class_name RaceHUD
extends CanvasLayer

## Ahead of the ghost is green, behind it is the same amber the menus give
## whatever has focus. Both stay legible over snow, which most colours do not.
const AHEAD_COLOR := Color(0.55, 1.0, 0.6)
const BEHIND_COLOR := Color(1.0, 0.83, 0.3)

@export var race: RaceScene

var _label: Label
## Second line: the ghost delta, or the other racers, or nothing. Its own label
## because it is the one thing here that changes colour.
var _status: Label

func _ready() -> void:
	if race == null:
		race = get_parent() as RaceScene
	_label = _make_label(Vector2(16, 12), 20)
	_status = _make_label(Vector2(16, 38), 18)

func _make_label(at: Vector2, size: int) -> Label:
	var label := Label.new()
	label.position = at
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(label)
	return label

func _process(_delta: float) -> void:
	if race == null or race.physics == null:
		return
	# The course menu draws over the same corner, and a frozen time and speed
	# behind it read as a bug.
	visible = not race.paused
	if not visible:
		return
	# DEVIATION: the original draws its ordinary HUD over the start animation and
	# says nothing about the fact that any key skips it. The string is one of the
	# migrated ones — it is what ETR puts under its splash screen — and a
	# four-and-a-half second wait nobody knows they can cut short is worse than a
	# line of text.
	if race.intro_running:
		_label.text = tr("PRESS_ANY_KEY_TO_START")
		_status.text = ""
		return
	var speed_kmh: float = race.physics.vel.length() * 3.6
	_label.text = "%.2f s   %5.1f km/h   herring %d%s" % [
		race.race_time, speed_kmh, race.herring,
		"   FINISH" if race.physics.finished else ""]
	_update_status()

## The ghost delta if there is a ghost, otherwise where the player is in the
## field.
##
## Never both: two numbers on one line, one of them signed and one of them not,
## is a line nobody reads at 60 km/h. Which one it is decides itself — a race
## against opponents does not draw a ghost (see
## [method RaceScene._setup_ghost]), so [method RaceScene.ghost_delta] is
## infinite there and the standings take the line.
func _update_status() -> void:
	var delta: float = race.ghost_delta()
	if is_finite(delta):
		_status.text = "%s %+.2f s" % [RaceScene.GHOST_LABEL, delta]
		_status.add_theme_color_override("font_color",
			BEHIND_COLOR if delta > 0.0 else AHEAD_COLOR)
		return
	if race.racers.size() < 2:
		_status.text = ""
		return
	_show_standings()

## Where the player is, and who is either side of them.
##
## Not the whole field: ten names on one line is a line nobody reads, and the
## only rows that change how you drive are the one you are chasing and the one
## chasing you. The gap is metres down the course rather than seconds, because
## metres is what [member RacerState.progress] holds for everybody — a racer who
## has not reached your point yet has no time to be compared against, which is
## the thing that makes a ghost delta a different measurement from this one.
func _show_standings() -> void:
	var ordered: Array[Racer] = race.standings()
	var place: int = ordered.find(race.local) + 1
	if place < 1:
		_status.text = ""
		return
	_status.add_theme_color_override("font_color",
		AHEAD_COLOR if place == 1 else Color.WHITE)
	var parts := PackedStringArray(["%d / %d" % [place, ordered.size()]])
	if place > 1:
		parts.push_back(_gap_line("↑", ordered[place - 2]))
	if place < ordered.size():
		parts.push_back(_gap_line("↓", ordered[place]))
	_status.text = "    ".join(parts)

func _gap_line(arrow: String, other: Racer) -> String:
	return "%s %s %.0f m" % [arrow, other.display_name,
		absf(other.state.progress - race.local.state.progress)]
