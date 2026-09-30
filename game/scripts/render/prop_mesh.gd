## Procedural meshes for the solid course props: a boulder, a cluster of
## stones, a fallen log and a tree stump. Drawn with `object_prop.gdshader`.
##
## ETR has no such objects, and nothing here is drawn from a picture — every
## colour is painted into the vertex colours by the builder, so nothing new has
## to pass the licence audit.
##
## Unit-sized like every other prefab mesh — ±0.5 across, 0 to 1 up — so the
## course's per-instance marker scale sizes them. A log lies along X: its
## marker's X scale is the log's length and its Y and Z scales its thickness.
## Each mesh reaches a little below 0, so it sits *in* the ground rather than on
## it: an origin on a slope leaves one side in the air otherwise.
##
## Vertex colours are stored linear (a [ShaderMaterial] reads `COLOR` raw), and
## faces are flat-shaded: a faceted rock reads as rock at a chase camera's
## distance, where a smooth one reads as a potato.
class_name PropMesh
extends RefCounted

enum Kind { BOULDER, STONES, LOG, STUMP }

## Rock greys, sRGB; a boulder picks its own tint between them.
const ROCK_LIGHT := Color(0.56, 0.55, 0.52)
const ROCK_DARK := Color(0.38, 0.38, 0.37)
## Moss and lichen on the rock's lower flanks.
const MOSS := Color(0.30, 0.33, 0.20)
const BARK := Color(0.30, 0.22, 0.16)
const BARK_DARK := Color(0.19, 0.14, 0.10)
## A cut or broken end, and its rings.
const HEARTWOOD := Color(0.62, 0.48, 0.32)
const RING := Color(0.45, 0.33, 0.21)

## Log proportions, in the unit box: the axis height and the rings.
const LOG_AXIS_Y := 0.3
const LOG_SIDES := 10
const LOG_SEGMENTS := 6
const STUMP_SIDES := 9
const STUMP_LEVELS: Array[float] = [-0.15, 0.0, 0.12, 0.45, 1.0]
const STUMP_FLARE: Array[float] = [1.0, 0.95, 0.72, 0.62, 0.6]

static func build(kind: Kind, seed_value: int = 1) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match kind:
		Kind.BOULDER:
			_rock(st, rng, Vector3(0.0, -0.15, 0.0), Vector3(0.5, 1.15, 0.5), 2)
		Kind.STONES:
			_stones(st, rng)
		Kind.LOG:
			_log(st, rng)
		Kind.STUMP:
			_stump(st, rng)
	# Normals first, from the unshared flat faces; indexing after merges only
	# the vertices that already agree.
	st.generate_normals()
	st.index()
	return st.commit()

# ---------------------------------------------------------------- rock

## A rock: an icosphere pushed about by a few random plane cuts, then fitted
## into a box [param radii] across (half-extents) and `radii.y` tall from
## [param base]. The cuts are what make it look fractured rather than lumpy.
static func _rock(st: SurfaceTool, rng: RandomNumberGenerator, base: Vector3,
		radii: Vector3, subdivisions: int) -> void:
	var sphere: Array = _icosphere(subdivisions)
	var verts: PackedVector3Array = sphere[0]
	var tris: PackedInt32Array = sphere[1]

	var cut_normals: Array[Vector3] = []
	var cut_depths: Array[float] = []
	for i: int in 7:
		cut_normals.push_back(Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.6, 1.0),
			rng.randf_range(-1.0, 1.0)).normalized())
		cut_depths.push_back(rng.randf_range(0.55, 0.85))
	var shaped := PackedVector3Array()
	for v: Vector3 in verts:
		var p: Vector3 = v * rng.randf_range(0.93, 1.07)
		for i: int in cut_normals.size():
			var d: float = p.dot(cut_normals[i])
			if d > cut_depths[i]:
				p -= cut_normals[i] * (d - cut_depths[i])
		# Flatter underneath: rocks settle.
		if p.y < -0.3:
			p.y = -0.3 + (p.y + 0.3) * 0.3
		shaped.push_back(p)
	var lo := INF
	var hi := -INF
	for p: Vector3 in shaped:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	for i: int in shaped.size():
		var p: Vector3 = shaped[i]
		var t: float = (p.y - lo) / maxf(hi - lo, 0.001)
		shaped[i] = base + Vector3(p.x * radii.x, t * radii.y, p.z * radii.z)

	var inside: Vector3 = base + Vector3(0.0, radii.y * 0.4, 0.0)
	var tint: Color = ROCK_DARK.lerp(ROCK_LIGHT, rng.randf())
	for f: int in range(0, tris.size(), 3):
		var a: Vector3 = shaped[tris[f]]
		var b: Vector3 = shaped[tris[f + 1]]
		var c: Vector3 = shaped[tris[f + 2]]
		var mid_y: float = (a.y + b.y + c.y) / 3.0
		# Per-face shade, so each facet reads; mossier toward the ground.
		var col: Color = tint * rng.randf_range(0.85, 1.12)
		var low: float = clampf(1.0 - (mid_y - base.y) / (radii.y * 0.5), 0.0, 1.0)
		col = col.lerp(MOSS, low * rng.randf_range(0.0, 0.6))
		_tri(st, a, b, c, col, inside)

static func _stones(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	for i: int in rng.randi_range(5, 8):
		var r: float = rng.randf_range(0.08, 0.2)
		var at := Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 0.5 - r)
		var h: float = r * rng.randf_range(0.9, 1.6)
		_rock(st, rng, Vector3(at.x, -h * 0.3, at.y),
			Vector3(r * rng.randf_range(0.8, 1.2), h, r * rng.randf_range(0.8, 1.2)), 1)

# ---------------------------------------------------------------- wood

## A fallen trunk along X, centred, radius 0.5 in Y and Z with its axis at
## [constant LOG_AXIS_Y], so a fifth of it is in the ground. Ridged bark, both
## ends cut to show their rings, and a few broken branch stubs.
static func _log(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var sag: float = rng.randf_range(-0.04, 0.04)
	# `rings[s][k]`: the point on ring s at side k.
	var rings: Array[PackedVector3Array] = []
	for s: int in LOG_SEGMENTS + 1:
		var along: float = float(s) / LOG_SEGMENTS
		var taper: float = lerpf(1.0, 0.82, along)
		var bend: float = sag * sin(PI * along)
		var ring := PackedVector3Array()
		for k: int in LOG_SIDES:
			var ang: float = TAU * float(k) / LOG_SIDES
			var r: float = 0.5 * taper * rng.randf_range(0.9, 1.05)
			ring.push_back(Vector3(-0.5 + along, LOG_AXIS_Y + bend + cos(ang) * r,
				sin(ang) * r))
		rings.push_back(ring)
	var axis := Vector3(0.0, LOG_AXIS_Y, 0.0)
	for s: int in LOG_SEGMENTS:
		for k: int in LOG_SIDES:
			var k1: int = (k + 1) % LOG_SIDES
			var col: Color = (BARK if (k + s) % 3 != 0 else BARK_DARK) \
				* rng.randf_range(0.85, 1.1)
			_quad(st, rings[s][k], rings[s + 1][k], rings[s + 1][k1], rings[s][k1], col,
				axis)
	_end_cap(st, rng, rings[0], axis)
	_end_cap(st, rng, rings[LOG_SEGMENTS], axis)
	for i: int in rng.randi_range(2, 4):
		var ang: float = rng.randf_range(-1.2, 1.2)
		var dir := Vector3(rng.randf_range(-0.3, 0.3), cos(ang), sin(ang)).normalized()
		var root := Vector3(rng.randf_range(-0.35, 0.35), LOG_AXIS_Y, 0.0) + dir * 0.4
		_stub(st, root, dir, 0.09, 0.03, rng.randf_range(0.25, 0.5))

## Close a ring with bands painted in: heartwood, a darker ring, heartwood, and
## the bark's edge.
static func _end_cap(st: SurfaceTool, rng: RandomNumberGenerator,
		rim: PackedVector3Array, inside: Vector3) -> void:
	var centre := Vector3.ZERO
	for p: Vector3 in rim:
		centre += p
	centre /= float(rim.size())
	const BANDS: Array[float] = [0.35, 0.6, 0.85, 1.0]
	var inner := PackedVector3Array()
	for p: Vector3 in rim:
		inner.push_back(centre)
	for band: int in BANDS.size():
		var ring := PackedVector3Array()
		for p: Vector3 in rim:
			ring.push_back(centre.lerp(p, BANDS[band]))
		var col: Color = HEARTWOOD if band % 2 == 0 else RING
		if band == BANDS.size() - 1:
			col = BARK_DARK
		col = col * rng.randf_range(0.92, 1.05)
		for k: int in rim.size():
			var k1: int = (k + 1) % rim.size()
			if band == 0:
				_tri(st, centre, ring[k], ring[k1], col, inside)
			else:
				_quad(st, inner[k], ring[k], ring[k1], inner[k1], col, inside)
		inner = ring

## A stump: a short trunk flaring into roots at the ground, cut on top.
static func _stump(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var jitter := PackedFloat32Array()
	for k: int in STUMP_SIDES:
		jitter.push_back(rng.randf_range(0.85, 1.1))
	var tilt := Vector2(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12))
	var rings: Array[PackedVector3Array] = []
	for l: int in STUMP_LEVELS.size():
		var ring := PackedVector3Array()
		for k: int in STUMP_SIDES:
			var ang: float = TAU * float(k) / STUMP_SIDES
			# Roots: the lowest two rings bulge out on every other side.
			var root: float = 1.35 if l <= 1 and k % 2 == 0 else 1.0
			var r: float = 0.5 * STUMP_FLARE[l] * jitter[k] * root
			var p := Vector3(cos(ang) * r, STUMP_LEVELS[l], sin(ang) * r)
			if l == STUMP_LEVELS.size() - 1:
				p.y += p.x * tilt.x + p.z * tilt.y
			ring.push_back(p)
		rings.push_back(ring)
	for l: int in STUMP_LEVELS.size() - 1:
		var inside := Vector3(0.0, (STUMP_LEVELS[l] + STUMP_LEVELS[l + 1]) * 0.5, 0.0)
		for k: int in STUMP_SIDES:
			var k1: int = (k + 1) % STUMP_SIDES
			var col: Color = (BARK if k % 3 != 0 else BARK_DARK) * rng.randf_range(0.85, 1.1)
			_quad(st, rings[l][k], rings[l + 1][k], rings[l + 1][k1], rings[l][k1], col,
				inside)
	_end_cap(st, rng, rings[STUMP_LEVELS.size() - 1], Vector3(0.0, 0.5, 0.0))

# ---------------------------------------------------------------- helpers

## A broken branch: a tapered five-sided prism with a pale broken tip.
static func _stub(st: SurfaceTool, root: Vector3, dir: Vector3, r0: float, r1: float,
		length: float) -> void:
	const SIDES := 5
	var side: Vector3 = dir.cross(Vector3.RIGHT)
	if side.length() < 0.1:
		side = dir.cross(Vector3.UP)
	side = side.normalized()
	var other: Vector3 = dir.cross(side).normalized()
	var tip: Vector3 = root + dir * length
	# Behind the root, so every face — the tip too — points away from it.
	var inside: Vector3 = root - dir * 0.2
	for k: int in SIDES:
		var o0: Vector3 = side * cos(TAU * k / SIDES) + other * sin(TAU * k / SIDES)
		var o1: Vector3 = side * cos(TAU * (k + 1) / SIDES) + other * sin(TAU * (k + 1) / SIDES)
		_quad(st, root + o0 * r0, tip + o0 * r1, tip + o1 * r1, root + o1 * r0, BARK, inside)
		_tri(st, tip, tip + o0 * r1, tip + o1 * r1, HEARTWOOD, inside)

## One flat-shaded triangle, wound clockwise as seen from outside (Godot's front
## face), where outside is away from [param inside] — so no caller has to get a
## winding right. [param colour] is sRGB and stored linear.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, colour: Color,
		inside: Vector3) -> void:
	var centroid: Vector3 = (a + b + c) / 3.0
	# Counter-clockwise from the viewer puts (b-a)x(c-a) toward the viewer.
	if (b - a).cross(c - a).dot(centroid - inside) > 0.0:
		var swap: Vector3 = b
		b = c
		c = swap
	var lin: Color = colour.srgb_to_linear()
	lin.a = 1.0
	# -1: this face's own normal, shared with no neighbour.
	st.set_smooth_group(0xFFFFFFFF)
	st.set_color(lin)
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)

static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		colour: Color, inside: Vector3) -> void:
	_tri(st, a, b, c, colour, inside)
	_tri(st, a, c, d, colour, inside)

## Unit icosphere: `[vertices, triangle indices]`, winding unspecified.
static func _icosphere(subdivisions: int) -> Array:
	var t: float = (1.0 + sqrt(5.0)) / 2.0
	var verts := PackedVector3Array([
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	])
	for i: int in verts.size():
		verts[i] = verts[i].normalized()
	var tris := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])
	for s: int in subdivisions:
		var mids: Dictionary[int, int] = {}
		var next := PackedInt32Array()
		for f: int in range(0, tris.size(), 3):
			var corner: Array[int] = [tris[f], tris[f + 1], tris[f + 2]]
			var mid: Array[int] = []
			for e: int in 3:
				var i: int = corner[e]
				var j: int = corner[(e + 1) % 3]
				var key: int = mini(i, j) * 65536 + maxi(i, j)
				if not mids.has(key):
					verts.push_back(((verts[i] + verts[j]) * 0.5).normalized())
					mids[key] = verts.size() - 1
				mid.push_back(mids[key])
			next.append_array(PackedInt32Array([
				corner[0], mid[0], mid[2], corner[1], mid[1], mid[0],
				corner[2], mid[2], mid[1], mid[0], mid[1], mid[2]]))
		tris = next
	return [verts, tris]
