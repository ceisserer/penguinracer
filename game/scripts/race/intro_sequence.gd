## The pre-race start animation: `CIntro` in the original.
##
## The course is up and lit, the racing theme is already playing, and the
## character walks itself to the start line before the simulation is handed the
## controls. Tux is standing off to one side of the start point, waddles across
## to it, turns to face down the hill and drops onto his belly.
##
## [b]Nothing here touches the simulation.[/b] The keyframe writes the body
## transform directly — the original does the same thing, overwriting
## `ctrl->cpos` from `CKeyframe::Update` every frame — and the simulation is
## stepped from the same start point it was initialised at once the animation is
## done, so there is nothing to hand over. It writes the racer's [RacerState]
## rather than its transform, so the walk is interpolated between ticks like
## everything else.
##
## [b]It borrows the camera and gives it back.[/b] `SetCameraDistance(4.0)` and
## `set_view_mode(ctrl, ABOVE)` in `CIntro::Enter` — the one camera that does
## not need a direction of travel to point itself, which during the intro there
## is none of. What the race was framed with is remembered here and restored by
## [method finish], which is the only reason this needs to be an object rather
## than three functions.
##
## Lifted out of [RaceScene], where it was ninety lines and five members of a
## file that was already doing five other jobs. The seam is narrow — it is
## begun, stepped and finished — and it was always a state machine; it just did
## not have anywhere to be one.
class_name IntroSequence
extends RefCounted

## The clip [CharacterRig] plays. `char/<name>/start.lst` in the original, and
## per character — Trixi's is not Tux's.
const CLIP := &"start"
## What `CIntro::Enter` passes `CKeyframe::Init` as its height correction, and
## the reason the standing pose sits into the snow rather than on top of it.
const HEIGHT_CORRECTION := -0.05
## `SetCameraDistance(4.0)` in `CIntro::Enter`. The same number as the racing
## default, named here because the intro is where the original says it.
const CAMERA_DISTANCE := 4.0

## True between a successful [method begin] and [method finish].
var running: bool = false

var _racer: Racer
var _camera: ChaseCamera
var _surface: SurfaceProvider
## Where the course puts the start line, in world XZ.
var _origin: Vector2 = Vector2.ZERO
## Root motion of the clip, sampled against [member _time]. A keyframe's body
## transform cannot be baked into an [Animation] — see [KeyframePath].
var _path: KeyframePath
var _time: float = 0.0
## The framing the race wants back.
var _camera_mode: ChaseCamera.Mode = ChaseCamera.Mode.BEHIND
var _camera_distance: float = CAMERA_DISTANCE

## Start the animation, or return false and change nothing.
##
## False for a racer with no rig, a rig with no `start` clip, and a clip with no
## root motion — all three of which are a course that should simply begin.
func begin(racer: Racer, camera: ChaseCamera, surface: SurfaceProvider,
		start: Vector2) -> bool:
	if racer == null or racer.rig == null or not racer.rig.play_clip(CLIP):
		return false
	_path = racer.rig.path_for(CLIP)
	if _path == null:
		racer.rig.stop_clip()
		return false

	_racer = racer
	_camera = camera
	_surface = surface
	_origin = start
	_time = 0.0
	running = true

	_camera_mode = camera.mode
	_camera_distance = camera.distance
	camera.mode = ChaseCamera.Mode.ABOVE
	camera.distance = CAMERA_DISTANCE

	_apply_pose(0.0)
	racer.snap()
	racer.present(1.0)
	camera.reset()
	camera.track(racer.global_position, Vector3.ZERO, Vector3.UP, 0.0)
	return true

## Advance one simulation tick. Returns false once the animation has run out,
## at which point it has already put itself away.
func step(dt: float) -> bool:
	if not running:
		return false
	_time += dt
	if _time >= _path.duration():
		finish()
		return false
	_apply_pose(_time)
	_racer.rig.seek_clip(_time)
	return true

## Hand the camera back and stop the clip. Idempotent, because it is reached
## both by the animation running out and by a key — the original aborts on any
## keypress too, and that is most of what the intro is for: a four-and-a-half
## second pause you are meant to be able to cut short.
func finish() -> void:
	if not running:
		return
	running = false
	_path = null
	if _racer != null and _racer.rig != null:
		_racer.rig.stop_clip()
	if _camera != null:
		_camera.mode = _camera_mode
		_camera.distance = _camera_distance
		_camera.reset()
	_racer = null
	_camera = null
	_surface = null

## Place the body where the keyframe says, on the hill rather than in it.
##
## `CKeyframe::Update` reads the authored Y as a clearance above the terrain and
## adds `Course.FindYCoord` to it, which is why a canned animation plays on any
## course. The rotation is the same yaw/pitch/roll the original hands node 0,
## turned into the frame the racer is positioned in — see
## [method CharacterRig.parent_basis_for].
func _apply_pose(t: float) -> void:
	var offset: Vector3 = _path.offset_at(t)
	var x: float = _origin.x + offset.x
	var z: float = _origin.y + offset.z
	var basis: Basis = _racer.rig.parent_basis_for(_path.basis_at(t))
	var y: float = _surface.height_at(x, z) + offset.y \
		+ PhysConst.TUX_Y_CORR + HEIGHT_CORRECTION
	_racer.apply_pose(Vector3(x, y, z), basis)
