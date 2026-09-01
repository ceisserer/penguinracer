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

## `terrains.lst` → one [TerrainLayer] per type. Gameplay numbers are migrated
## verbatim (they are tuned balance data); the PBR slots are left for authoring.
func import_terrains(stage: String) -> Dictionary:
	var recs: Array[Dictionary] = SPList.load_file(source_dir.path_join("terrains/terrains.lst"))
	var by_name: Dictionary[String, TerrainLayer] = {}
	var order: Array[String] = []
	var colors: Array[Color] = []

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
		_log("terrain textures copied: %d" % copied)

	ensure_dir(OUT_TERRAIN)
	var seen_colors: Dictionary[int, String] = {}
	for i: int in recs.size():
		var rec: Dictionary = recs[i]
		var name: String = SPList.get_str(rec, "name", "terrain_%d" % i)
		var layer := TerrainLayer.new()
		layer.id = StringName(name)
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
			_warn("terrain '%s' names unknown sound cue '%s'" % [name, layer.slide_sound])
		# Snow deforms, ice and rock do not. The original had no such concept —
		# it only knew whether a terrain took a decal.
		layer.is_deformable = layer.takes_trackmarks

		# `terrains.lst` reuses `pave04` for three different records — different
		# texture, different colour key, and only the first carries a `[sound]`.
		# The original indexes `TerrList` by position and never looks a terrain
		# up by name, so it keeps all three; keying the layer resources by name
		# collapses them and the last one wins. Pre-existing and untouched here
		# — disambiguating the names re-identifies every course's splat layers —
		# but it should not be silent.
		if by_name.has(name):
			_warn("terrain '%s' is declared more than once; the last record wins"
				% name)

		# The original matches colours within ±30 per channel against a 45-entry
		# list, so two terrains can silently collide (etracer.md §9). Report it
		# here rather than discovering it as a mystery friction value later.
		var key: int = int(layer.legacy_color.r8) << 16 | int(layer.legacy_color.g8) << 8 \
			| int(layer.legacy_color.b8)
		for other_key: int in seen_colors:
			if _colors_collide(key, other_key):
				_warn("terrain '%s' colour key collides with '%s' (±%d matching)"
					% [name, seen_colors[other_key], TERRAIN_COLOR_TOLERANCE])
		seen_colors[key] = name

		if stage == STAGE_RESOURCES:
			var tex_name: String = SPList.get_str(rec, "texture")
			if not tex_name.is_empty():
				var tex_path: String = ASSET_TERRAIN.path_join(tex_name)
				if ResourceLoader.exists(tex_path):
					layer.albedo = load(tex_path)
			ResourceSaver.save(layer, OUT_TERRAIN.path_join("%s.tres" % name))

		by_name[name] = layer
		order.push_back(name)
		colors.push_back(layer.legacy_color)

	_log("terrain layers: %d" % recs.size())
	return {"by_name": by_name, "order": order, "colors": colors}

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
	var streams: Dictionary[String, AudioStream] = {}
	for rec: Dictionary in pieces:
		var name: String = SPList.get_str(rec, "name")
		var file: String = SPList.get_str(rec, "file")
		if name.is_empty() or file.is_empty():
			continue
		var track := MusicTrack.new()
		track.id = StringName(name)
		track.stream = _load_audio(ASSET_MUSIC.path_join(file), "music '%s'" % name)
		streams[name] = track.stream
		lib.tracks.push_back(track)

	for rec: Dictionary in SPList.load_file(source_dir.path_join("music/racing_themes.lst")):
		var name: String = SPList.get_str(rec, "name")
		if name.is_empty():
			continue
		var theme := MusicTheme.new()
		theme.id = StringName(name)
		# The defaults are the original's own — `CMusic::LoadMusicList` passes
		# them to `SPStrN`, so a theme may name only the track that differs.
		theme.race = streams.get(SPList.get_str(rec, "race", "race_1"), null)
		theme.won = streams.get(SPList.get_str(rec, "wonrace", "wonrace_1"), null)
		theme.lost = streams.get(SPList.get_str(rec, "lostrace", "lostrace_1"), null)
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

	if not force and ResourceLoader.exists(tres_path):
		var existing: CourseData = load(tres_path)
		if existing != null and existing.modified_in_editor:
			_log("%s: skipped, edited in-editor (use --force to overwrite)" % dir_name)
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
	course.terrain_layers = layers

	var splat_maps: Array[Texture2D] = []
	for m: int in 2:
		var sp: String = out_dir.path_join("splat_%d.png" % m)
		if ResourceLoader.exists(sp):
			splat_maps.push_back(load(sp))
	course.splat_maps = splat_maps
	course.splat_size = hsize

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

## Build one [ObjectPrefab] per object type. Trees and herring were camera-facing
## billboards in the original and stay billboards here — swapping in authored
## meshes later is a matter of pointing the prefab at a different [Mesh].
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
				var quad := QuadMesh.new()
				# Unit quad: the per-instance transform carries diameter and
				# height, so one mesh serves every size on the course.
				quad.size = Vector2(1.0, 1.0)
				quad.center_offset = Vector3(0.0, 0.5, 0.0)
				prefab.mesh = quad
				# A StandardMaterial3D billboard shades from the quad's own
				# +Z, which after billboarding points at the camera — so the
				# sun's N·L, and with it the whole cutout's brightness, swings
				# as the view moves. `object_billboard.gdshader` does the same
				# BILLBOARD_FIXED_Y turn with a view-independent normal.
				var mat := ShaderMaterial.new()
				mat.shader = load("res://shaders/object_billboard.gdshader")
				mat.set_shader_parameter("albedo_texture", load(tex_path))
				mat.set_shader_parameter("alpha_scissor", 0.5)
				prefab.material = mat
		ResourceSaver.save(prefab, OUT_OBJECTS.path_join("%s.tres" % name))
		out[name] = prefab
	_log("object prefabs: %d" % out.size())
	return out

# ====================================================================
#                            characters
# ====================================================================

## `char/<name>/shape.lst` → a placeholder [ArrayMesh] plus a [Skeleton3D].
##
## The original's character is a hierarchy of up to 256 ellipsoids — a unit
## sphere per node with its own scale/rotation/translation. That representation
## is discarded, but it is worth converting once: every node becomes a scaled UV
## sphere welded into a single mesh, and the named joints become real bones.
##
## The point is the [b]joint names[/b]. You get a recognisable, posable Tux on
## day one, and when authored skinned glTF art arrives it drops in against the
## same `neck` / `head` / `left_shldr` / `left_hip` / … skeleton, so the
## procedural animation layer and the migrated keyframes keep working unchanged.
func import_characters(stage: String) -> void:
	var chars: Array[Dictionary] = SPList.load_file(source_dir.path_join("char/characters.lst"))
	ensure_dir("res://resources/characters")
	var count: int = 0
	for rec: Dictionary in chars:
		var dir_name: String = SPList.get_str(rec, "dir")
		if dir_name.is_empty():
			continue
		var src: String = source_dir.path_join("char").path_join(dir_name)
		var built: Dictionary = _build_character(src)
		if built.is_empty():
			continue
		if stage == STAGE_RESOURCES:
			var out_dir: String = "res://resources/characters".path_join(dir_name)
			ensure_dir(out_dir)
			ResourceSaver.save(built["mesh"], out_dir.path_join("placeholder_mesh.res"))
			_save_character_scene(out_dir, dir_name, built)
			_import_keyframes(src, out_dir, built["joints"])
		count += 1
	_log("characters: %d" % count)

## Walk the ellipsoid hierarchy, accumulating each node's transform exactly as
## `CCharShape::Load` does — the `[order]` string is a list of which operations
## to apply and in what order, which is the one genuinely fiddly part.
func _build_character(src: String) -> Dictionary:
	var recs: Array[Dictionary] = SPList.load_file(src.path_join("shape.lst"))
	if recs.is_empty():
		return {}

	var transforms: Dictionary[int, Transform3D] = {0: Transform3D.IDENTITY}
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

		var joint_name: String = SPList.get_str(rec, "joint")
		if not joint_name.is_empty():
			joints.push_back({"name": joint_name, "node": node, "parent": parent,
				"transform": world})
		if SPList.get_float(rec, "vis", -1.0) > 0.0:
			spheres.push_back({"transform": world,
				"color": colors.get(SPList.get_str(rec, "mat"), Color(0.8, 0.8, 0.8))})

	if spheres.is_empty():
		return {}
	return {"mesh": _weld_spheres(spheres), "joints": joints, "transforms": transforms}

## Each visible node is a unit sphere under its accumulated transform. Welding
## them into one [ArrayMesh] turns 34 draw calls into one.
static func _weld_spheres(spheres: Array[Dictionary]) -> ArrayMesh:
	const RINGS := 8
	const SEGMENTS := 12
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	for s: Dictionary in spheres:
		var xf: Transform3D = s["transform"]
		var col: Color = s["color"]
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
## −Z-forward and must not need the same fixup (§3.4).
const MODEL_TO_GODOT := Basis(
	Vector3(-1.0, 0.0, 0.0),
	Vector3(0.0, 0.0, -1.0),
	Vector3(0.0, -1.0, 0.0))

## Scene: `Skeleton3D` with the migrated joint names plus the placeholder mesh.
## Authored art replaces the mesh; the bone names are the contract.
func _save_character_scene(out_dir: String, dir_name: String, built: Dictionary) -> void:
	var root := Node3D.new()
	root.name = dir_name
	root.basis = MODEL_TO_GODOT

	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	root.add_child(skeleton)
	skeleton.owner = root

	var joints: Array = built["joints"]
	var bone_of: Dictionary[int, int] = {}
	for j: Dictionary in joints:
		var idx: int = skeleton.add_bone(j["name"])
		bone_of[j["node"]] = idx
	for j: Dictionary in joints:
		var idx: int = bone_of[j["node"]]
		# Joints chain through non-joint nodes, so walk up to the nearest
		# ancestor that is itself a joint.
		var parent_node: int = j["parent"]
		var guard: int = 0
		while parent_node > 0 and not bone_of.has(parent_node) and guard < 256:
			parent_node = _parent_of(joints, parent_node, built)
			guard += 1
		if bone_of.has(parent_node):
			skeleton.set_bone_parent(idx, bone_of[parent_node])
		skeleton.set_bone_rest(idx, j["transform"])
		skeleton.set_bone_pose_position(idx, j["transform"].origin)

	var mi := MeshInstance3D.new()
	mi.name = "Placeholder"
	mi.mesh = built["mesh"]
	root.add_child(mi)
	mi.owner = root

	var packed := PackedScene.new()
	if packed.pack(root) == OK:
		ResourceSaver.save(packed, out_dir.path_join("%s.tscn" % dir_name))
	root.free()

static func _parent_of(joints: Array, node: int, built: Dictionary) -> int:
	for j: Dictionary in joints:
		if j["node"] == node:
			return j["parent"]
	# Non-joint nodes are not in the joint list; fall back to the transform map,
	# which is keyed by node id and always has an entry.
	var transforms: Dictionary = built["transforms"]
	return -1 if not transforms.has(node) else 0

## `start/finish/wonrace/lostrace.lst` → Godot [Animation] resources on the
## migrated joint names.
func _import_keyframes(src: String, out_dir: String, joints: Array) -> void:
	const CLIPS: Array[String] = ["start", "finish", "wonrace", "lostrace"]
	var library := AnimationLibrary.new()
	for clip: String in CLIPS:
		var path: String = src.path_join("%s.lst" % clip)
		if not FileAccess.file_exists(path):
			continue
		var frames: Array[Dictionary] = SPList.load_file(path)
		if frames.is_empty():
			continue
		var anim := Animation.new()
		# Each record's [time] is a *duration*, not a timestamp — the original
		# advances a cursor per keyframe. Getting this backwards silently
		# collapses every animation onto t = 0.
		var t: float = 0.0
		var pos_track: int = anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(pos_track, NodePath("Skeleton3D:root"))
		var joint_tracks: Dictionary[String, int] = {}
		for j: Dictionary in joints:
			var jname: String = j["name"]
			if joint_tracks.has(jname):
				continue
			var tr: int = anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(tr, NodePath("Skeleton3D:%s" % jname))
			joint_tracks[jname] = tr

		for frame: Dictionary in frames:
			var p: PackedFloat64Array = SPList.get_numbers(frame, "pos")
			if p.size() >= 3:
				anim.position_track_insert_key(pos_track, t,
					Vector3(float(p[0]), float(p[1]), float(p[2])))
			_insert_pair(anim, joint_tracks, "sh", "left_shldr", "right_shldr", frame, t)
			_insert_pair(anim, joint_tracks, "hip", "left_hip", "right_hip", frame, t)
			_insert_pair(anim, joint_tracks, "knee", "left_knee", "right_knee", frame, t)
			_insert_pair(anim, joint_tracks, "ankle", "left_ankle", "right_ankle", frame, t)
			var head: PackedFloat64Array = SPList.get_numbers(frame, "head")
			if head.size() >= 1 and joint_tracks.has("head"):
				anim.rotation_track_insert_key(joint_tracks["head"], t,
					Quaternion(Vector3.RIGHT, deg_to_rad(float(head[0]))))
			var neck: PackedFloat64Array = SPList.get_numbers(frame, "neck")
			if neck.size() >= 1 and joint_tracks.has("neck"):
				anim.rotation_track_insert_key(joint_tracks["neck"], t,
					Quaternion(Vector3.RIGHT, deg_to_rad(float(neck[0]))))
			t += maxf(0.01, SPList.get_float(frame, "time", 0.1))

		anim.length = maxf(t, 0.1)
		library.add_animation(clip, anim)
	if library.get_animation_list().size() > 0:
		ResourceSaver.save(library, out_dir.path_join("animations.res"))

## Keyframe files give left and right in one tag, e.g. `[sh] -20 40`.
static func _insert_pair(anim: Animation, tracks: Dictionary[String, int], tag: String,
		left: String, right: String, frame: Dictionary, t: float) -> void:
	var v: PackedFloat64Array = SPList.get_numbers(frame, tag)
	if v.size() >= 1 and tracks.has(left):
		anim.rotation_track_insert_key(tracks[left], t,
			Quaternion(Vector3.RIGHT, deg_to_rad(float(v[0]))))
	if v.size() >= 2 and tracks.has(right):
		anim.rotation_track_insert_key(tracks[right], t,
			Quaternion(Vector3.RIGHT, deg_to_rad(float(v[1]))))
