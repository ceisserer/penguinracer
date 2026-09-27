## The phone as a steering wheel: gravity in, steering, paddling and braking out.
##
## [b]The frame.[/b] [method feed] takes gravity in the [i]screen's[/i]
## coordinates — x to the right of the picture, y up it, z out of the glass
## towards the player — pointing at the ground, which is Godot's own sign for
## [method Input.get_gravity]. [MotionSensor] does the per-platform remapping
## (screen rotation, the browser's opposite sign), so everything here is one
## piece of geometry, the same on every device, and runs headless.
##
## [b]Roll steers.[/b] Turning the device clockwise, as the player sees it, is a
## right turn — the wheel metaphor. The angle is the screen's x axis against the
## horizontal, `asin(gx / |g|)`, which does not change with how far back the
## device is tipped: a phone held at 30° and one held at 70° steer alike. No
## calibration, because level is level.
##
## [b]Pitch paddles and brakes.[/b] Tipping the top edge away (the screen turns
## up) paddles, tipping it back brakes. Unlike roll there is no natural zero —
## people hold a phone anywhere from upright to nearly flat — so the neutral is
## taken from how the player is holding it at the start of each run
## ([method recenter], called through [method LocalInputSource.reset]), and
## both thresholds have hysteresis so a hand's tremor at the edge does not
## chatter.
##
## [b]Steering is analogue, and floored.[/b] [RacePhysics] ignores a stick under
## 0.2 and silently falls through to the digital flags (trap list), so a tilt
## just past the deadzone maps to [constant STICK_FLOOR], not to 0.01.
##
## DEVIATION: ETR is keyboard-only.
class_name TiltSteering
extends RefCounted

## Below this, roll is noise: a hand is never quite level.
const ROLL_DEADZONE_DEG := 2.5
## Full lock. Past about 25° the screen is hard to read, so the useful range
## has to end before that.
const ROLL_FULL_DEG := 22.0
## What the smallest deliberate tilt steers at. Just over [RacePhysics]'s 0.2
## threshold, which would otherwise swallow the first third of the range.
const STICK_FLOOR := 0.21

## Tip past this from the neutral to paddle / brake…
const PITCH_ON_DEG := 11.0
## …and back inside this to stop. The gap is the hysteresis.
const PITCH_OFF_DEG := 7.0

## Low-pass time constant on the gravity vector. The Android gravity sensor is
## smooth already; a browser's `accelerationIncludingGravity` carries every
## jolt of the hand, and a racer that twitches with it is unplayable.
const FILTER_TAU := 0.07
## How long after [method recenter] the neutral pitch follows the device before
## it is fixed. Long enough for the filter to settle on how it is being held.
const SETTLE_TIME := 0.35
## Shorter than this is not a reading. Units differ — m/s² on Android, g on iOS
## and in some browsers — so only the direction is ever used and this only has
## to reject zero.
const MIN_MAGNITUDE := 0.1

## −1 (full left) … 1 (full right), 0 inside the deadzone.
var steer: float = 0.0
var paddling: bool = false
var braking: bool = false
## Degrees tipped away (+) or back (−) from the neutral; for the HUD's gauge.
var pitch_delta_deg: float = 0.0
## Degrees rolled clockwise (+); for the HUD's gauge.
var roll_deg: float = 0.0
## Whether a reading has ever arrived. A desktop with `--touch=tilt`, or a
## browser that has not been granted motion access, never sets it — and then
## [TouchControls] draws the steering buttons after all.
var has_data: bool = false

var _gravity := Vector3.ZERO
var _neutral_pitch_deg: float = 0.0
var _settle: float = SETTLE_TIME

## Start of a run: forget the neutral and take it again from the next
## [constant SETTLE_TIME] of readings. Paddle and brake are released meanwhile;
## steering keeps working, since it needs no neutral.
func recenter() -> void:
	_settle = SETTLE_TIME
	paddling = false
	braking = false

## One tick's reading. [param gravity] in the screen frame (see the class doc),
## any units; [constant Vector3.ZERO] for "no sensor".
func feed(gravity: Vector3, delta: float) -> void:
	if gravity.length() < MIN_MAGNITUDE:
		steer = 0.0
		paddling = false
		braking = false
		return
	var reading: Vector3 = gravity.normalized()
	if not has_data or _gravity == Vector3.ZERO:
		_gravity = reading
	else:
		_gravity = _gravity.lerp(reading, 1.0 - exp(-delta / FILTER_TAU)).normalized()
	has_data = true

	roll_deg = rad_to_deg(asin(clampf(_gravity.x, -1.0, 1.0)))
	steer = steer_for_roll(roll_deg)

	var pitch_deg: float = pitch_of(_gravity)
	if _settle > 0.0:
		_settle -= delta
		_neutral_pitch_deg = pitch_deg
		pitch_delta_deg = 0.0
		paddling = false
		braking = false
		return
	pitch_delta_deg = wrapf(pitch_deg - _neutral_pitch_deg, -180.0, 180.0)
	paddling = pitch_delta_deg > (PITCH_OFF_DEG if paddling else PITCH_ON_DEG)
	braking = pitch_delta_deg < -(PITCH_OFF_DEG if braking else PITCH_ON_DEG)

## How far back from upright the screen is tipped, in degrees: 0 facing the
## player square on, 90 lying face up. Measured in the screen's y–z plane, so
## roll does not move it.
static func pitch_of(gravity: Vector3) -> float:
	return rad_to_deg(atan2(-gravity.z, -gravity.y))

## Roll in degrees to a stick value, deadzone and floor applied.
static func steer_for_roll(roll: float) -> float:
	var past: float = absf(roll) - ROLL_DEADZONE_DEG
	if past <= 0.0:
		return 0.0
	var t: float = clampf(past / (ROLL_FULL_DEG - ROLL_DEADZONE_DEG), 0.0, 1.0)
	return signf(roll) * lerpf(STICK_FLOOR, 1.0, t)
