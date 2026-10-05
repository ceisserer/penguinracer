## The smear a moving camera leaves on the frame: the snow at the racer's feet
## streaks past, the trees at the edge of the frame drag, a hard turn blurs the
## whole hillside sideways. The racers stay sharp.
##
## DEVIATION: ETR draws every frame as a still. A setting,
## [member GameConfig.motion_blur], on only at BEST.
##
## [b]Camera motion only, on every renderer.[/b] Neither Compatibility nor
## Mobile hands a shader a velocity buffer, so the motion of each pixel is
## rebuilt from the depth buffer: the point drawn there, put through the camera
## as it was the frame before (`motion_blur.gdshader`). That is right for
## everything that stands still, which is the whole course. What moves is the
## racers, and the chase camera moves with the one it watches, so they are
## told apart: each racer in shot (up to [constant MAX_RACERS], nearest first)
## is a sphere round its body carrying the body's own displacement. All racers
## alike, the watched one included — nothing here asks who is driving.
##
## [b]What is left out, and how.[/b] The pass is first in the transparent pass
## and reads a copy taken after the opaque one, so the falling snow (which
## streaks itself, [SnowFall]), the spray and a ghost are drawn over it unsmeared.
## The HUD and the lens snow are canvas layers over the whole 3D frame. On
## [constant IceEnvironment.NEAR_FIELD_LAYER], so the ice's probe and mirror,
## which leave that layer out, do not draw it.
##
## [b]Travel is exposed longer than a turn.[/b] DEVIATION from a real shutter,
## which exposes both alike. Riding straight, everything streams out of the
## point the racer is heading for, where nothing moves at all, and only the
## near snow and the edges smear — at a film camera's 180° that was a few
## pixels and read as no blur at all, while a turn sweeps the whole frame
## sideways at once. One longer shutter for both made a carve a smudge. So the
## shutter opens at a camera turned back by [constant TURN_SHUTTER_SECONDS] of
## its turn but carried back by [constant TRAVEL_SHUTTER_SECONDS] of its travel
## ([method exposed]). Not for the racers: the chase camera holds the one it
## follows still on screen by turning and travelling together, and exposing
## the two apart smeared the penguin across a carve. A racer's pixels open
## the shutter at the turn's exposure for both, with the racer's own travel
## exposed as long (`body_view`).
##
## Hidden, and free, while the camera is still or the frame is a cut (a
## restart, the end of the intro); the frame after a cut is sharp.
## Presentation only, on the frame's clock.
class_name MotionBlur
extends MeshInstance3D

## How long the shutter is open for the camera's turn, in seconds: half a
## sixtieth, the film camera's 180°. Each is divided by the frame's own time,
## so a smear is the same length whatever the frame rate.
const TURN_SHUTTER_SECONDS := 1.0 / 120.0
## And for its travel: five times as long, so that riding straight streams the
## snow and the trees past the edges of the frame.
const TRAVEL_SHUTTER_SECONDS := 5.0 / 120.0
## The longest smear, as a share of the canvas height (~70 px at 720p). The
## near snow at the bottom of the frame reaches it at speed; the shader spends
## up to sixteen taps on it.
const MAX_SMEAR := 0.1
## Exposures are capped at this many frames' motion, for a frame rate so high
## that an extrapolated turn would stop meaning anything.
const MAX_EXPOSURE := 8.0
## Racers the shader tells apart from the world. The shader's `MAX_RACERS`.
const MAX_RACERS := 4
## The sphere a racer's body is taken to fill, round a point
## [constant BODY_LIFT] up its own axis from the drawn origin. Large enough to
## hold a penguin crouched or stretched out flat, small enough that the snow it
## takes along with it — which does not smear — is not a sharp ring round it.
const BODY_RADIUS := 0.75
const BODY_LIFT := 0.15
## Racers farther than this are a few pixels tall; let them smear.
const RACER_RANGE := 60.0
## A camera that moved more than this in one frame was moved, not carried
## along (a restart puts it back at the top), and smearing across the jump
## would sweep the whole frame.
const CUT_TRAVEL := 4.0
const CUT_TURN := deg_to_rad(25.0)
## The nearest the world comes to the camera, for the guess at how far the
## frame moved: [constant ChaseCamera.MIN_CAMERA_HEIGHT] over the snow.
const NEAREST_SCENE := 1.5

## Whether the setting is on. Off hides the pass.
var enabled: bool = false

var _material: ShaderMaterial
var _has_previous: bool = false
var _previous_camera := Transform3D.IDENTITY
## Racer instance id → body centre in the world at the last frame.
var _previous_bodies: Dictionary[int, Vector3] = {}

func _init() -> void:
	visible = false
	layers = IceEnvironment.NEAR_FIELD_LAYER
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The vertex shader places it; it must never be culled.
	ignore_occlusion_culling = true
	custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/motion_blur.gdshader")
	# First of the transparent pass: it writes the smeared copy over the frame,
	# so anything transparent drawn before it would be wiped, and everything
	# after it — snow, spray, ghosts, the sun's rays — lands on top, sharp.
	_material.render_priority = Material.RENDER_PRIORITY_MIN
	_material.set_shader_parameter("max_smear", MAX_SMEAR)
	material_override = _material

## Forget the last frame: the next one is drawn sharp and starts the smear
## again. For a pause, whose frames do not move, and anything else that stops
## [method update] being called every frame.
func hold() -> void:
	_has_previous = false
	_previous_bodies.clear()
	visible = false

## Smear the frame [param camera] is about to draw, [param delta] seconds after
## the last one, with [param racers] each moving on their own.
func update(camera: Camera3D, racers: Array[Racer], delta: float) -> void:
	if not enabled or camera == null or delta <= 0.0:
		hold()
		return
	var now: Transform3D = camera.global_transform
	var to_view: Transform3D = now.affine_inverse()
	var turn: float = minf(TURN_SHUTTER_SECONDS / delta, MAX_EXPOSURE)
	var travel: float = minf(TRAVEL_SHUTTER_SECONDS / delta, MAX_EXPOSURE)
	var bodies: Dictionary[int, Vector3] = {}
	var in_shot: Array[Racer] = []
	for racer: Racer in racers:
		if not racer.is_visible_in_tree():
			continue
		var centre: Vector3 = body_centre(racer)
		bodies[racer.get_instance_id()] = centre
		var depth: float = -(to_view * centre).z
		if depth > -BODY_RADIUS and depth < RACER_RANGE:
			in_shot.append(racer)
	in_shot.sort_custom(func(a: Racer, b: Racer) -> bool:
		return now.origin.distance_squared_to(body_centre(a)) \
			< now.origin.distance_squared_to(body_centre(b)))

	var smear: float = 0.0
	if _has_previous:
		smear = frame_smear(_previous_camera, now, camera.fov, turn, travel)
	var cut: bool = _has_previous and is_cut(_previous_camera, now)
	if _has_previous and not cut \
			and smear * camera.get_viewport().get_visible_rect().size.y > 0.5:
		# Fresh arrays every frame: the material keeps a reference to what it
		# is handed (trap list).
		var centres := PackedVector4Array()
		var moved := PackedVector3Array()
		for racer: Racer in in_shot.slice(0, MAX_RACERS):
			var id: int = racer.get_instance_id()
			var view_centre: Vector3 = to_view * bodies[id]
			centres.append(Vector4(view_centre.x, view_centre.y, view_centre.z, BODY_RADIUS))
			# A racer seen for the first time has not moved yet. Exposed as
			# `body_view` is.
			moved.append((bodies[id] - _previous_bodies.get(id, bodies[id])) * turn)
		while centres.size() < MAX_RACERS:
			centres.append(Vector4.ZERO)
			moved.append(Vector3.ZERO)
		_material.set_shader_parameter("previous_view",
			Projection(exposed(_previous_camera, now, turn, travel).affine_inverse()))
		_material.set_shader_parameter("body_view",
			Projection(exposed(_previous_camera, now, turn, turn).affine_inverse()))
		_material.set_shader_parameter("racer_count", mini(in_shot.size(), MAX_RACERS))
		_material.set_shader_parameter("racer_body", centres)
		_material.set_shader_parameter("racer_moved", moved)
		visible = true
	else:
		visible = false
	_previous_camera = now
	_previous_bodies = bodies
	_has_previous = true

## Where a racer's body is taken to be, for the sphere round it.
static func body_centre(racer: Node3D) -> Vector3:
	return racer.global_position + racer.global_basis.y.normalized() * BODY_LIFT

## Whether going from [param from] to [param to] in one frame was a jump of the
## camera rather than a movement of it.
static func is_cut(from: Transform3D, to: Transform3D) -> bool:
	return from.origin.distance_to(to.origin) > CUT_TRAVEL \
		or _turn(from, to) > CUT_TURN

## Where the shutter opened for a frame whose camera moved from [param from]
## to [param to]: [param turn] frames' worth of the turn back from [param to],
## and [param travel] frames' worth of the travel. 1 and 1 is [param from].
static func exposed(from: Transform3D, to: Transform3D, turn: float,
		travel: float) -> Transform3D:
	var facing: Quaternion = to.basis.get_rotation_quaternion().slerp(
		from.basis.get_rotation_quaternion(), turn)
	return Transform3D(Basis(facing), to.origin + (from.origin - to.origin) * travel)

## A generous guess, as a share of the canvas height, at the longest smear the
## camera's move from [param from] to [param to] leaves on the frame, for a
## lens [param fov_degrees] tall, its turn exposed [param turn] frames and its
## travel [param travel]: the turn, plus the travel seen across the nearest the
## world comes. Under half a pixel of it, the pass is not drawn.
static func frame_smear(from: Transform3D, to: Transform3D, fov_degrees: float,
		turn: float, travel: float) -> float:
	var angle: float = _turn(from, to) * turn \
		+ from.origin.distance_to(to.origin) / NEAREST_SCENE * travel
	return minf(angle / deg_to_rad(maxf(fov_degrees, 1.0)), MAX_SMEAR)

static func _turn(from: Transform3D, to: Transform3D) -> float:
	return from.basis.get_rotation_quaternion().angle_to(to.basis.get_rotation_quaternion())
