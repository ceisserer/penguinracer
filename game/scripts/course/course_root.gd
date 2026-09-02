## Root node of an imported course scene.
##
## Owns the bridge between authoring and runtime: the `Objects` subtree holds
## one [Marker3D] per tree/herring — arbitrary position, rotation and scale, all
## editable in the editor — and at load those transforms are baked into
## [MultiMesh] batches for drawing and [ObjectGrid]s for collision, after which
## the markers are dropped. Authoring is per-instance; drawing is instanced.
@tool
class_name CourseRoot
extends Node3D

@export var course_data: CourseData

## Prefab table, keyed by the object-type name used in `Objects/<name>`.
@export var object_prefabs: Dictionary[String, ObjectPrefab] = {}

var surface: HeightmapSurface
var trees: ObjectGrid
var items: ObjectGrid
## Index into [member items] → the MultiMesh instance slot, so collected herring
## can be hidden without rebuilding the batch.
var _item_instances: Dictionary[int, Array] = {}
## The transform each of those slots was built with, so a restart can put a
## collected herring back. Kept here rather than re-read off the MultiMesh
## because [method hide_item] has already overwritten it by then.
var _item_transforms: Dictionary[int, Transform3D] = {}

## Build the runtime representation. Safe to call once, from the race scene.
func build_runtime() -> void:
	assert(course_data != null, "CourseRoot has no CourseData")
	surface = HeightmapSurface.from_course(course_data)
	trees = ObjectGrid.new()
	items = ObjectGrid.new()

	var objects_root: Node = get_node_or_null("Objects")
	if objects_root == null:
		trees.build()
		items.build()
		return

	for group: Node in objects_root.get_children():
		var type_name: String = group.name
		var prefab: ObjectPrefab = object_prefabs.get(type_name, null)
		var transforms: Array[Transform3D] = []
		for marker: Node in group.get_children():
			if marker is not Node3D:
				continue
			var m: Node3D = marker
			var p: Vector3 = m.position
			# The heightmap is the authority for Y: it has just been resampled,
			# and the markers only ever stored a planar position.
			p.y = surface.height_at(p.x, p.z)
			var diam: float = m.scale.x
			var height: float = m.scale.y
			var xf := Transform3D(Basis().rotated(Vector3.UP, m.rotation.y), p)
			transforms.push_back(xf.scaled_local(Vector3(diam, height, diam)))
			if prefab != null and prefab.collidable:
				trees.add(p, diam, height, 0)
			elif prefab == null or prefab.collectable:
				var idx: int = items.add(p + Vector3(0.0, height * 0.5, 0.0), diam, height, 0)
				_item_instances[idx] = [type_name, transforms.size() - 1]
				_item_transforms[idx] = transforms[transforms.size() - 1]
		if prefab != null and prefab.mesh != null and not transforms.is_empty():
			_add_batch(type_name, prefab, transforms)

	trees.build()
	items.build()

func _add_batch(type_name: String, prefab: ObjectPrefab, transforms: Array[Transform3D]) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = prefab.mesh
	mm.instance_count = transforms.size()
	for i: int in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Batch_%s" % type_name
	mmi.multimesh = mm
	mmi.material_override = prefab.material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

## Hide a collected herring by collapsing its instance transform.
func hide_item(index: int) -> void:
	if not _item_instances.has(index):
		return
	var entry: Array = _item_instances[index]
	var mmi: MultiMeshInstance3D = get_node_or_null("Batch_%s" % entry[0])
	if mmi == null:
		return
	mmi.multimesh.set_instance_transform(entry[1], Transform3D().scaled(Vector3.ZERO))

## Put every collected herring back, for a restart.
##
## Two halves, and both are needed: the [ObjectGrid] holds whether an item is
## still there for the simulation, and the [MultiMesh] holds whether it is still
## there for the eye. Neither used to be undone, so pressing `r` raced a course
## that had been stripped of everything the previous run picked up — invisible
## until there was a ghost of that run collecting fish that were no longer
## there.
func reset_items() -> void:
	items.reset_collectables()
	for index: int in _item_transforms:
		var entry: Array = _item_instances[index]
		var mmi: MultiMeshInstance3D = get_node_or_null("Batch_%s" % entry[0])
		if mmi != null:
			mmi.multimesh.set_instance_transform(entry[1], _item_transforms[index])

## Discard the authoring markers once the batches and grids exist.
func release_markers() -> void:
	var objects_root: Node = get_node_or_null("Objects")
	if objects_root != null and not Engine.is_editor_hint():
		objects_root.queue_free()
