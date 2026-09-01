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
	_pulse_with_compensation(t)
	_release_with_compensation(t)

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
	t.ok(k.remote_keyboard, "but is recognised and reported")

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
