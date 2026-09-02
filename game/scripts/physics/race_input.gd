## Per-frame player intent. Kept separate from [RacePhysics] so the simulation
## can be driven from a recorded trace (headless tests, ghosts, replays) exactly
## as it is from the keyboard.
##
## Where it comes from is an [InputSource]: the keyboard, a scripted pattern, a
## recorded trace, or — later — an AI or a network peer. Nothing in here knows
## which.
class_name RaceInput
extends RefCounted

## Bit positions used by [method pack]. Their order is part of the recording
## format: appending is safe, reordering invalidates every stored trace.
const BIT_LEFT := 1 << 0
const BIT_RIGHT := 1 << 1
const BIT_PADDLE := 1 << 2
const BIT_BRAKE := 1 << 3
const BIT_CHARGE := 1 << 4
const BIT_TRICK := 1 << 5

## Quantisation of [member stick_turn] into the second byte of a packed word.
## 127 steps either side of centre is finer than the 0.2 deadzone the physics
## applies and finer than any thumbstick reports.
const STICK_SCALE := 127.0

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

func copy_from(other: RaceInput) -> void:
	left_turn = other.left_turn
	right_turn = other.right_turn
	stick_turn = other.stick_turn
	paddling = other.paddling
	braking = other.braking
	charging = other.charging
	trick_modifier = other.trick_modifier

## Whether two frames of intent are the same. Used by the recorder to notice
## that nothing changed, and by the tests to compare a trace to its round trip.
func equals(other: RaceInput) -> bool:
	return left_turn == other.left_turn \
		and right_turn == other.right_turn \
		and is_equal_approx(stick_turn, other.stick_turn) \
		and paddling == other.paddling \
		and braking == other.braking \
		and charging == other.charging \
		and trick_modifier == other.trick_modifier

## Sixteen bits: the six held controls in the low byte, the quantised stick in
## the high one. This is what a recording stores per tick and what a network
## packet would carry, so it is two bytes per simulated frame — 120 bytes for a
## second of play, under 15 kB for the longest course anyone has raced.
func pack() -> int:
	var bits: int = 0
	if left_turn:
		bits |= BIT_LEFT
	if right_turn:
		bits |= BIT_RIGHT
	if paddling:
		bits |= BIT_PADDLE
	if braking:
		bits |= BIT_BRAKE
	if charging:
		bits |= BIT_CHARGE
	if trick_modifier:
		bits |= BIT_TRICK
	var stick: int = int(roundf(clampf(stick_turn, -1.0, 1.0) * STICK_SCALE))
	return bits | ((stick & 0xFF) << 8)

## Inverse of [method pack], in place. The stick comes back quantised — a
## replayed trace steers to 1/127th of the original, which is well inside what
## the 0.2 deadzone and the turn ramp can tell apart.
func unpack(word: int) -> void:
	left_turn = (word & BIT_LEFT) != 0
	right_turn = (word & BIT_RIGHT) != 0
	paddling = (word & BIT_PADDLE) != 0
	braking = (word & BIT_BRAKE) != 0
	charging = (word & BIT_CHARGE) != 0
	trick_modifier = (word & BIT_TRICK) != 0
	var stick: int = (word >> 8) & 0xFF
	if stick >= 128:
		stick -= 256
	stick_turn = float(stick) / STICK_SCALE
