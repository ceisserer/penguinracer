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

## How far the body is dropped along its own up axis so the belly sits in the
## contact patch instead of on top of it.
##
## DEVIATION: the original draws the character at `cpos.y + TUX_Y_CORR` and
## nothing else. This used to be a local offset on the rig node, which is the
## same thing while the body's up axis is the surface normal — but during the
## start animation it is not, and an offset along a standing penguin's local Y
## walked him sideways out of his own footprints. Applied here, by the node that
## writes the body transform, which is now the only place that does.
const CHARACTER_SINK := 0.1

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

## The interpolated pose [method present] draws. A member so that drawing eight
## racers costs no allocation.
var _view := RacerState.new()

func is_simulated() -> bool:
	return false

func is_local() -> bool:
	return kind == Kind.LOCAL

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
	var body := Basis(_view.orientation)
	global_basis = body
	global_position = _view.position \
		+ Vector3(0.0, PhysConst.TUX_Y_CORR, 0.0) - body.y * CHARACTER_SINK

## Put the racer somewhere without interpolating through where it used to be.
## Used by a restart, and by the start animation, which writes the body
## transform itself rather than going through the simulation.
func apply_pose(position: Vector3, basis: Basis) -> void:
	global_basis = basis
	global_position = position - basis.y * CHARACTER_SINK
	state.position = position - Vector3(0.0, PhysConst.TUX_Y_CORR, 0.0)
	state.orientation = basis.get_rotation_quaternion()
	previous.copy_from(state)

## Collapse the interpolation window onto the current state, so the next frame
## draws where the racer is rather than sliding there from where it was.
func snap() -> void:
	previous.copy_from(state)

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
