## A time-ordered run of [RacerState] samples, and the one thing that reads
## between them.
##
## Three callers, one buffer. A ghost loads a whole recorded run into it and
## plays it back from t = 0; a network peer appends snapshots as they arrive and
## is read a fixed delay behind the local clock; a test builds one by hand. All
## three want the same question answered — [i]where was this racer at time
## t[/i] — and the answer has to be smooth, because a snapshot rate low enough
## to be cheap (20 Hz) is far below any screen's.
##
## The samples are stored as one flat [PackedFloat32Array] in
## [RacerState]'s layout, [constant RacerState.FLOATS] to a sample, so a
## recording is the buffer written straight to disk with no per-sample objects.
class_name RacerStateStream
extends RefCounted

## Samples out of order are dropped rather than sorted in. An unreliable
## transport reorders and duplicates, and a snapshot that arrives after a newer
## one has nothing to add — the newer one already describes the racer better
## than any interpolation through the stale one would.
var _data: PackedFloat32Array = PackedFloat32Array()
## Where the last [method sample_into] found itself. Playback walks forward, so
## the common case is "the same pair of samples as last frame, or the next".
var _cursor: int = 0
## Scratch for the bracketing samples, so sampling every frame for every racer
## does not allocate.
var _a := RacerState.new()
var _b := RacerState.new()

func clear() -> void:
	_data.clear()
	_cursor = 0

func is_empty() -> bool:
	return _data.is_empty()

func sample_count() -> int:
	@warning_ignore("integer_division")
	var n: int = _data.size() / RacerState.FLOATS
	return n

## Seconds from the first sample to the last. Zero for an empty or single-sample
## stream.
func duration() -> float:
	if sample_count() < 2:
		return 0.0
	return _time_of(sample_count() - 1) - _time_of(0)

func start_time() -> float:
	return 0.0 if is_empty() else _time_of(0)

func end_time() -> float:
	return 0.0 if is_empty() else _time_of(sample_count() - 1)

## Add a sample. Returns false if it was dropped for arriving out of order.
func append(state: RacerState) -> bool:
	if not is_empty() and state.time <= end_time():
		return false
	state.write_into(_data)
	return true

## Add a sample straight off a transport, without an intermediate [RacerState].
## Returns false for a malformed or stale packet — the caller is a network
## handler and cannot assume the sender is this build.
func append_packet(packet: PackedFloat32Array) -> bool:
	if not RacerState.is_valid_packet(packet):
		return false
	if not is_empty() and packet[0] <= end_time():
		return false
	_data.append_array(packet)
	return true

## Drop everything older than [param t], keeping one sample before it so that a
## read at [param t] still has something to interpolate from.
##
## A live network stream is unbounded otherwise: 20 snapshots a second for eight
## racers over a ten-minute course is 1.3 million floats nobody will ever look
## at again. A ghost is never trimmed — the whole run is the point.
func trim_before(t: float) -> void:
	var keep: int = 0
	var n: int = sample_count()
	while keep + 1 < n and _time_of(keep + 1) < t:
		keep += 1
	if keep == 0:
		return
	_data = _data.slice(keep * RacerState.FLOATS)
	_cursor = maxi(0, _cursor - keep)

## Fill [param out] with the racer's state at [param t]. Returns false only for
## an empty stream.
##
## Before the first sample and after the last, the nearest sample is held rather
## than extrapolated. Holding is what a finished ghost should do — it waits at
## the line — and it is the safe answer for a peer whose packets have stopped:
## a racer frozen mid-slope reads as a connection problem, where one extrapolated
## down the hill at its last velocity reads as a racer who is still playing.
func sample_into(t: float, out: RacerState) -> bool:
	var n: int = sample_count()
	if n == 0:
		return false
	if n == 1 or t <= _time_of(0):
		out.read_from(_data, 0)
		return true
	if t >= _time_of(n - 1):
		out.read_from(_data, (n - 1) * RacerState.FLOATS)
		return true
	var i: int = _bracket(t, n)
	_a.read_from(_data, i * RacerState.FLOATS)
	_b.read_from(_data, (i + 1) * RacerState.FLOATS)
	var span: float = _b.time - _a.time
	var k: float = 0.0 if span <= 0.0 else (t - _a.time) / span
	out.interpolate(_a, _b, k)
	return true

## When this racer was [param metres] down the course, or `-1.0` if it never got
## that far.
##
## This is the ghost delta on the HUD: the player is at `progress` now, the
## ghost was here at `time_at_progress(progress)`, and the difference is the
## number in seconds. Linear between the two bracketing samples, because at
## 20 Hz and racing speed the samples are several metres apart and a nearest-
## sample answer would quantise the readout into visible steps.
##
## Progress is assumed to increase. It very nearly does — a racer only moves
## back up the hill after a tree — and where it does not, the first crossing is
## the honest answer to "when did they reach here".
func time_at_progress(metres: float) -> float:
	var n: int = sample_count()
	if n == 0:
		return -1.0
	for i: int in n:
		var p: float = _progress_of(i)
		if p < metres:
			continue
		if i == 0:
			return _time_of(0)
		var prev: float = _progress_of(i - 1)
		var span: float = p - prev
		var k: float = 1.0 if span <= 0.0 else (metres - prev) / span
		return lerpf(_time_of(i - 1), _time_of(i), k)
	return -1.0

# ------------------------------------------------------------------
#                        storage
# ------------------------------------------------------------------

## The raw buffer, for writing to a [RaceRecording]. A copy: handing out the
## live array would let a caller's `push_back` land on this stream.
func to_floats() -> PackedFloat32Array:
	return _data.duplicate()

## Replace the contents with [param floats], ignoring a trailing partial sample
## rather than reading off the end of a truncated file.
func from_floats(floats: PackedFloat32Array) -> void:
	@warning_ignore("integer_division")
	var whole: int = (floats.size() / RacerState.FLOATS) * RacerState.FLOATS
	_data = floats.slice(0, whole)
	_cursor = 0

# ------------------------------------------------------------------

func _time_of(index: int) -> float:
	return _data[index * RacerState.FLOATS]

func _progress_of(index: int) -> float:
	return _data[index * RacerState.FLOATS + 11]

## Index of the sample at or before [param t], given `_time_of(0) < t <
## _time_of(n - 1)`.
##
## Walks forward from where the last read left off, which for playback is nearly
## always zero or one step, and falls back to a bisection when the caller jumps
## — a restart, a seek, or the first read after a stream is loaded.
func _bracket(t: float, n: int) -> int:
	if _cursor >= n - 1 or _time_of(_cursor) > t:
		_cursor = 0
	if _time_of(_cursor) <= t and t < _time_of(_cursor + 1):
		return _cursor
	var lo: int = _cursor
	var hi: int = n - 1
	while hi - lo > 1:
		@warning_ignore("integer_division")
		var mid: int = (lo + hi) / 2
		if _time_of(mid) <= t:
			lo = mid
		else:
			hi = mid
	_cursor = lo
	return lo
