## Tests for the weather — [SnowFall], ETR's `CFlakes`, and the far snow that
## replaces its `CCurtain` rings.
##
## Three things are worth asserting and none of them is "does it draw".
##
## [b]The table is the original's.[/b] Every number in [constant
## SnowFall.FLAKE_AREAS] comes out of `particles.cpp`, and the shape they make
## together — boxes that sit ahead of
## the player, flakes that get bigger and fall faster the further out they are —
## is what makes three overlapping fields read as one snowfall with depth. A
## transposed column would still render snow.
##
## [b]The snow stays where it is.[/b] The box follows the player and the flakes
## in it do not — ETR's `YDRIFT`/`ZDRIFT` half-follow is deliberately gone, see
## [SnowFall]. That is invisible in a still frame, and what the drift
## accumulator has to come out as after a metre of travel is arithmetic, so it
## is checked as arithmetic.
##
## [b]The far snow reaches past the near.[/b] [constant SnowFall.FAR_AREAS] is
## not ETR's, but it has to start where the near boxes stop and reach where the
## curtains stood, or there is a band of the hill with no snow in it.
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
	_far_snow(t)
	_tiles(t)
	var fall := _snowfall(t)
	if fall == null:
		return
	_grades(t, fall)
	_follows_the_player(t, fall)
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

## The migrated table, read against `CFlakes::Init`.
static func _table(t: TestCase) -> void:
	t.begin("snowfall/the table is ETR's")
	t.ok(SnowFall.FLAKE_AREAS.size() == SnowFall.MAX_GRADE + 1
		and SnowFall.FAR_AREAS.size() == SnowFall.MAX_GRADE + 1,
		"four grades, counting the clear sky at 0")
	t.ok((SnowFall.FLAKE_AREAS[0] as Array).is_empty()
		and (SnowFall.FAR_AREAS[0] as Array).is_empty(),
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

## The far snow: a box that covers the shell it is drawn in, starting where the
## near boxes stop, with patches that are the curtains' specks.
static func _far_snow(t: TestCase) -> void:
	t.begin("snowfall/the far snow")
	var band: Vector4 = SnowFall.FAR_FADE
	t.ok(band.x < band.y and band.y <= band.z and band.z < band.w,
		"it fades in, holds, and fades out again, in that order")
	t.ok(band.z >= 60.0, "and holds out to where the curtains' furthest ring stood")
	var last_tile: int = 0
	for grade: int in range(1, SnowFall.MAX_GRADE + 1):
		var row: Array = SnowFall.FAR_AREAS[grade]
		var near_far_edge: float = 0.0
		for near: Array in SnowFall.FLAKE_AREAS[grade]:
			near_far_edge = maxf(near_far_edge, float(near[4]) + float(near[5]))
		t.ok(band.x <= near_far_edge,
			"grade %d starts fading in before the near boxes end, at %.0f m" % [grade, near_far_edge])
		# Ahead is −z: the box's front face is `zback + zrange` in front of the
		# player, and the camera is a few metres behind them.
		t.ok(float(row[4]) + float(row[5]) >= band.w,
			"grade %d reaches past where it has faded out ahead" % grade)
		t.ok(float(row[1]) * 0.5 >= band.w,
			"and either side, so a slalom still looks into snow")
		t.ok(-float(row[4]) >= band.w,
			"and behind, so a camera looking back up the hill still sees it")
		t.ok(int(row[8]) >= 1 and int(row[8]) <= 3 and int(row[8]) >= last_tile,
			"grade %d cuts its patches from tile %d, no sparser than the grade below" % [grade, int(row[8])])
		last_tile = int(row[8])
		var rng := RandomNumberGenerator.new()
		rng.seed = SnowFall.SEED
		var field: Array[Vector4] = SnowFall.flake_field(row, rng)
		var sized: bool = true
		for patch: Vector4 in field:
			sized = sized and patch.w >= float(row[6]) and patch.w <= float(row[7])
		t.ok(field.size() == int(row[0]) and sized,
			"grade %d fills its box with patches of the row's size" % grade)

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
	t.ok(fall._areas.is_empty(),
		"grade 0 is `snow_id < 1`: nothing is built and nothing is drawn")
	fall.set_grade(3)
	t.ok(fall._areas.size() == 4,
		"grade 3 builds three near areas and the far one")
	t.ok(fall._areas[2].node.multimesh.instance_count
		== int(SnowFall.FLAKE_AREAS[3][2][0]),
		"the furthest near box holds the thousand flakes the table asks for")
	t.ok(fall._areas[3].node.multimesh.instance_count == int(SnowFall.FAR_AREAS[3][0]),
		"and the far snow the patches its row asks for")
	t.ok(fall._areas[3].node.name == "FarSnow", "last, and named for what it is")
	t.ok(fall._areas[0].node.cast_shadow
		== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"a thousand flakes do not each cast a shadow map entry")
	t.ok(fall._areas[3].node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"and neither does the far snow")
	fall.set_grade(7)
	t.ok(fall.grade == SnowFall.MAX_GRADE, "a grade out of range is clamped, not crashed")

## The box rides with the player; the flakes stay in the world.
static func _follows_the_player(t: TestCase, fall: SnowFall) -> void:
	t.begin("snowfall/the box follows the player, the snow does not")
	fall.set_grade(2)
	fall.restart()
	var at := Vector3(10.0, 100.0, -20.0)
	fall.update(at, null, 1.0 / 60.0)
	var area: SnowFall.FlakeArea = fall._areas[0]
	t.ok(area.drift.is_equal_approx(Vector3.ZERO),
		"the first frame establishes where the player is rather than moving the snow by it")
	t.ok(absf(area.fall - SnowFall.FALL_SPEED / 60.0) < 1e-5,
		"and the flakes have fallen one frame's worth, at the real fall speed")

	# One metre down the hill (−z), one metre of drop, one metre sideways.
	var moved := Vector3(1.0, -1.0, -1.0)
	fall.update(at + moved, null, 1.0 / 60.0)
	var drift: Vector3 = area.drift
	t.ok(drift.is_equal_approx((-moved).posmodv(area.extent)),
		"the drift takes the box's whole move back out, on every axis — no flake is dragged along")
	t.ok(drift.x >= 0.0 and drift.x < area.extent.x
		and drift.y >= 0.0 and drift.y < area.extent.y
		and drift.z >= 0.0 and drift.z < area.extent.z,
		"the accumulator is kept inside the box, so a long race cannot walk it out of range")
	t.ok(fall._areas[0].node.global_position.is_equal_approx(at + moved + area.offset),
		"the box is pinned to the racer being watched")

	# A flake's world position is the box corner plus its wrapped local one; for
	# a flake the wrap did not move, that sum must not have changed.
	var base := Vector3(2.0, 2.0, 2.0)
	var before_pos: Vector3 = at + area.offset + (base).posmodv(area.extent)
	var after_pos: Vector3 = at + moved + area.offset + (base + drift).posmodv(area.extent)
	t.ok(before_pos.is_equal_approx(after_pos), "so a flake is where it was in the world")

	var before: float = area.fall
	fall.update(at, null, 0.0)
	t.ok(is_equal_approx(area.fall, before), "a zero-length frame moves nothing")
	fall.restart()
	t.ok(area.drift.is_equal_approx(Vector3.ZERO) and is_zero_approx(area.fall)
		and is_zero_approx(fall._clock),
		"a restart puts the weather back to the start of the run")

	var seeds: Dictionary = {}
	var inside: bool = true
	for i: int in 1000:
		var s: Vector2 = SnowFall.flake_seed(i)
		inside = inside and s.x >= 0.0 and s.x < 1.0 and s.y >= 0.0 and s.y < 1.0
		seeds[Vector2i(int(s.x * 100.0), int(s.y * 100.0))] = true
	t.ok(inside, "a flake's own two numbers are in [0, 1)")
	t.ok(seeds.size() > 600, "and a thousand flakes spread over them rather than bunching")
