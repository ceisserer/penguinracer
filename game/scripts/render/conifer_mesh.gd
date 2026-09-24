## The 3D conifer that stands in for ETR's `snowy_tree1.png` cross, at three
## levels of detail, plus the hemi-octahedral maths its impostor is baked and
## sampled with.
##
## DEVIATION: ETR draws every tree as two crossed quads (see
## `object_cross.gdshader`). This is a real volume built from the *same*
## texture, unchanged, so nothing new has to pass the licence audit:
##
## - **fins** — vertical half-planes radiating from the trunk, each carrying one
##   half of the picture (`u` 0.5 → 1 or 0.5 → 0). Together they are the
##   silhouette the texture already draws, from every azimuth rather than two.
## - **whorls** — tiers of drooping branch cards. Each samples a thin band of the
##   picture at its own height, trunk to tip, so seen from above it is a strip of
##   snowy needles ending in the picture's own ragged edge. They are what gives
##   the tree depth, and they are the upward-facing surfaces the shader snows on.
## - **trunk** — a thin tapered prism, LOD 0 only.
##
## Unit-sized like the cross it replaces: ±0.5 across, 0 to 1 up, so the course's
## per-instance `(diameter, height, diameter)` scale applies unchanged.
##
## Vertex colour carries two flags the shader needs and the geometry cannot say:
## `r` = 1 where the back face should light as its own side (a whorl card has a
## top and an underside; a fin's cone normal is right from either side), and
## `g` = the fraction of the tree's height, for the wind bend — kept separate
## from `VERTEX.y` so the impostor card, whose vertices are not on the tree, can
## bend by the same curve.
class_name ConiferMesh
extends RefCounted

## How many mesh levels there are. The impostor is the level after the last.
const LODS := 3

## Where the picture's foliage starts and stops, as a fraction of the height,
## and how wide it is at the bottom — measured off the alpha of
## `snowy_tree1.png` (256²: first opaque row 10, widest row ~220, where the
## branches span nearly the full width).
const CROWN_TOP := 0.96
const CROWN_BASE := 0.14
const CROWN_RADIUS := 0.5

## The bounding sphere the impostor is baked in and drawn on: the unit tree's
## box, centred half way up. A card of ±[constant IMPOSTOR_RADIUS] holds the
## whole tree from any direction.
const IMPOSTOR_CENTER := Vector3(0.0, 0.5, 0.0)
const IMPOSTOR_RADIUS := 0.7072

## Views per side of the hemi-octahedral atlas, and pixels per view. 8² = 64
## views, 128 px each: 1024² per atlas. A tree 75 m out — where the impostor
## takes over — is 50–90 px tall at 720p, so 128 is already over-sampled.
const ATLAS_GRID := 8
const ATLAS_TILE := 128

const ALBEDO_ATLAS := "res://assets/trees/conifer_albedo.png"
const NORMAL_ATLAS := "res://assets/trees/conifer_normal.png"

## Per-level shape: fins, whorl tiers, branches per tier, segments per branch,
## and whether it has a trunk. Each level roughly halves the one before.
const _SHAPE: Array[Dictionary] = [
	{"fins": 8, "tiers": 10, "branches": 9, "segments": 2, "trunk": true},
	{"fins": 6, "tiers": 6, "branches": 6, "segments": 1, "trunk": false},
	{"fins": 4, "tiers": 3, "branches": 5, "segments": 1, "trunk": false},
]

## The golden angle, so no two tiers' branches line up down the tree.
const _TIER_TWIST := 2.39996

static var _cache: Array[ArrayMesh] = []

## The radius of the crown at height fraction [param h]: a straight cone from
## [constant CROWN_BASE] to [constant CROWN_TOP], the texture's own profile.
static func crown_radius(h: float) -> float:
	var t: float = clampf((CROWN_TOP - h) / (CROWN_TOP - CROWN_BASE), 0.0, 1.0)
	return CROWN_RADIUS * t

## LOD [param level] (0 = nearest). Built once per process and shared.
static func mesh(level: int) -> ArrayMesh:
	if _cache.is_empty():
		for l: int in LODS:
			_cache.push_back(_build(_SHAPE[l]))
	return _cache[clampi(level, 0, LODS - 1)]

## Triangles in LOD [param level], for the tests and the budget notes.
static func triangle_count(level: int) -> int:
	var m: ArrayMesh = mesh(level)
	return (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3

## One camera-facing quad for the impostor level. Its vertices are placeholders
## — `conifer_impostor.gdshader` places the corners from `UV` — so its AABB is
## set to the bounding sphere's box, or the batch would cull on four points.
static func impostor_mesh() -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		IMPOSTOR_CENTER, IMPOSTOR_CENTER, IMPOSTOR_CENTER, IMPOSTOR_CENTER])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var r := Vector3.ONE * IMPOSTOR_RADIUS
	m.custom_aabb = AABB(IMPOSTOR_CENTER - r, r * 2.0)
	return m

# ------------------------------------------------------------------
#                     hemi-octahedral mapping
# ------------------------------------------------------------------
# The upper hemisphere of view directions folded onto a square: the pole is the
# centre, the horizon is the square's edge. Views are baked at the grid's
# *corners* (`i / (GRID - 1)`), so the horizon — where a racer sees almost every
# tree from — has frames exactly on it. `conifer_impostor.gdshader` carries the
# same two functions; `TestForest` holds them to each other.

## Unit direction with `y >= 0` → [0, 1]².
static func hemi_oct_encode(d: Vector3) -> Vector2:
	var n: Vector3 = d
	n.y = maxf(n.y, 0.0)
	var s: float = absf(n.x) + n.y + absf(n.z)
	var p := Vector2(n.x, n.z) / maxf(s, 1e-6)
	return Vector2(p.x + p.y, p.x - p.y) * 0.5 + Vector2(0.5, 0.5)

## [0, 1]² → unit direction with `y >= 0`.
static func hemi_oct_decode(uv: Vector2) -> Vector3:
	var e: Vector2 = uv * 2.0 - Vector2.ONE
	var p := Vector2(e.x + e.y, e.x - e.y) * 0.5
	return Vector3(p.x, 1.0 - absf(p.x) - absf(p.y), p.y).normalized()

## The direction view ([param i], [param j]) of the atlas was baked from.
static func frame_direction(i: int, j: int) -> Vector3:
	return hemi_oct_decode(Vector2(i, j) / float(ATLAS_GRID - 1))

## The card's right and up for a view along [param d] (pointing at the viewer),
## as a [Basis] whose z is [param d]. The baker turns each copy of the tree by
## this basis' inverse and the shader builds its card from the same three
## lines, so a frame and the card that shows it agree.
static func view_basis(d: Vector3) -> Basis:
	var ref: Vector3 = Vector3.UP if absf(d.y) < 0.999 else Vector3.FORWARD
	var x: Vector3 = ref.cross(d).normalized()
	var y: Vector3 = d.cross(x)
	return Basis(x, y, d)

# ------------------------------------------------------------------
#                            building
# ------------------------------------------------------------------

static func _build(shape: Dictionary) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fins: int = shape["fins"]
	for f: int in fins:
		_add_fin(st, TAU * (float(f) + 0.25) / float(fins), f % 2 == 1)
	var tiers: int = shape["tiers"]
	for t: int in tiers:
		# Tiers crowd toward the top, where the crown narrows, as a fir's do.
		var k: float = (float(t) + 0.5) / float(tiers)
		var h: float = lerpf(CROWN_BASE + 0.02, CROWN_TOP - 0.1, pow(k, 0.85))
		var branches: int = shape["branches"]
		for b: int in branches:
			var a: float = float(t) * _TIER_TWIST + TAU * float(b) / float(branches)
			_add_branch(st, a, h, crown_radius(h), branches, shape["segments"],
				(t + b) % 2 == 1)
	if shape["trunk"]:
		_add_trunk(st)
	st.index()
	st.generate_tangents()
	return st.commit()

## The normal a point on the crown's surface would have: out and up the cone.
static func _cone_normal(dir: Vector3) -> Vector3:
	var slope: float = CROWN_RADIUS / (CROWN_TOP - CROWN_BASE)
	return (dir + Vector3.UP * slope).normalized()

static func _vert(st: SurfaceTool, p: Vector3, uv: Vector2, n: Vector3, flips: float) -> void:
	st.set_color(Color(flips, clampf(p.y, 0.0, 1.0), 0.0, 1.0))
	st.set_normal(n)
	st.set_uv(uv)
	st.add_vertex(p)

## A vertical half-plane from the trunk out to the crown's radius, carrying one
## half of the picture. [param mirror] takes the left half instead, so
## neighbouring fins do not repeat.
static func _add_fin(st: SurfaceTool, angle: float, mirror: bool) -> void:
	var dir := Vector3(sin(angle), 0.0, cos(angle))
	var n: Vector3 = _cone_normal(dir)
	var side: float = -1.0 if mirror else 1.0
	var r: float = CROWN_RADIUS
	var p0 := Vector3.ZERO
	var p1: Vector3 = dir * r
	var p2: Vector3 = dir * r + Vector3.UP
	var p3 := Vector3.UP
	# Near the trunk the "outward" normal means nothing; lean it to plain up
	# there so the middle of the tree is not lit from one side.
	var n_in: Vector3 = (n + Vector3.UP).normalized()
	_vert(st, p0, Vector2(0.5, 1.0), n_in, 0.0)
	_vert(st, p1, Vector2(0.5 + side * 0.5, 1.0), n, 0.0)
	_vert(st, p2, Vector2(0.5 + side * 0.5, 0.0), n, 0.0)
	_vert(st, p0, Vector2(0.5, 1.0), n_in, 0.0)
	_vert(st, p2, Vector2(0.5 + side * 0.5, 0.0), n, 0.0)
	_vert(st, p3, Vector2(0.5, 0.0), n_in, 0.0)

## One branch: a card from the trunk to the crown's edge at height [param h],
## drooping toward its tip, narrow at the trunk and at the tip under half its
## share of the whorl — a branch is a spray, not a plank, and a wider card only
## stretches the thin band of picture it carries into a slab.
static func _add_branch(st: SurfaceTool, angle: float, h: float, reach: float,
		per_tier: int, segments: int, mirror: bool) -> void:
	var dir := Vector3(sin(angle), 0.0, cos(angle))
	var across: Vector3 = Vector3.UP.cross(dir)
	var tip_width: float = TAU * reach / float(per_tier) * 0.45
	# A band of the picture at this height, a little under a tier deep.
	var v0: float = clampf(1.0 - h - 0.05, 0.0, 1.0)
	var v1: float = clampf(1.0 - h + 0.04, 0.0, 1.0)
	var side: float = -1.0 if mirror else 1.0
	var droop: float = 0.45 * reach
	var rows: Array = []
	for s: int in segments + 1:
		var k: float = float(s) / float(segments)
		# A curve, not a line: the drop grows with the square of the reach.
		var centre: Vector3 = dir * reach * k + Vector3.UP * (h + 0.03 - droop * k * k)
		var half: float = lerpf(0.15, 1.0, k) * tip_width * 0.5
		# Slope of the branch here → a normal square to it, tipped out.
		var tangent: Vector3 = (dir * reach - Vector3.UP * 2.0 * droop * k).normalized()
		var n: Vector3 = tangent.cross(across).normalized()
		if n.y < 0.0:
			n = -n
		n = (n * 0.8 + dir * 0.2).normalized()
		var u: float = 0.5 + side * (reach * k)
		rows.push_back([centre - across * half, centre + across * half, u, n])
	for s: int in segments:
		var a: Array = rows[s]
		var b: Array = rows[s + 1]
		_vert(st, a[0], Vector2(a[2], v0), a[3], 1.0)
		_vert(st, b[0], Vector2(b[2], v0), b[3], 1.0)
		_vert(st, b[1], Vector2(b[2], v1), b[3], 1.0)
		_vert(st, a[0], Vector2(a[2], v0), a[3], 1.0)
		_vert(st, b[1], Vector2(b[2], v1), b[3], 1.0)
		_vert(st, a[1], Vector2(a[2], v1), a[3], 1.0)

## A five-sided prism up the middle, textured from the strip of bark the picture
## shows under its lowest branches.
static func _add_trunk(st: SurfaceTool) -> void:
	const SIDES := 5
	const TOP := 0.8
	for s: int in SIDES:
		var a0: float = TAU * float(s) / SIDES
		var a1: float = TAU * float(s + 1) / SIDES
		var d0 := Vector3(sin(a0), 0.0, cos(a0))
		var d1 := Vector3(sin(a1), 0.0, cos(a1))
		var b0: Vector3 = d0 * 0.035
		var b1: Vector3 = d1 * 0.035
		var t0: Vector3 = d0 * 0.008 + Vector3.UP * TOP
		var t1: Vector3 = d1 * 0.008 + Vector3.UP * TOP
		_vert(st, b0, Vector2(0.49, 0.99), d0, 0.0)
		_vert(st, b1, Vector2(0.51, 0.99), d1, 0.0)
		_vert(st, t1, Vector2(0.51, 0.93), d1, 0.0)
		_vert(st, b0, Vector2(0.49, 0.99), d0, 0.0)
		_vert(st, t1, Vector2(0.51, 0.93), d1, 0.0)
		_vert(st, t0, Vector2(0.49, 0.93), d0, 0.0)
