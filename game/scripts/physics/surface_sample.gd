## One terrain query result. Reused in place by the physics inner loop —
## `SurfaceProvider.sample_into()` writes into a caller-owned instance so the
## ODE substep loop allocates nothing.
class_name SurfaceSample
extends RefCounted

## Terrain height in metres at the queried (x, z), including the analytic base slope.
var height: float = 0.0
## Unit surface normal, smooth-blended across the heightmap.
var normal: Vector3 = Vector3.UP
## Splat-weighted friction coefficient (0.2 ice .. 0.7 rock).
var friction: float = 0.35
## Splat-weighted compression depth in metres (0.01 .. 0.11).
var compression_depth: float = 0.05
## Dominant terrain layer index — for footstep sounds and particle gating.
var terrain_id: int = 0
## Whether the dominant layer emits kick-up particles.
var emits_particles: bool = true

func copy_from(other: SurfaceSample) -> void:
	height = other.height
	normal = other.normal
	friction = other.friction
	compression_depth = other.compression_depth
	terrain_id = other.terrain_id
	emits_particles = other.emits_particles
