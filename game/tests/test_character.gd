## The migrated character: the skeleton the importer builds, the skin that binds
## the placeholder mesh to it, and the keyframe animations that pose it.
##
## Everything here is generated, and every failure mode it covers is silent. An
## unskinned mesh renders perfectly — as a statue. A flat bone list poses each
## joint correctly and moves nothing below it. A rotation track on the wrong axis
## produces a pose, just not the one in the file. And a tag the file stops
## naming has to fall back to zero rather than hold, which is the difference
## between Tux putting his flippers down before he lies on them and racing the
## whole course with them out.
class_name TestCharacter
extends RefCounted

const RIG_SCENE := "res://resources/characters/tux/tux.tscn"
## Sum of `[time]` over every frame of `char/tux/start.lst` but the last: the
## original goes inactive the moment its cursor reaches the final key.
const START_LENGTH := 4.5

static func run(t: TestCase) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		t.begin("character")
		t.ok(false, "no scene tree to attach the rig to")
		return
	var rig: CharacterRig = (load(RIG_SCENE) as PackedScene).instantiate() as CharacterRig
	if rig == null:
		t.begin("character")
		t.ok(false, "%s is not a CharacterRig" % RIG_SCENE)
		return
	tree.root.add_child(rig)

	_skeleton(t, rig)
	_skin(t, rig)
	_model_frame(t, rig)
	_start_path(t, rig)
	_start_poses(t, rig)

	tree.root.remove_child(rig)
	rig.free()

static func _skeleton(t: TestCase, rig: CharacterRig) -> void:
	t.begin("character/skeleton")
	var sk: Skeleton3D = rig.skeleton
	t.ok(sk != null, "the rig has a Skeleton3D")
	if sk == null:
		return
	# The synthetic root is what the body and breast spheres hang off; every
	# `[joint]` in shape.lst follows it.
	t.ok(sk.get_bone_count() == 16, "root plus fifteen joints (%d)" % sk.get_bone_count())
	t.ok(sk.find_bone("root") == 0, "the root bone is bone 0")
	t.ok(sk.get_bone_parent(0) == -1, "the root bone has no parent")

	# The chains, not just the names. A flat list keeps every name and loses
	# every consequence: a rotated hip that leaves the knee behind.
	for pair: Array in [["head", "neck"], ["neck", "root"],
			["left_elbow", "left_shldr"], ["left_hand", "left_elbow"],
			["left_knee", "left_hip"], ["left_ankle", "left_knee"],
			["right_knee", "right_hip"], ["right_ankle", "right_knee"],
			["left_shldr", "root"], ["left_hip", "root"], ["tail", "root"]]:
		var child: int = sk.find_bone(pair[0])
		var parent: int = sk.find_bone(pair[1])
		t.ok(child >= 0 and parent >= 0 and sk.get_bone_parent(child) == parent,
			"%s hangs off %s" % [pair[0], pair[1]])
		# Skeleton3D walks bones in index order, so a child ahead of its parent
		# would pose against a stale global.
		t.ok(child > parent, "%s comes after %s in the bone list" % [pair[0], pair[1]])

static func _skin(t: TestCase, rig: CharacterRig) -> void:
	t.begin("character/skin")
	var mi: MeshInstance3D = rig.get_node_or_null(^"Placeholder") as MeshInstance3D
	t.ok(mi != null and mi.mesh != null, "the placeholder mesh is there")
	if mi == null or mi.mesh == null:
		return
	t.ok(mi.skin != null, "the mesh is skinned")
	t.ok(mi.skin != null and mi.skin.get_bind_count() == rig.skeleton.get_bone_count(),
		"one bind per bone")
	t.ok(mi.get_node_or_null(mi.skeleton) == rig.skeleton, "the skin points at the skeleton")

	var arrays: Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	t.ok(bones.size() == verts.size() * 4, "four bone slots per vertex")
	t.ok(weights.size() == verts.size() * 4, "four weight slots per vertex")

	# Rigid binding: one bone per vertex at full weight, which is what a sphere
	# hanging off exactly one chain of matrices in the original amounts to.
	var total: float = 0.0
	var moving: int = 0
	for i: int in range(0, weights.size(), 4):
		total += weights[i] + weights[i + 1] + weights[i + 2] + weights[i + 3]
		if bones[i] > 0:
			moving += 1
	t.eq_f(total, float(verts.size()), 0.01, "every vertex weighs exactly 1")
	t.ok(moving > 0 and moving < verts.size(),
		"some vertices ride a joint and some ride the root (%d of %d)" % [moving, verts.size()])

static func _model_frame(t: TestCase, rig: CharacterRig) -> void:
	t.begin("character/model frame")
	# +Y forward and +Z belly in the original, +Y up and −Z forward here.
	var b: Basis = rig.transform.basis
	t.eq_v(b * Vector3.UP, Vector3.FORWARD, 1e-5, "the model's forward is Godot's −Z")
	t.eq_v(b * Vector3.BACK, Vector3.DOWN, 1e-5, "the model's belly faces down")

	# What the intro uses to place the character: the parent basis has to undo
	# the rig's own turn so that a rotation authored in the model frame lands
	# unchanged in the world.
	var wanted := Basis(Vector3.UP, deg_to_rad(37.0))
	t.ok((rig.parent_basis_for(wanted) * b).is_equal_approx(wanted),
		"parent_basis_for cancels the rig's own basis")

static func _start_path(t: TestCase, rig: CharacterRig) -> void:
	t.begin("character/start path")
	var path: KeyframePath = rig.path_for(&"start")
	t.ok(path != null, "tux has a start clip with root motion")
	if path == null:
		return
	t.ok(path.times.size() == 11, "eleven keys, one per line of start.lst")
	# `[time]` is a duration, not a timestamp. Read the other way the clip
	# collapses onto a single frame and nothing moves.
	t.eq_f(path.duration(), START_LENGTH, 1e-4, "the clip runs for 4.5 s")

	# He starts 1.25 m across the slope and 1 m behind the line, and finishes on
	# it — `[pos] -1.25 0.25 1.00` through `[pos] 0.00 0.00 0.00`.
	t.eq_v(path.offset_at(0.0), Vector3(-1.25, 0.25, 1.0), 1e-4, "the first key is the far side")
	t.eq_v(path.offset_at(START_LENGTH), Vector3.ZERO, 1e-4, "the last key is the start point")
	t.eq_v(path.offset_at(2.25), Vector3(-0.125, 0.25, 1.0), 1e-4, "halfway between two keys")
	t.eq_v(path.offset_at(START_LENGTH * 2.0), Vector3.ZERO, 1e-4, "past the end holds the last key")

	# Yaw 100 while waddling across, 180 once turned to face down the hill, and
	# pitch 110 flat on his belly. Yaw is about +Y and pitch about +X, composed
	# in that order.
	t.ok(path.basis_at(0.0).is_equal_approx(Basis(Vector3.UP, deg_to_rad(100.0))),
		"the first key is a pure 100 degree yaw")
	var last: Basis = path.basis_at(START_LENGTH)
	t.ok(last.is_equal_approx(Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, deg_to_rad(110.0))),
		"the last key is yaw 180 then pitch 110")
	# The pose the race takes over from: belly down, head down the hill.
	t.eq_v(last * Vector3.BACK, Vector3(0.0, -sin(deg_to_rad(110.0)), -cos(deg_to_rad(110.0))),
		1e-4, "the belly ends up facing the snow")
	t.eq_v(last * Vector3.UP, Vector3(0.0, cos(deg_to_rad(110.0)), -sin(deg_to_rad(110.0))),
		1e-4, "and the head down the hill")

static func _start_poses(t: TestCase, rig: CharacterRig) -> void:
	t.begin("character/start poses")
	var sk: Skeleton3D = rig.skeleton
	var player: AnimationPlayer = rig.animation_player
	t.ok(player != null and player.has_animation(&"start"), "the rig can play the start clip")
	if player == null or not player.has_animation(&"start"):
		return
	t.eq_f(player.get_animation(&"start").length, START_LENGTH, 1e-4,
		"the animation is as long as the path")

	var hip: int = sk.find_bone("left_hip")
	var shoulder: int = sk.find_bone("left_shldr")
	var rest_hip: Quaternion = sk.get_bone_rest(hip).basis.get_rotation_quaternion()
	var rest_shoulder: Quaternion = sk.get_bone_rest(shoulder).basis.get_rotation_quaternion()

	t.ok(rig.play_clip(&"start"), "the clip starts")
	# A bone track is an absolute pose, so every key is the rest times the
	# file's rotation — `[hip] -25 20` on the first line of start.lst.
	rig.seek_clip(0.0)
	t.ok(sk.get_bone_pose_rotation(hip).is_equal_approx(
			rest_hip * Quaternion(Vector3.BACK, deg_to_rad(-25.0))),
		"the first key turns the left hip 25 degrees about its own Z")

	# The seventh line drops `[sh]` entirely, and a dropped tag is a zero: the
	# original resets every joint each frame and reapplies only what the file
	# names. Holding the last value instead would leave the flippers out.
	rig.seek_clip(3.0)
	t.ok(sk.get_bone_pose_rotation(shoulder).is_equal_approx(rest_shoulder),
		"a frame with no [sh] puts the shoulder back at rest")

	# `[hip] -40 -40` on the last line, lying down.
	rig.seek_clip(START_LENGTH)
	t.ok(sk.get_bone_pose_rotation(hip).is_equal_approx(
			rest_hip * Quaternion(Vector3.BACK, deg_to_rad(-40.0))),
		"the last key folds the legs back for the slide")

	# And the race gets a rig back in the pose shape.lst left it in.
	rig.stop_clip()
	t.ok(sk.get_bone_pose_rotation(hip).is_equal_approx(rest_hip),
		"stopping the clip restores the rest pose")
	t.ok(not player.is_playing(), "and stops the player")
