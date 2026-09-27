## The race's on-screen controls, for a phone or a tablet.
##
## [b]A button is a key.[/b] Every held control here presses the same action a
## key does ([method Input.action_press]), so [LocalInputSource] and
## [KeyHoldFilter] read a thumb exactly as they read a keyboard — on the tick,
## through the same action map — and a recording made with one replays the same
## as with the other. The two tap controls, pause and menu, send the action as
## an event ([method Input.parse_input_event]), because [RaceScene] hears `P`
## and Esc as events rather than polling them.
##
## [b]Which buttons[/b] is [enum TouchScheme.Kind]'s question. With tilt, the
## device steers, paddles and brakes ([TiltSteering]) and only jump, the trick
## modifier, pause and menu are drawn — plus a small level at the bottom showing
## what the tilt is doing, since a tilt has no feel of its own to go by. With
## buttons, all of them. And if tilt was asked for but no reading has ever
## arrived — a browser that was refused motion access, a desktop with
## `--touch=tilt` — the steering buttons come back rather than leaving the
## player with no way to turn.
##
## [b]Multi-touch, and a thumb can slide.[/b] Each finger is tracked by its
## index, and which buttons are held is recomputed from where every finger is
## now: sliding a thumb from left to right steers the other way without lifting
## it, and two thumbs hold two buttons.
##
## [b]Placed around the HUD, not over it.[/b] Steering sits above the wind rose,
## jump and brake left of the gauge, paddle and the trick modifier above them,
## pause and menu under the herring count — all measured back from the edge they
## belong to, like [RaceHUD]'s own anchors, so a 4:3 tablet and a 21:9 phone both
## keep them in the corners. [method layout] is static for [TestTouch], which
## checks none of them covers a piece of the HUD on any of those canvases.
##
## Built by [RaceScene] in code, like [IceReflection]: nothing to place in an
## editor. Icons are primitives, so there is no string to translate and no art
## for the licence audit.
##
## DEVIATION: ETR is keyboard-only.
class_name TouchControls
extends CanvasLayer

enum Id { LEFT, RIGHT, PADDLE, BRAKE, JUMP, TRICK, PAUSE, MENU }

## The action each button presses. Pause and menu are taps, not holds.
const ACTIONS: Dictionary[Id, StringName] = {
	Id.LEFT: &"steer_left", Id.RIGHT: &"steer_right", Id.PADDLE: &"paddle",
	Id.BRAKE: &"brake", Id.JUMP: &"jump", Id.TRICK: &"trick_modifier",
	Id.PAUSE: &"pause", Id.MENU: &"menu",
}
const TAPS: Array[Id] = [Id.PAUSE, Id.MENU]
## The buttons tilt replaces.
const TILTED: Array[Id] = [Id.LEFT, Id.RIGHT, Id.PADDLE, Id.BRAKE]

## A finger this far outside a button's circle still holds it: a thumb is not
## a mouse pointer, and it drifts while racing.
const TOUCH_SLACK := 1.15

const FILL := Color(0.0, 0.0, 0.0, 0.28)
const FILL_HELD := Color(1.0, 0.8, 0.0, 0.45)
const EDGE := Color(1.0, 1.0, 1.0, 0.7)
const ICON := Color(1.0, 1.0, 1.0, 0.9)
const EDGE_WIDTH := 3.0

## The tilt level: centred along the bottom, clear of the gauge and the rose.
const LEVEL_HALF_WIDTH := 110.0
const LEVEL_FROM_BOTTOM := 34.0

@export var race: RaceScene
var scheme: TouchScheme.Kind = TouchScheme.Kind.OFF

var _face: Control
## Finger index → where it is on the canvas.
var _touches: Dictionary[int, Vector2] = {}
## Which hold buttons are pressed now, so a change can be told from a repeat.
var _held: Dictionary[Id, bool] = {}
## A real mouse stands in for finger −1 when the overlay is forced on a desktop.
var _mouse_down: bool = false

func _ready() -> void:
	layer = 5
	_face = Control.new()
	_face.set_anchors_preset(Control.PRESET_FULL_RECT)
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.draw.connect(_on_face_draw)
	add_child(_face)
	# Idempotent; normally done at startup by [GameConfig]. Here too for a
	# scheme switched on from the settings screen since.
	MotionSensor.install()

## Where every button goes on a [param canvas]-sized screen, and how big: `Id →
## Vector3(x, y, radius)`. Every button, whichever are drawn.
static func layout(canvas: Vector2) -> Dictionary[Id, Vector3]:
	var w: float = canvas.x
	var h: float = canvas.y
	return {
		Id.LEFT: Vector3(105.0, h - 215.0, 78.0),
		Id.RIGHT: Vector3(285.0, h - 215.0, 78.0),
		Id.JUMP: Vector3(w - 250.0, h - 120.0, 80.0),
		Id.BRAKE: Vector3(w - 425.0, h - 95.0, 62.0),
		Id.PADDLE: Vector3(w - 175.0, h - 300.0, 62.0),
		Id.TRICK: Vector3(w - 360.0, h - 275.0, 50.0),
		Id.MENU: Vector3(w - 122.0, 95.0, 32.0),
		Id.PAUSE: Vector3(w - 45.0, 95.0, 32.0),
	}

## Which buttons are drawn under [param kind]. [param tilt_live] is whether the
## sensor has ever answered; [param networked] drops pause, which a shared race
## does not have; [param key_paused] leaves only pause, to come back with.
static func shown(kind: TouchScheme.Kind, tilt_live: bool, networked: bool,
		key_paused: bool) -> Array[Id]:
	var out: Array[Id] = []
	if kind == TouchScheme.Kind.OFF:
		return out
	if key_paused:
		out.append(Id.PAUSE)
		return out
	for id: Id in Id.values():
		if id in TILTED and kind == TouchScheme.Kind.TILT and tilt_live:
			continue
		if id == Id.PAUSE and networked:
			continue
		out.append(id)
	return out

func _process(_delta: float) -> void:
	var active: bool = _is_active()
	if visible != active:
		visible = active
		if not active:
			_touches.clear()
			_mouse_down = false
			_update_held()
	if visible:
		_face.queue_redraw()

## Up only while there is a race to drive: not over the course menu or the
## results (the race is paused and not by `P`), not over the start animation
## (where any touch skips it, as any key does).
func _is_active() -> bool:
	if scheme == TouchScheme.Kind.OFF or race == null or race.physics == null:
		return false
	if race.intro_running:
		return false
	return not race.paused or race.key_paused

func _notification(what: int) -> void:
	# A finger lifted while the app was in the background never sends its
	# release; nothing may stay held across that.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_touches.clear()
		_mouse_down = false
		_update_held()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	var tapped: Variant = null
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touches[touch.index] = touch.position
			tapped = _button_at(touch.position)
		else:
			_touches.erase(touch.index)
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_touches[drag.index] = drag.position
	elif event is InputEventMouseButton and _takes_mouse(event):
		var click := event as InputEventMouseButton
		if click.button_index != MOUSE_BUTTON_LEFT:
			return
		_mouse_down = click.pressed
		if click.pressed:
			_touches[-1] = click.position
			tapped = _button_at(click.position)
		else:
			_touches.erase(-1)
	elif event is InputEventMouseMotion and _takes_mouse(event) and _mouse_down:
		_touches[-1] = (event as InputEventMouseMotion).position
	else:
		return
	if tapped != null:
		get_viewport().set_input_as_handled()
		if tapped in TAPS:
			_tap(ACTIONS[tapped])
	_update_held()

## A real mouse, on a desktop the overlay was forced onto. Never on a phone,
## where Godot also sends a mouse event for every touch and a tap would land
## twice — pause, pressed twice, is no pause.
func _takes_mouse(event: InputEvent) -> bool:
	return event.device != InputEvent.DEVICE_ID_EMULATION \
		and not TouchScheme.platform_is_mobile()

func _tap(action: StringName) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventAction.new()
		event.action = action
		event.pressed = pressed
		Input.parse_input_event(event)

## The drawn button under [param at], or null.
func _button_at(at: Vector2) -> Variant:
	var places: Dictionary[Id, Vector3] = layout(_face.size)
	for id: Id in _shown_now():
		var place: Vector3 = places[id]
		if at.distance_to(Vector2(place.x, place.y)) <= place.z * TOUCH_SLACK:
			return id
	return null

## Press what is under a finger and release what no longer is.
func _update_held() -> void:
	var now: Dictionary[Id, bool] = {}
	for at: Vector2 in _touches.values():
		var id: Variant = _button_at(at)
		if id != null and not (id in TAPS):
			now[id] = true
	for id: Id in _held.keys():
		if not now.has(id):
			Input.action_release(ACTIONS[id])
	for id: Id in now.keys():
		if not _held.has(id):
			Input.action_press(ACTIONS[id])
	_held = now

func _tilt() -> TiltSteering:
	if race == null or race.roster == null or race.roster.local == null:
		return null
	var source := race.roster.local.input_source as LocalInputSource
	return source.tilt if source != null else null

func _shown_now() -> Array[Id]:
	var tilt: TiltSteering = _tilt()
	var networked: bool = race.setup != null and race.setup.networked
	return shown(scheme, tilt != null and tilt.has_data, networked, race.key_paused)

# ==================================================================
#                              drawing
# ==================================================================

func _on_face_draw() -> void:
	var size: Vector2 = _face.size
	var places: Dictionary[Id, Vector3] = layout(size)
	for id: Id in _shown_now():
		var place: Vector3 = places[id]
		var center := Vector2(place.x, place.y)
		_face.draw_circle(center, place.z, FILL_HELD if _held.has(id) else FILL)
		_face.draw_arc(center, place.z, 0.0, TAU, 48, EDGE, EDGE_WIDTH, true)
		_draw_icon(id, center, place.z * 0.42)
	var tilt: TiltSteering = _tilt()
	if tilt != null and tilt.has_data and not race.key_paused:
		_draw_level(size, tilt)

func _draw_icon(id: Id, c: Vector2, s: float) -> void:
	match id:
		Id.LEFT:
			_triangle(c + Vector2(-s, 0), c + Vector2(s * 0.6, -s), c + Vector2(s * 0.6, s))
		Id.RIGHT:
			_triangle(c + Vector2(s, 0), c + Vector2(-s * 0.6, -s), c + Vector2(-s * 0.6, s))
		Id.PADDLE:
			_chevron(c + Vector2(0, -s * 0.45), s, -1.0)
			_chevron(c + Vector2(0, s * 0.45), s, -1.0)
		Id.BRAKE:
			_chevron(c + Vector2(0, -s * 0.45), s, 1.0)
			_chevron(c + Vector2(0, s * 0.45), s, 1.0)
		Id.JUMP:
			_triangle(c + Vector2(0, -s), c + Vector2(-s * 0.8, 0), c + Vector2(s * 0.8, 0))
			_face.draw_rect(Rect2(c + Vector2(-s * 0.8, s * 0.45), Vector2(s * 1.6, s * 0.4)), ICON)
		Id.TRICK:
			_face.draw_arc(c, s * 0.8, deg_to_rad(-60.0), deg_to_rad(210.0), 24, ICON, 5.0, true)
			var tip: Vector2 = c + Vector2.from_angle(deg_to_rad(-60.0)) * s * 0.8
			_triangle(tip + Vector2(s * 0.45, s * 0.1), tip + Vector2(-s * 0.25, -s * 0.35),
				tip + Vector2(-s * 0.05, s * 0.5))
		Id.PAUSE:
			_face.draw_rect(Rect2(c + Vector2(-s * 0.7, -s), Vector2(s * 0.5, s * 2.0)), ICON)
			_face.draw_rect(Rect2(c + Vector2(s * 0.2, -s), Vector2(s * 0.5, s * 2.0)), ICON)
		Id.MENU:
			for row: int in 3:
				_face.draw_rect(Rect2(c + Vector2(-s, -s + row * s * 0.8), Vector2(s * 2.0, s * 0.35)),
					ICON)

func _triangle(a: Vector2, b: Vector2, c: Vector2) -> void:
	_face.draw_colored_polygon(PackedVector2Array([a, b, c]), ICON)

## A `^` ([param direction] −1) or `v` (+1), [param s] half-wide.
func _chevron(c: Vector2, s: float, direction: float) -> void:
	var tip: Vector2 = c + Vector2(0, s * 0.35 * direction)
	_face.draw_polyline(PackedVector2Array([c + Vector2(-s * 0.8, -s * 0.35 * direction), tip,
		c + Vector2(s * 0.8, -s * 0.35 * direction)]), ICON, 6.0, true)

## What the tilt is doing: a bar along the bottom with a marker for the steer,
## and a chevron above or below it lit while paddling or braking.
func _draw_level(size: Vector2, tilt: TiltSteering) -> void:
	var center := Vector2(size.x * 0.5, size.y - LEVEL_FROM_BOTTOM)
	var half := Vector2(LEVEL_HALF_WIDTH, 0.0)
	_face.draw_line(center - half, center + half, Color(0, 0, 0, 0.5), 8.0, true)
	_face.draw_line(center - half, center + half, EDGE, 3.0, true)
	_face.draw_line(center + Vector2(0, -8), center + Vector2(0, 8), EDGE, 2.0)
	var marker: Vector2 = center + half * tilt.steer
	_face.draw_circle(marker, 9.0, FILL_HELD if tilt.steer != 0.0 else EDGE)
	if tilt.paddling:
		_chevron(center + Vector2(0, -22), 14.0, -1.0)
	if tilt.braking:
		_chevron(center + Vector2(0, 22), 14.0, 1.0)
