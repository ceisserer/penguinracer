## Writes a [RaceRecording] as a racer races.
##
## Attached to a [SimulatedRacer] and driven from the simulation tick, not from
## the frame: the input trace is one word per tick by definition, and a pose
## sampled on a frame boundary would land at a different point in the run every
## time the framerate moved.
##
## Recording is unconditional and cheap — 2 bytes a tick plus 72 every third
## tick, about 5 kB for a Bunny Hill run — so the player does not have to have
## asked for a ghost before the run that would have set one. What is conditional
## is keeping it; see [SavedRunStore].
class_name RaceRecorder
extends RefCounted

## Twenty minutes at 60 Hz. A race that has been left running is not a run
## anyone wants to watch, and an unbounded buffer on a paused game is the one
## way this could become a memory problem. Recording stops; the race does not.
const MAX_TICKS := 60 * 60 * 20

var recording: RaceRecording

var _tick: int = 0
## Ticks between pose samples, from the two rates in the recording's header.
var _pose_interval: int = 3
var _last_state := RacerState.new()
var _have_state: bool = false

## Start a new recording. Called on every race start and every restart — the
## previous one is either already saved or was not worth saving.
func begin(course_dir: String, character_dir: String, racer_name: String) -> void:
	recording = RaceRecording.new()
	# Stamped rather than defaulted — see [member RaceRecording.format_version]
	# for why a version that is only a default is not stored at all.
	recording.format_version = RaceRecording.FORMAT_VERSION
	recording.course_dir = course_dir
	recording.character_dir = character_dir
	recording.racer_name = racer_name
	recording.sim_hz = RaceRecording.DEFAULT_SIM_HZ
	recording.pose_hz = RaceRecording.POSE_HZ
	recording.physics_signature = RaceRecording.current_physics_signature()
	recording.recorded_unix = int(Time.get_unix_time_from_system())
	_pose_interval = maxi(1, recording.sim_hz / recording.pose_hz)
	_tick = 0
	_have_state = false

func is_recording() -> bool:
	return recording != null and _tick < MAX_TICKS

## One simulation tick: the intent that was applied, and the state it produced.
func record(input: RaceInput, state: RacerState) -> void:
	if not is_recording():
		return
	recording.push_input(input)
	if _tick % _pose_interval == 0:
		recording.poses.append_array(state.to_floats())
	_last_state.copy_from(state)
	_have_state = true
	_tick += 1

## Close the recording off and hand it over.
##
## The last state is appended whatever the sampling interval says, so the stored
## run ends where the racer ended rather than up to a twentieth of a second
## short of the line — which is exactly the part a ghost is watched at.
func finish(total_time: float, herring: int, completed: bool) -> RaceRecording:
	if recording == null:
		return null
	if _have_state and _last_state.time > _end_time():
		recording.poses.append_array(_last_state.to_floats())
	recording.total_time = total_time
	recording.herring = herring
	recording.completed = completed
	return recording

func _end_time() -> float:
	var n: int = recording.pose_count()
	if n == 0:
		return -INF
	return recording.poses[(n - 1) * RacerState.FLOATS]
