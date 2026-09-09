## Spike S7 — planar character reflection under the Compatibility renderer.
##
## Compatibility has no SSR and no RenderingDevice (architecture rule 2), so the
## only way to put a penguin into the ice is the fixed-function one: render the
## character a second time, mirrored through the ice plane, into a
## [SubViewport], and let the terrain shader add that render target where
## `ice_mask` says there is ice.
##
## Three things had to be observed rather than assumed:
##   1. a [SubViewport] renders 3D at all here, and a spatial shader can sample
##      its texture by SCREEN_UV and land it on the right pixel;
##   2. whether that needs a Y flip;
##   3. [b]which of the two ways to mirror actually works[/b] — see below.
##
## [b]The two candidates.[/b] A reflection is orientation-reversing, so one of
## the two passes ends up with a determinant −1 basis and inverted winding, and
## the question is which side pays for it:
##
## [codeblock]
## SHARED   one SubViewport on the *same* World3D, camera mirrored through the
##          plane, cull_mask limited to the racer layer. No duplicate anything:
##          the reflection draws the very rigs the main pass draws, so it is
##          free of pose copying and covers ghosts and peers automatically.
##          Costs: the camera basis is det −1, and the materials are shared
##          with the main pass, so the winding cannot be fixed per-pass.
##
## OWN      a SubViewport with its own World3D holding a mirrored *duplicate*
##          of the character. The camera is an ordinary copy of the main one,
##          so det −1 lands on geometry this pass exclusively owns and its
##          material can simply say CULL_FRONT. Costs: a duplicate rig per
##          reflected racer, and its pose has to be driven every frame.
## [/codeblock]
##
## SHARED is much the better design if the renderer tolerates it. This scene
## runs both and checks them against each other.
##
## Verified numerically, in the S1 spirit: a red marker above the plane must
## show up red in the plane's reflection band and nowhere else.
##
## [b]Result — PASS, and SHARED is what shipped.[/b] Three findings, all
## measured on the container's AMD GPU under `--rendering-driver opengl3`:
##
## [enum]
## [*] Both modes render identically (reflection patch r=0.669 against a control
##     patch of r=0.616, in both). A [SubViewport] on a shared [World3D] with a
##     determinant −1 camera is fine here, so [IceReflection] carries no
##     duplicate rigs and reflects ghosts and peers for free.
## [*] The winding needs no fixing. `S7_CULL=back`, `front` and `disabled` all
##     produce r=0.669 to three decimals, so the renderer flips the front face
##     itself for a negative-determinant view matrix and character materials are
##     left alone. This is the finding that removed a whole material-duplication
##     path from the design.
## [*] SCREEN_UV lands the right way up. No Y flip.
## [/enum]
##
## And the one that shaped the shader: [b]the Fresnel weight is about 0.02–0.09
## at the angle a chase camera sits at[/b] — probing `EMISSION = vec3(fresnel)`
## moved the plane by 0.004. An *additive* reflection at that weight is
## invisible, which is the same wall AGENTS.md records the sky ramp hitting
## ("0.09 of sky over an already near-white albedo is four levels nobody sees").
## The answer was to stop adding: in `terrain.gdshader` the racers *occlude* the
## sky the ice was already reflecting, so a dark penguin reads as a dark shape
## on bright ice rather than as a glow that has to out-shout it. Measured on
## `tuxway`, that is 17 levels against a run-to-run noise floor of zero.
##
##     godot --path game --rendering-driver opengl3 res://spikes/s7_reflection/s7_spike.tscn
##
## `S7_MODE=own|shared`, `S7_CULL=back|front|disabled`, `S7_STRENGTH=<float>`.
extends Node3D

const TEST_FRAMES := 30
## Where the marker stands. The mirror plane is y = 0.
const MARKER_POS := Vector3(0.0, 1.2, 0.0)
## The visual layer the reflection pass is allowed to see. Layer 1 is everything
## else; the ground must not appear in the reflection of the ground.
const RACER_LAYER := 2

var _mode: String = "shared"
var _vp: SubViewport
var _reflect_cam: Camera3D
var _mirror: MeshInstance3D
var _cam: Camera3D
var _material: ShaderMaterial
var _marker_mesh: BoxMesh
var _marker_material: StandardMaterial3D
var _frame: int = 0
var _results: PackedStringArray = PackedStringArray()
var _done: bool = false

func _ready() -> void:
	_mode = OS.get_environment("S7_MODE")
	if _mode.is_empty():
		_mode = "shared"

	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	_material = ShaderMaterial.new()
	_material.shader = load("res://spikes/s7_reflection/s7_ice.gdshader")
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = plane
	ground.material_override = _material
	add_child(ground)

	_marker_mesh = BoxMesh.new()
	_marker_mesh.size = Vector3(0.8, 1.6, 0.8)
	_marker_material = StandardMaterial3D.new()
	_marker_material.albedo_color = Color(1.0, 0.05, 0.05)
	_marker_material.roughness = 0.9
	# Shared with the reflection in SHARED mode, where the winding is inverted
	# and cannot be fixed per-pass. Whether that costs anything is the third
	# thing this spike measures: `S7_CULL=back` asks the renderer to cull the
	# way it normally would and sees whether the mirrored image survives it.
	match OS.get_environment("S7_CULL"):
		"back":
			_marker_material.cull_mode = BaseMaterial3D.CULL_BACK
		"front":
			_marker_material.cull_mode = BaseMaterial3D.CULL_FRONT
		_:
			_marker_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var marker := MeshInstance3D.new()
	marker.name = "Marker"
	marker.mesh = _marker_mesh
	marker.material_override = _marker_material
	marker.position = MARKER_POS
	marker.layers = RACER_LAYER
	add_child(marker)

	_cam = Camera3D.new()
	# A chase camera's grazing angle: low and looking slightly down, which is
	# where the Fresnel term the game already computes is strongest.
	_cam.look_at_from_position(Vector3(0.0, 2.2, 7.0), Vector3(0.0, 0.9, 0.0), Vector3.UP)
	# Layer 1 only would hide the marker; the main pass sees everything.
	add_child(_cam)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	add_child(sun)

	var world_env := WorldEnvironment.new()
	world_env.environment = _make_environment(Environment.BG_COLOR)
	add_child(world_env)

	_vp = SubViewport.new()
	_vp.name = "ReflectionViewport"
	_vp.size = get_viewport().size
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	if _mode == "shared":
		_build_shared()
	else:
		_build_own_world()
	add_child(_vp)
	_material.set_shader_parameter("reflection_map", _vp.get_texture())
	var strength: String = OS.get_environment("S7_STRENGTH")
	_material.set_shader_parameter("reflection_strength",
		8.0 if strength.is_empty() else float(strength))

## SHARED: no duplicate. The reflection camera looks at the same rigs the main
## camera does, from the mirrored viewpoint, and `cull_mask` keeps the ground
## out of its own reflection. The environment override is what makes the pass
## transparent without a second World3D to put a different one in.
func _build_shared() -> void:
	_vp.own_world_3d = false
	_reflect_cam = Camera3D.new()
	_reflect_cam.cull_mask = RACER_LAYER
	_reflect_cam.environment = _make_environment(Environment.BG_CLEAR_COLOR)
	_vp.add_child(_reflect_cam)
	_reflect_cam.make_current()

## OWN: a duplicate, mirrored, in a world of its own, so its material can say
## CULL_FRONT and the camera stays an honest copy of the main one.
func _build_own_world() -> void:
	_vp.own_world_3d = true
	var env := WorldEnvironment.new()
	env.environment = _make_environment(Environment.BG_CLEAR_COLOR)
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	_vp.add_child(sun)
	_mirror = MeshInstance3D.new()
	_mirror.name = "MirroredMarker"
	_mirror.mesh = _marker_mesh
	var mat: StandardMaterial3D = _marker_material.duplicate()
	mat.cull_mode = BaseMaterial3D.CULL_FRONT
	_mirror.material_override = mat
	_vp.add_child(_mirror)
	_reflect_cam = Camera3D.new()
	_vp.add_child(_reflect_cam)
	_reflect_cam.make_current()

func _make_environment(bg: int) -> Environment:
	var env := Environment.new()
	env.background_mode = bg as Environment.BGMode
	env.background_color = Color(0.05, 0.06, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.6)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	return env

## Reflect a transform through the plane through `plane_point` with normal
## `plane_normal`. The basis picks up a determinant of −1, which is the whole
## difficulty: a mirror image cannot be reached by any rotation.
static func mirror_transform(t: Transform3D, plane_point: Vector3,
		plane_normal: Vector3) -> Transform3D:
	var n: Vector3 = plane_normal.normalized()
	# Householder: v ↦ v − 2 (v·n) n, and the origin about the plane's own point.
	var reflect := Basis(
		Vector3(1, 0, 0) - 2.0 * n.x * n,
		Vector3(0, 1, 0) - 2.0 * n.y * n,
		Vector3(0, 0, 1) - 2.0 * n.z * n)
	var offset: Vector3 = t.origin - plane_point
	return Transform3D(reflect * t.basis,
		plane_point + offset - 2.0 * offset.dot(n) * n)

func _process(_delta: float) -> void:
	if _done:
		return
	if _mode == "shared":
		# Mirror the camera. In the game this plane is the ice under the
		# racer's contact point, not the world origin.
		_reflect_cam.global_transform = mirror_transform(
			_cam.global_transform, Vector3.ZERO, Vector3.UP)
	else:
		# Mirror the object; the camera is an ordinary copy.
		_mirror.global_transform = mirror_transform(
			Transform3D(Basis.IDENTITY, MARKER_POS), Vector3.ZERO, Vector3.UP)
		_reflect_cam.global_transform = _cam.global_transform
	_reflect_cam.fov = _cam.fov
	_reflect_cam.near = _cam.near
	_reflect_cam.far = _cam.far

	_frame += 1
	if _frame >= TEST_FRAMES:
		_done = true
		_verify()

func _verify() -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("/tmp/s7_%s.png" % _mode)
	var w: int = img.get_width()
	var h: int = img.get_height()

	# `unproject_position` answers in the viewport's *visible* 2D space, which
	# `stretch/mode = canvas_items` pins to the project's 1280x720 base while
	# the 3D buffer is the window's actual size. Probing the image needs the
	# ratio between the two, or every coordinate lands 25 % short.
	var visible: Vector2 = get_viewport().get_visible_rect().size
	var to_image := Vector2(float(w) / visible.x, float(h) / visible.y)

	# Where the reflection should be: straight below the marker on screen, on
	# the ground. Where it must not be: the same height, far off to the side.
	var marker_px: Vector2 = _cam.unproject_position(MARKER_POS) * to_image
	var reflect_px: Vector2 = _cam.unproject_position(
		Vector3(MARKER_POS.x, -MARKER_POS.y, MARKER_POS.z)) * to_image
	var control_px := Vector2(clampf(reflect_px.x + float(w) * 0.30, 0.0, float(w) - 1.0),
		reflect_px.y)

	var refl: Color = _patch_mean(img, reflect_px, 6)
	var ctrl: Color = _patch_mean(img, control_px, 6)
	var mark: Color = _patch_mean(img, marker_px, 6)
	var flip: Color = _patch_mean(img,
		Vector2(reflect_px.x, float(h) - reflect_px.y), 6)

	_log("mode %s, viewport %dx%d (visible %s)" % [_mode, w, h, str(visible)])
	_log("marker at %s, reflection expected at %s"
		% [str(marker_px.round()), str(reflect_px.round())])
	_log("marker patch      r=%.3f g=%.3f b=%.3f" % [mark.r, mark.g, mark.b])
	_log("reflection patch  r=%.3f g=%.3f b=%.3f" % [refl.r, refl.g, refl.b])
	_log("control patch     r=%.3f g=%.3f b=%.3f" % [ctrl.r, ctrl.g, ctrl.b])

	# Against the control patch, not against an absolute: the reflection is an
	# *additive* red over a plane that is already bright and blue, so "is this
	# pixel red" is the wrong question. "Is this pixel redder than the same
	# plane a third of a screen away" is the right one.
	var lift: float = refl.r - ctrl.r
	_check("marker renders red", mark.r - maxf(mark.g, mark.b) > 0.2)
	_check("the reflection reaches the plane at all", lift > 0.02)
	_check("it is where the mirror predicts, and not everywhere",
		lift > 0.02 and absf(refl.b - ctrl.b) < 0.02)
	_check("SCREEN_UV lands right way up (no Y flip needed)",
		lift > flip.r - ctrl.r)

	for line: String in _results:
		print(line)
	print("S7 wrote /tmp/s7_%s.png" % _mode)
	get_tree().quit()

func _patch_mean(img: Image, centre: Vector2, radius: int) -> Color:
	var acc := Color(0, 0, 0)
	var n: int = 0
	for y: int in range(int(centre.y) - radius, int(centre.y) + radius + 1):
		for x: int in range(int(centre.x) - radius, int(centre.x) + radius + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			acc += img.get_pixel(x, y)
			n += 1
	return acc if n == 0 else acc / float(n)

func _log(msg: String) -> void:
	_results.push_back("     " + msg)

func _check(name: String, ok: bool) -> void:
	_results.push_back(("PASS " if ok else "FAIL ") + name)
