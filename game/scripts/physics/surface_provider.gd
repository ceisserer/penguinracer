## Interface between the physics simulation and whatever defines the ground.
##
## `RacePhysics` talks only to this, which is what keeps it node-free and
## headless-testable, and what lets `CompositeSurface` (heightmap + raycast
## against extra geometry: bridges, rails, tunnels) drop in later without
## touching a single caller. See godot-port-plan.md §4.2.
class_name SurfaceProvider
extends RefCounted

## Fill `out` with the surface state at world (x, z). Must not allocate.
func sample_into(_x: float, _z: float, _out: SurfaceSample) -> void:
	push_error("SurfaceProvider.sample_into() is abstract")

## Height only — cheaper path for object placement and camera collision.
func height_at(_x: float, _z: float) -> float:
	push_error("SurfaceProvider.height_at() is abstract")
	return 0.0

## Signed distance from `pos` to the local tangent plane at (pos.x, pos.z).
## Positive means airborne. Mirrors ETR's `DistanceToPlane(GetLocalCoursePlane(pos), pos)`.
func distance_to_surface(pos: Vector3, sample: SurfaceSample) -> float:
	return sample.normal.dot(pos - Vector3(pos.x, sample.height, pos.z))
