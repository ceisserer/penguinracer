## Rock faces standing out of a course's walls: real geometry where the
## heightmap can only be a smooth sheet.
##
## A heightmap holds one height per point, sampled every half metre across X
## and Z. On a 70° wall that is a vertex every 1.5 m up the face and no ledge,
## undercut or joint at all — the rock is a smooth sheet whatever its texture.
## A course generator can therefore lay meshes over its rock: each one stands
## out of the wall where the rock is and sinks under the heightmap at its
## edges, so it needs no seam, and the terrain under it stays what the physics,
## the occlusion bake and every placement read.
##
## Drawn with the terrain's own material ([TerrainRenderer]) — the same splat,
## photographs, light and fog by construction, so the rock and the ground it
## comes out of cannot disagree. Vertex colour is that material's: R the sky the
## rock's own relief leaves the vertex (the terrain's baked occlusion at its XZ
## is multiplied in at load, with the torchlight in G and the trees' shadow in
## B), and A one minus how much of a ledge it is — see the shader's
## `cliff_ledge_snow`.
##
## Kept off the play area, so nothing that races touches it. The one reader
## besides the renderer is the chase camera, which must not sink into a face
## standing proud of the heightmap: [method lift_at].
@tool
class_name CliffSet
extends Resource

## The rock, in world coordinates, a piece per few tens of metres so the
## renderer can cull them.
@export var meshes: Array[ArrayMesh] = []
## The heightmap grid the lift is on: [member CourseData.heightmap_size].
@export var grid_size: Vector2i = Vector2i.ZERO
## [member CourseData.world_size].
@export var world_size: Vector2 = Vector2.ONE
## How far the rock stands above the heightmap, at the grid vertices it stands
## over: [member lift_index] names the vertex (row-major), [member lift] the
## metres. Sparse, since the rock covers a sliver of the course.
@export var lift_index: PackedInt32Array = PackedInt32Array()
@export var lift: PackedFloat32Array = PackedFloat32Array()

var _lift_at: Dictionary[int, float] = {}

## The most the rock stands above the heightmap round (x, z), in metres; zero
## off the rock. The highest of the four grid vertices round the point, which
## errs high, and high is the safe side for a camera.
func lift_at(x: float, z: float) -> float:
	if lift_index.is_empty():
		return 0.0
	if _lift_at.is_empty():
		for i: int in lift_index.size():
			_lift_at[lift_index[i]] = lift[i]
	var gx: float = x / world_size.x * float(grid_size.x - 1)
	var gz: float = -z / world_size.y * float(grid_size.y - 1)
	var x0: int = clampi(int(floor(gx)), 0, grid_size.x - 1)
	var z0: int = clampi(int(floor(gz)), 0, grid_size.y - 1)
	var x1: int = mini(x0 + 1, grid_size.x - 1)
	var z1: int = mini(z0 + 1, grid_size.y - 1)
	var w: int = grid_size.x
	return maxf(maxf(_lift_at.get(z0 * w + x0, 0.0), _lift_at.get(z0 * w + x1, 0.0)),
		maxf(_lift_at.get(z1 * w + x0, 0.0), _lift_at.get(z1 * w + x1, 0.0)))
