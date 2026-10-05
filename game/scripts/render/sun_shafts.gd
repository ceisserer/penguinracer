## Rays of sunlight in the air: the bright sky round the disc smeared out
## along lines from the sun, so that a trunk, a crest or the penguin in front
## of it throws a dark gap across the frame and the light between reads as
## shafts.
##
## DEVIATION: ETR has no sun to see and no air to light. Like [LensFlare] it
## follows the drawn disc ([constant Atmosphere.SUN_DIRECTION]), not the light,
## and only under a sky whose look has `shafts` ([member Atmosphere.shafts]).
## A setting, [member GameConfig.sun_shafts], off below HIGH.
##
## [b]Screen space, on every renderer.[/b] Forward+'s volumetric fog would
## draw real ones, but it is Forward+ only and would lay a second fog over the
## `FOG` every lit shader writes. This is one full-screen pass that reads the
## frame and its depth, both of which Compatibility and Mobile hand a spatial
## shader. What it cannot know is the sky outside the frame, so the rays
## are there only while the disc is: they fade in over [constant EDGE_FADE] as
## it comes into shot, and there are none while it is out of it.
##
## [b]What is sky is the depth buffer's answer[/b] (`sun_shafts.gdshader`), not
## a brightness test's: snow at the illumination clamp is as white as the air
## round the disc.
##
## Everything this script decides is where the disc lands on the canvas and how
## far inside the edge it is. A [MeshInstance3D] whose shader puts it over
## the whole frame; on [constant IceEnvironment.NEAR_FIELD_LAYER], so the ice's
## probe and mirror, which leave that layer out, do not draw it into the ice.
## Presentation only, on the frame's clock.
class_name SunShafts
extends MeshInstance3D

## How far inside the canvas's edge, as a share of its height, the disc has
## to come before the rays are in full. Inside, not past it like the flare's
## fade: riding straight down the fall line the disc stands about 0.03 of the
## height past the right edge ([constant Atmosphere.SUN_DIRECTION]), and a
## fade reaching out there ran the pass — ~1.3 ms on the iGPU — for most of a
## run to lay a beam of a few levels in from the corner. Under the 0.1 the disc
## stands below the top, so a disc in shot gets all of it.
const EDGE_FADE := 0.08

## How strongly the sky sends rays, 0..1: [member Atmosphere.shafts].
var strength: float = 0.0
## World direction toward the drawn disc: [member Atmosphere.sun_world_direction].
var direction: Vector3 = Vector3.UP

var _material: ShaderMaterial

func _init() -> void:
	visible = false
	layers = IceEnvironment.NEAR_FIELD_LAYER
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The vertex shader places it, so wherever the node is, it must never be
	# culled: the box is the world.
	ignore_occlusion_culling = true
	custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/sun_shafts.gdshader")
	# Last of the transparent pass: over the spray and the falling snow, which
	# the screen copy it reads was taken before.
	_material.render_priority = Material.RENDER_PRIORITY_MAX
	material_override = _material

## Point the rays at the sky's disc: [param world_direction] toward it, and
## [param amount] of rays (0 is none).
func set_sun(world_direction: Vector3, amount: float) -> void:
	direction = world_direction.normalized()
	strength = maxf(amount, 0.0)
	if strength <= 0.0:
		visible = false

## Place the rays for [param camera] as it is this frame.
func update(camera: Camera3D) -> void:
	if strength <= 0.0 or camera == null:
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

## How much of the rays there is for a sun at [param at] (canvas shares) on a
## canvas [param aspect] wide per unit of height: 0 on the edge and beyond it,
## easing to 1 [constant EDGE_FADE] of the height inside it.
static func edge_presence(at: Vector2, aspect: float) -> float:
	var inside: float = minf(minf(at.x, 1.0 - at.x) * aspect, minf(at.y, 1.0 - at.y))
	return smoothstep(0.0, EDGE_FADE, inside)
