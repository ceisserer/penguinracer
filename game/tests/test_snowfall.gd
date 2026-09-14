## Tests for the weather — [SnowFall], ETR's `CFlakes` and `CCurtain`.
##
## Three things are worth asserting and none of them is "does it draw".
##
## [b]The table is the original's.[/b] Every number in [constant
## SnowFall.FLAKE_AREAS] and [constant SnowFall.CURTAINS] comes out of
## `particles.cpp`, and the shape they make together — boxes that sit ahead of
## the player, flakes that get bigger and fall faster the further out they are —
## is what makes three overlapping fields read as one snowfall with depth. A
## transposed column would still render snow.
##
## [b]The follow fraction.[/b] `YDRIFT`/`ZDRIFT` are the whole feel of the
## effect and they are invisible in a still frame: at 1.0 the snow is painted on
## the camera and at 0.0 every flake is a streak. What the drift accumulator has
## to come out as after a metre of travel is arithmetic, so it is checked as
## arithmetic.
##
## [b]The redrawn tiles.[/b] Same standing as the spray's puff atlas: the art is
## licence-blocked, so the tiles are generated, and what they are generated to
## is the originals' measured density. Deterministic, or every capture of a
## snowing course differs from the last for no reason in the frame.
##
## Everything here is plain data — arrays, an [Image], the script-side element
## state — so the group runs headless. The batch itself cannot be: a
## [MultiMesh]'s transforms live in the [RenderingServer] and the dummy renderer
## keeps none of them, so [method SnowFall.flake_field] is what gets asserted
## rather than what came back out of the batch.
class_name TestSnowFall
extends RefCounted

static func run(t: TestCase) -> void:
	_table(t)
	_flake_field(t)
	_curtain_geometry(t)
	_tiles(t)
	var fall := _snowfall(t)
	if fall == null:
		return
	_grades(t, fall)
	_follows_the_player(t, fall)
	_curtain_elements(t, fall)
	fall.queue_free()

static func _snowfall(t: TestCase) -> SnowFall:
	var fall := SnowFall.new()
	var tree := Engine.get_main_loop() as SceneTree
	t.ok(tree != null, "there is a tree to hang the weather in")
	if tree == null:
		fall.free()
		return null
	tree.root.add_child(fall)
	return fall

## The migrated table, read against `CFlakes::Init` and `CCurtain::Init`.
static func _table(t: TestCase) -> void:
	t.begin("snowfall/the table is ETR's")
	t.ok(SnowFall.FLAKE_AREAS.size() == SnowFall.MAX_GRADE + 1
		and SnowFall.CURTAINS.size() == SnowFall.MAX_GRADE + 1,
		"four grades, counting the clear sky at 0")
	t.ok((SnowFall.FLAKE_AREAS[0] as Array).is_empty()
		and (SnowFall.CURTAINS[0] as Array).is_empty(),
		"grade 0 has no snow in it at all — `snow_id < 1` returns from every entry point")
	for grade: int in range(1, SnowFall.MAX_GRADE + 1):
		var areas: Array = SnowFall.FLAKE_AREAS[grade]
		t.ok(areas.size() == 3, "grade %d has ETR's three flake areas" % grade)
		var last_size: float = 0.0
		var last_width: float = 0.0
		for i: int in areas.size():
			var row: Array = areas[i]
			t.ok(float(row[6]) < float(row[7]),
				"grade %d area %d has a size range, not a point" % [grade, i])
			t.ok(float(row[7]) > last_size,
				"grade %d area %d holds bigger flakes than the one inside it" % [grade, i])
			t.ok(float(row[1]) > last_width,
				"grade %d area %d is wider than the one inside it" % [grade, i])
			last_size = float(row[7])
			last_width = float(row[1])
		# `zback` is subtracted from the player's z and the course runs down −z,
		# so the two outer boxes sitting at +2 and +10 is what puts them in
		# front of the camera rather than around it.
		t.ok(float(areas[1][4]) > 0.0 and float(areas[2][4]) > float(areas[1][4]),
			"grade %d stacks its outer areas ahead of the player" % grade)
		var curtains: Array = SnowFall.CURTAINS[grade]
		t.ok(curtains.size() == 3, "grade %d has ETR's three curtains" % grade)
		for row: Array in curtains:
			t.ok(float(row[1]) >= 40.0 and float(row[1]) <= 60.0,
				"a curtain stands 40–60 m out")
			t.ok(int(row[6]) >= 1 and int(row[6]) <= 3, "and is drawn with one of the three tiles")
	# Heavier snow is more flakes, not bigger ones, which is the distinction the
	# grade table makes and a single "density" scalar could not.
	t.ok(int(SnowFall.FLAKE_AREAS[1][0][0]) < int(SnowFall.FLAKE_AREAS[2][0][0])
		and int(SnowFall.FLAKE_AREAS[2][0][0]) < int(SnowFall.FLAKE_AREAS[3][0][0]),
		"each grade puts more flakes in the near box than the one below it")

## What one area is filled with: everything inside the box, at a size the row
## allows, and the same field on every run.
static func _flake_field(t: TestCase) -> void:
	t.begin("snowfall/a flake area")
	var row: Array = SnowFall.FLAKE_AREAS[3][2]
	var rng := RandomNumberGenerator.new()
	rng.seed = SnowFall.SEED
	var field: Array[Vector4] = SnowFall.flake_field(row, rng)
	t.ok(field.size() == int(row[0]), "as many flakes as the row asks for")
	var extent := Vector3(float(row[1]), float(row[3]), float(row[5]))
	var inside: bool = true
	var sized: bool = true
	for flake: Vector4 in field:
		inside = inside and flake.x >= 0.0 and flake.x < extent.x \
			and flake.y >= 0.0 and flake.y < extent.y \
			and flake.z >= 0.0 and flake.z < extent.z
		sized = sized and flake.w >= float(row[6]) and flake.w <= float(row[7])
	t.ok(inside, "every flake starts inside the box, in box-local metres")
	t.ok(sized, "and at a size between the row's two ends")
	var again := RandomNumberGenerator.new()
	again.seed = SnowFall.SEED
	t.ok(SnowFall.flake_field(row, again) == field,
		"the field is deterministic — a capture of a snowing course is comparable")

## `TCurtain::CurtainVec`. The sign flip either side of ±90° is the whole of it,
## and getting it wrong puts the back of the ring in front of the player, where
## it reads as a wall.
static func _curtain_geometry(t: TestCase) -> void:
	t.begin("snowfall/the curtain ring")
	var ahead: Vector3 = SnowFall.curtain_vector(0.0, 50.0)
	t.ok(absf(ahead.x) < 1e-4 and absf(ahead.z + 50.0) < 1e-4,
		"zero degrees is straight down the course, at −z")
	var behind: Vector3 = SnowFall.curtain_vector(180.0, 50.0)
	t.ok(absf(behind.z - 50.0) < 1e-3, "and 180° is behind you")
	var right: Vector3 = SnowFall.curtain_vector(90.0, 50.0)
	t.ok(absf(right.x - 50.0) < 1e-4 and absf(right.z) < 1e-3, "90° is beside you")
	for angle: float in [-100.0, -45.0, 0.0, 37.5, 90.0, 140.0]:
		t.ok(absf(SnowFall.curtain_vector(angle, 50.0).length() - 50.0) < 1e-3,
			"every element of a ring stands the same distance out (%.1f°)" % angle)

## The redrawn `snow1/2/3.png`: as dense as the originals measure, white with
## the alpha doing the shaping, wrapped at the edges, and the same tile twice.
static func _tiles(t: TestCase) -> void:
	t.begin("snowfall/the redrawn curtain tiles")
	# Measured off `etr-0.8.4/data/textures/snow<n>.png` by connected component.
	var target: Array[float] = [0.0, 0.015, 0.046, 0.147]
	var last_coverage: float = 0.0
	for density: int in range(1, 4):
		var img: Image = SnowFall.make_curtain_image(density)
		t.ok(img.get_width() == SnowFall.CURTAIN_TILE
			and img.get_height() == SnowFall.CURTAIN_TILE,
			"tile %d is ETR's 512²" % density)
		var covered: int = 0
		var white: bool = true
		var border: int = 0
		for y: int in range(0, SnowFall.CURTAIN_TILE, 2):
			for x: int in range(0, SnowFall.CURTAIN_TILE, 2):
				var c: Color = img.get_pixel(x, y)
				if c.a <= 0.0625:
					continue
				covered += 1
				white = white and c.r > 0.99 and c.g > 0.99 and c.b > 0.99
				if x < 8 or y < 8 or x >= SnowFall.CURTAIN_TILE - 8 \
						or y >= SnowFall.CURTAIN_TILE - 8:
					border += 1
		var coverage: float = float(covered) / float(
			(SnowFall.CURTAIN_TILE / 2) * (SnowFall.CURTAIN_TILE / 2))
		t.ok(absf(coverage - target[density]) < 0.4 * target[density],
			"tile %d covers %.1f%% against the original's %.1f%%" % [
				density, coverage * 100.0, target[density] * 100.0])
		t.ok(coverage > last_coverage, "tile %d is denser than tile %d" % [density, density - 1])
		last_coverage = coverage
		t.ok(white, "tile %d is white — the tint carries `[partcol]`, the alpha the shape" % density)
		# Specks are wrapped rather than kept clear of the edges: a flake-free
		# border repeats across every quad of a ring and reads as a grid.
		t.ok(border > 0, "tile %d snows right up to its own edges" % density)
	t.ok(SnowFall.make_curtain_image(2).get_data()
		== SnowFall.make_curtain_image(2).get_data(),
		"a tile is deterministic — no RNG that is not seeded")

## Asking for a grade builds it; asking for none builds nothing.
static func _grades(t: TestCase, fall: SnowFall) -> void:
	t.begin("snowfall/grades")
	fall.set_grade(0)
	t.ok(fall._areas.is_empty() and fall._curtains.is_empty(),
		"grade 0 is `snow_id < 1`: nothing is built and nothing is drawn")
	fall.set_grade(3)
	t.ok(fall._areas.size() == 3 and fall._curtains.size() == 3,
		"grade 3 builds three areas and three curtains")
	t.ok(fall._areas[2].node.multimesh.instance_count
		== int(SnowFall.FLAKE_AREAS[3][2][0]),
		"the far box holds the thousand flakes the table asks for")
	for curtain: SnowFall.Curtain in fall._curtains:
		t.ok(curtain.cols > 1 and curtain.cols <= SnowFall.MAX_CURTAIN_COLS,
			"a ring is cut into 2..16 quads, as `MAX_CURTAIN_COLS` allows")
		t.ok(curtain.node.multimesh.instance_count == curtain.cols * curtain.rows,
			"and every column carries every row")
		# A ring has to close far enough for the arc it covers; a quad narrower
		# than `angle_dist` would leave gaps you can see the sky through.
		t.ok(absf(curtain.angle_dist
			- atan(curtain.size / 2.0 / curtain.z_dist) * 360.0 / PI) < 1e-4,
			"the arc one quad subtends is the original's expression")
	t.ok(fall._areas[0].node.cast_shadow
		== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"a thousand flakes do not each cast a shadow map entry")
	fall.set_grade(7)
	t.ok(fall.grade == SnowFall.MAX_GRADE, "a grade out of range is clamped, not crashed")

## The load-bearing fraction: the snow follows the player, and not exactly.
static func _follows_the_player(t: TestCase, fall: SnowFall) -> void:
	t.begin("snowfall/the snow follows the player, and not exactly")
	fall.set_grade(2)
	fall.restart()
	var at := Vector3(10.0, 100.0, -20.0)
	fall.update(at, null, 1.0 / 60.0)
	var area: SnowFall.FlakeArea = fall._areas[0]
	t.ok(area.drift.is_equal_approx(Vector3.ZERO),
		"the first frame establishes where the player is rather than moving the snow by it")
	t.ok(absf(area.fall - area.speed / 60.0) < 1e-5,
		"and the flakes have fallen one frame's worth")

	# One metre down the hill (−z), one metre of drop, one metre sideways.
	fall.update(at + Vector3(1.0, -1.0, -1.0), null, 1.0 / 60.0)
	var drift: Vector3 = area.drift
	t.ok(absf(drift.x - fposmod(-1.0, area.extent.x)) < 1e-4,
		"a flake does not follow the player sideways at all — ETR's x has only wind in it")
	t.ok(absf(drift.y - fposmod((SnowFall.Y_DRIFT - 1.0) * -1.0, area.extent.y)) < 1e-4,
		"it follows %d%% of the drop, so a fifth of it is left behind" % int(SnowFall.Y_DRIFT * 100.0))
	t.ok(absf(drift.z - fposmod((SnowFall.Z_DRIFT - 1.0) * -1.0, area.extent.z)) < 1e-4,
		"and %d%% of the travel down the hill" % int(SnowFall.Z_DRIFT * 100.0))
	t.ok(drift.x >= 0.0 and drift.x < area.extent.x
		and drift.y >= 0.0 and drift.y < area.extent.y
		and drift.z >= 0.0 and drift.z < area.extent.z,
		"the accumulator is kept inside the box, so a long race cannot walk it out of range")
	# The box itself follows exactly; it is the flakes inside it that lag.
	t.ok(fall._areas[0].node.global_position.is_equal_approx(
		at + Vector3(1.0, -1.0, -1.0) + area.offset),
		"the box is pinned to the racer being watched")

	var before: float = area.fall
	fall.update(at, null, 0.0)
	t.ok(is_equal_approx(area.fall, before), "a zero-length frame moves nothing")
	fall.restart()
	t.ok(area.drift.is_equal_approx(Vector3.ZERO) and is_zero_approx(area.fall),
		"a restart puts the weather back to the start of the run")

## `TCurtain::Update`: the rings turn, sink, and wrap in both.
static func _curtain_elements(t: TestCase, fall: SnowFall) -> void:
	t.begin("snowfall/the curtains turn and sink")
	fall.set_grade(3)
	fall.restart()
	var curtain: SnowFall.Curtain = fall._curtains[0]
	var first_angle: float = curtain.angles[0]
	var first_height: float = curtain.heights[0]
	t.ok(absf(first_angle - curtain.start_angle) < 1e-4,
		"a ring starts at `startangle`, which is ETR's −100°")
	t.ok(absf(first_height - curtain.min_height) < 1e-4, "and the bottom row at `minheight`")
	var at := Vector3(0.0, 50.0, 0.0)
	fall.update(at, null, 1.0 / 60.0)
	for step: int in 60:
		fall.update(at, null, 1.0 / 60.0)
	t.ok(curtain.heights[0] < first_height,
		"a second later the ring has sunk")
	t.ok(absf(curtain.heights[0] - (first_height - curtain.speed * 61.0 / 60.0)) < 1e-3,
		"at `speed` metres a second, which is ETR's 3")
	t.ok(curtain.angles[0] != first_angle, "and turned, because the oscillators run")
	var lowest: bool = true
	var in_arc: bool = true
	for i: int in curtain.angles.size():
		in_arc = in_arc and curtain.angles[i] >= curtain.start_angle - curtain.angle_dist \
			and curtain.angles[i] <= curtain.last_angle + curtain.angle_dist
		lowest = lowest and curtain.heights[i] >= curtain.min_height - curtain.size
	t.ok(in_arc, "every element stays inside the arc the ring covers")
	t.ok(lowest, "and above the floor it wraps at")

	# Ten minutes at 60 fps, which is longer than any course: the wrap has to
	# hold, or the rings sink out of the frame and the snow simply stops.
	for step: int in 3600:
		fall.update(at, null, 1.0 / 60.0)
	var held: bool = true
	for i: int in curtain.heights.size():
		held = held and curtain.heights[i] >= curtain.min_height - curtain.size \
			and curtain.heights[i] <= curtain.min_height + float(curtain.rows) * curtain.size
	t.ok(held, "ten minutes in, the rings are still standing where they started")
