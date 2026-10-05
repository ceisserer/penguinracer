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
## Vertex colours are stored linear (a [ShaderMaterial] reads `COLOR` raw).
## A rock's flat cuts stay flat with a hard edge, which is what reads as rock
## rather than a potato; the weathered surface between them, and the bark of a
## log or stump, is shaded smooth ([constant ROCK_SMOOTH_GROUP],
## [constant BARK_SMOOTH_GROUP]). A colour or a normal of its own on every small
## face draws a patchwork of triangles close up — rock and bark are coloured
## by position (a rock) or down each side (bark), never per face.
class_name PropMesh
extends RefCounted

## [code]TRUNK[/code] is a log for long spans — a dead tree lodged across a
## gully, ten to twenty times as long as it is thick (Mountain Forest). The
## rest are Snow Park's furniture ([method park_size]): a snowman, an igloo,
## and a chairlift's parts — a tower, a length of cable, a chair and the
## station at either end.
enum Kind { BOULDER, STONES, LOG, STUMP, TRUNK, SNOWMAN, IGLOO, LIFT_TOWER, LIFT_CABLE,
	LIFT_CHAIR, LIFT_STATION }

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
## A trunk is stretched much further than a log, so it has more of both, and
## its bark's unevenness runs along it rather than changing ring by ring —
## stretched twelve times, a per-ring wobble reads as a stack of planks.
const TRUNK_SIDES := 12
const TRUNK_SEGMENTS := 16
## How much longer than thick a marker makes each, typically: a log 2.5-6 m by
## 0.3-0.55 m, a trunk 7-15 m by 0.45-0.8 m (Mountain Forest). Its branch stubs
## are built this much narrower along X, so that the stretch leaves them round —
## built round in the unit box, they came out as blades 1-2 m long and a few
## centimetres thick, a pale strip of broken tip smeared along the bark.
const LOG_STRETCH := 10.0
## The bark of a log or trunk is shaded smooth round its girth — faceted, a
## 12-sided trunk reads as a sawn beam up close. Rock, cut ends and stubs stay
## flat. Any group but the flat one; SurfaceTool averages within it.
const BARK_SMOOTH_GROUP := 1
## A boulder's or stone's surface between its flat cuts, shaded smooth; the
## cuts themselves stay flat ([method _rock]).
const ROCK_SMOOTH_GROUP := 2
const TRUNK_STRETCH := 15.0
const STUMP_SIDES := 9
const STUMP_LEVELS: Array[float] = [-0.15, 0.0, 0.12, 0.45, 1.0]
const STUMP_FLARE: Array[float] = [1.0, 0.95, 0.72, 0.62, 0.6]

## Snow Park's colours, sRGB like the rest.
const PACKED_SNOW := Color(0.93, 0.95, 0.99)
const ICE_BLOCK := Color(0.84, 0.90, 0.97)
const COAL := Color(0.08, 0.08, 0.09)
const CARROT := Color(0.93, 0.45, 0.10)
const SCARF := Color(0.75, 0.10, 0.12)
const TWIG := Color(0.32, 0.22, 0.14)
const DOORWAY := Color(0.05, 0.06, 0.09)
const CONCRETE := Color(0.55, 0.55, 0.53)
const STEEL := Color(0.52, 0.55, 0.58)
const LIFT_PAINT := Color(0.88, 0.62, 0.10)
const MACHINE_DARK := Color(0.16, 0.17, 0.19)
const SEAT := Color(0.14, 0.30, 0.62)
const PLANKS := Color(0.45, 0.30, 0.18)
const ROOF := Color(0.58, 0.13, 0.10)
const WINDOW := Color(0.10, 0.13, 0.17)
## The chairlift's geometry, in metres at [method park_size], for the course
## that strings it together: how far either line runs from the lift's middle,
## how high up a tower the cable passes (a share of its height), how far below
## the cable a chair's seat hangs, and where a station's bullwheel turns.
const LIFT_LINE_OFFSET := 2.4
const TOWER_CABLE_SHARE := 0.94
const CHAIR_HANG := 2.62
const STATION_WHEEL := Vector3(0.0, 4.75, 3.0)

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
		Kind.TRUNK:
			_trunk(st, rng)
		Kind.SNOWMAN:
			_snowman(st, rng)
		Kind.IGLOO:
			_igloo(st, rng)
		Kind.LIFT_TOWER:
			_lift_tower(st)
		Kind.LIFT_CABLE:
			_tube(st, Vector3(-0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0), 0.5, 0.5, 6, MACHINE_DARK,
				true, false)
		Kind.LIFT_CHAIR:
			_lift_chair(st)
		Kind.LIFT_STATION:
			_lift_station(st)
	# Normals first, from the unshared flat faces; indexing after merges only
	# the vertices that already agree.
	st.generate_normals()
	st.index()
	var mesh: ArrayMesh = st.commit()
	return _to_unit(mesh, park_size(kind)) if kind >= Kind.SNOWMAN else mesh

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
	# Which cuts each vertex ends up on, as a bit mask: a triangle with all three
	# corners on one cut is part of that flat face.
	var on_cut := PackedInt32Array()
	for v: Vector3 in verts:
		var p: Vector3 = v * rng.randf_range(0.93, 1.07)
		for i: int in cut_normals.size():
			var d: float = p.dot(cut_normals[i])
			if d > cut_depths[i]:
				p -= cut_normals[i] * (d - cut_depths[i])
		# Flatter underneath: rocks settle.
		if p.y < -0.3:
			p.y = -0.3 + (p.y + 0.3) * 0.3
		var mask: int = 0
		for i: int in cut_normals.size():
			if absf(p.dot(cut_normals[i]) - cut_depths[i]) < 1e-4:
				mask |= 1 << i
		on_cut.push_back(mask)
		shaped.push_back(p)
	# The colour's slow variation over the rock: a few long waves through the
	# unit sphere, one set for the shade and one for the moss.
	var waves: Array[Vector4] = []
	for i: int in 6:
		var k := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)).normalized() * rng.randf_range(2.0, 4.0)
		waves.push_back(Vector4(k.x, k.y, k.z, rng.randf() * TAU))
	var unit: PackedVector3Array = shaped.duplicate()
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
	# A colour per vertex, not per face, so the triangles meeting at a corner
	# agree there: a random shade and moss on every face drew the rock as a
	# patchwork of triangles. Mossier toward the ground.
	var colours := PackedColorArray()
	for i: int in shaped.size():
		var p: Vector3 = unit[i]
		var shade: float = 0.0
		var moss: float = 0.0
		for w: int in 3:
			shade += sin(p.dot(Vector3(waves[w].x, waves[w].y, waves[w].z)) + waves[w].w) / 3.0
			moss += sin(p.dot(Vector3(waves[w + 3].x, waves[w + 3].y, waves[w + 3].z))
				+ waves[w + 3].w) / 3.0
		var low: float = clampf(1.0 - (shaped[i].y - base.y) / (radii.y * 0.5), 0.0, 1.0)
		colours.push_back((tint * (1.0 + 0.12 * shade)).lerp(MOSS,
			low * clampf(0.3 + 0.5 * moss, 0.0, 0.6)))
	for f: int in range(0, tris.size(), 3):
		var i0: int = tris[f]
		var i1: int = tris[f + 1]
		var i2: int = tris[f + 2]
		# A face cut flat stays one flat facet with a hard edge round it — that
		# is what makes the rock look fractured. The rest is the weathered
		# surface between the cuts, shaded smooth: flat, each of its small
		# triangles caught the light on its own.
		var flat: bool = (on_cut[i0] & on_cut[i1] & on_cut[i2]) != 0
		var group: int = 0xFFFFFFFF if flat else ROCK_SMOOTH_GROUP
		_tri_shaded(st, shaped[i0], shaped[i1], shaped[i2], colours[i0], colours[i1],
			colours[i2], inside, group)

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
	# One colour down each side, so the bark is streaked along the log — a
	# colour per patch drew it as a checkerboard of light and dark blocks.
	var side_col: Array[Color] = _bark_sides(rng, LOG_SIDES)
	for s: int in LOG_SEGMENTS:
		for k: int in LOG_SIDES:
			var k1: int = (k + 1) % LOG_SIDES
			_quad(st, rings[s][k], rings[s + 1][k], rings[s + 1][k1], rings[s][k1], side_col[k],
				axis, BARK_SMOOTH_GROUP)
	_end_cap(st, rng, rings[0], axis)
	_end_cap(st, rng, rings[LOG_SEGMENTS], axis)
	for i: int in rng.randi_range(2, 4):
		var ang: float = rng.randf_range(-1.2, 1.2)
		var dir := Vector3(rng.randf_range(-0.3, 0.3), cos(ang), sin(ang)).normalized()
		var root := Vector3(rng.randf_range(-0.35, 0.35), LOG_AXIS_Y, 0.0) + dir * 0.4
		_stub(st, root, dir, 0.09, 0.07, rng.randf_range(0.12, 0.25), LOG_STRETCH)

## A long dead trunk: tapering to its top end, sagging a little, bark in
## streaks along it, broken-off branches standing out square to it, and both
## ends broken off.
static func _trunk(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var sag: float = rng.randf_range(-0.05, 0.02)
	var side_r := PackedFloat32Array()
	var side_col: Array[Color] = []
	for k: int in TRUNK_SIDES:
		side_r.push_back(rng.randf_range(0.9, 1.04))
		side_col.push_back(BARK.lerp(BARK_DARK, rng.randf()) * rng.randf_range(0.85, 1.1))
	var rings: Array[PackedVector3Array] = []
	for s: int in TRUNK_SEGMENTS + 1:
		var along: float = float(s) / TRUNK_SEGMENTS
		var taper: float = lerpf(1.0, 0.7, along)
		var bend: float = sag * sin(PI * along)
		var ring := PackedVector3Array()
		for k: int in TRUNK_SIDES:
			var ang: float = TAU * float(k) / TRUNK_SIDES
			var r: float = 0.5 * taper * side_r[k] * rng.randf_range(0.98, 1.02)
			ring.push_back(Vector3(-0.5 + along, LOG_AXIS_Y + bend + cos(ang) * r,
				sin(ang) * r))
		rings.push_back(ring)
	var axis := Vector3(0.0, LOG_AXIS_Y, 0.0)
	for s: int in TRUNK_SEGMENTS:
		for k: int in TRUNK_SIDES:
			var k1: int = (k + 1) % TRUNK_SIDES
			_quad(st, rings[s][k], rings[s + 1][k], rings[s + 1][k1], rings[s][k1],
				side_col[k] * rng.randf_range(0.95, 1.05), axis, BARK_SMOOTH_GROUP)
	_end_cap(st, rng, rings[0], axis)
	_end_cap(st, rng, rings[TRUNK_SEGMENTS], axis)
	# Up and to the sides only — the ones underneath broke off in the fall —
	# and short enough to stay within the unit box's allowance.
	for i: int in rng.randi_range(5, 8):
		var ang: float = rng.randf_range(-1.5, 1.5)
		var dir := Vector3(0.0, cos(ang), sin(ang))
		var x: float = rng.randf_range(-0.4, 0.4)
		var root := Vector3(x, LOG_AXIS_Y, 0.0) + dir * 0.35 * lerpf(1.0, 0.7, x + 0.5)
		_stub(st, root, dir, 0.12, 0.1, rng.randf_range(0.12, 0.22), TRUNK_STRETCH)

## A bark colour for each of [param sides] sides, between light and dark.
static func _bark_sides(rng: RandomNumberGenerator, sides: int) -> Array[Color]:
	var out: Array[Color] = []
	for k: int in sides:
		out.push_back(BARK.lerp(BARK_DARK, rng.randf()) * rng.randf_range(0.9, 1.08))
	return out

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
	# The bark shaded smooth and streaked up the stump, as on a log: flat, with a
	# shade per patch, its nine sides read as a patchwork of planks.
	var side_col: Array[Color] = _bark_sides(rng, STUMP_SIDES)
	for l: int in STUMP_LEVELS.size() - 1:
		var inside := Vector3(0.0, (STUMP_LEVELS[l] + STUMP_LEVELS[l + 1]) * 0.5, 0.0)
		for k: int in STUMP_SIDES:
			var k1: int = (k + 1) % STUMP_SIDES
			_quad(st, rings[l][k], rings[l + 1][k], rings[l + 1][k1], rings[l][k1], side_col[k],
				inside, BARK_SMOOTH_GROUP)
	_end_cap(st, rng, rings[STUMP_LEVELS.size() - 1], Vector3(0.0, 0.5, 0.0))

# ---------------------------------------------------------------- park

## How big Snow Park's furniture is, in metres. Each is built at this size and
## shrunk into the unit box ([method _to_unit]), so a marker scaled to it draws
## the thing true to size, and any other scale stretches it like every other
## prop. A cable is a unit length: its marker gives its span and thickness.
static func park_size(kind: Kind) -> Vector3:
	match kind:
		Kind.SNOWMAN:
			return Vector3(2.3, 2.3, 2.3)
		Kind.IGLOO:
			return Vector3(3.8, 1.9, 5.6)
		Kind.LIFT_TOWER:
			return Vector3(5.6, 10.0, 5.6)
		Kind.LIFT_CHAIR:
			return Vector3(2.0, 2.7, 2.0)
		Kind.LIFT_STATION:
			return Vector3(7.0, 5.0, 11.0)
	return Vector3.ONE

## Three balls of packed snow, a coal face and buttons, a carrot, stick arms, a
## scarf and a hat. Faces +Z.
static func _snowman(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var lean := Vector3(rng.randf_range(-0.03, 0.03), 0.0, rng.randf_range(-0.03, 0.03))
	var body: Array[Vector4] = [Vector4(0.0, 0.48, 0.0, 0.55), Vector4(0.0, 1.18, 0.0, 0.40),
		Vector4(0.0, 1.70, 0.0, 0.28)]
	for b: Vector4 in body:
		_ball(st, Vector3(b.x, b.y, b.z) + lean * b.y, b.w, 2,
			PACKED_SNOW * rng.randf_range(0.97, 1.0), BARK_SMOOTH_GROUP)
	var head: Vector3 = Vector3(0.0, 1.70, 0.0) + lean * 1.70
	var middle: Vector3 = Vector3(0.0, 1.18, 0.0) + lean * 1.18
	var tilt := Vector3(rng.randf_range(-0.08, 0.08), 1.0, rng.randf_range(-0.05, 0.05)).normalized()
	var brim: Vector3 = head + tilt * 0.22
	_tube(st, brim, brim + tilt * 0.035, 0.31, 0.31, 14, COAL, false, true)
	_tube(st, brim + tilt * 0.03, brim + tilt * 0.09, 0.195, 0.19, 14, SCARF, true, false)
	_tube(st, brim + tilt * 0.09, brim + tilt * 0.31, 0.19, 0.18, 14, COAL, true, true)
	_tube(st, head + Vector3(0.0, -0.01, 0.26), head + Vector3(0.0, -0.04, 0.53), 0.05, 0.006,
		8, CARROT, true, true)
	for side: float in [-1.0, 1.0]:
		_ball(st, head + Vector3(side * 0.095, 0.08, 0.25), 0.035, 0, COAL)
	for i: int in 5:
		var a: float = lerpf(-0.6, 0.6, i / 4.0)
		var at: Vector3 = Vector3(sin(a) * 0.15, -0.09 + absf(a) * 0.08, 0.0)
		at.z = sqrt(maxf(0.28 * 0.28 - at.x * at.x - at.y * at.y, 0.0)) - 0.01
		_ball(st, head + at, 0.022, 0, COAL)
	for y: float in [-0.13, 0.02, 0.17]:
		var z: float = sqrt(0.40 * 0.40 - y * y) - 0.01
		_ball(st, middle + Vector3(0.0, y, z), 0.04, 0, COAL)
	_tube(st, middle + Vector3(0.0, 0.25, 0.0), middle + Vector3(0.0, 0.35, 0.0), 0.33, 0.31,
		16, SCARF, true, true)
	_box(st, middle + Vector3(0.14, 0.12, 0.29), Vector3(0.12, 0.32, 0.05), SCARF)
	for side: float in [-1.0, 1.0]:
		var root: Vector3 = middle + Vector3(side * 0.36, 0.07, 0.0)
		var hand: Vector3 = root + Vector3(side * rng.randf_range(0.55, 0.65),
			rng.randf_range(0.2, 0.45), rng.randf_range(-0.05, 0.1))
		_tube(st, root, hand, 0.03, 0.015, 5, TWIG, false, true)
		var fork: Vector3 = root.lerp(hand, 0.75)
		_tube(st, fork, fork + Vector3(side * 0.08, 0.16, 0.0), 0.015, 0.008, 4, TWIG, false,
			true)

## A dome of snow blocks in courses, each course's blocks offset by half a
## block, and a low tunnel out to a dark doorway along +Z. Every course shares
## the same columns of vertices, so no seam opens between blocks.
static func _igloo(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	const R := 1.8
	const SQUASH := 0.95
	const COURSES := 7
	const COLUMNS := 36
	const SUNK := 0.08
	var centre := Vector3(0.0, -SUNK, 0.0)
	var point := func(lat: float, col: float) -> Vector3:
		var a: float = TAU * col / COLUMNS
		return centre + Vector3(cos(lat) * cos(a) * R, sin(lat) * R * SQUASH,
			cos(lat) * sin(a) * R)
	for k: int in COURSES:
		var lat0: float = PI * 0.5 * k / COURSES
		var lat1: float = PI * 0.5 * (k + 1) / COURSES
		# Two columns a block; odd courses start a column on.
		for j: int in COLUMNS / 2:
			var col: Color = ICE_BLOCK.lerp(PACKED_SNOW, rng.randf()) * rng.randf_range(0.95, 1.02)
			for half: int in 2:
				var c0: float = j * 2 + half + (k % 2)
				var a: Vector3 = point.call(lat0, c0)
				var b: Vector3 = point.call(lat0, c0 + 1.0)
				var c: Vector3 = point.call(lat1, c0 + 1.0)
				var d: Vector3 = point.call(lat1, c0)
				if k == COURSES - 1:
					_tri(st, a, b, c, col, centre)
				else:
					_quad(st, a, b, c, d, col, centre)
	# The tunnel: an arch of blocks from inside the dome out to the doorway.
	const ARCH := 0.75
	const DOOR := 0.5
	const SEGMENTS := 8
	var z0 := 1.2
	var z1 := 2.7
	var arch := func(r: float, s: float, z: float) -> Vector3:
		var a: float = PI * s / SEGMENTS
		return Vector3(cos(a) * r, sin(a) * r - SUNK, z)
	for ring: int in 3:
		var za: float = lerpf(z0, z1, ring / 3.0)
		var zb: float = lerpf(z0, z1, (ring + 1) / 3.0)
		for s: int in SEGMENTS:
			var col: Color = ICE_BLOCK.lerp(PACKED_SNOW, rng.randf()) * rng.randf_range(0.95, 1.02)
			_quad(st, arch.call(ARCH, s, za), arch.call(ARCH, s + 1, za),
				arch.call(ARCH, s + 1, zb), arch.call(ARCH, s, zb), col,
				Vector3(0.0, -SUNK, (za + zb) * 0.5))
	var behind := Vector3(0.0, 0.2, z1 - 0.5)
	for s: int in SEGMENTS:
		_quad(st, arch.call(DOOR, s, z1), arch.call(ARCH, s, z1), arch.call(ARCH, s + 1, z1),
			arch.call(DOOR, s + 1, z1), PACKED_SNOW, behind)
		_tri(st, Vector3(0.0, -SUNK, z1 - 0.02), arch.call(DOOR, s, z1 - 0.02),
			arch.call(DOOR, s + 1, z1 - 0.02), DOORWAY, behind)

## A chairlift tower: a concrete footing, a tapered steel column, a painted
## crossarm with a sheave train under either end, where the cable runs.
static func _lift_tower(st: SurfaceTool) -> void:
	_box(st, Vector3(0.0, -0.05, 0.0), Vector3(1.6, 0.5, 1.6), CONCRETE)
	_tube(st, Vector3(0.0, 0.2, 0.0), Vector3(0.0, 9.57, 0.0), 0.42, 0.3, 8, STEEL, true, true)
	_box(st, Vector3(0.0, 9.75, 0.0), Vector3(5.6, 0.36, 0.4), LIFT_PAINT)
	_tube(st, Vector3(0.0, 9.93, 0.0), Vector3(0.0, 10.0, 0.0), 0.08, 0.04, 6, MACHINE_DARK,
		false, true)
	for side: float in [-1.0, 1.0]:
		var x: float = side * LIFT_LINE_OFFSET
		_box(st, Vector3(x, 9.6, 0.0), Vector3(0.12, 0.3, 0.12), MACHINE_DARK)
		_box(st, Vector3(x, 9.4, 0.0), Vector3(0.22, 0.24, 1.6), MACHINE_DARK)
		# The sheaves, along the train's flanks.
		for k: int in 4:
			var z: float = lerpf(-0.6, 0.6, k / 3.0)
			_tube(st, Vector3(x - 0.14, 9.4, z), Vector3(x + 0.14, 9.4, z), 0.14, 0.14, 8,
				STEEL, false, true)
	# A ladder up the column's back.
	for side: float in [-1.0, 1.0]:
		_box(st, Vector3(side * 0.2, 4.9, -0.48), Vector3(0.04, 9.4, 0.04), MACHINE_DARK)
	var y: float = 0.6
	while y < 9.3:
		_box(st, Vector3(0.0, y, -0.48), Vector3(0.4, 0.03, 0.03), MACHINE_DARK)
		y += 0.4

## A three-seat chair, facing +Z: the grip on the cable at the top, the hanger
## down to the backrest, the seat, armrests, and the footrest on its struts.
static func _lift_chair(st: SurfaceTool) -> void:
	_box(st, Vector3(0.0, 2.6, 0.0), Vector3(0.2, 0.18, 0.35), MACHINE_DARK)
	_tube(st, Vector3(0.0, 2.55, 0.0), Vector3(0.0, 1.3, 0.0), 0.04, 0.04, 6, STEEL, true, true)
	_tube(st, Vector3(0.0, 1.3, 0.0), Vector3(0.0, 1.05, -0.32), 0.04, 0.04, 6, STEEL, true, true)
	_box(st, Vector3(0.0, 0.86, -0.32), Vector3(1.8, 0.42, 0.07), SEAT)
	_box(st, Vector3(0.0, 0.58, -0.05), Vector3(1.8, 0.1, 0.52), SEAT)
	_box(st, Vector3(0.0, 0.5, -0.05), Vector3(1.84, 0.06, 0.06), MACHINE_DARK)
	_box(st, Vector3(0.0, 1.08, -0.33), Vector3(1.84, 0.05, 0.05), MACHINE_DARK)
	for side: float in [-1.0, 1.0]:
		_box(st, Vector3(side * 0.93, 0.8, -0.18), Vector3(0.05, 0.5, 0.05), MACHINE_DARK)
		_box(st, Vector3(side * 0.93, 0.78, 0.0), Vector3(0.05, 0.05, 0.45), MACHINE_DARK)
		_tube(st, Vector3(side * 0.7, 0.55, 0.2), Vector3(side * 0.7, 0.12, 0.42), 0.025, 0.025,
			5, MACHINE_DARK, false, true)
	_box(st, Vector3(0.0, 0.1, 0.44), Vector3(1.5, 0.05, 0.12), MACHINE_DARK)

## A lift station: a plank hut under a red gable roof, its bullwheel on a
## steel column out in front of it, along +Z, where the cable comes in.
static func _lift_station(st: SurfaceTool) -> void:
	const W := 3.0
	const BACK := -4.0
	const FRONT := 1.0
	const EAVE := 3.0
	const RIDGE := 4.4
	_box(st, Vector3(0.0, (EAVE - 0.1) * 0.5, (BACK + FRONT) * 0.5),
		Vector3(W * 2.0, EAVE + 0.1, FRONT - BACK), PLANKS)
	_box(st, Vector3(0.0, 1.9, FRONT + 0.02), Vector3(4.0, 0.9, 0.06), WINDOW)
	for side: float in [-1.0, 1.0]:
		_box(st, Vector3(side * (W + 0.02), 1.9, -1.5), Vector3(0.06, 0.9, 3.4), WINDOW)
	# The gable ends, then the roof's two pitches, overhanging all round.
	var inside := Vector3(0.0, EAVE, (BACK + FRONT) * 0.5)
	for z: float in [BACK, FRONT]:
		_tri(st, Vector3(-W, EAVE, z), Vector3(W, EAVE, z), Vector3(0.0, RIDGE, z), PLANKS,
			inside)
	const OVER := 0.35
	for side: float in [-1.0, 1.0]:
		var eave := Vector3(side * (W + OVER), EAVE - OVER * (RIDGE - EAVE) / W, 0.0)
		var top := Vector3(0.0, RIDGE, 0.0)
		var z0 := Vector3(0.0, 0.0, BACK - OVER)
		var z1 := Vector3(0.0, 0.0, FRONT + OVER)
		_quad(st, eave + z0, top + z0, top + z1, eave + z1, ROOF, inside)
		# The underside, so the roof is not a sheet seen from below.
		var under := Vector3(0.0, -0.12, 0.0)
		_quad(st, eave + z0 + under, top + z0 + under, top + z1 + under, eave + z1 + under,
			PLANKS * 0.7, inside + Vector3(0.0, 4.0, 0.0))
	var wheel: Vector3 = STATION_WHEEL
	_tube(st, Vector3(0.0, -0.1, wheel.z), Vector3(0.0, wheel.y - 0.15, wheel.z), 0.32, 0.26, 8,
		STEEL, true, true)
	_box(st, Vector3(0.0, wheel.y - 0.3, (FRONT + wheel.z) * 0.5),
		Vector3(0.5, 0.35, wheel.z - FRONT + 0.6), LIFT_PAINT)
	_tube(st, wheel + Vector3(0.0, -0.13, 0.0), wheel + Vector3(0.0, 0.13, 0.0),
		LIFT_LINE_OFFSET + 0.05, LIFT_LINE_OFFSET + 0.05, 24, MACHINE_DARK, false, true)
	_tube(st, wheel + Vector3(0.0, 0.13, 0.0), wheel + Vector3(0.0, 0.25, 0.0), 0.5, 0.4, 10,
		LIFT_PAINT, false, true)

## Shrink a mesh built in metres at [param size] into the unit box: positions
## divided by it, normals multiplied by it (the inverse transpose of the
## shrink) and renormalised.
static func _to_unit(mesh: ArrayMesh, size: Vector3) -> ArrayMesh:
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i: int in verts.size():
		verts[i] = verts[i] / size
		normals[i] = (normals[i] * size).normalized()
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out

# ---------------------------------------------------------------- helpers

## A box [param size] across round [param centre], flat-shaded.
static func _box(st: SurfaceTool, centre: Vector3, size: Vector3, colour: Color) -> void:
	var h: Vector3 = size * 0.5
	var c := func(x: float, y: float, z: float) -> Vector3:
		return centre + Vector3(x * h.x, y * h.y, z * h.z)
	_quad(st, c.call(-1, -1, -1), c.call(1, -1, -1), c.call(1, 1, -1), c.call(-1, 1, -1), colour,
		centre)
	_quad(st, c.call(-1, -1, 1), c.call(1, -1, 1), c.call(1, 1, 1), c.call(-1, 1, 1), colour,
		centre)
	_quad(st, c.call(-1, -1, -1), c.call(-1, -1, 1), c.call(-1, 1, 1), c.call(-1, 1, -1), colour,
		centre)
	_quad(st, c.call(1, -1, -1), c.call(1, -1, 1), c.call(1, 1, 1), c.call(1, 1, -1), colour,
		centre)
	_quad(st, c.call(-1, -1, -1), c.call(1, -1, -1), c.call(1, -1, 1), c.call(-1, -1, 1), colour,
		centre)
	_quad(st, c.call(-1, 1, -1), c.call(1, 1, -1), c.call(1, 1, 1), c.call(-1, 1, 1), colour,
		centre)

## A tapered tube from [param a] (radius [param r0]) to [param b] ([param r1]),
## [param sides] round, shaded smooth round its girth or faceted, and capped
## at both ends if [param caps].
static func _tube(st: SurfaceTool, a: Vector3, b: Vector3, r0: float, r1: float, sides: int,
		colour: Color, smooth: bool, caps: bool) -> void:
	var axis: Vector3 = (b - a).normalized()
	var u: Vector3 = axis.cross(Vector3.UP)
	if u.length() < 0.1:
		u = axis.cross(Vector3.RIGHT)
	u = u.normalized()
	var v: Vector3 = axis.cross(u).normalized()
	var mid: Vector3 = (a + b) * 0.5
	var group: int = BARK_SMOOTH_GROUP if smooth else 0xFFFFFFFF
	for k: int in sides:
		var o0: Vector3 = u * cos(TAU * k / sides) + v * sin(TAU * k / sides)
		var o1: Vector3 = u * cos(TAU * (k + 1) / sides) + v * sin(TAU * (k + 1) / sides)
		_quad(st, a + o0 * r0, b + o0 * r1, b + o1 * r1, a + o1 * r0, colour, mid, group)
		if caps:
			_tri(st, a, a + o0 * r0, a + o1 * r0, colour, mid)
			_tri(st, b, b + o0 * r1, b + o1 * r1, colour, mid)

## A ball: an icosphere of [param radius] round [param centre].
static func _ball(st: SurfaceTool, centre: Vector3, radius: float, subdivisions: int,
		colour: Color, smooth_group: int = 0xFFFFFFFF) -> void:
	var sphere: Array = _icosphere(subdivisions)
	var verts: PackedVector3Array = sphere[0]
	var tris: PackedInt32Array = sphere[1]
	for f: int in range(0, tris.size(), 3):
		_tri(st, centre + verts[tris[f]] * radius, centre + verts[tris[f + 1]] * radius,
			centre + verts[tris[f + 2]] * radius, colour, centre, smooth_group)

## A broken branch: a tapered five-sided prism with a pale broken tip, built
## [param stretch] times narrower along X than it is to look once the mesh's
## X is stretched by that much.
static func _stub(st: SurfaceTool, root: Vector3, dir: Vector3, r0: float, r1: float,
		length: float, stretch: float) -> void:
	const SIDES := 5
	var side: Vector3 = dir.cross(Vector3.RIGHT)
	if side.length() < 0.1:
		side = dir.cross(Vector3.UP)
	side = side.normalized()
	var other: Vector3 = dir.cross(side).normalized()
	var tip: Vector3 = root + dir * length
	# Behind the root, so every face — the tip too — points away from it.
	var inside: Vector3 = root - dir * 0.2
	var squash := func(p: Vector3) -> Vector3:
		return Vector3(root.x + (p.x - root.x) / stretch, p.y, p.z)
	for k: int in SIDES:
		var o0: Vector3 = side * cos(TAU * k / SIDES) + other * sin(TAU * k / SIDES)
		var o1: Vector3 = side * cos(TAU * (k + 1) / SIDES) + other * sin(TAU * (k + 1) / SIDES)
		_quad(st, squash.call(root + o0 * r0), squash.call(tip + o0 * r1),
			squash.call(tip + o1 * r1), squash.call(root + o1 * r0), BARK, squash.call(inside))
		_tri(st, squash.call(tip), squash.call(tip + o0 * r1), squash.call(tip + o1 * r1),
			HEARTWOOD, squash.call(inside))

## One triangle, flat-shaded unless given a smooth group, wound clockwise as seen from outside (Godot's front
## face), where outside is away from [param inside] — so no caller has to get a
## winding right. [param colour] is sRGB and stored linear.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, colour: Color,
		inside: Vector3, smooth_group: int = 0xFFFFFFFF) -> void:
	_tri_shaded(st, a, b, c, colour, colour, colour, inside, smooth_group)

## [method _tri] with a colour at each corner ([param ca] at [param a], …).
static func _tri_shaded(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color,
		cb: Color, cc: Color, inside: Vector3, smooth_group: int = 0xFFFFFFFF) -> void:
	var centroid: Vector3 = (a + b + c) / 3.0
	# Counter-clockwise from the viewer puts (b-a)x(c-a) toward the viewer.
	if (b - a).cross(c - a).dot(centroid - inside) > 0.0:
		var swap: Vector3 = b
		b = c
		c = swap
		var swap_colour: Color = cb
		cb = cc
		cc = swap_colour
	# 0xFFFFFFFF (the default): this face's own normal, shared with no neighbour.
	st.set_smooth_group(smooth_group)
	for corner: Array in [[a, ca], [b, cb], [c, cc]]:
		var lin: Color = (corner[1] as Color).srgb_to_linear()
		lin.a = 1.0
		st.set_color(lin)
		st.add_vertex(corner[0])

static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		colour: Color, inside: Vector3, smooth_group: int = 0xFFFFFFFF) -> void:
	_tri(st, a, b, c, colour, inside, smooth_group)
	_tri(st, a, c, d, colour, inside, smooth_group)

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
