## Tests for the trees' baked shadows ([TreeShadowBake]).
##
## What the terrain shader makes of the bytes cannot be seen headless, so this
## holds the bake to the geometry it claims: a shadow falls away from the sun
## and nowhere else, reaches as far as the tree is tall at a 45° sun, compounds
## where two crowns are in line, and is fainter under a bare crown than under a
## conifer. And on the biggest courses it is quick, which is the whole reason it
## is a stamp per size and not a ray per vertex.
class_name TestTreeShadows
extends RefCounted

## ETR's sunny sun, and every sunny preset's: from +X, 45° up.
const SUN := Vector3(0.70710677, 0.70710677, 0.0)
## The worst cases for the bake, and not the whole catalogue, which would
## triple the suite's time building every course: the most trees
## (`bronze_set`), and the most tree sizes, so the most stamps (`bunny_hill`).
const COURSES: PackedStringArray = ["bronze_set", "bunny_hill"]

static func run(t: TestCase) -> void:
	_the_profiles(t)
	_one_tree(t)
	_crowns_compound(t)
	_down_a_bank(t)
	_nothing_to_bake(t)
	_the_biggest_courses_bake_quickly(t)

## Flat ground, 40 × 40 m at 0.5 m.
static func _flat() -> HeightmapSurface:
	var s := HeightmapSurface.new()
	var heights := PackedFloat32Array()
	heights.resize(81 * 81)
	s.build(heights, Vector2i(81, 81), Vector2(40.0, 40.0), 0.0)
	return s

## A tree of [param diameter] × [param height] standing at world ([param x], [param z]).
static func _tree(x: float, z: float, diameter: float, height: float) -> Transform3D:
	return Transform3D(Basis().scaled(Vector3(diameter, height, diameter)), Vector3(x, 0.0, z))

## The bake's value at world ([param x], [param z]) on [method _flat]'s grid, 0..1.
static func _at(bytes: PackedByteArray, x: float, z: float) -> float:
	return float(bytes[roundi(-z / 0.5) * 81 + roundi(x / 0.5)]) / 255.0

static func _the_profiles(t: TestCase) -> void:
	t.begin("tree shadows/crown profiles")
	for kind: int in 3:
		t.ok(TreeShadowBake.crown_radius(kind, 1.01) == 0.0
			and TreeShadowBake.crown_radius(kind, -0.01) == 0.0,
			"species %d has no crown outside its height" % kind)
		var widest: float = 0.0
		for s: int in 21:
			widest = maxf(widest, TreeShadowBake.crown_radius(kind, float(s) / 20.0))
		t.between(widest, 0.4, 0.5, "species %d's crown is about its diameter across" % kind)
	# `ConiferMesh.crown_radius` clamps below the crown to its widest; a
	# shadow from there would be a solid cylinder down to the snow.
	t.ok(TreeShadowBake.crown_radius(Forest.Species.CONIFER, 0.05) == 0.0,
		"a conifer's crown stops at its lowest branches")

static func _one_tree(t: TestCase) -> void:
	t.begin("tree shadows/one conifer")
	var ground: HeightmapSurface = _flat()
	var trees: Array[Transform3D] = [_tree(20.0, -20.0, 4.0, 6.0)]
	var bytes: PackedByteArray = TreeShadowBake.bake(trees,
		PackedInt32Array([Forest.Species.CONIFER]), ground, SUN)
	t.ok(bytes.size() == 81 * 81, "one byte per heightmap vertex")
	var behind: float = _at(bytes, 17.0, -20.0)
	t.ok(behind < 0.4, "3 m down-sun of the trunk is in shadow (%.2f)" % behind)
	t.ok(_at(bytes, 23.0, -20.0) == 1.0, "3 m toward the sun is sunlit")
	t.ok(_at(bytes, 17.0, -24.0) == 1.0 and _at(bytes, 17.0, -16.0) == 1.0,
		"and so is either side of the shadow")
	# At 45° the top of the crown, 0.96 of 6 m up, lands 5.8 m out; its tip
	# is a point, so the shadow narrows and pales toward it.
	t.ok(_at(bytes, 14.0, -20.0) < 1.0, "the shadow reaches as far as the tree is tall")
	t.ok(_at(bytes, 14.0, -20.0) > _at(bytes, 17.0, -20.0),
		"and pales toward the tip of the crown")
	t.ok(_at(bytes, 13.5, -20.0) == 1.0, "and past the tip the snow is sunlit")
	var bare: PackedByteArray = TreeShadowBake.bake(trees,
		PackedInt32Array([Forest.Species.BARE]), ground, SUN)
	t.ok(_at(bare, 17.0, -20.0) > behind + 0.2,
		"a bare crown of the same size casts a fainter shadow (%.2f)" % _at(bare, 17.0, -20.0))

static func _crowns_compound(t: TestCase) -> void:
	t.begin("tree shadows/two crowns in line")
	var ground: HeightmapSurface = _flat()
	var kinds := PackedInt32Array([Forest.Species.BARE, Forest.Species.BARE])
	var one: PackedByteArray = TreeShadowBake.bake(
		[_tree(20.0, -20.0, 4.0, 6.0)] as Array[Transform3D], kinds, ground, SUN)
	# The second tree stands up-sun, close enough that the ray from a vertex
	# under the first one's shadow crosses both crowns.
	var two: PackedByteArray = TreeShadowBake.bake(
		[_tree(20.0, -20.0, 4.0, 6.0), _tree(23.0, -20.0, 4.0, 6.0)] as Array[Transform3D],
		kinds, ground, SUN)
	t.ok(_at(two, 17.0, -20.0) < _at(one, 17.0, -20.0) - 0.05,
		"two crowns take more sun than one (%.2f < %.2f)"
		% [_at(two, 17.0, -20.0), _at(one, 17.0, -20.0)])

static func _down_a_bank(t: TestCase) -> void:
	t.begin("tree shadows/down a bank")
	# Ground falling 0.3 m per metre away from the sun, toward -X, as a bank
	# does down to the piste: the shadow of the same tree lands further out.
	var bank := HeightmapSurface.new()
	var heights := PackedFloat32Array()
	heights.resize(81 * 81)
	for j: int in 81:
		for i: int in 81:
			heights[j * 81 + i] = 0.3 * (float(i) * 0.5 - 20.0)
	bank.build(heights, Vector2i(81, 81), Vector2(40.0, 40.0), 0.0)
	var trees: Array[Transform3D] = [_tree(20.0, -20.0, 4.0, 6.0)]
	var kinds := PackedInt32Array([Forest.Species.CONIFER])
	var flat: PackedByteArray = TreeShadowBake.bake(trees, kinds, _flat(), SUN)
	var down: PackedByteArray = TreeShadowBake.bake(trees, kinds, bank, SUN)
	# 0.96 · 6 m / (1 - 0.3) = 8.2 m out, where flat ground stops at 5.8 m.
	t.ok(_at(flat, 12.5, -20.0) == 1.0 and _at(down, 12.5, -20.0) < 0.5,
		"7.5 m out is sunlit on the flat and shaded down the bank (%.2f)" % _at(down, 12.5, -20.0))
	t.ok(_at(down, 10.5, -20.0) == 1.0, "and the bank's shadow still ends")

static func _nothing_to_bake(t: TestCase) -> void:
	t.begin("tree shadows/nothing to bake")
	var ground: HeightmapSurface = _flat()
	var trees: Array[Transform3D] = [_tree(20.0, -20.0, 4.0, 6.0)]
	var kinds := PackedInt32Array([Forest.Species.CONIFER])
	t.ok(TreeShadowBake.bake([] as Array[Transform3D], PackedInt32Array(), ground, SUN).is_empty(),
		"no trees, no bytes — the terrain reads that as sunlit")
	t.ok(TreeShadowBake.bake(trees, kinds, ground, Vector3(1.0, 0.05, 0.0)).is_empty(),
		"a sun on the horizon bakes nothing")
	var overhead: PackedByteArray = TreeShadowBake.bake(trees, kinds, ground, Vector3.UP)
	t.ok(_at(overhead, 20.5, -20.0) < 0.5 and _at(overhead, 24.0, -20.0) == 1.0,
		"a sun straight overhead shades the ground under the crown and nothing else")

static func _the_biggest_courses_bake_quickly(t: TestCase) -> void:
	t.begin("tree shadows/the biggest courses")
	var slowest: float = 0.0
	var slowest_dir: String = ""
	for dir: String in COURSES:
		var scene_path: String = "res://courses/%s/course.tscn" % dir
		if not ResourceLoader.exists(scene_path):
			continue  # a streamed web build; `TestPackStream` owns that case
		var packed: PackedScene = load(scene_path)
		var root: CourseRoot = packed.instantiate()
		root.build_runtime()
		var casters: Array = TreeShadowBake.casters_of(root)
		var start: int = Time.get_ticks_usec()
		var bytes: PackedByteArray = TreeShadowBake.bake(casters[0], casters[1], root.surface, SUN)
		var ms: float = float(Time.get_ticks_usec() - start) / 1000.0
		if ms > slowest:
			slowest = ms
			slowest_dir = dir
		t.ok(bytes.size() == root.surface.size.x * root.surface.size.y,
			"%s (%d trees) bakes one byte per vertex" % [dir, (casters[0] as Array).size()])
		root.free()
	# ~30 ms on the desktop; the bound is loose for a loaded machine and still
	# far under what a ray per vertex took.
	t.ok(slowest < 400.0, "the slowest bake is %s's, %.0f ms" % [slowest_dir, slowest])
