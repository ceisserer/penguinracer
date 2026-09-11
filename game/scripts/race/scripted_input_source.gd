## A stand-in for a player, so a headless run produces the same carve every
## time.
##
## `--auto-input=carve` slaloms, `--auto-input=brake` drags the belly,
## `--auto-input=paddle` holds the accelerator, `--auto-input=jump` charges and
## fires on a fixed cycle. Every reference capture in
## `tools/shot.sh` is one of these, which is why the patterns are keyed off
## [member RacePhysics.time] and not off a frame counter: the simulation clock
## is the one thing that is identical between a 60 fps capture and a headless
## run that took two minutes to draw the same frames.
class_name ScriptedInputSource
extends InputSource

## Seconds per slalom half-cycle in the `carve` pattern.
const CARVE_PERIOD := 1.6
## When `brake` starts braking — a run needs a moment of speed to lose.
const BRAKE_DELAY := 3.0
## The `jump` cycle: charge for this long, fire, and be airborne for the rest of
## it. Longer than [constant RacePhysics.MAX_JUMP_AMT] seconds, so the charge
## reaches the top of the HUD's gauge and sits there — which is the state a
## capture of that gauge has to be able to hold still in.
const JUMP_CHARGE := 1.4
const JUMP_PERIOD := 2.4

var pattern: String = ""

func _init(pattern_name: String = "") -> void:
	pattern = pattern_name

func poll(out: RaceInput, physics: RacePhysics, _delta: float) -> void:
	out.clear()
	var t: float = physics.time
	match pattern:
		"carve":
			var phase: int = int(t / CARVE_PERIOD) % 2
			out.left_turn = phase == 0
			out.right_turn = phase == 1
			out.paddling = true
		"brake":
			out.braking = t > BRAKE_DELAY
		"paddle":
			out.paddling = true
		"jump":
			out.paddling = true
			out.charging = fmod(t, JUMP_PERIOD) < JUMP_CHARGE

func describe() -> String:
	return "scripted:%s" % pattern
