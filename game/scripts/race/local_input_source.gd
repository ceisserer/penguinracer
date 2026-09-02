## The keyboard, gamepad and whatever else Godot's action map is bound to.
##
## A thin wrapper around [KeyHoldFilter], which is where the interesting part
## lives: the held controls have to survive a keyboard forwarded as zero-length
## press/release pulses. Everything else here is the mapping from actions to
## [RaceInput] fields, which used to sit in [RaceScene] and belongs with the
## other sources now that there is more than one.
class_name LocalInputSource
extends InputSource

const ACTIONS: PackedStringArray = ["steer_left", "steer_right", "paddle",
	"brake", "jump", "trick_modifier"]

var keys := KeyHoldFilter.new(ACTIONS)

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

func describe() -> String:
	return "keyboard"
