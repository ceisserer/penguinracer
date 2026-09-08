## One racer's run, stored twice: as the poses they moved through and as the
## intent that produced them.
##
## [b]Both, deliberately.[/b] They answer different questions and neither one
## does the other's job:
##
## [b]The pose stream[/b] ([member poses], [constant POSE_HZ]) is what a ghost
## plays back and what a network peer receives. It is exact by construction —
## the racer was there — and costs nothing to replay: no second simulation, no
## surface queries, no dependence on the course, the constants or the platform
## still being what they were. That last part is the reason it exists. Input
## replay only reproduces a run if every float operation lands on the same bit,
## and this game ships to native desktops and to a WebAssembly runtime whose
## libm is a different implementation of `exp` and `pow`. A ghost recorded on
## one and replayed on the other would drift, slowly and unfalsifiably, and the
## player would see a penguin taking a line nobody drove.
##
## [b]The input trace[/b] ([member inputs]) is 2 bytes per tick — a fortieth of
## the poses — and is the exact thing for anything that has to re-derive the
## run rather than repeat it: a regression test that asserts the same trajectory
## from the same intent, a saved run replayed against a changed force constant
## to see what moved, and the corpus an AI opponent is scored against. It is
## driven through [ReplayInputSource], and it carries [member physics_signature]
## so a trace recorded before a constant changed can say so instead of quietly
## producing a different race.
##
## A saved run lives in `user://runs/`; see [SavedRunStore].
class_name RaceRecording
extends Resource

## Bumped when the meaning of a stored field changes. A file from another
## version is rejected rather than reinterpreted — a ghost is a convenience,
## and there is nothing here worth a migration path.
##
## 2: [RacerState] grew the four floats the character rig poses itself from
## (see [constant RacerState.FLOATS]). A v1 file is the same poses at the wrong
## stride, which reads as a ghost teleporting rather than as a corrupt file, so
## it is rejected on the version rather than on the arithmetic.
const FORMAT_VERSION := 2

## Simulation ticks per second the trace was recorded at. Not a preference:
## [constant RaceScene.SIM_HZ] is what the words in [member inputs] line up
## with, and a trace recorded at another rate is not replayable at this one.
const DEFAULT_SIM_HZ := 60

## Pose samples per second. 20 Hz is three simulation ticks apart, which at
## racing speed is around a metre — close enough that the interpolation in
## [RacerStateStream] is indistinguishable from the real path, and 72 bytes a
## sample means a four-minute run is about 350 kB.
const POSE_HZ := 20

## Which layout this file is in, [b]stamped explicitly by [method
## RaceRecorder.begin][/b] rather than defaulted to [constant FORMAT_VERSION].
##
## The declared default has to be a version that has never shipped, because
## Godot's saver omits any exported property that still equals its script's
## default — so a field declared `= FORMAT_VERSION` is never written to disk at
## all, and every stored file loads back as [i]whatever the current build calls
## current[/i]. The check below then passes for every file ever written and the
## bump does nothing: the v1 ghosts on disk when [constant FORMAT_VERSION]
## became 2 were read back as v2 and replayed at the wrong stride, which is a
## penguin skating through the scenery rather than an error. Nothing warns.
## Zero is what a file with no version in it now comes back as, and it is
## rejected.
@export var format_version: int = 0
## Directory name of the course, e.g. `bunny_hill`. A ghost is only ever shown
## on the course it was set on.
@export var course_dir: String = ""
## Who the run was raced as, so the ghost is drawn as the right penguin.
@export var character_dir: String = ""
@export var racer_name: String = ""
## What the player called this run when they saved it. Empty for a recording
## that was never explicitly saved (every finished run is recorded; only
## [SavedRunStore.save] stamps this). See [SavedRunStore].
@export var run_name: String = ""
@export var sim_hz: int = DEFAULT_SIM_HZ
@export var pose_hz: int = POSE_HZ
## Hash of the force constants the run was simulated under. See
## [method current_physics_signature].
@export var physics_signature: String = ""
@export var recorded_unix: int = 0

## Finish time in seconds, or the time at which recording stopped.
@export var total_time: float = 0.0
@export var herring: int = 0
## Whether the racer crossed the line. An abandoned run is still a usable
## reference for the first half of a course, but it is never a best time.
@export var completed: bool = false

## Two bytes per simulation tick, little end first — see [method RaceInput.pack].
@export var inputs: PackedByteArray = PackedByteArray()
## [constant RacerState.FLOATS] per sample, in [RacerState]'s layout.
@export var poses: PackedFloat32Array = PackedFloat32Array()

# ------------------------------------------------------------------
#                          the input trace
# ------------------------------------------------------------------

func tick_count() -> int:
	@warning_ignore("integer_division")
	var n: int = inputs.size() / 2
	return n

## Append one tick of intent. The recorder's hot path, called 60 times a second.
func push_input(input: RaceInput) -> void:
	var word: int = input.pack()
	inputs.push_back(word & 0xFF)
	inputs.push_back((word >> 8) & 0xFF)

## Read tick [param tick] into [param out]. Out of range is a cleared input, not
## an error: a trace that has run out leaves its racer coasting.
func input_into(tick: int, out: RaceInput) -> void:
	if tick < 0 or tick >= tick_count():
		out.clear()
		return
	out.unpack(inputs[tick * 2] | (inputs[tick * 2 + 1] << 8))

# ------------------------------------------------------------------
#                          the pose stream
# ------------------------------------------------------------------

func pose_count() -> int:
	@warning_ignore("integer_division")
	var n: int = poses.size() / RacerState.FLOATS
	return n

## The poses as something that can be read between. A fresh stream each call —
## a ghost and the HUD's delta readout keep their own cursors, and sharing one
## would make each seek the other backwards.
func pose_stream() -> RacerStateStream:
	var stream := RacerStateStream.new()
	stream.from_floats(poses)
	return stream

# ------------------------------------------------------------------
#                          compatibility
# ------------------------------------------------------------------

## Whether this recording can be shown as a ghost on [param course]. Only the
## course and the format have to match: playing back poses asks nothing of the
## physics.
func is_playable_on(course: String) -> bool:
	return format_version == FORMAT_VERSION and course_dir == course \
		and pose_count() >= 2

## Whether the input trace can be [i]re-simulated[/i] to the same run. Stricter
## than [method is_playable_on] by exactly the two things a re-simulation
## depends on and a playback does not: the tick rate the words line up with, and
## the constants the forces were computed from.
func is_resimulatable_on(course: String) -> bool:
	return format_version == FORMAT_VERSION and course_dir == course \
		and sim_hz == DEFAULT_SIM_HZ and tick_count() > 0 \
		and physics_signature == current_physics_signature()

## A hash of every constant that would change a trajectory.
##
## Not of the whole of [PhysConst] by reflection: a constant that does not enter
## the force model — a diagnostic threshold, a name — would then invalidate
## every stored trace when it moved. This list is the force model, the
## integrator's tolerances and the character's contact size, which is what
## `etracer.md` §4.1 covers, and it wants extending whenever that section does.
static func current_physics_signature() -> String:
	var parts := PackedFloat64Array([
		PhysConst.MAX_PADDLING_SPEED, PhysConst.PADDLE_FACT, PhysConst.EARTH_GRAV,
		PhysConst.JUMP_FORCE_DURATION, PhysConst.TUX_MASS, PhysConst.MIN_TUX_SPEED,
		PhysConst.INIT_TUX_SPEED, PhysConst.COLL_TOLERANCE, PhysConst.MAX_SURF_PEN,
		PhysConst.TUX_Y_CORR, PhysConst.IDEAL_ROLL_SPEED, PhysConst.IDEAL_ROLL_FRIC,
		PhysConst.WIND_FACTOR, PhysConst.MIN_FRICT_SPEED, PhysConst.MAX_FRICT_FORCE,
		PhysConst.MAX_TURN_ANGLE, PhysConst.MAX_TURN_PERP, PhysConst.MAX_TURN_PEN,
		PhysConst.PADDLING_DURATION, PhysConst.IDEAL_PADD_FRIC, PhysConst.MAX_PADD_FORCE,
		PhysConst.BRAKE_FORCE, PhysConst.MIN_TIME_STEP, PhysConst.MAX_TIME_STEP,
		PhysConst.MAX_STEP_DIST, PhysConst.MAX_POS_ERR, PhysConst.MAX_VEL_ERR,
		PhysConst.MAX_ROLL_ANGLE, PhysConst.BRAKING_ROLL_ANGLE, PhysConst.TUX_WIDTH,
	])
	var text := PackedStringArray()
	# `String.num` rather than a `%` format: GDScript's formatter has no `%g`,
	# and a fixed number of decimals either loses a small constant's precision
	# or writes trailing zeros for a large one.
	for v: float in parts:
		text.push_back(String.num(v, 9))
	for v: float in PhysConst.AIRLOG:
		text.push_back(String.num(v, 9))
	for v: float in PhysConst.AIRDRAG:
		text.push_back(String.num(v, 9))
	return str(",".join(text).hash())

## What the finish line reads, for a menu or a log.
func summary() -> String:
	return "%s  %.2f s  %d herring%s" % [course_dir, total_time, herring,
		"" if completed else "  (unfinished)"]
