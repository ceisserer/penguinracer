## The phone's controls: which scheme a run gets, what a tilt steers, how a
## browser's reading becomes the screen's, and where the buttons sit.
##
## No phone in the container, so every piece is checked where it is pure: the
## scheme matrix ([method TouchScheme.resolve]), the geometry ([TiltSteering]
## handed gravity vectors built from a known roll and pitch), the browser's
## remapping ([method MotionSensor.web_to_screen] against the rotations the
## native path makes), the merge into a [RaceInput], and the layout against
## [RaceHUD]'s anchors on the canvases a phone and a tablet produce.
##
## [TouchControls] and [RaceHUD] are loaded by path, not named — see [TestHUD].
class_name TestTouch
extends RefCounted

const CONTROLS_SCRIPT := "res://scripts/shell/touch_controls.gd"
const HUD_SCRIPT := "res://scripts/shell/race_hud.gd"
const TICK := 1.0 / 60.0

static func run(t: TestCase) -> void:
	_scheme(t)
	_steering(t)
	_pitch(t)
	_no_sensor(t)
	_web_frame(t)
	_merge(t)
	var controls: GDScript = load(CONTROLS_SCRIPT)
	var hud: GDScript = load(HUD_SCRIPT)
	_shown(t, controls)
	_layout(t, controls, hud)

## Gravity, toward the ground in the screen's frame, for a device tipped back
## [param pitch_deg] from upright and turned [param roll_deg] clockwise.
static func _gravity(pitch_deg: float, roll_deg: float) -> Vector3:
	var a: float = deg_to_rad(pitch_deg)
	var r: float = deg_to_rad(roll_deg)
	return Vector3(sin(r), -cos(r) * cos(a), -cos(r) * sin(a)) * 9.81

static func _settled(pitch_deg: float) -> TiltSteering:
	var tilt := TiltSteering.new()
	tilt.recenter()
	for i: int in 60:
		tilt.feed(_gravity(pitch_deg, 0.0), TICK)
	return tilt

## Long enough for the filter to settle to well under a thousandth.
static func _hold(tilt: TiltSteering, pitch_deg: float, roll_deg: float) -> void:
	for i: int in 90:
		tilt.feed(_gravity(pitch_deg, roll_deg), TICK)

static func _scheme(t: TestCase) -> void:
	t.begin("touch/scheme")
	var tilt := TouchScheme.Kind.TILT
	var buttons := TouchScheme.Kind.BUTTONS
	var off := TouchScheme.Kind.OFF
	t.ok(TouchScheme.resolve(buttons, false, "") == off, "a desktop draws nothing")
	t.ok(TouchScheme.resolve(buttons, true, "") == buttons, "a phone draws the file's scheme")
	t.ok(TouchScheme.resolve(off, true, "") == off, "…including none")
	t.ok(TouchScheme.resolve(buttons, false, "on") == buttons, "--touch forces the file's")
	t.ok(TouchScheme.resolve(off, false, "on") == tilt, "--touch over 'off' still draws")
	t.ok(TouchScheme.resolve(tilt, false, "buttons") == buttons, "--touch=buttons names one")
	t.ok(TouchScheme.resolve(tilt, true, "off") == off, "--touch=off hides it on a phone")
	t.ok(TouchScheme.parse("Buttons") == buttons, "names parse case-blind")
	t.ok(TouchScheme.parse("sideways", off) == off, "an unknown name keeps the fallback")
	for kind: int in TouchScheme.NAMES.size():
		t.ok(TouchScheme.parse(TouchScheme.name_of(kind)) == kind, "name round-trips: %d" % kind)

static func _steering(t: TestCase) -> void:
	t.begin("touch/tilt steers")
	var tilt := _settled(40.0)
	t.eq_f(tilt.steer, 0.0, 1e-6, "level is straight on")
	_hold(tilt, 40.0, 1.5)
	t.eq_f(tilt.steer, 0.0, 1e-6, "a hand's wobble is inside the deadzone")
	_hold(tilt, 40.0, 4.0)
	t.ok(tilt.steer > 0.2, "just past the deadzone clears RacePhysics's 0.2 floor")
	t.ok(tilt.steer < 0.4, "…and is still a gentle turn")
	_hold(tilt, 40.0, 12.0)
	var mid: float = tilt.steer
	t.between(mid, 0.4, 0.9, "halfway is a middling turn")
	_hold(tilt, 40.0, 35.0)
	t.eq_f(tilt.steer, 1.0, 1e-6, "past full lock is full lock")
	_hold(tilt, 40.0, -12.0)
	t.eq_f(tilt.steer, -mid, 1e-3, "anticlockwise is left, and symmetrical")
	var flat := _settled(75.0)
	_hold(flat, 75.0, 12.0)
	t.eq_f(flat.steer, mid, 1e-3, "how far back it is tipped does not change the steering")
	var previous: float = -2.0
	for roll: int in range(-40, 41):
		var s: float = TiltSteering.steer_for_roll(float(roll))
		t.ok(s >= previous, "monotone at %d°" % roll)
		previous = s

static func _pitch(t: TestCase) -> void:
	t.begin("touch/tilt paddles and brakes")
	t.eq_f(TiltSteering.pitch_of(_gravity(0.0, 0.0)), 0.0, 1e-4, "upright is 0°")
	t.eq_f(TiltSteering.pitch_of(_gravity(90.0, 0.0)), 90.0, 1e-4, "face up is 90°")
	t.eq_f(TiltSteering.pitch_of(_gravity(50.0, 20.0)), 50.0, 1e-4, "roll does not move pitch")
	var tilt := _settled(45.0)
	t.ok(not tilt.paddling and not tilt.braking, "the neutral is how it was held")
	_hold(tilt, 53.0, 0.0)
	t.ok(not tilt.paddling, "a small tip does nothing")
	_hold(tilt, 60.0, 0.0)
	t.ok(tilt.paddling, "tipping the top away paddles")
	_hold(tilt, 54.0, 0.0)
	t.ok(tilt.paddling, "hysteresis: easing back a little keeps paddling")
	_hold(tilt, 50.0, 0.0)
	t.ok(not tilt.paddling, "back inside the band stops")
	_hold(tilt, 30.0, 0.0)
	t.ok(tilt.braking and not tilt.paddling, "tipping it back brakes")
	_hold(tilt, 30.0, 15.0)
	t.ok(tilt.braking and tilt.steer > 0.0, "and steering carries on while braking")
	tilt.recenter()
	t.ok(not tilt.braking, "a new run lets go")
	_hold(tilt, 30.0, 0.0)
	t.ok(not tilt.braking, "…and takes the new hold as its neutral")
	_hold(tilt, 45.0, 0.0)
	t.ok(tilt.paddling, "from which forward is forward again")

static func _no_sensor(t: TestCase) -> void:
	t.begin("touch/no sensor")
	var tilt := TiltSteering.new()
	for i: int in 30:
		tilt.feed(Vector3.ZERO, TICK)
	t.ok(not tilt.has_data, "zero is no reading")
	t.ok(tilt.steer == 0.0 and not tilt.paddling and not tilt.braking, "and drives nothing")
	# iOS reports in g, Android in m/s²: the same pose must read the same.
	var ios := TiltSteering.new()
	var android := TiltSteering.new()
	for i: int in 60:
		ios.feed(_gravity(40.0, 10.0) / 9.81, TICK)
		android.feed(_gravity(40.0, 10.0), TICK)
	t.eq_f(ios.steer, android.steer, 1e-5, "units do not matter")

## Android's own remap (what the engine does natively for ROTATION_90/180/270)
## is the reference: the browser's path has to agree with it.
static func _web_frame(t: TestCase) -> void:
	t.begin("touch/browser reading to screen frame")
	var up := Vector3(0.0, -9.81, 0.0)
	# Portrait, upright: the spec's reading is the reaction, +y.
	t.eq_v(MotionSensor.web_to_screen(Vector3(0, 9.81, 0), 0.0, false), up, 1e-4,
		"portrait, upright")
	# Turned anticlockwise into landscape (angle 90): the device's +x points up.
	t.eq_v(MotionSensor.web_to_screen(Vector3(9.81, 0, 0), 90.0, false), up, 1e-4,
		"landscape, angle 90")
	t.eq_v(MotionSensor.web_to_screen(Vector3(-9.81, 0, 0), 270.0, false), up, 1e-4,
		"landscape, angle 270")
	t.eq_v(MotionSensor.web_to_screen(Vector3(-9.81, 0, 0), -90.0, false), up, 1e-4,
		"old iOS spells 270 as -90")
	t.eq_v(MotionSensor.web_to_screen(Vector3(-9.81, 0, 0), 90.0, true), up, 1e-4,
		"iOS reports gravity itself, not the reaction")
	t.eq_v(MotionSensor.web_to_screen(Vector3(0, 0, 9.81), 90.0, false),
		Vector3(0, 0, -9.81), 1e-4, "face up: gravity goes into the glass")
	# Steering right in landscape 90: turning clockwise lowers the right edge,
	# which is the device's -y end.
	var r: float = deg_to_rad(10.0)
	var device := Vector3(cos(r), sin(r), 0.0) * 9.81
	var screen: Vector3 = MotionSensor.web_to_screen(device, 90.0, false)
	t.ok(TiltSteering.steer_for_roll(rad_to_deg(asin(screen.normalized().x))) > 0.0,
		"clockwise is right in a browser too")

static func _merge(t: TestCase) -> void:
	t.begin("touch/tilt into RaceInput")
	var source := LocalInputSource.new()
	source.tilt = TiltSteering.new()
	source.reset()
	var out := RaceInput.new()
	for i: int in 60:
		out.clear()
		source._merge_tilt(out, _gravity(40.0, 0.0), TICK)
	out.clear()
	for i: int in 30:
		out.clear()
		source._merge_tilt(out, _gravity(60.0, -15.0), TICK)
	t.ok(out.stick_turn < -0.2, "the tilt steers through the stick")
	t.ok(out.left_turn and not out.right_turn, "and says left, for the trick modifier")
	t.ok(out.paddling and not out.braking, "tipped forward paddles")
	out.clear()
	out.stick_turn = 1.0
	out.right_turn = true
	source._merge_tilt(out, _gravity(60.0, -15.0), TICK)
	t.eq_f(out.stick_turn, 1.0, 1e-6, "a key held outranks the tilt")
	t.ok(source.describe() == "keyboard + tilt", "describes itself")

static func _shown(t: TestCase, controls: GDScript) -> void:
	t.begin("touch/which buttons")
	var id: Dictionary = controls.Id
	var tilted: Array = controls.shown(TouchScheme.Kind.TILT, true, false, false)
	t.ok(id.JUMP in tilted and id.TRICK in tilted, "tilt keeps jump and the trick modifier")
	t.ok(not (id.LEFT in tilted) and not (id.PADDLE in tilted) and not (id.BRAKE in tilted),
		"tilt drops steering, paddle and brake")
	var dead: Array = controls.shown(TouchScheme.Kind.TILT, false, false, false)
	t.ok(id.LEFT in dead and id.RIGHT in dead and id.PADDLE in dead,
		"a tilt that never answered brings the buttons back")
	var buttons: Array = controls.shown(TouchScheme.Kind.BUTTONS, true, false, false)
	t.ok(buttons.size() == id.size(), "buttons draws all of them")
	t.ok(not (id.PAUSE in controls.shown(TouchScheme.Kind.BUTTONS, true, true, false)),
		"a network race has no pause")
	t.ok(controls.shown(TouchScheme.Kind.BUTTONS, true, false, true) == [id.PAUSE],
		"paused, only the way back")
	t.ok(controls.shown(TouchScheme.Kind.OFF, true, false, false).is_empty(), "off is off")

## Every button clear of every other and of every piece of the HUD, on a
## 16:9 screen, a 19.5:9 phone, a 21:9 one and a 4:3 tablet.
static func _layout(t: TestCase, controls: GDScript, hud: GDScript) -> void:
	t.begin("touch/layout clears the HUD")
	for canvas: Vector2 in [Vector2(1280, 720), Vector2(1560, 720), Vector2(1680, 720),
			Vector2(1280, 960)]:
		var places: Dictionary = controls.layout(canvas)
		var gauge_box := Rect2(canvas - Vector2(hud.GAUGE_SIZE, hud.GAUGE_SIZE),
			Vector2(hud.GAUGE_SIZE, hud.GAUGE_SIZE))
		var wind: Vector2 = hud.wind_center(canvas)
		var keep_out: Array[Rect2] = [
			gauge_box,
			hud.position_bar_rect(canvas),
			Rect2(Vector2(0, 0), Vector2(260, 90)),  # clock + the status line
			Rect2(Vector2(hud.herring_digits_at(canvas).x, 0), Vector2(hud.HERRING_DIGITS_INSET, 50)),
			Rect2(wind - Vector2.ONE * hud.WIND_DIAMETER * 0.5, Vector2.ONE * hud.WIND_DIAMETER),
			Rect2(hud.wind_digits_at(canvas), Vector2(90, 40)),
			Rect2(Vector2(canvas.x * 0.5 - controls.LEVEL_HALF_WIDTH - 10,
				canvas.y - controls.LEVEL_FROM_BOTTOM - 36),
				Vector2(controls.LEVEL_HALF_WIDTH * 2 + 20, 72)),
		]
		var keys: Array = places.keys()
		for i: int in keys.size():
			var a: Vector3 = places[keys[i]]
			var reach: float = a.z * controls.TOUCH_SLACK
			t.ok(a.x - reach >= 0.0 and a.x + reach <= canvas.x and a.y - reach >= 0.0
				and a.y + reach <= canvas.y, "button %d on screen at %s" % [keys[i], canvas])
			for j: int in range(i + 1, keys.size()):
				var b: Vector3 = places[keys[j]]
				t.ok(Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y))
					> (a.z + b.z) * controls.TOUCH_SLACK,
					"buttons %d and %d apart at %s" % [keys[i], keys[j], canvas])
			for box: Rect2 in keep_out:
				var nearest := Vector2(clampf(a.x, box.position.x, box.end.x),
					clampf(a.y, box.position.y, box.end.y))
				t.ok(nearest.distance_to(Vector2(a.x, a.y)) > a.z,
					"button %d clear of %s at %s" % [keys[i], box, canvas])
