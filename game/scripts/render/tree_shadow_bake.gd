## The trees' shadows on the snow, baked once per sun into the terrain's vertex
## colour, for wherever the sun casts no shadow map.
##
## DEVIATION, like the shadow map it stands in for: ETR draws no tree shadow at
## all. Under Compatibility the sun cannot cast one without wrecking the frame
## ([RenderBackend]), so there this is the only tree shadow there is; under
## Mobile it is the player's choice (`[quality] tree_shadow_kind = "baked"`),
## and takes the trees out of the shadow map, which is most of its cost.
##
## One byte per heightmap vertex, 255 where the sun reaches the snow, in the
## grid's row-major order — [TerrainRenderer] puts a vertex on every texel of
## the grid and reads these straight into `COLOR.b`, beside the relief
## occlusion and the torchlight ([method CourseLights.bake_terrain]).
## `terrain.gdshader` multiplies the sun term by it, exactly where the shadow
## map's `ATTENUATION` goes, so a baked shadow is lit by the ambient alone and
## turns snow the same blue a real one does.
##
## [b]How.[/b] Each tree is a solid of revolution — its species' own crown
## profile, the one its mesh is built on — with a density. A vertex's shadow is
## what a ray from it toward the sun loses on its way through the crowns it
## crosses: `1 - max_opacity · (1 - exp(-density · path))`, so two crowns in
## line compound. The ray is marched against one tree at a time, in the tree's
## own frame, over a plane at the course's slope, which makes the answer a
## function of the tree's size alone — and the ground actually under the
## shadow, which is not that plane on a bank, goes into the size as well
## ([method _stretch]). So it is worked out once per [constant SIZE_RATIO] of
## diameter and height as a small stamp, and every tree of that size is one
## [method Image.blend_rect] of it into the course's map: blending black at the
## shadow's opacity multiplies what is already there by `1 - opacity`, which is
## exactly the compounding. A tree is moved to its nearest vertex, which is
## under a vertex's spacing, and the terrain interpolates between vertices
## anyway. Measured top down against the shadow map on Bunny Hill: the same
## place, the same length, a little softer.
##
## [b]What it cannot do.[/b] The grid is 0.25–1 m, so a shadow is as soft as
## that ([method _soften]), and anything thinner — a flag's pole, a bare tree's
## trunk and limbs — falls between vertices and is left out; a bare crown casts
## a faint wash instead. Nothing sways: the wind moves the trees and not their
## shadows. Trees do not shade each other, and the racers are not shaded by
## the trees.
##
## [b]Cost.[/b] ~50–150 ms on the desktop for the biggest courses (`bronze_set`,
## 8153 trees), 121 ms (Bunny Hill) and 237 ms (`bronze_set`) in headless
## Chromium — once per course and sun, at load. Nothing a frame.
##
## Plain [RefCounted] with no autoload names, so the tests can call it statically.
class_name TreeShadowBake
extends RefCounted

## Trees within this ratio of each other in both diameter and height share a
## stamp: 6 % either way, under half a metre on the tallest. The stamps are
## what the bake's time goes on, and with the slope folded into the height
## ([method _stretch]) a fixed 0.5 m step made ~260 of them on Bunny Hill.
const SIZE_RATIO := 1.12
## Ray samples per vertex through a tree's bounding cylinder.
const SAMPLES := 6
## A sun lower than this (the sine of its elevation over the slope) throws
## shadows longer than any stamp should be; nothing is baked.
const MIN_SUN_HEIGHT := 0.15
## Crown profile resolution: radius at this many evenly spaced heights.
const PROFILE_STEPS := 64
## The steepest ground a tree's shadow is measured on, rise per metre.
const MAX_GRADIENT := 1.5
## How far the ground under a shadow may stretch it — see [method _stretch].
const MAX_STRETCH := 3.0

## Per [enum Forest.Species]: how dense the crown is, per metre of path, and the
## most light it can take out of the sun. Matched by eye to the shadow map, top
## down on Bunny Hill. A conifer's fins are cutouts of an opaque picture, so a
## ray through even the thin tip of the crown is stopped — at a density of 1.4
## the tip of every shadow went pale; a shrub nearly as much; a bare crown is
## mostly air, and its limbs' shadows are too thin for the grid, so it casts a
## faint wash where the shadow map draws a dapple.
const DENSITY: PackedFloat32Array = [5.0, 0.3, 4.0]
const MAX_OPACITY: PackedFloat32Array = [0.95, 0.45, 0.9]

static var _profiles: Array[PackedFloat32Array] = []

## Bake [param trees] — world transforms scaled to (diameter, height, diameter),
## as [CourseRoot] draws them — each of the [enum Forest.Species] in step in
## [param species], onto [param surface]'s grid for a sun in direction
## [param sun] (toward the sun). Empty when there is nothing to bake, which the
## terrain reads as sunlit everywhere.
static func bake(trees: Array[Transform3D], species: PackedInt32Array,
		surface: HeightmapSurface, sun: Vector3) -> PackedByteArray:
	if trees.is_empty() or surface == null or surface.size.x < 2 or surface.size.y < 2:
		return PackedByteArray()
	var light: Vector3 = sun.normalized()
	var slope: float = surface.slope
	# How fast a ray toward the sun climbs away from the sloping ground.
	if light.y - slope * light.z < MIN_SUN_HEIGHT:
		return PackedByteArray()
	var w: int = surface.size.x
	var h: int = surface.size.y
	var pitch := Vector2(surface.world_size.x / float(w - 1),
		surface.world_size.y / float(h - 1))

	# Half floats while blending, so a vertex under many crown edges does not
	# lose a level to rounding at every one; one byte a vertex at the end.
	var map: Image = Image.create_empty(w, h, false, Image.FORMAT_RGBAH)
	map.fill(Color.WHITE)
	var stamps: Dictionary[Vector3i, Array] = {}
	for k: int in trees.size():
		var xf: Transform3D = trees[k]
		var kind: int = species[k] if k < species.size() else Forest.Species.CONIFER
		var height: float = xf.basis.y.length()
		var stretch: float = _stretch(surface, xf.origin, light, height)
		if stretch <= 0.0:
			continue
		var key := Vector3i(kind, _size_class(xf.basis.x.length()),
			_size_class(height * stretch))
		var stamp: Array = stamps.get(key, [])
		if stamp.is_empty():
			stamp = _stamp(kind, pow(SIZE_RATIO, key.y), pow(SIZE_RATIO, key.z),
				light, Vector2(0.0, slope), pitch)
			stamps[key] = stamp
		var img: Image = stamp[0]
		if img == null:
			continue
		var at := Vector2i(roundi(xf.origin.x / pitch.x), roundi(-xf.origin.z / pitch.y))
		map.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), at + (stamp[1] as Vector2i))
	map.convert(Image.FORMAT_L8)
	return map.get_data()

## [param metres] to the nearest power of [constant SIZE_RATIO], as its exponent.
static func _size_class(metres: float) -> int:
	return roundi(log(maxf(metres, 0.1)) / log(SIZE_RATIO))

## [param surface]'s height at the vertex nearest world ([param x], [param z]).
## Nearest rather than interpolated: three of these a tree, for a plane fitted
## across metres.
static func _ground(surface: HeightmapSurface, x: float, z: float) -> float:
	var i: int = clampi(roundi(x / surface.world_size.x * float(surface.size.x - 1)),
		0, surface.size.x - 1)
	var j: int = clampi(roundi(-z / surface.world_size.y * float(surface.size.y - 1)),
		0, surface.size.y - 1)
	return surface.heights[j * surface.size.x + i] + surface.slope * z

## How much taller than it is a tree standing at [param foot] has to be to
## throw its shadow on the course's plane as far as it throws it on the ground
## actually there — or 0 for ground turned so far from the sun that it is in
## its own shade.
##
## The course's plane is not enough. A tree on a bank throws its shadow down
## the bank, and ground falling away from the sun lengthens it: on Bunny Hill's
## banks the shadow map drew them 2–3 m longer than a bake on the course's
## plane, every tip short. But stamps for every slope were ~3000 of them and
## 0.8 s on `bronze_set`. So the slope goes into the height instead: a ray from
## a point `y` up the axis lands `y / climb` along the sun, where `climb` is how
## fast the ray leaves the ground, so on ground that makes it leave slower the
## tree throws the shadow of one `climb_course / climb_here` times as tall on
## the course's plane — and that is a stamp there already is.
##
## The ground is a plane fitted through three heights: the foot, where the top
## of the crown would land on the course's plane, and as far to the side.
static func _stretch(surface: HeightmapSurface, foot: Vector3, light: Vector3,
		height: float) -> float:
	var flat: float = light.y - surface.slope * light.z
	var sun := Vector2(light.x, light.z)
	if sun.length() < 1e-3:
		return 1.0
	var along: Vector2 = -sun.normalized() * maxf(2.0, height * sun.length() / flat)
	var side := Vector2(-along.y, along.x)
	var h0: float = _ground(surface, foot.x, foot.z)
	var h1: float = _ground(surface, foot.x + along.x, foot.z + along.y) - h0
	var h2: float = _ground(surface, foot.x + side.x, foot.z + side.y) - h0
	# [along; side] · (dy/dx, dy/dz) = (h1, h2)
	var det: float = along.x * side.y - along.y * side.x
	var g := Vector2((h1 * side.y - h2 * along.y) / det, (along.x * h2 - side.x * h1) / det)
	g = g.clampf(-MAX_GRADIENT, MAX_GRADIENT)
	var here: float = light.y - g.x * light.x - g.y * light.z
	if here < MIN_SUN_HEIGHT:
		return 0.0
	return clampf(flat / here, 1.0 / MAX_STRETCH, MAX_STRETCH)

## The shadow of one tree of [param kind], [param diameter] × [param height]
## metres, standing on a vertex of ground rising [param ground] per metre
## along X and Z: `[image, offset]`, the image black with the shadow's opacity
## in alpha and the offset in vertices from the tree's to the image's corner.
## `[null, …]` for a tree that shades no vertex.
static func _stamp(kind: int, diameter: float, height: float, light: Vector3,
		ground: Vector2, pitch: Vector2) -> Array:
	var profile: PackedFloat32Array = _profile(kind)
	var reach: float = 0.0
	for r: float in profile:
		reach = maxf(reach, r)
	reach *= diameter
	var density: float = DENSITY[kind]
	var max_opacity: float = MAX_OPACITY[kind]
	# How fast a ray toward the sun climbs away from the ground. A slope facing
	# away from the sun that steeply is in its own shade.
	var climb: float = light.y - ground.x * light.x - ground.y * light.z
	if climb < MIN_SUN_HEIGHT:
		return [null, Vector2i.ZERO]

	# The footprint: the bounding cylinder's rim, top and bottom, carried down
	# the sun's ray to the ground plane through the tree's foot.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for ring: int in 2:
		var y: float = height * float(ring)
		for a: int in 16:
			var q := Vector3(cos(a * TAU / 16.0) * reach, y, sin(a * TAU / 16.0) * reach)
			var t: float = (q.y - ground.x * q.x - ground.y * q.z) / climb
			var g := Vector2(q.x - t * light.x, q.z - t * light.z)
			lo = lo.min(g)
			hi = hi.max(g)
	# Grid x runs along +X, grid y along -Z.
	var i0: int = floori(lo.x / pitch.x) - 1
	var i1: int = ceili(hi.x / pitch.x) + 1
	var j0: int = floori(-hi.y / pitch.y) - 1
	var j1: int = ceili(-lo.y / pitch.y) + 1
	var sw: int = i1 - i0 + 1
	var sh: int = j1 - j0 + 1

	var steps: float = float(PROFILE_STEPS - 1)
	var a2: float = light.x * light.x + light.z * light.z
	var shade := PackedFloat32Array()
	shade.resize(sw * sh)
	var any: bool = false
	for j: int in sh:
		var pz: float = -float(j0 + j) * pitch.y
		for i: int in sw:
			var px: float = float(i0 + i) * pitch.x
			var py: float = ground.x * px + ground.y * pz
			# Where the ray is inside the bounding cylinder: between its floor
			# and its roof, and within `reach` of the axis.
			var t0: float = maxf(0.0, -py / light.y)
			var t1: float = (height - py) / light.y
			var c: float = px * px + pz * pz - reach * reach
			if a2 > 1e-8:
				var b: float = px * light.x + pz * light.z
				var disc: float = b * b - a2 * c
				if disc <= 0.0:
					continue
				var root: float = sqrt(disc)
				t0 = maxf(t0, (-b - root) / a2)
				t1 = minf(t1, (-b + root) / a2)
			elif c > 0.0:
				continue
			if t1 <= t0:
				continue
			var dt: float = (t1 - t0) / float(SAMPLES)
			var inside: int = 0
			for s: int in SAMPLES:
				var t: float = t0 + (float(s) + 0.5) * dt
				var x: float = px + t * light.x
				var z: float = pz + t * light.z
				var level: int = clampi(roundi((py + t * light.y) / height * steps),
					0, PROFILE_STEPS - 1)
				var r: float = profile[level] * diameter
				if x * x + z * z <= r * r:
					inside += 1
			if inside == 0:
				continue
			shade[j * sw + i] = max_opacity * (1.0 - exp(-density * float(inside) * dt))
			any = true
	if not any:
		return [null, Vector2i.ZERO]
	shade = _soften(shade, sw, sh)
	var bytes := PackedByteArray()
	bytes.resize(sw * sh * 4)
	for k: int in sw * sh:
		bytes[k * 4 + 3] = roundi(minf(shade[k] * 2.0, max_opacity) * 255.0)
	var img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, bytes)
	img.convert(Image.FORMAT_RGBAH)
	return [img, Vector2i(i0, j0)]

## [param shade], [param w] × [param h], through a [1 2 1] filter each way.
##
## A vertex is a point sample of the shadow, and a shadow's edge falls between
## two of them: sharp, it steps from vertex to vertex, which on a course whose
## rows are a metre apart (Bunny Hill) drew every shadow as a staircase. Soft,
## it ramps over two. The stamp keeps a vertex of margin each side for it.
##
## [method _stamp] then doubles what comes out, up to the species' ceiling, so
## the softening goes outward only. Snow in the sun sits at ETR's illumination
## clamp, so taking half the sun away hardly darkens it: blurred as it is, every
## shadow drew as a pale smear of itself, most of it half strength. Doubled,
## everything inside the sharp shadow's half-way line is full strength again
## and only the ramp outside it is soft.
static func _soften(shade: PackedFloat32Array, w: int, h: int) -> PackedFloat32Array:
	var across := PackedFloat32Array()
	across.resize(w * h)
	for j: int in h:
		var row: int = j * w
		for i: int in w:
			var l: float = shade[row + i - 1] if i > 0 else 0.0
			var r: float = shade[row + i + 1] if i < w - 1 else 0.0
			across[row + i] = (l + 2.0 * shade[row + i] + r) * 0.25
	var out := PackedFloat32Array()
	out.resize(w * h)
	for j: int in h:
		for i: int in w:
			var u: float = across[(j - 1) * w + i] if j > 0 else 0.0
			var d: float = across[(j + 1) * w + i] if j < h - 1 else 0.0
			out[j * w + i] = (u + 2.0 * across[j * w + i] + d) * 0.25
	return out

## The crown's radius, as a fraction of the diameter, at [constant PROFILE_STEPS]
## heights from the foot to the top of a unit tree of [param kind] — the same
## outline its mesh is built on.
static func _profile(kind: int) -> PackedFloat32Array:
	if _profiles.is_empty():
		for k: int in 3:
			var out := PackedFloat32Array()
			out.resize(PROFILE_STEPS)
			for s: int in PROFILE_STEPS:
				out[s] = crown_radius(k, float(s) / float(PROFILE_STEPS - 1))
			_profiles.push_back(out)
	return _profiles[clampi(kind, 0, 2)]

## A unit tree of [param kind]'s crown radius at height fraction [param h].
## The trunk is left out: it is thinner than a vertex spacing.
static func crown_radius(kind: int, h: float) -> float:
	match kind:
		Forest.Species.BARE:
			var c: Vector3 = BareTreeMesh.CROWN_CENTER
			var e: Vector3 = BareTreeMesh.CROWN_RADII
			var v: float = (h - c.y) / e.y
			return e.x * sqrt(1.0 - v * v) if absf(v) < 1.0 else 0.0
		Forest.Species.SHRUB:
			var p: PackedVector2Array = ShrubMesh.PROFILE
			if h < p[0].x or h > p[p.size() - 1].x:
				return 0.0
			for k: int in range(1, p.size()):
				if h <= p[k].x:
					return lerpf(p[k - 1].y, p[k].y, (h - p[k - 1].x) / (p[k].x - p[k - 1].x))
			return 0.0
	return ConiferMesh.crown_radius(h) if h >= ConiferMesh.CROWN_BASE else 0.0

## Every tree [param root] draws with a [Forest], as `[transforms, species]` for
## [method bake]. Nothing else on a course is solid enough to shade a vertex.
static func casters_of(root: CourseRoot) -> Array:
	var transforms: Array[Transform3D] = []
	var species := PackedInt32Array()
	for type_name: String in root.object_transforms:
		var prefab: ObjectPrefab = root.object_prefabs.get(type_name, null)
		if prefab == null or not (prefab.conifer or prefab.bare or prefab.shrub):
			continue
		var kind: int = Forest.Species.CONIFER
		if prefab.bare:
			kind = Forest.Species.BARE
		elif prefab.shrub:
			kind = Forest.Species.SHRUB
		for xf: Transform3D in root.object_transforms[type_name]:
			transforms.push_back(xf)
			species.push_back(kind)
	return [transforms, species]
