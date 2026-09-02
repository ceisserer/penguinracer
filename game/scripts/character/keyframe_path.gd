## The root motion of one migrated ETR keyframe animation.
##
## An ETR keyframe file (`char/<name>/start.lst` and friends) drives two things
## at once: the joint angles of the character, and the position and orientation
## of the body as a whole. The joints migrate cleanly to a Godot [Animation] on
## the [Skeleton3D] — that is what `animations.res` holds. The root motion does
## not, and this is where it lands instead.
##
## Two reasons it cannot be a track like the others:
##
## 1. [b]The height is not in the file.[/b] `CKeyframe::Update` computes
##    `pos.y = interp(...) + Course.FindYCoord(pos.x, pos.z)` — the authored Y is
##    a clearance above the terrain, and the terrain is course data the animation
##    knows nothing about. A baked position track would walk Tux through the hill
##    on all 44 courses but the one it was baked against.
## 2. [b]The rotation is in world space.[/b] The original applies yaw, pitch and
##    roll to node 0, whose frame [i]is[/i] the world, so the animation and the
##    simulation write the same transform. Here that transform belongs to the
##    node the race scene positions the character with, which is above the rig
##    and outside anything an [AnimationPlayer] on the rig can reach.
##
## So the caller samples this against the same clock it runs the pose animation
## on, adds the terrain height, and places the character itself. See
## [method RaceScene._apply_intro_pose].
##
## Angles are degrees and composed exactly as `CKeyframe::InterpolateKeyframe`
## composes them — yaw about +Y, then pitch about +X, then roll about +Z, in the
## [b]model frame the rig was authored in[/b] (ETR's +Y forward, +Z belly), not
## in Godot's. [method CharacterRig.parent_basis_for] is what converts.
class_name KeyframePath
extends Resource

## Seconds from the start of the clip to each key. Cumulative: the file stores
## `[time]` as the duration the frame is held for, and the original advances a
## cursor by it, so the last entry is the length of the whole clip.
@export var times: PackedFloat32Array = PackedFloat32Array()
## Offset from the reference point, in metres, on the world axes. `x` is across
## the slope, `y` is clearance above the terrain, `z` is along it.
@export var offsets: PackedVector3Array = PackedVector3Array()
## Yaw, pitch and roll in degrees, one per key.
@export var angles: PackedVector3Array = PackedVector3Array()

## Length of the clip. The original stops on reaching the last key rather than
## holding it for its own `[time]`, and so does this.
func duration() -> float:
	return times[times.size() - 1] if times.size() > 0 else 0.0

func is_empty() -> bool:
	return times.size() < 2

## Offset from the reference point at [param t], linearly interpolated.
func offset_at(t: float) -> Vector3:
	if offsets.is_empty():
		return Vector3.ZERO
	var i: int = _segment(t)
	if i < 0:
		return offsets[offsets.size() - 1]
	return offsets[i].lerp(offsets[i + 1], _fraction(t, i))

## Body rotation at [param t], in the rig's own model frame.
func basis_at(t: float) -> Basis:
	if angles.is_empty():
		return Basis.IDENTITY
	var a: Vector3 = angles[angles.size() - 1]
	var i: int = _segment(t)
	if i >= 0:
		a = angles[i].lerp(angles[i + 1], _fraction(t, i))
	# Ry(yaw) * Rx(pitch) * Rz(roll): the order `InterpolateKeyframe` applies
	# them to node 0 in, which is not any of Godot's Euler orders.
	return Basis(Vector3.UP, deg_to_rad(a.x)) \
		* Basis(Vector3.RIGHT, deg_to_rad(a.y)) \
		* Basis(Vector3.BACK, deg_to_rad(a.z))

## Index of the key at or before [param t], or -1 past the end.
func _segment(t: float) -> int:
	for i: int in range(times.size() - 1):
		if t < times[i + 1]:
			return i
	return -1

func _fraction(t: float, i: int) -> float:
	var span: float = times[i + 1] - times[i]
	if span <= 0.0001:
		return 0.0
	return clampf((t - times[i]) / span, 0.0, 1.0)
