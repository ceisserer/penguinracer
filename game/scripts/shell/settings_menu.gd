## The options screen `penguinracer.cfg` was always written for.
##
## ETR's `options.txt` has two halves — the keys its configuration screen can
## also set, and the keys only the file carries — and [GameConfig] started as
## the second half because there was no screen. This is the screen, and it moves
## every key a player can act on today: window size, fullscreen, render scale,
## whether ice reflects the racers, whether anything casts a shadow, and the two
## fog distances. Nothing else lands here; a value migrated out of
## `etr-0.8.4/data` belongs on a resource, not in a settings panel.
##
## Two keys are deliberately file-only for now — `[multiplayer] player_name` and
## `port`. A name you cannot see anyone use and a port with no session to open
## are settings for a screen that does not exist yet; they arrive here with the
## lobby. See [RaceNetwork].
##
## Editing is transactional. The widgets hold a copy, [b]Ok[/b] writes it to
## [GameConfig], applies the display half and saves the file, [b]Cancel[/b]
## throws it away. Nothing is applied while a slider is being dragged, because
## half the settings can only be seen on a course — fog is read when a race
## builds its [Environment], so a change to it shows up on the next race rather
## than instantly. That is also why this screen hangs off [MainMenu] and not off
## the in-race menu.
class_name SettingsMenu
extends CanvasLayer

## Closed, one way or the other. The main menu takes its focus back.
signal closed()

## Every slider's range is the range [method GameConfig.read] would clamp a
## hand-edited value to, deliberately: a screen that cannot express what the
## file can would silently narrow someone's settings the first time they pressed
## Ok. The one exception is the fog start, which the file only floors at zero and
## which stops here at 200 m — further than the far plane of any course.
##
## What the drop-down offers under "Auto" ([constant Vector2i.ZERO], where the
## platform sizes the window): the modes of the display the window is on, from
## [DisplayModes], not a fixed list.
@onready var _title: Label = %Title
@onready var _resolution_label: Label = %ResolutionLabel
@onready var _fullscreen_label: Label = %FullscreenLabel
@onready var _path_label: Label = %Path
@onready var _resolution_row: Control = %ResolutionRow
@onready var _resolution: OptionButton = %ResolutionOption
@onready var _fullscreen_row: Control = %FullscreenRow
@onready var _fullscreen: CheckBox = %FullscreenCheck
@onready var _render_scale: HSlider = %RenderScaleSlider
@onready var _render_scale_value: Label = %RenderScaleValue
@onready var _ice_reflection_label: Label = %IceReflectionLabel
@onready var _ice_reflection: CheckBox = %IceReflectionCheck
@onready var _shadows_row: Control = %ShadowsRow
@onready var _shadows_label: Label = %ShadowsLabel
@onready var _shadows: CheckBox = %ShadowsCheck
@onready var _fog_start: HSlider = %FogStartSlider
@onready var _fog_start_value: Label = %FogStartValue
@onready var _fog_scale: HSlider = %FogScaleSlider
@onready var _fog_scale_value: Label = %FogScaleValue
@onready var _ok_button: Button = %OkButton
@onready var _cancel_button: Button = %CancelButton

func _ready() -> void:
	_title.text = tr("CONFIGURATION")
	_resolution_label.text = tr("RESOLUTION")
	_fullscreen_label.text = tr("FULLSCREEN")
	# Neither migrated nor keyed, like `ghost` and *Race the computer*: ETR
	# reflects nothing, so there is no string to migrate and a `tr()` key would
	# resolve to nothing in all 13 languages.
	_ice_reflection_label.text = "Ice reflections:"
	_shadows_label.text = "Shadows:"
	_ok_button.text = tr("OK")
	_cancel_button.text = tr("CANCEL")
	_path_label.text = ProjectSettings.globalize_path(GameConfig.PATH)

	# The page sizes the canvas in a browser build, and `apply_display` knows it
	# — offering the two controls there would be offering two dead knobs.
	var on_web: bool = OS.has_feature("web")
	_resolution_row.visible = not on_web
	_fullscreen_row.visible = not on_web
	# And the same argument for the shadows row. The browser runs the
	# Compatibility renderer, where a shadow-casting light is drawn in a second,
	# sRGB-blended pass that wrecks the whole frame — so [RaceScene] refuses
	# there whatever this says, and offering the switch would be offering a
	# third dead knob. Asked of [RenderBackend] rather than of `web`, so a
	# desktop run started with `--rendering-method gl_compatibility` — which is
	# how the web look gets checked without a browser — hides it too.
	_shadows_row.visible = RenderBackend.supports_light_shadows()

	_render_scale.value_changed.connect(_on_render_scale_changed)
	_fog_start.value_changed.connect(_on_fog_start_changed)
	_fog_scale.value_changed.connect(_on_fog_scale_changed)
	_ok_button.pressed.connect(_accept)
	_cancel_button.pressed.connect(_cancel)
	visible = false

## Fill the widgets from the live settings and show the panel. Reading on every
## open rather than once in [method _ready] is what makes Cancel free: the
## discarded edit is only ever in the widgets.
func open() -> void:
	if _resolution_row.visible:
		_fill_resolutions(Config.resolution)
	_fullscreen.button_pressed = Config.fullscreen
	_render_scale.value = Config.render_scale
	_ice_reflection.button_pressed = Config.ice_reflections
	_shadows.button_pressed = Config.shadows
	_fog_start.value = Config.fog_start_distance
	_fog_scale.value = Config.fog_distance_scale
	# `value_changed` does not fire when the value assigned is the one already
	# there, so the labels are refreshed by hand rather than as a side effect.
	_on_render_scale_changed(_render_scale.value)
	_on_fog_start_changed(_fog_start.value)
	_on_fog_scale_changed(_fog_scale.value)
	visible = true
	if _resolution_row.visible:
		_resolution.grab_focus()
	else:
		_render_scale.grab_focus()

func _fill_resolutions(current: Vector2i) -> void:
	var sizes: Array[Vector2i] = DisplayModes.for_current_screen(current)
	_resolution.clear()
	for i: int in sizes.size():
		_resolution.add_item(_size_label(sizes[i]), i)
		_resolution.set_item_metadata(i, sizes[i])
		if sizes[i] == current:
			_resolution.select(i)

## What a row of the drop-down says. Godot's own `--resolution` spells it
## `WIDTHxHEIGHT`; this is the same size with room to breathe.
func _size_label(size: Vector2i) -> String:
	if size == Vector2i.ZERO:
		return tr("AUTO")
	return "%d x %d" % [size.x, size.y]

func _on_render_scale_changed(value: float) -> void:
	# The number in the file is a fraction; the number a player recognises is a
	# percentage and the pixels it actually renders.
	var base: Vector2i = Config.resolution if Config.resolution != Vector2i.ZERO \
		else get_tree().root.size
	_render_scale_value.text = "%d %%   (%d x %d)" % [roundi(value * 100.0),
		roundi(base.x * value), roundi(base.y * value)]

func _on_fog_start_changed(value: float) -> void:
	_fog_start_value.text = "%d m" % roundi(value)

func _on_fog_scale_changed(value: float) -> void:
	_fog_scale_value.text = "%.1f x" % value

func _accept() -> void:
	if _resolution_row.visible:
		Config.resolution = _resolution.get_selected_metadata()
		Config.fullscreen = _fullscreen.button_pressed
	Config.render_scale = _render_scale.value
	Config.ice_reflections = _ice_reflection.button_pressed
	# Written back even when the row is hidden, which is what keeps a settings
	# file edited on a desktop from being flattened by a run in a browser: the
	# widget was filled from the file either way, so this writes back what was
	# read.
	Config.shadows = _shadows.button_pressed
	Config.fog_start_distance = _fog_start.value
	Config.fog_distance_scale = _fog_scale.value
	Config.apply_display()
	Config.save()
	_close()

func _cancel() -> void:
	_close()

func _close() -> void:
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("menu"):
		return
	get_viewport().set_input_as_handled()
	_cancel()
