## The 3D leafless tree that stands in for ETR's `tree_barren2.png` cross, at
## three levels of detail, and the texture it is drawn with.
##
## DEVIATION: ETR draws the bare tree as two crossed quads of a 239×245
## picture. Up close that is a staircase of magnified texels, and from the side
## it is a flat card. [ConiferMesh] gets away with carrying its picture on fins
## because a fir is a solid cone; a bare tree is mostly air, and the picture on
## eight fins reads as a tangle. So this one is grown:
##
## - **wood** — the trunk and three orders of branches as tapered tubes, from a
##   fixed-seed recursive skeleton kept inside the crown the picture draws. Real
##   geometry, so it is sharp at any distance, and its normals are round, so the
##   sun and the snow land on the tops of the limbs the way they do in the
##   picture (about a third of its opaque texels are snow).
## - **twigs** — cards at the ends and middles of the finest branches, each
##   showing one of four twig sprays drawn by [method make_texture]. The fine
##   haze a winter crown is made of is far below a pixel as geometry; as a
##   mipmapped cutout it thins out gracefully instead of crawling.
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
## order's tube, and how many twig cards stand at each twig placement.
const _SHAPE: Array[Dictionary] = [
	{"max_order": 3, "sides": [7, 5, 4, 3], "segments": [6, 4, 3, 2], "cards": 2, "mid_cards": true},
	{"max_order": 3, "sides": [5, 4, 3, 3], "segments": [3, 3, 2, 1], "cards": 1, "mid_cards": true},
	{"max_order": 2, "sides": [4, 3, 3, 3], "segments": [2, 2, 1, 1], "cards": 1, "mid_cards": false},
]

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
	var b: Dictionary = _branch(rng, start, dir, length, radius, radius * 0.3, order, arc0, 0.12)
	out.push_back(b)
	if order >= 3:
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
		# A little upward pull, as a winter crown's shoots have.
		d = (d + Vector3.UP * 0.25).normalized()
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
		# Twigs on the finest order only, whichever level is drawing: the cards
		# are where the eye reads the crown's outline, and moving them between
		# levels would be what pops.
		if order == 3:
			var pts: PackedVector3Array = b["points"]
			var at_tip: Vector3 = pts[-1]
			var dir_tip: Vector3 = (pts[-1] - pts[maxi(pts.size() - 3, 0)]).normalized()
			_add_twigs(st, at_tip, dir_tip, 0.2, shape["cards"], card_n)
			card_n += 1
			if shape["mid_cards"] and pts.size() > 3:
				var m: int = pts.size() / 2
				var dir_mid: Vector3 = (pts[m] - pts[m - 1]).normalized()
				_add_twigs(st, pts[m], dir_mid, 0.15, shape["cards"], card_n)
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

## Twig cards at [param at], growing along [param dir]: [param cards] of them,
## crossed about that line. Each shows one of the four sprays.
static func _add_twigs(st: SurfaceTool, at: Vector3, dir: Vector3, size: float, cards: int,
		n: int) -> void:
	# Sprays point up and out more than the twig they sit on, as shoots do.
	var up: Vector3 = (dir + Vector3.UP * 0.6).normalized()
	var roll: float = float(n) * 2.39996
	var variant: int = n % 4
	var u0: float = float(variant % 2) * BARK_U * 0.5
	var v0: float = float(variant / 2) * 0.5
	# The crown's outward normal, so the whole crown lights as one soft volume
	# like the conifer's fins — flattened toward level, or the top of the crown
	# faces up, takes the shader's snow on every twig and reads as white
	# foliage. The sprays carry their own snow.
	var outward: Vector3 = ((at - CROWN_CENTER) / CROWN_RADII).normalized()
	var normal: Vector3 = Vector3(outward.x, outward.y * 0.35, outward.z).normalized()
	for c: int in cards:
		var right: Vector3 = _perpendicular(up).rotated(up, roll + PI * float(c) / float(cards))
		var h: float = size
		var corners: Array[Vector3] = []
		# Shrink a card that would poke out of the unit box.
		for tries: int in 8:
			var w: float = h * 0.75
			var base: Vector3 = at - up * h * 0.08
			var p0: Vector3 = base - right * w * 0.5
			var p1: Vector3 = base + right * w * 0.5
			corners = [p0, p1, p1 + up * h, p0 + up * h]
			if corners.all(func(q: Vector3) -> bool:
					return Vector2(q.x, q.z).length() <= 0.5 and q.y >= 0.0 and q.y <= 1.0):
				break
			h *= 0.8
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

## A spray: one twig from the bottom middle of [param cell], forking three or
## four times, each fork thinner and shorter, with snow caught on the upper
## side of the thicker ones.
static func _draw_spray(img: Image, rng: RandomNumberGenerator, cell: Rect2i) -> void:
	var root := Vector2(cell.position.x + cell.size.x * 0.5, cell.end.y - 2.0)
	var stack: Array = [[root, Vector2(0, -1).rotated(rng.randf_range(-0.15, 0.15)),
		cell.size.y * 0.38, 3.6, 0]]
	var clip := Rect2(Vector2(cell.position) + Vector2(3, 3), Vector2(cell.size) - Vector2(6, 6))
	while not stack.is_empty():
		var t: Array = stack.pop_back()
		var p: Vector2 = t[0]
		var d: Vector2 = t[1]
		var length: float = t[2]
		var width: float = t[3]
		var depth: int = t[4]
		var steps: int = 5
		var start: Vector2 = p
		for i: int in steps:
			d = d.rotated(rng.randf_range(-0.22, 0.22)).lerp(Vector2(0, -1), 0.06).normalized()
			var q: Vector2 = p + d * length / float(steps)
			# A twig that would leave its cell ends there; clamping it would
			# draw it along the cell's edge.
			if not clip.has_point(q):
				break
			var w0: float = lerpf(width, width * 0.65, float(i) / steps)
			var w1: float = lerpf(width, width * 0.65, float(i + 1) / steps)
			var tone: Color = _WOOD.lerp(_TRUNK, 0.3 + rng.randf() * 0.6)
			_stroke(img, p, q, w0, w1, tone)
			# Snow on top of the thicker twigs, in dabs rather than a line.
			if width > 1.3 and absf(d.x) > 0.15 and rng.randf() < 0.85:
				var up := Vector2(0, -1) * (w0 * 0.5 + 0.6)
				_stroke(img, p.lerp(q, 0.2) + up, p.lerp(q, 0.8) + up, w0 * 0.9, w1 * 0.8, _SNOW)
			p = q
		if depth >= 4:
			continue
		var forks: int = 2 if depth < 3 else rng.randi_range(1, 2)
		for f: int in forks:
			var k: float = rng.randf_range(0.45, 1.0)
			var at: Vector2 = start.lerp(p, k)
			var sign: float = -1.0 if (f + depth) % 2 == 0 else 1.0
			var nd: Vector2 = d.rotated(sign * rng.randf_range(0.35, 0.75))
			stack.push_back([at, nd, length * rng.randf_range(0.55, 0.7),
				maxf(width * 0.65, 1.1), depth + 1])
		# And the leader carries on, a little thinner.
		stack.push_back([p, d, length * 0.55, maxf(width * 0.72, 1.1), depth + 1])

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
