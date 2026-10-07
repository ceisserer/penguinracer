## A play area polygon in world XZ (x, z), asked every tick whether a racer is
## still inside it.
##
## Not [method Geometry2D.is_point_in_polygon]: that casts toward a corner
## beyond the polygon's bounds and miscounts a vertex its cast grazes. Down
## Snow Park's straight half-pipe, where the play area's edges are long rows
## of collinear vertices, it called 0.16 % of the points well inside the pipe
## outside — and [RacePhysics] snapped the racer 17 m sideways onto the edge,
## several times a run. This counts even-odd along a ray across +X, each edge
## taken half-open, so a ray through a vertex counts it once; and it only
## looks at the edges in the racer's band of z, so it costs a handful of
## edges, not the polygon's hundreds.
class_name PlayArea
extends RefCounted

## How deep a band of z is, metres.
const BAND := 8.0

var polygon: PackedVector2Array
var _z0: float = 0.0
## Per band, the edges (by their first vertex) whose z span reaches into it.
var _bands: Array[PackedInt32Array] = []

func _init(p_polygon: PackedVector2Array = PackedVector2Array()) -> void:
	polygon = p_polygon
	if polygon.size() < 3:
		return
	var lo: float = INF
	var hi: float = -INF
	for p: Vector2 in polygon:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	_z0 = lo
	_bands.resize(int((hi - lo) / BAND) + 1)
	for b: int in _bands.size():
		_bands[b] = PackedInt32Array()
	var n: int = polygon.size()
	for i: int in n:
		var a: float = polygon[i].y
		var c: float = polygon[(i + 1) % n].y
		for b: int in range(_band(minf(a, c)), _band(maxf(a, c)) + 1):
			_bands[b].push_back(i)

func _band(z: float) -> int:
	return clampi(int((z - _z0) / BAND), 0, _bands.size() - 1)

## Whether [param at] is inside the polygon.
func contains(at: Vector2) -> bool:
	if _bands.is_empty():
		return false
	var n: int = polygon.size()
	var inside: bool = false
	for i: int in _bands[_band(at.y)]:
		var a: Vector2 = polygon[i]
		var b: Vector2 = polygon[(i + 1) % n]
		if (a.y > at.y) != (b.y > at.y) \
				and at.x < a.x + (at.y - a.y) * (b.x - a.x) / (b.y - a.y):
			inside = not inside
	return inside

## The point on the polygon's edge nearest [param p].
func closest_point(p: Vector2) -> Vector2:
	var best: Vector2 = polygon[0]
	var best_d: float = INF
	var n: int = polygon.size()
	for i: int in n:
		var c: Vector2 = Geometry2D.get_closest_point_to_segment(p, polygon[i],
			polygon[(i + 1) % n])
		var d: float = c.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = c
	return best

## [method contains] for a polygon asked once: the same count over every edge.
static func is_inside(at: Vector2, p_polygon: PackedVector2Array) -> bool:
	var inside: bool = false
	var j: int = p_polygon.size() - 1
	for i: int in p_polygon.size():
		var a: Vector2 = p_polygon[i]
		var b: Vector2 = p_polygon[j]
		if (a.y > at.y) != (b.y > at.y) \
				and at.x < a.x + (at.y - a.y) * (b.x - a.x) / (b.y - a.y):
			inside = not inside
		j = i
	return inside
