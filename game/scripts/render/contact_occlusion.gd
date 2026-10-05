## The sky the course's objects take from the ground round them, baked once
## per course at load into the terrain's relief occlusion.
##
## [TerrainOcclusion] measures what the hill's own relief hides, and nothing
## stands on the hill as far as it knows: the snow at a boulder's foot, under a
## spruce's skirt or along a fallen trunk saw as much sky as open piste, so
## everything on the course floated — most of all on the web, which has no
## shadow map to put anything under it. This is the same horizon measure,
## taken against the objects: from each heightmap vertex, how high each
## azimuth's horizon climbs over the objects near it, and the cosine-weighted
## sky that loses (`sin²` of the elevation). It multiplies the relief's answer,
## so the terrain reads one sky term in `COLOR.r` as before — no varying, no
## texture unit, nothing a frame.
##
## DEVIATION: ETR has no occlusion term anywhere.
##
## [b]How.[/b] Every occluder is a solid of revolution standing on level
## ground: a tree its species' crown profile, the one its mesh and its baked
## shadow are built on ([method TreeShadowBake.crown_radius]); a prop the
## widest its mesh reaches at each height. A prop much longer than it is wide
## (a log) is a row of such solids along its length, each as wide as the log.
## A solid of revolution on level ground occludes the same at every azimuth
## round it, so the sky it takes is a function of the distance from its axis
## alone: worked out once as a short table ([method _lost_table]) per
## [constant SIZE_RATIO] of width and height — the stamp scheme of
## [TreeShadowBake], for the same reason, and with the same compounding: each
## object is one [method Image.blend_rect] of black at the sky it takes into a
## map that starts as the relief's occlusion, which multiplies what is there.
## Two objects on one side of a vertex take a little less together than they
## would as one wall — a product, not a sum — which leans toward open sky.
##
## A crown is not solid: a bare tree's is mostly air, so each species takes
## only a share of what its outline covers ([constant TREE_OPACITY]). And a
## crown that starts above the ground leaves the band under it open: an
## azimuth loses the sky between the solid's lowest and highest points as seen
## from the vertex, not everything up to the top. A vertex inside a solid's
## foot is under it and never seen; it takes the foot's value, since the
## terrain interpolates it out across the triangles round it.
##
## [b]What it leaves out.[/b] The ground's slope, and its relief under the
## object: the solid stands on the level, as the vertex does. A tilted
## ground-aligned prop is measured upright. Anything not on the ground (the
## trunk lodged over Mountain Forest's gully), anything thin (flags, poles,
## a bare tree's trunk and limbs), and the invisible colliders. An object is
## moved to its nearest vertex, as in [TreeShadowBake].
##
## [b]Cost.[/b] ~75–170 ms on the desktop (Bunny Hill 75, `bronze_set`'s 8153
## trees 120, Forest Trail's 7052 trees and props 170, most of it the tables in
## GDScript), once per course at load, on every renderer and sky. Not yet
## measured in a browser. Nothing a frame. Plain [RefCounted] with no autoload
## names, so the tests can call it statically.
class_name ContactOcclusion
extends RefCounted

## Occluders within this ratio of each other in both width and height share a
## stamp, as in [TreeShadowBake].
const SIZE_RATIO := 1.12
## How far from an object's outline the ground still loses sky to it, metres.
## Occluders fade out toward it like [constant TerrainOcclusion.RADIUS_M]'s,
## nearer: this is the contact term — the foot of a boulder, a tree well — and
## the wider landscape is the relief's.
const REACH_M := 6.0
## Azimuths sampled round a vertex, and samples along each through the
## object's bounding cylinder. The solid is symmetric about the line from its
## axis to the vertex, so only half the azimuths are walked.
const AZIMUTHS := 24
const SAMPLES := 8
## Entries in the sky-lost-by-distance table, and in the outline's
## top-and-bottom-by-radius table it is worked out from.
const TABLE_STEPS := 48
const RADIAL_STEPS := 48
## Heights at which a prop's outline is measured off its mesh.
const PROFILE_STEPS := 48
## A prop whose footprint is this many times longer than it is wide is a row
## of round solids along its length rather than one solid of its length.
const ELONGATED := 1.6
## The share of the sky lost that the ground actually goes without. The rest
## comes back off the snow round the object, which the sky measure leaves
## out: snow is the brightest thing on the course, and the foot of a tree is
## lit by the sunlit snow beside it. At 1 the web build's baked tree shadows,
## where the ambient is all there is, went slate grey beside every trunk.
const BOUNCE_KEPT := 0.6
## Per [enum Forest.Species]: the share of the sky its outline covers that a
## crown actually takes. A conifer's fins and whorls are close to solid at a
## grazing look; a shrub nearly so; a bare crown is twigs and air.
const TREE_OPACITY: PackedFloat32Array = [0.85, 0.3, 0.8]

## One shape an occluder can have.
class Shape:
	extends RefCounted
	## Radius, in units of the occluder's width scale, at [member profile]'s
	## size heights evenly from the ground to [member top], in units of its
	## height scale.
	var profile: PackedFloat32Array
	var top: float = 1.0
	var opacity: float = 1.0
	## The furthest [member profile] reaches.
	var widest: float = 0.0
	## The outline the other way round, at [constant RADIAL_STEPS] radii from
	## the axis to [member widest]: the highest and lowest the solid stands at
	## least that far out, in units of the height scale; -1 where it is nowhere
	## that wide. Free of either scale, so worked out once a shape.
	var tops := PackedFloat32Array()
	var bottoms := PackedFloat32Array()

	func _init(p_profile: PackedFloat32Array, p_top: float, p_opacity: float) -> void:
		profile = p_profile
		top = p_top
		opacity = p_opacity
		for v: float in profile:
			widest = maxf(widest, v)
		tops.resize(RADIAL_STEPS)
		bottoms.resize(RADIAL_STEPS)
		var levels: int = profile.size()
		for k: int in RADIAL_STEPS:
			var r: float = widest * float(k) / float(RADIAL_STEPS)
			var hi: float = -1.0
			var lo: float = INF
			for s: int in levels:
				if profile[s] > 0.0 and profile[s] >= r:
					var y: float = top * float(s) / float(levels - 1)
					hi = maxf(hi, y)
					lo = minf(lo, y)
			tops[k] = hi
			bottoms[k] = lo if hi >= 0.0 else -1.0

## Bake the occluders `casters_of` returns onto [param surface]'s grid, over
## [param relief] — the course's [member CourseData.ambient_occlusion], or null
## for open sky. A FORMAT_L8 [Image] on the grid, 255 open sky, or
## [param relief] itself when nothing stands on the course.
##
## [param occluders] holds one `Vector4(x, z, width scale, height scale)` per
## solid, [param shape_of] its index into [param shapes].
static func bake(occluders: PackedVector4Array, shape_of: PackedInt32Array,
		shapes: Array[Shape], surface: HeightmapSurface, relief: Image) -> Image:
	if surface == null or surface.size.x < 2 or surface.size.y < 2:
		return relief
	var w: int = surface.size.x
	var h: int = surface.size.y
	var usable: bool = relief != null and relief.get_format() == Image.FORMAT_L8 \
		and relief.get_size() == Vector2i(w, h)
	if occluders.is_empty():
		return relief if usable else null
	var pitch := Vector2(surface.world_size.x / float(w - 1),
		surface.world_size.y / float(h - 1))

	# Floats while blending, so a vertex near many objects does not lose a
	# level to rounding at each; one byte a vertex at the end. Full floats, not
	# [TreeShadowBake]'s half: Godot truncates a float to a byte, and a half
	# float sits just under most byte values, so through halves every vertex of
	# the relief came back a level or two darker — the whole course, not just
	# the ground near something.
	var map: Image
	if usable:
		map = relief.duplicate()
		map.convert(Image.FORMAT_RGBAF)
	else:
		map = Image.create_empty(w, h, false, Image.FORMAT_RGBAF)
		map.fill(Color.WHITE)
	var stamps: Dictionary[Vector3i, Array] = {}
	for k: int in occluders.size():
		var o: Vector4 = occluders[k]
		var key := Vector3i(shape_of[k], _size_class(o.z), _size_class(o.w))
		var stamp: Array = stamps.get(key, [])
		if stamp.is_empty():
			stamp = _stamp(shapes[key.x], pow(SIZE_RATIO, key.y), pow(SIZE_RATIO, key.z), pitch)
			stamps[key] = stamp
		var img: Image = stamp[0]
		if img == null:
			continue
		var at := Vector2i(roundi(o.x / pitch.x), roundi(-o.y / pitch.y))
		map.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), at + (stamp[1] as Vector2i))
	map.convert(Image.FORMAT_L8)
	return map

## [param metres] to the nearest power of [constant SIZE_RATIO], as its exponent.
static func _size_class(metres: float) -> int:
	return roundi(log(maxf(metres, 0.01)) / log(SIZE_RATIO))

## The sky one occluder of [param shape] at [param width] × [param height]
## scale takes from the ground round it: `[image, offset]`, black with the sky
## lost in alpha, and the offset in vertices from the occluder's vertex to the
## image's corner. `[null, …]` for one that takes none.
static func _stamp(shape: Shape, width: float, height: float, pitch: Vector2) -> Array:
	var table: PackedFloat32Array = _lost_table(shape, width, height)
	var reach: float = shape.widest * width + REACH_M
	var ni: int = ceili(reach / pitch.x)
	var nj: int = ceili(reach / pitch.y)
	var sw: int = 2 * ni + 1
	var sh: int = 2 * nj + 1
	var bytes := PackedByteArray()
	bytes.resize(sw * sh * 4)
	var scale: float = float(TABLE_STEPS - 1) / reach
	var any: bool = false
	for j: int in sh:
		var dz: float = float(j - nj) * pitch.y
		for i: int in sw:
			var dx: float = float(i - ni) * pitch.x
			var f: float = sqrt(dx * dx + dz * dz) * scale
			if f >= float(TABLE_STEPS - 1):
				continue
			var k: int = int(f)
			var lost: float = lerpf(table[k], table[k + 1], f - float(k))
			var a: int = roundi(clampf(lost, 0.0, 1.0) * 255.0)
			if a > 0:
				bytes[(j * sw + i) * 4 + 3] = a
				any = true
	if not any:
		return [null, Vector2i.ZERO]
	var img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, bytes)
	img.convert(Image.FORMAT_RGBAF)
	return [img, Vector2i(-ni, -nj)]

## The share of the sky lost at [constant TABLE_STEPS] distances from the axis
## of one [param shape] at [param width] × [param height] scale, evenly from 0
## to its outline plus [constant REACH_M]: the mean over [constant AZIMUTHS]
## of `sin²` of the highest point of the solid the azimuth crosses less `sin²`
## of its lowest, faded by distance, times the shape's opacity — the
## [TerrainOcclusion] measure, against the solid.
static func _lost_table(shape: Shape, width: float, height: float) -> PackedFloat32Array:
	var r_max: float = shape.widest * width
	var reach: float = r_max + REACH_M
	var table := PackedFloat32Array()
	table.resize(TABLE_STEPS)
	if r_max <= 0.0 or height <= 0.0:
		return table
	var tops: PackedFloat32Array = shape.tops
	var bottoms: PackedFloat32Array = shape.bottoms
	var radial_scale: float = float(RADIAL_STEPS) / r_max
	var half: int = AZIMUTHS / 2
	var cosines := PackedFloat32Array()
	cosines.resize(half)
	for a: int in half:
		cosines[a] = cos(PI * (float(a) + 0.5) / float(half))
	# Where the solid meets the ground. A vertex inside that is under it and
	# never seen — but the terrain interpolates its value across every triangle
	# round it, out past the solid's edge, so it takes the value at the foot
	# rather than the black of being inside: a stone half a vertex wide drew
	# a dark diamond twice its size. A crown that starts above the ground has
	# no foot, and the snow under it is measured where it is. One step of
	# the outline table out, which reads the foot's own step as still inside.
	var foot: float = shape.profile[0] * width
	if foot > 0.0:
		foot += r_max / float(RADIAL_STEPS)
	for e: int in TABLE_STEPS - 1:
		var rho: float = maxf(reach * float(e) / float(TABLE_STEPS - 1), foot)
		var lost: float = 0.0
		for a: int in half:
			# The ray from (rho, 0) along this azimuth, against the bounding
			# cylinder: where it is within r_max of the axis.
			var b: float = rho * cosines[a]
			var disc: float = b * b - (rho * rho - r_max * r_max)
			if disc <= 0.0:
				continue
			var root: float = sqrt(disc)
			var t0: float = maxf(0.0, -b - root)
			var t1: float = -b + root
			if t1 <= t0 or t0 >= REACH_M:
				continue
			var dt: float = (t1 - t0) / float(SAMPLES)
			var q_hi: float = -1.0
			var q_lo: float = INF
			var nearest: float = INF
			for s: int in SAMPLES:
				var t: float = t0 + (float(s) + 0.5) * dt
				var d: float = sqrt(maxf(rho * rho + 2.0 * t * b + t * t, 0.0))
				var k: int = mini(int(d * radial_scale), RADIAL_STEPS - 1)
				if tops[k] < 0.0:
					continue
				q_hi = maxf(q_hi, tops[k] * height / t)
				q_lo = minf(q_lo, bottoms[k] * height / t)
				nearest = minf(nearest, t)
			if q_hi < 0.0:
				continue
			var fall: float = 1.0 - (nearest / REACH_M) * (nearest / REACH_M)
			if fall <= 0.0:
				continue
			var s_hi: float = q_hi * q_hi / (1.0 + q_hi * q_hi)
			var s_lo: float = q_lo * q_lo / (1.0 + q_lo * q_lo)
			lost += (s_hi - s_lo) * fall
		table[e] = lost / float(half) * shape.opacity * BOUNCE_KEPT
	# The last entry stays 0: nothing past the reach, where the stamp ends.
	return table

## Everything on [param root]'s course that stands on the ground and is solid
## enough to shade it, as `[occluders, shape_of, shapes]` for [method bake]:
## every tree a [Forest] draws, and every ground-aligned prop with a mesh.
static func casters_of(root: CourseRoot) -> Array:
	var occluders := PackedVector4Array()
	var shape_of := PackedInt32Array()
	var shapes: Array[Shape] = []
	var tree_shape := {}
	for type_name: String in root.object_transforms:
		var prefab: ObjectPrefab = root.object_prefabs.get(type_name, null)
		if prefab == null:
			continue
		var transforms: Array = root.object_transforms[type_name]
		if prefab.conifer or prefab.bare or prefab.shrub:
			var kind: int = Forest.Species.CONIFER
			if prefab.bare:
				kind = Forest.Species.BARE
			elif prefab.shrub:
				kind = Forest.Species.SHRUB
			if not tree_shape.has(kind):
				tree_shape[kind] = shapes.size()
				shapes.push_back(Shape.new(TreeShadowBake._profile(kind), 1.0,
					TREE_OPACITY[kind]))
			for xf: Transform3D in transforms:
				occluders.push_back(Vector4(xf.origin.x, xf.origin.z,
					xf.basis.x.length(), xf.basis.y.length()))
				shape_of.push_back(tree_shape[kind])
		elif prefab.ground_aligned and prefab.mesh != null:
			var faces: PackedVector3Array = prefab.mesh.get_faces()
			if faces.is_empty():
				continue
			var box: AABB = prefab.mesh.get_aabb()
			var round_shape: int = shapes.size()
			shapes.push_back(prop_shape(faces, false))
			var long_shape: int = shapes.size()
			shapes.push_back(prop_shape(faces, true))
			for xf: Transform3D in transforms:
				_add_prop(occluders, shape_of, xf, box, round_shape, long_shape,
					shapes[long_shape].widest)
	return [occluders, shape_of, shapes]

## One prop at [param xf] whose mesh spans [param box]: one solid, or a row of
## them along its local X when it is [constant ELONGATED] — each as wide as the
## prop and spaced by that width.
static func _add_prop(occluders: PackedVector4Array, shape_of: PackedInt32Array,
		xf: Transform3D, box: AABB, round_shape: int, long_shape: int,
		long_widest: float) -> void:
	var sx: float = xf.basis.x.length()
	var sy: float = xf.basis.y.length()
	var sz: float = xf.basis.z.length()
	var long_x: float = box.size.x * sx
	var across: float = box.size.z * sz
	var mid_z: float = box.position.z + box.size.z * 0.5
	if long_x <= across * ELONGATED or long_widest <= 0.0:
		var c: Vector3 = xf * Vector3(box.position.x + box.size.x * 0.5, 0.0, mid_z)
		occluders.push_back(Vector4(c.x, c.z, (sx + sz) * 0.5, sy))
		shape_of.push_back(round_shape)
		return
	var piece: float = 2.0 * long_widest * sz
	var n: int = maxi(1, ceili(long_x / piece))
	for k: int in n:
		# Local X of each piece's centre, the row spanning the box end to end.
		var f: float = (float(k) + 0.5) / float(n)
		var c: Vector3 = xf * Vector3(box.position.x + box.size.x * f, 0.0, mid_z)
		occluders.push_back(Vector4(c.x, c.z, sz, sy))
		shape_of.push_back(long_shape)

## A prop's outline off its mesh ([param faces], as `Mesh.get_faces` gives
## them): the furthest its surface reaches from the vertical axis — or, with
## [param across], from the plane through its long axis — at each of
## [constant PROFILE_STEPS] heights from the ground (local Y 0, where a prop
## stands; anything sunk below is ignored) to its top. Edges are sampled, not
## just corners, so a coarse mesh has no gaps between its rows.
static func prop_shape(faces: PackedVector3Array, across: bool) -> Shape:
	var top: float = 0.0
	for v: Vector3 in faces:
		top = maxf(top, v.y)
	var profile := PackedFloat32Array()
	profile.resize(PROFILE_STEPS)
	if top <= 0.0:
		return Shape.new(profile, 1.0, 1.0)
	var mid := Vector2.ZERO
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for v: Vector3 in faces:
		lo = lo.min(v)
		hi = hi.max(v)
	mid = Vector2((lo.x + hi.x) * 0.5, (lo.z + hi.z) * 0.5)
	const EDGE_SAMPLES := 8
	for f: int in range(0, faces.size() - 2, 3):
		for e: int in 3:
			var a: Vector3 = faces[f + e]
			var b: Vector3 = faces[f + (e + 1) % 3]
			# The samples, and where the edge passes through the ground: a sunk
			# prop's outline at its foot is there and nowhere else.
			for s: int in EDGE_SAMPLES + 2:
				var p: Vector3
				if s <= EDGE_SAMPLES:
					p = a.lerp(b, float(s) / float(EDGE_SAMPLES))
				elif (a.y < 0.0) != (b.y < 0.0):
					p = a.lerp(b, a.y / (a.y - b.y))
					p.y = 0.0
				else:
					continue
				if p.y < 0.0:
					continue
				var r: float = absf(p.z - mid.y) if across \
					else Vector2(p.x - mid.x, p.z - mid.y).length()
				var k: int = clampi(roundi(p.y / top * float(PROFILE_STEPS - 1)),
					0, PROFILE_STEPS - 1)
				profile[k] = maxf(profile[k], r)
	# A level no sample landed on takes its neighbours' between them, and the
	# lowest measured one down to the ground: a prop stands on it.
	var last: int = -1
	for k: int in PROFILE_STEPS:
		if profile[k] <= 0.0:
			continue
		if last < 0:
			for g: int in k:
				profile[g] = profile[k]
		elif k - last > 1:
			for g: int in range(last + 1, k):
				profile[g] = lerpf(profile[last], profile[k],
					float(g - last) / float(k - last))
		last = k
	return Shape.new(profile, top, 1.0)
