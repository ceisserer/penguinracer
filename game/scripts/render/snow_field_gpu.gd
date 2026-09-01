## GPU half of the snow deformation field (plan §4.3).
##
## A ping-pong pair of [SubViewport] render targets, 1024² covering a 64 m
## window (≈6.25 cm/texel) that follows the player with toroidal scrolling. Each
## frame one fragment pass decays the field and stamps the player's contact
## footprint; the terrain shader samples the result to displace snow down into
## the trench and up into ridges at its edges.
##
## [b]It is never read back to the CPU.[/b] A GPU→CPU readback would stall the
## browser, so gameplay reads a separate, deliberately coarser [SnowField] that
## is stamped by the same footprint logic. The two do not match exactly, on
## purpose: this one is for pixels, that one is for feel.
class_name SnowFieldGPU
extends Node

## Texels per side. 1024² over 64 m is 6.25 cm/texel.
const RESOLUTION := 1024
## Window extent in metres. Must match [member SnowField.WINDOW_SIZE] so the two
## representations describe the same patch of hill.
const WINDOW_SIZE := 64.0
const MAX_STAMPS := 8

## Deepest trench the field can represent, metres. The R channel is normalised
## against this so an RGBA8 target still resolves ~0.5 mm steps.
@export var max_depth: float = 0.25
## Seconds for a trench to refill by 1/e.
@export var refill_tau: float = 90.0
@export var pack_tau: float = 600.0

var _viewports: Array[SubViewport] = []
var _rects: Array[ColorRect] = []
var _materials: Array[ShaderMaterial] = []
var _current: int = 0
var _origin: Vector2 = Vector2.ZERO
var _prev_origin: Vector2 = Vector2.ZERO
var _first_frame: bool = true
var _stamps: PackedVector4Array = PackedVector4Array()
var _initialized: bool = false

func _ready() -> void:
	_build()

func _build() -> void:
	if _initialized:
		return
	var shader: Shader = load("res://shaders/snow_trail.gdshader")
	for i: int in 2:
		var vp := SubViewport.new()
		vp.name = "TrailViewport%d" % i
		vp.size = Vector2i(RESOLUTION, RESOLUTION)
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		# No MSAA, no post: this is a data buffer that happens to be a texture.
		vp.msaa_2d = Viewport.MSAA_DISABLED

		var rect := ColorRect.new()
		rect.size = Vector2(RESOLUTION, RESOLUTION)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		rect.material = mat
		vp.add_child(rect)
		add_child(vp)

		_viewports.push_back(vp)
		_rects.push_back(rect)
		_materials.push_back(mat)
	_initialized = true

## Texture holding the current field. Hand this to the terrain material.
func trail_texture() -> Texture2D:
	if not _initialized:
		return null
	return _viewports[_current].get_texture()

## World-space corner of the current window, for the terrain shader's UV lookup.
func window_origin() -> Vector2:
	return _origin

func window_extent() -> float:
	return WINDOW_SIZE

## Queue a contact stamp. `radius` and `depth` are in metres.
func stamp(world_x: float, world_z: float, radius: float, depth: float) -> void:
	if _stamps.size() >= MAX_STAMPS:
		return
	var uv := Vector2(
		(world_x - _origin.x) / WINDOW_SIZE,
		(world_z - _origin.y) / WINDOW_SIZE)
	if uv.x < -0.1 or uv.x > 1.1 or uv.y < -0.1 or uv.y > 1.1:
		return
	_stamps.push_back(Vector4(uv.x, uv.y, radius / WINDOW_SIZE, depth / max_depth))

## Advance the field one frame. Call after the simulation, before drawing.
func update(center_x: float, center_z: float, delta: float) -> void:
	if not _initialized:
		return
	# Snap the window to whole texels so scrolling never resamples the field.
	var texel: float = WINDOW_SIZE / float(RESOLUTION)
	_prev_origin = _origin
	_origin = Vector2(
		floor((center_x - WINDOW_SIZE * 0.5) / texel) * texel,
		floor((center_z - WINDOW_SIZE * 0.5) / texel) * texel)

	var target: int = 1 - _current
	var mat: ShaderMaterial = _materials[target]
	mat.set_shader_parameter("prev_tex", _viewports[_current].get_texture())
	mat.set_shader_parameter("scroll_uv", (_origin - _prev_origin) / WINDOW_SIZE)
	mat.set_shader_parameter("first_frame", _first_frame)
	mat.set_shader_parameter("depth_decay", exp(-delta / refill_tau))
	mat.set_shader_parameter("pack_decay", exp(-delta / pack_tau))
	mat.set_shader_parameter("stamp_count", _stamps.size())
	if not _stamps.is_empty():
		# Duplicate: the material keeps a reference to the packed array, and
		# clearing ours below would clear the one the shader reads.
		mat.set_shader_parameter("stamps", _stamps.duplicate())

	_viewports[target].render_target_update_mode = SubViewport.UPDATE_ONCE
	_current = target
	_first_frame = false
	_stamps = PackedVector4Array()

## Wipe the field — new race, or the player was teleported.
func reset() -> void:
	_first_frame = true
	_stamps = PackedVector4Array()
