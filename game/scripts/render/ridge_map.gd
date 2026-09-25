## The distant ridges baked into a texture, once per race, for the fog.
##
## Every lit surface writes its own `FOG`, and past about 80 m that fog fades
## into whatever stands behind the surface — the ridges, which are three layers
## of noise evaluated per direction (`atmosphere.gdshaderinc`). Evaluated per
## fragment of every far slope and tree, that cost about a millisecond a frame
## on the desktop's iGPU. Nothing about them changes during a race except how
## far they have sunk ([member Atmosphere.advance]'s drop), and they are worked
## out before the drop, so one bake serves the whole race: the fog then reads
## two texels. The sky still evaluates them itself, since its crests have to be
## sharp at any resolution.
##
## Baked on the next frame drawn after [method bake], which is before anything
## that reads it: a [SubViewport] is drawn ahead of the viewport it sits in.
## Anywhere there is no map `atmo_ridge_baked` is 0, and far surfaces fade
## into the plain sky: the fog deliberately has no way to evaluate the ridges
## itself (see the include for why).
class_name RidgeMap
extends SubViewport

## Keep in step with `ATMO_MAP_WIDTH` and `ATMO_MAP_ROWS` in the include:
## columns once round the horizon, and twice the rows — colour above, the
## haze's share below. 4096 columns is about a pixel's worth at 720p and a
## 70-degree field of view, which is as sharp as the fog ever drew them.
const WIDTH := 4096
const ROWS := 512

const SHADER := "res://shaders/ridge_map_bake.gdshader"

func _init() -> void:
	name = "RidgeMap"
	size = Vector2i(WIDTH, ROWS * 2)
	disable_3d = true
	# Coverage is in the alpha channel, so keep it.
	transparent_bg = true
	msaa_2d = Viewport.MSAA_DISABLED
	render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	var rect := ColorRect.new()
	rect.size = Vector2(WIDTH, ROWS * 2)
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	rect.material = mat
	add_child(rect)

## Draw the map from the atmosphere's globals as they stand — call it after
## [method Atmosphere.apply] — and point the fog at it.
func bake() -> void:
	render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.global_shader_parameter_set("atmo_ridge_map", get_texture())
	RenderingServer.global_shader_parameter_set("atmo_ridge_baked", 1.0)

## Stop the fog reading the map: under `[display] sky = etr`, where there
## are no ridges, and when the map goes away with its race.
func clear() -> void:
	RenderingServer.global_shader_parameter_set("atmo_ridge_baked", 0.0)

func _exit_tree() -> void:
	clear()
	RenderingServer.global_shader_parameter_set("atmo_ridge_map", null)
