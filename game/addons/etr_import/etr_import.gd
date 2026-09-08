## One-way, re-runnable importer from Extreme Tux Racer 0.8.4 data to the v2
## course format (godot-port-plan.md §5).
##
## Legacy files are never written to — the original converted `trees.png` into
## `items.lst` inside its own data directory on first run, which this replaces.
## Generated resources land under `res://courses/` and `res://resources/` and
## are committed. A course carries a provenance marker; once a designer has
## touched it, re-import refuses to clobber it without `force`.
##
## Runs in two stages because Godot must import PNGs it did not previously know
## about before a resource can reference them as [Texture2D]:
##   1. `STAGE_ASSETS`    — copy/generate every binary asset
##   2. `STAGE_RESOURCES` — build the `.tres`/`.tscn` graph that points at them
## `tools/import_all.sh` drives both stages with a Godot `--import` in between.
@tool
class_name ETRImport
extends RefCounted

const STAGE_ASSETS := "assets"
const STAGE_RESOURCES := "resources"

## Bumped when the importer's output changes shape.
const IMPORT_VERSION := 1

## ETR encodes elevation as an 8-bit offset from this value.
const BASE_HEIGHT_VALUE := 127.0
## Terrain colour keys match within ±30 per channel, first match wins.
const TERRAIN_COLOR_TOLERANCE := 30
## Heightmap upsample factor applied during dequantization.
const HEIGHT_UPSAMPLE := 2
## Hard cap from the format: 2 RGBA splat textures.
const MAX_TERRAIN_LAYERS := 8
## OpenGL's default `GL_LIGHT_MODEL_AMBIENT`, which the original never overrides.
const GL_LIGHT_MODEL_AMBIENT := 0.2

const OUT_TERRAIN := "res://resources/terrain"
const OUT_OBJECTS := "res://resources/objects"
const OUT_ENV := "res://resources/environments"
const OUT_EVENTS := "res://resources/events"
const OUT_AUDIO := "res://resources/audio"
const OUT_COURSES := "res://courses"
const ASSET_TERRAIN := "res://assets/terrain"
const ASSET_OBJECTS := "res://assets/objects"
const ASSET_ENV := "res://assets/env"
const ASSET_SOUNDS := "res://assets/sounds"
const ASSET_MUSIC := "res://assets/music"

## `SetSoundVolumes` in `racing.cpp` — the original's whole per-sound mix, and
## the only thing that ever revisits a chunk's volume after it is loaded. The
## four cues missing from it keep the plain effects volume, exactly as there.
const RACE_SOUND_GAIN: Dictionary = {
	"pickup1": 1.0,
	"pickup2": 0.8,
	"pickup3": 0.8,
	"snow_sound": 1.5,
	"ice_sound": 0.6,
	"rock_sound": 1.1,
}

var source_dir: String = ""
var force: bool = false
var log_lines: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()
## Menu index rows, accumulated by [method import_course] during the resources
## stage and written out by [method write_course_catalog].
var catalog_entries: Array[CourseListing] = []
## Cue names seen in `sounds.lst`, so [method import_terrains] can tell a
## terrain that names a missing effect from one that names none.
var sound_cue_names: PackedStringArray = PackedStringArray()

func _log(msg: String) -> void:
	log_lines.push_back(msg)
	print("  ", msg)

func _warn(msg: String) -> void:
	warnings.push_back(msg)
	print("  WARN: ", msg)

## The resource already at [param path], if it has to be preserved rather than
## overwritten — else null. Logs the decision; `--force` always returns null.
##
## Two ways to be protected. [CourseData] has an explicit `modified_in_editor`
## a designer can tick. Both it and [TerrainLayer] then carry an
## `import_fingerprint` of what was last written here plus an
## `edited_since_import()` that recomputes it, which catches the edits nobody
## remembered to flag — so this works for either without a shared base class.
##
## A file with no fingerprint — one written before the field existed — reads as
## unedited, which is what let the first import after this change adopt the
## whole tree instead of refusing to touch any of it.
##
## Returns the resource rather than a bool because a caller that keeps a file
## still has to account for it: a course dropped from `catalog_entries` is a
## course dropped from the menu.
func _protected(path: String, label: String) -> Resource:
	if force or not ResourceLoader.exists(path):
		return null
	var existing: Resource = load(path)
	if existing == null:
		return null
	var why: String = ""
	if "modified_in_editor" in existing and existing.modified_in_editor:
		why = "flagged as edited in-editor"
	elif existing.has_method("edited_since_import") and existing.edited_since_import():
		why = "edited outside the importer"
	if why.is_empty():
		return null
	_log("%s: kept, %s (use --force to overwrite)" % [label, why])
	return existing

static func ensure_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path)

static func copy_file(from: String, to: String) -> bool:
	ensure_dir(to.get_base_dir())
	var data: PackedByteArray = FileAccess.get_file_as_bytes(from)
	if data.is_empty():
		return false
	var f := FileAccess.open(to, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true

## Load a PNG that lives outside the project. The legacy tree is deliberately
## not inside `res://` — 40 MB of assets we never ship should not be scanned by
## the editor's import pipeline.
static func load_external_image(path: String) -> Image:
	var img := Image.new()
	var err: int = img.load(path)
	if err != OK:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img

# ====================================================================
#                       global: terrain layers
# ====================================================================

## `terrains.lst` → one [TerrainLayer] per record. Gameplay numbers are migrated
## verbatim (they are tuned balance data); the PBR slots are left for authoring.
##
## One layer per *record*, never per `[name]`: the original indexes `TerrList`
## by position and `TTerrType` does not even store the name, so a repeated name
## is legal there and `terrains.lst` uses one three times. See
## [method _layer_id_for].
func import_terrains(stage: String) -> Dictionary:
	var recs: Array[Dictionary] = SPList.load_file(source_dir.path_join("terrains/terrains.lst"))
	var by_id: Dictionary[String, TerrainLayer] = {}
	var order: Array[String] = []
	var colors: Array[Color] = []
	# How often each `[name]` is declared, so the first holder of a repeated one
	# can keep it and the rest can be told apart. Needs the whole file first.
	var name_counts: Dictionary[String, int] = {}
	for rec: Dictionary in recs:
		var n: String = SPList.get_str(rec, "name")
		name_counts[n] = name_counts.get(n, 0) + 1

	if stage == STAGE_ASSETS:
		ensure_dir(ASSET_TERRAIN)
		var copied: int = 0
		for rec: Dictionary in recs:
			var tex: String = SPList.get_str(rec, "texture")
			if tex.is_empty():
				continue
			if copy_file(source_dir.path_join("terrains").path_join(tex),
					ASSET_TERRAIN.path_join(tex)):
				copied += 1
			else:
				# Two records name a texture that is not in the tree: `pave04`
				# wants a `pave04.png` nobody shipped, and `snowy_hockey_ice`
				# writes `snowy_ice02` without the extension. `TTexture::Load`
				# concatenates dir and filename and guesses nothing, so both are
				# untextured in the original as well — migrated as they stand,
				# but the layer that comes out with no albedo should say why.
				_warn("terrain '%s' texture '%s' is not in the source tree"
					% [SPList.get_str(rec, "name"), tex])
		_log("terrain textures copied: %d" % copied)

	ensure_dir(OUT_TERRAIN)
	var seen_colors: Dictionary[int, String] = {}
	for i: int in recs.size():
		var rec: Dictionary = recs[i]
		var declared: String = SPList.get_str(rec, "name", "terrain_%d" % i)
		var id: String = _layer_id_for(rec, i, name_counts, by_id)
		if id != declared:
			_log("terrain record %d is a second '%s' (%s); imported as '%s'"
				% [i, declared, SPList.get_str(rec, "texture", "no texture"), id])
		var layer := TerrainLayer.new()
		layer.id = StringName(id)
		layer.legacy_name = StringName(declared)
		layer.legacy_index = i
		layer.friction = SPList.get_float(rec, "friction", 0.35)
		layer.compression_depth = SPList.get_float(rec, "depth", 0.05)
		layer.emits_particles = SPList.get_bool(rec, "part", false)
		layer.takes_trackmarks = SPList.get_bool(rec, "trackmarks", false)
		layer.shiny = SPList.get_bool(rec, "shiny", false)
		layer.legacy_color = SPList.get_color3(rec, "col")
		layer.slide_sound = StringName(SPList.get_str(rec, "sound"))
		# Silence is normal here — 12 of the 43 records ship without a `[sound]`,
		# `snow` among them. A name that resolves to nothing is not.
		if not layer.slide_sound.is_empty() and not sound_cue_names.is_empty() \
				and not sound_cue_names.has(String(layer.slide_sound)):
			_warn("terrain '%s' names unknown sound cue '%s'" % [id, layer.slide_sound])
		# Snow deforms, ice and rock do not. The original had no such concept —
		# it only knew whether a terrain took a decal.
		layer.is_deformable = layer.takes_trackmarks
		# Roughness has no source in `terrains.lst` — ETR's terrain is flat
		# textured diffuse. Seed the split the renderer used to hardcode, so the
		# migrated library keeps the look it had, and leave it authorable.
		# After `is_deformable`, because `is_ice()` reads it.
		layer.roughness = 0.25 if layer.is_ice() else 0.85

		# The original matches colours within ±30 per channel against a 45-entry
		# list, so two terrains can silently collide (etracer.md §9). Report it
		# here rather than discovering it as a mystery friction value later.
		var key: int = int(layer.legacy_color.r8) << 16 | int(layer.legacy_color.g8) << 8 \
			| int(layer.legacy_color.b8)
		for other_key: int in seen_colors:
			if _colors_collide(key, other_key):
				_warn("terrain '%s' colour key collides with '%s' (±%d matching)"
					% [id, seen_colors[other_key], TERRAIN_COLOR_TOLERANCE])
		seen_colors[key] = id

		if stage == STAGE_RESOURCES:
			var tex_name: String = SPList.get_str(rec, "texture")
			if not tex_name.is_empty():
				var tex_path: String = ASSET_TERRAIN.path_join(tex_name)
				if ResourceLoader.exists(tex_path):
					layer.albedo = load(tex_path)
			var out_path: String = OUT_TERRAIN.path_join("%s.tres" % id)
			# The terrain library is the one place a designer can tune a
			# material from the Inspector, and until now every import
			# overwrote all 43 files unconditionally — an edit survived
			# exactly until the next `import_all.sh`. Courses have had this
			# guard from the start; layers deserve the same one.
			var kept: Resource = _protected(out_path, "terrain layer '%s'" % id)
			if kept != null:
				by_id[id] = kept
				order.push_back(id)
				# The colour key stays the source file's either way: it is how
				# `terrain.png` is decoded, not a rendering choice, and a course
				# would repaint itself if an edit could move it.
				colors.push_back(layer.legacy_color)
				continue
			layer.import_fingerprint = layer.fingerprint()
			ResourceSaver.save(layer, out_path)

		by_id[id] = layer
		order.push_back(id)
		colors.push_back(layer.legacy_color)

	_log("terrain layers: %d" % by_id.size())
	if by_id.size() != recs.size():
		_warn("terrain layers collapsed: %d records → %d resources"
			% [recs.size(), by_id.size()])
	return {"by_id": by_id, "order": order, "colors": colors}

## The resource id for terrain record [param index], unique across the file.
##
## `terrains.lst` declares `pave04` three times — different texture, different
## colour key, and only the first carries a `[sound]`. That is legal in the
## original: courses reference a terrain by *colour*, `CCourse::LoadTerrainTypes`
## indexes `TerrList` by position, and `TTerrType` has no name field at all. Here
## each record becomes a file, so a repeated name has to be resolved or two of
## the three are lost.
##
## The first holder keeps the plain name — for `pave04` that is the record whose
## texture is `pave04.png`. A later one takes its texture stem, which is unique
## across all 43 records and is what actually tells them apart, matching how the
## file already names `icy_pave05` after `icy_pave05.png`. The record index is
## the fallback if a stem is taken, empty, or is some other record's name.
static func _layer_id_for(rec: Dictionary, index: int, name_counts: Dictionary,
		taken: Dictionary) -> String:
	var name: String = SPList.get_str(rec, "name", "terrain_%d" % index)
	if int(name_counts.get(name, 1)) < 2 or not taken.has(name):
		return name
	var stem: String = SPList.get_str(rec, "texture").get_basename()
	if not stem.is_empty() and not taken.has(stem) and not name_counts.has(stem):
		return stem
	return "%s_%d" % [name, index]

static func _colors_collide(a: int, b: int) -> bool:
	return absi((a >> 16 & 0xFF) - (b >> 16 & 0xFF)) < TERRAIN_COLOR_TOLERANCE \
		and absi((a >> 8 & 0xFF) - (b >> 8 & 0xFF)) < TERRAIN_COLOR_TOLERANCE \
		and absi((a & 0xFF) - (b & 0xFF)) < TERRAIN_COLOR_TOLERANCE

## ETR's terrain lookup: first entry within ±30 on every channel, else index 0.
static func match_terrain(r: int, g: int, b: int, colors: Array[Color]) -> int:
	for i: int in colors.size():
		var c: Color = colors[i]
		if absi(r - c.r8) < TERRAIN_COLOR_TOLERANCE \
				and absi(g - c.g8) < TERRAIN_COLOR_TOLERANCE \
				and absi(b - c.b8) < TERRAIN_COLOR_TOLERANCE:
			return i
	return 0

# ====================================================================
#                       global: sounds + music
# ====================================================================

## `sounds/sounds.lst` + `music/music.lst` + `music/racing_themes.lst` → one
## [SoundBank] and one [MusicLibrary].
##
## Both are single global resources rather than per-course references: the ten
## effects and ten pieces are the same on every course, and a per-course
## reference would duplicate 18 MB of streams into every pack that gets
## exported separately.
##
## Only files the lists actually name are copied. The original loads by list
## too, so anything else in those directories was never reachable.
func import_audio(stage: String) -> void:
	var sounds: Array[Dictionary] = SPList.load_file(
		source_dir.path_join("sounds/sounds.lst"))
	var pieces: Array[Dictionary] = SPList.load_file(
		source_dir.path_join("music/music.lst"))

	sound_cue_names = PackedStringArray()
	for rec: Dictionary in sounds:
		var name: String = SPList.get_str(rec, "name")
		if not name.is_empty():
			sound_cue_names.push_back(name)

	if stage == STAGE_ASSETS:
		ensure_dir(ASSET_SOUNDS)
		ensure_dir(ASSET_MUSIC)
		var copied: int = 0
		for rec: Dictionary in sounds:
			var f: String = SPList.get_str(rec, "file")
			if not f.is_empty() and copy_file(
					source_dir.path_join("sounds").path_join(f),
					ASSET_SOUNDS.path_join(f)):
				copied += 1
		for rec: Dictionary in pieces:
			var f: String = SPList.get_str(rec, "file")
			if not f.is_empty() and copy_file(
					source_dir.path_join("music").path_join(f),
					ASSET_MUSIC.path_join(f)):
				copied += 1
		_log("audio files copied: %d" % copied)
		return

	ensure_dir(OUT_AUDIO)
	var bank := SoundBank.new()
	for rec: Dictionary in sounds:
		var name: String = SPList.get_str(rec, "name")
		var file: String = SPList.get_str(rec, "file")
		if name.is_empty() or file.is_empty():
			continue
		var cue := SoundCue.new()
		cue.id = StringName(name)
		# `[vol]` is dead in the original — see SoundCue — so the live number is
		# the gain `racing.cpp` sets by name, or 1.0 for the cues it never names.
		cue.legacy_volume = SPList.get_float(rec, "vol", 1.0)
		cue.race_gain = float(RACE_SOUND_GAIN.get(name, 1.0))
		cue.stream = _load_audio(ASSET_SOUNDS.path_join(file), "sound '%s'" % name)
		bank.cues.push_back(cue)
	ResourceSaver.save(bank, SoundBank.PATH)

	var lib := MusicLibrary.new()
	var paths: Dictionary[String, String] = {}
	for rec: Dictionary in pieces:
		var name: String = SPList.get_str(rec, "name")
		var file: String = SPList.get_str(rec, "file")
		if name.is_empty() or file.is_empty():
			continue
		var track := MusicTrack.new()
		track.id = StringName(name)
		var path: String = ASSET_MUSIC.path_join(file)
		# Only for the warning if the editor's import pass has not seen it yet
		# — the path is what MusicLibrary carries, not the loaded stream, so a
		# web export can leave `assets/music/*` out of the base pck and stream
		# it on demand (see PackStream) without MusicLibrary itself failing to
		# load.
		_load_audio(path, "music '%s'" % name)
		track.stream_path = path
		paths[name] = path
		lib.tracks.push_back(track)

	for rec: Dictionary in SPList.load_file(source_dir.path_join("music/racing_themes.lst")):
		var name: String = SPList.get_str(rec, "name")
		if name.is_empty():
			continue
		var theme := MusicTheme.new()
		theme.id = StringName(name)
		# The defaults are the original's own — `CMusic::LoadMusicList` passes
		# them to `SPStrN`, so a theme may name only the track that differs.
		theme.race_path = paths.get(SPList.get_str(rec, "race", "race_1"), "")
		theme.won_path = paths.get(SPList.get_str(rec, "wonrace", "wonrace_1"), "")
		theme.lost_path = paths.get(SPList.get_str(rec, "lostrace", "lostrace_1"), "")
		lib.themes.push_back(theme)

	ResourceSaver.save(lib, MusicLibrary.PATH)
	_log("audio: %d effects, %d music pieces, %d themes"
		% [bank.cues.size(), lib.tracks.size(), lib.themes.size()])

## A copied audio file as a stream, warning rather than failing if the editor's
## import pass has not seen it yet — the two-stage split exists for exactly
## this, and a missing stream leaves a named cue that simply makes no sound.
func _load_audio(path: String, what: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		_warn("%s has no imported stream at %s" % [what, path])
		return null
	return load(path) as AudioStream

# ====================================================================
#                      heightmap: decode + dequantize
# ====================================================================

## Decode `elev.png` to float32 [b]local relief only[/b].
##
## The original bakes the global downhill slope into every sample:
##   `elev = ((px − 127)/255) × scale − (row/ny) × length × tan(angle)`
## We keep only the first term and hand the slope to [CourseData.base_angle],
## so the float32 range goes on detail instead of a 500 m ramp (§3.2).
##
## The image is mirrored in X and its top row is the start line, matching the
## index gymnastics in `CCourse::LoadElevMap`.
static func decode_elevation(img: Image, scale: float) -> PackedFloat32Array:
	var nx: int = img.get_width()
	var ny: int = img.get_height()
	var out := PackedFloat32Array()
	out.resize(nx * ny)
	for gy: int in ny:
		for gx: int in nx:
			var px: int = nx - 1 - gx
			var v: float = img.get_pixel(px, gy).r * 255.0
			out[gy * nx + gx] = ((v - BASE_HEIGHT_VALUE) / 255.0) * scale
	return out

## Catmull-Rom upsample by an integer factor.
##
## A naive 8-bit→float32 widening preserves the terracing exactly — the source
## quantises to `scale/255`, i.e. 2.7–3.9 cm steps, which the original hides
## behind normal smoothing. Catmull-Rom reconstructs a plausible continuous
## surface through the same samples. This is the one lossy, judgement-dependent
## step in the pipeline (risk S3): eyeball it per course.
static func upsample_catmull_rom(src: PackedFloat32Array, w: int, h: int,
		factor: int) -> PackedFloat32Array:
	if factor <= 1:
		return src
	var ow: int = (w - 1) * factor + 1
	var oh: int = (h - 1) * factor + 1
	var tmp := PackedFloat32Array()
	tmp.resize(ow * h)
	for y: int in h:
		for ox: int in ow:
			var fx: float = float(ox) / float(factor)
			tmp[y * ow + ox] = _cr_row(src, w, y * w, fx, 1)
	var out := PackedFloat32Array()
	out.resize(ow * oh)
	for oy: int in oh:
		var fy: float = float(oy) / float(factor)
		for ox: int in ow:
			out[oy * ow + ox] = _cr_row(tmp, h, ox, fy, ow)
	return out

static func _cr_row(a: PackedFloat32Array, n: int, base: int, t: float, stride: int) -> float:
	var i: int = int(floor(t))
	var f: float = t - float(i)
	var i0: int = clampi(i - 1, 0, n - 1)
	var i1: int = clampi(i, 0, n - 1)
	var i2: int = clampi(i + 1, 0, n - 1)
	var i3: int = clampi(i + 2, 0, n - 1)
	var p0: float = a[base + i0 * stride]
	var p1: float = a[base + i1 * stride]
	var p2: float = a[base + i2 * stride]
	var p3: float = a[base + i3 * stride]
	var f2: float = f * f
	var f3: float = f2 * f
	return 0.5 * ((2.0 * p1)
		+ (-p0 + p2) * f
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f3)

## Edge-preserving smooth: a 3×3 bilateral pass whose range term is scaled to
## the source quantisation step. It erases residual stair-steps without
## rounding off the ridges and lips that make a course readable.
static func bilateral_smooth(src: PackedFloat32Array, w: int, h: int,
		quantum: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(src.size())
	var range_sigma: float = maxf(quantum, 1e-5)
	var inv_range: float = 1.0 / (2.0 * range_sigma * range_sigma)
	const SPATIAL: Array[float] = [
		0.0751, 0.1238, 0.0751,
		0.1238, 0.2042, 0.1238,
		0.0751, 0.1238, 0.0751]
	for y: int in h:
		for x: int in w:
			var centre: float = src[y * w + x]
			var acc: float = 0.0
			var wsum: float = 0.0
			var k: int = 0
			for dy: int in range(-1, 2):
				var sy: int = clampi(y + dy, 0, h - 1)
				for dx: int in range(-1, 2):
					var sx: int = clampi(x + dx, 0, w - 1)
					var v: float = src[sy * w + sx]
					var d: float = v - centre
					var weight: float = SPATIAL[k] * exp(-d * d * inv_range)
					acc += v * weight
					wsum += weight
					k += 1
			out[y * w + x] = acc / wsum
	return out

## Package a height field as a FORMAT_RF [Image] for [CourseData].
static func heights_to_image(heights: PackedFloat32Array, w: int, h: int) -> Image:
	return Image.create_from_data(w, h, false, Image.FORMAT_RF, heights.to_byte_array())

# ====================================================================
#                       splat maps from terrain.png
# ====================================================================

## `terrain.png` → up to two RGBA8 splat textures.
##
## The original stores a hard per-vertex terrain index and only ever *derives*
## a blend from it. Here the blend is authored: one-hot weights are written at
## the heightmap resolution, then the boundaries are blurred so a designer
## inherits something they can paint over rather than a colour-keyed index map.
##
## Returns `{images, layer_names, layer_indices}`; warns and merges the
## least-used types if a course exceeds the 8-layer cap.
func build_splat(terr_img: Image, colors: Array[Color], names: Array[String],
		target_w: int, target_h: int) -> Dictionary:
	var nx: int = terr_img.get_width()
	var ny: int = terr_img.get_height()

	# Which terrain types does this course actually use, and how much?
	var index_map := PackedInt32Array()
	index_map.resize(nx * ny)
	var usage: Dictionary[int, int] = {}
	for gy: int in ny:
		for gx: int in nx:
			var c: Color = terr_img.get_pixel(nx - 1 - gx, gy)
			var t: int = match_terrain(c.r8, c.g8, c.b8, colors)
			index_map[gy * nx + gx] = t
			usage[t] = usage.get(t, 0) + 1

	var used: Array[int] = usage.keys()
	used.sort_custom(func(a: int, b: int) -> bool: return usage[a] > usage[b])

	var remap: Dictionary[int, int] = {}
	var layer_indices: Array[int] = []
	var layer_names: Array[String] = []
	for i: int in used.size():
		var terrain_index: int = used[i]
		if i < MAX_TERRAIN_LAYERS:
			remap[terrain_index] = i
			layer_indices.push_back(terrain_index)
			layer_names.push_back(names[terrain_index])
		else:
			# Merge into the most-used layer with the closest friction, so the
			# course still plays approximately right rather than silently
			# becoming the dominant terrain everywhere.
			var best: int = 0
			var best_d: float = INF
			for j: int in MAX_TERRAIN_LAYERS:
				var d: float = absf(colors[layer_indices[j]].r - colors[terrain_index].r) \
					+ absf(colors[layer_indices[j]].g - colors[terrain_index].g) \
					+ absf(colors[layer_indices[j]].b - colors[terrain_index].b)
				if d < best_d:
					best_d = d
					best = j
			remap[terrain_index] = best
			_warn("course uses %d terrain types (cap %d): merging '%s' into '%s'"
				% [used.size(), MAX_TERRAIN_LAYERS, names[terrain_index],
					names[layer_indices[best]]])

	var layer_count: int = layer_indices.size()

	# One-hot at the target resolution (nearest from the source grid), then a
	# separable blur across the boundaries.
	var weights := PackedFloat32Array()
	weights.resize(target_w * target_h * layer_count)
	weights.fill(0.0)
	for y: int in target_h:
		var sy: int = clampi(int(float(y) / float(target_h) * float(ny)), 0, ny - 1)
		for x: int in target_w:
			var sx: int = clampi(int(float(x) / float(target_w) * float(nx)), 0, nx - 1)
			var layer: int = remap[index_map[sy * nx + sx]]
			weights[(y * target_w + x) * layer_count + layer] = 1.0
	weights = _blur_weights(weights, target_w, target_h, layer_count)

	var images: Array[Image] = []
	var maps: int = int(ceil(float(layer_count) / 4.0))
	for m: int in maps:
		var img := Image.create_empty(target_w, target_h, false, Image.FORMAT_RGBA8)
		for y: int in target_h:
			for x: int in target_w:
				var base: int = (y * target_w + x) * layer_count
				var c := Color(0, 0, 0, 0)
				for ch: int in 4:
					var layer: int = m * 4 + ch
					if layer < layer_count:
						c[ch] = weights[base + layer]
				img.set_pixel(x, y, c)
		images.push_back(img)

	return {
		"images": images,
		"layer_names": layer_names,
		"layer_indices": layer_indices,
		"layer_count": layer_count,
	}

## Two 1-D box passes, then renormalise so the weights still sum to one.
static func _blur_weights(w: PackedFloat32Array, width: int, height: int,
		layers: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(w.size())
	for y: int in height:
		for x: int in width:
			var x0: int = maxi(x - 1, 0)
			var x1: int = mini(x + 1, width - 1)
			for l: int in layers:
				tmp[(y * width + x) * layers + l] = (
					w[(y * width + x0) * layers + l]
					+ w[(y * width + x) * layers + l]
					+ w[(y * width + x1) * layers + l]) / 3.0
	var out := PackedFloat32Array()
	out.resize(w.size())
	for y: int in height:
		var y0: int = maxi(y - 1, 0)
		var y1: int = mini(y + 1, height - 1)
		for x: int in width:
			var total: float = 0.0
			for l: int in layers:
				var v: float = (
					tmp[(y0 * width + x) * layers + l]
					+ tmp[(y * width + x) * layers + l]
					+ tmp[(y1 * width + x) * layers + l]) / 3.0
				out[(y * width + x) * layers + l] = v
				total += v
			if total > 0.0:
				for l: int in layers:
					out[(y * width + x) * layers + l] /= total
	return out

# ====================================================================
#                          objects / prefabs
# ====================================================================

## `object_types.lst` → prefab scenes. Each carries an explicit collision proxy
## (radius + height), which is what the physics uses — the original ran the
## character's ellipsoid hierarchy against an 8-face polyhedron for the same
## answer at ten times the cost (§3.3).
func import_objects(stage: String) -> Array[Dictionary]:
	var recs: Array[Dictionary] = SPList.load_file(
		source_dir.path_join("objects/object_types.lst"))
	if stage == STAGE_ASSETS:
		ensure_dir(ASSET_OBJECTS)
		var copied: int = 0
		for rec: Dictionary in recs:
			var tex: String = SPList.get_str(rec, "texture")
			if tex.is_empty():
				continue
			if copy_file(source_dir.path_join("objects").path_join(tex),
					ASSET_OBJECTS.path_join(tex)):
				copied += 1
		_log("object textures copied: %d" % copied)

	var out: Array[Dictionary] = []
	for i: int in recs.size():
		var rec: Dictionary = recs[i]
		out.push_back({
			"name": SPList.get_str(rec, "name", "object_%d" % i),
			"texture": SPList.get_str(rec, "texture"),
			"collidable": SPList.get_bool(rec, "coll", false),
			"collectable": SPList.get_bool(rec, "snap", true),
			"drawable": SPList.get_bool(rec, "draw", true),
			"reset_point": SPList.get_bool(rec, "reset", false),
		})
	_log("object types: %d" % out.size())
	return out

## Colour keys for `trees.png`, transcribed from `CCourse::GetObject`. Used only
## for the 24 courses that ship without an `items.lst`.
static func object_from_pixel(r: int, g: int, b: int) -> int:
	if r < 150 and b > 200: return 0          # herring
	if absi(r - 194) < 10 and absi(g - 40) < 10 and absi(b - 40) < 10: return 1   # flag
	if absi(r - 128) < 10 and absi(g - 128) < 10 and b < 10: return 2             # start
	if r > 220 and g > 220 and b < 20: return 3                                   # finish
	if r > 220 and absi(g - 128) < 10 and b > 220: return 4                       # float/reset
	if r > 220 and g > 220 and b > 220: return 5                                  # tree
	if r > 220 and absi(g - 96) < 10 and b < 40: return 6                         # tree_barren
	if r < 40 and g > 220 and b < 80: return 7                                    # shrub
	return -1

## Read `items.lst` if the course ships one — it carries float height/diam that
## the pixel map cannot — otherwise convert `trees.png` in memory. The original
## wrote that conversion back into its own data directory on first run; this
## never touches the source tree.
func load_course_objects(course_dir: String, nx: int, ny: int, world: Vector2,
		object_types: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var items_path: String = course_dir.path_join("items.lst")
	if FileAccess.file_exists(items_path):
		var name_to_type: Dictionary[String, int] = {}
		for i: int in object_types.size():
			name_to_type[object_types[i]["name"]] = i
		for rec: Dictionary in SPList.load_file(items_path):
			var name: String = SPList.get_str(rec, "name")
			if not name_to_type.has(name):
				continue
			var gx: int = SPList.get_int(rec, "x", 0)
			var gz: int = SPList.get_int(rec, "z", 0)
			out.push_back({
				"type": name_to_type[name],
				"name": name,
				# Grid-snapped in the source. Preserved exactly: tree placement
				# is gameplay, and de-gridding is a designer's call (§5.1).
				"x": float(nx - gx) / float(nx - 1) * world.x,
				"z": -float(ny - gz) / float(ny - 1) * world.y,
				"height": SPList.get_float(rec, "height", 1.0),
				"diam": SPList.get_float(rec, "diam", 1.0),
			})
		return out

	var tree_img: Image = load_external_image(course_dir.path_join("trees.png"))
	if tree_img == null:
		_warn("%s has neither items.lst nor a readable trees.png" % course_dir)
		return out
	var rng := RandomNumberGenerator.new()
	# Deterministic per course, so re-import is reproducible. The original
	# re-rolled tree sizes from the global rand() on every first load.
	rng.seed = hash(course_dir)
	for y: int in tree_img.get_height():
		for x: int in tree_img.get_width():
			var c: Color = tree_img.get_pixel(x, y)
			var t: int = object_from_pixel(c.r8, c.g8, c.b8)
			if t < 0 or t >= object_types.size():
				continue
			var height: float = 1.0
			var diam: float = 1.0
			if t == 5 or t == 6 or t == 7:
				var base: float = 2.5 if t == 5 else (3.0 if t == 6 else 1.2)
				var hd: Vector2 = _random_tree(rng, base)
				height = hd.x
				diam = hd.y
			elif t == 2 or t == 3:
				height = 6.0
				diam = 9.0
			out.push_back({
				"type": t,
				"name": object_types[t]["name"],
				"x": float(nx - x) / float(nx - 1) * world.x,
				"z": -float(ny - y) / float(ny - 1) * world.y,
				"height": height,
				"diam": diam,
			})
	return out

## ETR `CalcRandomTrees` at the default treesize/treevar of 3:
## sizefact[3] = 1.0, varfact[3] = 1.41, diamfact = 1.4.
static func _random_tree(rng: RandomNumberGenerator, base: float) -> Vector2:
	const VARFACT := 1.41
	const DIAMFACT := 1.4
	var height: float = rng.randf_range(base / VARFACT, base * VARFACT)
	var diam: float = rng.randf_range(height / DIAMFACT, height)
	return Vector2(height, diam)

# ====================================================================
#                            per-course
# ====================================================================

## Import one course. `group` is the ETR course group (`default` / `extras`);
## `list_name` is the display name from that group's `courses.lst`.
func import_course(group: String, dir_name: String,
		stage: String, terrains: Dictionary, object_types: Array[Dictionary],
		prefabs: Dictionary[String, ObjectPrefab], list_name: String = "") -> bool:
	var src: String = source_dir.path_join("courses").path_join(group).path_join(dir_name)
	var out_dir: String = OUT_COURSES.path_join(dir_name)
	var tres_path: String = out_dir.path_join("course.tres")

	var protected: Resource = _protected(tres_path, dir_name)
	if protected != null:
		# Still list it. The catalog is rebuilt from scratch every run, so a
		# course that is merely left alone would otherwise vanish from the
		# course menu — `DirAccess` cannot find it back in an exported build.
		catalog_entries.push_back(_listing_for(protected, group, dir_name, out_dir))
		return false

	var dim: Array[Dictionary] = SPList.load_file(src.path_join("course.dim"))
	if dim.is_empty():
		_warn("%s: no course.dim" % dir_name)
		return false
	var head: Dictionary = dim[0]

	var world := Vector2(
		SPList.get_float(head, "width", 100.0),
		SPList.get_float(head, "length", 1000.0))
	var play := Vector2(
		SPList.get_float(head, "play_width", 90.0),
		SPList.get_float(head, "play_length", 900.0))
	var angle: float = SPList.get_float(head, "angle", 10.0)
	var scale: float = SPList.get_float(head, "scale", 10.0)

	var elev: Image = load_external_image(src.path_join("elev.png"))
	if elev == null:
		_warn("%s: cannot read elev.png" % dir_name)
		return false
	var nx: int = elev.get_width()
	var ny: int = elev.get_height()

	ensure_dir(out_dir)

	if stage == STAGE_ASSETS:
		# float32 relief, dequantized. 8-bit over a 7–10 m scale quantises to
		# 2.7–3.9 cm, which reads as terracing on a bright slope.
		var heights: PackedFloat32Array = decode_elevation(elev, scale)
		var up: PackedFloat32Array = upsample_catmull_rom(heights, nx, ny, HEIGHT_UPSAMPLE)
		var uw: int = (nx - 1) * HEIGHT_UPSAMPLE + 1
		var uh: int = (ny - 1) * HEIGHT_UPSAMPLE + 1
		up = bilateral_smooth(up, uw, uh, scale / 255.0)
		var himg: Image = heights_to_image(up, uw, uh)
		ResourceSaver.save(himg, out_dir.path_join("heightmap.res"))

		var terr: Image = load_external_image(src.path_join("terrain.png"))
		if terr != null:
			var splat: Dictionary = build_splat(terr, terrains["colors"], terrains["order"],
				uw, uh)
			var imgs: Array[Image] = splat["images"]
			for m: int in imgs.size():
				imgs[m].save_png(ProjectSettings.globalize_path(
					out_dir.path_join("splat_%d.png" % m)))
			var meta := ConfigFile.new()
			meta.set_value("splat", "layer_names", splat["layer_names"])
			meta.set_value("splat", "layer_indices", splat["layer_indices"])
			meta.set_value("splat", "layer_count", splat["layer_count"])
			meta.set_value("heightmap", "size", Vector2i(uw, uh))
			meta.save(out_dir.path_join("import_meta.cfg"))
		else:
			_warn("%s: cannot read terrain.png" % dir_name)

		copy_file(src.path_join("preview.png"), out_dir.path_join("preview.png"))
		_log("%s: %dx%d → %dx%d heightmap" % [dir_name, nx, ny, uw, uh])
		return true

	# ---- STAGE_RESOURCES ----
	var meta := ConfigFile.new()
	if meta.load(out_dir.path_join("import_meta.cfg")) != OK:
		_warn("%s: import_meta.cfg missing; run the assets stage first" % dir_name)
		return false
	var hsize: Vector2i = meta.get_value("heightmap", "size", Vector2i.ZERO)

	var course := CourseData.new()
	# The name the player reads lives in the group's `courses.lst`, not in
	# `course.dim` — the original menu builds its list from that file and only a
	# handful of courses repeat a `[name]` inside their own header.
	course.display_name = list_name if not list_name.is_empty() \
		else SPList.get_str(head, "name", dir_name)
	course.author = SPList.get_str(head, "author", "unknown")
	if dim.size() >= 2:
		course.description = SPList.get_str(dim[dim.size() - 1], "desc", "")
	course.world_size = world
	course.play_size = play
	course.base_angle = angle
	course.height_scale = scale
	course.heightmap_size = hsize
	course.start_position = Vector2(
		SPList.get_float(head, "startx", 50.0),
		SPList.get_float(head, "starty", 5.0))
	course.finish_line_z = -play.y
	course.music_theme = StringName(SPList.get_str(head, "theme", "normal"))
	course.finish_brake = SPList.get_float(head, "finish_brake", 20.0)
	course.use_keyframe = SPList.get_bool(head, "use_keyframe", false)
	# Courses name an environment but not a time of day — the light condition is
	# chosen per race in events.lst. Sunny is the standalone-practice default.
	var env_name: String = SPList.get_str(head, "env", "etr")
	var env_path: String = OUT_ENV.path_join("%s_sunny.tres" % env_name)
	if ResourceLoader.exists(env_path):
		course.environment_preset = load(env_path)
	course.play_bounds = course.default_play_bounds()
	course.imported_from = "%s/%s" % [group, dir_name]
	course.import_version = IMPORT_VERSION
	course.modified_in_editor = false

	var hres_path: String = out_dir.path_join("heightmap.res")
	if ResourceLoader.exists(hres_path):
		course.heightmap = load(hres_path)
	var preview_path: String = out_dir.path_join("preview.png")
	if ResourceLoader.exists(preview_path):
		course.preview = load(preview_path)

	var layer_names: Array = meta.get_value("splat", "layer_names", [])
	var layers: Array[TerrainLayer] = []
	for n: String in layer_names:
		var lp: String = OUT_TERRAIN.path_join("%s.tres" % n)
		if ResourceLoader.exists(lp):
			layers.push_back(load(lp))
		else:
			# Skipping the slot would slide every later layer onto the wrong
			# splat channel — the course would still load and play the wrong
			# friction. Keep the position and make the hole loud instead.
			_warn("%s: terrain layer '%s' is missing; splat channel %d gets a default"
				% [dir_name, n, layers.size()])
			var missing := TerrainLayer.new()
			missing.id = StringName(n)
			layers.push_back(missing)
	course.terrain_layers = layers

	var splat_maps: Array[Texture2D] = []
	for m: int in 2:
		var sp: String = out_dir.path_join("splat_%d.png" % m)
		if ResourceLoader.exists(sp):
			splat_maps.push_back(load(sp))
	course.splat_maps = splat_maps
	course.splat_size = hsize

	# Last, so it covers everything above it.
	course.import_fingerprint = course.fingerprint()
	ResourceSaver.save(course, tres_path)

	var objects: Array[Dictionary] = load_course_objects(src, nx, ny, world, object_types)
	_write_course_scene(out_dir, dir_name, tres_path, objects, prefabs)
	catalog_entries.push_back(_listing_for(course, group, dir_name, out_dir))
	_log("%s: %d layers, %d objects" % [dir_name, layers.size(), objects.size()])
	return true

## Emit `course.tscn`: the [CourseRoot] runtime node plus one marker per object,
## grouped by prefab type. Authoring is per-instance — arbitrary position,
## rotation and scale, none of which the colour-keyed pixel map could express —
## while drawing is instanced, built from these transforms at load (§3.3).
func _write_course_scene(out_dir: String, dir_name: String, tres_path: String,
		objects: Array[Dictionary], prefabs: Dictionary[String, ObjectPrefab]) -> void:
	var root := Node3D.new()
	root.name = dir_name
	root.set_script(load("res://scripts/course/course_root.gd"))
	root.set("course_data", load(tres_path))
	root.set("object_prefabs", prefabs)

	var objects_root := Node3D.new()
	objects_root.name = "Objects"
	root.add_child(objects_root)
	objects_root.owner = root

	var groups: Dictionary[String, Node3D] = {}
	var counter: Dictionary[String, int] = {}
	for obj: Dictionary in objects:
		var type_name: String = obj["name"]
		if not groups.has(type_name):
			var g := Node3D.new()
			g.name = type_name
			objects_root.add_child(g)
			g.owner = root
			groups[type_name] = g
			counter[type_name] = 0
		var marker := Marker3D.new()
		marker.name = "%s_%d" % [type_name, counter[type_name]]
		counter[type_name] += 1
		# Y is resolved against the surface at load; the heightmap is the
		# authority and it has just been resampled.
		marker.position = Vector3(obj["x"], 0.0, obj["z"])
		marker.scale = Vector3(obj["diam"], obj["height"], obj["diam"])
		groups[type_name].add_child(marker)
		marker.owner = root

	var packed := PackedScene.new()
	if packed.pack(root) == OK:
		ResourceSaver.save(packed, out_dir.path_join("course.tscn"))
	root.free()

## One [CourseListing] for the menu index, built from the course that was just
## written. Metadata only — see [CourseListing] for why it holds paths.
func _listing_for(course: CourseData, group: String, dir_name: String,
		out_dir: String) -> CourseListing:
	var listing := CourseListing.new()
	listing.dir = dir_name
	listing.group = group
	listing.display_name = course.display_name
	listing.author = course.author
	listing.description = course.description
	listing.scene_path = out_dir.path_join("course.tscn")
	listing.course_path = out_dir.path_join("course.tres")
	var preview_path: String = out_dir.path_join("preview.png")
	listing.preview_path = preview_path if ResourceLoader.exists(preview_path) else ""
	listing.world_size = course.world_size
	listing.base_angle = course.base_angle
	return listing

## Write the course-menu index to [constant CourseCatalog.PATH].
##
## Merges rather than replaces. A `--course=bunny_hill` run rebuilds exactly one
## course, and writing a one-entry catalog would empty the menu of the other 43
## without touching anything that looks broken. Rows whose course resource has
## since disappeared are dropped, so a deleted course leaves the index.
func write_course_catalog() -> void:
	var merged: Array[CourseListing] = []
	var replaced: Dictionary[String, bool] = {}
	for e: CourseListing in catalog_entries:
		replaced[e.dir] = true
		merged.push_back(e)
	if ResourceLoader.exists(CourseCatalog.PATH):
		var existing: CourseCatalog = load(CourseCatalog.PATH)
		if existing != null:
			for e: CourseListing in existing.entries:
				if replaced.has(e.dir):
					continue
				if not ResourceLoader.exists(e.course_path):
					continue
				merged.push_back(e)

	var catalog := CourseCatalog.new()
	catalog.entries = merged
	catalog.sort()
	ensure_dir(CourseCatalog.PATH.get_base_dir())
	ResourceSaver.save(catalog, CourseCatalog.PATH)
	_log("course catalog: %d courses" % catalog.entries.size())

# ====================================================================
#                     events / cups / event sets
# ====================================================================

## `events.lst` → [RaceEvent] / [RaceCup] / [EventSet] resources.
## The herring and time thresholds carry over unchanged.
func import_events() -> void:
	var recs: Array[Dictionary] = SPList.load_file(source_dir.path_join("courses/events.lst"))
	ensure_dir(OUT_EVENTS)
	var races: Dictionary[String, RaceEvent] = {}
	var cups: Dictionary[String, RaceCup] = {}
	var race_count: int = 0
	var cup_count: int = 0
	var set_count: int = 0

	for rec: Dictionary in recs:
		match SPList.get_int(rec, "struct", -1):
			0:
				var r := RaceEvent.new()
				r.id = StringName(SPList.get_str(rec, "race"))
				r.course_group = SPList.get_str(rec, "group", "default")
				r.course_dir = SPList.get_str(rec, "course")
				r.light = StringName(SPList.get_str(rec, "light", "sunny"))
				r.snow = SPList.get_int(rec, "snow", 0)
				r.wind = SPList.get_int(rec, "wind", 0)
				var h: PackedFloat64Array = SPList.get_numbers(rec, "herring")
				if h.size() >= 3:
					r.herring = Vector3i(int(h[0]), int(h[1]), int(h[2]))
				var tm: PackedFloat64Array = SPList.get_numbers(rec, "time")
				if tm.size() >= 3:
					r.time = Vector3(float(tm[0]), float(tm[1]), float(tm[2]))
				r.music_theme = StringName(SPList.get_str(rec, "theme", "normal"))
				var cp: String = OUT_COURSES.path_join(r.course_dir).path_join("course.tres")
				if ResourceLoader.exists(cp):
					r.course = load(cp)
				else:
					_warn("race '%s' references missing course '%s'" % [r.id, r.course_dir])
				races[String(r.id)] = r
				ResourceSaver.save(r, OUT_EVENTS.path_join("race_%s.tres" % r.id))
				race_count += 1
			1:
				var c := RaceCup.new()
				c.id = StringName(SPList.get_str(rec, "cup"))
				c.display_name = SPList.get_str(rec, "name")
				c.description = SPList.get_str(rec, "desc")
				for i: int in range(1, SPList.get_int(rec, "num", 0) + 1):
					var rid: String = SPList.get_str(rec, str(i))
					if races.has(rid):
						c.races.push_back(races[rid])
					elif not rid.is_empty():
						_warn("cup '%s' references unknown race '%s'" % [c.id, rid])
				cups[String(c.id)] = c
				ResourceSaver.save(c, OUT_EVENTS.path_join("cup_%s.tres" % c.id))
				cup_count += 1
			2:
				var e := EventSet.new()
				e.id = StringName(SPList.get_str(rec, "event"))
				e.display_name = SPList.get_str(rec, "name")
				e.description = SPList.get_str(rec, "desc")
				for i: int in range(1, SPList.get_int(rec, "num", 0) + 1):
					var cid: String = SPList.get_str(rec, str(i))
					if cups.has(cid):
						e.cups.push_back(cups[cid])
					elif not cid.is_empty():
						_warn("event '%s' references unknown cup '%s'" % [e.id, cid])
				ResourceSaver.save(e, OUT_EVENTS.path_join("event_%s.tres" % e.id))
				set_count += 1
	_log("events: %d races, %d cups, %d event sets" % [race_count, cup_count, set_count])

# ====================================================================
#                          environments
# ====================================================================

## `env/<env>/<light>/light.lst` + skyboxes → [EnvironmentPreset] resources.
func import_environments(stage: String) -> void:
	var envs: Array[Dictionary] = SPList.load_file(
		source_dir.path_join("env/environment.lst"), true)
	const LIGHTS: Array[String] = ["sunny", "cloudy", "evening", "night"]
	ensure_dir(OUT_ENV)
	ensure_dir(ASSET_ENV)
	var count: int = 0
	for rec: Dictionary in envs:
		var loc: String = SPList.get_str(rec, "location")
		if loc.is_empty():
			continue
		for light: String in LIGHTS:
			if not SPList.get_bool(rec, light, false):
				continue
			var dir: String = source_dir.path_join("env").path_join(loc).path_join(light)
			var lines: Array[Dictionary] = SPList.load_file(dir.path_join("light.lst"))
			if lines.is_empty():
				continue
			var preset := EnvironmentPreset.new()
			preset.id = StringName("%s_%s" % [loc, light])
			_import_skybox(preset, dir, SPList.get_bool(rec, "high_res", false), stage)

			for line: Dictionary in lines:
				if line.has("fog"):
					preset.fog_enabled = SPList.get_bool(line, "fog", true)
					preset.fog_color = _color4(SPList.get_numbers(line, "fogcol"), Color.WHITE)
					preset.fog_start = SPList.get_float(line, "fogstart", 0.0)
					preset.fog_end = SPList.get_float(line, "fogend", 75.0)
					preset.fog_height = SPList.get_float(line, "fogheight", 0.0)
					preset.particle_color = _color4(SPList.get_numbers(line, "partcol"),
						Color(0.85, 0.9, 1.0))
				elif line.has("light"):
					var idx: int = SPList.get_int(line, "light", 0)
					var pos: PackedFloat64Array = SPList.get_numbers(line, "pos")
					var diff: Color = _color4(SPList.get_numbers(line, "diff"), Color.WHITE)
					var amb: Color = _color4(SPList.get_numbers(line, "amb"), Color.BLACK)
					var spec: Color = _color4(SPList.get_numbers(line, "spec"), Color.BLACK)
					if idx == 0:
						# Light 0 is the key light: it becomes the sun.
						if pos.size() >= 3:
							preset.sun_direction = Vector3(
								float(pos[0]), float(pos[1]), float(pos[2])).normalized()
						preset.sun_color = diff
						# Plus the fixed-function light model's own ambient. ETR
						# never calls glLightModel, so GL_LIGHT_MODEL_AMBIENT stays
						# at the GL default (0.2, 0.2, 0.2) and is added to every
						# surface on top of the per-light ambient in `light.lst`.
						# Migrating only what the file says leaves the shaded side of
						# every slope about a third too dark — it is the floor under
						# the original's snow, not a rendering-state detail.
						preset.ambient_color = Color(
							minf(1.0, amb.r + GL_LIGHT_MODEL_AMBIENT),
							minf(1.0, amb.g + GL_LIGHT_MODEL_AMBIENT),
							minf(1.0, amb.b + GL_LIGHT_MODEL_AMBIENT))
					else:
						# The fill lights have nowhere to go under a single-sun
						# PBR setup, so their energy is folded into ambient and
						# specular rather than thrown away.
						var cur: Color = preset.ambient_color
						preset.ambient_color = Color(
							minf(1.0, cur.r + diff.r * 0.175),
							minf(1.0, cur.g + diff.g * 0.175),
							minf(1.0, cur.b + diff.b * 0.175))
						preset.specular_color = Color(
							minf(1.0, preset.specular_color.r + spec.r * 0.5),
							minf(1.0, preset.specular_color.g + spec.g * 0.5),
							minf(1.0, preset.specular_color.b + spec.b * 0.5))

			if stage == STAGE_RESOURCES:
				ResourceSaver.save(preset, OUT_ENV.path_join("%s.tres" % preset.id))
			count += 1
	_log("environment presets: %d" % count)

## The three skybox faces for one environment, plus the two flat colours that
## stand in for the faces ETR never shipped.
##
## `environment.lst` marks a location `high_res`, which selects the `H` variants
## — 1024² instead of 512². The original picked between them at load time from
## the same flag; here it is baked in, because the choice is per-location and
## never changed at runtime.
##
## Only front, left and right exist: `param.full_skybox` is off in the shipped
## config, so no top, bottom or back was ever authored. `etr_skybox.gdshader`
## fills the gap by fading to the average of the front face's top and bottom
## rows, which is what these two colours are.
func _import_skybox(preset: EnvironmentPreset, dir: String, high_res: bool, stage: String) -> void:
	const FACES: Array[String] = ["front", "left", "right"]
	var out_dir: String = ASSET_ENV.path_join(String(preset.id))
	for face: String in FACES:
		var src: String = dir.path_join("%s%s.png" % [face, "H" if high_res else ""])
		if not FileAccess.file_exists(src):
			# A location can be marked high_res without shipping every H face.
			src = dir.path_join("%s.png" % face)
		if not FileAccess.file_exists(src):
			_warn("environment '%s' has no %s skybox face" % [preset.id, face])
			continue
		if stage == STAGE_ASSETS:
			if not copy_file(src, out_dir.path_join("%s.png" % face)):
				_warn("could not copy %s" % src)
			continue
		var tex_path: String = out_dir.path_join("%s.png" % face)
		var tex: Texture2D = load(tex_path) if ResourceLoader.exists(tex_path) else null
		match face:
			"front":
				preset.sky_front = tex
				var img: Image = load_external_image(src)
				if img != null:
					preset.sky_zenith_color = _row_average(img, 0)
					preset.sky_nadir_color = _row_average(img, img.get_height() - 1)
			"left":
				preset.sky_left = tex
			"right":
				preset.sky_right = tex

## Mean colour of one row of an image, used to extend a skybox face past its own
## edge without a visible join.
static func _row_average(img: Image, y: int) -> Color:
	var w: int = img.get_width()
	if w <= 0:
		return Color.WHITE
	var acc := Vector3.ZERO
	for x: int in w:
		var c: Color = img.get_pixel(x, y)
		acc += Vector3(c.r, c.g, c.b)
	acc /= float(w)
	return Color(acc.x, acc.y, acc.z)

static func _color4(n: PackedFloat64Array, def: Color) -> Color:
	if n.size() < 3:
		return def
	return Color(float(n[0]), float(n[1]), float(n[2]),
		float(n[3]) if n.size() > 3 else 1.0)

# ====================================================================
#                          translations
# ====================================================================

## 15 `translations/*.lst` → one Godot CSV translation table.
##
## The originals are indexed by opaque integers that the C++ hard-codes. During
## the move those become semantic keys derived from the English string, which is
## the kind of legacy wart worth fixing exactly once (§5.2).
func import_translations() -> void:
	var dir: String = source_dir.path_join("translations")
	var langs: Array[Dictionary] = SPList.load_file(dir.path_join("languages.lst"))
	var codes: Array[String] = []
	for rec: Dictionary in langs:
		var code: String = SPList.get_str(rec, "lang")
		if not code.is_empty() and FileAccess.file_exists(dir.path_join("%s.lst" % code)):
			codes.push_back(code)

	# The English source strings live in the reference file; every other file is
	# keyed by the same [idx].
	var english: Dictionary[int, String] = {}
	var per_lang: Dictionary[String, Dictionary] = {}
	for code: String in codes:
		var table: Dictionary[int, String] = {}
		for rec: Dictionary in SPList.load_file(dir.path_join("%s.lst" % code)):
			var idx: int = SPList.get_int(rec, "idx", -1)
			if idx < 0:
				continue
			var eng: String = SPList.get_str(rec, "engl")
			if not eng.is_empty() and not english.has(idx):
				english[idx] = eng
			var trans: String = SPList.get_str(rec, "trans")
			if not trans.is_empty():
				table[idx] = trans
		per_lang[code] = table

	var keys: Array[int] = english.keys()
	keys.sort()
	var used_keys: Dictionary[String, bool] = {}
	var lines: PackedStringArray = PackedStringArray()
	var header: PackedStringArray = PackedStringArray(["keys", "en"])
	for code: String in codes:
		header.push_back(code)
	lines.push_back(",".join(header))

	for idx: int in keys:
		var key: String = _semantic_key(english[idx], used_keys)
		var row: PackedStringArray = PackedStringArray([key, _csv(english[idx])])
		for code: String in codes:
			row.push_back(_csv(per_lang[code].get(idx, "")))
		lines.push_back(",".join(row))

	ensure_dir("res://i18n")
	var f := FileAccess.open("res://i18n/penguinracer.csv", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	# The numeric IDs stay recorded so a mis-mapped key can be traced back.
	var map := ConfigFile.new()
	for idx: int in keys:
		map.set_value("legacy_ids", str(idx), english[idx])
	map.save("res://i18n/legacy_string_ids.cfg")
	_log("translations: %d strings × %d languages" % [keys.size(), codes.size() + 1])

## `PRESS ANY KEY TO START` → `PRESS_ANY_KEY_TO_START`, deduplicated.
static func _semantic_key(english: String, used: Dictionary[String, bool]) -> String:
	var s: String = english.strip_edges().to_upper()
	var out: String = ""
	for i: int in s.length():
		var c: String = s[i]
		if (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"):
			out += c
		elif not out.ends_with("_"):
			out += "_"
	out = out.strip_edges().trim_suffix("_").substr(0, 48)
	if out.is_empty():
		out = "STRING"
	var key: String = out
	var n: int = 2
	while used.has(key):
		key = "%s_%d" % [out, n]
		n += 1
	used[key] = true
	return key

static func _csv(s: String) -> String:
	if s.contains(",") or s.contains("\"") or s.contains("\n"):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s

# ====================================================================
#                          object prefabs
# ====================================================================

## Build one [ObjectPrefab] per object type.
##
## Two shapes, because the original draws two. `DrawTrees` in
## `course_render.cpp` walks `CollArr` — everything `[coll] 1`, i.e. the trees
## and the shrub — and emits eight fixed vertices per object: one quad across X
## and one across Z, both from the ground to `[height]`, never turned toward the
## camera. It then walks `NocollArr` — the herring, the flags, the start and
## finish banners — and emits four vertices per object, turned to face
## `ctrl->viewpos`. So a tree is a static cross of two planes at 90 degrees and
## an item is a billboard, and the two are not interchangeable: a billboarded
## tree swivels as the player rides past it and has the same silhouette from
## every side, which is the single most visible difference between a hillside
## here and a hillside there.
##
## Swapping in authored meshes later is still a matter of pointing the prefab at
## a different [Mesh]; [method _cross_quad_mesh] is only the default.
func build_object_prefabs(object_types: Array[Dictionary]) -> Dictionary[String, ObjectPrefab]:
	ensure_dir(OUT_OBJECTS)
	var out: Dictionary[String, ObjectPrefab] = {}
	for entry: Dictionary in object_types:
		var name: String = entry["name"]
		var prefab := ObjectPrefab.new()
		prefab.id = StringName(name)
		prefab.collidable = entry["collidable"]
		prefab.collectable = entry["collectable"] and not entry["collidable"]
		prefab.decorative = not entry["collidable"] and not entry["collectable"]

		if entry["drawable"] and not String(entry["texture"]).is_empty():
			var tex_path: String = ASSET_OBJECTS.path_join(entry["texture"])
			if ResourceLoader.exists(tex_path):
				var mat := ShaderMaterial.new()
				if entry["collidable"]:
					prefab.mesh = _cross_quad_mesh()
					mat.shader = load("res://shaders/object_cross.gdshader")
				else:
					var quad := QuadMesh.new()
					# Unit quad: the per-instance transform carries diameter and
					# height, so one mesh serves every size on the course.
					quad.size = Vector2(1.0, 1.0)
					quad.center_offset = Vector3(0.0, 0.5, 0.0)
					prefab.mesh = quad
					# A StandardMaterial3D billboard shades from the quad's own
					# +Z, which after billboarding points at the camera — so the
					# sun's N·L, and with it the whole cutout's brightness,
					# swings as the view moves. `object_billboard.gdshader` does
					# the same BILLBOARD_FIXED_Y turn with a view-independent
					# normal.
					mat.shader = load("res://shaders/object_billboard.gdshader")
				mat.set_shader_parameter("albedo_texture", load(tex_path))
				mat.set_shader_parameter("alpha_scissor", 0.5)
				prefab.material = mat
		ResourceSaver.save(prefab, OUT_OBJECTS.path_join("%s.tres" % name))
		out[name] = prefab
	_log("object prefabs: %d" % out.size())
	return out

## The eight vertices `DrawTrees` emits, as a unit mesh: one quad in the XY
## plane and one in the ZY plane, both spanning ±0.5 across and 0 to 1 up.
##
## Unit-sized for the same reason the billboard quad is — the per-instance
## transform carries `(diameter, height, diameter)`, so ±0.5 across is ±radius
## once scaled, which is exactly the original's `treeRadius = diam / 2`.
##
## Normals and tangents are authored rather than left to Godot: the shader
## builds its cylinder impostor out of both, and a mesh with no `ARRAY_TANGENT`
## hands it a zero vector with nothing to say so. The UVs are the original's,
## with V flipped for Godot's top-left origin.
static func _cross_quad_mesh() -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0),
		Vector3(0.5, 1.0, 0.0), Vector3(-0.5, 1.0, 0.0),
		Vector3(0.0, 0.0, -0.5), Vector3(0.0, 0.0, 0.5),
		Vector3(0.0, 1.0, 0.5), Vector3(0.0, 1.0, -0.5),
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	# Each quad's tangent is the direction U increases in, and its normal is
	# that crossed with the trunk — so the pair is right-handed and the shader's
	# `TANGENT * u + NORMAL * sqrt(1 - u²)` sweeps the near half of a cylinder.
	for quad: int in 2:
		var tangent: Vector3 = Vector3.RIGHT if quad == 0 else Vector3.BACK
		var normal: Vector3 = tangent.cross(Vector3.UP)
		for i: int in 4:
			normals.push_back(normal)
			tangents.append_array(PackedFloat32Array(
				[tangent.x, tangent.y, tangent.z, 1.0]))

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ====================================================================
#                            characters
# ====================================================================

## `char/<name>/shape.lst` → a skinned placeholder [ArrayMesh] on a [Skeleton3D],
## plus the migrated keyframe animations that pose it.
##
## The original's character is a hierarchy of up to 256 ellipsoids — a unit
## sphere per node with its own scale/rotation/translation, drawn by walking the
## tree and pushing a matrix per node. That representation is discarded, but it
## is worth converting once: every visible node becomes a scaled UV sphere welded
## into a single mesh, the named joints become real bones, and each sphere is
## bound rigidly to the nearest joint above it. Rigid binding is not an
## approximation here — it is what the original does, because a sphere is a leaf
## under exactly one chain of matrices.
##
## The point is the [b]joint names[/b]. You get a recognisable, posable Tux on
## day one, and when authored skinned glTF art arrives it drops in against the
## same `neck` / `head` / `left_shldr` / `left_hip` / … skeleton, so the
## procedural animation layer and the migrated keyframes keep working unchanged.
## All five of them, not just Tux: `characters.lst` is a five-record file and
## each `[dir]` has its own `shape.lst` and its own four keyframe lists, so
## Trixi does not wave Tux's flippers. The catalog written at the end is what
## the shell offers and what `penguinracer.cfg` names a row of.
func import_characters(stage: String) -> void:
	var chars: Array[Dictionary] = SPList.load_file(source_dir.path_join("char/characters.lst"))
	ensure_dir("res://resources/characters")
	var listings: Array[CharacterListing] = []
	for rec: Dictionary in chars:
		var dir_name: String = SPList.get_str(rec, "dir")
		if dir_name.is_empty():
			continue
		var src: String = source_dir.path_join("char").path_join(dir_name)
		var out_dir: String = "res://resources/characters".path_join(dir_name)
		if stage == STAGE_ASSETS:
			ensure_dir(out_dir)
			# The 128x128 the registration screen draws in a white frame. Copied
			# in the assets stage so that the listing built in the next one can
			# ask whether it landed.
			if not copy_file(src.path_join("preview.png"), out_dir.path_join("preview.png")):
				_warn("%s: no preview.png" % dir_name)
		var built: Dictionary = _build_character(src)
		if built.is_empty():
			_warn("%s: no usable shape.lst" % dir_name)
			continue
		if stage == STAGE_RESOURCES:
			ensure_dir(out_dir)
			ResourceSaver.save(built["mesh"], out_dir.path_join("placeholder_mesh.res"))
			# Keyframes first: the scene carries both halves of them, and the
			# joint rotations are baked against the same bone rests the scene
			# is about to be given.
			var clips: Dictionary = _import_keyframes(src, out_dir, built["bones"])
			_save_character_scene(out_dir, dir_name, built, clips)
		listings.push_back(_character_listing_for(rec, dir_name, out_dir))
	if stage == STAGE_RESOURCES:
		_write_character_catalog(listings)
	_log("characters: %d" % listings.size())

## One [CharacterListing] for the character menu, straight off the
## `characters.lst` record. `[name]` is the name the player reads and `[type]`
## is migrated so the file is not silently lossy — nothing reads it, in the
## original either.
func _character_listing_for(rec: Dictionary, dir_name: String,
		out_dir: String) -> CharacterListing:
	var listing := CharacterListing.new()
	listing.dir = dir_name
	listing.display_name = SPList.get_str(rec, "name")
	listing.shape_type = SPList.get_str(rec, "type", "spheres")
	listing.scene_path = out_dir.path_join("%s.tscn" % dir_name)
	var preview_path: String = out_dir.path_join("preview.png")
	listing.preview_path = preview_path if ResourceLoader.exists(preview_path) else ""
	return listing

## Write the character index to [constant CharacterCatalog.PATH].
##
## Replaces rather than merges, unlike [method write_course_catalog]: every run
## walks the whole of `characters.lst`, there is no `--character=` narrowing the
## way `--course=` narrows the course loop, and the file's order is the menu's
## order — so a merge would have nothing to preserve and could only reorder it.
func _write_character_catalog(listings: Array[CharacterListing]) -> void:
	if listings.is_empty():
		_warn("no characters imported; leaving the catalog alone")
		return
	var catalog := CharacterCatalog.new()
	catalog.entries = listings
	ensure_dir(CharacterCatalog.PATH.get_base_dir())
	ResourceSaver.save(catalog, CharacterCatalog.PATH)
	_log("character catalog: %d characters" % catalog.entries.size())

## Walk the ellipsoid hierarchy, accumulating each node's transform exactly as
## `CCharShape::Load` does — the `[order]` string is a list of which operations
## to apply and in what order, which is the one genuinely fiddly part.
##
## Returns the welded mesh, the bone table (see [method _build_bones]) and the
## per-node bookkeeping the scene writer needs.
func _build_character(src: String) -> Dictionary:
	var recs: Array[Dictionary] = SPList.load_file(src.path_join("shape.lst"))
	if recs.is_empty():
		return {}

	var transforms: Dictionary[int, Transform3D] = {0: Transform3D.IDENTITY}
	var parents: Dictionary[int, int] = {0: -1}
	var joints: Array[Dictionary] = []
	var spheres: Array[Dictionary] = []
	var colors: Dictionary[String, Color] = {}

	for rec: Dictionary in recs:
		if SPList.get_int(rec, "material", 0) > 0:
			var mat_name: String = SPList.get_str(rec, "mat")
			var diff: PackedFloat64Array = SPList.get_numbers(rec, "diff")
			if not mat_name.is_empty() and diff.size() >= 3:
				colors[mat_name] = Color(float(diff[0]), float(diff[1]), float(diff[2]))
			continue

		var node: int = SPList.get_int(rec, "node", -1)
		var parent: int = SPList.get_int(rec, "par", -1)
		if node < 0 or not transforms.has(parent):
			continue

		var local := Transform3D.IDENTITY
		var trans: PackedFloat64Array = SPList.get_numbers(rec, "trans")
		var rot: PackedFloat64Array = SPList.get_numbers(rec, "rot")
		var scale: PackedFloat64Array = SPList.get_numbers(rec, "scale")
		var order: String = SPList.get_str(rec, "order")
		for i: int in order.length():
			match order[i]:
				"0":
					if trans.size() >= 3:
						local = local.translated_local(
							Vector3(float(trans[0]), float(trans[1]), float(trans[2])))
				"1":
					if rot.size() >= 1:
						local = local.rotated_local(Vector3.RIGHT, deg_to_rad(float(rot[0])))
				"2":
					if rot.size() >= 2:
						local = local.rotated_local(Vector3.UP, deg_to_rad(float(rot[1])))
				"3":
					if rot.size() >= 3:
						local = local.rotated_local(Vector3.BACK, deg_to_rad(float(rot[2])))
				"4":
					if scale.size() >= 3:
						local = local.scaled_local(
							Vector3(float(scale[0]), float(scale[1]), float(scale[2])))
				"9":
					if rot.size() >= 3:
						local = local.rotated_local(Vector3.UP, deg_to_rad(float(rot[2])))
		var world: Transform3D = transforms[parent] * local
		transforms[node] = world
		parents[node] = parent

		var joint_name: String = SPList.get_str(rec, "joint")
		if not joint_name.is_empty():
			joints.push_back({"name": joint_name, "node": node, "parent": parent,
				"transform": world})
		if SPList.get_float(rec, "vis", -1.0) > 0.0:
			spheres.push_back({"node": node, "transform": world,
				"color": colors.get(SPList.get_str(rec, "mat"), Color(0.8, 0.8, 0.8))})

	if spheres.is_empty():
		return {}

	var bones: Array[Dictionary] = _build_bones(joints, parents)
	# Every sphere rides the nearest joint above it, and the ones with no joint
	# above them — body, breast, and the geometry hung directly off node 1 —
	# ride the root bone, which never moves.
	var bone_of_node: Dictionary[int, int] = {}
	for i: int in bones.size():
		bone_of_node[int(bones[i]["node"])] = i
	for s: Dictionary in spheres:
		s["bone"] = _nearest_bone(int(s["node"]), parents, bone_of_node)

	return {"mesh": _weld_spheres(spheres), "joints": joints, "transforms": transforms,
		"parents": parents, "bones": bones}

## The bone table: a synthetic `root` at index 0, then one bone per `[joint]`
## node in file order.
##
## Each entry is `{name, node, parent, global, rest}`.
##
## [b]`rest` is relative to the parent bone, not global.[/b] Joints chain through
## nodes that are not themselves joints — `left_shldr` hangs off the breast,
## which hangs off the figure — and skipping those on the way up is what makes
## the accumulated frame land on the parent bone rather than on the world. The
## joint node's own transform is identity in every shipped `shape.lst` (a
## `[joint]` record carries no `[trans]`/`[rot]`/`[scale]`), which is exactly why
## the original can pose it by assigning `node->trans` outright: the rest of the
## chain is baked above and below it.
##
## Bones come out parent-before-child, which the file order already guarantees
## and [Skeleton3D] wants.
static func _build_bones(joints: Array[Dictionary],
		parents: Dictionary[int, int]) -> Array[Dictionary]:
	var bones: Array[Dictionary] = [{
		"name": "root", "node": 0, "parent": -1,
		"global": Transform3D.IDENTITY, "rest": Transform3D.IDENTITY,
	}]
	var bone_of_node: Dictionary[int, int] = {0: 0}
	for j: Dictionary in joints:
		bone_of_node[int(j["node"])] = bones.size()
		bones.push_back({"name": String(j["name"]), "node": int(j["node"]),
			"parent": 0, "global": j["transform"] as Transform3D,
			"rest": Transform3D.IDENTITY})
	for i: int in range(1, bones.size()):
		var parent_bone: int = _nearest_bone(
			int(parents.get(int(bones[i]["node"]), 0)), parents, bone_of_node)
		bones[i]["parent"] = parent_bone
		bones[i]["rest"] = (bones[parent_bone]["global"] as Transform3D).affine_inverse() \
			* (bones[i]["global"] as Transform3D)
	return bones

## Walk up the node hierarchy from [param node] to the first node that is a bone.
## Node 0 always is, so this terminates on the root.
static func _nearest_bone(node: int, parents: Dictionary[int, int],
		bone_of_node: Dictionary[int, int]) -> int:
	var guard: int = 0
	while node >= 0 and guard < 256:
		if bone_of_node.has(node):
			return bone_of_node[node]
		node = parents.get(node, -1)
		guard += 1
	return 0

## Each visible node is a unit sphere under its accumulated transform. Welding
## them into one [ArrayMesh] turns 34 draw calls into one, and binding each
## sphere's vertices rigidly to one bone keeps the articulation the hierarchy
## was there for.
static func _weld_spheres(spheres: Array[Dictionary]) -> ArrayMesh:
	const RINGS := 8
	const SEGMENTS := 12
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()

	for s: Dictionary in spheres:
		var xf: Transform3D = s["transform"]
		var col: Color = s["color"]
		var bone: int = int(s.get("bone", 0))
		var base: int = verts.size()
		# Degenerate scales exist in the source data (flattened ellipsoids), and
		# inverting those is a divide by zero. Fall back to the rotation alone.
		var normal_basis: Basis = xf.basis.orthonormalized() if absf(xf.basis.determinant()) < 1e-9 \
			else xf.basis.inverse().transposed()
		for r: int in RINGS + 1:
			var phi: float = PI * float(r) / float(RINGS)
			for c: int in SEGMENTS + 1:
				var theta: float = TAU * float(c) / float(SEGMENTS)
				var p := Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
				verts.push_back(xf * p)
				normals.push_back((normal_basis * p).normalized())
				colors.push_back(col)
				bones.append_array([bone, 0, 0, 0])
				weights.append_array([1.0, 0.0, 0.0, 0.0])
		for r: int in RINGS:
			for c: int in SEGMENTS:
				var a: int = base + r * (SEGMENTS + 1) + c
				var b: int = a + 1
				var d: int = a + SEGMENTS + 1
				var e: int = d + 1
				indices.append_array([a, d, b, b, d, e])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.6
	mesh.surface_set_material(0, mat)
	return mesh

## ETR's character model frame is not Godot's, and nothing else in the pipeline
## corrects for it.
##
## `CCharShape::AdjustOrientation` builds the body basis with `new_y` = the
## direction of travel and `new_z` = −surface normal, so in model space [b]+Y is
## forward and +Z is the belly[/b]. `shape.lst` agrees: breast, neck and head
## stack along +Y, and every white underside part is offset toward +Z. Godot's
## convention is +Y up, −Z forward — feed one to the other and Tux rides down
## the hill standing bolt upright.
##
## The rotation between them maps +Y → −Z, +Z → −Y and +X → −X: a 180° turn
## about (0, 1, −1). It is baked into the generated scene root rather than
## applied by the race scene, because authored glTF art is already Y-up /
## −Z-forward and must not need the same fixup (§3.4). [CharacterRig] is what
## reads it back off the root for the one caller that does need it.
const MODEL_TO_GODOT := Basis(
	Vector3(-1.0, 0.0, 0.0),
	Vector3(0.0, 0.0, -1.0),
	Vector3(0.0, -1.0, 0.0))

## Scene: a [CharacterRig] over a [Skeleton3D] with the migrated joint names, the
## skinned placeholder mesh, and an [AnimationPlayer] holding the keyframes.
## Authored art replaces the mesh; the bone names and this shape are the contract.
func _save_character_scene(out_dir: String, dir_name: String, built: Dictionary,
		clips: Dictionary) -> void:
	var root := Node3D.new()
	root.name = dir_name
	root.set_script(load("res://scripts/character/character_rig.gd"))
	root.basis = MODEL_TO_GODOT
	var paths: Dictionary[StringName, KeyframePath] = {}
	for clip: String in clips.get("paths", {}):
		paths[StringName(clip)] = clips["paths"][clip]
	root.set(&"keyframe_paths", paths)

	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	root.add_child(skeleton)
	skeleton.owner = root

	var bones: Array = built["bones"]
	var skin := Skin.new()
	for b: Dictionary in bones:
		skeleton.add_bone(String(b["name"]))
	for i: int in bones.size():
		var rest: Transform3D = bones[i]["rest"]
		skeleton.set_bone_parent(i, int(bones[i]["parent"]))
		skeleton.set_bone_rest(i, rest)
		# A bone's pose is built from its own position/rotation/scale, not from
		# the rest plus an offset, so the rest has to be copied into the pose or
		# an animation that keys rotation alone drops the other two to identity.
		skeleton.set_bone_pose_position(i, rest.origin)
		skeleton.set_bone_pose_rotation(i, rest.basis.get_rotation_quaternion())
		skeleton.set_bone_pose_scale(i, rest.basis.get_scale())
		# Bind index i is bone i, which is what `_weld_spheres` indexed against.
		skin.add_bind(i, (bones[i]["global"] as Transform3D).affine_inverse())

	var mi := MeshInstance3D.new()
	mi.name = "Placeholder"
	mi.mesh = built["mesh"]
	mi.skin = skin
	mi.skeleton = ^"../Skeleton3D"
	root.add_child(mi)
	mi.owner = root

	var library: AnimationLibrary = clips.get("library", null)
	if library != null:
		var player := AnimationPlayer.new()
		player.name = "AnimationPlayer"
		player.add_animation_library(&"", library)
		root.add_child(player)
		player.owner = root

	var packed := PackedScene.new()
	if packed.pack(root) == OK:
		ResourceSaver.save(packed, out_dir.path_join("%s.tscn" % dir_name))
	root.free()

## `start/finish/wonrace/lostrace.lst` → an [AnimationLibrary] of joint poses on
## the migrated bone names, plus a [KeyframePath] of root motion per clip.
##
## Returns `{"library": AnimationLibrary, "paths": {clip: KeyframePath}}`.
##
## Three things about the format are easy to get wrong and silent when you do:
##
## - [b]`[time]` is a duration, not a timestamp.[/b] `CKeyframe::Update` holds
##   frame `i` for `frames[i].val[0]` seconds and then moves on, so the key times
##   are a running sum. Read as timestamps they collapse the whole clip onto
##   t = 0. The clip ends [i]on[/i] the last key rather than holding it, which is
##   why the length is the sum over every frame but the last.
## - [b]A missing tag is a zero, not "leave it alone".[/b] The original resets
##   every joint each frame and then applies the file's values, and `SPFloatN`
##   defaults to 0 — so `start.lst` dropping `[sh]` after the sixth frame is what
##   brings the flippers back down. Keying only the tags that are present would
##   hold the last pose instead.
## - [b]Each tag names its own rotation axis[/b] in the joint's own frame, and
##   they are not all the same one. `[sh]`, `[hip]`, `[knee]`, `[ankle]` and
##   `[neck]` turn about Z; `[head]` and `[arm]` turn about Y. The joint frames
##   are already twisted by `shape.lst` so that each of those comes out as the
##   anatomical motion.
##
## A [Skeleton3D] rotation track is an absolute pose, not an offset from the
## rest, so each key is `rest × R` — which also means the [Animation] is only
## valid against the skeleton it was baked with.
func _import_keyframes(src: String, out_dir: String, bones: Array) -> Dictionary:
	const CLIPS: Array[String] = ["start", "finish", "wonrace", "lostrace"]
	var rest_of: Dictionary[String, Quaternion] = {}
	var bone_index: Dictionary[String, int] = {}
	for i: int in bones.size():
		var bname: String = String(bones[i]["name"])
		bone_index[bname] = i
		rest_of[bname] = (bones[i]["rest"] as Transform3D).basis.get_rotation_quaternion()

	var library := AnimationLibrary.new()
	var paths: Dictionary[String, KeyframePath] = {}
	for clip: String in CLIPS:
		var path: String = src.path_join("%s.lst" % clip)
		if not FileAccess.file_exists(path):
			continue
		var frames: Array[Dictionary] = SPList.load_file(path)
		if frames.size() < 2:
			continue

		var anim := Animation.new()
		var tracks: Dictionary[String, int] = {}
		for joint: String in ["neck", "head", "left_shldr", "right_shldr",
				"left_hip", "right_hip", "left_knee", "right_knee",
				"left_ankle", "right_ankle"]:
			if not bone_index.has(joint):
				continue
			var tr: int = anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(tr, NodePath("Skeleton3D:%s" % joint))
			tracks[joint] = tr

		# Built up locally and assigned once: reading a packed array back off a
		# property hands out a copy, so appending through `route.times` would
		# quietly throw every key away.
		var times := PackedFloat32Array()
		var offsets := PackedVector3Array()
		var angles := PackedVector3Array()
		var t: float = 0.0
		for frame: Dictionary in frames:
			var p: PackedFloat64Array = SPList.get_numbers(frame, "pos")
			times.push_back(t)
			offsets.push_back(Vector3(
				float(p[0]) if p.size() >= 3 else 0.0,
				float(p[1]) if p.size() >= 3 else 0.0,
				float(p[2]) if p.size() >= 3 else 0.0))
			angles.push_back(Vector3(
				SPList.get_float(frame, "yaw", 0.0),
				SPList.get_float(frame, "pitch", 0.0),
				SPList.get_float(frame, "roll", 0.0)))

			_key_axis(anim, tracks, rest_of, "neck", Vector3.BACK,
				SPList.get_float(frame, "neck", 0.0), t)
			_key_axis(anim, tracks, rest_of, "head", Vector3.UP,
				SPList.get_float(frame, "head", 0.0), t)
			# The shoulders take two tags on two axes. `[sh]` is applied first,
			# matching the order in `InterpolateKeyframe`.
			var sh: Vector2 = _pair(frame, "sh")
			var arm: Vector2 = _pair(frame, "arm")
			_key_shoulder(anim, tracks, rest_of, "left_shldr", sh.x, arm.x, t)
			_key_shoulder(anim, tracks, rest_of, "right_shldr", sh.y, arm.y, t)
			var hip: Vector2 = _pair(frame, "hip")
			_key_axis(anim, tracks, rest_of, "left_hip", Vector3.BACK, hip.x, t)
			_key_axis(anim, tracks, rest_of, "right_hip", Vector3.BACK, hip.y, t)
			var knee: Vector2 = _pair(frame, "knee")
			_key_axis(anim, tracks, rest_of, "left_knee", Vector3.BACK, knee.x, t)
			_key_axis(anim, tracks, rest_of, "right_knee", Vector3.BACK, knee.y, t)
			var ankle: Vector2 = _pair(frame, "ankle")
			_key_axis(anim, tracks, rest_of, "left_ankle", Vector3.BACK, ankle.x, t)
			_key_axis(anim, tracks, rest_of, "right_ankle", Vector3.BACK, ankle.y, t)

			t += maxf(0.01, SPList.get_float(frame, "time", 0.1))

		# The last frame's own `[time]` is never spent: the original goes
		# inactive the moment its cursor reaches the last key.
		var route := KeyframePath.new()
		route.times = times
		route.offsets = offsets
		route.angles = angles
		anim.length = maxf(route.duration(), 0.01)
		library.add_animation(clip, anim)
		paths[clip] = route

	if library.get_animation_list().is_empty():
		return {}
	var lib_path: String = out_dir.path_join("animations.res")
	ResourceSaver.save(library, lib_path)
	# So the scene stores the library as an external reference rather than
	# embedding a second copy of it.
	library.take_over_path(lib_path)
	return {"library": library, "paths": paths}

## Keyframe files give left and right in one tag, e.g. `[sh] -20 40`. A tag that
## is absent is two zeroes — see [method _import_keyframes].
static func _pair(frame: Dictionary, tag: String) -> Vector2:
	var v: PackedFloat64Array = SPList.get_numbers(frame, tag)
	return Vector2(
		float(v[0]) if v.size() >= 1 else 0.0,
		float(v[1]) if v.size() >= 2 else 0.0)

static func _key_axis(anim: Animation, tracks: Dictionary[String, int],
		rest_of: Dictionary[String, Quaternion], joint: String, axis: Vector3,
		degrees: float, t: float) -> void:
	if not tracks.has(joint):
		return
	anim.rotation_track_insert_key(tracks[joint], t,
		rest_of[joint] * Quaternion(axis, deg_to_rad(degrees)))

## DEVIATION: a shoulder carrying both `[sh]` and `[arm]` is keyed as one
## quaternion and interpolated by slerp, where the original interpolates the two
## angles separately and rebuilds the pair of matrices. The two agree exactly
## whenever one of the angles is constant across a segment, which covers
## `start.lst` (no `[arm]` at all) and every segment of `finish.lst` but the two
## either side of its wave. Interpolating in Euler space instead would need one
## track per axis, which a [Skeleton3D] rotation track does not offer.
static func _key_shoulder(anim: Animation, tracks: Dictionary[String, int],
		rest_of: Dictionary[String, Quaternion], joint: String,
		sh_degrees: float, arm_degrees: float, t: float) -> void:
	if not tracks.has(joint):
		return
	anim.rotation_track_insert_key(tracks[joint], t, rest_of[joint]
		* Quaternion(Vector3.BACK, deg_to_rad(sh_degrees))
		* Quaternion(Vector3.UP, deg_to_rad(arm_degrees)))
