## The flakes on the lens ([LensSnow]): that they keep out of the middle, that
## more snow puts more on the lens and a faster camera catches more, that each
## one melts away, and that a run reproduces. A still frame shows none of that.
class_name TestLensSnow
extends RefCounted

const DT := 1.0 / 60.0

static func run(t: TestCase) -> void:
	_middle_stays_clear(t)
	_grades(t)
	_speed(t)
	_melts(t)
	_deterministic(t)
	_blobs(t)

static func _make(grade: int) -> LensSnow:
	var lens := LensSnow.new()
	lens.set_grade(grade)
	return lens

## Heavy snow at full speed for two minutes, on a wide and a narrow canvas:
## no flake's disc ever reaches the ellipse the penguin rides in.
static func _middle_stays_clear(t: TestCase) -> void:
	t.begin("lens_snow/middle_stays_clear")
	for aspect: float in [16.0 / 9.0, 4.0 / 3.0, 9.0 / 16.0]:
		var lens := _make(3)
		lens.aspect = aspect
		var clear := true
		var seen := 0
		for _f: int in 60 * 120:
			lens.step(LensSnow.MAX_FACTOR, DT)
			for i: int in lens.flake_count():
				seen += 1
				clear = clear and LensSnow.is_clear(lens.flake_position(i),
					lens.flake_radius(i), aspect)
		t.ok(seen > 0, "flakes land at aspect %.2f" % aspect)
		t.ok(clear, "none covers the middle at aspect %.2f" % aspect)
		lens.free()
	t.ok(not LensSnow.is_clear(LensSnow.CLEAR_CENTRE, 0.01, 16.0 / 9.0),
		"the centre itself is not clear")
	t.ok(LensSnow.is_clear(Vector2(0.02, 0.05), 0.08, 16.0 / 9.0),
		"a corner is")

## Average flakes on the lens over a minute: none without snow, more with each
## grade, never over the grade's cap.
static func _grades(t: TestCase) -> void:
	t.begin("lens_snow/grades")
	var means: Array[float] = []
	for grade: int in 4:
		var lens := _make(grade)
		var total := 0
		var capped := true
		for _f: int in 60 * 60:
			lens.step(1.0, DT)
			total += lens.flake_count()
			capped = capped and lens.flake_count() <= int(LensSnow.GRADES[grade][0])
		means.push_back(float(total) / (60.0 * 60.0))
		t.ok(capped, "grade %d stays under its cap" % grade)
		lens.free()
	t.eq_f(means[0], 0.0, 0.0, "no snow, no flakes")
	t.ok(means[1] > 0.0 and means[1] < means[2] and means[2] < means[3],
		"more snow, more on the lens (%.2f / %.2f / %.2f)" % [means[1], means[2], means[3]])
	t.ok(means[3] < 5.0, "only a few even in the heaviest (%.2f)" % means[3])

## A lens riding into the snow catches more than one standing still, and one
## looking away from its motion catches only what falls on it.
static func _speed(t: TestCase) -> void:
	t.begin("lens_snow/speed")
	var ahead := Vector3(0.0, -0.3, -1.0).normalized()
	var still: float = LensSnow.landing_factor(Vector3.ZERO, ahead)
	var racing: float = LensSnow.landing_factor(Vector3(0.0, -6.0, -20.0), ahead)
	var backward: float = LensSnow.landing_factor(Vector3(0.0, 0.0, 20.0), ahead)
	t.ok(still < 0.3, "a still lens catches little (%.2f)" % still)
	t.ok(racing >= 1.0 and racing <= LensSnow.MAX_FACTOR, "a racing one its grade's rate (%.2f)" % racing)
	t.eq_f(backward, LensSnow.STILL_SHARE, 1e-6, "a lens backing away catches only the floor")

## Stop the landings and every flake is gone within the longest stay, fading
## and shrinking on the way out.
static func _melts(t: TestCase) -> void:
	t.begin("lens_snow/melts")
	var lens := _make(3)
	while lens.flake_count() == 0:
		lens.step(LensSnow.MAX_FACTOR, DT)
	var alpha_at_full := -1.0
	var radius_at_full := 0.0
	for _f: int in 10:
		lens.step(0.0, DT)
	if lens.flake_count() > 0:
		alpha_at_full = lens.flake_alpha(0)
		radius_at_full = lens.flake_radius(0)
	var faded := true
	var shrank := true
	var last_alpha: float = alpha_at_full
	while lens.flake_count() > 0 and lens.flake_alpha(0) > 0.05:
		lens.step(0.0, DT)
		if lens.flake_count() > 0:
			faded = faded and lens.flake_alpha(0) <= last_alpha + 1e-6
			last_alpha = lens.flake_alpha(0)
			shrank = shrank and lens.flake_radius(0) <= radius_at_full + 1e-6
	t.eq_f(alpha_at_full, 1.0, 1e-6, "a landed flake is at full strength")
	t.ok(faded, "it only ever fades after landing")
	t.ok(shrank, "and never grows")
	for _f: int in int(float(LensSnow.GRADES[3][5]) / DT) + 1:
		lens.step(0.0, DT)
	t.eq_f(lens.flake_count(), 0, 0.0, "all melted within the longest stay")
	lens.free()

static func _deterministic(t: TestCase) -> void:
	t.begin("lens_snow/deterministic")
	var a := _make(2)
	var b := _make(2)
	var same := true
	for f: int in 60 * 30:
		var factor: float = 0.5 + 0.5 * sin(float(f) * 0.01)
		a.step(factor, DT)
		b.step(factor, DT)
		same = same and a.flake_count() == b.flake_count()
		for i: int in mini(a.flake_count(), b.flake_count()):
			same = same and a.flake_position(i) == b.flake_position(i)
	t.ok(same, "same seed, same frames, same lens")
	a.restart()
	var first: Array[Vector2] = []
	while a.flake_count() == 0:
		a.step(1.0, DT)
	first.push_back(a.flake_position(0))
	a.restart()
	while a.flake_count() == 0:
		a.step(1.0, DT)
	t.ok(a.flake_position(0) == first[0], "a restart replays the same landings")
	a.free()
	b.free()

## Every cell is a soft blob: solid in the middle, nothing at its corners.
static func _blobs(t: TestCase) -> void:
	t.begin("lens_snow/blobs")
	var img: Image = LensSnow.make_blob_image()
	var cell: int = LensSnow.BLOB_CELL
	t.eq_f(img.get_width(), LensSnow.BLOB_CELLS * cell, 0.0, "the atlas is its cells")
	var shaped := true
	for q: int in LensSnow.BLOB_CELLS * LensSnow.BLOB_CELLS:
		var o := Vector2i((q % LensSnow.BLOB_CELLS) * cell, (q / LensSnow.BLOB_CELLS) * cell)
		shaped = shaped and img.get_pixel(o.x + cell / 2, o.y + cell / 2).a > 0.4
		shaped = shaped and img.get_pixel(o.x + 1, o.y + 1).a == 0.0
		shaped = shaped and img.get_pixel(o.x + cell - 2, o.y + cell - 2).a == 0.0
	t.ok(shaped, "every cell is a blob with clear corners")
	t.ok(LensSnow.make_blob_image().get_data() == img.get_data(), "and the same every time")
