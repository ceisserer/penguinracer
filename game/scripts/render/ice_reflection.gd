## The penguin the ice gives back: a planar mirror pass, drawn once per frame.
##
## DEVIATION: ETR reflects nothing. Its ice terrains differ from its snow only
## by texture and by `[friction]` (`is_ice()`), and `DrawCharacter` draws the
## penguin exactly once. This is the same kind of addition as the Fresnel sky
## ramp already on ice — a view-dependent term for the one surface in the game
## that is a smooth dielectric — and it is switched off by
## [member GameConfig.ice_reflections].
##
## [b]Why a second camera.[/b] Architecture rule 2: Compatibility has no SSR, no
## `RenderingDevice` and no reflection probes worth the name, so the only
## reflection available is the fixed-function one — render the thing again from
## the mirrored viewpoint and blend the result in where the surface says it is
## reflective. That blend is [TerrainRenderer]'s; this class owns the pass.
##
## [b]Why it shares the World3D.[/b] The [SubViewport] renders the very rigs the
## main pass renders, from a camera reflected through the ice plane, with
## `cull_mask` narrowed to [constant RACER_VISUAL_LAYER] so the terrain does not
## appear in the reflection of the terrain. There is no duplicate rig and no
## pose to copy: whatever [method Racer.present] posed is what gets mirrored, so
## a ghost, a computer opponent and a remote peer are reflected without this
## file knowing any of them exist. That is architecture rule 8 paying out again
## — the reflection is one more thing that reads a drawn racer and cannot tell
## who is driving it.
##
## [b]The determinant.[/b] A reflection is orientation-reversing, so the camera
## basis comes out with a determinant of −1 and the triangle winding in that
## pass is inverted. Sharing the world means the materials are shared too, so
## there is no per-pass cull mode to fix it with — which would matter if it
## needed fixing. Spike S7 measured it: `CULL_BACK`, `CULL_FRONT` and
## `CULL_DISABLED` all render the mirrored image identically, because the
## renderer flips the front face itself for a negative-determinant view matrix.
## Character materials are therefore untouched.
##
## [b]The plane.[/b] A planar reflection needs a plane and the terrain is a
## heightmap, so there is exactly one honest answer: the tangent plane under the
## racer being watched. That is not an approximation where it matters — the
## penguin's feet are *on* the anchor point, so the reflection is attached
## exactly where the eye checks it, and the error grows with height above the
## surface, over the metre or so of penguin above it. Everywhere else on the
## hill the error grows without bound, which is what
## [member fade_distance] is for: see [method TerrainRenderer.set_character_reflection].
class_name IceReflection
extends Node

## The visual layer racers are drawn on in addition to layer 1, and the only
## layer this pass renders. Set by [method Racer.install_character]; nothing
## else in the game uses layers, so the whole convention is these two files.
const RACER_VISUAL_LAYER := 1 << 1

## Fraction of the main viewport the mirror is rendered at. A reflection in ice
## is the one image in the frame that is allowed to be soft — it is scattered by
## the surface it comes off — so half resolution is a quarter of the fill for no
## cost anybody can point at, and it stacks with
## [member GameConfig.render_scale] rather than fighting it.
const RESOLUTION_SCALE := 0.5
## Never smaller than this on either axis, whatever the render scale is.
const MIN_RESOLUTION := Vector2i(160, 90)

## Seconds for the mirror plane's normal to follow the terrain's by 1/e.
##
## The plane is re-derived every frame from the surface under a racer who is
## moving at 20 m/s over a heightmap with metre-scale structure, and an
## unsmoothed normal swings the whole reflected image about with every bump.
## The reflection is a soft additive term and nobody can see that it lags; they
## can very much see it swim.
const NORMAL_TAU := 0.12

## Off is the shipped behaviour on nothing — this defaults on and
## [member GameConfig.ice_reflections] turns it off. A disabled pass frees its
## render target rather than rendering into one nobody samples.
var enabled: bool = true:
	set(value):
		if enabled == value:
			return
		enabled = value
		_apply_enabled()

## Metres from the mirror plane at which a fragment stops taking the reflection
## at all. Passed through to the shader; see there for what it protects against.
var fade_distance: float = 8.0

var _viewport: SubViewport
var _camera: Camera3D
var _plane_point: Vector3 = Vector3.ZERO
var _plane_normal: Vector3 = Vector3.UP
var _has_plane: bool = false

func _ready() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "MirrorViewport"
	# The whole design in one line: no world of its own, so the racers already
	# in the scene are what this camera sees.
	_viewport.own_world_3d = false
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
	# A mirror of a soft additive term does not need to be antialiased, and this
	# is a second full-screen target on a WebGL2 budget.
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.positional_shadow_atlas_size = 0
	add_child(_viewport)

	_camera = Camera3D.new()
	_camera.name = "MirrorCamera"
	_camera.cull_mask = RACER_VISUAL_LAYER
	_viewport.add_child(_camera)
	_camera.make_current()
	_apply_enabled()

## The mirror, or `null` when the pass is off. Handed to the terrain material.
func texture() -> Texture2D:
	if not enabled or _viewport == null:
		return null
	return _viewport.get_texture()

## Where the mirror plane sits, in world space. Only meaningful once
## [method update] has been called with a racer to hang it on.
func plane_point() -> Vector3:
	return _plane_point

## The mirror plane's normal, smoothed — see [constant NORMAL_TAU].
func plane_normal() -> Vector3:
	return _plane_normal

## Whether a plane has been established yet. False before the first
## [method update] of a race, when there is nothing to reflect in.
func has_plane() -> bool:
	return _has_plane

## Match the reflection's air to the main pass's.
##
## The [DirectionalLight3D] is in the shared world and needs no copying, but the
## [Environment] does not live in the world — it hangs off the [WorldEnvironment]
## of the viewport that is rendering. Without this the mirrored penguin is lit
## by Godot's default ambient and comes back a different colour from the penguin
## casting it.
##
## The background is the one thing that must differ: [constant
## Environment.BG_CLEAR_COLOR] against a transparent target is what makes the
## alpha channel mean "there is a penguin here", which is the whole of how the
## terrain shader knows where to put it. Fog is deliberately kept — the
## reflected image is seen through the same air, over very nearly the same path
## length, so it should haze out with distance exactly as its subject does.
func set_environment(source: Environment) -> void:
	if _camera == null:
		return
	if source == null:
		_camera.environment = null
		return
	var env: Environment = source.duplicate() as Environment
	env.background_mode = Environment.BG_CLEAR_COLOR
	_camera.environment = env

## Aim the mirror for this frame.
##
## [param point] and [param normal] describe the ice under the racer being
## watched; [param source] is the camera the player is actually looking through.
## Called from [method RaceScene._present], at the screen's rate — a reflection
## is presentation and nothing in the race may read it (architecture rule 7).
func update(source: Camera3D, point: Vector3, normal: Vector3, delta: float) -> void:
	if not enabled or _camera == null or source == null:
		return
	_resize_to(source.get_viewport())

	var n: Vector3 = normal.normalized() if normal.length_squared() > 0.0 else Vector3.UP
	if not _has_plane:
		_plane_normal = n
		_has_plane = true
	else:
		# Exponential smoothing written against the frame time rather than a
		# fixed step, because this runs on the screen's rate and the screen's
		# rate is not ours to choose.
		_plane_normal = _plane_normal.lerp(n,
			1.0 - exp(-delta / maxf(NORMAL_TAU, 0.001))).normalized()
	_plane_point = point

	_camera.global_transform = mirror_transform(source.global_transform,
		_plane_point, _plane_normal)
	# Everything about the lens is the main camera's, or the reflection lands on
	# a different pixel than the surface reflecting it.
	_camera.fov = source.fov
	_camera.near = source.near
	_camera.far = source.far
	_camera.keep_aspect = source.keep_aspect

## Reflect [param t] through the plane through [param point] with normal
## [param normal].
##
## Static and free of the node so the suite can check the geometry without a
## viewport: a point on the plane must come back unmoved, the normal must come
## back negated, and applying it twice must be the identity.
static func mirror_transform(t: Transform3D, point: Vector3,
		normal: Vector3) -> Transform3D:
	var n: Vector3 = normal.normalized()
	# Householder: v ↦ v − 2 (v·n) n, one column at a time. This is where the
	# determinant of −1 comes from, and it is not avoidable — no rotation takes
	# a thing to its own mirror image.
	var reflect := Basis(
		Vector3(1.0, 0.0, 0.0) - 2.0 * n.x * n,
		Vector3(0.0, 1.0, 0.0) - 2.0 * n.y * n,
		Vector3(0.0, 0.0, 1.0) - 2.0 * n.z * n)
	var offset: Vector3 = t.origin - point
	return Transform3D(reflect * t.basis,
		point + offset - 2.0 * offset.dot(n) * n)

## Forget the plane, so the next frame establishes a fresh one rather than
## easing the normal across from wherever the last race left it.
func reset() -> void:
	_has_plane = false
	_plane_normal = Vector3.UP
	_plane_point = Vector3.ZERO

func _apply_enabled() -> void:
	if _viewport == null:
		return
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled \
		else SubViewport.UPDATE_DISABLED
	if not enabled:
		# Give the target back. A disabled pass that keeps a full-screen RGBA8
		# buffer alive is the memory cost of the feature with none of the
		# feature, which on the web build is the tier this setting exists for.
		_viewport.size = MIN_RESOLUTION
	if _camera != null:
		_camera.current = enabled

func _resize_to(source: Viewport) -> void:
	if source == null:
		return
	var want: Vector2i = Vector2i(Vector2(source.size) * RESOLUTION_SCALE)
	want = want.max(MIN_RESOLUTION)
	if _viewport.size != want:
		_viewport.size = want
