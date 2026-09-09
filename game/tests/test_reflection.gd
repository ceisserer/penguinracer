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
## [method Racer._join_reflection_layer] is still being called, and still
## reaching the meshes that hang under the rig rather than only the top node.
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
