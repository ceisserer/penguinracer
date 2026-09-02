## A racer that is not computed here — only watched.
##
## Two things arrive as one: a ghost, which is a whole recorded run loaded up
## front and read from t = 0, and a remote peer, whose snapshots trickle in over
## the race and are read a fixed delay behind the local clock. The difference
## between them is [member interpolation_delay] and where the samples come from;
## everything else — how they are drawn, how their finish is noticed, what the
## HUD asks them — is the same code, because it is the same
## [RacerStateStream] underneath.
##
## Costs nothing but the mesh. No physics, no surface queries, no snow, no
## spray. That is the whole argument for playing remote racers back rather than
## simulating them locally: eight opponents are eight skinned meshes and eight
## cursors into a float buffer, not eight ODE solvers that would each have to
## agree with the machine they are actually being played on.
class_name PlaybackRacer
extends Racer

## How far behind the race clock to read the stream.
##
## Zero for a ghost — the recording is complete before the race starts, so there
## is nothing to wait for. Non-zero for a network peer: snapshots take a while
## to arrive and do not arrive evenly, and reading at the live clock means
## reading past the end of the buffer and holding the last sample every time the
## network hiccups. A delay of a few snapshot intervals buys smooth motion at
## the cost of showing the peer slightly in the past, which is the trade every
## networked game makes.
var interpolation_delay: float = 0.0

## Clock error past which the read head is moved rather than eased.
##
## Half a second is far more than jitter and far less than a race: it separates
## "the link wobbled" from "this racer's clock is somewhere else entirely",
## which is what a peer joining a race already in progress looks like. Without
## the snap such a racer never moves at all — its clock starts at zero while its
## snapshots are stamped a minute in, so every read lands before the first
## sample and holds it.
const CLOCK_SNAP := 0.5
## Fraction of a small clock error corrected per snapshot. Small on purpose: the
## read head has to move at very nearly one second per second or the racer
## visibly speeds up and slows down, so a drift of a few milliseconds is taken
## out over a second rather than in one frame.
const CLOCK_NUDGE := 0.05

var stream := RacerStateStream.new()
## This racer's own read head, in race time.
var clock: float = 0.0
var running: bool = false

## Whether there is anything to play. A ghost with no recording is hidden rather
## than drawn at the origin.
func has_data() -> bool:
	return not stream.is_empty()

func advance(dt: float) -> void:
	if not running or stream.is_empty():
		return
	clock += dt
	previous.copy_from(state)
	if not stream.sample_into(clock - interpolation_delay, state):
		return
	herring = state.herring
	if state.finished() and not finished:
		finished = true
		finish_time = state.time
		finished_race.emit(self)

## Rewind to the start of the run.
func restart() -> void:
	clock = 0.0
	finished = false
	finish_time = 0.0
	herring = 0
	running = true
	if stream.sample_into(-interpolation_delay, state):
		snap()

## Load a recorded run. Returns whether there was one to load.
func play_recording(recording: RaceRecording) -> bool:
	if recording == null or recording.pose_count() < 2:
		return false
	stream = recording.pose_stream()
	character_dir = recording.character_dir
	restart()
	return true

## Feed one snapshot in off the wire. Returns false for a stale or malformed
## packet; see [method RacerStateStream.append_packet].
##
## Also steers the read head. The sender stamps its snapshots with its own race
## clock, and this racer is drawn [member interpolation_delay] behind whatever
## the newest one says — so [member clock] wants to sit on the sender's clock,
## and the local tick between packets is only what carries it smoothly from one
## to the next.
func push_snapshot(packet: PackedFloat32Array) -> bool:
	if not stream.append_packet(packet):
		return false
	var drift: float = packet[0] - clock
	clock += drift if absf(drift) > CLOCK_SNAP else drift * CLOCK_NUDGE
	return true

## Drop history this racer will never be read at again. A ghost keeps
## everything — the run is the point — so this is the network path only, and it
## is what stops a long race from growing a buffer per peer without bound.
func trim_history() -> void:
	stream.trim_before(clock - interpolation_delay * 2.0)

## Seconds this racer took to reach [param metres] down the course, or -1 if it
## never got there. What the HUD's ghost delta is built out of.
func time_at_progress(metres: float) -> float:
	return stream.time_at_progress(metres)

## Length of the recorded run, for a menu that wants to say how long a ghost is.
func duration() -> float:
	return stream.duration()
