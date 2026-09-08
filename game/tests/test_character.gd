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
##
## Tux is checked in detail, against the numbers in `char/tux/`. The other four
## are checked against the contract they share with him — see
## [method _every_character] for why that contract is weaker than his joint list
## and not by an oversight.
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
	_racing_pose(t, rig)

	tree.root.remove_child(rig)
	rig.free()

	_catalog(t)
	_every_character(t, tree)

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

# ------------------------------------------------------------------
#                       the procedural layer
# ------------------------------------------------------------------

## `AdjustJoints`: the pose a racer holds while racing, which is every frame of
## every race that is not the start animation.
##
## Checked against the numbers in `tux.cpp` rather than against a screenshot,
## because every failure mode here is a penguin that still looks like a penguin.
## A flipper on the wrong side, a head that turns the wrong way, an angle that
## saturates one line early — none of them are visible as *wrong*, only as not
## quite the original.
static func _racing_pose(t: TestCase, rig: CharacterRig) -> void:
	t.begin("character/racing pose")
	var sk: Skeleton3D = rig.skeleton
	var left: int = sk.find_bone("left_shldr")
	var right: int = sk.find_bone("right_shldr")
	var rest_left: Quaternion = sk.get_bone_rest(left).basis.get_rotation_quaternion()
	var rest_right: Quaternion = sk.get_bone_rest(right).basis.get_rotation_quaternion()

	# Coasting: flippers in, and the standing angles the original applies
	# unconditionally — a neck at -50 and a head at -30 are what make the
	# penguin look down the hill rather than at his own feet.
	rig.adjust_joints(0.0, false, 0.0, 0.0, 0.0, 0.0)
	t.ok(sk.get_bone_pose_rotation(left).is_equal_approx(rest_left),
		"coasting leaves the flippers at rest")
	_at(t, sk, "neck", -50.0, "the neck is held at -50 whatever the racer is doing")
	_at(t, sk, "head", -30.0, "and the head at -30")
	_at(t, sk, "left_hip", -20.0, "the hips sit at -20 at a standstill")
	_at(t, sk, "left_ankle", -20.0, "and the ankles at -20")

	# Braking puts both flippers all the way out, to MAX_ARM_ANGLE2.
	rig.adjust_joints(0.0, true, 0.0, 0.0, 0.0, 0.0)
	_at(t, sk, "left_shldr", CharacterRig.MAX_ARM_ANGLE, "braking puts the left flipper out")
	_at(t, sk, "right_shldr", CharacterRig.MAX_ARM_ANGLE, "and the right one")

	# Steering is one-sided: `max(-turn, 0)` and `max(turn, 0)`, so a full turn
	# raises one flipper and leaves the other alone. That asymmetry is the whole
	# of what a steering animation looks like from behind.
	rig.adjust_joints(1.0, false, 0.0, 0.0, 0.0, 0.0)
	_at(t, sk, "right_shldr", CharacterRig.MAX_ARM_ANGLE, "a right turn puts the right flipper out")
	t.ok(sk.get_bone_pose_rotation(left).is_equal_approx(rest_left),
		"and leaves the left one in")
	_at(t, sk, "tail", 20.0, "the tail swings with the lean")
	_at(t, sk, "head", -30.0, "the head keeps its pitch", -70.0)
	rig.adjust_joints(-1.0, false, 0.0, 0.0, 0.0, 0.0)
	_at(t, sk, "left_shldr", CharacterRig.MAX_ARM_ANGLE, "a left turn is the mirror of it")
	t.ok(sk.get_bone_pose_rotation(right).is_equal_approx(rest_right),
		"with the right flipper in")
	_at(t, sk, "head", -30.0, "and the head turned the other way", 70.0)

	# Braking and steering share one limit: the sum is clamped at
	# MAX_ARM_ANGLE2 before the flap is added past it.
	rig.adjust_joints(1.0, true, 0.0, 0.0, 0.0, 0.0)
	_at(t, sk, "right_shldr", CharacterRig.MAX_ARM_ANGLE,
		"braking through a turn does not stack past the limit")

	# The paddle stroke is half a sine, so its peak is at phase 0.5 and both
	# ends are the rest pose — which is what lets the phase reset without a step.
	rig.adjust_joints(0.0, false, 0.5, 0.0, 0.0, 0.0)
	_at(t, sk, "left_shldr", CharacterRig.MAX_ARM_ANGLE,
		"mid-stroke the flipper is at the limit", -CharacterRig.MAX_EXT_PADDLING_ANGLE)
	rig.adjust_joints(0.0, false, 1.0, 0.0, 0.0, 0.0)
	t.ok(sk.get_bone_pose_rotation(left).is_equal_approx(rest_left),
		"a stroke that has run out is back at rest")

	# A flap is added past the clamp, so a jump reads even out of a brake, and
	# it too starts and ends at the rest pose.
	rig.adjust_joints(0.0, true, 0.0, 0.0, 0.0, 0.0)
	var braced: Quaternion = sk.get_bone_pose_rotation(left)
	rig.adjust_joints(0.0, true, 0.0, 0.0, 0.0, 1.0 / 6.0)
	t.ok(not sk.get_bone_pose_rotation(left).is_equal_approx(braced),
		"a flap moves a flipper that is already at the braking limit")
	rig.adjust_joints(0.0, false, 0.0, 0.0, 0.0, 0.0)
	t.ok(sk.get_bone_pose_rotation(left).is_equal_approx(rest_left),
		"and phase zero of a flap is the rest pose")

	# Speed tucks the knees and extends the ankles, each with its own ceiling.
	# Past it the pose stops changing — a racer at 40 m/s and one at 60 hold the
	# same legs.
	rig.adjust_joints(0.0, false, 0.0, 20.0, 0.0, 0.0)
	_at(t, sk, "left_knee", -30.0, "20 m/s tucks the knees")
	_at(t, sk, "left_ankle", 0.0, "and extends the ankles")
	rig.adjust_joints(0.0, false, 0.0, 100.0, 0.0, 0.0)
	_at(t, sk, "left_knee", -45.0, "the knee saturates at 35 m/s")
	_at(t, sk, "left_ankle", 30.0, "the ankle at 50")

	# The legs brace against the ground pushing back, over ±20 degrees. The
	# clamp matters more than the slope: a landing is thousands of newtons, and
	# without it the hips fold through the body.
	var past_limit: float = CharacterRig.FORCE_PER_DEGREE * CharacterRig.MAX_FORCE_ANGLE * 1.5
	rig.adjust_joints(0.0, false, 0.0, 0.0, past_limit, 0.0)
	_at(t, sk, "left_hip", -20.0 + CharacterRig.MAX_FORCE_ANGLE,
		"a hard landing braces the hips to the limit")
	rig.adjust_joints(0.0, false, 0.0, 0.0, -past_limit, 0.0)
	_at(t, sk, "left_hip", -20.0 - CharacterRig.MAX_FORCE_ANGLE,
		"and going light over a crest folds them the other way")
	rig.adjust_joints(0.0, false, 0.0, 0.0, CharacterRig.FORCE_PER_DEGREE * 5.0, 0.0)
	_at(t, sk, "left_hip", -15.0, "below the limit it is linear in the force")

	# The start animation and this write the same joints. The original never has
	# both: `CIntro` poses through the keyframe and `CRacing` through here.
	t.ok(rig.play_clip(&"start"), "the start clip plays")
	rig.seek_clip(0.0)
	var posed: Quaternion = sk.get_bone_pose_rotation(left)
	rig.adjust_joints(1.0, true, 0.5, 30.0, 3000.0, 0.5)
	t.ok(sk.get_bone_pose_rotation(left).is_equal_approx(posed),
		"and a clip that is playing is not fought over")
	rig.stop_clip()

## Assert that [param joint] is posed at [param z] degrees about its own Z and
## [param y] about its own Y, on top of its rest — the form every one of these
## poses takes. See [method CharacterRig._pose].
static func _at(t: TestCase, sk: Skeleton3D, joint: String, z: float,
		message: String, y: float = 0.0) -> void:
	var index: int = sk.find_bone(joint)
	if index < 0:
		t.ok(false, "%s (no %s bone)" % [message, joint])
		return
	var want: Quaternion = sk.get_bone_rest(index).basis.get_rotation_quaternion() \
		* Quaternion(Vector3.BACK, deg_to_rad(z)) * Quaternion(Vector3.UP, deg_to_rad(y))
	var got: Quaternion = sk.get_bone_pose_rotation(index)
	if not got.is_equal_approx(want):
		message = "%s (expected z %.1f y %.1f, off by %.2f degrees)" % [
			message, z, y, rad_to_deg(got.angle_to(want))]
		t.ok(false, message)
		return
	t.ok(true, message)

# ------------------------------------------------------------------
#                          all five of them
# ------------------------------------------------------------------

## The generated index the shell picks from, and the fallbacks that keep a
## missing character from being a missing player.
static func _catalog(t: TestCase) -> void:
	t.begin("character/catalog")
	var cat: CharacterCatalog = CharacterCatalog.load_default()
	t.ok(cat.entries.size() == 5, "five characters (%d)" % cat.entries.size())

	# The order is `characters.lst`'s, not alphabetical: ETR's spinner opens on
	# index 0 and index 0 has to be Tux for that to mean anything.
	var order: PackedStringArray = []
	for e: CharacterListing in cat.entries:
		order.push_back(e.dir)
	t.ok(order == PackedStringArray(["tux", "trixi", "boris", "samuel", "beastie"]),
		"in the file's order, Tux first (%s)" % ", ".join(order))
	t.ok(cat.entries[0].display_name == "Tux", "with the name the file gives, untranslated")

	t.ok(cat.index_of("beastie") == 4, "index_of finds a row")
	t.ok(cat.index_of("nobody") == 0, "and a name nobody has opens on index 0")
	t.ok(cat.find("trixi") != null and cat.find("trixi").dir == "trixi", "find returns the row")
	t.ok(cat.find("nobody") == null, "and null for one that is not there")

	# The fallback chain. A hand-edited config file and a `--character=` typo
	# both arrive at scene_path_for, and both have to come back with a rig.
	t.ok(cat.scene_path_for("boris").ends_with("boris/boris.tscn"), "a named character resolves")
	t.ok(cat.scene_path_for("nobody").ends_with("tux/tux.tscn"),
		"and an unknown one falls back to Tux rather than to no character at all")
	t.ok(cat.scene_path_for("").ends_with("tux/tux.tscn"), "so does an empty name")

	for e: CharacterListing in cat.entries:
		t.ok(ResourceLoader.exists(e.scene_path), "%s has a scene" % e.dir)
		# The 128x128 the registration screen frames. It is copied in the
		# assets stage, so a listing with no preview means the two importer
		# stages ran out of order.
		t.ok(e.preview() != null, "%s has a preview" % e.dir)

## Every character, not just Tux. The four others are not variants of him: they
## have their own `shape.lst` and their own four keyframe lists, and the data
## disagrees with itself between them — four of the five spell the left elbow
## `[joint] joint` (the `[name] joint for left_elbow` beside it gives the slip
## away), and Samuel has no right leg, no hands and no tail at all. The original
## simply does not rotate a joint it cannot find: `CCharShape::RotateNode` looks
## the name up in `NodeIndex` and returns false. So the contract checked here is
## the weak one that is actually true of all five — a skinned mesh, a rooted
## skeleton, and a start clip whose length matches its root motion — rather than
## Tux's joint list, which is only Tux's.
static func _every_character(t: TestCase, tree: SceneTree) -> void:
	t.begin("character/every character")
	for listing: CharacterListing in CharacterCatalog.load_default().entries:
		var rig: CharacterRig = (load(listing.scene_path) as PackedScene).instantiate() as CharacterRig
		if rig == null:
			t.ok(false, "%s instantiates as a CharacterRig" % listing.dir)
			continue
		tree.root.add_child(rig)
		var name: String = listing.dir

		var sk: Skeleton3D = rig.skeleton
		t.ok(sk != null and sk.get_bone_count() > 1, "%s: a skeleton with joints on it" % name)
		var mi: MeshInstance3D = rig.get_node_or_null(^"Placeholder") as MeshInstance3D
		t.ok(mi != null and mi.skin != null and mi.get_node_or_null(mi.skeleton) == sk,
			"%s: the mesh is skinned to it" % name)

		if sk != null:
			# Exactly one root, and every other bone after its parent — a flat
			# list poses each joint correctly and moves nothing below it.
			var roots: int = 0
			var ordered: bool = true
			for b: int in sk.get_bone_count():
				var parent: int = sk.get_bone_parent(b)
				if parent < 0:
					roots += 1
				elif parent >= b:
					ordered = false
			t.ok(roots == 1, "%s: one root bone (%d)" % [name, roots])
			t.ok(ordered, "%s: every bone comes after its parent" % name)
			# The joints every character does have, and that AdjustJoints will
			# reach for when the procedural layer lands.
			for joint: String in ["neck", "head", "left_shldr", "left_hip", "left_knee"]:
				t.ok(sk.find_bone(joint) >= 0, "%s: has a %s" % [name, joint])

		# The two halves of a migrated clip are sampled off one clock, so a
		# length that disagrees with its root motion is a rig that drifts.
		var player: AnimationPlayer = rig.animation_player
		for clip: StringName in [&"start", &"finish", &"wonrace", &"lostrace"]:
			t.ok(player != null and player.has_animation(clip),
				"%s: has the %s clip" % [name, clip])
			var path: KeyframePath = rig.path_for(clip)
			t.ok(path != null and path.times.size() > 1,
				"%s: %s carries root motion" % [name, clip])
			if player != null and player.has_animation(clip) and path != null:
				t.eq_f(player.get_animation(clip).length, path.duration(), 1e-4,
					"%s: %s is as long as its path" % [name, clip])

		# The procedural layer runs for whoever is on the hill, and four of the
		# five are missing at least one joint it names — Samuel has no right leg
		# and no tail at all. A joint that is not there is skipped, exactly as
		# `RotateNode` skips a name its index cannot resolve, so this has to be
		# a pose and not a crash.
		if sk != null:
			rig.adjust_joints(1.0, true, 0.5, 30.0, 3000.0, 0.25)
			var shoulder: int = sk.find_bone("left_shldr")
			t.ok(shoulder < 0 or not sk.get_bone_pose_rotation(shoulder).is_equal_approx(
					sk.get_bone_rest(shoulder).basis.get_rotation_quaternion()),
				"%s: the joints it does have are posed" % name)

		# The model frame is baked per scene, so it is per character to get
		# wrong — and getting it wrong is a penguin riding the hill upright.
		t.eq_v(rig.transform.basis * Vector3.UP, Vector3.FORWARD, 1e-5,
			"%s: the model's forward is Godot's -Z" % name)

		tree.root.remove_child(rig)
		rig.free()
