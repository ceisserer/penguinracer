## The multi-racer layer: intent that survives a round trip, states that survive
## a round trip, a stream that can be read between its samples, and a recording
## that can be played back two different ways.
##
## The load-bearing one is [method _resimulation]: a run recorded as intent,
## replayed through [ReplayInputSource], lands in the same place. That is the
## property a ghost, an input-trace replay and any future networked play all
## sit on, and it is only true because the simulation runs on a fixed tick.
class_name TestMultiplayer
extends RefCounted

## The rate [RaceScene] ticks at. Written out rather than reached for through
## the scene, which is a [Node3D] with a course in it and no business being
## loaded by a headless test.
const DT := 1.0 / 60.0

static func run(t: TestCase) -> void:
	_input_codec(t)
	_state_codec(t)
	_stream_sampling(t)
	_stream_progress(t)
	_stream_trimming(t)
	_recording_round_trip(t)
	_resimulation(t)
	_ghost_store(t)
	_playback_racer(t)
	_remote_racer(t)
	_who_collides(t)

# ------------------------------------------------------------------

static func _input_codec(t: TestCase) -> void:
	t.begin("input pack/unpack")
	var out := RaceInput.new()
	# Every combination of the six flags, so a bit that has been given the wrong
	# position cannot hide behind another one being set.
	for bits: int in 64:
		var input := RaceInput.new()
		input.left_turn = (bits & 1) != 0
		input.right_turn = (bits & 2) != 0
		input.paddling = (bits & 4) != 0
		input.braking = (bits & 8) != 0
		input.charging = (bits & 16) != 0
		input.trick_modifier = (bits & 32) != 0
		out.unpack(input.pack())
		if not out.equals(input):
			t.ok(false, "flag combination %d survives a round trip" % bits)
			return
	t.ok(true, "all 64 flag combinations survive a round trip")

	var stick := RaceInput.new()
	stick.stick_turn = 1.0
	out.unpack(stick.pack())
	t.eq_f(out.stick_turn, 1.0, 1e-6, "full right stick")
	stick.stick_turn = -1.0
	out.unpack(stick.pack())
	t.eq_f(out.stick_turn, -1.0, 1e-6, "full left stick")
	stick.stick_turn = 0.0
	out.unpack(stick.pack())
	t.eq_f(out.stick_turn, 0.0, 1e-6, "centred stick")
	# Quantisation is one part in 127, which has to be finer than the 0.2
	# deadzone the steering applies or a replayed trace would steer differently.
	stick.stick_turn = 0.37
	out.unpack(stick.pack())
	t.eq_f(out.stick_turn, 0.37, 1.0 / 127.0, "an analogue value quantises to within a step")
	# Out of range is clamped, not wrapped: a stick reading 1.5 must not come
	# back as a hard left.
	stick.stick_turn = 4.0
	out.unpack(stick.pack())
	t.eq_f(out.stick_turn, 1.0, 1e-6, "an out-of-range stick clamps rather than wrapping")

static func _state_codec(t: TestCase) -> void:
	t.begin("racer state layout")
	var a := RacerState.new()
	a.time = 12.5
	a.position = Vector3(3.0, -1.25, -80.0)
	a.orientation = Quaternion(Vector3(0.3, 0.8, 0.52).normalized(), 1.1)
	a.velocity = Vector3(0.5, -2.0, -14.0)
	a.progress = 80.0
	a.flags = RacerState.FLAG_AIRBORNE | RacerState.FLAG_BRAKING
	a.herring = 7

	var packet: PackedFloat32Array = a.to_floats()
	t.ok(packet.size() == RacerState.FLOATS, "a packet is one sample wide")
	t.ok(RacerState.is_valid_packet(packet), "a packet it just wrote is valid")
	t.ok(not RacerState.is_valid_packet(PackedFloat32Array([1.0, 2.0])),
		"a short packet is rejected")

	var b := RacerState.new()
	b.read_from(packet, 0)
	t.eq_f(b.time, a.time, 1e-4, "time survives the round trip")
	t.eq_v(b.position, a.position, 1e-4, "position survives the round trip")
	t.eq_v(b.velocity, a.velocity, 1e-4, "velocity survives the round trip")
	t.eq_f(b.progress, a.progress, 1e-3, "progress survives the round trip")
	t.ok(b.flags == a.flags, "flags survive the round trip")
	t.ok(b.herring == a.herring, "the herring count survives the round trip")
	t.ok(b.airborne() and not b.finished(), "the flag accessors read the right bits")
	t.eq_f(b.orientation.angle_to(a.orientation), 0.0, 1e-4,
		"orientation survives the round trip")
	# float32 storage denormalises a quaternion by about a part in 10^7, which a
	# slerp between two of them turns into a visible scale wobble on a skinned
	# mesh. It has to come back normalised.
	t.eq_f(b.orientation.length(), 1.0, 1e-6, "a decoded quaternion is normalised")

	var mid := RacerState.new()
	mid.interpolate(a, b, 0.5)
	t.eq_v(mid.position, a.position, 1e-4, "interpolating two equal states is a no-op")
	var c := RacerState.new()
	c.copy_from(a)
	c.time = 13.5
	c.position = a.position + Vector3(0.0, 0.0, -10.0)
	c.herring = 8
	mid.interpolate(a, c, 0.25)
	t.eq_f(mid.time, 12.75, 1e-6, "time interpolates")
	t.eq_f(mid.position.z, -82.5, 1e-4, "position interpolates")
	# A fish is collected once, at a known instant. 7.25 of them is not a state
	# the game has ever been in.
	t.ok(mid.herring == 7, "a discrete count takes the earlier sample")

# ------------------------------------------------------------------

## A stream of `count` samples one second apart, travelling 10 m each.
static func _ramp(count: int) -> RacerStateStream:
	var stream := RacerStateStream.new()
	var s := RacerState.new()
	for i: int in count:
		s.time = float(i)
		s.position = Vector3(0.0, 0.0, -10.0 * float(i))
		s.progress = 10.0 * float(i)
		s.velocity = Vector3(0.0, 0.0, -10.0)
		stream.append(s)
	return stream

static func _stream_sampling(t: TestCase) -> void:
	t.begin("state stream sampling")
	var empty := RacerStateStream.new()
	var out := RacerState.new()
	t.ok(not empty.sample_into(0.0, out), "an empty stream answers nothing")

	var stream: RacerStateStream = _ramp(6)
	t.ok(stream.sample_count() == 6, "six samples went in")
	t.eq_f(stream.duration(), 5.0, 1e-6, "the run is five seconds long")

	t.ok(stream.sample_into(2.5, out), "a mid-stream read succeeds")
	t.eq_f(out.position.z, -25.0, 1e-4, "a read between samples interpolates")
	# Before the start and past the end, the nearest sample is held. Holding is
	# what a finished ghost should do — wait at the line — and it is the safe
	# answer for a peer whose packets have stopped.
	stream.sample_into(-3.0, out)
	t.eq_f(out.position.z, 0.0, 1e-4, "reading before the start holds the first sample")
	stream.sample_into(99.0, out)
	t.eq_f(out.position.z, -50.0, 1e-4, "reading past the end holds the last sample")

	# The cursor walks forward for playback and has to bisect when the caller
	# jumps. Both directions, repeatedly, off the same stream.
	for time: float in [4.2, 0.3, 3.7, 1.1, 4.9, 0.0]:
		stream.sample_into(time, out)
		t.eq_f(out.position.z, -10.0 * time, 1e-3,
			"a seek to %.1f s lands in the right place" % time)

	var s := RacerState.new()
	s.time = 1.0
	t.ok(not stream.append(s), "a sample older than the last one is dropped")
	t.ok(stream.sample_count() == 6, "and does not land in the buffer")
	t.ok(not stream.append_packet(PackedFloat32Array([0.0])),
		"a malformed packet is dropped")

static func _stream_progress(t: TestCase) -> void:
	t.begin("state stream progress lookup")
	var stream: RacerStateStream = _ramp(6)
	t.eq_f(stream.time_at_progress(0.0), 0.0, 1e-6, "the start is at t = 0")
	t.eq_f(stream.time_at_progress(25.0), 2.5, 1e-4,
		"a progress between samples interpolates its time")
	t.eq_f(stream.time_at_progress(50.0), 5.0, 1e-4, "the last sample is reachable")
	t.eq_f(stream.time_at_progress(999.0), -1.0, 1e-6,
		"a progress the racer never reached says so")

static func _stream_trimming(t: TestCase) -> void:
	t.begin("state stream trimming")
	var stream: RacerStateStream = _ramp(10)
	stream.trim_before(4.5)
	# One sample before the cut is kept, or a read at the cut has nothing to
	# interpolate from.
	t.ok(stream.sample_count() == 6, "trimming keeps one sample before the cut")
	t.eq_f(stream.start_time(), 4.0, 1e-6, "and that sample is the one just before it")
	var out := RacerState.new()
	stream.sample_into(4.5, out)
	t.eq_f(out.position.z, -45.0, 1e-4, "a read at the cut still interpolates")
	stream.trim_before(-100.0)
	t.ok(stream.sample_count() == 6, "trimming before the start changes nothing")

# ------------------------------------------------------------------

static func _sim() -> RacePhysics:
	var p := RacePhysics.new()
	p.surface = SlopeFixture.rolling_slope(22.0)
	p.play_min_x = 2.5
	p.play_max_x = 87.5
	p.play_length = 470.0
	p.init_at(45.0, -5.0)
	return p

## Drive a simulation with a scripted pattern, recording it. Returns the
## recording and the final position.
static func _record(seconds: float) -> Array:
	var physics: RacePhysics = _sim()
	var source := ScriptedInputSource.new("carve")
	var recorder := RaceRecorder.new()
	recorder.begin("test_slope", "tux", "tester")
	var input := RaceInput.new()
	var state := RacerState.new()
	var time: float = 0.0
	var ticks: int = int(seconds / DT)
	for i: int in ticks:
		source.poll(input, physics, DT)
		physics.step(input, DT)
		time += DT
		state.capture(physics, time, 0)
		recorder.record(input, state)
	return [recorder.finish(time, 0, true), physics.pos]

static func _recording_round_trip(t: TestCase) -> void:
	t.begin("race recording")
	var result: Array = _record(6.0)
	var rec: RaceRecording = result[0]
	var ticks: int = int(6.0 / DT)

	t.ok(rec.tick_count() == ticks, "one word of intent per simulation tick")
	# 60 Hz of intent sampled at 20 Hz of pose, plus the final sample the
	# recorder appends so the run ends where the racer did.
	t.between(float(rec.pose_count()), float(ticks / 3), float(ticks / 3 + 1),
		"poses are sampled at the recording's pose rate")
	t.ok(rec.completed, "the run is marked complete")
	t.eq_f(rec.total_time, 6.0, 1e-3, "the finish time is stored")

	t.ok(rec.is_playable_on("test_slope"), "the recording plays on its own course")
	t.ok(not rec.is_playable_on("somewhere_else"), "and not on another one")
	t.ok(rec.is_resimulatable_on("test_slope"),
		"and re-simulates under the constants it was recorded with")
	rec.physics_signature = "stale"
	t.ok(not rec.is_resimulatable_on("test_slope"),
		"a trace from before a constant changed refuses to re-simulate")
	t.ok(rec.is_playable_on("test_slope"),
		"but its poses are still playable — they ask nothing of the physics")
	rec.physics_signature = RaceRecording.current_physics_signature()

	t.ok(RaceRecording.current_physics_signature()
		== RaceRecording.current_physics_signature(),
		"the physics signature is stable within a run")

	var stream: RacerStateStream = rec.pose_stream()
	t.ok(stream.sample_count() == rec.pose_count(), "the pose stream is the stored poses")
	t.ok(rec.pose_stream() != stream,
		"each caller gets its own stream, so two cursors cannot fight")

static func _resimulation(t: TestCase) -> void:
	t.begin("replaying a recorded input trace")
	var result: Array = _record(6.0)
	var rec: RaceRecording = result[0]
	var expected: Vector3 = result[1]

	var physics: RacePhysics = _sim()
	var source := ReplayInputSource.new(rec)
	var input := RaceInput.new()
	for i: int in rec.tick_count():
		source.poll(input, physics, DT)
		physics.step(input, DT)
	# This is the whole point of the fixed tick. The same intent, applied in the
	# same order at the same step, has to land in the same place — otherwise a
	# ghost is not the run it claims to be and two peers cannot agree who won.
	t.eq_v(physics.pos, expected, 1e-9, "a replayed trace reaches the same position")
	t.ok(source.exhausted(), "the trace ran out exactly at the end of the run")

	# Past the end, a replay holds nothing rather than the last keypress: a
	# short recording leaves its racer coasting, not steering into the trees.
	source.poll(input, physics, DT)
	t.ok(not input.left_turn and not input.right_turn and not input.paddling,
		"a trace that has run out hands out no intent")

	source.reset()
	var again: RacePhysics = _sim()
	for i: int in rec.tick_count():
		source.poll(input, again, DT)
		again.step(input, DT)
	t.eq_v(again.pos, expected, 1e-9, "and does it again after a reset")

# ------------------------------------------------------------------

static func _ghost_store(t: TestCase) -> void:
	t.begin("ghost store")
	# A course name no shipped course uses, so a developer's own best times are
	# never touched by the suite.
	var course := "__test_course__"
	GhostStore.erase(course)
	t.ok(GhostStore.load_for(course) == null, "no ghost before one is stored")

	var slow: RaceRecording = _record(4.0)[0]
	slow.course_dir = course
	slow.total_time = 40.0
	t.ok(GhostStore.save_if_best(slow), "the first completed run is stored")
	var loaded: RaceRecording = GhostStore.load_for(course)
	t.ok(loaded != null, "and comes back")
	if loaded != null:
		t.eq_f(loaded.total_time, 40.0, 1e-3, "with its time")
		t.ok(loaded.pose_count() == slow.pose_count(), "and all of its poses")
		t.ok(loaded.tick_count() == slow.tick_count(), "and all of its intent")
		t.ok(loaded.character_dir == "tux", "and the character it was raced as")

	var slower: RaceRecording = _record(4.0)[0]
	slower.course_dir = course
	slower.total_time = 45.0
	t.ok(not GhostStore.save_if_best(slower), "a slower run does not replace it")
	t.eq_f(GhostStore.load_for(course).total_time, 40.0, 1e-3, "the best time stands")

	var faster: RaceRecording = _record(4.0)[0]
	faster.course_dir = course
	faster.total_time = 35.0
	t.ok(GhostStore.save_if_best(faster), "a faster run replaces it")
	t.eq_f(GhostStore.load_for(course).total_time, 35.0, 1e-3, "and becomes the best")

	var abandoned: RaceRecording = _record(4.0)[0]
	abandoned.course_dir = course
	abandoned.total_time = 1.0
	abandoned.completed = false
	t.ok(not GhostStore.save_if_best(abandoned),
		"an unfinished run is never a best time, however short")

	GhostStore.erase(course)
	t.ok(GhostStore.load_for(course) == null, "and the suite leaves nothing behind")

static func _playback_racer(t: TestCase) -> void:
	t.begin("playback racer")
	var racer := PlaybackRacer.new()
	t.ok(not racer.has_data(), "a playback racer with no stream has nothing to draw")
	t.ok(not racer.play_recording(null), "and refuses a recording that is not there")

	var rec: RaceRecording = _record(5.0)[0]
	t.ok(racer.play_recording(rec), "a recorded run loads")
	t.ok(racer.has_data(), "and gives it something to draw")
	t.ok(racer.character_dir == "tux", "as the character it was raced as")

	# Advancing it is what a race does every tick. Half a second of that has to
	# move it and leave it unfinished.
	var start: Vector3 = racer.state.position
	racer.running = true
	for i: int in 30:
		racer.advance(DT)
	t.ok(racer.state.position.distance_to(start) > 1.0, "half a second of playback moves it")
	t.ok(not racer.finished, "and does not finish a five-second run")

	# Reading past the end holds the last pose rather than extrapolating down
	# the hill, so a ghost waits at the line instead of carrying on into the fog.
	for i: int in 60 * 10:
		racer.advance(DT)
	var held: Vector3 = racer.state.position
	racer.advance(DT)
	t.eq_v(racer.state.position, held, 1e-6, "past the end it holds its last pose")

	racer.restart()
	t.eq_v(racer.state.position, start, 1e-6, "a restart rewinds it")
	racer.free()

static func _remote_racer(t: TestCase) -> void:
	t.begin("remote racer clock")
	var racer := PlaybackRacer.new()
	racer.kind = Racer.Kind.REMOTE
	racer.interpolation_delay = RaceNetwork.INTERPOLATION_DELAY
	racer.running = true

	# A peer that has been racing for a minute before we arrive. Its snapshots
	# are stamped with its clock, not ours; without the snap our read head sits
	# at zero, every read lands before the first sample, and the racer stands
	# still on the start line for the rest of the race.
	var s := RacerState.new()
	for i: int in 8:
		s.time = 60.0 + 0.05 * float(i)
		s.position = Vector3(0.0, 0.0, -600.0 - float(i))
		s.progress = 600.0 + float(i)
		t.ok(racer.push_snapshot(s.to_floats()), "snapshot %d is accepted" % i)
	t.between(racer.clock, 59.5, 60.5, "the read head snapped to the sender's clock")
	racer.advance(DT)
	t.ok(racer.state.position.z < -595.0, "and the racer is drawn where the peer is")

	# A duplicate and a reordered packet are both dropped. An unreliable
	# transport produces both, and neither has anything to add over what has
	# already arrived.
	s.time = 60.1
	t.ok(not racer.push_snapshot(s.to_floats()), "a reordered snapshot is dropped")
	t.ok(not racer.push_snapshot(PackedFloat32Array()), "an empty packet is dropped")

	# Small drift is eased rather than jumped, or the racer visibly stutters
	# every time the link wobbles by a frame. The packet has to be newer than
	# everything already in the buffer or it is dropped before the clock sees it.
	var before: float = racer.clock
	s.time = racer.stream.end_time() + 0.05
	var drift: float = s.time - before
	t.ok(racer.push_snapshot(s.to_floats()), "the next snapshot in sequence is accepted")
	t.ok(racer.clock > before and racer.clock - before < drift * 0.5,
		"a small clock error is eased, not jumped")

	# Nothing arriving is not a reason to stop: the read head keeps moving and
	# the stream holds its last sample, so a dropped peer freezes in place
	# rather than skating off down the hill at its last known velocity. Run the
	# read head off the end of the buffer first — up to that point it is still
	# playing samples it has, which is not the case under test.
	for i: int in 120:
		racer.advance(DT)
	var held: Vector3 = racer.state.position
	t.eq_v(held, Vector3(0.0, 0.0, -607.0), 1e-4, "it played out to the last snapshot")
	for i: int in 120:
		racer.advance(DT)
	t.eq_v(racer.state.position, held, 1e-6, "a peer that goes quiet holds its last pose")
	racer.free()

## Who is a body and who is a picture. A ghost is the whole reason this
## predicate exists — everything else on the hill is being simulated somewhere,
## even a remote peer, who is a [PlaybackRacer] here and a [SimulatedRacer] on
## the machine that owns them.
static func _who_collides(t: TestCase) -> void:
	t.begin("what a racer collides with")
	var expected: Dictionary[Racer.Kind, bool] = {
		Racer.Kind.LOCAL: true,
		Racer.Kind.AI: true,
		Racer.Kind.REMOTE: true,
		Racer.Kind.GHOST: false,
	}
	for kind: Racer.Kind in expected:
		var racer := Racer.new()
		racer.kind = kind
		t.ok(racer.collides() == expected[kind],
			"kind %d %s a body on the hill" % [kind, "is" if expected[kind] else "is not"])
		racer.free()

	# And the field the scene publishes keeps the two arrays in step, because a
	# position read against somebody else's velocity is a contact resolved
	# against a racer who is not there.
	var field := RacerField.new()
	field.resize(3)
	t.ok(field.size() == 3 and field.velocities.size() == 3, "a field sizes both columns")
	field.set_state(1, Vector3(1.0, 2.0, 3.0), Vector3(4.0, 5.0, 6.0))
	t.eq_v(field.position_of(1), Vector3(1.0, 2.0, 3.0), 1e-9, "and stores a position")
	t.eq_v(field.velocity_of(1), Vector3(4.0, 5.0, 6.0), 1e-9, "and the velocity beside it")
	# Shared by reference, not by value: nine opponents hold this very array.
	var shared: Array[Vector3] = field.positions
	field.set_state(0, Vector3(9.0, 0.0, 0.0), Vector3.ZERO)
	t.eq_v(shared[0], Vector3(9.0, 0.0, 0.0), 1e-9, "and is shared by reference")
