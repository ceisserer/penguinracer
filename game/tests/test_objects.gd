## The generated [ObjectPrefab]s — what a tree, a shrub, a herring and a banner
## are made of.
##
## `course_render.cpp` draws two different things and the difference is not a
## detail. `DrawTrees` walks `CollArr` and emits eight fixed vertices per
## object — a quad across X and a quad across Z, both from the ground to
## `[height]`, never turned toward anything. It then walks `NocollArr` and emits
## four vertices per object, turned to face `ctrl->viewpos`. So every collidable
## object is a static cross of two planes at 90 degrees, and every collectable
## one is a camera-facing billboard.
##
## Getting that backwards is silent. A billboarded tree renders perfectly: it is
## the right texture at the right size in the right place, and it is only wrong
## while the camera is moving, when the whole forest swivels to keep facing the
## player and no tree ever shows a different profile. Nothing about a still
## frame says so, which is why this is asserted against the vertex data rather
## than looked at.
##
## The prefabs are written twice — once to `res://resources/objects/` and once,
## embedded, into each `course.tscn` — so both copies are checked. The embedded
## one is what actually renders.
class_name TestObjects
extends RefCounted

const OBJECT_DIR := "res://resources/objects"
const CROSS_SHADER := "res://shaders/object_cross.gdshader"
const BILLBOARD_SHADER := "res://shaders/object_billboard.gdshader"
## One course, for the second copy. Bunny Hill carries all fourteen object
## types, which is what makes it the useful one to open.
const COURSE_SCENE := "res://courses/bunny_hill/course.tscn"
## And one for the planes those quads land in. Challenge One is the course the
## flicker was reported on: 1480 collidable objects, 1255 pairs of them
## coplanar-and-overlapping before [constant CourseRoot.YAW_JITTER] existed.
const FOREST_SCENE := "res://courses/challenge_one/course.tscn"
## Two overlapping quads this close to parallel are still fighting for every
## practical purpose: a tenth of a degree is 1.7 mm of separation a metre out
## from where the planes cross, and the depth buffer resolves about a
## centimetre at the far end of the fog.
const FIGHTING_ANGLE := deg_to_rad(0.1)

static func run(t: TestCase) -> void:
	var prefabs: Dictionary[String, ObjectPrefab] = _load_all(t)
	_trees_are_crossed_quads(t, prefabs)
	_items_are_billboards(t, prefabs)
	_the_course_carries_the_same(t)
	_no_two_trees_share_a_plane(t)

static func _load_all(t: TestCase) -> Dictionary[String, ObjectPrefab]:
	t.begin("course objects/on disk")
	var out: Dictionary[String, ObjectPrefab] = {}
	var dir := DirAccess.open(OBJECT_DIR)
	t.ok(dir != null, "the object prefabs are on disk")
	if dir == null:
		return out
	for file: String in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var prefab: ObjectPrefab = load(OBJECT_DIR.path_join(file))
		t.ok(prefab != null, "%s loads as an ObjectPrefab" % file)
		if prefab != null:
			out[String(prefab.id)] = prefab
	t.ok(out.size() == 14, "fourteen object types (%d)" % out.size())
	return out

static func _trees_are_crossed_quads(t: TestCase,
		prefabs: Dictionary[String, ObjectPrefab]) -> void:
	t.begin("course objects/trees")
	var checked: int = 0
	for id: String in prefabs:
		var prefab: ObjectPrefab = prefabs[id]
		if not prefab.collidable or prefab.mesh == null:
			continue
		checked += 1
		_assert_cross(t, prefab.mesh, id)
		var shader: Shader = (prefab.material as ShaderMaterial).shader
		t.ok(shader != null and shader.resource_path == CROSS_SHADER,
			"%s does not billboard" % id)
	# `tree`, `tree_barren`, `tree_barren2`, `tree1` and `shrub`. The other four
	# tree types name a texture ETR never shipped and are undrawn there too.
	t.ok(checked == 5, "five collidable types are drawn (%d)" % checked)

## The eight vertices of `DrawTrees`, as a unit mesh.
static func _assert_cross(t: TestCase, mesh: Mesh, id: String) -> void:
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	t.ok(verts.size() == 8, "%s: eight vertices (%d)" % [id, verts.size()])
	if verts.size() != 8:
		return
	t.ok(arrays[Mesh.ARRAY_INDEX].size() == 12, "%s: two quads" % id)

	# Unit-sized, because the per-instance transform carries
	# `(diameter, height, diameter)` — so ±0.5 across is the original's
	# `treeRadius = diam / 2` once scaled, and 0..1 up is `treeHeight`.
	var aabb: AABB = mesh.get_aabb()
	t.eq_v(aabb.position, Vector3(-0.5, 0.0, -0.5), 1e-5,
		"%s: the cross starts at the ground and spans ±radius" % id)
	t.eq_v(aabb.size, Vector3(1.0, 1.0, 1.0), 1e-5, "%s: and is one unit across" % id)

	# The two planes are at 90 degrees to each other, which is the whole shape.
	# Four vertices lie in each; a mesh where they did not would still have the
	# right bounding box.
	var in_xy: int = 0
	var in_zy: int = 0
	for v: Vector3 in verts:
		if absf(v.z) < 1e-5:
			in_xy += 1
		if absf(v.x) < 1e-5:
			in_zy += 1
	t.ok(in_xy == 4 and in_zy == 4,
		"%s: four vertices in each plane (%d, %d)" % [id, in_xy, in_zy])
	t.eq_f(absf(normals[0].dot(normals[4])), 0.0, 1e-3,
		"%s: the two planes are perpendicular" % id)

	# The shader builds its cylinder impostor out of NORMAL and TANGENT. A mesh
	# with no tangents hands it a zero vector and says nothing about it.
	#
	# The tolerance is 1e-3 because a saved mesh stores both octahedrally
	# compressed: what goes in as an exact axis comes back about 3e-5 off it,
	# on every mesh Godot has ever written.
	t.ok(tangents.size() == verts.size() * 4, "%s: a tangent per vertex" % id)
	if tangents.size() == verts.size() * 4:
		var tangent := Vector3(tangents[0], tangents[1], tangents[2])
		t.eq_f(tangent.dot(normals[0]), 0.0, 1e-3,
			"%s: the tangent lies in its own plane" % id)
		t.eq_f(absf(tangent.dot(Vector3.UP)), 0.0, 1e-3,
			"%s: and runs across it rather than up it" % id)

static func _items_are_billboards(t: TestCase,
		prefabs: Dictionary[String, ObjectPrefab]) -> void:
	t.begin("course objects/items")
	# The other half of `DrawTrees`: a herring, a flag and the two banners are
	# one quad turned toward the viewpoint. Turning these into crossed quads
	# would be the same mistake in the other direction — a herring seen edge-on
	# would disappear.
	for id: String in ["herring", "flag", "start", "finish"]:
		var prefab: ObjectPrefab = prefabs.get(id, null)
		t.ok(prefab != null and prefab.mesh is QuadMesh, "%s is a single quad" % id)
		if prefab == null or prefab.material == null:
			continue
		var shader: Shader = (prefab.material as ShaderMaterial).shader
		t.ok(shader != null and shader.resource_path == BILLBOARD_SHADER,
			"%s billboards" % id)
		t.ok(not prefab.collidable, "%s is not collidable, which is what decides it" % id)

## The copy that actually renders. [CourseRoot] reads its own
## [member CourseRoot.object_prefabs], not the files above, so a course scene
## imported before the mesh changed would still draw the old shape with every
## test on the files passing.
static func _the_course_carries_the_same(t: TestCase) -> void:
	t.begin("course objects/in the course scene")
	var scene: PackedScene = load(COURSE_SCENE)
	t.ok(scene != null, "the course scene loads")
	if scene == null:
		return
	var root: CourseRoot = scene.instantiate() as CourseRoot
	t.ok(root != null, "and its root is a CourseRoot")
	if root == null:
		return
	var tree: ObjectPrefab = root.object_prefabs.get("tree", null)
	t.ok(tree != null and tree.mesh != null, "the embedded tree prefab has a mesh")
	if tree != null and tree.mesh != null:
		_assert_cross(t, tree.mesh, "the embedded tree")
	var herring: ObjectPrefab = root.object_prefabs.get("herring", null)
	t.ok(herring != null and herring.mesh is QuadMesh, "and the embedded herring is a quad")
	root.free()

## The planes the crossed quads land in, over a whole forest.
##
## A cross of two world-axis-aligned quads is the original's geometry and it is
## kept; what cannot be kept is every object on the course using the *same* two
## planes. Objects come off an object-map cell, so a row of trees shares its z
## to the last bit — and two of them standing closer together than the sum of
## their radii then have quads that are exactly coplanar over the overlap.
## Nothing resolves that: the depth test is a comparison and neither surface is
## in front, so the pair swaps frame by frame over a region the size of a tree.
## [method CourseRoot.decorrelating_yaw] is what stops it.
##
## Asserted against [method CourseRoot.decorrelating_yaw] over the real markers
## rather than against the [MultiMesh] the yaw ends up in, because
## **`MultiMesh.get_instance_transform` returns the identity under
## `--headless`** — the transforms live in the [RenderingServer] and the dummy
## renderer keeps none of them. Nothing errors; every instance simply reads back
## as an untransformed one, which for this test would have looked like every
## tree being perfectly coplanar with every other.
static func _no_two_trees_share_a_plane(t: TestCase) -> void:
	t.begin("course objects/no two trees share a plane")
	var root: CourseRoot = (load(FOREST_SCENE) as PackedScene).instantiate() as CourseRoot
	t.ok(root != null, "the forest course loads")
	if root == null:
		return

	# Plan position, radius and the quarter turn the cross is symmetric under —
	# turning a tree by 90 degrees puts each quad in the plane the other one
	# just left, so 89 degrees apart is one degree from coplanar.
	var placed: Array[Vector4] = []
	for group: Node in root.get_node("Objects").get_children():
		var prefab: ObjectPrefab = root.object_prefabs.get(String(group.name), null)
		if prefab == null or not prefab.collidable:
			continue
		for marker: Node in group.get_children():
			var m: Node3D = marker as Node3D
			var yaw: float = fposmod(m.rotation.y + CourseRoot.decorrelating_yaw(m.position),
				PI * 0.5)
			placed.push_back(Vector4(m.position.x, m.position.z, m.scale.x * 0.5, yaw))
	t.ok(placed.size() > 1000, "the forest is a forest (%d objects)" % placed.size())

	# Sweep along x: two objects further apart than the sum of their radii
	# cannot have overlapping quads whatever their angle.
	placed.sort_custom(func(a: Vector4, b: Vector4) -> bool: return a.x < b.x)
	var widest: float = 0.0
	for o: Vector4 in placed:
		widest = maxf(widest, o.z)
	var overlapping: int = 0
	var coplanar: int = 0
	var fighting: int = 0
	for i: int in placed.size():
		var a: Vector4 = placed[i]
		for j: int in range(i + 1, placed.size()):
			var b: Vector4 = placed[j]
			if b.x - a.x > a.z + widest:
				break
			if b.x - a.x > a.z + b.z or absf(b.y - a.y) > a.z + b.z:
				continue
			overlapping += 1
			var delta: float = absf(b.w - a.w)
			delta = minf(delta, PI * 0.5 - delta)
			if delta < 1e-6:
				coplanar += 1
			elif delta < FIGHTING_ANGLE:
				fighting += 1
	t.ok(overlapping > 100, "objects do overlap in plan (%d pairs)" % overlapping)
	t.ok(coplanar == 0, "and none of those pairs is coplanar (%d)" % coplanar)
	# The worst pair is deliberately not what is asserted. A hash decorrelates in
	# the aggregate and cannot promise a floor: with thousands of overlapping
	# pairs some pair lands nearly coincident by chance, and a thin fighting
	# strip is what any two nearly-parallel cards give anyway. What is asserted
	# is that the angles behave like a spread rather than a heap — the yaws are
	# drawn from ±[constant CourseRoot.YAW_JITTER] and their differences are
	# triangular about zero, so the share of pairs inside FIGHTING_ANGLE should
	# be about that ratio. Challenge One: 11 of 3215, against 16 expected and
	# 1255 exactly coplanar before there was a yaw at all.
	var expected: float = float(overlapping) * FIGHTING_ANGLE / CourseRoot.YAW_JITTER
	t.ok(float(fighting) < 3.0 * expected,
		"and %d of %d pairs are within %.1f degrees, against %.0f expected" % [
			fighting, overlapping, rad_to_deg(FIGHTING_ANGLE), expected])

	root.free()
