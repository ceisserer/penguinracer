## Where everybody on the hill is this tick, for the one thing a racer's own
## simulation cannot see: the other racers.
##
## [RacePhysics] is handed a [SurfaceProvider] and two [ObjectGrid]s and that is
## the whole world — the trees and the herring are course furniture, loaded once
## and never moved. Another penguin is neither: it is a body being integrated in
## a [RacePhysics] of its own, on the same tick, and the only place the two meet
## is here. The scene rebuilds this once per tick from every racer's published
## [RacerState] and hands the same object to all of them, so a field of ten
## costs one array of ten and not ten arrays of ten.
##
## [b]Ghosts are not in it.[/b] A ghost is a recording of a run that already
## happened, not a body on the hill, and a player who could be shoved off their
## line by their own best time would be racing something that cannot be raced
## back. [method Racer.collides] is the predicate; this class only ever sees
## what survived it.
##
## [b]Deliberately an [Array] and not a [PackedVector3Array].[/b] A packed array
## is copy-on-write, so handing one to nine opponents would hand out nine
## snapshots that stop tracking the moment the scene writes to its own.
## [member positions] is shared by reference — [AIInputSource.rivals] holds this
## very array — and written in place.
class_name RacerField
extends RefCounted

## Body centres, in the order the scene registered them. Index i belongs to the
## racer whose [member RacePhysics.rival_index] is i.
var positions: Array[Vector3] = []
## Velocities alongside them. Carried because a collision between two bodies is
## about how fast they are closing, not about where they are: a racer drifting
## alongside at the same speed is touching, not colliding, and only the relative
## velocity tells the two apart.
var velocities: Array[Vector3] = []

func size() -> int:
	return positions.size()

func is_empty() -> bool:
	return positions.is_empty()

## Make room for [param n] racers, keeping the array identity so that everything
## already holding it keeps tracking.
func resize(n: int) -> void:
	positions.resize(n)
	velocities.resize(n)

## Publish one racer's instant.
func set_state(index: int, p: Vector3, v: Vector3) -> void:
	positions[index] = p
	velocities[index] = v

func position_of(index: int) -> Vector3:
	return positions[index]

func velocity_of(index: int) -> Vector3:
	return velocities[index]
