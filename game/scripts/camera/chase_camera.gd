## Chase camera with the lag model from ETR `view.cpp` §4.5 — reproduced as
## behaviour, not as code.
##
## The good part of the original is the time constant: the camera is dragged
## toward its target with `alpha = min(0.3, 1 − exp(−dt/τ))`, τ = 0.06 s, and the
## lag is switched off below 2 m/s and ramped back in by 4.5 m/s. That is why the
## camera feels snappy when you are crawling and smooth at speed, and it is
## subtle enough to leave out by accident.
class_name ChaseCamera
extends Camera3D

enum Mode {
	## Orbits with the velocity direction. The default.
	BEHIND,
	## Chase with more position lag.
	FOLLOW,
	## Fixed offset, no lag. Useful for watching the simulation from outside.
	ABOVE,
	## Development view: sits ahead of the player looking back up the hill, so
	## the trench and the spray can be inspected directly.
	TRAIL,
}

const TIME_CONSTANT := 0.06
const MAX_ALPHA := 0.3
## Below this the camera does not lag at all.
const NO_INTERP_SPEED := 2.0
## By this it lags fully.
const FULL_INTERP_SPEED := 4.5
const MIN_CAMERA_HEIGHT := 1.5
const MAX_PITCH_DEGREES := 40.0

@export var mode: Mode = Mode.BEHIND
@export var distance: float = 4.0
@export var height: float = 1.4
## Point on the player the camera aims at, above the point mass.
@export var look_ahead: float = 0.3

var surface: SurfaceProvider

## Lagged camera position and aim point. Both are interpolated as vectors and
## the basis is rebuilt against world up every frame.
##
## Slerping the orientation directly — the obvious reading of "quaternion
## interpolation" in view.cpp — takes the shortest arc between two look-at
## orientations, and that arc passes through orientations with roll. While the
## target keeps moving the lag never settles, so the horizon ends up permanently
## tilted. Interpolating the two points gives the identical lag with no roll.
var _position: Vector3 = Vector3.ZERO
var _aim: Vector3 = Vector3.ZERO
var _initialized: bool = false

func reset() -> void:
	_initialized = false

## Call once per frame, after the simulation has advanced.
func track(player_pos: Vector3, player_vel: Vector3, surface_normal: Vector3,
		delta: float) -> void:
	var speed: float = player_vel.length()
	var direction: Vector3 = player_vel.normalized() if speed > 1e-4 else Vector3.FORWARD

	var target_pos: Vector3
	var target_aim: Vector3
	if mode == Mode.ABOVE:
		target_pos = player_pos + Vector3(0.0, height + 2.5, 0.0) - direction * distance
		target_aim = player_pos
	elif mode == Mode.TRAIL:
		target_pos = player_pos + Vector3(0.0, height + 3.0, 0.0) + direction * (distance * 2.5)
		target_aim = player_pos - direction * 12.0
	else:
		# Lean the offset with the terrain so the camera stays over the slope
		# rather than burying itself in it on a steep pitch.
		var up: Vector3 = surface_normal.lerp(Vector3.UP, 0.5).normalized()
		target_pos = player_pos - direction * distance + up * height
		target_aim = player_pos + Vector3(0.0, look_ahead, 0.0)

	if not _initialized:
		_position = target_pos
		_aim = target_aim
		_initialized = true
	else:
		var ramp: float = clampf(
			(speed - NO_INTERP_SPEED) / (FULL_INTERP_SPEED - NO_INTERP_SPEED), 0.0, 1.0)
		var alpha: float = minf(MAX_ALPHA, 1.0 - exp(-delta / TIME_CONSTANT))
		var blend: float = lerpf(1.0, alpha, ramp)
		if mode == Mode.ABOVE or mode == Mode.TRAIL:
			_position = target_pos
		else:
			_position = _position.lerp(target_pos, blend)
		_aim = _aim.lerp(target_aim, blend)

	# Never let the camera sink into the hill.
	if surface != null:
		var ground: float = surface.height_at(_position.x, _position.z)
		_position.y = maxf(_position.y, ground + MIN_CAMERA_HEIGHT)

	# Clamp pitch: staring straight down a steep course hides the very thing the
	# player needs to see.
	var to_aim: Vector3 = _aim - _position
	var horizontal: float = Vector2(to_aim.x, to_aim.z).length()
	var max_pitch: float = deg_to_rad(MAX_PITCH_DEGREES)
	if horizontal > 1e-4:
		var pitch: float = atan2(-to_aim.y, horizontal)
		if pitch > max_pitch:
			to_aim.y = -horizontal * tan(max_pitch)
		elif pitch < -max_pitch:
			to_aim.y = horizontal * tan(max_pitch)

	global_transform = Transform3D(
		_look_basis(Vector3.ZERO, to_aim).orthonormalized(), _position)

static func _look_basis(from: Vector3, to: Vector3) -> Basis:
	var forward: Vector3 = to - from
	if forward.length_squared() < 1e-8:
		return Basis.IDENTITY
	forward = forward.normalized()
	var right: Vector3 = forward.cross(Vector3.UP)
	if right.length_squared() < 1e-8:
		right = Vector3.RIGHT
	right = right.normalized()
	var up: Vector3 = right.cross(forward).normalized()
	return Basis(right, up, -forward)
