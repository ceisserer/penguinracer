## One racer at one instant, in the only form the rest of the game reads.
##
## This is the seam the whole multi-racer design turns on. A racer that is being
## simulated here fills it from [RacePhysics]; a ghost fills it from a recorded
## stream; a network peer fills it from a packet. [Racer] draws whatever is in
## it and cannot tell the three apart — which is what lets one presentation path
## serve the player, an AI opponent, a replay and a remote peer.
##
## [b]The float layout is a file format and a wire format.[/b] A ghost on disk
## and a snapshot on the wire are both [constant FLOATS] of these, in the order
## [method write_into] writes them. Appending a field is a version bump; moving
## one silently reinterprets every stored ghost.
class_name RacerState
extends RefCounted

## Floats per sample in the packed layout: time, position (3), orientation (4),
## velocity (3), progress, flags, herring.
const FLOATS := 14

const FLAG_AIRBORNE := 1 << 0
const FLAG_PADDLING := 1 << 1
const FLAG_BRAKING := 1 << 2
const FLAG_FINISHED := 1 << 3
const FLAG_JUMPING := 1 << 4

## Seconds since the race started. Not the wall clock and not the tick index:
## a stream is sampled by time so that a 20 Hz recording can drive a 144 Hz
## screen, and so that a peer running at another framerate still lines up.
var time: float = 0.0
## The point mass, exactly as [member RacePhysics.pos] holds it — the body
## centre, before [constant PhysConst.TUX_Y_CORR] lifts it to where the model
## is drawn. How deep the belly rides is the terrain's `[depth]` and the spring
## under it, both of which are already in here.
var position: Vector3 = Vector3.ZERO
var orientation: Quaternion = Quaternion.IDENTITY
## Carried because the presentation wants it (spray, camera lag, the HUD's
## km/h) and because a snapshot without it cannot be extrapolated across a
## dropped packet.
var velocity: Vector3 = Vector3.ZERO
## Metres down the course, i.e. `-position.z`. Stored rather than derived so
## that "where was the ghost when I was here" is a search over one column, and
## so a later course layout with a non-monotonic Z can redefine it in one place.
var progress: float = 0.0
var flags: int = 0
var herring: int = 0

func copy_from(other: RacerState) -> void:
	time = other.time
	position = other.position
	orientation = other.orientation
	velocity = other.velocity
	progress = other.progress
	flags = other.flags
	herring = other.herring

## Read the simulation. The one place [RacePhysics] state is turned into the
## form everything downstream consumes.
func capture(physics: RacePhysics, race_time: float, herring_count: int) -> void:
	time = race_time
	position = physics.pos
	orientation = physics.orientation
	velocity = physics.vel
	progress = -physics.pos.z
	herring = herring_count
	flags = 0
	if physics.airborne:
		flags |= FLAG_AIRBORNE
	if physics.is_paddling:
		flags |= FLAG_PADDLING
	if physics.is_braking:
		flags |= FLAG_BRAKING
	if physics.finished:
		flags |= FLAG_FINISHED
	if physics.jumping:
		flags |= FLAG_JUMPING

func airborne() -> bool:
	return (flags & FLAG_AIRBORNE) != 0

func finished() -> bool:
	return (flags & FLAG_FINISHED) != 0

func speed() -> float:
	return velocity.length()

## Fill this state from two bracketing samples. [param t] is 0 at [param a] and
## 1 at [param b].
##
## The discrete fields take the earlier sample rather than being rounded: a
## herring is collected once, at a known instant, and interpolating the count
## would show 3.5 fish. `slerp` on the orientation is right here where it is
## wrong for the chase camera — this is one body's rotation between two poses of
## itself, not two look-at frames, so there is no roll to pick up.
func interpolate(a: RacerState, b: RacerState, t: float) -> void:
	var k: float = clampf(t, 0.0, 1.0)
	time = lerpf(a.time, b.time, k)
	position = a.position.lerp(b.position, k)
	orientation = a.orientation.slerp(b.orientation, k)
	velocity = a.velocity.lerp(b.velocity, k)
	progress = lerpf(a.progress, b.progress, k)
	flags = a.flags
	herring = a.herring

# ------------------------------------------------------------------
#                     the packed layout
# ------------------------------------------------------------------

## Append this sample to [param buf]. See the class note: the order is the
## format.
func write_into(buf: PackedFloat32Array) -> void:
	buf.push_back(time)
	buf.push_back(position.x)
	buf.push_back(position.y)
	buf.push_back(position.z)
	buf.push_back(orientation.x)
	buf.push_back(orientation.y)
	buf.push_back(orientation.z)
	buf.push_back(orientation.w)
	buf.push_back(velocity.x)
	buf.push_back(velocity.y)
	buf.push_back(velocity.z)
	buf.push_back(progress)
	buf.push_back(float(flags))
	buf.push_back(float(herring))

## Read the sample starting at [param offset] out of [param buf].
##
## The quaternion is normalised on the way out: float32 storage denormalises it
## by about a part in 10^7, which a `slerp` between two such samples turns into
## a visible scale wobble on a mesh that is bound to it.
func read_from(buf: PackedFloat32Array, offset: int) -> void:
	time = buf[offset]
	position = Vector3(buf[offset + 1], buf[offset + 2], buf[offset + 3])
	orientation = Quaternion(buf[offset + 4], buf[offset + 5],
		buf[offset + 6], buf[offset + 7]).normalized()
	velocity = Vector3(buf[offset + 8], buf[offset + 9], buf[offset + 10])
	progress = buf[offset + 11]
	flags = int(buf[offset + 12])
	herring = int(buf[offset + 13])

## This sample on its own, ready to hand to a transport. A snapshot RPC sends
## exactly this; [RacerStateStream] stores a concatenation of them.
func to_floats() -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	write_into(buf)
	return buf

## Whether [param buf] is a plausible single sample. A snapshot arrives from
## another process and is not to be trusted with an array index.
static func is_valid_packet(buf: PackedFloat32Array) -> bool:
	if buf.size() != FLOATS:
		return false
	for v: float in buf:
		if not is_finite(v):
			return false
	return true
