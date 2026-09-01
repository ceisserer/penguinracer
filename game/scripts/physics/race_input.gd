## Per-frame player intent. Kept separate from [RacePhysics] so the simulation
## can be driven from a recorded trace (headless tests, ghosts, replays) exactly
## as it is from the keyboard.
class_name RaceInput
extends RefCounted

var left_turn: bool = false
var right_turn: bool = false
## Analogue steering; when |value| > 0.2 it overrides the digital turn flags.
var stick_turn: float = 0.0
var paddling: bool = false
var braking: bool = false
## Held to charge a jump; released to fire it.
var charging: bool = false
## Held with a direction while airborne to roll/flip.
var trick_modifier: bool = false

func clear() -> void:
	left_turn = false
	right_turn = false
	stick_turn = 0.0
	paddling = false
	braking = false
	charging = false
	trick_modifier = false
