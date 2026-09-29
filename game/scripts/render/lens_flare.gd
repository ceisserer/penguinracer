## The sun in the lens: a soft glare round the disc and a few faint ghosts of
## it strung across the frame, while the sun is in shot and nothing stands in
## front of it.
##
## DEVIATION: ETR has no sun to see and no flare. This follows the drawn disc
## ([constant Atmosphere.SUN_DIRECTION]), not the light, and is kept gentle —
## a camera's reflections, not a light show: the glare is most of it, the
## ghosts are a few levels over what is behind them, and nothing is added in
## the middle of the frame worth the name.
##
## [b]Whether the sun is hidden is the GPU's question.[/b] Gameplay never reads
## back (architecture rule 3), and the presentation should not either: a
## readback stalls the browser. The shader samples the frame it is drawn over
## at a few points inside the disc, which is white wherever the disc shows and
## anything else where a tree, a slope or the penguin is in front of it, and
## scales the whole flare by the share that is white. So the flare dims as a
## trunk sweeps across the sun and goes out behind a ridge of the course, with
## nothing on the CPU knowing either.
##
## Everything this script decides is where the disc lands on the canvas and
## how much of the frame's edge it has left behind ([method edge_presence]).
## Plain 2D under the HUD's layer, beside [LensSnow], so both renderers draw it
## alike; presentation only, on the frame's clock.
class_name LensFlare
extends CanvasLayer

## How far past the canvas's edge, as a share of its height, the sun may go
## before the flare is gone. A lens flares a little from a sun just out of
## shot; much further and a flare with no sun reads as a bug.
const EDGE_FADE := 0.06
## The patch the occlusion probe samples, as a share of the disc's radius:
## inside the disc, where it is white, clear of its soft edge.
const PROBE_SHARE := 0.6

## How strongly the sky flares the lens, 0..1: [member Atmosphere.flare].
var strength: float = 0.0
## World direction toward the drawn disc: [member Atmosphere.sun_world_direction].
var direction: Vector3 = Vector3.UP

var _rect: ColorRect
var _material: ShaderMaterial

func _init() -> void:
	# Under the HUD (layer 1) and every menu, over the 3D frame — like [LensSnow].
	layer = 0
	visible = false

func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/lens_flare.gdshader")
	_rect = ColorRect.new()
	_rect.name = "Flare"
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.material = _material
	add_child(_rect)

## Point the flare at the sky's disc: [param world_direction] toward it, and
## [param amount] of flare (0 is none).
func set_sun(world_direction: Vector3, amount: float) -> void:
	direction = world_direction.normalized()
	strength = maxf(amount, 0.0)
	if strength <= 0.0:
		visible = false

## Place the flare for [param camera] as it is this frame.
func update(camera: Camera3D) -> void:
	if strength <= 0.0 or camera == null or _material == null:
		visible = false
		return
	var size: Vector2 = get_viewport().get_visible_rect().size
	if size.y <= 0.0:
		visible = false
		return
	var far_point: Vector3 = camera.global_position + direction * 100.0
	if camera.is_position_behind(far_point):
		visible = false
		return
	var at: Vector2 = camera.unproject_position(far_point) / size
	var presence: float = edge_presence(at, size.x / size.y)
	visible = presence > 0.0
	if not visible:
		return
	_material.set_shader_parameter("sun_uv", at)
	_material.set_shader_parameter("strength", strength * presence)
	_material.set_shader_parameter("probe", probe_radius(camera.fov))

## How much of the flare is left for a sun at [param at] (canvas shares) on a
## canvas [param aspect] wide per unit of height: 1 anywhere on the canvas,
## easing to 0 [constant EDGE_FADE] of the height beyond its edge.
static func edge_presence(at: Vector2, aspect: float) -> float:
	var outside := Vector2(maxf(maxf(-at.x, at.x - 1.0), 0.0) * aspect,
		maxf(maxf(-at.y, at.y - 1.0), 0.0))
	return 1.0 - smoothstep(0.0, EDGE_FADE, outside.length())

## The occlusion probe's radius as a share of the canvas height, for a camera
## [param fov_degrees] tall: the disc's angular radius at the middle of the
## frame, times [constant PROBE_SHARE]. Toward the edges perspective draws the
## disc larger, so the probe only sits further inside it.
static func probe_radius(fov_degrees: float) -> float:
	var tall: float = 2.0 * tan(deg_to_rad(fov_degrees) * 0.5)
	return Atmosphere.SUN_RADIUS * PROBE_SHARE / maxf(tall, 1e-4)
