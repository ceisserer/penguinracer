## [IceReflection] tests.
##
## What the mirror looks like is a capture's business — spike S7 is where that
## was settled, and the shader term it feeds is not assertable headless. What
## [i]is[/i] assertable is the geometry underneath it, and the geometry is the
## part that is easy to get subtly wrong: a reflection that is off by the sign
## of the plane offset still renders a penguin, just not one attached to any
## feet. These are the properties that pin it down.
class_name TestReflection
extends RefCounted

static func run(t: TestCase) -> void:
	_the_plane_is_fixed(t)
	_the_mirror_is_its_own_inverse(t)
	_it_reverses_orientation(t)
	_it_reflects_the_way_a_mirror_does(t)
	_an_off_axis_plane_behaves(t)
	_racers_are_on_the_layer_the_mirror_renders(t)
	_a_racer_can_be_taken_out_of_the_mirror(t)
	_the_plane_admits_its_own_ground(t)
	_the_plane_refuses_ground_it_does_not_speak_for(t)
	_admission_has_hysteresis(t)
	_a_floor_keeps_its_reflection_and_a_wall_loses_it(t)
	_the_setting_survives_the_file(t)

const PLANES: Array[Array] = [
	[Vector3.ZERO, Vector3.UP],
	[Vector3(3.0, 12.0, -40.0), Vector3.UP],
	[Vector3(-2.0, 5.0, 8.0), Vector3(0.3, 0.9, -0.2)],
	[Vector3(0.0, -7.5, 0.0), Vector3(-0.5, 0.8, 0.33)],
]

## Every point of the mirror plane is a fixed point of the reflection. This is
## the property that makes the whole thing hang together visually: the racer's
## feet are on the plane, so whatever else drifts, the reflection is welded to
## the contact point.
static func _the_plane_is_fixed(t: TestCase) -> void:
	t.begin("the mirror plane is fixed under the reflection")
	for plane: Array in PLANES:
		var point: Vector3 = plane[0]
		var n: Vector3 = (plane[1] as Vector3).normalized()
		# Two independent directions that lie in the plane.
		var u: Vector3 = n.cross(Vector3(1.0, 2.0, 3.0)).normalized()
		var v: Vector3 = n.cross(u).normalized()
		for s: float in [0.0, 1.0, -4.5, 17.0]:
			for w: float in [0.0, 2.5, -9.0]:
				var on_plane: Vector3 = point + u * s + v * w
				var t_in := Transform3D(Basis.IDENTITY, on_plane)
				var out: Transform3D = IceReflection.mirror_transform(t_in, point, n)
				t.eq_v(out.origin, on_plane, 1e-4,
					"a point on the plane does not move (normal %v)" % n)

## Reflecting twice is the identity, which is the cheapest statement that the
## offset is applied with the right sign and exactly once.
static func _the_mirror_is_its_own_inverse(t: TestCase) -> void:
	t.begin("reflecting twice is the identity")
	var subject := Transform3D(
		Basis(Quaternion(Vector3(0.3, 0.8, 0.5).normalized(), 1.1)),
		Vector3(4.0, 9.0, -13.0))
	for plane: Array in PLANES:
		var point: Vector3 = plane[0]
		var n: Vector3 = (plane[1] as Vector3).normalized()
		var once: Transform3D = IceReflection.mirror_transform(subject, point, n)
		var twice: Transform3D = IceReflection.mirror_transform(once, point, n)
		t.eq_v(twice.origin, subject.origin, 1e-4,
			"the position comes back (normal %v)" % n)
		for axis: int in 3:
			t.eq_v(twice.basis[axis], subject.basis[axis], 1e-4,
				"basis axis %d comes back (normal %v)" % [axis, n])

## The determinant is −1, and that is not an accident to be tidied away: it is
## what says this is a mirror image and not some rotation that happens to look
## like one. [IceReflection] documents why it is safe to hand a camera; spike
## S7 measured that the renderer flips the winding to match.
static func _it_reverses_orientation(t: TestCase) -> void:
	t.begin("the mirror reverses orientation")
	for plane: Array in PLANES:
		var n: Vector3 = (plane[1] as Vector3).normalized()
		var out: Transform3D = IceReflection.mirror_transform(
			Transform3D(Basis.IDENTITY, Vector3(1.0, 2.0, 3.0)), plane[0], n)
		t.eq_f(out.basis.determinant(), -1.0, 1e-4,
			"determinant is −1 (normal %v)" % n)
		# Orthogonal all the same: a reflection does not stretch anything, so
		# the reflected penguin is the same size as the penguin.
		for axis: int in 3:
			t.eq_f(out.basis[axis].length(), 1.0, 1e-4,
				"axis %d keeps unit length (normal %v)" % [axis, n])

## A camera one metre above the ice comes back one metre below it, looking back
## up — the two statements that make the image land where the eye expects.
static func _it_reflects_the_way_a_mirror_does(t: TestCase) -> void:
	t.begin("the mirror puts the camera through the floor")
	var point := Vector3(0.0, 20.0, 0.0)
	var n := Vector3.UP
	for height: float in [0.5, 1.0, 4.0, 30.0]:
		var eye: Vector3 = point + Vector3(2.0, height, -3.0)
		var out: Transform3D = IceReflection.mirror_transform(
			Transform3D(Basis.IDENTITY, eye), point, n)
		t.eq_f(out.origin.y, point.y - height, 1e-4,
			"the camera lands as far below as it was above (%.1f m)" % height)
		t.eq_f(out.origin.x, eye.x, 1e-4, "it does not move sideways")
		t.eq_f(out.origin.z, eye.z, 1e-4, "it does not move along the slope")
	# A direction along the normal is negated; one lying in the plane is not.
	var basis: Basis = IceReflection.mirror_transform(
		Transform3D(Basis.IDENTITY, Vector3.ZERO), point, n).basis
	t.eq_v(basis * Vector3.UP, Vector3.DOWN, 1e-4, "up becomes down")
	t.eq_v(basis * Vector3.RIGHT, Vector3.RIGHT, 1e-4, "sideways is untouched")

## The same, on a plane that is neither level nor through the origin — which is
## every ice slope in the game.
static func _an_off_axis_plane_behaves(t: TestCase) -> void:
	t.begin("the mirror works on a tilted plane off the origin")
	var point := Vector3(11.0, -4.0, 60.0)
	var n: Vector3 = Vector3(0.25, 0.94, -0.23).normalized()
	# Genuinely in the plane: an arbitrary offset with its normal component
	# taken out, so `distance` really is the distance from the plane.
	var along: Vector3 = Vector3(3.0, 0.0, -1.0)
	along -= n * along.dot(n)
	for distance: float in [0.25, 2.0, 11.0]:
		var above: Vector3 = point + n * distance + along
		var out: Transform3D = IceReflection.mirror_transform(
			Transform3D(Basis.IDENTITY, above), point, n)
		# Signed distance from the plane flips and keeps its magnitude.
		t.eq_f((out.origin - point).dot(n), -distance, 1e-4,
			"signed distance flips (%.2f m off the plane)" % distance)
		# And nothing moves within the plane: the component square to the
		# normal is untouched, which is what keeps the reflection under its
		# subject rather than beside it.
		var slide: Vector3 = (out.origin - above) - n * (out.origin - above).dot(n)
		t.eq_f(slide.length(), 0.0, 1e-4, "no sideways slide along the plane")

## The mirror pass renders one visual layer and one only. A racer that is not on
## it is a racer with no reflection, silently — so this is the assertion that
## [method Racer._apply_reflected] is still being called, and still reaching the
## meshes that hang under the rig rather than only the top node.
static func _racers_are_on_the_layer_the_mirror_renders(t: TestCase) -> void:
	t.begin("racers are drawn on the layer the mirror renders")
	var racer := Racer.new()
	racer.install_fallback_mesh()
	var meshes: Array[Node] = Racer._mesh_instances(racer)
	t.ok(meshes.size() > 0, "the fallback racer has something to draw")
	for node: Node in meshes:
		var mesh: MeshInstance3D = node
		t.ok((mesh.layers & IceReflection.RACER_VISUAL_LAYER) != 0,
			"%s is on the reflection layer" % mesh.name)
		# And still on the ordinary one, or the main camera stops drawing it.
		t.ok((mesh.layers & 1) != 0, "%s is still on layer 1" % mesh.name)
	racer.free()

## And off again. [member Racer.reflected] is how a racer the plane does not
## speak for is kept out of the mirror, and it has to reach every mesh and leave
## layer 1 alone — clearing both would take the penguin out of the frame, which
## is a far worse bug than the one this fixes.
static func _a_racer_can_be_taken_out_of_the_mirror(t: TestCase) -> void:
	t.begin("a racer can be taken out of the mirror and put back")
	var racer := Racer.new()
	racer.install_fallback_mesh()
	var meshes: Array[Node] = Racer._mesh_instances(racer)
	for pass_state: bool in [false, true, false, true]:
		racer.reflected = pass_state
		for node: Node in meshes:
			var mesh: MeshInstance3D = node
			t.ok(((mesh.layers & IceReflection.RACER_VISUAL_LAYER) != 0) == pass_state,
				"%s on the reflection layer = %s" % [mesh.name, pass_state])
			t.ok((mesh.layers & 1) != 0,
				"%s is still on layer 1 either way" % mesh.name)
	racer.free()

## Ground that *is* the plane is admitted, and so is ground anywhere along it —
## a straight slope ahead of you is the same plane, however far ahead. (The
## racer the plane was taken under never reaches this test at all: see
## [method RaceScene._admit_racers_to_reflection] for the 14° of smoothing lag
## that is why.)
static func _the_plane_admits_its_own_ground(t: TestCase) -> void:
	t.begin("the plane admits the ground it was taken from")
	for plane: Array in PLANES:
		var point: Vector3 = plane[0]
		var n: Vector3 = (plane[1] as Vector3).normalized()
		t.ok(IceReflection.plane_admits(point, n, point, n, false),
			"the anchor point itself is admitted (normal %v)" % n)
		# And anywhere along the plane, which is a straight slope ahead of you.
		var along: Vector3 = n.cross(Vector3(1.0, 2.0, 3.0)).normalized()
		for distance: float in [3.0, 20.0, -45.0]:
			t.ok(IceReflection.plane_admits(point, n, point + along * distance, n,
				false), "%.0f m along the same plane is admitted" % distance)

## The bug, as an assertion. A racer whose own ice is metres off the plane, or
## tipped away from it, is mirrored to somewhere that is not under it — so it is
## not mirrored at all.
static func _the_plane_refuses_ground_it_does_not_speak_for(t: TestCase) -> void:
	t.begin("the plane refuses ground it does not speak for")
	var point := Vector3(20.0, -7.0, -17.0)
	var n := Vector3.UP
	# Measured on Who Says Penguins Can't Fly?: 2–4 m off the plane the moment
	# the field spreads across the pipe. That is the case in the bug report.
	for off: float in [2.0, 3.0, 4.0]:
		t.ok(not IceReflection.plane_admits(point, n,
			point + Vector3(6.0, off, 0.0), n, false),
			"%.0f m off the plane is refused" % off)
		t.ok(not IceReflection.plane_admits(point, n,
			point + Vector3(6.0, -off, 0.0), n, false),
			"%.0f m under the plane is refused too" % off)
	# On the plane but on ice facing somewhere else — the trench floor under a
	# mirror plane taken from halfway up the wall. Comes back rotated by 2θ.
	for degrees: float in [25.0, 40.0, 60.0]:
		var tilted: Vector3 = Vector3.UP.rotated(Vector3.FORWARD, deg_to_rad(degrees))
		t.ok(not IceReflection.plane_admits(point, n, point, tilted, false),
			"ice leaning %.0f° away is refused" % degrees)
	# A hand's breadth and a couple of degrees is the same slope, and stays in.
	t.ok(IceReflection.plane_admits(point, n, point + Vector3(4.0, 0.1, 2.0),
		Vector3.UP.rotated(Vector3.FORWARD, deg_to_rad(4.0)), false),
		"the same slope a few metres away is still admitted")

## The tolerances are wider for a racer already in the mirror than for one
## coming into it. Without that, an opponent holding your line one hump behind
## sits on the threshold and its reflection strobes.
static func _admission_has_hysteresis(t: TestCase) -> void:
	t.begin("admission has hysteresis")
	var point := Vector3.ZERO
	var n := Vector3.UP
	# Between the two thresholds: out stays out, in stays in.
	var between: float = IceReflection.PLANE_TOLERANCE \
		* (1.0 + IceReflection.ADMIT_HYSTERESIS) * 0.5
	t.ok(IceReflection.ADMIT_HYSTERESIS > 1.0, "the band is a band")
	t.ok(not IceReflection.plane_admits(point, n, Vector3(0.0, between, 0.0), n,
		false), "%.2f m off does not get in" % between)
	t.ok(IceReflection.plane_admits(point, n, Vector3(0.0, between, 0.0), n,
		true), "%.2f m off does not get thrown out" % between)
	# Far enough out and being in already does not save it.
	var far: float = IceReflection.PLANE_TOLERANCE * IceReflection.ADMIT_HYSTERESIS + 0.5
	t.ok(not IceReflection.plane_admits(point, n, Vector3(0.0, far, 0.0), n, true),
		"%.2f m off is refused even to a racer already in" % far)

## The other axis: not where the ice is, but where the reflection of a penguin
## standing on it lands on screen.
##
## A mirror image sits off its subject along the plane normal. Pointed down the
## screen it hides behind the belly and reads as a reflection; pointed sideways
## it slides out and reads as a second penguin. [method
## IceReflection.attachment_of] is that distinction as a number, and these are
## the two ends of it plus the measurements the band was set from.
static func _a_floor_keeps_its_reflection_and_a_wall_loses_it(t: TestCase) -> void:
	t.begin("the mirror is kept on a floor and dropped on a wall")
	# A chase camera: behind and a little above, looking slightly down. The
	# plane under it is level, so the offset is straight down the screen.
	var level: Basis = Basis(Vector3.RIGHT, deg_to_rad(-15.0))
	t.eq_f(IceReflection.attachment_of(level, Vector3.UP), 1.0, 1e-4,
		"a level plane under a level camera is fully attached")
	for pitch: float in [0.0, -10.0, -25.0, -40.0]:
		t.eq_f(IceReflection.attachment_of(
			Basis(Vector3.RIGHT, deg_to_rad(pitch)), Vector3.UP), 1.0, 1e-4,
			"... and at any pitch (%.0f°), because the offset stays vertical"
				% pitch)
	# Roll the camera — or bank the plane away from it, which is the same
	# relative geometry — and the offset swings into the horizontal.
	for roll: float in [50.0, 70.0, 90.0]:
		t.eq_f(IceReflection.attachment_of(
			Basis(Vector3.BACK, deg_to_rad(roll)), Vector3.UP), 0.0, 1e-4,
			"a plane banked %.0f° across the view is dropped" % roll)
	# Looking straight down the normal there is no screen-space offset at all,
	# so there is nothing to slide out from behind anything.
	t.eq_f(IceReflection.attachment_of(
		Basis(Vector3.RIGHT, deg_to_rad(-90.0)), Vector3.UP), 1.0, 1e-4,
		"straight down the normal is attached by definition")
	# The band itself, against what was measured in a race: `tuxway` never fell
	# below 0.969 over 300 frames and the two reported frames of
	# `penguins_cant_fly` read 0.665 and 0.542.
	t.ok(IceReflection.ATTACHMENT_FADE_HIGH < 0.969,
		"the flat-lake course stays at full strength")
	t.ok(IceReflection.ATTACHMENT_FADE_LOW > 0.665,
		"the reported frames are taken all the way to zero")
	t.ok(IceReflection.ATTACHMENT_FADE_LOW < IceReflection.ATTACHMENT_FADE_HIGH,
		"the band is a band")

## The setting is only useful if it survives the round trip through the file,
## and the file is written by hand — see [method GameConfig.file_text].
static func _the_setting_survives_the_file(t: TestCase) -> void:
	t.begin("ice_reflections survives the settings file")
	for value: bool in [true, false]:
		var written := GameConfig.new()
		written.ice_reflections = value
		var cfg := ConfigFile.new()
		t.ok(cfg.parse(written.file_text()) == OK, "the written file parses")
		var read_back := GameConfig.new()
		read_back.read(cfg)
		t.ok(read_back.ice_reflections == value,
			"ice_reflections = %s round-trips" % value)
		written.free()
		read_back.free()
