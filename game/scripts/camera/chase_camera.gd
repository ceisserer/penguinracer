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

## The shape the lens is designed at: `project.godot`'s 1280x720 base. Every
## capture in the notes was taken at it, and [member Camera3D.fov] in
## `race.tscn` is the vertical angle that belongs to it.
const DESIGN_ASPECT := 1280.0 / 720.0

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

## [member Camera3D.fov] as the scene authored it, at [constant DESIGN_ASPECT].
## Kept separately because `fov` itself is rewritten every time the window
## changes shape, and reading a value back that this has already widened would
## widen it again on the next resize.
var _design_fov: float = 0.0

func _ready() -> void:
	_design_fov = fov
	# Stated rather than inherited from the scene, because everything below
	# reads `fov` as the *vertical* angle and [constant Camera3D.KEEP_WIDTH]
	# would quietly make it the horizontal one.
	keep_aspect = Camera3D.KEEP_HEIGHT
	var viewport: Viewport = get_viewport()
	if viewport != null:
		viewport.size_changed.connect(_match_viewport_shape)
	_match_viewport_shape()

## Keep the design frustum inside the window's, whatever shape the window is.
##
## `window/stretch/aspect="expand"` lets the canvas be any shape: it keeps the
## 1280x720 base's short side and grows along the long one. Wider than 16:9 the
## camera's own default does the right thing on its own — [constant
## Camera3D.KEEP_HEIGHT] holds the vertical angle and the horizontal one opens
## up, so a 21:9 window really does see more hill to either side, which is the
## whole reason for expanding rather than letterboxing.
##
## Narrower than 16:9 that same default is backwards: it would hold the vertical
## angle and *close* the horizontal one, so a 4:3 window would see less of the
## hill to the sides than a 16:9 one — less, in fact, than the letterboxed 4:3
## window this replaced, which at least kept the whole 16:9 picture between its
## black bars. Losing peripheral vision is the one thing a downhill racer cannot
## afford to a window shape, so below [constant DESIGN_ASPECT] the vertical
## angle is opened instead and the horizontal one held at the design value.
##
## Either way the 16:9 frame is a subset of what is drawn and no window shape
## shows less of the course than another.
func _match_viewport_shape() -> void:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var size: Vector2 = viewport.get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	fov = fov_for_aspect(_design_fov, size.x / size.y)

## The vertical field of view to use at [param aspect] for a lens that is
## [param design_fov] degrees vertically at [constant DESIGN_ASPECT].
##
## Static and pure so [TestCamera] can check the two branches without a window:
## at or above the design shape the answer is the design angle unchanged, and
## below it the angle that keeps `tan(h/2) = tan(design_fov/2) * DESIGN_ASPECT`
## — the design *horizontal* half-angle — true at the narrower aspect.
static func fov_for_aspect(design_fov: float, aspect: float) -> float:
	if aspect >= DESIGN_ASPECT or aspect <= 0.0:
		return design_fov
	var half_width: float = tan(deg_to_rad(design_fov) * 0.5) * DESIGN_ASPECT
	return rad_to_deg(2.0 * atan(half_width / aspect))

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
		var up: Vector3 = _lean_up(surface_normal, direction)
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

## The direction the camera's height offset leans in: the terrain normal blended
## half way to world up, with its [b]sideways[/b] half removed.
##
## The lean exists for one reason — not burying the camera in the hill on a
## steep pitch — and that is entirely a fore-and-aft effect. The across-track
## half of the same tilt does nothing for it and translates the camera sideways
## instead, which at [member distance] behind the player is a yaw swing.
##
## It shows up on a jump. Airborne, the horizontal velocity is exactly constant
## — no steering, and neither gravity nor drag turns it — so the camera has
## nothing to follow but the ground it is flying over, whose normal sweeps
## hardest across exactly the ridge the jump was taken off. Measured with the
## full normal, a jump on Bumpy Ride swung the camera 16.6° with five reversals
## in it, and one on Downhill Fear 11.2° with four, over a heading that moved
## 0.01° — the two or three nervous flicks left and right that a jump used to
## come with. Keeping only the pitch half leaves the anti-burying behaviour
## identical (the [constant MIN_CAMERA_HEIGHT] backstop fires at the same rate)
## and takes both swings under a quarter of a degree. [TestCamera] asserts it.
static func _lean_up(surface_normal: Vector3, direction: Vector3) -> Vector3:
	var lean: Vector3 = surface_normal
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() > 1e-8:
		var side: Vector3 = flat.normalized().cross(Vector3.UP)
		lean = (lean - side * lean.dot(side)).normalized()
	return lean.lerp(Vector3.UP, 0.5).normalized()

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
