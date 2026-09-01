## Headless driver for [ETRImport].
##
##     godot --headless --path game --script res://addons/etr_import/run_import.gd -- \
##         --source=/path/to/etr-0.8.4/data --stage=assets [--course=bunny_hill] [--force]
##
## Use `tools/import_all.sh`, which runs both stages with the editor's own
## `--import` pass in between so freshly written PNGs become loadable textures.
extends SceneTree

func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var source: String = ""
	var stage: String = ETRImport.STAGE_ASSETS
	var only_course: String = ""
	var groups: PackedStringArray = PackedStringArray()
	var force: bool = false

	for a: String in args:
		if a.begins_with("--source="):
			source = a.trim_prefix("--source=")
		elif a.begins_with("--stage="):
			stage = a.trim_prefix("--stage=")
		elif a.begins_with("--course="):
			only_course = a.trim_prefix("--course=")
		elif a.begins_with("--group="):
			groups.push_back(a.trim_prefix("--group="))
		elif a == "--force":
			force = true

	if source.is_empty():
		source = ProjectSettings.globalize_path("res://").path_join("../etr-0.8.4/data")
	source = source.simplify_path()
	if not DirAccess.dir_exists_absolute(source):
		printerr("source data directory not found: ", source)
		quit(2)
		return
	if groups.is_empty():
		groups = PackedStringArray(["default", "extras"])

	var imp := ETRImport.new()
	imp.source_dir = source
	imp.force = force

	print("PenguinRacer importer — stage '%s', source %s" % [stage, source])
	var start: int = Time.get_ticks_msec()

	# Audio first: the sound bank names the cues `terrains.lst` refers to, so
	# importing it before the layers is what turns a typo into a warning.
	imp.import_audio(stage)
	var terrains: Dictionary = imp.import_terrains(stage)
	var object_types: Array[Dictionary] = imp.import_objects(stage)
	var prefabs: Dictionary[String, ObjectPrefab] = {}
	if stage == ETRImport.STAGE_RESOURCES:
		prefabs = imp.build_object_prefabs(object_types)
	imp.import_environments(stage)
	imp.import_characters(stage)

	var imported: int = 0
	for group: String in groups:
		var list_path: String = source.path_join("courses").path_join(group).path_join("courses.lst")
		for rec: Dictionary in SPList.load_file(list_path):
			var dir_name: String = SPList.get_str(rec, "dir")
			if dir_name.is_empty():
				continue
			if not only_course.is_empty() and dir_name != only_course:
				continue
			var list_name: String = SPList.get_str(rec, "name")
			if imp.import_course(group, dir_name, stage, terrains, object_types,
					prefabs, list_name):
				imported += 1

	if stage == ETRImport.STAGE_RESOURCES:
		imp.write_course_catalog()
		imp.import_events()
		imp.import_translations()

	var elapsed: int = Time.get_ticks_msec() - start
	print("")
	print("stage '%s' done: %d courses, %d warnings, %.1f s"
		% [stage, imported, imp.warnings.size(), float(elapsed) / 1000.0])
	quit(0)
