## Minimal in-race HUD: time, speed, herring. Enough to read the simulation
## while the shell (Phase 5) is still to come.
class_name RaceHUD
extends CanvasLayer

@export var race: RaceScene

var _label: Label

func _ready() -> void:
	if race == null:
		race = get_parent() as RaceScene
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)

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
		return
	var speed_kmh: float = race.physics.vel.length() * 3.6
	_label.text = "%.2f s   %5.1f km/h   herring %d%s" % [
		race.race_time, speed_kmh, race.herring,
		"   FINISH" if race.physics.finished else ""]
