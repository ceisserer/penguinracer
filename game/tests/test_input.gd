## Held controls, with and without the pulsed-keyboard compensation.
##
## Drives [KeyHoldFilter.feed] directly rather than the Input singleton, so a
## remote desktop's delivery pattern can be reproduced exactly and headlessly.
class_name TestInput
extends RefCounted

const FRAME := 1.0 / 60.0
const A := &"steer_left"

static func run(t: TestCase) -> void:
	_plain_poll(t)
	_pulse_without_compensation(t)
	_one_pulse_is_a_tap(t)
	_pulse_with_compensation(t)
	_release_with_compensation(t)

## Feed `count` pulses `gap` seconds apart, the way autorepeat delivers them.
static func _pulse_train(k: KeyHoldFilter, count: int, gap: float) -> void:
	for i: int in count:
		k.feed(A, false, true, FRAME)
		var waited: float = 0.0
		while waited < gap:
			k.feed(A, false, false, FRAME)
			waited += FRAME

static func _filter(compensate: bool) -> KeyHoldFilter:
	var k := KeyHoldFilter.new(PackedStringArray([A]))
	k.compensate = compensate
	return k

## Off — the default — has to be indistinguishable from `is_action_pressed()`.
static func _plain_poll(t: TestCase) -> void:
	t.begin("input/plain poll")
	var k := _filter(false)
	k.feed(A, true, true, FRAME)
	t.ok(k.pressed(A), "press reads as held")
	k.feed(A, true, false, FRAME)
	t.ok(k.pressed(A), "still held on the next frame")
	k.feed(A, false, false, FRAME)
	t.ok(not k.pressed(A), "release is frame-exact")
	t.ok(not k.remote_keyboard, "a held press does not look remote")

## A pulse must still be reported when compensation is off, and must still not
## steer — that is the bug, left in place deliberately until it is asked for.
static func _pulse_without_compensation(t: TestCase) -> void:
	t.begin("input/pulse, compensation off")
	var k := _filter(false)
	k.feed(A, false, true, FRAME)
	t.ok(not k.pressed(A), "a zero-length pulse does not steer")
	# Autorepeat's 25–33 ms is one to two frames.
	_pulse_train(k, 2, 2.0 * FRAME)
	t.ok(k.remote_keyboard, "a train of them is recognised and reported")

## The false positive the corroboration exists for: a player tapping a control
## quickly enough that press and release share a frame is not a remote desktop,
## and must not be told it is one.
static func _one_pulse_is_a_tap(t: TestCase) -> void:
	t.begin("input/a single pulse is a tap")
	var k := _filter(false)
	k.feed(A, false, true, FRAME)
	t.ok(not k.remote_keyboard, "one quick tap diagnoses nothing")

	# Held for a while, then let go — the ordinary case, at any tap speed.
	for frame: int in range(30):
		k.feed(A, true, frame == 0, FRAME)
	k.feed(A, false, false, FRAME)
	t.ok(not k.remote_keyboard, "nor does a press that survived to a poll")

	# Two taps, but a fifth of a second apart: a hand, not autorepeat.
	_pulse_train(k, 2, 0.2)
	t.ok(not k.remote_keyboard, "nor two taps slower than the pulse window")

	# The same two taps at autorepeat speed are the transport.
	_pulse_train(k, 2, 2.0 * FRAME)
	t.ok(k.remote_keyboard, "the same pair at autorepeat speed is")

	# A pulse on one control does not corroborate a pulse on another.
	var pair := KeyHoldFilter.new(PackedStringArray([A, &"paddle"]))
	pair.feed(A, false, true, FRAME)
	pair.feed(&"paddle", false, true, FRAME)
	t.ok(not pair.remote_keyboard, "two different controls tapped at once do not")

## RustDesk translate mode: down and up land in the same inter-frame gap, then
## autorepeat delivers the same pulse again every other frame or so.
static func _pulse_with_compensation(t: TestCase) -> void:
	t.begin("input/pulse, compensation on")
	var k := _filter(true)
	k.feed(A, false, true, FRAME)
	t.ok(k.pressed(A), "a zero-length pulse steers")
	# Autorepeat at ~30 Hz against a 60 Hz frame: a pulse every second frame.
	var gaps: int = 0
	for frame: int in range(60):
		k.feed(A, false, frame % 2 == 0, FRAME)
		if not k.pressed(A):
			gaps += 1
	t.ok(gaps == 0, "autorepeat reads as one continuous hold (%d dropped frames)" % gaps)

## Letting go still has to stop the turn, promptly enough to be steering.
static func _release_with_compensation(t: TestCase) -> void:
	t.begin("input/release, compensation on")
	var k := _filter(true)
	k.feed(A, false, true, FRAME)
	var frames: int = 0
	while k.pressed(A) and frames < 600:
		k.feed(A, false, false, FRAME)
		frames += 1
	t.ok(frames > 1, "the stretch outlasts one frame")
	t.between(frames * FRAME, 0.0, 0.2, "the turn stops within 200 ms of the last pulse")
