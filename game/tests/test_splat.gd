## Tests for the generated splat maps — the per-course weight fields under
## `res://courses/<dir>/splat_*.png`.
##
## A splat map is a weight field that happens to be stored as a PNG, and that is
## what makes it easy to break: everything between the importer and the shader
## treats it as a picture. Godot's texture importer defaults
## `process/fix_alpha_border` on, which overwrites the RGB of every
## near-transparent texel with the colour of the nearest opaque one within four
## texels — right for a cutout sprite, ruinous here, where alpha is layer 3's
## weight and "nearly transparent" means "this texel is not mostly layer 3",
## i.e. most of the course. On penguins_cant_fly it rewrote 19 % of the map and
## walked the rock/ice line a metre down the valley wall. Nothing downstream
## could notice: the weights still blended, they just blended the wrong layers,
## and the PNG on disk was correct the whole time.
##
## So the guard is on what the *consumer* gets back, not on what the importer
## wrote. The load-bearing check is the weight sum: the importer renormalises
## every texel to one, and any transformation that mixes texels without
## preserving alpha — the alpha-border bleed, a block-compressed re-import —
## breaks that sum while leaving a perfectly plausible-looking image.
class_name TestSplat
extends RefCounted

## 8-bit quantisation of a renormalised float weight. The worst case across the
## 44 shipped courses is 2; the bleed this exists to catch is off by 85.
const SUM_TOLERANCE := 4

static func run(t: TestCase) -> void:
	var catalog: CourseCatalog = CourseCatalog.load_default()
	t.begin("splat/catalog")
	t.ok(catalog != null and not catalog.entries.is_empty(),
		"the course catalog is on disk")
	if catalog == null:
		return
	for listing: CourseListing in catalog.entries:
		if not ResourceLoader.exists(listing.course_path):
			# A streamed web build has the listing without the course pack;
			# `TestPackStream` owns that case.
			continue
		var course: CourseData = load(listing.course_path) as CourseData
		if course == null:
			t.ok(false, "%s: course.tres loads" % listing.dir)
			continue
		_weights_survived_import(t, listing.dir, course)
		_matches_the_png(t, listing.dir, course)

## Every texel's weights still sum to one across all of the course's splat maps.
static func _weights_survived_import(t: TestCase, dir: String,
		course: CourseData) -> void:
	t.begin("splat/weights (%s)" % dir)
	t.ok(not course.splat_maps.is_empty(), "%s has a splat map" % dir)
	if course.splat_maps.is_empty():
		return

	# The layer table is positional over the concatenated maps, so a five-layer
	# course leaves three channels of `splat_1` at zero by design. Summing every
	# channel of every map is still the right total: an unclaimed channel
	# contributes nothing, and a bleed into one would be a failure too.
	var planes: Array[PackedByteArray] = []
	var size := Vector2i.ZERO
	for map: Texture2D in course.splat_maps:
		var img: Image = map.get_image()
		if img == null:
			t.ok(false, "%s: a splat map has no image" % dir)
			return
		if img.get_format() != Image.FORMAT_RGBA8:
			img = img.duplicate()
			img.convert(Image.FORMAT_RGBA8)
		if planes.is_empty():
			size = img.get_size()
		t.ok(img.get_size() == size, "%s: every splat map is %v" % [dir, size])
		planes.push_back(img.get_data())

	var texels: int = size.x * size.y
	var worst: int = 0
	var worst_at: int = 0
	for i: int in texels:
		var o: int = i * 4
		var sum: int = 0
		for p: PackedByteArray in planes:
			sum += p[o] + p[o + 1] + p[o + 2] + p[o + 3]
		var err: int = absi(sum - 255)
		if err > worst:
			worst = err
			worst_at = i
	t.ok(worst <= SUM_TOLERANCE, "%s: splat weights sum to 1 (worst %d/255 at %v)"
		% [dir, worst, Vector2i(worst_at % size.x, worst_at / size.x)])

## And the texture the game loads is still the file the importer wrote.
##
## Skipped in an exported build, where the source PNG is not shipped — the sum
## check above is the one that travels.
static func _matches_the_png(t: TestCase, dir: String, course: CourseData) -> void:
	t.begin("splat/import (%s)" % dir)
	for m: int in course.splat_maps.size():
		var path: String = "res://courses/%s/splat_%d.png" % [dir, m]
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			continue
		var on_disk := Image.new()
		if on_disk.load_png_from_buffer(bytes) != OK:
			t.ok(false, "%s: splat_%d.png decodes" % [dir, m])
			continue
		on_disk.convert(Image.FORMAT_RGBA8)
		var loaded: Image = course.splat_maps[m].get_image().duplicate()
		# The loaded texture carries the mip chain the shader needs, and
		# `get_data()` returns the whole pyramid. Only level 0 is the file.
		loaded.clear_mipmaps()
		loaded.convert(Image.FORMAT_RGBA8)
		t.ok(loaded.get_data() == on_disk.get_data(),
			"%s: splat_%d survives the texture importer unchanged" % [dir, m])
