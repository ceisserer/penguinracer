## Uniform spatial grid over the course, bucketed in X and Z.
##
## Replaces ETR's `CheckItemCollection`, which was a linear scan over every item
## on the course *per ODE substep* (etracer.md §9). Trees and items each get
## their own grid.
class_name ObjectGrid
extends RefCounted

const DEFAULT_CELL_SIZE := 4.0

var cell_size: float = DEFAULT_CELL_SIZE
## World position of each object.
var positions: PackedVector3Array = PackedVector3Array()
## Collision diameter per object, metres.
var diameters: PackedFloat32Array = PackedFloat32Array()
## Height per object, metres.
var heights: PackedFloat32Array = PackedFloat32Array()
## Prefab / object-type index per object.
var types: PackedInt32Array = PackedInt32Array()
## 1 while still collectable, 0 once picked up. Unused for trees.
var collectable: PackedByteArray = PackedByteArray()

var _cells: Dictionary[int, PackedInt32Array] = {}
var _cols: int = 1

func _key(cx: int, cz: int) -> int:
	return cz * 73856093 + cx * 19349663

func add(pos: Vector3, diam: float, height: float, type_index: int) -> int:
	var idx: int = positions.size()
	positions.push_back(pos)
	diameters.push_back(diam)
	heights.push_back(height)
	types.push_back(type_index)
	collectable.push_back(1)
	return idx

## Build the buckets. Call once after all objects are added.
##
## Accumulated in plain [Array]s and converted once. Appending straight into the
## dictionary's [PackedInt32Array] read the value back out first, which is a
## copy-on-write share — so `push_back` copied the whole cell, per insertion.
func build(p_cell_size: float = DEFAULT_CELL_SIZE) -> void:
	cell_size = p_cell_size
	_cells.clear()
	var buckets: Dictionary[int, Array] = {}
	for i: int in positions.size():
		var p: Vector3 = positions[i]
		var k: int = _key(floori(p.x / cell_size), floori(p.z / cell_size))
		if buckets.has(k):
			buckets[k].push_back(i)
		else:
			buckets[k] = [i]
	for k: int in buckets:
		_cells[k] = PackedInt32Array(buckets[k])

func size() -> int:
	return positions.size()

## Indices in the 3x3 cell neighbourhood around (x, z). With the default 4 m
## cell and query radii under 3 m this is a conservative superset.
func query(x: float, z: float, out: PackedInt32Array) -> PackedInt32Array:
	out.clear()
	var cx: int = floori(x / cell_size)
	var cz: int = floori(z / cell_size)
	for dz: int in range(-1, 2):
		for dx: int in range(-1, 2):
			var k: int = _key(cx + dx, cz + dz)
			if _cells.has(k):
				out.append_array(_cells[k])
	return out

func reset_collectables() -> void:
	for i: int in collectable.size():
		collectable[i] = 1
