## The 3D leafless tree that stands in for ETR's `tree_barren2.png` cross, at
## three levels of detail, and the texture it is drawn with.
##
## DEVIATION: ETR draws the bare tree as two crossed quads of a 239×245
## picture. Up close that is a staircase of magnified texels, and from the side
## it is a flat card. [ConiferMesh] gets away with carrying its picture on fins
## because a fir is a solid cone; a bare tree is mostly air, and the picture on
## eight fins reads as a tangle. So this one is grown:
##
## - **wood** — the trunk and two orders of branches as tapered tubes, from a
##   fixed-seed recursive skeleton kept inside the crown the picture draws. Real
##   geometry, so it is sharp at any distance, and its normals are round, so the
##   sun and the snow land on the tops of the limbs the way they do in the
##   picture (about a third of its opaque texels are snow).
## - **twigs** — the skeleton's third, finest order is not a tube: each of
##   those branches *is* a card, laid along it from where it leaves its limb to
##   a little past its tip, showing one of four twig sprays drawn by
##   [method make_texture] — a crooked twig with its side shoots. The fine haze
##   a winter crown is made of is far below a pixel as geometry; as a mipmapped
##   cutout it thins out gracefully instead of crawling. (The finest order was
##   tubes once, with a spray on a stalk stood upright at every tip and middle:
##   twice the triangles, and a crown of little brooms.)
##
## The texture is drawn here, not taken from ETR, so nothing new has to pass the
## licence audit; its colours are measured off `tree_barren2.png` (opaque texels:
## wood (0.34, 0.32, 0.30), trunk (0.47, 0.45, 0.44), snow (0.84, 0.83, 0.81),
## sRGB). The left three quarters are the four sprays in a 2×2 grid, the right
## quarter a bark strip the tubes wrap.
##
## Unit-sized like the cross it replaces and like [ConiferMesh]: ±0.5 across,
## 0 to 1 up. The impostor maths, card and bounding sphere are [ConiferMesh]'s.
##
## Vertex colour is [ConiferMesh]'s convention — `r` = back face lights as its
## own side, `g` = height fraction for the wind — plus `b` = the tube's radius
## × [constant RADIUS_CODE_SCALE], which `conifer.gdshader` uses to keep a
## distant limb at least a pixel wide rather than letting it break into dashes.
## Cards carry `b` = 0 and are never widened.
class_name BareTreeMesh
extends RefCounted

const LODS := 3

const ALBEDO_ATLAS := "res://assets/trees/bare_albedo.png"
const NORMAL_ATLAS := "res://assets/trees/bare_normal.png"

## `COLOR.b` = radius × this. The trunk, the thickest tube, codes to ~0.35.
const RADIUS_CODE_SCALE := 10.0

## The crown the picture draws, as an ellipsoid: opaque from row 0 to ~192 of
## 245 (height 0.22 to 1.0) and nearly the full width between.
const CROWN_CENTER := Vector3(0.0, 0.6, 0.0)
const CROWN_RADII := Vector3(0.5, 0.4, 0.5)

const TEXTURE_SIZE := 512
## Where the bark strip starts, in u. The sprays fill everything left of it.
const BARK_U := 0.75

## Per level: which branch orders are tubes, the sides and segments of each
## order's tube, and how many crossed cards draw each twig. The finest order,
## [constant TWIG_ORDER], is never a tube; it is the twigs.
const _SHAPE: Array[Dictionary] = [
	{"max_order": 2, "sides": [7, 5, 4], "segments": [6, 4, 3], "cards": 2},
	{"max_order": 2, "sides": [5, 4, 3], "segments": [3, 3, 2], "cards": 1},
	{"max_order": 2, "sides": [4, 3, 3], "segments": [2, 1, 1], "cards": 1},
]
## The skeleton's finest order, drawn as twig cards rather than tubes.
const TWIG_ORDER := 3

const _SEED := 20260924

static var _cache: Array[ArrayMesh] = []
static var _skeleton: Array[Dictionary] = []
static var _texture: ImageTexture

## [method make_texture] with its mip chain, drawn once per process and
## shared. Drawn rather than shipped: it is 70 ms and nothing to go stale.
static func texture() -> ImageTexture:
	if _texture == null:
		var img: Image = make_texture()
		img.generate_mipmaps()
		_texture = ImageTexture.create_from_image(img)
	return _texture

## LOD [param level] (0 = nearest). Built once per process and shared.
static func mesh(level: int) -> ArrayMesh:
	if _cache.is_empty():
		for l: int in LODS:
			_cache.push_back(_build(_SHAPE[l]))
	return _cache[clampi(level, 0, LODS - 1)]

static func triangle_count(level: int) -> int:
	var m: ArrayMesh = mesh(level)
	return (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3

## How far outside the crown ellipsoid [param p] is: < 1 inside.
static func crown_extent(p: Vector3) -> float:
	var q: Vector3 = (p - CROWN_CENTER) / CROWN_RADII
	return q.length()

# ------------------------------------------------------------------
#                            skeleton
# ------------------------------------------------------------------
# Every level draws the same skeleton, so a hand-over changes how finely a limb
# is drawn and never where it is. Each branch is a Dictionary: `points`,
# `radii` (per point), `order` (0 = trunk), `arc` (distance from the root at
# each point, for the bark's v).

static func skeleton() -> Array[Dictionary]:
	if _skeleton.is_empty():
		_skeleton = _grow()
	return _skeleton

static func _grow() -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = _SEED
	var out: Array[Dictionary] = []
	# The trunk: the picture's is bare for its lowest fifth and forks a little
	# under half way up.
	var trunk: Dictionary = _branch(rng, Vector3.ZERO, Vector3.UP, 0.36, 0.034, 0.025, 0, 0.0, 0.03)
	out.push_back(trunk)
	var top: Vector3 = (trunk["points"] as PackedVector3Array)[-1]
	var trunk_end: float = (trunk["arc"] as PackedFloat32Array)[-1]
	# Four leaders out of the fork, spread round and leaning well out: the
	# picture's crown is a broad dome, not a vase.
	var spin: float = rng.randf() * TAU
	for i: int in 4:
		var a: float = spin + TAU * float(i) / 4.0 + rng.randf_range(-0.3, 0.3)
		var lean: float = rng.randf_range(0.45, 0.8)
		var d := Vector3(sin(a) * sin(lean), cos(lean), cos(a) * sin(lean))
		_grow_from(rng, out, top, d, rng.randf_range(0.55, 0.65), 0.02, 1, trunk_end)
	# And side limbs off the upper trunk, nearly level, filling the dome's
	# lower half.
	for i: int in 3:
		var h: float = lerpf(0.2, 0.32, (float(i) + rng.randf()) / 3.0)
		var p := Vector3(0.0, h, 0.0)
		var a: float = spin + PI / 4.0 + TAU * float(i) / 3.0 + rng.randf_range(-0.4, 0.4)
		var lean: float = rng.randf_range(1.0, 1.25)
		var d := Vector3(sin(a) * sin(lean), cos(lean), cos(a) * sin(lean))
		_grow_from(rng, out, p, d, rng.randf_range(0.48, 0.55), 0.015, 1, h)
	return out

## Grow a branch of [param order] from [param start], then its children.
static func _grow_from(rng: RandomNumberGenerator, out: Array[Dictionary], start: Vector3,
		dir: Vector3, length: float, radius: float, order: int, arc0: float) -> void:
	# Finer branches wander more: a twig is crooked, a limb much less so.
	var b: Dictionary = _branch(rng, start, dir, length, radius, radius * 0.3, order, arc0,
		[0.0, 0.1, 0.16, 0.22][order])
	out.push_back(b)
	if order >= TWIG_ORDER:
		return
	var pts: PackedVector3Array = b["points"]
	var radii: PackedFloat32Array = b["radii"]
	var arcs: PackedFloat32Array = b["arc"]
	var children: int = 4 if order < 2 else 3
	var roll: float = rng.randf() * TAU
	for c: int in children:
		# Along the outer two thirds, the last one near the tip as its
		# continuation — which is why a crown fans out rather than bristling.
		var t: float = lerpf(0.35, 0.95, (float(c) + rng.randf_range(0.2, 0.8)) / float(children))
		var f: float = t * float(pts.size() - 1)
		var i0: int = mini(floori(f), pts.size() - 2)
		var k: float = f - float(i0)
		var at: Vector3 = pts[i0].lerp(pts[i0 + 1], k)
		var along: Vector3 = (pts[i0 + 1] - pts[i0]).normalized()
		roll += 2.39996 + rng.randf_range(-0.4, 0.4)
		var side: Vector3 = _perpendicular(along).rotated(along, roll)
		var spread: float = rng.randf_range(0.5, 0.85)
		var d: Vector3 = (along * cos(spread) + side * sin(spread)).normalized()
		# A little upward pull, as a winter crown's shoots have — less the
		# finer they are, or every twig points at the sky and the crown's top
		# reads as a brush.
		d = (d + Vector3.UP * (0.25 if order == 1 else 0.08)).normalized()
		var r: float = lerpf(radii[i0], radii[i0 + 1], k) * 0.7
		var len: float = length * (rng.randf_range(0.6, 0.7) if order == 1 else rng.randf_range(0.5, 0.6))
		_grow_from(rng, out, at, d, len, r, order + 1, lerpf(arcs[i0], arcs[i0 + 1], k))

## One branch's centre line: [constant _STEPS] steps that wander a little, bend
## toward the light, and stop at the crown's edge.
const _STEPS := 6

static func _branch(rng: RandomNumberGenerator, start: Vector3, dir: Vector3, length: float,
		r0: float, r1: float, order: int, arc0: float, wander: float) -> Dictionary:
	var pts := PackedVector3Array([start])
	var arcs := PackedFloat32Array([arc0])
	var d: Vector3 = dir.normalized()
	var p: Vector3 = start
	var step: float = length / float(_STEPS)
	for s: int in _STEPS:
		var jitter := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		d = (d + jitter * wander + Vector3.UP * 0.04).normalized()
		var next: Vector3 = p + d * step
		# Keep a margin inside the crown for the twig cards.
		if order > 0 and crown_extent(next) > 0.86:
			if s == 0:
				next = p + d * step * 0.5
			else:
				break
		# And never past the collision radius, whatever the envelope says.
		var flat := Vector2(next.x, next.z)
		if flat.length() > 0.44:
			flat = flat.normalized() * 0.44
			next = Vector3(flat.x, next.y, flat.y)
		p = next
		pts.push_back(p)
		arcs.push_back(arcs[-1] + step)
	var radii := PackedFloat32Array()
	for i: int in pts.size():
		var k: float = float(i) / float(maxi(pts.size() - 1, 1))
		radii.push_back(lerpf(r0, r1, k))
	return {"points": pts, "radii": radii, "arc": arcs, "order": order}

static func _perpendicular(v: Vector3) -> Vector3:
	var ref: Vector3 = Vector3.UP if absf(v.y) < 0.9 else Vector3.RIGHT
	return v.cross(ref).normalized()

# ------------------------------------------------------------------
#                            building
# ------------------------------------------------------------------

static func _build(shape: Dictionary) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = _SEED + 1
	var max_order: int = shape["max_order"]
	var card_n: int = 0
	for b: Dictionary in skeleton():
		var order: int = b["order"]
		if order <= max_order:
			_add_tube(st, b, (shape["sides"] as Array)[order], (shape["segments"] as Array)[order])
		# Every level draws every twig, in the same place: the cards are where
		# the eye reads the crown's outline, and moving them between levels
		# would be what pops. Only how many cross each one changes.
		if order == TWIG_ORDER:
			_add_twig(st, b["points"], shape["cards"], card_n)
			card_n += 1
	st.index()
	st.generate_tangents()
	return st.commit()

static func _vert(st: SurfaceTool, p: Vector3, uv: Vector2, n: Vector3, radius: float) -> void:
	# Vertex colour is stored as 8 bits a channel, so a twig tip's code would
	# round to 0 and read as a card; one step up keeps it a tube.
	var code: float = maxf(radius * RADIUS_CODE_SCALE, 1.0 / 255.0) if radius > 0.0 else 0.0
	st.set_color(Color(0.0, clampf(p.y, 0.0, 1.0), code, 1.0))
	st.set_normal(n)
	st.set_uv(uv)
	st.add_vertex(p)

## A tapered tube along the branch's centre line, resampled to [param segments]
## lengths, wrapping the bark strip once round.
static func _add_tube(st: SurfaceTool, b: Dictionary, sides: int, segments: int) -> void:
	var pts: PackedVector3Array = b["points"]
	var radii: PackedFloat32Array = b["radii"]
	var arcs: PackedFloat32Array = b["arc"]
	if pts.size() < 2:
		return
	var rings: Array = []
	var frame: Vector3 = _perpendicular(pts[1] - pts[0])
	var count: int = mini(segments, pts.size() - 1)
	for s: int in count + 1:
		var f: float = float(s) / float(count) * float(pts.size() - 1)
		var i0: int = mini(floori(f), pts.size() - 2)
		var k: float = f - float(i0)
		var c: Vector3 = pts[i0].lerp(pts[i0 + 1], k)
		var r: float = lerpf(radii[i0], radii[i0 + 1], k)
		var along: Vector3 = (pts[i0 + 1] - pts[i0]).normalized()
		# Parallel transport: carry the last ring's frame onto this plane, so
		# the tube does not twist where the branch bends.
		frame = (frame - along * frame.dot(along)).normalized()
		var v: float = 0.02 + 0.96 * clampf(lerpf(arcs[i0], arcs[i0 + 1], k) / 1.4, 0.0, 1.0)
		var ring: Array = []
		for j: int in sides + 1:
			var a: float = TAU * float(j) / float(sides)
			var n: Vector3 = frame.rotated(along, a)
			var u: float = lerpf(BARK_U + 0.02, 0.98, float(j) / float(sides))
			ring.push_back([c + n * r, Vector2(u, v), n, r])
		rings.push_back(ring)
	for s: int in count:
		var a: Array = rings[s]
		var z: Array = rings[s + 1]
		for j: int in sides:
			var p00: Array = a[j]
			var p01: Array = a[j + 1]
			var p10: Array = z[j]
			var p11: Array = z[j + 1]
			for q: Array in [p00, p10, p11, p00, p11, p01]:
				_vert(st, q[0], q[1], q[2], q[3])

## A twig: [param cards] cards crossed along the finest-order branch through
## [param pts], from its root to a little past its tip, each showing one of the
## four sprays with the spray's root on the branch's. The first card faces out
## of the crown, so a tree seen from outside — as a racer sees every tree —
## shows its twigs broadside rather than edge-on.
static func _add_twig(st: SurfaceTool, pts: PackedVector3Array, cards: int, n: int) -> void:
	var at: Vector3 = pts[0]
	var axis: Vector3 = pts[-1] - pts[0]
	var up: Vector3 = axis.normalized()
	var variant: int = n % 4
	var u0: float = float(variant % 2) * BARK_U * 0.5
	var v0: float = float(variant / 2) * 0.5
	# The crown's outward normal, so the whole crown lights as one soft volume
	# like the conifer's fins — but held near level, or the top of the crown
	# faces up, takes the shader's snow on every twig and reads as white
	# foliage. The sprays carry their own snow. Built from the level part, since
	# over the crown's very top the outward direction has none to scale.
	var outward: Vector3 = ((pts[-1] - CROWN_CENTER) / CROWN_RADII).normalized()
	var level := Vector3(outward.x, 0.0, outward.z)
	if level.length() < 1e-3:
		level = Vector3(axis.x, 0.0, axis.z) if Vector2(axis.x, axis.z).length() > 1e-3 \
			else Vector3.BACK
	level = level.normalized()
	var normal: Vector3 = (level + Vector3.UP * outward.y * 0.25).normalized()
	var facing: Vector3 = level - up * level.dot(up)
	if facing.length() < 1e-3:
		facing = _perpendicular(up)
	var face_right: Vector3 = up.cross(facing.normalized()).normalized()
	for c: int in cards:
		var right: Vector3 = face_right.rotated(up, PI * float(c) / float(cards))
		# The spray is drawn a little longer than the twig it stands for.
		var h: float = axis.length() * 1.35
		var corners: Array[Vector3] = []
		# Shrink a card that would poke out of the unit box.
		for tries: int in 8:
			var w: float = h * 0.75
			var base: Vector3 = at - up * h * 0.02
			var p0: Vector3 = base - right * w * 0.5
			var p1: Vector3 = base + right * w * 0.5
			corners = [p0, p1, p1 + up * h, p0 + up * h]
			if corners.all(func(q: Vector3) -> bool:
					return Vector2(q.x, q.z).length() <= 0.5 and q.y >= 0.0 and q.y <= 1.0):
				break
			h *= 0.85
		var p0: Vector3 = corners[0]
		var p1: Vector3 = corners[1]
		var p2: Vector3 = corners[2]
		var p3: Vector3 = corners[3]
		# Half a texel in from the cell's edges so mips never bleed a neighbour.
		var e: float = 1.0 / float(TEXTURE_SIZE)
		var uv0 := Vector2(u0 + e, v0 + 0.5 - e)
		var uv1 := Vector2(u0 + BARK_U * 0.5 - e, v0 + 0.5 - e)
		var uv2 := Vector2(u0 + BARK_U * 0.5 - e, v0 + e)
		var uv3 := Vector2(u0 + e, v0 + e)
		for q: Array in [[p0, uv0], [p1, uv1], [p2, uv2], [p0, uv0], [p2, uv2], [p3, uv3]]:
			_vert(st, q[0], q[1], normal, 0.0)

# ------------------------------------------------------------------
#                            texture
# ------------------------------------------------------------------

const _WOOD := Color(0.34, 0.32, 0.295)
const _TRUNK := Color(0.47, 0.455, 0.44)
const _SNOW := Color(0.86, 0.855, 0.84)

## The tree's texture, drawn: four twig sprays and a bark strip. sRGB colour
## with straight alpha; a transparent texel carries the wood colour, so neither
## the mips nor the filter drag a twig's edge toward black.
static func make_texture() -> Image:
	var s: int = TEXTURE_SIZE
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGBAF)
	img.fill(Color(_WOOD.r, _WOOD.g, _WOOD.b, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = _SEED + 2
	var cell := Vector2i(roundi(s * BARK_U * 0.5), s / 2)
	for v: int in 4:
		var origin := Vector2i((v % 2) * cell.x, (v / 2) * cell.y)
		_draw_spray(img, rng, Rect2i(origin, cell))
	_draw_bark(img, rng, roundi(s * BARK_U))
	img.convert(Image.FORMAT_RGBA8)
	return img

## A spray: one crooked twig from the bottom middle of [param cell] nearly to
## its top, thinning as it goes, with side shoots off it alternately left and
## right — shorter toward the tip — and the odd shoot off those. Snow in dabs
## on the upper side where a twig runs near level. It stands for a whole
## finest-order branch, so it branches at once: no bare stalk under it.
static func _draw_spray(img: Image, rng: RandomNumberGenerator, cell: Rect2i) -> void:
	var root := Vector2(cell.position.x + cell.size.x * 0.5, cell.end.y - 2.0)
	var clip := Rect2(Vector2(cell.position) + Vector2(3, 3), Vector2(cell.size) - Vector2(6, 6))
	var length: float = cell.size.y * 0.9
	var main: PackedVector2Array = _draw_twig(img, rng, clip, root,
		Vector2(0, -1).rotated(rng.randf_range(-0.12, 0.12)), length, 3.0, 1.2, 7, 0.16, true)
	var shoots: int = rng.randi_range(8, 10)
	var sign: float = -1.0 if rng.randf() < 0.5 else 1.0
	for i: int in shoots:
		var t: float = lerpf(0.12, 0.88, (float(i) + rng.randf_range(0.2, 0.8)) / float(shoots))
		var f: float = t * float(main.size() - 1)
		var i0: int = mini(floori(f), main.size() - 2)
		var at: Vector2 = main[i0].lerp(main[i0 + 1], f - float(i0))
		var along: Vector2 = (main[i0 + 1] - main[i0]).normalized()
		var d: Vector2 = along.rotated(sign * rng.randf_range(0.45, 0.8))
		sign = -sign
		var shoot_len: float = length * rng.randf_range(0.3, 0.45) * (1.0 - 0.5 * t)
		var shoot: PackedVector2Array = _draw_twig(img, rng, clip, at, d, shoot_len,
			lerpf(2.2, 1.4, t), 1.0, 5, 0.22, t < 0.6)
		# And a shoot or two off that, to either side.
		var turn: float = 1.0 if rng.randf() < 0.5 else -1.0
		for j: int in rng.randi_range(1, 2):
			if shoot.size() < 3:
				break
			var k: int = mini(1 + j * 2, shoot.size() - 2)
			var sd: Vector2 = (shoot[k] - shoot[k - 1]).normalized().rotated(
				turn * rng.randf_range(0.4, 0.7))
			turn = -turn
			_draw_twig(img, rng, clip, shoot[k], sd, shoot_len * rng.randf_range(0.4, 0.55),
				1.2, 1.0, 3, 0.25, false)

## One tapered, crooked twig of [param steps] strokes from [param from] along
## [param dir], [param w0] to [param w1] px wide; returns the points it passed
## through. It ends where it would leave [param clip] — clamping it would draw
## it along the cell's edge.
static func _draw_twig(img: Image, rng: RandomNumberGenerator, clip: Rect2, from: Vector2,
		dir: Vector2, length: float, w0: float, w1: float, steps: int, crook: float,
		snowy: bool) -> PackedVector2Array:
	var pts := PackedVector2Array([from])
	var p: Vector2 = from
	var d: Vector2 = dir
	for i: int in steps:
		d = d.rotated(rng.randf_range(-crook, crook)).lerp(Vector2(0, -1), 0.05).normalized()
		var q: Vector2 = p + d * length / float(steps)
		if not clip.has_point(q):
			break
		var wa: float = lerpf(w0, w1, float(i) / steps)
		var wb: float = lerpf(w0, w1, float(i + 1) / steps)
		_stroke(img, p, q, wa, wb, _WOOD.lerp(_TRUNK, 0.3 + rng.randf() * 0.6))
		if snowy and absf(d.x) > 0.3 and rng.randf() < 0.6:
			var lift := Vector2(0, -1) * (wa * 0.5 + 0.5)
			_stroke(img, p.lerp(q, 0.25) + lift, p.lerp(q, 0.75) + lift, wa * 0.9, wb * 0.8, _SNOW)
		p = q
		pts.push_back(p)
	return pts

## An anti-aliased tapered line from [param a] to [param b], alpha by coverage.
static func _stroke(img: Image, a: Vector2, b: Vector2, wa: float, wb: float, color: Color) -> void:
	var r: float = maxf(wa, wb) * 0.5 + 1.0
	var lo := Vector2i(floori(minf(a.x, b.x) - r), floori(minf(a.y, b.y) - r))
	var hi := Vector2i(ceili(maxf(a.x, b.x) + r), ceili(maxf(a.y, b.y) + r))
	lo = lo.clamp(Vector2i.ZERO, img.get_size() - Vector2i.ONE)
	hi = hi.clamp(Vector2i.ZERO, img.get_size() - Vector2i.ONE)
	var ab: Vector2 = b - a
	var len2: float = maxf(ab.length_squared(), 1e-6)
	for y: int in range(lo.y, hi.y + 1):
		for x: int in range(lo.x, hi.x + 1):
			var p := Vector2(x + 0.5, y + 0.5)
			var t: float = clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var dist: float = p.distance_to(a + ab * t)
			var half: float = lerpf(wa, wb, t) * 0.5
			var cover: float = clampf(half - dist + 0.5, 0.0, 1.0)
			if cover <= 0.0:
				continue
			var old: Color = img.get_pixel(x, y)
			var rgb: Color = old.lerp(color, cover) if old.a > 0.0 else color
			img.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, maxf(old.a, cover)))

## The bark strip, from [param x0] to the right edge: the picture's wood and
## trunk greys in lengthwise streaks, with a few pale lichen flecks.
static func _draw_bark(img: Image, rng: RandomNumberGenerator, x0: int) -> void:
	var s: int = img.get_height()
	var w: int = img.get_width() - x0
	var noise := FastNoiseLite.new()
	noise.seed = _SEED
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.08
	for y: int in s:
		for x: int in w:
			# Stretched 8x along the branch, so the grain runs lengthwise; the
			# x term wraps, since the strip goes once round every tube.
			var a: float = TAU * float(x) / float(w)
			var n: float = noise.get_noise_3d(cos(a) * 6.0, sin(a) * 6.0, float(y) / 8.0)
			var fine: float = noise.get_noise_3d(cos(a) * 20.0, sin(a) * 20.0, float(y) * 0.6)
			var k: float = clampf(0.5 + n * 0.8 + fine * 0.25, 0.0, 1.0)
			var c: Color = _WOOD.darkened(0.1).lerp(_TRUNK, k)
			if fine > 0.55:
				c = c.lerp(Color(0.62, 0.63, 0.58), 0.5)
			img.set_pixel(x0 + x, y, Color(c.r, c.g, c.b, 1.0))
