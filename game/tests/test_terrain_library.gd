## Tests for the imported terrain library — the generated [TerrainLayer] set
## under `res://resources/terrain`.
##
## The importer writes one resource per *record* in `terrains.lst`, keyed by a
## unique id rather than by `[name]`. The file declares `pave04` three times
## with three textures, three colour keys and only one `[sound]`, which a
## name-keyed importer collapses into whichever record it reads last. Nothing
## downstream can see that happen: the survivor still loads and still has a
## friction, and no shipped course paints any of the three colour keys, so no
## capture and no physics test would ever have gone red. The guard has to live
## here, against the file.
class_name TestTerrainLibrary
extends RefCounted

const TERRAIN_DIR := "res://resources/terrain"

## The ETR data tree is outside `res://` and absent from an exported build, so
## the file-level cross-check is skipped when it is not reachable.
static func _source_lst() -> String:
	return ProjectSettings.globalize_path("res://") \
		.path_join("../etr-0.8.4/data/terrains/terrains.lst").simplify_path()

static func run(t: TestCase) -> void:
	var layers: Array[TerrainLayer] = _load_all(t)
	_identity(t, layers)
	_matches_source(t, layers)
	_repeated_name(t, layers)

static func _load_all(t: TestCase) -> Array[TerrainLayer]:
	t.begin("terrain library/on disk")
	var out: Array[TerrainLayer] = []
	var dir := DirAccess.open(TERRAIN_DIR)
	t.ok(dir != null, "the terrain layers are on disk")
	if dir == null:
		return out
	for file: String in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var layer: TerrainLayer = load(TERRAIN_DIR.path_join(file))
		t.ok(layer != null, "%s loads as a TerrainLayer" % file)
		if layer == null:
			continue
		t.ok(String(layer.id) == file.get_basename(),
			"%s carries its own id (%s)" % [file, layer.id])
		out.push_back(layer)
	return out

static func _identity(t: TestCase, layers: Array[TerrainLayer]) -> void:
	t.begin("terrain library/identity")
	var ids: Dictionary[StringName, int] = {}
	var indices: Dictionary[int, StringName] = {}
	var colors: Dictionary[int, StringName] = {}
	for layer: TerrainLayer in layers:
		t.ok(not ids.has(layer.id), "id '%s' is used once" % layer.id)
		ids[layer.id] = 1
		t.ok(layer.legacy_index >= 0, "'%s' knows its record index" % layer.id)
		t.ok(not indices.has(layer.legacy_index),
			"record %d became one layer ('%s')" % [layer.legacy_index, layer.id])
		indices[layer.legacy_index] = layer.id
		# The colour key is the original's real identity: a course paints it and
		# `GetTerrainIdx` resolves it. Two layers sharing one is the same bug in
		# a different coat, and would make a course's terrain unrepresentable.
		var key: int = int(layer.legacy_color.r8) << 16 \
			| int(layer.legacy_color.g8) << 8 | int(layer.legacy_color.b8)
		t.ok(not colors.has(key),
			"'%s' has a colour key of its own (vs '%s')" % [layer.id, colors.get(key, &"")])
		colors[key] = layer.id

static func _matches_source(t: TestCase, layers: Array[TerrainLayer]) -> void:
	t.begin("terrain library/matches terrains.lst")
	var source: String = _source_lst()
	if not FileAccess.file_exists(source):
		t.ok(true, "source tree not reachable — file cross-check skipped")
		return
	var recs: Array[Dictionary] = SPList.load_file(source)
	t.ok(recs.size() > 0, "terrains.lst parses (%d records)" % recs.size())
	t.ok(layers.size() == recs.size(),
		"one layer per record (%d records, %d layers)" % [recs.size(), layers.size()])

	var by_index: Dictionary[int, TerrainLayer] = {}
	for layer: TerrainLayer in layers:
		by_index[layer.legacy_index] = layer
	for i: int in recs.size():
		var rec: Dictionary = recs[i]
		var layer: TerrainLayer = by_index.get(i, null)
		t.ok(layer != null, "record %d ('%s') survived the import"
			% [i, SPList.get_str(rec, "name", "?")])
		if layer == null:
			continue
		t.ok(String(layer.legacy_name) == SPList.get_str(rec, "name"),
			"record %d keeps its declared name (%s)" % [i, layer.legacy_name])
		# Friction and depth are the gameplay half and are migrated verbatim;
		# a collapse shows up here as a neighbour's number.
		t.eq_f(layer.friction, SPList.get_float(rec, "friction", 0.35), 1e-6,
			"'%s' has record %d's friction" % [layer.id, i])
		t.eq_f(layer.compression_depth, SPList.get_float(rec, "depth", 0.05), 1e-6,
			"'%s' has record %d's depth" % [layer.id, i])
		t.ok(String(layer.slide_sound) == SPList.get_str(rec, "sound"),
			"'%s' has record %d's slide sound" % [layer.id, i])
		t.ok(layer.legacy_color.is_equal_approx(SPList.get_color3(rec, "col")),
			"'%s' has record %d's colour key" % [layer.id, i])

static func _repeated_name(t: TestCase, layers: Array[TerrainLayer]) -> void:
	t.begin("terrain library/repeated [name]")
	var pave: Array[TerrainLayer] = []
	for layer: TerrainLayer in layers:
		if layer.legacy_name == &"pave04":
			pave.push_back(layer)
	t.ok(pave.size() == 3, "all three pave04 records are present (%d)" % pave.size())
	if pave.size() != 3:
		return
	pave.sort_custom(func(a: TerrainLayer, b: TerrainLayer) -> bool:
		return a.legacy_index < b.legacy_index)

	# The first holder keeps the plain name; the others take their texture stem.
	t.ok(pave[0].id == &"pave04", "the first pave04 keeps the name")
	t.ok(pave[1].id == &"icy_rock06", "the second is named for its texture")
	t.ok(pave[2].id == &"icy_pave04", "the third is named for its texture")

	# What the collapse actually cost: two colour keys took the last record's
	# texture, and the only one of the three with a `[sound]` lost it.
	t.ok(pave[0].slide_sound == &"rock_sound", "only the first pave04 slides on rock")
	t.ok(pave[1].slide_sound.is_empty() and pave[2].slide_sound.is_empty(),
		"the other two are silent, as declared")
	t.ok(pave[1].albedo != pave[2].albedo, "the two icy records keep different textures")
	# `pave04.png` is not in the ETR tree at all, so the original renders this
	# one untextured too — asserted so that giving it an albedo is a deliberate
	# deviation rather than an unnoticed one.
	t.ok(pave[0].albedo == null, "the first pave04 has no texture to import")
