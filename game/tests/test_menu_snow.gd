## The main menu's snow ([MenuSnow]): that it falls, that the pointer scatters
## it the way ETR's does — harder near the pointer and on bigger flakes — and
## that a still pointer does nothing. A still frame shows none of that.
##
## Loaded by path, not named, for the reason [TestHUD] gives.
class_name TestMenuSnow
extends RefCounted

const SNOW_SCRIPT := "res://scripts/shell/menu_snow.gd"
const DT := 1.0 / 60.0

static func run(t: TestCase) -> void:
	_falls(t)
	_push(t)
	_deterministic(t)

static func _make(count: int) -> Control:
	var snow: Control = load(SNOW_SCRIPT).new()
	snow.size = Vector2(1000.0, 500.0)
	snow.seed_flakes(count)
	return snow

## Left alone for a minute, every flake moves down and none leaves the sides.
## Then long enough for the smallest to have wrapped: still all on the screen.
static func _falls(t: TestCase) -> void:
	t.begin("menu_snow/falls")
	var snow: Control = _make(200)
	t.eq_f(snow.flake_count(), 200, 0.0, "the field is the count it was seeded with")
	var before: Array[Vector2] = []
	for i: int in 200:
		before.append(snow.flake_position(i))
	for _f: int in 60:
		snow.step(DT)
	var fell := 0
	var drifted := 0
	for i: int in 200:
		var p: Vector2 = snow.flake_position(i)
		if p.y > before[i].y or p.y < 0.0:
			fell += 1
		if p.x != before[i].x:
			drifted += 1
	t.eq_f(fell, 200, 0.0, "every flake falls (or has wrapped to the top)")
	t.eq_f(drifted, 0, 0.0, "nothing moves sideways without a push")
	for _f: int in 60 * 600:
		snow.step(DT)
	var inside := true
	for i: int in 200:
		var p: Vector2 = snow.flake_position(i)
		inside = inside and p.x >= -0.05 and p.x <= 1.05 and p.y <= 1.05 \
				and p.y >= -float(load(SNOW_SCRIPT).BASE_VELOCITY)
	t.ok(inside, "ten minutes on, every flake is still on the screen")
	snow.free()

## A sweep to the right pushes flakes right, a near one more than a far one of
## the same size, a big one more than a small one at the same place.
static func _push(t: TestCase) -> void:
	t.begin("menu_snow/push")
	var snow: Control = _make(400)
	snow.push(Vector2(500.0, 250.0), true)
	snow.step(DT)
	var before: Array[Vector2] = []
	for i: int in 400:
		before.append(snow.flake_position(i))
	snow.push(Vector2(520.0, 250.0))
	snow.step(DT)
	for _f: int in 10:
		snow.step(DT)
	var near_moved := 0.0
	var near_n := 0
	var far_moved := 0.0
	var far_n := 0
	var big_moved := 0.0
	var big_n := 0
	var small_moved := 0.0
	var small_n := 0
	var leftward := 0
	for i: int in 400:
		var dx: float = snow.flake_position(i).x - before[i].x
		if dx < 0.0:
			leftward += 1
		var d: float = before[i].distance_to(Vector2(0.51, 0.5))
		var per_size: float = dx / snow.flake_size(i)
		if d < 0.1:
			near_moved += per_size
			near_n += 1
		elif d > 0.3:
			far_moved += per_size
			far_n += 1
		if d < 0.2:
			if snow.flake_size(i) > 8.0:
				big_moved += dx
				big_n += 1
			elif snow.flake_size(i) < 4.0:
				small_moved += dx
				small_n += 1
	t.eq_f(leftward, 0, 0.0, "a push to the right moves nothing left")
	t.ok(near_n > 0 and far_n > 0 and big_n > 0 and small_n > 0, "the field has flakes in every bin")
	t.ok(near_moved / near_n > 5.0 * far_moved / far_n, "a flake by the pointer is pushed further than one across the screen")
	t.ok(big_moved / big_n > 2.0 * small_moved / small_n, "a big flake is pushed further than a small one")
	snow.free()

## Two fields from the same seed through the same frames are the same field —
## what keeps a capture of the menu from reshuffling it.
static func _deterministic(t: TestCase) -> void:
	t.begin("menu_snow/deterministic")
	var a: Control = _make(100)
	var b: Control = _make(100)
	for f: int in 300:
		if f == 100:
			a.push(Vector2(300.0, 200.0), true)
			b.push(Vector2(300.0, 200.0), true)
		if f == 101:
			a.push(Vector2(340.0, 230.0))
			b.push(Vector2(340.0, 230.0))
		a.step(DT)
		b.step(DT)
	var same := true
	for i: int in 100:
		same = same and a.flake_position(i) == b.flake_position(i)
	t.ok(same, "same seed, same frames, same flakes")
	a.free()
	b.free()
