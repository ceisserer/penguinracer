## One penguin on the hill, whoever is driving it.
##
## Everything the race draws about a racer lives here: the character rig, the
## body transform, the herring count, the finish. What is [i]not[/i] here is
## where the motion comes from — that is the split between the two subclasses,
## and it is the whole of the multiplayer design:
##
## [codeblock]
## Racer                  identity, rig, interpolated presentation
##   ├── SimulatedRacer   owns a RacePhysics, fed by an InputSource
##   │                    → the local player, and later an AI opponent
##   └── PlaybackRacer    owns a RacerStateStream, read by time
##                        → a ghost, and a remote peer
## [/codeblock]
##
## A racer being simulated and a racer being played back are not two modes of
## one thing with an `if` between them; they are two ways of filling the same
## [RacerState], and [method present] cannot tell which happened. That is what
## keeps a ghost from needing a second physics world and a remote peer from
## needing to agree with us about anything but the clock.
##
## The node's own transform is the body's: the rig hangs under it at the origin,
## already turned out of ETR's model frame by the importer. See
## [method CharacterRig.parent_basis_for].
class_name Racer
extends Node3D

enum Kind {
	## The player, simulated from the keyboard.
	LOCAL,
	## A computer opponent: simulated exactly as the player is, from an
	## [AIInputSource] rather than a keyboard. See [AISkill] for what a
	## difficulty setting is allowed to move, which is nothing in the physics.
	AI,
	## A recorded run of the player's own, played back beside them.
	GHOST,
	## Another machine's racer, played back from its snapshots.
	REMOTE,
}

## Emitted when this racer crosses the line. The scene owns what happens next —
## the result panel is the local player's business and a remote finish is a
## line on the HUD.
signal finished_race(racer: Racer)

var kind: Kind = Kind.LOCAL
var display_name: String = ""
## Directory name of the character being raced as, e.g. `tux`.
var character_dir: String = ""
## Multiplayer peer id for [constant Kind.REMOTE], 0 for everyone else.
var peer_id: int = 0

## Where the racer is now, in simulation time.
var state := RacerState.new()
## Where it was at the previous tick. [method present] reads between the two,
## which is what keeps a 60 Hz simulation smooth on a 144 Hz screen.
var previous := RacerState.new()

var rig: CharacterRig
var herring: int = 0
var finished: bool = false
var finish_time: float = 0.0

## The CPU snow mirror the simulation reads, or `null` off a course. Read here
## for one reason only — see [method _drawn_snow_lift].
var snow_cpu: SnowField

## The interpolated pose [method present] draws. A member so that drawing eight
## racers costs no allocation.
var _view := RacerState.new()

## The snow lift at this tick and at the one before it, the two ends
## [method present] interpolates between. See [method _drawn_snow_lift] for
## what the lift is and [method sample_snow_lift] for why it is a pair of
## numbers rather than a call.
var _lift: float = 0.0
var _lift_previous: float = 0.0

func is_simulated() -> bool:
	return false

func is_local() -> bool:
	return kind == Kind.LOCAL

## Whether this racer is a body the others bounce off.
##
## Everyone actually on the hill is — the player, the computer opponents, and a
## remote peer, who is played back here but is being simulated for real on the
## machine that owns them, where the same contact is resolved from the other
## side. A [constant Kind.GHOST] is not: it is a recording of a run that has
## already happened, and a player shoved off their line by their own best time
## would be losing to something that cannot lose back. It is also the one racer
## on the hill that cannot be pushed, so a collision with it could only ever go
## one way.
##
## Read by [method RaceScene._refresh_rivals] when it builds the [RacerField];
## this is the whole of "no collisions in ghost mode".
func collides() -> bool:
	return kind != Kind.GHOST

## Advance by one simulation tick. Overridden; the base racer stands still.
func advance(_dt: float) -> void:
	pass

## Draw the racer [param alpha] of the way from the previous tick to this one.
##
## Called once per rendered frame, where [method advance] is called once per
## simulation tick, and the two rates are deliberately not the same. Without
## this the penguin would move in 60 discrete jumps a second whatever the
## monitor was doing, which is visible as a shimmer at 144 Hz and as a stutter
## at any rate that is not a multiple of 60.
func present(alpha: float) -> void:
	_view.interpolate(previous, state, alpha)
	global_basis = Basis(_view.orientation)
	global_position = _view.position + Vector3(0.0,
		PhysConst.TUX_Y_CORR + lerpf(_lift_previous, _lift, alpha), 0.0)

## Put the racer somewhere without interpolating through where it used to be.
## Used by a restart, and by the start animation, which writes the body
## transform itself rather than going through the simulation.
##
## [param position] is where the body is to be drawn, i.e. it already carries
## [constant PhysConst.TUX_Y_CORR] — the caller took it off a keyframe rather
## than out of a simulation. The snow lift is added on the same terms as in
## [method present], so the two agree about a hill with a trench in it.
func apply_pose(position: Vector3, basis: Basis) -> void:
	global_basis = basis
	state.position = position - Vector3(0.0, PhysConst.TUX_Y_CORR, 0.0)
	_lift = _drawn_snow_lift(state.position)
	_lift_previous = _lift
	global_position = position + Vector3(0.0, _lift, 0.0)
	state.orientation = basis.get_rotation_quaternion()
	previous.copy_from(state)

## Read the trench under the racer, once, on the tick.
##
## [b]The lift cannot be sampled at frame time.[/b] [SnowField] is simulation
## state and it is written from inside the substep loop, so a live read from
## [method present] mixes two clocks: on a frame where a tick ran, the depth has
## just jumped by everything that tick stamped; on the frames between, the
## interpolated body slides forward onto texels its own stamp has not reached
## yet and the depth falls back. Measured on Bunny Hill at 145 fps that is a
## 60 Hz sawtooth of about 4 mm — twenty to seventy times the frame-to-frame
## curvature of the simulated position it is added to, and the whole of the
## nervous shiver it produced. The [i]physics[/i] never showed it: the same
## steps arrive under a 1500 N/m spring whose natural frequency is about
## 1.4 Hz, which filters them out. Drawing added them back unfiltered.
##
## So it obeys architecture rule 7 like every other quantity that affects what
## the race looks like: sampled on the tick at the tick's position, kept as two
## ends, and interpolated by [method present]. Called for every racer, not just
## the ones that stamp — a ghost and a peer are drawn against the same trench.
func sample_snow_lift() -> void:
	_lift_previous = _lift
	_lift = _drawn_snow_lift(state.position)

## Metres to lift the drawn body by so that it rides on the snow that is drawn.
##
## DEVIATION: the original has no snow deformation, so there is nothing here to
## port — this exists because ours is deliberately two fields that do not match
## (architecture rule 3). [SnowField] subtracts the trench from the height the
## simulation stands on, so a carving racer really does sit up to
## [member SnowField.max_trench] lower than the bare heightmap. The [i]drawn[/i]
## surface does not go down with it: the terrain mesh is displaced from the GPU
## field instead, on ~0.5 m vertices that cannot resolve a 0.45 m contact patch,
## so the trench reads in lighting and not in silhouette. Draw the body against
## the physics height and it sinks into snow that was never dug out — half the
## penguin, at a 0.1 m trench.
##
## This is the exact inverse of what [method SnowField.apply_to_sample] took
## off, sampled where the body is: outside the 64 m window both are zero, so the
## two stay in step wherever the racer is. It goes away the day the near-field
## mesh is dense enough to carry the trench in geometry — that is the whole of
## the "reads in lighting but not in silhouette" gap, and the day it closes this
## should be deleted rather than retuned.
func _drawn_snow_lift(at: Vector3) -> float:
	return 0.0 if snow_cpu == null else snow_cpu.depth_at(at.x, at.z)

## Collapse the interpolation window onto the current state, so the next frame
## draws where the racer is rather than sliding there from where it was.
##
## The lift is re-read rather than carried over: a restart hands out a fresh
## [SnowField], so the pair kept from the last race is a trench on a hill that
## no longer has one.
func snap() -> void:
	previous.copy_from(state)
	_lift = _drawn_snow_lift(state.position)
	_lift_previous = _lift

## The pose the last [method present] drew — the interpolated one, not the
## simulation's. What the camera and the streaming window follow, so that they
## follow the penguin the player can see rather than the one the last tick
## computed.
func view_state() -> RacerState:
	return _view

## The terrain normal under the racer, for whatever wants to lean with the
## slope. [constant Vector3.UP] for a racer that is not simulated here: a
## snapshot does not carry it, and nothing that follows a remote racer needs it.
func surface_normal() -> Vector3:
	return Vector3.UP

# ------------------------------------------------------------------
#                            the rig
# ------------------------------------------------------------------

## Instance the character scene under this racer.
##
## Anything the catalog cannot resolve leaves the racer with no rig rather than
## failing — [RaceScene] keeps its stand-in capsule for the local player, and a
## ghost with no rig simply is not shown. See
## [method CharacterCatalog.scene_path_for].
func install_character(scene_path: String) -> bool:
	for child: Node in get_children():
		if child is CharacterRig:
			child.queue_free()
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return false
	var instance: Node3D = (load(scene_path) as PackedScene).instantiate()
	add_child(instance)
	rig = instance as CharacterRig
	return rig != null

## The capsule the race drew before there were characters, and still draws when
## there is no rig to draw instead.
##
## Reached by a narrowed export that ships no character at all, and by a config
## file naming one that has been deleted — see
## [method CharacterCatalog.scene_path_for], which returns empty rather than
## failing. A grey capsule is a racer you can see and steer; nothing is not.
func install_fallback_mesh() -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.22
	mesh.height = 0.9
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.1, 0.1, 0.12)
	material.roughness = 0.7
	var instance := MeshInstance3D.new()
	instance.name = "FallbackMesh"
	instance.mesh = mesh
	instance.material_override = material
	# The capsule stands along its own Y; the body frame it hangs in has Y as
	# the surface normal and −Z as the direction of travel, so it has to be laid
	# down to point the way the racer is going. Same turn the rig root bakes.
	instance.transform = Transform3D(Basis(Vector3(1, 0, 0), -PI / 2.0), Vector3.ZERO)
	add_child(instance)

## Render the rig as something you can see the course through.
##
## A ghost has to read as a ghost from behind, at speed, against snow. Alpha
## alone is not enough — a 45 % penguin over white terrain is still a dark
## silhouette — so the tint goes into the albedo too, and shadows come off:
## a ghost casting a shadow on the slope is the tell that gives away that it is
## a solid object the player might expect to hit.
##
## The material is duplicated per surface rather than replaced with a flat one,
## because the character mesh is vertex-coloured (`vertex_color_use_as_albedo`)
## and a plain [StandardMaterial3D] would throw away every marking on it.
func make_translucent(tint: Color) -> void:
	for node: Node in _mesh_instances(self):
		var mesh_instance: MeshInstance3D = node
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for surface: int in mesh_instance.get_surface_override_material_count():
			var source: Material = mesh_instance.get_active_material(surface)
			var mat: StandardMaterial3D = null
			if source is StandardMaterial3D:
				mat = (source as StandardMaterial3D).duplicate() as StandardMaterial3D
			else:
				mat = StandardMaterial3D.new()
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = tint
			mesh_instance.set_surface_override_material(surface, mat)

static func _mesh_instances(root: Node) -> Array[Node]:
	var found: Array[Node] = []
	for child: Node in root.get_children():
		if child is MeshInstance3D:
			found.push_back(child)
		found.append_array(_mesh_instances(child))
	return found
