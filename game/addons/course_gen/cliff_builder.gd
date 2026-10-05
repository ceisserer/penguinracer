## Lays a rock face over a stretch of a generated course's wall: a [CliffSet]
## piece, for a generator that knows where its rock is.
##
## The face is a grid laid on the wall itself rather than on the heightmap's XZ
## grid — rows down the course every [constant STEP], and along each row
## vertices every [constant STEP] *of the slope's own length*, so a 70° face
## gets as many vertices up it as a gentle one gets across. Each vertex is then
## pushed off the wall:
##
## - [b]bedding[/b]: the rock lies in beds about [constant BED] thick, parallel
##   to the trail's floor and warped, each one leaning out a little more toward
##   its top and stepping back sharply above it. Pushed out level, not along the
##   wall's normal, so the step is a level ledge — which catches snow — and the
##   bed under it a face steeper than the wall;
## - [b]joints[/b]: blocks a few metres across, each set out by its own amount,
##   so the beds break into steps along the course;
## - [b]roughness[/b] along the normal, at two scales.
##
## How much of that a vertex gets is the generator's [member mask], 0..1; at 0
## the vertex sinks [constant BURY] under the wall. A generator masks its rock
## and the face's edges, so the face comes up out of the ground where the rock
## starts and the heightmap closes over it wherever it ends — no seam to stitch.
##
## Deterministic: the same callables and seed give the same rock.
class_name CliffBuilder
extends RefCounted

## Metres between vertices, both ways.
const STEP := 0.25
## How far under the wall a vertex sits where the mask is 0, and how far out of
## it the rock stands at the least where it is 1: past the heightmap's own
## triangles, which sit a few centimetres off the smooth ground they sample.
const BURY := 0.5
const STAND_OUT := 0.3
## A bed's thickness in metres, and how far out its top leans at the most.
const BED := 1.9
const BED_OUT := 1.4
## The fraction of a bed taken by the step back at its top.
const BED_STEP := 0.14
## Rows per mesh, so each covers 16 m of the course and can be culled.
const PIECE_ROWS := 64
## Metres between the samples each row's profile is measured at.
const PROFILE_STEP := 0.05

## (x, z) → the ground's world height: the generator's own analytic ground.
var ground: Callable
## (x, z) → 0..1, how much the rock stands out there.
var mask: Callable
## (d) → the world height of the trail's floor [param d] metres down, which the
## bedding runs parallel to.
var floor_y: Callable
## (d) → the X where a row starts, at the wall's foot.
var foot_x: Callable
## +1 for a wall on the +X side of the trail, −1 for one on the −X side.
var side: float = 1.0
## How far across X a row runs from its foot, at most.
var reach: float = 30.0
## X the rows stay inside: the course's edges.
var x_limits: Vector2 = Vector2(0.0, 1.0e9)

var _warp := FastNoiseLite.new()
var _bed_amp := FastNoiseLite.new()
var _joints := FastNoiseLite.new()
var _rough := FastNoiseLite.new()
var _bulge := FastNoiseLite.new()

func _init(p_seed: int) -> void:
	var all: Array[FastNoiseLite] = [_warp, _bed_amp, _joints, _rough, _bulge]
	for i: int in all.size():
		all[i].seed = p_seed + i
		all[i].noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp.frequency = 1.0 / 11.0
	_warp.fractal_octaves = 2
	_bed_amp.frequency = 1.0 / 9.0
	_joints.noise_type = FastNoiseLite.TYPE_CELLULAR
	_joints.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	_joints.frequency = 1.0 / 3.2
	_joints.fractal_type = FastNoiseLite.FRACTAL_NONE
	_rough.frequency = 1.0 / 1.3
	_rough.fractal_octaves = 2
	_bulge.frequency = 1.0 / 6.0

## The face over [param d_from]..[param d_to] metres down: its meshes, and how
## far it stands above the heightmap at each grid vertex it covers, added to
## [param lift] (vertex index → metres, the largest kept). [param grid_height]
## is (gx, gz) → the heightmap's world height at that vertex and [param cell]
## the grid's pitch.
func build(d_from: float, d_to: float, grid_height: Callable, cell: float,
		lift: Dictionary) -> Array[ArrayMesh]:
	var rows: int = int((d_to - d_from) / STEP) + 1
	# Each row's profile across the wall, by length along the slope.
	var profiles: Array = []
	var longest: float = 0.0
	for r: int in rows:
		var d: float = d_from + float(r) * STEP
		var p: PackedVector3Array = _profile(d)
		profiles.push_back(p)
		longest = maxf(longest, p[p.size() - 1].z)
	var cols: int = maxi(2, int(longest / STEP) + 1)

	var base := PackedVector3Array()
	var normal0 := PackedVector3Array()
	var verts := PackedVector3Array()
	var weight := PackedFloat32Array()
	base.resize(rows * cols)
	normal0.resize(rows * cols)
	verts.resize(rows * cols)
	weight.resize(rows * cols)
	for r: int in rows:
		var d: float = d_from + float(r) * STEP
		var z: float = -d
		var p: PackedVector3Array = profiles[r]
		var length: float = p[p.size() - 1].z
		var k: int = 0
		var ends: float = smoothstep(d_from, d_from + 2.5, d) \
			* (1.0 - smoothstep(d_to - 2.5, d_to, d))
		for c: int in cols:
			# Spread over this row's own length, so every row has `cols`.
			var s: float = length * float(c) / float(cols - 1)
			while k < p.size() - 2 and p[k + 1].z < s:
				k += 1
			var f: float = clampf((s - p[k].z) / maxf(p[k + 1].z - p[k].z, 1e-6), 0.0, 1.0)
			var x: float = lerpf(p[k].x, p[k + 1].x, f)
			var y: float = lerpf(p[k].y, p[k + 1].y, f)
			var b := Vector3(x, y, z)
			var n0: Vector3 = _ground_normal(x, z)
			var m: float = clampf(mask.call(x, z), 0.0, 1.0) * ends
			var i: int = r * cols + c
			base[i] = b
			normal0[i] = n0
			weight[i] = m
			verts[i] = b + _offset(b, n0, d, m)

	var normals: PackedVector3Array = _grid_normals(verts, normal0, rows, cols)
	var colors := PackedColorArray()
	colors.resize(rows * cols)
	for r: int in rows:
		for c: int in cols:
			var i: int = r * cols + c
			var n: Vector3 = normals[i]
			var n0: Vector3 = normal0[i]
			var ledge: float = weight[i] * smoothstep(0.08, 0.3, n.y - n0.y) \
				* smoothstep(0.5, 0.8, n.y)
			var sky: float = _cavity(verts, normals, rows, cols, r, c) \
				* clampf((1.0 + n.y) / (1.0 + n0.y), 0.4, 1.0)
			colors[i] = Color(lerpf(1.0, sky, weight[i]), 0.0, 1.0, 1.0 - ledge)
	_add_lift(verts, weight, grid_height, cell, lift)

	# Which way round the grid faces is a property of the whole face, read off
	# the wall before it was pushed about: per quad, a fold under an overhang
	# would turn some triangles inside out.
	var facing: float = 0.0
	for r: int in rows - 1:
		for c: int in cols - 1:
			var a: int = r * cols + c
			facing += (base[a + 1] - base[a]).cross(base[a + cols] - base[a]).dot(normal0[a])
	var out: Array[ArrayMesh] = []
	var r0: int = 0
	while r0 < rows - 1:
		var r1: int = mini(r0 + PIECE_ROWS, rows - 1)
		out.push_back(_piece(verts, normals, colors, cols, r0, r1, facing > 0.0))
		r0 = r1
	return out

## One row's wall, from its foot out across X: (x, y, length along the slope so
## far) every [constant PROFILE_STEP] across X.
func _profile(d: float) -> PackedVector3Array:
	var z: float = -d
	var x: float = foot_x.call(d)
	var out := PackedVector3Array()
	var length: float = 0.0
	var prev := Vector2(x, ground.call(x, z))
	out.push_back(Vector3(prev.x, prev.y, 0.0))
	var t: float = PROFILE_STEP
	while t <= reach:
		var px: float = x + side * t
		if px < x_limits.x or px > x_limits.y:
			break
		var at := Vector2(px, ground.call(px, z))
		length += at.distance_to(prev)
		out.push_back(Vector3(at.x, at.y, length))
		prev = at
		t += PROFILE_STEP
	return out

func _ground_normal(x: float, z: float) -> Vector3:
	var e: float = STEP
	var dx: float = (ground.call(x + e, z) - ground.call(x - e, z)) / (2.0 * e)
	var dz: float = (ground.call(x, z + e) - ground.call(x, z - e)) / (2.0 * e)
	return Vector3(-dx, 1.0, -dz).normalized()

## Where the rock stands relative to the wall point [param b] (normal
## [param n0]), [param d] metres down, with [param m] of the full relief.
func _offset(b: Vector3, n0: Vector3, d: float, m: float) -> Vector3:
	# Out along the normal: the least the rock stands out, and its roughness.
	var along: float = STAND_OUT + 0.1 * _rough.get_noise_3dv(b) \
		+ 0.3 * _bulge.get_noise_3dv(b)
	var out_n: float = lerpf(-BURY, along, m)
	if m <= 0.0:
		return n0 * out_n
	# Out level: the bedding and the joints, only on a face steep enough to
	# show them — on the gentle top of a wall a level push slides the ground
	# along itself and draws nothing.
	var level := Vector3(n0.x, 0.0, n0.z)
	if level.length() < 1e-3:
		return n0 * out_n
	level = level.normalized()
	var steep: float = smoothstep(0.15, 0.5, 1.0 - n0.y)
	var height: float = b.y - floor_y.call(d)
	var bed_at: float = height + 0.9 * _warp.get_noise_2d(d, height * 0.3)
	var bed: float = floor(bed_at / BED)
	var amp: float = lerpf(0.15, 1.0, 0.5 + 0.5 * _bed_amp.get_noise_2d(bed * 53.0, d))
	var seam: float = _bed_profile(bed_at / BED - bed) * amp * BED_OUT \
		+ 0.12 * _bed_profile(fposmod(bed_at / (BED * 0.31), 1.0))
	var joint: float = 0.3 + 0.3 * _joints.get_noise_2d(d, bed_at * 0.6)
	return n0 * out_n + level * ((seam + joint) * steep * m)

## A bed's lean, 0 at its foot rising to 1 just under its top, then the step
## back to 0 over the last [constant BED_STEP] of it.
static func _bed_profile(t: float) -> float:
	var top: float = 1.0 - BED_STEP
	if t < top:
		return pow(t / top, 0.8)
	return 1.0 - smoothstep(top, 1.0, t)

## Smooth normals off the displaced grid, turned to face the way the wall does.
static func _grid_normals(verts: PackedVector3Array, normal0: PackedVector3Array,
		rows: int, cols: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(verts.size())
	for r: int in rows:
		var r0: int = maxi(r - 1, 0)
		var r1: int = mini(r + 1, rows - 1)
		for c: int in cols:
			var c0: int = maxi(c - 1, 0)
			var c1: int = mini(c + 1, cols - 1)
			var across: Vector3 = verts[r * cols + c1] - verts[r * cols + c0]
			var down: Vector3 = verts[r1 * cols + c] - verts[r0 * cols + c]
			var n: Vector3 = across.cross(down)
			var i: int = r * cols + c
			if n.length_squared() < 1e-12:
				n = normal0[i]
			n = n.normalized()
			out[i] = -n if n.dot(normal0[i]) < 0.0 else n
	return out

## The sky a vertex's own surroundings leave it: how far the rock round it
## rises above its tangent plane, at two reaches. A crude horizon AO, enough to
## put the shade under a ledge and in a joint.
static func _cavity(verts: PackedVector3Array, normals: PackedVector3Array,
		rows: int, cols: int, r: int, c: int) -> float:
	var p: Vector3 = verts[r * cols + c]
	var n: Vector3 = normals[r * cols + c]
	var lost: float = 0.0
	var taps: int = 0
	for reach: int in [2, 5]:
		for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
				Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
			var rr: int = r + o.y * reach
			var cc: int = c + o.x * reach
			if rr < 0 or rr >= rows or cc < 0 or cc >= cols:
				continue
			var q: Vector3 = verts[rr * cols + cc] - p
			var dist: float = q.length()
			if dist < 1e-4:
				continue
			lost += maxf(q.dot(n) / dist, 0.0)
			taps += 1
	if taps == 0:
		return 1.0
	return clampf(1.0 - 1.3 * lost / float(taps), 0.35, 1.0)

## How far the rock stands over each grid vertex it covers, and the vertices
## round those, so a camera reading the four round a point always sees it.
static func _add_lift(verts: PackedVector3Array, weight: PackedFloat32Array,
		grid_height: Callable, cell: float, lift: Dictionary) -> void:
	for i: int in verts.size():
		if weight[i] <= 0.0:
			continue
		var v: Vector3 = verts[i]
		var gx0: int = roundi(v.x / cell)
		var gz0: int = roundi(-v.z / cell)
		for oz: int in [-1, 0, 1]:
			for ox: int in [-1, 0, 1]:
				var gx: int = gx0 + ox
				var gz: int = gz0 + oz
				var above: float = v.y - float(grid_height.call(gx, gz))
				if above <= 0.05:
					continue
				var key := Vector2i(gx, gz)
				if above > float(lift.get(key, 0.0)):
					lift[key] = above

## Rows [param r0]..[param r1] as one mesh. Wound so the face the wall shows is
## the front — Godot's front face is clockwise seen from in front — which for
## a grid whose (column, row) cross product points out of the wall
## ([param flip]) is the other way round from the order it is laid out in.
static func _piece(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, cols: int, r0: int, r1: int, flip: bool) -> ArrayMesh:
	var n: int = (r1 - r0 + 1) * cols
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts.slice(r0 * cols, r0 * cols + n)
	arrays[Mesh.ARRAY_NORMAL] = normals.slice(r0 * cols, r0 * cols + n)
	arrays[Mesh.ARRAY_COLOR] = colors.slice(r0 * cols, r0 * cols + n)
	var indices := PackedInt32Array()
	indices.resize((r1 - r0) * (cols - 1) * 6)
	var k: int = 0
	for r: int in r1 - r0:
		for c: int in cols - 1:
			var a: int = r * cols + c
			var b: int = a + 1
			var cc: int = a + cols
			var dd: int = cc + 1
			if flip:
				indices[k] = a; indices[k + 1] = cc; indices[k + 2] = b
				indices[k + 3] = b; indices[k + 4] = cc; indices[k + 5] = dd
			else:
				indices[k] = a; indices[k + 1] = b; indices[k + 2] = cc
				indices[k + 3] = b; indices[k + 4] = dd; indices[k + 5] = cc
			k += 6
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
