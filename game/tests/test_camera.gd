## [ChaseCamera] tests. What the camera does is presentation and normally shows
## up in a capture rather than in an assertion, but two of its properties are
## cheap to state: the lean must not move the camera sideways, which was
## silently wrong for a phase, and no window shape may show less of the hill
## than another, which is what `window/stretch/aspect="expand"` made the
## camera's business rather than the letterbox's.
class_name TestCamera
extends RefCounted

const DT := 1.0 / 60.0

static func run(t: TestCase) -> void:
	_lean_has_no_sideways_half(t)
	_lean_still_leans_with_the_pitch(t)
	_a_jump_does_not_swing_the_camera(t)
	_the_lens_follows_the_window_shape(t)

## The invariant the fix is: whatever the terrain under the racer is doing, the
## height offset stays in the vertical plane the racer is travelling in.
static func _lean_has_no_sideways_half(t: TestCase) -> void:
	t.begin("the camera's terrain lean has no sideways half")
	for heading_deg: float in [0.0, 37.0, 90.0, 154.0, -121.0]:
		var heading: float = deg_to_rad(heading_deg)
		var direction := Vector3(sin(heading), -0.4, cos(heading)).normalized()
		var side: Vector3 = Vector3(direction.x, 0.0, direction.z).normalized().cross(Vector3.UP)
		for tilt: Vector3 in [Vector3(0.6, 0.7, -0.2), Vector3(-0.5, 0.8, 0.3),
				Vector3(0.0, 1.0, 0.0), Vector3(0.9, 0.4, 0.15)]:
			var up: Vector3 = ChaseCamera._lean_up(tilt.normalized(), direction)
			t.eq_f(up.dot(side), 0.0, 1e-5,
				"lean is square to the direction of travel (heading %.0f°, normal %v)" % [
					heading_deg, tilt])
			t.ok(up.y > 0.0, "lean still points upward (heading %.0f°, normal %v)" % [
				heading_deg, tilt])

## And the half it keeps is the one the lean is for: on a slope the offset tips
## back up the hill, which is what stops the camera burying itself in a steep
## pitch. Deleting the lean outright would pass the test above.
static func _lean_still_leans_with_the_pitch(t: TestCase) -> void:
	t.begin("the camera's terrain lean still leans with the pitch")
	# Travelling down a 30° slope that falls toward −Z: the normal tips toward
	# −Z with it, and the lean has to come back the other way, up the hill.
	var pitch: float = deg_to_rad(30.0)
	var normal := Vector3(0.0, cos(pitch), -sin(pitch))
	var direction := Vector3(0.0, -sin(pitch), -cos(pitch))
	var up: Vector3 = ChaseCamera._lean_up(normal, direction)
	t.ok(up.z < -0.05, "the offset tips down-slope with the terrain, not straight up")
	t.eq_f(up.angle_to(Vector3.UP), pitch * 0.5, deg_to_rad(1.0),
		"and by half the slope angle, as the half-way blend to world up says")
	t.eq_f(ChaseCamera._lean_up(Vector3.UP, direction).angle_to(Vector3.UP), 0.0, 1e-5,
		"flat ground leans not at all")

## End to end, on a real course: through a jump the horizontal velocity is
## exactly constant — airborne there is no steering, and neither gravity nor
## drag turns it — so the drawn yaw must be constant too. It was not. The
## terrain normal under the flight path was leaning the camera sideways, and a
## jump is taken off the ridge where that normal sweeps hardest: 11–17° of yaw
## with two to five reversals in it, on a racer flying dead straight.
static func _a_jump_does_not_swing_the_camera(t: TestCase) -> void:
	t.begin("a jump does not swing the camera left and right")
	for course_dir: String in ["bumpy_ride", "downhill_fear"]:
		var flight: Dictionary = _fly(course_dir, 9.0)
		if flight.is_empty():
			t.ok(false, "%s: the probe found no airtime to measure" % course_dir)
			continue
		# The case is only being exercised if the ground under the flight is
		# doing something. Assert that first, or the test passes on a course
		# that got flattened.
		t.ok(flight["normal_swing"] > 0.2,
			"%s: the terrain normal under the jump really does sweep (%.2f)" % [
				course_dir, flight["normal_swing"]])
		t.eq_f(flight["heading_swing"], 0.0, 0.1,
			"%s: the racer flies straight (%.3f° of heading)" % [
				course_dir, flight["heading_swing"]])
		t.ok(flight["yaw_swing"] < 1.0,
			"%s: and the camera holds still with it (%.3f° of yaw over %.2f s)" % [
				course_dir, flight["yaw_swing"], flight["seconds"]])

## Drive the real physics down a real course, jump at [param release_at], and
## report what the camera did over the first airborne stretch after it. Empty
## when the run never left the ground.
## The invariant `expand` needs from the lens: the 16:9 design frustum is a
## subset of what any window shape draws. Wider windows get it by opening the
## horizontal angle at a fixed vertical one, which is [constant
## Camera3D.KEEP_HEIGHT] doing nothing; narrower ones get it by opening the
## vertical angle, which is [method ChaseCamera.fov_for_aspect] doing something.
static func _the_lens_follows_the_window_shape(t: TestCase) -> void:
	t.begin("the lens follows the window's shape")
	var design: float = 70.0
	var base: float = ChaseCamera.DESIGN_ASPECT
	t.eq_f(ChaseCamera.fov_for_aspect(design, base), design, 1e-5,
		"a 16:9 window is the design lens unchanged — captures stay comparable")
	t.eq_f(ChaseCamera.fov_for_aspect(design, 3440.0 / 1440.0), design, 1e-5,
		"and so is a 21:9 one: the extra width is the aspect's, not the lens's")

	# 4:3 and portrait. The vertical angle grows; what it grows to is whatever
	# keeps the horizontal angle at the design value.
	var design_half_width: float = tan(deg_to_rad(design) * 0.5) * base
	for aspect: float in [4.0 / 3.0, 5.0 / 4.0, 1.0, 1080.0 / 1920.0]:
		var widened: float = ChaseCamera.fov_for_aspect(design, aspect)
		t.ok(widened > design, "a %.2f window opens the lens past %.0f°" % [aspect, design])
		t.eq_f(tan(deg_to_rad(widened) * 0.5) * aspect, design_half_width, 1e-5,
			"and opens it exactly far enough to keep the 16:9 width")

	# Monotone, because the resolution drop-down offers a run of shapes and a
	# dip anywhere in it is a window size that sees less than its neighbours.
	var previous: float = 1e9
	var monotone: bool = true
	for step: int in 40:
		var aspect: float = lerpf(0.5, base, float(step) / 39.0)
		var widened: float = ChaseCamera.fov_for_aspect(design, aspect)
		if widened > previous + 1e-5:
			monotone = false
			break
		previous = widened
	t.ok(monotone, "and never narrows anywhere between 1:2 and 16:9")

	# Degenerate viewports: a window with no area reports one for a frame or
	# two on some platforms, and a division by it would put NaN on the lens.
	t.eq_f(ChaseCamera.fov_for_aspect(design, 0.0), design, 1e-5,
		"a zero-area window leaves the lens alone rather than making it NaN")

static func _fly(course_dir: String, release_at: float) -> Dictionary:
	var course: CourseData = load("res://courses/%s/course.tres" % course_dir)
	if course == null:
		return {}
	var p := RacePhysics.new()
	p.surface = HeightmapSurface.from_course(course)
	p.play_min_x = 2.5
	p.play_max_x = course.world_size.x - 2.5
	p.play_length = course.play_size.y
	p.init_at(course.start_position.x, -course.start_position.y)

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var cam := ChaseCamera.new()
	cam.surface = p.surface
	tree.root.add_child(cam)

	var input := RaceInput.new()
	var yaw := PackedFloat32Array()
	var heading := PackedFloat32Array()
	var normal_x := PackedFloat32Array()
	var previous: float = 1e9
	for i: int in 1800:
		input.clear()
		input.paddling = true
		input.charging = p.time >= release_at - 1.0 and p.time < release_at
		p.step(input, DT)
		cam.track(p.pos, p.vel, p.plane_nml, DT)
		var forward: Vector3 = -cam.global_transform.basis.z
		var y: float = rad_to_deg(atan2(forward.x, forward.z))
		if previous < 1e8:
			# Unwrap: the camera crosses ±180° on an ordinary run down the hill.
			y = previous + wrapf(y - previous, -180.0, 180.0)
		previous = y
		if p.airborne and p.time >= release_at:
			yaw.append(y)
			heading.append(rad_to_deg(atan2(p.vel.x, p.vel.z)))
			normal_x.append(p.plane_nml.x)
		elif not yaw.is_empty():
			break
	# Freed rather than queued: the suite quits on its first `_process`, so the
	# deletion queue is never drained and the node is reported as a leak.
	tree.root.remove_child(cam)
	cam.free()
	if yaw.size() < 8:
		return {}
	return {
		"seconds": yaw.size() * DT,
		"yaw_swing": _swing(yaw),
		"heading_swing": _swing(heading),
		"normal_swing": _swing(normal_x),
	}

static func _swing(a: PackedFloat32Array) -> float:
	var lo: float = a[0]
	var hi: float = a[0]
	for v: float in a:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo
