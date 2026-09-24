## Ambient occlusion of a course's relief, baked once by the importer.
##
## ETR's ambient reaches every vertex of the hill equally, so the bottom of a
## gully, the foot of a bank and an open slope all read the same in shade. This
## measures how much of the sky each heightmap vertex can actually see and
## hands the answer to `terrain.gdshader`, which takes it off the ambient.
##
## Horizon-based: from each vertex, march outward in [constant DIRECTIONS]
## directions and keep the highest elevation angle the relief reaches. The sky
## a cosine-weighted receiver loses behind a horizon at elevation θ is sin²θ of
## that azimuth's share, so the visible fraction is `1 − mean(sin²θ)`. Nearer
## occluders count for more ([constant RADIUS_M] fades the far ones out), since
## a ridge 14 m away shades a slope far less than the bank beside it.
##
## Measured against the **local relief**, not the world: the course's base
## slope is analytic ([member CourseData.base_angle]) and a uniformly tilted
## plane occludes nothing of the sky it faces. That is also why this can run on
## [member CourseData.heightmap] as stored.
##
## DEVIATION: ETR has no occlusion term anywhere.
##
## Static and free of any node or autoload, so the importer and the tests can
## both call it.
class_name TerrainOcclusion
extends RefCounted

## Azimuths sampled per vertex.
const DIRECTIONS := 8
## Distances marched along each azimuth, in metres. Spaced wider as they go:
## the near steps find the foot of a bank, the far ones a gully's walls.
const STEPS_M: Array[float] = [0.6, 1.25, 2.25, 3.5, 5.5, 8.0, 11.5]
## Occluders fade out towards this distance.
const RADIUS_M := 14.0

## Occlusion for a `w`×`h` vertex grid of relief heights spanning `world_size`
## metres, as a FORMAT_L8 [Image] of the same size: 255 is open sky, 0 is none.
##
## The march runs on every [param stride]th vertex and is then interpolated
## back up — occlusion is low-frequency by construction (nothing nearer than
## [constant STEPS_M]'s first step can shade), and the importer's heightmap is
## a 2x upsample whose even vertices are the source grid anyway. A stride that
## does not divide the grid falls back to 1.
static func bake(heights: PackedFloat32Array, w: int, h: int, world_size: Vector2,
		stride: int = 2) -> Image:
	if stride < 1 or (w - 1) % stride != 0 or (h - 1) % stride != 0:
		stride = 1
	var cw: int = (w - 1) / stride + 1
	var ch: int = (h - 1) / stride + 1
	var dx: float = world_size.x / float(maxi(w - 1, 1)) * float(stride)
	var dz: float = world_size.y / float(maxi(h - 1, 1)) * float(stride)

	# Coarse-grid offsets per (direction, step), with the distance the rounded
	# offset really covers and its falloff. Flat arrays: this loop is most of an
	# import, and GDScript pays for every lookup.
	var off_x := PackedInt32Array()
	var off_z := PackedInt32Array()
	var inv_dist := PackedFloat32Array()
	var weight := PackedFloat32Array()
	var starts := PackedInt32Array()
	for d: int in DIRECTIONS:
		starts.push_back(off_x.size())
		var a: float = TAU * float(d) / float(DIRECTIONS)
		var last := Vector2i.ZERO
		for m: float in STEPS_M:
			var o := Vector2i(roundi(cos(a) * m / dx), roundi(sin(a) * m / dz))
			if o == Vector2i.ZERO or o == last:
				continue
			last = o
			var dist: float = Vector2(float(o.x) * dx, float(o.y) * dz).length()
			if dist > RADIUS_M:
				continue
			var fall: float = 1.0 - (dist / RADIUS_M) * (dist / RADIUS_M)
			off_x.push_back(o.x)
			off_z.push_back(o.y)
			inv_dist.push_back(1.0 / dist)
			weight.push_back(fall)
	starts.push_back(off_x.size())

	# The coarse grid's heights, gathered once.
	var coarse := PackedFloat32Array()
	coarse.resize(cw * ch)
	for y: int in ch:
		var src_row: int = y * stride * w
		for x: int in cw:
			coarse[y * cw + x] = heights[src_row + x * stride]

	var ao := PackedFloat32Array()
	ao.resize(cw * ch)
	var inv_dirs: float = 1.0 / float(DIRECTIONS)
	for y: int in ch:
		for x: int in cw:
			var h0: float = coarse[y * cw + x]
			var lost: float = 0.0
			for d: int in DIRECTIONS:
				var best: float = 0.0
				for k: int in range(starts[d], starts[d + 1]):
					var sx: int = clampi(x + off_x[k], 0, cw - 1)
					var sy: int = clampi(y + off_z[k], 0, ch - 1)
					var rise: float = coarse[sy * cw + sx] - h0
					if rise <= 0.0:
						continue
					var t: float = rise * inv_dist[k]
					var s2: float = t * t / (1.0 + t * t) * weight[k]
					if s2 > best:
						best = s2
				lost += best
			ao[y * cw + x] = 1.0 - lost * inv_dirs

	# Back up to the full grid. A vertex grid, not a texture: coarse vertex i
	# sits exactly on fine vertex i * stride, so interpolate between those and
	# never through texel centres.
	var bytes := PackedByteArray()
	bytes.resize(w * h)
	var inv_stride: float = 1.0 / float(stride)
	for y: int in h:
		var fy: float = float(y) * inv_stride
		var y0: int = mini(int(fy), ch - 1)
		var y1: int = mini(y0 + 1, ch - 1)
		var ty: float = fy - float(y0)
		for x: int in w:
			var fx: float = float(x) * inv_stride
			var x0: int = mini(int(fx), cw - 1)
			var x1: int = mini(x0 + 1, cw - 1)
			var tx: float = fx - float(x0)
			var top: float = lerpf(ao[y0 * cw + x0], ao[y0 * cw + x1], tx)
			var bot: float = lerpf(ao[y1 * cw + x0], ao[y1 * cw + x1], tx)
			bytes[y * w + x] = int(round(clampf(lerpf(top, bot, ty), 0.0, 1.0) * 255.0))
	return Image.create_from_data(w, h, false, Image.FORMAT_L8, bytes)

## The visible-sky fraction at vertex (x, y) of an image [method bake] made,
## 0..1. For tests and tools; the terrain reads the bytes directly.
static func at(img: Image, x: int, y: int) -> float:
	return img.get_pixel(x, y).r
