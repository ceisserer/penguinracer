## CPU mirror of the snow deformation field — the gameplay half of the dual
## representation in godot-port-plan.md §4.3.
##
## A plain float grid, 128² over a 64 m window (50 cm/texel) that follows the
## player with toroidal scrolling. Stamped by the same footprint logic as the
## GPU trail map, but never synced to it: a GPU→CPU readback would stall the
## browser, and the two representations serve different masters. The GPU one is
## for pixels at 6.25 cm/texel; this one is for feel.
##
## [b]Note on direction of effect.[/b] Plan §4.3 says packed snow should "raise
## friction and lower compression_depth", but the paragraph below it — and the
## whole design rationale — is that packed snow is [i]faster[/i] than fresh
## powder, which is what makes racing lines matter. In this force model friction
## directly scales the retarding force (ice 0.2 fast .. rock 0.7 slow), so
## "faster" means friction goes [i]down[/i] in a packed trench. That is what the
## defaults below do; both coefficients are exported so the call can be redone
## by feel rather than by argument.
class_name SnowField
extends RefCounted

## Texels per side. 128² at 50 cm covers the 64 m window.
const RESOLUTION := 128
## Window extent in metres.
const WINDOW_SIZE := 64.0
const TEXEL := WINDOW_SIZE / float(RESOLUTION)

## Metres of snow displaced downward, per texel — [b]divided by
## [member _depth_scale][/b]. Private because a raw read is not a depth; go
## through [method depth_at], or [method decay] is a lie.
var _depth: PackedFloat32Array = PackedFloat32Array()
## Compaction 0..1, per texel, over [member _pack_scale]. Persists after the
## trench refills.
var _pack: PackedFloat32Array = PackedFloat32Array()

## What a stored texel has to be multiplied by to be metres, and 0..1.
##
## [b]This is the whole of [method decay].[/b] Both fields decay by a single
## exponential that is the same for every texel, so scaling 16 384 floats and
## scaling one number are the same field — and the loop was costing 0.74 ms of
## every tick, fifteen times the entire physics simulation, to multiply a 128²
## grid by 0.99982. The scale is folded back into the arrays by
## [method _renormalise] when it has drifted far enough to be worth a pass,
## which at these time constants is about once every quarter of an hour.
var _depth_scale: float = 1.0
var _pack_scale: float = 1.0
## How small a scale may get before the arrays are rescaled and it is reset.
## Nothing numerical forces a bound this loose — a float32 texel holds the ratio
## happily for hours — so this is only about the divisions in [method stamp]
## staying in a sane range.
const RENORMALISE_BELOW := 1e-4

## Friction offset at full compaction. Negative: a packed trench runs faster.
var packed_friction_delta: float = -0.10
## Compression depth multiplier at full compaction — less snow left to plough.
var packed_depth_scale: float = 0.45
## Deepest trench a single pass can cut, metres.
var max_trench: float = 0.12
## Seconds for a trench to refill by 1/e (wind, fresh snowfall).
var refill_tau: float = 90.0
## Seconds for compaction to fade by 1/e. Much slower than the trench itself.
var pack_tau: float = 600.0

var _origin: Vector2i = Vector2i(0, 0)   ## window corner, in global texel units
var _initialized: bool = false

func _init() -> void:
	_depth.resize(RESOLUTION * RESOLUTION)
	_pack.resize(RESOLUTION * RESOLUTION)
	_depth.fill(0.0)
	_pack.fill(0.0)

func _wrap(v: int) -> int:
	return ((v % RESOLUTION) + RESOLUTION) % RESOLUTION

func _index(gx: int, gy: int) -> int:
	return _wrap(gy) * RESOLUTION + _wrap(gx)

## True when the global texel is inside the current window.
func _in_window(gx: int, gy: int) -> bool:
	return gx >= _origin.x and gx < _origin.x + RESOLUTION \
		and gy >= _origin.y and gy < _origin.y + RESOLUTION

## Move the window to follow the player. Only the newly exposed edge strips are
## cleared, which is the whole point of toroidal addressing — no full clear, no
## copy of the retained interior.
func recenter(center_x: float, center_z: float) -> void:
	var target := Vector2i(
		floori(center_x / TEXEL) - RESOLUTION / 2,
		floori(center_z / TEXEL) - RESOLUTION / 2)
	if not _initialized:
		_origin = target
		_initialized = true
		_reset_arrays()
		return
	var d: Vector2i = target - _origin
	if d == Vector2i.ZERO:
		return
	if absi(d.x) >= RESOLUTION or absi(d.y) >= RESOLUTION:
		_origin = target
		_reset_arrays()
		return

	# Columns scrolled in along X.
	if d.x != 0:
		var from_x: int = _origin.x + RESOLUTION if d.x > 0 else target.x
		for i: int in absi(d.x):
			var gx: int = from_x + i
			for gy: int in range(_origin.y, _origin.y + RESOLUTION):
				var idx: int = _index(gx, gy)
				_depth[idx] = 0.0
				_pack[idx] = 0.0
	# Rows scrolled in along Z, over the already-updated X extent.
	if d.y != 0:
		var from_y: int = _origin.y + RESOLUTION if d.y > 0 else target.y
		for i: int in absi(d.y):
			var gy: int = from_y + i
			for gx: int in range(target.x, target.x + RESOLUTION):
				var idx: int = _index(gx, gy)
				_depth[idx] = 0.0
				_pack[idx] = 0.0
	_origin = target

## Stamp a contact footprint as an antialiased disc: texels inside `radius` take
## the full `amount` in metres, texels within one texel of the edge feather.
## The flat-bottomed profile is deliberate — this grid is 50 cm/texel and the
## contact patch is 45 cm wide, so a dome would quantise a carve away entirely.
## Ridge formation at the trench edges is the GPU field's job, not this one's.
func stamp(x: float, z: float, radius: float, amount: float) -> void:
	if not _initialized:
		recenter(x, z)
	var cx: float = x / TEXEL
	var cz: float = z / TEXEL
	var r: float = radius / TEXEL
	var x0: int = floori(cx - r - 1.0)
	var x1: int = ceili(cx + r + 1.0)
	var y0: int = floori(cz - r - 1.0)
	var y1: int = ceili(cz + r + 1.0)
	for gy: int in range(y0, y1 + 1):
		for gx: int in range(x0, x1 + 1):
			if not _in_window(gx, gy):
				continue
			var dx: float = (float(gx) + 0.5) - cx
			var dy: float = (float(gy) + 0.5) - cz
			var dist: float = sqrt(dx * dx + dy * dy)
			if dist > r + 0.5:
				continue
			var falloff: float = clampf(r + 0.5 - dist, 0.0, 1.0)
			var idx: int = _index(gx, gy)
			# Both clamps are on the true value, so they have to be applied in
			# metres and in 0..1 and stored back scaled. Two extra flops per
			# texel of a footprint that is a few dozen texels across.
			_depth[idx] = minf(max_trench, _depth[idx] * _depth_scale
				+ amount * falloff) / _depth_scale
			_pack[idx] = minf(1.0, _pack[idx] * _pack_scale
				+ falloff * 0.5) / _pack_scale

## Refill and settle.
##
## [b]O(1).[/b] The decay is a single exponential applied to every texel alike,
## so it lives in [member _depth_scale] rather than in 16 384 multiplies — see
## that member for what the loop this replaced was costing.
func decay(dt: float) -> void:
	if dt <= 0.0:
		return
	_depth_scale *= exp(-dt / refill_tau)
	_pack_scale *= exp(-dt / pack_tau)
	if _depth_scale < RENORMALISE_BELOW or _pack_scale < RENORMALISE_BELOW:
		_renormalise()

## Fold the scales back into the arrays. The one full pass this class makes, and
## it makes it about once a quarter of an hour.
func _renormalise() -> void:
	for i: int in _depth.size():
		_depth[i] *= _depth_scale
		_pack[i] *= _pack_scale
	_depth_scale = 1.0
	_pack_scale = 1.0

## Clear both fields. The scales go back to 1 with them: an empty field times
## any scale is still empty, but leaving a drifted scale behind would make the
## next stamp divide by it.
func _reset_arrays() -> void:
	_depth.fill(0.0)
	_pack.fill(0.0)
	_depth_scale = 1.0
	_pack_scale = 1.0

func _bilinear(arr: PackedFloat32Array, x: float, z: float) -> float:
	if not _initialized:
		return 0.0
	var cx: float = x / TEXEL - 0.5
	var cz: float = z / TEXEL - 0.5
	var gx: int = floori(cx)
	var gy: int = floori(cz)
	if not _in_window(gx, gy) or not _in_window(gx + 1, gy + 1):
		return 0.0
	var fx: float = cx - float(gx)
	var fy: float = cz - float(gy)
	var v00: float = arr[_index(gx, gy)]
	var v10: float = arr[_index(gx + 1, gy)]
	var v01: float = arr[_index(gx, gy + 1)]
	var v11: float = arr[_index(gx + 1, gy + 1)]
	return lerpf(lerpf(v00, v10, fx), lerpf(v01, v11, fx), fy)

## Metres the surface has been pushed down at this point.
func depth_at(x: float, z: float) -> float:
	return _bilinear(_depth, x, z) * _depth_scale

func pack_at(x: float, z: float) -> float:
	return _bilinear(_pack, x, z) * _pack_scale

## Apply compaction to a surface query. Called from [HeightmapSurface].
func apply_to_sample(x: float, z: float, out: SurfaceSample) -> void:
	out.height -= _bilinear(_depth, x, z) * _depth_scale
	var p: float = _bilinear(_pack, x, z) * _pack_scale
	if p <= 0.0:
		return
	out.friction = maxf(0.05, out.friction + packed_friction_delta * p)
	out.compression_depth *= lerpf(1.0, packed_depth_scale, p)
