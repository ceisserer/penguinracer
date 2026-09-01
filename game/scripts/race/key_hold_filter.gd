## Reads the held player controls, optionally in a way that survives a keyboard
## forwarded as zero-length pulses.
##
## The race polls steering, paddling and jump charge as levels — true from press
## until release. A remote desktop in a character-translating keyboard mode
## (RustDesk's Legacy/Translate; VNC clients do it too) never sends a hold: it
## sends a down and an up back to back and repeats the pair at the autorepeat
## rate. Both land in the same inter-frame gap, so `Input.is_action_pressed()`
## is false at every poll and steering, paddling and jump are simply dead —
## while `r` still restarts the race, because `is_action_just_pressed()` latches
## the press frame and does not care that the release has already arrived.
##
## With [member compensate] off — the default — this is exactly that poll and
## nothing more; the pulse is still *noticed*, and says so once, so the cause is
## discoverable from the console rather than from the physics. Turning it on
## ([code]--remote-keyboard[/code]) stretches every press to [constant STRETCH],
## long enough to bridge the ~33 ms between autorepeat pulses and turn a
## stuttering train of them back into a continuous hold. That is a real cost on
## a local keyboard — a release lingers a tenth of a second, which a trick
## landing can feel — so it is opt-in rather than automatic.
##
## DEVIATION: the original has no equivalent — it polls SDL key state directly.
class_name KeyHoldFilter
extends RefCounted

## How long a press is held for once compensating. Must exceed one autorepeat
## interval (X11 defaults to 25–33 ms) or the stretched hold gaps between
## repeats, and stay short enough that letting go still reads as deliberate.
const STRETCH := 0.1

## Stretch presses to bridge a pulsed keyboard. Off is the plain poll.
var compensate: bool = false

## Set the first time a press is seen that did not survive to a frame poll.
## Sticky: the diagnosis is about the transport, not about one keystroke.
var remote_keyboard: bool = false

var _actions: PackedStringArray
var _hold: Dictionary[StringName, float] = {}

func _init(actions: PackedStringArray) -> void:
	_actions = actions
	for action: StringName in _actions:
		_hold[action] = 0.0

## Sample the Input singleton once for this frame.
func poll(delta: float) -> void:
	for action: StringName in _actions:
		feed(action, Input.is_action_pressed(action),
			Input.is_action_just_pressed(action), delta)

## The state machine, separated from the singleton so the suite can drive it.
## `edge` without `down` is the pulse: pressed and released inside one frame.
func feed(action: StringName, down: bool, edge: bool, delta: float) -> void:
	if edge and not down and not remote_keyboard:
		remote_keyboard = true
		_report()
	if down:
		_hold[action] = STRETCH
	elif not compensate:
		_hold[action] = 0.0
	elif edge:
		_hold[action] = STRETCH
	else:
		_hold[action] = maxf(_hold[action] - delta, 0.0)

func pressed(action: StringName) -> bool:
	return _hold.get(action, 0.0) > 0.0

## Analogue steering wins where there is any; otherwise the two keys, filtered.
func axis(negative: StringName, positive: StringName) -> float:
	var stick: float = Input.get_axis(negative, positive)
	if absf(stick) > 0.2:
		return stick
	return (1.0 if pressed(positive) else 0.0) - (1.0 if pressed(negative) else 0.0)

func _report() -> void:
	if compensate:
		print("KeyHoldFilter: pulsed keyboard confirmed; held controls are being stretched.")
		return
	print("KeyHoldFilter: a key press arrived and left inside one frame, so held ",
		"controls (steering, paddle, jump) cannot register. The keyboard is being ",
		"forwarded as pulses — put the remote desktop in a raw/map keyboard mode, ",
		"or relaunch with `-- --remote-keyboard` to compensate for it.")
