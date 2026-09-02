## Spike S1 — ping-pong [SubViewport] render targets in a Godot web export.
##
## The entire snow design in godot-port-plan.md §4.3 rests on this working under
## the Compatibility renderer: no compute shaders means the deformation field has
## to be advanced by a fragment pass between two render targets, and the terrain
## has to displace from the result via vertex texture fetch. The plan flagged it
## Critical and noted it had been inferred from the feature matrix, not observed.
##
## This scene stamps a moving footprint into a real [SnowFieldGPU], displaces a
## plane from it, and then [b]verifies the result numerically[/b] rather than
## leaving it to be eyeballed: it reads the render target back once, at the end,
## and checks that the stamped texels are non-zero, that untouched texels are
## still zero, and that the trail persists across frames (which is what proves
## the ping-pong is actually feeding back rather than clearing).
##
## The readback is a one-off diagnostic. Nothing in the game ever does it — a
## GPU→CPU readback per frame would stall the browser, which is exactly why the
## gameplay side keeps its own CPU mirror.
extends Node3D

const TEST_FRAMES := 120

var _snow: SnowFieldGPU
var _plane: MeshInstance3D
var _material: ShaderMaterial
var _label: Label
var _frame: int = 0
var _t: float = 0.0
var _results: PackedStringArray = PackedStringArray()
var _done: bool = false
var _bench: Dictionary = {}

func _ready() -> void:
	_snow = SnowFieldGPU.new()
	_snow.name = "SnowFieldGPU"
	add_child(_snow)

	var plane := PlaneMesh.new()
	plane.size = Vector2(SnowFieldGPU.WINDOW_SIZE, SnowFieldGPU.WINDOW_SIZE)
	# Dense enough that displacement reads as geometry, not as a wobble.
	plane.subdivide_width = 160
	plane.subdivide_depth = 160

	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/s1_displace.gdshader")
	_material.set_shader_parameter("plane_size",
		Vector2(SnowFieldGPU.WINDOW_SIZE, SnowFieldGPU.WINDOW_SIZE))

	_plane = MeshInstance3D.new()
	_plane.mesh = plane
	_plane.material_override = _material
	add_child(_plane)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 22.0, 26.0)
	cam.look_at_from_position(Vector3(0.0, 22.0, 26.0), Vector3.ZERO, Vector3.UP)
	add_child(cam)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	add_child(sun)

	var layer := CanvasLayer.new()
	_label = Label.new()
	_label.position = Vector2(14, 10)
	_label.add_theme_font_size_override("font_size", 18)
	layer.add_child(_label)
	add_child(layer)

	print("S1 spike: renderer=", RenderingServer.get_video_adapter_name(),
		" driver=", ProjectSettings.get_setting("rendering/renderer/rendering_method"))

func _process(delta: float) -> void:
	if _done:
		return
	_frame += 1
	_t += delta

	# A circle traced through the field, so successive frames must accumulate
	# into a continuous ring rather than a single dot.
	var r: float = 12.0
	var x: float = cos(_t * 1.6) * r
	var z: float = sin(_t * 1.6) * r
	_snow.stamp(x, z, 1.2, 0.10)
	_snow.update(0.0, 0.0, delta)
	_material.set_shader_parameter("trail_map", _snow.trail_texture())

	_label.text = "S1 ping-pong spike — frame %d/%d" % [_frame, TEST_FRAMES]
	if _frame >= TEST_FRAMES:
		_done = true
		_verify()

func _verify() -> void:
	await RenderingServer.frame_post_draw
	var img: Image = _snow.trail_texture().get_image()
	if img == null:
		_report(false, "render target produced no image")
		return

	var w: int = img.get_width()
	var h: int = img.get_height()
	var stamped: int = 0
	var max_depth: float = 0.0
	# The stamped ring sits at radius 12 m in a 64 m window: 0.1875 of the
	# window from the centre.
	var ring_px: float = 12.0 / SnowFieldGPU.WINDOW_SIZE * float(w)
	var centre := Vector2(float(w) * 0.5, float(h) * 0.5)
	var centre_untouched: bool = true

	for y: int in range(0, h, 2):
		for x: int in range(0, w, 2):
			var v: float = img.get_pixel(x, y).r
			var d: float = Vector2(float(x), float(y)).distance_to(centre)
			if absf(d - ring_px) < 6.0 and v > 0.02:
				stamped += 1
				max_depth = maxf(max_depth, v)
			elif d < ring_px * 0.4 and v > 0.02:
				centre_untouched = false

	var checks: Array[Array] = [
		["render target readable", img.get_width() == SnowFieldGPU.RESOLUTION],
		["stamps written to the field", stamped > 50],
		["trail accumulated over frames (ping-pong feedback)", stamped > 400],
		["untouched snow left alone", centre_untouched],
		["depth in range", max_depth > 0.05 and max_depth <= 1.0],
	]
	var all_ok: bool = true
	for c: Array in checks:
		var ok: bool = c[1]
		all_ok = all_ok and ok
		_results.push_back("  %s %s" % ["PASS" if ok else "FAIL", c[0]])
	_results.push_back("  ring texels stamped: %d, peak depth: %.3f" % [stamped, max_depth])

	# While we are here, answer risk S2 in the same environment: the ODE substep
	# loop measured on an actual web-export budget rather than on a workstation.
	_bench = BenchPhysics.run()
	_results.push_back("  physics: %.4f ms/frame (%.1f%% of 16.7 ms), %.2f substeps/frame"
		% [_bench["per_frame_ms"], _bench["budget_fraction"] * 100.0,
			_bench["substeps_per_frame"]])
	_report(all_ok, "")

func _report(ok: bool, extra: String) -> void:
	var header: String = "S1 RESULT: %s" % ("PASS" if ok else "FAIL")
	print(header)
	for line: String in _results:
		print(line)
	if not extra.is_empty():
		print("  ", extra)
	# The browser harness scrapes this marker out of the console.
	print("S1_DONE %s" % ("PASS" if ok else "FAIL"))
	# Leave the result on screen briefly for a screenshot, then exit so the
	# harness gets a clean exit code.
	await get_tree().create_timer(2.0).timeout
	if not OS.has_feature("web"):
		Audio.quit_game(0 if ok else 1)
	_label.text = "%s\n%s" % [header, "\n".join(_results)]
	_label.add_theme_color_override("font_color", Color.GREEN if ok else Color.RED)
