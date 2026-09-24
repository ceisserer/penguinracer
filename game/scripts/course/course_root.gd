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
## Index into [member items] → `[type_name, MultiMesh instance slot]`, so a
## collected herring can be hidden without rebuilding the batch.
var _item_instances: Dictionary[int, Array] = {}
## The instanced batch per object type, so hiding a herring is a dictionary
## lookup rather than a string format and a `get_node_or_null` down the scene
## tree — which a restart on a fish-heavy course paid once per collected item.
var _batches: Dictionary[String, MultiMeshInstance3D] = {}
## The conifer and bare-tree types, drawn by a [Forest] each instead of a
## batch above.
var _forests: Array[Forest] = []
## The transform each of those slots was built with, so a restart can put a
## collected herring back. Kept here rather than re-read off the MultiMesh
## because [method hide_item] has already overwritten it by then.
var _item_transforms: Dictionary[int, Transform3D] = {}
## Whether the standing objects cast into the sun's shadow map. Off until
## [method set_casting_shadows] says otherwise, because the default has to be
## the one that is safe on every renderer — see [RenderBackend].
var _casts_shadows: bool = false

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
			var collidable: bool = prefab != null and prefab.collidable
			# Only the crossed quads need turning; an item billboards and has no
			# plane of its own to share.
			var yaw: float = m.rotation.y + (decorrelating_yaw(p) if collidable else 0.0)
			var xf := Transform3D(Basis().rotated(Vector3.UP, yaw), p)
			transforms.push_back(xf.scaled_local(Vector3(diam, height, diam)))
			if collidable:
				trees.add(p, diam, height, 0)
			elif prefab == null or prefab.collectable:
				var idx: int = items.add(p + Vector3(0.0, height * 0.5, 0.0), diam, height, 0)
				_item_instances[idx] = [type_name, transforms.size() - 1]
				_item_transforms[idx] = transforms[transforms.size() - 1]
		if prefab != null and (prefab.conifer or prefab.bare) and not transforms.is_empty() \
				and not Engine.is_editor_hint():
			_add_forest(type_name, prefab, transforms)
		elif prefab != null and prefab.mesh != null and not transforms.is_empty():
			_add_batch(type_name, prefab, transforms)

	trees.build()
	items.build()

## Widest turn [method decorrelating_yaw] gives a crossed-quad object, either
## way. Small enough that a tree still presents ETR's face to a racer coming
## down the fall line; wide enough that widening it further stops helping —
## measured, ±45° leaves the same flicker as ±20°, because what is left by then
## is the alpha-scissor cutout edge crawling and not two planes fighting.
const YAW_JITTER := deg_to_rad(20.0)

## A per-object yaw, hashed from where the object stands.
##
## DEVIATION: ETR turns a collidable object by nothing at all — `DrawTrees`
## emits one quad spanning X and one spanning Z, both world-axis-aligned — and
## every object it places sits on an object-map cell. So a row of trees shares
## its z to the last bit, and the X-quads of two trees standing closer together
## than the sum of their radii are *exactly coplanar over the overlap*. No depth
## buffer resolves that: the pair swaps which one wins from frame to frame as
## the camera moves, over a region as large as a whole tree. It reads as trees
## flickering. `challenge_one` has 1255 such pairs, 522 of them along x = 50.505
## — the wall of trees down the left of the course, which is where it shows.
##
## The geometry stays the original's: two fixed planes at 90 degrees, turned
## toward nothing, the silhouette and the collision cylinder unchanged. All this
## does is stop the whole forest from sharing four planes. Hashed from the
## position rather than drawn from a [RandomNumberGenerator] so a course looks
## the same on every machine and in every run — a capture has to be comparable.
static func decorrelating_yaw(p: Vector3) -> float:
	# Quantised to a centimetre first: two objects on the same cell centre must
	# hash the same way whatever float arithmetic got them there.
	var k: int = roundi(p.x * 100.0) * 73856093 ^ roundi(p.z * 100.0) * 19349663
	return (float(k & 0xffff) / 32768.0 - 1.0) * YAW_JITTER

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
	mmi.cast_shadow = _shadow_setting()
	add_child(mmi)
	_batches[type_name] = mmi

## A conifer or bare-tree type as a [Forest]: the same transforms the crossed
## quads would have had, drawn as a 3D tree.
func _add_forest(type_name: String, prefab: ObjectPrefab, transforms: Array[Transform3D]) -> void:
	var mat: ShaderMaterial = prefab.material as ShaderMaterial
	var texture: Texture2D = mat.get_shader_parameter("albedo_texture") if mat != null else null
	var forest := Forest.new()
	forest.name = "Forest_%s" % type_name
	add_child(forest)
	forest.build(texture, transforms,
		Forest.Species.CONIFER if prefab.conifer else Forest.Species.BARE)
	forest.set_shadow_casting(_shadow_setting())
	_forests.push_back(forest)

## The weather the forests sway and hold snow in. Presentation only; called
## every frame by [method RaceScene._present].
func set_weather(wind: WindField, snow_grade: int) -> void:
	for forest: Forest in _forests:
		forest.set_weather(wind, snow_grade)

## Hand every object batch the environment's ambient.
##
## Same reason the terrain needs it and the same number — the object shaders are
## `ambient_light_disabled` too, because ETR clamps a tree exactly as it clamps a
## slope. See `shaders/etr_illumination.gdshaderinc`.
##
## The material is a shared [ShaderMaterial] on the [ObjectPrefab] resource, so
## this writes through to every course that uses the same prefab. Harmless: one
## course is loaded at a time and every one of them sets this on load.
func set_ambient(ambient: Vector3) -> void:
	for mmi: MultiMeshInstance3D in _batches.values():
		var mat: ShaderMaterial = mmi.material_override as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("etr_ambient", ambient)
	for forest: Forest in _forests:
		forest.set_ambient(ambient)

## Turn the standing objects' shadow casting on or off for the whole course.
##
## Called by [method RaceScene._apply_environment] once the preset is known,
## because two of the three things that decide it — the renderer and the sky —
## are not visible from here. Batches built later take it from
## [member _casts_shadows] instead, which is what keeps a course streamed in
## mid-race in step with one built at load.
func set_casting_shadows(enabled: bool) -> void:
	_casts_shadows = enabled
	for mmi: MultiMeshInstance3D in _batches.values():
		mmi.cast_shadow = _shadow_setting()
	for forest: Forest in _forests:
		forest.set_shadow_casting(_shadow_setting())

## `DOUBLE_SIDED` rather than `ON`, and that is not a detail. A tree here is two
## crossed quads with `cull_disabled` and an alpha cutout, so it has no back
## face to cull and no volume to be inside: the default `ON` renders the shadow
## map with back faces culled, which for a single-sided card means the half of
## every tree facing away from the sun casts nothing and the forest throws a
## shadow made of stripes.
func _shadow_setting() -> GeometryInstance3D.ShadowCastingSetting:
	if _casts_shadows:
		return GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Hide a collected herring by collapsing its instance transform.
func hide_item(index: int) -> void:
	if not _item_instances.has(index):
		return
	var entry: Array = _item_instances[index]
	var mmi: MultiMeshInstance3D = _batches.get(entry[0], null)
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
		var mmi: MultiMeshInstance3D = _batches.get(entry[0], null)
		if mmi != null:
			mmi.multimesh.set_instance_transform(entry[1], _item_transforms[index])

## Discard the authoring markers once the batches and grids exist.
func release_markers() -> void:
	var objects_root: Node = get_node_or_null("Objects")
	if objects_root != null and not Engine.is_editor_hint():
		objects_root.queue_free()
