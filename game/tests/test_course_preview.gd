## The editor preview of a course — the ground the object markers stand on.
##
## `scripts/course/course_preview.gd` exists so a course can be authored in the
## 3D viewport instead of by guessing coordinates and running the game. It is
## editor-only code, which is exactly why it is tested headlessly: nothing about
## opening a scene in the editor is asserted anywhere, and the one property that
## really matters — that a preview leaves no trace in the saved scene — is
## invisible until somebody opens `course.tscn`, saves it out of habit, and
## commits a hillside's worth of preview nodes.
##
## The preview is loaded by path rather than by class name (see the script's own
## comment for why), so this file loads it the same way.
class_name TestCoursePreview
extends RefCounted

const PREVIEW_SCRIPT := "res://scripts/course/course_preview.gd"
## Bunny Hill: small, carries all fourteen object types, and the course every
## other look-test is written against.
const COURSE_SCENE := "res://courses/bunny_hill/course.tscn"

static func run(t: TestCase) -> void:
	var packed: PackedScene = load(COURSE_SCENE)
	var root: CourseRoot = packed.instantiate()
	var before: int = _packed_node_count(root)

	var preview: Node3D = load(PREVIEW_SCRIPT).new()
	root.add_child(preview, false, Node.INTERNAL_MODE_BACK)
	preview.build(root.course_data, root.object_prefabs, root.get_node_or_null("Objects"))

	_the_ground_exists(t, preview)
	_the_objects_in_range_are_drawn(t, preview, root)
	_snapping_puts_markers_on_the_surface(t, preview, root)
	_none_of_it_is_saved(t, root, before)

	preview.clear_object_previews()
	root.free()

static func _the_ground_exists(t: TestCase, preview: Node3D) -> void:
	t.begin("course preview/the ground")
	var terrain: TerrainRenderer = preview.terrain
	t.ok(terrain != null, "the preview builds a TerrainRenderer")
	if terrain == null:
		return
	# Built around the start gate, so a scene opened without touching the editor
	# camera still has something under it.
	t.ok(terrain.chunk_count() > 0, "chunks exist at the start position")
	t.ok(preview.surface != null, "and a HeightmapSurface to build them from")
	# The environment half: without it the shaders, which are all
	# `ambient_light_disabled`, render the shaded side of the hill black.
	t.ok(preview.get_node_or_null("PreviewSun") != null,
		"the preset's sun is in the preview")
	t.ok(preview.get_node_or_null("PreviewEnvironment") != null,
		"and its sky")

static func _the_objects_in_range_are_drawn(t: TestCase, preview: Node3D,
		root: CourseRoot) -> void:
	t.begin("course preview/the objects")
	var radius: float = preview.get_script().get_script_constant_map()["PREVIEW_RADIUS"]
	var center := Vector3(root.course_data.start_position.x, 0.0,
		-root.course_data.start_position.y)
	var expected: int = 0
	for group: Node in root.get_node("Objects").get_children():
		var prefab: ObjectPrefab = root.object_prefabs.get(group.name, null)
		if prefab == null or prefab.mesh == null:
			continue
		for marker: Node in group.get_children():
			var m: Node3D = marker as Node3D
			if m == null:
				continue
			if Vector2(m.position.x - center.x, m.position.z - center.z).length() <= radius:
				expected += 1
	t.ok(expected > 0, "Bunny Hill has objects within %d m of the start" % int(radius))
	t.ok(preview.shown_count() == expected,
		"every one of them has a preview mesh (%d of %d)"
			% [preview.shown_count(), expected])

static func _snapping_puts_markers_on_the_surface(t: TestCase, preview: Node3D,
		root: CourseRoot) -> void:
	t.begin("course preview/snap to ground")
	var moved: int = preview.snap_markers_to_ground()
	t.ok(moved > 0, "the importer's y = 0 markers are not on the hill")
	var surface: HeightmapSurface = preview.surface
	var checked: int = 0
	for group: Node in root.get_node("Objects").get_children():
		for marker: Node in group.get_children():
			var m: Node3D = marker as Node3D
			if m == null:
				continue
			# Same resolution `CourseRoot.build_runtime` uses, so what the editor
			# shows and what the race builds are the same height.
			t.eq_f(m.position.y, surface.height_at(m.position.x, m.position.z), 1e-4,
				"marker sits on the surface")
			checked += 1
			if checked >= 32:
				return
	t.ok(checked > 0, "there were markers to check")

## The property the whole design turns on: preview nodes are internal and
## unowned, and [PackedScene] packs neither, so a scene saved with a preview up
## is byte-identical to one saved without.
static func _none_of_it_is_saved(t: TestCase, root: CourseRoot, before: int) -> void:
	t.begin("course preview/nothing is saved")
	t.ok(_packed_node_count(root) == before,
		"repacking the course after a preview yields the same node count (%d)" % before)

static func _packed_node_count(root: Node) -> int:
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		return -1
	return packed.get_state().get_node_count()
