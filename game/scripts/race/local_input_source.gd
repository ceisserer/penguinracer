## The keyboard, gamepad and whatever else Godot's action map is bound to.
##
## A thin wrapper around [KeyHoldFilter], which is where the interesting part
## lives: the held controls have to survive a keyboard forwarded as zero-length
## press/release pulses. Everything else here is the mapping from actions to
## [RaceInput] fields, which used to sit in [RaceScene] and belongs with the
## other sources now that there is more than one.
##
## [b]And the phone.[/b] On-screen buttons need nothing here: [TouchControls]
## presses the same actions a key does. Tilt does — it is an analogue reading,
## not an action — so when [member tilt] is set, [method poll] reads the
## [MotionSensor] once per tick (rule 7: input is polled on the tick, never on
## the frame) and merges it: the keyboard's steering wins where there is any,
## paddle and brake are either one's. Only the halves the scheme gives the
## tilt ([member TiltSteering.steers], [member TiltSteering.speeds]) are merged;
## the other half is the buttons'.
class_name LocalInputSource
extends InputSource

const ACTIONS: PackedStringArray = ["steer_left", "steer_right", "paddle",
	"brake", "jump", "trick_modifier"]

var keys := KeyHoldFilter.new(ACTIONS)

## The device's tilt, when this run steers by it; null otherwise. Set by
## [RacerRoster.build_local] from [method TouchScheme.resolve].
var tilt: TiltSteering = null

## Bridge a keyboard that arrives as pulses. `--remote-keyboard`.
var compensate: bool:
	get:
		return keys.compensate
	set(value):
		keys.compensate = value

func poll(out: RaceInput, _physics: RacePhysics, delta: float) -> void:
	keys.poll(delta)
	out.left_turn = keys.pressed("steer_left")
	out.right_turn = keys.pressed("steer_right")
	out.stick_turn = keys.axis("steer_left", "steer_right")
	out.paddling = keys.pressed("paddle")
	out.braking = keys.pressed("brake")
	out.charging = keys.pressed("jump")
	out.trick_modifier = keys.pressed("trick_modifier")
	if tilt != null:
		_merge_tilt(out, MotionSensor.read(), delta)

## Fold one tilt reading into [param out]. Split from [method poll] so the suite
## can hand it a gravity vector instead of a phone.
func _merge_tilt(out: RaceInput, gravity: Vector3, delta: float) -> void:
	tilt.feed(gravity, delta)
	if tilt.steers and absf(out.stick_turn) < TiltSteering.STICK_FLOOR and tilt.steer != 0.0:
		out.stick_turn = tilt.steer
		# The trick modifier reads the digital flags, not the stick: a roll in
		# the air is "modifier + left", so a tilted phone has to say left too.
		out.left_turn = out.left_turn or tilt.steer < 0.0
		out.right_turn = out.right_turn or tilt.steer > 0.0
	if tilt.speeds:
		out.paddling = out.paddling or tilt.paddling
		out.braking = out.braking or tilt.braking

## A new run takes the neutral pitch again from how the phone is held now.
func reset() -> void:
	if tilt != null:
		tilt.recenter()

func describe() -> String:
	if tilt == null:
		return "keyboard"
	if tilt.steers and tilt.speeds:
		return "keyboard + tilt"
	return "keyboard + tilt steering" if tilt.steers else "keyboard + tilt speed"
