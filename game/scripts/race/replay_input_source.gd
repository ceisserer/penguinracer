## Drives a racer from a recorded input trace, re-simulating rather than
## replaying poses.
##
## This is the other half of [RaceRecording], and the half that is [i]not[/i]
## what a ghost uses — see that class for why the poses are the robust playback
## path and the trace is the exact one. What the trace is good for is anything
## that has to react to the world rather than repeat a path through it: a
## regression test that asserts the same trajectory out of the same intent, a
## bug report replayed against a changed force constant, and the corpus an AI
## would be measured against.
##
## Runs off its own tick counter rather than off the clock, because that is what
## the recorder counted: one word per simulation tick, and the tick rate is in
## the recording's header. A trace that has run out holds a cleared input, so a
## short recording leaves its racer coasting instead of repeating its last
## keypress forever.
class_name ReplayInputSource
extends InputSource

var recording: RaceRecording
var _tick: int = 0

func _init(from: RaceRecording = null) -> void:
	recording = from

func poll(out: RaceInput, _physics: RacePhysics, _delta: float) -> void:
	if recording == null or _tick >= recording.tick_count():
		out.clear()
		_tick += 1
		return
	recording.input_into(_tick, out)
	_tick += 1

func reset() -> void:
	_tick = 0

## Whether the trace still has intent to hand out.
func exhausted() -> bool:
	return recording == null or _tick >= recording.tick_count()

func describe() -> String:
	return "replay"
