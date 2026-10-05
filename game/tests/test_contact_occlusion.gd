## Tests for the sky the course's objects take from the ground round them
## ([ContactOcclusion]).
##
## What the shader makes of it cannot be seen headless, so this holds the bake
## to the geometry it claims: open ground far from anything is left alone, the
## foot of an object is darker than a few metres out, a bare crown takes less
## than a conifer, a vertex under a stone takes no more than its foot (or the
## terrain smears the black of being inside across the triangles round it),
## a log shades along its length, and the relief's occlusion is multiplied, not
## replaced. And on the biggest courses it is quick and finds only what stands
## on the ground.
class_name TestContactOcclusion
extends RefCounted

## The worst cases for the bake: the most trees (`bronze_set`), the most
## props and shapes (`forest_trail`), and the one with things that must be
## left out — an overhead trunk and invisible colliders (`mountain_forest`).
const COURSES: PackedStringArray = ["bronze_set", "forest_trail", "mountain_forest"]

static func run(t: TestCase) -> void:
	_open_ground_is_open(t)
	_one_conifer(t)
	_a_boulder(t)
	_a_log(t)
	_over_the_relief(t)
	_the_biggest_courses(t)

## Flat ground, 40 × 40 m at 0.5 m.
static func _flat() -> HeightmapSurface:
	var s := HeightmapSurface.new()
	var heights := PackedFloat32Array()
	heights.resize(81 * 81)
	s.build(heights, Vector2i(81, 81), Vector2(40.0, 40.0), 0.0)
	return s

## The bake's value at world ([param x], [param z]) on [method _flat]'s grid, 0..1.
static func _at(img: Image, x: float, z: float) -> float:
	return img.get_pixel(roundi(x / 0.5), roundi(-z / 0.5)).r

## One tree of [param kind] as `casters_of` would hand it over.
static func _tree(kind: int, x: float, z: float, diameter: float, height: float) -> Array:
	var shapes: Array[ContactOcclusion.Shape] = [ContactOcclusion.Shape.new(
		TreeShadowBake._profile(kind), 1.0, ContactOcclusion.TREE_OPACITY[kind])]
	return [PackedVector4Array([Vector4(x, z, diameter, height)]), PackedInt32Array([0]), shapes]

## A box [param half] wide each way and [param height] tall, sunk 0.1 below
## the ground, as `Mesh.get_faces` would give it.
static func _box_faces(half: Vector2, height: float) -> PackedVector3Array:
	var m := BoxMesh.new()
	m.size = Vector3(half.x * 2.0, height + 0.1, half.y * 2.0)
	var faces: PackedVector3Array = m.get_faces()
	for k: int in faces.size():
		faces[k].y += (height + 0.1) * 0.5 - 0.1
	return faces

static func _bake(casters: Array, surface: HeightmapSurface, relief: Image = null) -> Image:
	return ContactOcclusion.bake(casters[0], casters[1], casters[2], surface, relief)

static func _open_ground_is_open(t: TestCase) -> void:
	t.begin("contact occlusion/open ground")
	var ground: HeightmapSurface = _flat()
	var none: Array[ContactOcclusion.Shape] = []
	t.ok(ContactOcclusion.bake(PackedVector4Array(), PackedInt32Array(), none, ground,
		null) == null, "nothing on the course and no relief: nothing to draw")
	var img: Image = _bake(_tree(Forest.Species.CONIFER, 20.0, -20.0, 4.0, 8.0), ground)
	t.ok(img.get_format() == Image.FORMAT_L8 and img.get_size() == Vector2i(81, 81),
		"one byte per heightmap vertex")
	t.ok(_at(img, 20.0 + 2.0 + ContactOcclusion.REACH_M + 0.5, -20.0) == 1.0
		and _at(img, 2.0, -2.0) == 1.0, "past the reach the ground sees the whole sky")

static func _one_conifer(t: TestCase) -> void:
	t.begin("contact occlusion/one conifer")
	var ground: HeightmapSurface = _flat()
	var img: Image = _bake(_tree(Forest.Species.CONIFER, 20.0, -20.0, 4.0, 8.0), ground)
	var under: float = _at(img, 20.5, -20.0)
	var edge: float = _at(img, 22.0, -20.0)
	var out: float = _at(img, 25.0, -20.0)
	t.ok(under < edge and edge < out and out < 1.0,
		"darkest under the crown, lighter at its edge and 3 m out (%.2f, %.2f, %.2f)"
		% [under, edge, out])
	# The crown starts above the ground, so the snow under it still sees the
	# band of sky under the lowest branches.
	t.between(under, 0.2, 0.8, "the snow under a spruce is shaded, not black")
	t.eq_f(_at(img, 20.0, -23.0), _at(img, 23.0, -20.0), 2.0 / 255.0,
		"the same all round the trunk")
	var bare: Image = _bake(_tree(Forest.Species.BARE, 20.0, -20.0, 4.0, 8.0), ground)
	t.ok(_at(bare, 20.5, -20.0) > under + 0.15,
		"a bare crown of the same size takes far less (%.2f)" % _at(bare, 20.5, -20.0))

static func _a_boulder(t: TestCase) -> void:
	t.begin("contact occlusion/a boulder")
	var ground: HeightmapSurface = _flat()
	var shape: ContactOcclusion.Shape = ContactOcclusion.prop_shape(
		_box_faces(Vector2(0.5, 0.5), 1.0), false)
	t.eq_f(shape.top, 1.0, 1e-3, "a prop's outline runs to its top")
	t.ok(shape.profile[0] > 0.5, "and down to the ground, sunk part left out (%.2f)"
		% shape.profile[0])
	var shapes: Array[ContactOcclusion.Shape] = [shape]
	var casters: Array = [PackedVector4Array([Vector4(20.0, -20.0, 1.0, 1.0)]),
		PackedInt32Array([0]), shapes]
	var img: Image = _bake(casters, ground)
	# The box's corners reach 0.71 m from its axis, so the vertex on its face,
	# half a metre out, is inside the outline at the ground: its foot.
	var foot: float = _at(img, 20.5, -20.0)
	var out: float = _at(img, 21.5, -20.0)
	t.ok(foot < out and out < _at(img, 22.5, -20.0),
		"darker at its foot than a metre out (%.2f, %.2f)" % [foot, out])
	t.between(foot, 0.3, 0.9, "the foot of a wall loses some of the sky (%.2f)" % foot)
	# The vertex at the centre is under the boulder and never seen, but its
	# value is interpolated out across every triangle round it.
	t.eq_f(_at(img, 20.0, -20.0), foot, 1.0 / 255.0,
		"under it, the value at its foot and no darker (%.2f)" % _at(img, 20.0, -20.0))

static func _a_log(t: TestCase) -> void:
	t.begin("contact occlusion/a log")
	var ground: HeightmapSurface = _flat()
	var faces: PackedVector3Array = _box_faces(Vector2(0.5, 0.5), 1.0)
	var shapes: Array[ContactOcclusion.Shape] = [ContactOcclusion.prop_shape(faces, false),
		ContactOcclusion.prop_shape(faces, true)]
	var occluders := PackedVector4Array()
	var shape_of := PackedInt32Array()
	# 8 m long along X, 0.5 m thick, lying across the slope.
	var xf := Transform3D(Basis().scaled(Vector3(8.0, 0.5, 0.5)), Vector3(20.0, 0.0, -20.0))
	ContactOcclusion._add_prop(occluders, shape_of, xf, BoxMesh.new().get_aabb(), 0, 1,
		shapes[1].widest)
	t.ok(occluders.size() >= 8, "a long prop is a row of solids (%d)" % occluders.size())
	var img: Image = _bake([occluders, shape_of, shapes], ground)
	var beside_end: float = _at(img, 17.0, -20.5)
	var beside_mid: float = _at(img, 20.0, -20.5)
	t.ok(beside_end < 0.95 and beside_mid < 0.95,
		"shaded beside it near an end and in the middle (%.2f, %.2f)" % [beside_end, beside_mid])
	t.ok(_at(img, 20.0, -24.0) > beside_mid and _at(img, 26.5, -20.0) > beside_mid,
		"and not as a disc as wide as it is long")

static func _over_the_relief(t: TestCase) -> void:
	t.begin("contact occlusion/over the relief")
	var ground: HeightmapSurface = _flat()
	var relief := Image.create_empty(81, 81, false, Image.FORMAT_L8)
	relief.fill(Color(0.5, 0.5, 0.5))
	var level: float = relief.get_pixel(40, 40).r
	var casters: Array = _tree(Forest.Species.CONIFER, 20.0, -20.0, 4.0, 8.0)
	var alone: Image = _bake(casters, ground)
	var over: Image = _bake(casters, ground, relief)
	t.ok(_at(over, 2.0, -2.0) == level, "away from the tree the relief's value, to the byte")
	t.eq_f(_at(over, 21.0, -20.0), level * _at(alone, 21.0, -20.0), 2.0 / 255.0,
		"under it, the relief's times the tree's")
	var wrong := Image.create_empty(40, 40, false, Image.FORMAT_L8)
	t.ok(_bake(casters, ground, wrong).get_size() == Vector2i(81, 81),
		"a relief image off the grid is ignored, as the terrain would")
	t.ok(relief.get_pixel(40, 40).r == level and relief.get_format() == Image.FORMAT_L8,
		"the course's own image is left as it was")

static func _the_biggest_courses(t: TestCase) -> void:
	t.begin("contact occlusion/the biggest courses")
	var slowest: float = 0.0
	var slowest_dir: String = ""
	for dir: String in COURSES:
		var scene_path: String = "res://courses/%s/course.tscn" % dir
		if not ResourceLoader.exists(scene_path):
			continue  # a streamed web build; `TestPackStream` owns that case
		var packed: PackedScene = load(scene_path)
		var root: CourseRoot = packed.instantiate()
		root.build_runtime()
		var start: int = Time.get_ticks_usec()
		var casters: Array = ContactOcclusion.casters_of(root)
		var img: Image = _bake(casters, root.surface, root.course_data.ambient_occlusion)
		var ms: float = float(Time.get_ticks_usec() - start) / 1000.0
		if ms > slowest:
			slowest = ms
			slowest_dir = dir
		var size := Vector2i(root.surface.size.x, root.surface.size.y)
		t.ok(img != null and img.get_size() == size and img.get_format() == Image.FORMAT_L8,
			"%s (%d solids) bakes one byte per vertex"
			% [dir, (casters[0] as PackedVector4Array).size()])
		# Never lighter than the relief alone: it only takes sky away.
		var relief: PackedByteArray = root.course_data.ambient_occlusion.get_data()
		var baked: PackedByteArray = img.get_data()
		var lighter: int = 0
		for k: int in baked.size():
			if baked[k] > relief[k]:
				lighter += 1
		t.ok(lighter == 0, "%s: no vertex lighter than its relief (%d)" % [dir, lighter])
		if dir == "mountain_forest":
			# Nothing stands where the overhead trunk or a collider is.
			var left_out: Array = []
			for type_name: String in ["lodged_log", "trunk_collider"]:
				left_out.append_array(root.object_transforms.get(type_name, []))
			var found: int = 0
			for xf: Transform3D in left_out:
				for o: Vector4 in casters[0] as PackedVector4Array:
					if Vector2(o.x - xf.origin.x, o.y - xf.origin.z).length() < 0.05:
						found += 1
			t.ok(left_out.size() > 0 and found == 0,
				"the overhead trunk and the colliders are left out (%d of %d found)"
				% [found, left_out.size()])
		root.free()
	# ~150 ms on the desktop for the biggest; loose for a loaded machine.
	t.ok(slowest < 600.0, "the slowest bake is %s's, %.0f ms" % [slowest_dir, slowest])
