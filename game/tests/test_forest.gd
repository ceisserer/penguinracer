## The 3D conifer and bare tree: their mesh levels, the impostor's view
## mapping, and how [Forest] cuts a course's trees into bands and cells.
##
## Nothing here renders — the suite is headless — so each check is on what feeds
## the GPU: the mesh arrays, the directions the atlas was baked from, the bands
## the shader is handed. What the frame looks like is `tools/shot.sh`'s job.
class_name TestForest
extends RefCounted

static func run(t: TestCase) -> void:
	_levels_get_cheaper(t)
	_the_mesh_fills_the_unit_box(t)
	_views_round_trip(t)
	_view_basis_is_a_rotation(t)
	_bands_tile_the_distance(t)
	_cells_hold_every_tree_once(t)
	_conifers_are_marked(t)
	_the_atlases_are_baked(t)
	_bare_levels_get_cheaper(t)
	_the_bare_tree_fills_the_unit_box(t)
	_only_limbs_are_widened(t)
	_the_bare_texture(t)
	_bare_trees_are_marked(t)

static func _levels_get_cheaper(t: TestCase) -> void:
	t.begin("forest/levels of detail")
	var last: int = 1 << 30
	for level: int in ConiferMesh.LODS:
		var tris: int = ConiferMesh.triangle_count(level)
		t.ok(tris > 0, "LOD %d has geometry (%d triangles)" % [level, tris])
		t.ok(tris * 3 / 2 <= last, "LOD %d costs at most two thirds of the one before (%d)" % [level, tris])
		last = tris
	# The impostor is one quad, whatever the tree.
	var quad: ArrayMesh = ConiferMesh.impostor_mesh()
	t.ok((quad.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() == 6,
		"the impostor is two triangles")
	# Its four vertices are all at the centre until the shader moves them, so
	# only the custom AABB stops it being culled as a point.
	var box: AABB = quad.custom_aabb
	t.ok(box.has_point(Vector3(0.49, 0.99, 0.49)) and box.has_point(Vector3(-0.49, 0.01, -0.49)),
		"the impostor's AABB holds the whole unit tree")

## The course's per-instance scale assumes a tree ±0.5 across and 0..1 up, like
## the cross it replaces; a mesh that pokes out is a tree wider than its
## collision cylinder.
static func _the_mesh_fills_the_unit_box(t: TestCase) -> void:
	t.begin("forest/unit box")
	for level: int in ConiferMesh.LODS:
		var verts: PackedVector3Array = ConiferMesh.mesh(level).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var worst_r: float = 0.0
		var lo: float = 1.0
		var hi: float = 0.0
		for v: Vector3 in verts:
			worst_r = maxf(worst_r, Vector2(v.x, v.z).length())
			lo = minf(lo, v.y)
			hi = maxf(hi, v.y)
		t.ok(worst_r <= 0.5 + 1e-4, "LOD %d stays inside the collision radius (%.3f)" % [level, worst_r])
		t.ok(lo >= -1e-4 and hi <= 1.0 + 1e-4, "LOD %d stands 0..1 (%.3f..%.3f)" % [level, lo, hi])
		var colors: PackedColorArray = ConiferMesh.mesh(level).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		t.ok(colors.size() == verts.size(), "LOD %d carries its shader flags" % level)

## `conifer_impostor.gdshader` encodes a view direction and looks the frame up;
## the baker decodes the frame to a direction and draws it. If the two disagree
## the impostor shows a tree from the wrong side — silently, since every frame
## is a plausible tree.
static func _views_round_trip(t: TestCase) -> void:
	t.begin("forest/hemi-octahedral views")
	var n: int = ConiferMesh.ATLAS_GRID
	var worst: float = 0.0
	var below: int = 0
	for j: int in n:
		for i: int in n:
			var d: Vector3 = ConiferMesh.frame_direction(i, j)
			var back: Vector2 = ConiferMesh.hemi_oct_encode(d) * float(n - 1)
			worst = maxf(worst, back.distance_to(Vector2(i, j)))
			if d.y < -1e-6:
				below += 1
	t.ok(worst < 1e-3, "every view decodes and encodes back to its own tile (worst %.5f)" % worst)
	t.ok(below == 0, "no view is from below the horizon (%d)" % below)
	# The horizon is where a racer sees almost every tree from: the grid's edge.
	var horizon: Vector3 = ConiferMesh.frame_direction(0, n / 2)
	t.ok(absf(horizon.y) < 0.2, "the grid's edge is near the horizon (y %.3f)" % horizon.y)
	var pole: Vector2 = ConiferMesh.hemi_oct_encode(Vector3.UP)
	t.ok(pole.distance_to(Vector2(0.5, 0.5)) < 1e-6, "straight down is the atlas centre")
	# A direction below the horizon folds onto it rather than wrapping round.
	var under: Vector2 = ConiferMesh.hemi_oct_encode(Vector3(1.0, -0.3, 0.0).normalized())
	var level: Vector2 = ConiferMesh.hemi_oct_encode(Vector3(1.0, 0.0, 0.0))
	t.ok(under.distance_to(level) < 1e-6, "a view from below reads as a level view")

static func _view_basis_is_a_rotation(t: TestCase) -> void:
	t.begin("forest/view basis")
	for d: Vector3 in [Vector3(1, 0, 0), Vector3(0, 0.3, 1).normalized(),
			Vector3(-0.4, 0.8, 0.2).normalized(), Vector3.UP]:
		var b: Basis = ConiferMesh.view_basis(d)
		t.ok(absf(b.determinant() - 1.0) < 1e-4, "right-handed and unit for %s" % d)
		t.ok(b.z.distance_to(d) < 1e-5, "its z is the view for %s" % d)
		if absf(d.y) < 0.99:
			t.ok(b.y.y > 0.0, "the card's up leans up for %s" % d)

static func _bands_tile_the_distance(t: TestCase) -> void:
	t.begin("forest/bands")
	for impostor: bool in [true, false]:
		var levels: int = Forest.level_count(impostor)
		var first: Vector2 = Forest.band(0, levels)
		var last: Vector2 = Forest.band(levels - 1, levels)
		t.ok(first.x < -1.0e5, "the nearest level has no near edge (impostor %s)" % impostor)
		t.ok(last.y > 1.0e5, "the farthest has no far edge (impostor %s)" % impostor)
		for level: int in levels - 1:
			var a: Vector2 = Forest.band(level, levels)
			var b: Vector2 = Forest.band(level + 1, levels)
			t.ok(a.y == b.x, "level %d ends where %d begins" % [level, level + 1])
			t.ok(b.y - b.x > Forest.FADE_WIDTH or b.y > 1.0e5,
				"level %d is wider than a hand-over" % (level + 1))
	# The shader's fade: at a boundary both neighbours half-draw the tree, and
	# anywhere the pair's coverage adds up to one.
	var edge: float = Forest.LOD_ENDS[0]
	for d: float in [edge - 12.0, edge - 2.0, edge, edge + 1.9, edge + 8.0]:
		var out_near: float = _fade(d, Forest.band(0, 4)).y
		var in_far: float = _fade(d, Forest.band(1, 4)).x
		t.ok(absf(out_near - in_far) < 1e-6,
			"at %.1f m LOD 0 leaves exactly what LOD 1 takes (%.3f, %.3f)" % [d, out_near, in_far])

## `conifer_lod_fade`, for the test.
static func _fade(d: float, b: Vector2) -> Vector2:
	var h: float = Forest.FADE_WIDTH * 0.5
	return Vector2(clampf((d - (b.x - h)) / Forest.FADE_WIDTH, 0.0, 1.0),
		clampf((d - (b.y - h)) / Forest.FADE_WIDTH, 0.0, 1.0))

static func _cells_hold_every_tree_once(t: TestCase) -> void:
	t.begin("forest/cells")
	var xfs: Array[Transform3D] = []
	for i: int in 500:
		xfs.push_back(Transform3D(Basis(), Vector3(fmod(i * 7.3, 300.0) - 150.0, 0.0, -i * 3.1)))
	var cells: Dictionary[Vector2i, PackedInt32Array] = Forest.cells_of(xfs)
	var seen := PackedInt32Array()
	seen.resize(xfs.size())
	var escaped: int = 0
	for key: Vector2i in cells:
		for i: int in cells[key]:
			seen[i] += 1
			var o: Vector3 = xfs[i].origin
			if floori(o.x / Forest.CELL_SIZE) != key.x or floori(o.z / Forest.CELL_SIZE) != key.y:
				escaped += 1
	t.ok(seen.count(1) == xfs.size(), "every tree is in exactly one cell")
	t.ok(escaped == 0, "and it is the cell it stands in")

## The prefab flag is what switches a type to [Forest]; the cross it carries is
## still asserted by `TestObjects`.
static func _conifers_are_marked(t: TestCase) -> void:
	t.begin("forest/which prefabs")
	for id: String in ["tree", "tree1"]:
		var p: ObjectPrefab = load("res://resources/objects/%s.tres" % id)
		t.ok(p != null and p.conifer, "%s is a conifer" % id)
	for id: String in ["tree_barren", "tree_barren2", "shrub", "herring"]:
		var p: ObjectPrefab = load("res://resources/objects/%s.tres" % id)
		t.ok(p != null and not p.conifer, "%s is not" % id)
	# And the embedded copy, which is the one that renders.
	var scene: PackedScene = load("res://courses/bunny_hill/course.tscn")
	var root: CourseRoot = scene.instantiate() as CourseRoot
	t.ok(root != null and root.object_prefabs["tree"].conifer, "the course's own tree is a conifer")
	if root != null:
		root.free()

static func _the_atlases_are_baked(t: TestCase) -> void:
	t.begin("forest/impostor atlases")
	# The shader spells the atlas layout out as constants; they have to be
	# `ConiferMesh`'s, or it samples between tiles.
	var code: String = (load(Forest.IMPOSTOR_SHADER) as Shader).code
	for line: String in ["const float GRID = %.1f;" % ConiferMesh.ATLAS_GRID,
			"const float TILE = %.1f;" % ConiferMesh.ATLAS_TILE,
			"const float RADIUS = %s;" % ConiferMesh.IMPOSTOR_RADIUS]:
		t.ok(code.contains(line), "the impostor shader says `%s`" % line)
	t.ok(Forest.has_impostor(), "both atlases are in the project")
	var size: int = ConiferMesh.ATLAS_GRID * ConiferMesh.ATLAS_TILE
	for path: String in [ConiferMesh.ALBEDO_ATLAS, ConiferMesh.NORMAL_ATLAS]:
		var tex: Texture2D = load(path)
		t.ok(tex != null and tex.get_width() == size and tex.get_height() == size,
			"%s is %d² — the grid the shader assumes" % [path.get_file(), size])

static func _bare_levels_get_cheaper(t: TestCase) -> void:
	t.begin("forest/bare tree levels")
	var last: int = 1 << 30
	for level: int in BareTreeMesh.LODS:
		var tris: int = BareTreeMesh.triangle_count(level)
		t.ok(tris > 0, "LOD %d has geometry (%d triangles)" % [level, tris])
		t.ok(tris * 3 / 2 <= last, "LOD %d costs at most two thirds of the one before (%d)" % [level, tris])
		last = tris
	t.ok(BareTreeMesh.LODS == ConiferMesh.LODS,
		"as many levels as the conifer, so the two share Forest's bands")
	# Every level draws the same skeleton; only the finest limbs drop out.
	var orders := {}
	for b: Dictionary in BareTreeMesh.skeleton():
		orders[b["order"]] = orders.get(b["order"], 0) + 1
	t.ok(orders.get(0, 0) == 1, "one trunk")
	t.ok(orders.get(3, 0) > orders.get(2, 0) and orders.get(2, 0) > orders.get(1, 0),
		"each order of branch outnumbers the one before (%s)" % orders)
	var again: Array[Dictionary] = BareTreeMesh._grow()
	var first: Dictionary = BareTreeMesh.skeleton()[-1]
	t.ok((again[-1]["points"] as PackedVector3Array) == (first["points"] as PackedVector3Array),
		"the skeleton is the same every time it is grown")

## As for the conifer: the per-instance scale assumes ±0.5 across and 0..1 up.
static func _the_bare_tree_fills_the_unit_box(t: TestCase) -> void:
	t.begin("forest/bare tree unit box")
	for level: int in BareTreeMesh.LODS:
		var arrays: Array = BareTreeMesh.mesh(level).surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var worst_r: float = 0.0
		var lo: float = 1.0
		var hi: float = 0.0
		for v: Vector3 in verts:
			worst_r = maxf(worst_r, Vector2(v.x, v.z).length())
			lo = minf(lo, v.y)
			hi = maxf(hi, v.y)
		t.ok(worst_r <= 0.5 + 1e-4, "LOD %d stays inside the collision radius (%.3f)" % [level, worst_r])
		t.ok(lo >= -0.05 and hi <= 1.0 + 1e-4, "LOD %d stands 0..1 (%.3f..%.3f)" % [level, lo, hi])
		# And fills it: the picture's crown is nearly the full width.
		t.ok(worst_r > 0.4 and hi > 0.85, "LOD %d reaches the crown's edge (r %.3f, top %.3f)" % [level, worst_r, hi])
		t.ok((arrays[Mesh.ARRAY_COLOR] as PackedColorArray).size() == verts.size(),
			"LOD %d carries its shader flags" % level)

## `COLOR.b` is what `conifer.gdshader` widens by. A card with a radius code
## would be pushed off its plane; a conifer vertex with one would swell.
static func _only_limbs_are_widened(t: TestCase) -> void:
	t.begin("forest/limb widening")
	var arrays: Array = BareTreeMesh.mesh(0).surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var tubes: int = 0
	var wrong: int = 0
	for i: int in colors.size():
		var on_bark: bool = uvs[i].x >= BareTreeMesh.BARK_U
		if colors[i].b > 0.0:
			tubes += 1
		if on_bark != (colors[i].b > 0.0):
			wrong += 1
	t.ok(tubes > 0, "the limbs code a radius (%d vertices)" % tubes)
	t.ok(wrong == 0, "exactly the bark-textured vertices do (%d disagree)" % wrong)
	var widest: float = 0.0
	for c: Color in colors:
		widest = maxf(widest, c.b)
	t.ok(widest < 1.0, "the trunk's code fits the channel (%.3f)" % widest)
	var conifer: PackedColorArray = ConiferMesh.mesh(0).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var coded: int = 0
	for c: Color in conifer:
		if c.b > 0.0:
			coded += 1
	t.ok(coded == 0, "no conifer vertex codes one (%d)" % coded)
	var code: String = (load(Forest.MESH_SHADER) as Shader).code
	t.ok(code.contains("const float RADIUS_CODE_SCALE = %.1f;" % BareTreeMesh.RADIUS_CODE_SCALE),
		"the shader decodes it with the mesh's scale")

static func _the_bare_texture(t: TestCase) -> void:
	t.begin("forest/bare tree texture")
	var img: Image = BareTreeMesh.make_texture()
	var s: int = BareTreeMesh.TEXTURE_SIZE
	t.ok(img.get_width() == s and img.get_height() == s, "%d²" % s)
	var bark_x: int = roundi(s * BareTreeMesh.BARK_U)
	var holes: int = 0
	for y: int in range(0, s, 7):
		for x: int in range(bark_x, s, 5):
			if img.get_pixel(x, y).a < 1.0:
				holes += 1
	t.ok(holes == 0, "the bark strip is opaque (%d holes)" % holes)
	# Each spray cell has twigs in it and is mostly air.
	var cell := Vector2i(roundi(s * BareTreeMesh.BARK_U * 0.5), s / 2)
	for v: int in 4:
		var o := Vector2i((v % 2) * cell.x, (v / 2) * cell.y)
		var solid: int = 0
		var n: int = 0
		for y: int in range(o.y, o.y + cell.y, 2):
			for x: int in range(o.x, o.x + cell.x, 2):
				n += 1
				if img.get_pixel(x, y).a > 0.5:
					solid += 1
		var f: float = float(solid) / float(n)
		t.ok(f > 0.01 and f < 0.35, "spray %d covers %.1f %% of its cell" % [v, f * 100.0])
	t.ok(BareTreeMesh.texture().get_image().has_mipmaps(), "the runtime texture has its mips")

static func _bare_trees_are_marked(t: TestCase) -> void:
	t.begin("forest/which prefabs are bare")
	for id: String in ["tree_barren", "tree_barren2"]:
		var p: ObjectPrefab = load("res://resources/objects/%s.tres" % id)
		t.ok(p != null and p.bare and not p.conifer, "%s is a bare tree" % id)
	for id: String in ["tree", "tree1", "shrub", "herring"]:
		var p: ObjectPrefab = load("res://resources/objects/%s.tres" % id)
		t.ok(p != null and not p.bare, "%s is not" % id)
	# Every course's embedded copies, which are the ones that render. Read as
	# text: instancing 44 scenes of thousands of markers would be most of the
	# suite's run time.
	var catalog: CourseCatalog = CourseCatalog.load_default()
	var unmarked: PackedStringArray = []
	var seen: int = 0
	for entry: CourseListing in catalog.entries:
		var text: String = FileAccess.get_file_as_string(entry.scene_path)
		for id: String in ["tree_barren", "tree_barren2"]:
			var at: int = text.find('id = &"%s"\n' % id)
			if at < 0:
				continue
			seen += 1
			var block: String = text.substr(at, text.find("\n\n", at) - at)
			if not block.contains("\nbare = true"):
				unmarked.push_back("%s/%s" % [entry.dir, id])
	t.ok(seen > 40, "the courses embed bare-tree prefabs (%d)" % seen)
	t.ok(unmarked.is_empty(), "every course draws its bare trees as bare trees %s" % unmarked)
	t.ok(Forest.has_impostor(Forest.Species.BARE), "the bare tree's atlases are in the project")
	var size: int = ConiferMesh.ATLAS_GRID * ConiferMesh.ATLAS_TILE
	for path: String in Forest.atlases(Forest.Species.BARE):
		var tex: Texture2D = load(path)
		t.ok(tex != null and tex.get_width() == size and tex.get_height() == size,
			"%s is %d² — the grid the shader assumes" % [path.get_file(), size])
