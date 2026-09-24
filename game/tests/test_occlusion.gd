## Tests for the terrain's baked ambient occlusion ([TerrainOcclusion]) and the
## per-course images the importer writes from it.
##
## What the shader does with it cannot be observed headless, so this holds the
## two things that can go quietly wrong before it gets there: the bake has to
## darken what is enclosed and leave what is open alone — an occlusion that
## greys the whole hill is an ambient gain nobody fitted — and every course has
## to carry an image on its own heightmap grid, or [TerrainRenderer] drops it
## without a word and the course renders as ETR's evenly lit hill.
class_name TestOcclusion
extends RefCounted

static func run(t: TestCase) -> void:
	_open_ground_is_open(t)
	_a_gully_is_darker_at_the_bottom(t)
	_the_foot_of_a_bank(t)
	_every_course_carries_it(t)

## A `w`×`h` grid at 0.5 m, relief from `f(x_m, z_m)`.
static func _grid(w: int, h: int, f: Callable) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(w * h)
	for y: int in h:
		for x: int in w:
			out[y * w + x] = f.call(float(x) * 0.5, float(y) * 0.5)
	return out

static func _open_ground_is_open(t: TestCase) -> void:
	t.begin("occlusion/open ground")
	var w: int = 41
	var flat: PackedFloat32Array = _grid(w, w, func(_x: float, _z: float) -> float: return 1.5)
	var img: Image = TerrainOcclusion.bake(flat, w, w, Vector2(20.0, 20.0))
	t.ok(img.get_format() == Image.FORMAT_L8 and img.get_size() == Vector2i(w, w),
		"one byte per heightmap vertex")
	var lo: int = 255
	for b: int in img.get_data():
		lo = mini(lo, b)
	t.ok(lo == 255, "flat relief sees the whole sky (darkest %d)" % lo)
	# The base slope is analytic and never in the heightmap; a ridge line — a
	# convex crest — has nothing above it either.
	var crest: PackedFloat32Array = _grid(w, w,
		func(x: float, _z: float) -> float: return -absf(x - 10.0) * 0.5)
	img = TerrainOcclusion.bake(crest, w, w, Vector2(20.0, 20.0))
	t.ok(img.get_pixel(20, 20).r8 == 255, "a crest is open sky")

static func _a_gully_is_darker_at_the_bottom(t: TestCase) -> void:
	t.begin("occlusion/gully")
	var w: int = 41
	# A 45° V across X, 10 m wide.
	var v: PackedFloat32Array = _grid(w, w,
		func(x: float, _z: float) -> float: return minf(absf(x - 10.0), 5.0))
	var img: Image = TerrainOcclusion.bake(v, w, w, Vector2(20.0, 20.0))
	var bottom: float = TerrainOcclusion.at(img, 20, 20)
	var wall: float = TerrainOcclusion.at(img, 26, 20)
	var rim: float = TerrainOcclusion.at(img, 38, 20)
	t.ok(bottom < wall and wall < rim,
		"darker down the wall: bottom %.2f < wall %.2f < rim %.2f" % [bottom, wall, rim])
	# Two 45° walls take sin²45° = half of each of the six azimuths that see
	# them, fading with distance — well short of half the sky, well over none.
	t.between(bottom, 0.5, 0.9, "a 45° gully floor keeps most of its sky")

static func _the_foot_of_a_bank(t: TestCase) -> void:
	t.begin("occlusion/bank")
	var w: int = 41
	# A 2 m step up at x = 10 m, a metre wide.
	var bank: PackedFloat32Array = _grid(w, w,
		func(x: float, _z: float) -> float: return clampf(x - 10.0, 0.0, 1.0) * 2.0)
	var img: Image = TerrainOcclusion.bake(bank, w, w, Vector2(20.0, 20.0))
	var foot: float = TerrainOcclusion.at(img, 19, 20)
	var away: float = TerrainOcclusion.at(img, 2, 20)
	var top: float = TerrainOcclusion.at(img, 30, 20)
	t.ok(foot < away, "the foot of a bank is shaded by it (%.2f < %.2f)" % [foot, away])
	t.ok(top > foot, "the top of the bank is not (%.2f > %.2f)" % [top, foot])

static func _every_course_carries_it(t: TestCase) -> void:
	t.begin("occlusion/every course")
	var catalog: CourseCatalog = CourseCatalog.load_default()
	if catalog == null:
		t.ok(false, "the course catalog is on disk")
		return
	for listing: CourseListing in catalog.entries:
		if not ResourceLoader.exists(listing.course_path):
			continue  # a streamed web build; `TestPackStream` owns that case
		var course: CourseData = load(listing.course_path) as CourseData
		var ao: Image = course.ambient_occlusion
		var ok: bool = ao != null and ao.get_format() == Image.FORMAT_L8 \
			and ao.get_size() == course.heightmap.get_size()
		t.ok(ok, "%s: occlusion on the heightmap's own grid" % listing.dir)
