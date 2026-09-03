## Everything compiles, and every scene still loads.
##
## [b]Why this exists.[/b] The rest of the suite is written against the
## simulation, which is deliberately node-free — so it never loads
## `race_scene.gd`, `main_menu.gd`, `course_menu.gd`, `race_hud.gd` or any of
## the other shell scripts. A parse error in any of them passed 3638 assertions
## and was only found by taking a screenshot. That is the wrong feedback loop
## for something a compiler already knows.
##
## Two ways for a script to be broken that this catches and nothing else did:
## an outright parse error, and a `class_name` that has not made it into
## `.godot/global_script_class_cache.cfg` — which is gitignored and only
## rewritten by an editor pass, so a newly added class is "not declared in the
## current scope" for every headless run until somebody opens the editor.
class_name TestScripts
extends RefCounted

## Walked with [DirAccess], which finds nothing under `res://` in an exported
## build — see the trap list. That is fine and permanent here: the headless
## suite only ever runs from source, and there is no reason to ship it.
const ROOTS: PackedStringArray = ["res://scripts", "res://addons", "res://tests"]

## Loaded whole, because a scene is where a script and the node it expects to be
## attached to finally meet.
const SCENES: PackedStringArray = [
	"res://scenes/main_menu.tscn",
	"res://scenes/race.tscn",
	"res://scenes/course_menu.tscn",
	"res://scenes/character_menu.tscn",
	"res://scenes/settings_menu.tscn",
	"res://scenes/key_log.tscn",
]

static func run(t: TestCase) -> void:
	t.begin("every script compiles")
	var paths := PackedStringArray()
	for root: String in ROOTS:
		_collect(root, paths)
	t.ok(paths.size() > 50, "the walk found the source tree (%d scripts)" % paths.size())
	var broken := PackedStringArray()
	for path: String in paths:
		# [b]Not a null check.[/b] `ResourceLoader.load` hands back a perfectly
		# real [GDScript] object for a file that failed to parse — it prints the
		# error and carries on, and `load() != null` passes. What actually
		# separates a compiled script from a broken one is whether it can be
		# instantiated; `reload(true)` returning `ERR_PARSE_ERROR` says the same
		# thing more expensively and re-runs `@tool` scripts to do it.
		#
		# `CACHE_MODE_REUSE`, emphatically. Forcing a fresh compile with
		# `CACHE_MODE_IGNORE` replaces the [GDScript] object under every live
		# instance of it — including the autoloads and the script running this
		# loop — and segfaults the engine. Reuse is the right answer anyway: the
		# only scripts already in the cache at this point are the ones that had
		# to compile for the process to be running at all.
		var script: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		if script == null or not (script as Script).can_instantiate():
			broken.push_back(path.get_file())
	t.ok(broken.is_empty(), "every script compiles (broken: %s)" % ", ".join(broken))

	t.begin("every scene loads")
	for path: String in SCENES:
		if not ResourceLoader.exists(path):
			t.ok(false, "%s is missing" % path)
			continue
		# Loading a [PackedScene] compiles every script attached anywhere in it,
		# which is the half a bare script walk cannot reach: a `class_name` that
		# resolves in isolation but not from the scene that names it.
		var packed: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		t.ok(packed is PackedScene, "%s loads" % path.get_file())

static func _collect(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_collect(full, out)
		elif entry.ends_with(".gd"):
			out.push_back(full)
		entry = dir.get_next()
	dir.list_dir_end()
