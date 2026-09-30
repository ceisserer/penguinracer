## The world the ice gives back: a small cube map rendered round the racer
## being watched, sampled by the ice for everything that is not a racer.
##
## DEVIATION: ETR reflects nothing. [IceReflection] already mirrors the racers;
## this is the rest of the hill — the trees round a frozen lake, the far bank,
## the sky as it is actually drawn rather than [TerrainRenderer]'s two-colour
## ramp. The ramp stays underneath as the fallback, and is what the ice shows
## wherever this is off.
##
## [b]Why a cube and not the mirror camera.[/b] The planar pass is true on one
## plane only, the tangent plane under the watched racer, and its error grows
## without bound away from it — that is what its 8 m fade is for. Trees 40 m
## off across a lake are exactly the far field that plane gets wrong. A cube
## taken from the ice has no plane: it is what a mirror anywhere near the probe
## would see, for any tilt of the surface, so a banked wall and a flat lake are
## the same lookup. What it gives up is parallax — see [member radius].
##
## [b]Why an atlas and not a [Cubemap].[/b] A [SubViewport] renders into a 2D
## target, and turning six of those into a cube map is a GPU readback per face,
## which is a stall (architecture rule 3's reasoning, if not its letter). So the
## six faces are drawn side by side into one 3x2 target by a 2D pass, entirely
## on the GPU, and `terrain.gdshader` picks the face and the texel itself. One
## sampler either way — which matters, because it is the last one the terrain
## shader can have (see below).
##
## [b]The 16th sampler, and only when asked for.[/b] Under Compatibility the
## terrain shader already binds 15, and WebGL2 guarantees 16 — which is what
## most real browsers report. The atlas is declared only under `ICE_ENV_ATLAS`,
## which [TerrainRenderer] defines in a variant of the shader it builds when
## [member GameConfig.ice_world_reflections] is on: with the setting off, the
## terrain is compiled exactly as it was before this class existed, 15 units
## and all. Godot's GLES3 back end binds its own textures counting down from the
## top of the device's range (`// texunit:-2` radiance, `-3` shadows, `-6`/`-7`
## screen and depth), none of which the terrain uses in a browser, so the 16th
## should land on a free unit — but nothing here reports 16 (headless
## Chromium's SwiftShader offers 32), so on the web this is the setting's risk
## to carry, and switching it off is the way back.
##
## [b]What is not in it.[/b] The racers (the mirror pass has them, and a
## penguin a metre from the probe would fill half the cube), their spray and
## the falling snow — everything drawn round the player rather than on the
## hill. Those live on [constant NEAR_FIELD_LAYER] instead of layer 1, and the
## probe's cameras leave that layer out.
##
## [b]Cost, and the probe's own sun.[/b] Every face is a whole scene render,
## and every render that sees a shadowed sun redraws that sun's cascades — on
## Forest Trail 67 ms a frame for the six faces on the desktop's iGPU (Renoir,
## 1600x900), four times the main view, flat in the face size. A viewport has
## no switch for it, but a camera's `cull_mask` does cull directional lights
## (`RendererSceneCull::_render_scene`): so the sun moves to
## [constant SUN_LAYER], which the faces leave out, and the faces see a copy
## of it on [constant PROBE_SUN_LAYER] with no shadows, which the main camera
## leaves out ([method attach_sun]). The faces then cost 14 ms, and 4 once
## [CourseRoot] cut its props into cells. The reflection loses the sun's
## shadows — a 128² image, broken up and hazed; baked tree shadows stay.
## The whole cube is still re-taken every frame. Taking it every 3 m instead
## cost a sixth as much and read as a stutter: the reflection jumped each time
## the probe caught up. Beyond that, nothing at all is drawn while no ice is
## within [constant ACTIVE_RANGE] of the camera. Most courses have none.
class_name IceEnvironment
extends Node

## The layer racers, spray and snowfall are drawn on *instead of* layer 1.
## The main camera sees every layer; the probe sees every layer but this one and
## [constant IceReflection.RACER_VISUAL_LAYER].
const NEAR_FIELD_LAYER := 1 << 2
## The layer the real, shadowed sun is moved to, so the probe can leave it out.
const SUN_LAYER := 1 << 3
## The layer of the probe's shadowless copy of it, which the main camera leaves
## out. See [method attach_sun].
const PROBE_SUN_LAYER := 1 << 4

## Texels along a face's edge. The reflection is broken up by the ice's
## micro-relief and hazed by Fresnel, so a soft image is the right one.
const FACE_SIZE := 128
## Metres above the drawn ice the probe sits. The right viewpoint for a mirror
## is the mirror itself; this is just enough to keep the micro-relief and the
## trench out of the bottom face.
const PROBE_HEIGHT := 0.5
## Metres round the probe that its cameras leave out — their near plane.
##
## [b]A cube map magnifies whatever is close to its centre.[/b] A flag a metre
## from the probe spans some 6° by 50° of a face, and every ice pixel whose
## mirror ray falls in that wedge takes the flag's colour: a stripe of red ice
## from the horizon to the bottom of the screen, there for the few frames the
## racer takes to pass it. A canyon wall at arm's length did the same on a
## larger scale — half of `inception`'s floor one flat pale blue. Anything this
## close was never drawn in the right place anyway: the lookup assumes the
## world stands [member radius] out. Clipped at 5 m, a flag covers a degree or
## two, a wall the probe is hugging gives way to what lies across from it, and
## the far field — the only part a cube gets right — is untouched.
const PROBE_NEAR := 5.0
## Metres from the camera within which ice switches the probe on. The fog is
## full by 150 m (see the fog deviation) and a reflection in ice that far off is
## a few pixels of haze.
const ACTIVE_RANGE := 90.0
## Seconds for the term to fade in and out, so the ice does not pop from the
## ramp to the world when a lake comes into range.
const FADE_TIME := 0.5
## Sample spacing of the ice map, and the size of the cells it is kept in.
const ICE_SAMPLE := 4.0
const ICE_CELL := 16.0

## One row per face: where it looks and which way is up on it. The order and
## the bases are a contract with `ice_env_uv` in `terrain.gdshader` — change
## one, change both. [method face_uv] is the GDScript twin the suite checks
## the cameras against.
const FACE_FORWARD: Array[Vector3] = [
	Vector3(1, 0, 0), Vector3(-1, 0, 0),
	Vector3(0, 1, 0), Vector3(0, -1, 0),
	Vector3(0, 0, 1), Vector3(0, 0, -1)]
const FACE_UP: Array[Vector3] = [
	Vector3(0, 1, 0), Vector3(0, 1, 0),
	Vector3(0, 0, 1), Vector3(0, 0, -1),
	Vector3(0, 1, 0), Vector3(0, 1, 0)]

## Metres out from the probe at which the reflected world is assumed to stand.
##
## A cube map has no depth, so a lookup by direction alone reflects everything
## as if it were infinitely far — right for the sky, wrong for a tree across
## the lake from ice that is not where the probe is. Intersecting the mirror ray
## with a sphere of this radius first, and looking up the direction *from the
## probe* to that point, puts the far bank back roughly where it stands. Passed
## to the shader, which also fades the term out toward it: ice beyond the
## sphere is outside everything the probe can speak for.
var radius: float = 60.0

var _atlas: SubViewport
var _sun: DirectionalLight3D
var _probe_sun: DirectionalLight3D
var _faces: Array[SubViewport] = []
var _cameras: Array[Camera3D] = []
var _origin: Vector3 = Vector3.ZERO
var _active: bool = false
# Frames the faces have been drawing for. The first one's atlas is whatever the
# target held before, so the term waits a frame before it starts fading in.
var _frames: int = 0
var _strength: float = 0.0

# The ice map: one byte per ICE_CELL cell, 1 where ice lies within ACTIVE_RANGE.
var _near_ice: PackedByteArray = PackedByteArray()
var _near_size: Vector2i = Vector2i.ZERO

func _ready() -> void:
	_atlas = SubViewport.new()
	_atlas.name = "Atlas"
	_atlas.size = Vector2i(FACE_SIZE * 3, FACE_SIZE * 2)
	_atlas.disable_3d = true
	_atlas.transparent_bg = false
	_atlas.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	for i: int in 6:
		var face := SubViewport.new()
		face.name = "Face%d" % i
		face.size = Vector2i(FACE_SIZE, FACE_SIZE)
		# The shared world, like the mirror: the hill is already in it.
		face.own_world_3d = false
		face.handle_input_locally = false
		face.msaa_3d = Viewport.MSAA_DISABLED
		face.positional_shadow_atlas_size = 0
		add_child(face)
		var cam := Camera3D.new()
		cam.name = "Camera"
		cam.fov = 90.0
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.near = PROBE_NEAR
		cam.cull_mask = 0xFFFFF & ~(NEAR_FIELD_LAYER | IceReflection.RACER_VISUAL_LAYER | SUN_LAYER)
		face.add_child(cam)
		cam.make_current()
		_faces.push_back(face)
		_cameras.push_back(cam)
		var rect := TextureRect.new()
		rect.texture = face.get_texture()
		rect.position = Vector2((i % 3) * FACE_SIZE, (i / 3) * FACE_SIZE)
		rect.size = Vector2(FACE_SIZE, FACE_SIZE)
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		_atlas.add_child(rect)
	# After the faces, so that tree order — which is what Godot sorts sibling
	# viewports by, as far as can be told — draws it after them. Were it drawn
	# first it would hold last frame's cube against this frame's origin: a
	# sixtieth of a second of parallax, not a visible error.
	add_child(_atlas)
	_apply_active(false)

## The atlas, for the terrain material.
func texture() -> Texture2D:
	return _atlas.get_texture() if _atlas != null else null

## Where the cube was taken from — the centre of [member radius].
func origin() -> Vector3:
	return _origin

## How much of the ice's reflection comes from the probe this frame, 0..1.
## Zero until a cube has been drawn, then eased by [constant FADE_TIME].
func strength() -> float:
	return _strength

## The same lens, the same far plane, the same air as the main pass. The
## environment is set on each camera for the reason
## [method IceReflection.set_environment] gives; unlike the mirror, the probe
## wants the sky drawn, so it takes the environment as it is.
func set_environment(env: Environment) -> void:
	for cam: Camera3D in _cameras:
		cam.environment = env

## Light the probe with a shadowless copy of [param sun], and keep [param sun]
## itself — and its cascades — for [param main_camera] alone. The copy follows
## the sun in [method update], so a preset, a lightning flash or a night is
## the same light in both.
func attach_sun(sun: DirectionalLight3D, main_camera: Camera3D) -> void:
	_sun = sun
	sun.layers = SUN_LAYER
	main_camera.cull_mask &= ~PROBE_SUN_LAYER
	_probe_sun = DirectionalLight3D.new()
	_probe_sun.name = "ProbeSun"
	_probe_sun.layers = PROBE_SUN_LAYER
	_probe_sun.shadow_enabled = false
	add_child(_probe_sun)
	_follow_sun()

func _follow_sun() -> void:
	if _probe_sun == null or not is_instance_valid(_sun):
		return
	_probe_sun.global_transform = _sun.global_transform
	_probe_sun.visible = _sun.visible
	_probe_sun.light_color = _sun.light_color
	_probe_sun.light_energy = _sun.light_energy
	_probe_sun.light_indirect_energy = _sun.light_indirect_energy
	_probe_sun.light_specular = _sun.light_specular
	_probe_sun.light_angular_distance = _sun.light_angular_distance
	_probe_sun.light_cull_mask = _sun.light_cull_mask
	_probe_sun.sky_mode = _sun.sky_mode

## Build the ice map for a course: which parts of it have ice close enough to
## the camera to be worth a probe. Once per course load.
func build_ice_map(surface: HeightmapSurface, layers: Array[TerrainLayer]) -> void:
	_near_ice = PackedByteArray()
	_near_size = Vector2i.ZERO
	if surface == null or layers.is_empty():
		return
	var ice_layer := PackedByteArray()
	ice_layer.resize(layers.size())
	var any: bool = false
	for l: int in layers.size():
		ice_layer[l] = 1 if layers[l] != null and layers[l].is_ice() else 0
		any = any or ice_layer[l] == 1
	if not any:
		return
	var world: Vector2 = surface.world_size
	var cells := Vector2i(ceili(world.x / ICE_CELL), ceili(world.y / ICE_CELL))
	var has_ice := PackedByteArray()
	has_ice.resize(cells.x * cells.y)
	has_ice.fill(0)
	var sample := SurfaceSample.new()
	var steps := Vector2i(ceili(world.x / ICE_SAMPLE), ceili(world.y / ICE_SAMPLE))
	var found: bool = false
	for sz: int in steps.y:
		for sx: int in steps.x:
			var x: float = (float(sx) + 0.5) * ICE_SAMPLE
			var z: float = -(float(sz) + 0.5) * ICE_SAMPLE
			surface.sample_into(x, z, sample)
			if sample.terrain_id < ice_layer.size() and ice_layer[sample.terrain_id] == 1:
				var cx: int = mini(int(x / ICE_CELL), cells.x - 1)
				var cz: int = mini(int(-z / ICE_CELL), cells.y - 1)
				has_ice[cz * cells.x + cx] = 1
				found = true
	if not found:
		return
	# Dilate by the range, in whole cells and a square rather than a disc: the
	# test is "worth rendering", and a corner of slack costs nothing.
	var reach: int = ceili(ACTIVE_RANGE / ICE_CELL)
	_near_ice.resize(cells.x * cells.y)
	_near_ice.fill(0)
	for cz: int in cells.y:
		for cx: int in cells.x:
			if has_ice[cz * cells.x + cx] == 0:
				continue
			for dz: int in range(maxi(cz - reach, 0), mini(cz + reach + 1, cells.y)):
				for dx: int in range(maxi(cx - reach, 0), mini(cx + reach + 1, cells.x)):
					_near_ice[dz * cells.x + dx] = 1
	_near_size = cells

## Whether any ice lies within about [constant ACTIVE_RANGE] of world point
## [param at]. False on a course with no ice anywhere.
func ice_near(at: Vector3) -> bool:
	if _near_size == Vector2i.ZERO:
		return false
	var cx: int = int(floor(at.x / ICE_CELL))
	var cz: int = int(floor(-at.z / ICE_CELL))
	if cx < 0 or cz < 0 or cx >= _near_size.x or cz >= _near_size.y:
		return false
	return _near_ice[cz * _near_size.x + cx] == 1

## Move the probe to [param ground] (the drawn ice under the watched racer):
## all six faces are drawn from there this frame, and the shader is told the
## same point, so the cube and its lookup always agree. [param camera] decides
## whether there is ice worth rendering for, and lends the probe its far plane.
func update(camera: Camera3D, ground: Vector3, delta: float) -> void:
	if _atlas == null:
		return
	var want: bool = camera != null and ice_near(camera.global_position)
	if want != _active:
		_apply_active(want)
	if _active:
		_follow_sun()
		_origin = ground + Vector3.UP * PROBE_HEIGHT
		for i: int in 6:
			_cameras[i].global_transform = Transform3D(face_basis(i), _origin)
			_cameras[i].far = camera.far
		_frames += 1
	var target: float = 1.0 if _active and _frames > 1 else 0.0
	_strength = move_toward(_strength, target, delta / FADE_TIME)

## Forget the last cube, so a restart does not reflect wherever the last run
## ended for the first few frames.
func reset() -> void:
	_frames = 0
	_strength = 0.0

func _apply_active(active: bool) -> void:
	_active = active
	_frames = 0
	var mode: SubViewport.UpdateMode = SubViewport.UPDATE_ALWAYS if active \
		else SubViewport.UPDATE_DISABLED
	for face: SubViewport in _faces:
		face.render_target_update_mode = mode
	if _atlas != null:
		_atlas.render_target_update_mode = mode

## The camera basis for face [param i]: looking down −Z along
## [constant FACE_FORWARD], with Y along [constant FACE_UP].
static func face_basis(i: int) -> Basis:
	var f: Vector3 = FACE_FORWARD[i]
	var up: Vector3 = FACE_UP[i]
	return Basis(f.cross(up), up, -f)

## Where direction [param d] lands in the atlas: the GDScript twin of
## `ice_env_uv` in `terrain.gdshader`, for the suite. Returns the atlas UV,
## with (0, 0) the top-left corner as a viewport texture is sampled.
static func face_uv(d: Vector3) -> Vector2:
	var a: Vector3 = d.abs()
	var face: int
	if a.x >= a.y and a.x >= a.z:
		face = 0 if d.x > 0.0 else 1
	elif a.y >= a.z:
		face = 2 if d.y > 0.0 else 3
	else:
		face = 4 if d.z > 0.0 else 5
	var f: Vector3 = FACE_FORWARD[face]
	var up: Vector3 = FACE_UP[face]
	var right: Vector3 = f.cross(up)
	var depth: float = d.dot(f)
	var s := Vector2(d.dot(right), d.dot(up)) / depth
	var uv := Vector2(s.x + 1.0, 1.0 - s.y) * 0.5
	return (Vector2(face % 3, face / 3) + uv) / Vector2(3.0, 2.0)
