## The 3D bush that stands in for ETR's `shrub.png` cross, at three levels of
## detail. The impostor maths, card and bounding sphere are [ConiferMesh]'s.
##
## DEVIATION: ETR draws the shrub as two crossed quads. This is [ConiferMesh]'s
## treatment of the conifer applied to a bush, from the *same* texture,
## unchanged, so nothing new has to pass the licence audit:
##
## - **fins** — vertical half-planes radiating from the middle, each carrying
##   one half of the picture. Together they are the silhouette the texture
##   already draws, from every azimuth rather than two.
## - **sprigs** — cards bursting out of the root, trunkless, as a bush grows:
##   low at the bottom (never under ~20°), near upright at the top, spread round by the
##   golden angle. Each carries the strip of picture that lies along its own
##   ray, root to rim, so it ends in the picture's own ragged edge, and each
##   faces up and out — the dome's surface, which is what gives the bush depth
##   and what the shader snows on. Where a conifer's whorls hang in flat
##   tiers, these fan out over the whole crown: that is the difference between
##   a fir and a bush.
##
## Unit-sized like the cross it replaces: ±0.5 across, 0 to 1 up, so the course's
## per-instance `(diameter, height, diameter)` scale applies unchanged.
##
## Vertex colour is [ConiferMesh]'s convention: `r` = 1 where the back face
## lights as its own side (a sprig's underside), `g` = height fraction for the
## wind — plus `a`, which `conifer.gdshader` multiplies the picture's alpha by:
## a sprig fades to nothing at its root and part way at its sides, so the
## scissor cuts it along the picture's own gaps instead of along the card's
## straight edges. Everything else, and both other species, carry 1.
class_name ShrubMesh
extends RefCounted

const LODS := 3

const ALBEDO_ATLAS := "res://assets/trees/shrub_albedo.png"
const NORMAL_ATLAS := "res://assets/trees/shrub_normal.png"

## The picture's outline as `(height, radius)` pairs, bottom to top — measured
## off the alpha of `shrub.png` (256²: opaque from row ~30 to ~250, widest,
## nearly the full width, around row 205) and smoothed over the ragged sprig
## tips, which the texture draws for itself.
const PROFILE: PackedVector2Array = [
	Vector2(0.0, 0.1), Vector2(0.06, 0.3), Vector2(0.14, 0.46), Vector2(0.26, 0.46),
	Vector2(0.4, 0.4), Vector2(0.56, 0.37), Vector2(0.68, 0.32), Vector2(0.78, 0.22),
	Vector2(0.88, 0.08), Vector2(0.9, 0.0),
]

## Where the sprigs spring from: the root, a little above the ground.
const ROOT := Vector3(0.0, 0.05, 0.0)

## Per level: fins, the sprigs' elevations (degrees above level), how many
## sprigs the lowest tier has (higher tiers have fewer, as the dome narrows),
## and segments per sprig. None nearer level than ~20°: the fins already draw
## the skirt, and a chase camera looks along a flat sprig, which it sees as a
## streak.
const _SHAPE: Array[Dictionary] = [
	{"fins": 8, "tiers": [22.0, 34.0, 46.0, 58.0, 70.0, 82.0], "sprigs": 11, "segments": 2},
	{"fins": 6, "tiers": [24.0, 44.0, 63.0, 80.0], "sprigs": 8, "segments": 1},
	{"fins": 4, "tiers": [28.0, 58.0], "sprigs": 6, "segments": 1},
]

const _TIER_TWIST := 2.39996
const _SEED := 20260928

static var _cache: Array[ArrayMesh] = []

## The outline's radius at height fraction [param h]; 0 above the top.
static func profile_radius(h: float) -> float:
	if h <= PROFILE[0].x:
		return PROFILE[0].y
	for i: int in PROFILE.size() - 1:
		var a: Vector2 = PROFILE[i]
		var b: Vector2 = PROFILE[i + 1]
		if h <= b.x:
			return lerpf(a.y, b.y, (h - a.x) / (b.x - a.x))
	return 0.0

## How far from [constant ROOT] a ray at [param elevation] radians above level
## runs before it leaves the outline, in the picture's own plane.
static func reach(elevation: float) -> float:
	var d := Vector2(cos(elevation), sin(elevation))
	var t: float = 0.0
	while t < 1.2:
		var p: Vector2 = Vector2(0.0, ROOT.y) + d * (t + 0.01)
		if p.x > profile_radius(p.y):
			break
		t += 0.01
	return t

## LOD [param level] (0 = nearest). Built once per process and shared.
static func mesh(level: int) -> ArrayMesh:
	if _cache.is_empty():
		for l: int in LODS:
			_cache.push_back(_build(_SHAPE[l]))
	return _cache[clampi(level, 0, LODS - 1)]

static func triangle_count(level: int) -> int:
	var m: ArrayMesh = mesh(level)
	return (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3

# ------------------------------------------------------------------
#                            building
# ------------------------------------------------------------------

static func _build(shape: Dictionary) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fins: int = shape["fins"]
	for f: int in fins:
		_add_fin(st, TAU * (float(f) + 0.25) / float(fins), f % 2 == 1)
	var tiers: Array = shape["tiers"]
	# Every level draws from the same sequence, so a sprig's jitter is its own
	# and not its neighbour's when a level has fewer of them.
	var rng := RandomNumberGenerator.new()
	rng.seed = _SEED
	for t: int in tiers.size():
		var elevation: float = deg_to_rad(tiers[t])
		# As many round a tier as its circle has room for.
		var count: int = maxi(3, roundi(float(shape["sprigs"]) * cos(elevation) + 1.0))
		for s: int in count:
			# Tiers are how the sprigs are counted, not how they grow: each is
			# nudged off its tier and its slot, and a little short of the rim
			# or past it, or the bush reads as a rosette.
			var a: float = float(t) * _TIER_TWIST + TAU * (float(s) + rng.randf_range(-0.3, 0.3)) / float(count)
			var e: float = elevation + deg_to_rad(rng.randf_range(-6.0, 6.0))
			_add_sprig(st, a, clampf(e, 0.1, 1.5), count, shape["segments"],
				rng.randf_range(0.85, 1.05), (t + s) % 2 == 1)
	st.index()
	st.generate_tangents()
	return st.commit()

static func _vert(st: SurfaceTool, p: Vector3, uv: Vector2, n: Vector3, flips: float,
		cover: float = 1.0) -> void:
	st.set_color(Color(flips, clampf(p.y, 0.0, 1.0), 0.0, cover))
	st.set_normal(n)
	# A strip's corner can run off the picture at the rim, where it is clear
	# anyway; `repeat_disable` would smear the edge texel over it instead.
	st.set_uv(uv.clamp(Vector2.ZERO, Vector2.ONE))
	st.add_vertex(p)

## The normal a point on the dome would have at height [param h] on the side
## facing [param dir]: out at the widest, up at the top, and never down — the
## underside of a bush is in its own shade anyway, and a normal pointing at the
## snow would light it from below.
static func _dome_normal(dir: Vector3, h: float) -> Vector3:
	var up: float = lerpf(0.25, 1.6, clampf((h - 0.15) / 0.75, 0.0, 1.0))
	return (dir + Vector3.UP * up).normalized()

## A vertical half-plane from the middle out to the unit radius, carrying one
## half of the picture, in two rows so the dome's normal can turn up over it.
static func _add_fin(st: SurfaceTool, angle: float, mirror: bool) -> void:
	var dir := Vector3(sin(angle), 0.0, cos(angle))
	var side: float = -1.0 if mirror else 1.0
	var rows: Array = []
	for h: float in [0.0, 0.45, 1.0]:
		var n: Vector3 = _dome_normal(dir, h)
		# Near the middle "outward" means nothing; lean it to plain up there
		# so the heart of the bush is not lit from one side.
		var n_in: Vector3 = (n + Vector3.UP).normalized()
		rows.push_back([Vector3.UP * h, dir * 0.5 + Vector3.UP * h, n_in, n, 1.0 - h])
	for r: int in 2:
		var a: Array = rows[r]
		var b: Array = rows[r + 1]
		var uv_ai := Vector2(0.5, a[4])
		var uv_ao := Vector2(0.5 + side * 0.5, a[4])
		var uv_bi := Vector2(0.5, b[4])
		var uv_bo := Vector2(0.5 + side * 0.5, b[4])
		_vert(st, a[0], uv_ai, a[2], 0.0)
		_vert(st, a[1], uv_ao, a[3], 0.0)
		_vert(st, b[1], uv_bo, b[3], 0.0)
		_vert(st, a[0], uv_ai, a[2], 0.0)
		_vert(st, b[1], uv_bo, b[3], 0.0)
		_vert(st, b[0], uv_bi, b[2], 0.0)

## One sprig: a card from near the root out along [param elevation] to just
## past the outline, narrow at the root and at the rim under half its share of
## the tier — a sprig is a spray, not a plank. Its texture is the strip of the
## picture along the same ray, a sprig wide. Three vertices across each row,
## so the fade (`COLOR.a`) can run to the sides as well as to the root.
static func _add_sprig(st: SurfaceTool, angle: float, elevation: float, per_tier: int,
		segments: int, stretch: float, mirror: bool) -> void:
	var dir := Vector3(sin(angle), 0.0, cos(angle))
	var across: Vector3 = Vector3.UP.cross(dir)
	var ray := Vector2(cos(elevation), sin(elevation))
	# To the outline and a little past it: the rim of the strip is the picture's
	# own ragged edge, and alpha cuts it there.
	var length: float = (reach(elevation) + 0.05) * stretch
	# ... but never out of the unit box, whose side is the collision radius.
	var along: Vector2 = Vector2(0.0, ROOT.y) + ray * length
	if along.x > 0.49:
		length *= 0.49 / along.x
	if along.y > 0.99:
		length *= 0.99 / along.y
	var tip_width: float = TAU * length * ray.x / float(per_tier) * 0.6 + 0.08
	# Its tip corners too: a wide tip at the rim pokes out sideways.
	for tries: int in 12:
		var tip_x: float = ray.x * length
		if Vector2(tip_x, tip_width * 0.5).length() <= 0.49:
			break
		length *= 0.95
		tip_width *= 0.95
	var side: float = -1.0 if mirror else 1.0
	# The strip is square to the ray in the picture and as wide as the card,
	# so the picture lands on it at its own scale rather than smeared across.
	# Not a level strip, as the conifer's whorls take: that ends in the rim
	# only where the sprig does, and across the dense middle of the picture
	# its straight sides draw every card as a trapezoid.
	var band := Vector2(-ray.y * side, -ray.x)
	# A sprig bows under its own tip, more the nearer level it grows.
	var droop: float = 0.08 * length * ray.x
	var rows: Array = []
	for s: int in segments + 1:
		var f: float = float(s) / float(segments)
		# From a third of the way out: the heart of the bush is the fins', and
		# every sprig reaching into it is a star drawn round the root.
		var k: float = lerpf(0.3, 1.0, f)
		var flat: Vector2 = Vector2(0.0, ROOT.y) + ray * length * k
		var centre: Vector3 = dir * flat.x + Vector3.UP * (flat.y - droop * k * k)
		var half: float = lerpf(0.4, 1.0, k) * tip_width * 0.5
		var tangent: Vector3 = (dir * ray.x + Vector3.UP * (ray.y - 2.0 * droop * k)).normalized()
		var n: Vector3 = tangent.cross(across).normalized()
		if n.y < 0.0:
			n = -n
		# Tipped toward the dome's own normal, so the sprigs light as one
		# rounded volume rather than as a heap of separate cards.
		n = (n + _dome_normal(dir, centre.y) * 1.5).normalized()
		var uv := Vector2(0.5 + side * flat.x, 1.0 - flat.y)
		# Clear at the root, whole from half way out; the sides at a third.
		var cover: float = minf(f * 2.0, 1.0) if segments > 1 else f
		rows.push_back({"c": centre, "x": across * half, "uv": uv, "b": band * half,
			"n": n, "mid": cover, "edge": cover * 0.35})
	for s: int in segments:
		var a: Dictionary = rows[s]
		var b: Dictionary = rows[s + 1]
		# Two quads, edge to middle to edge.
		for w: float in [-1.0, 1.0]:
			var a_edge: Vector3 = a["c"] + a["x"] * w
			var b_edge: Vector3 = b["c"] + b["x"] * w
			var a_uv: Vector2 = a["uv"] + a["b"] * w
			var b_uv: Vector2 = b["uv"] + b["b"] * w
			_vert(st, a["c"], a["uv"], a["n"], 1.0, a["mid"])
			_vert(st, b["c"], b["uv"], b["n"], 1.0, b["mid"])
			_vert(st, b_edge, b_uv, b["n"], 1.0, b["edge"])
			_vert(st, a["c"], a["uv"], a["n"], 1.0, a["mid"])
			_vert(st, b_edge, b_uv, b["n"], 1.0, b["edge"])
			_vert(st, a_edge, a_uv, a["n"], 1.0, a["edge"])
