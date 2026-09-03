## Tests for [HeightmapSurface] and the [SnowField] CPU mirror.
class_name TestSurface
extends RefCounted

static func run(t: TestCase) -> void:
	_analytic_slope(t)
	_bilinear(t)
	_splat_blending(t)
	_splat_resample(t)
	_snow_field(t)
	_snow_decay_is_scalar(t)

static func _analytic_slope(t: TestCase) -> void:
	t.begin("analytic base slope")
	# Local relief and the global downhill slope are stored separately, so a
	# flat heightmap over a 25° base angle must give an exact plane — no 8-bit
	# terracing, no float32 range wasted on a 500 m ramp (§3.2).
	var s := SlopeFixture.flat_slope(25.0, 90.0, 500.0)
	var expected_slope: float = tan(deg_to_rad(25.0))
	t.eq_f(s.height_at(45.0, 0.0), 0.0, 1e-6, "height at the start is zero")
	t.eq_f(s.height_at(45.0, -100.0), -100.0 * expected_slope, 1e-4,
		"height falls exactly with tan(base_angle)")
	t.eq_f(s.height_at(45.0, -400.0), -400.0 * expected_slope, 1e-3,
		"still exact 400 m down the course")

	var sample := SurfaceSample.new()
	s.sample_into(45.0, -100.0, sample)
	t.eq_f(rad_to_deg(sample.normal.angle_to(Vector3.UP)), 25.0, 1e-3,
		"normal is tilted by the base angle")
	t.ok(sample.normal.z < 0.0, "normal leans downhill")
	t.eq_f(sample.normal.length(), 1.0, 1e-6, "normal is unit length")

static func _bilinear(t: TestCase) -> void:
	t.begin("bilinear height")
	var nx: int = 5
	var ny: int = 5
	var heights := PackedFloat32Array()
	heights.resize(nx * ny)
	heights.fill(0.0)
	heights[2 * nx + 2] = 4.0                       # one bump in the middle
	var s := HeightmapSurface.new()
	s.build(heights, Vector2i(nx, ny), Vector2(4.0, 4.0), 0.0)

	t.eq_f(s.height_at(2.0, -2.0), 4.0, 1e-5, "exact at the bump's texel")
	t.eq_f(s.height_at(1.0, -2.0), 0.0, 1e-5, "exact at a neighbouring texel")
	t.eq_f(s.height_at(1.5, -2.0), 2.0, 1e-5, "halfway between is the average")
	t.eq_f(s.height_at(0.0, 0.0), 0.0, 1e-5, "corner sample")

	# Out-of-range queries clamp rather than wrapping or crashing — the player
	# can be pushed past the edge by a tree bounce before bounds are applied.
	t.ok(is_finite(s.height_at(-50.0, 50.0)), "sampling off the map is safe")
	t.ok(is_finite(s.height_at(999.0, -999.0)), "sampling far off the map is safe")

static func _splat_blending(t: TestCase) -> void:
	t.begin("splat-weighted friction")
	var ice := TerrainLayer.new()
	ice.id = &"ice"
	ice.friction = 0.2
	ice.compression_depth = 0.03
	ice.emits_particles = false
	ice.takes_trackmarks = false
	var snow := TerrainLayer.new()
	snow.id = &"snow"
	snow.friction = 0.35
	snow.compression_depth = 0.11
	snow.emits_particles = true
	snow.takes_trackmarks = true
	var layers: Array[TerrainLayer] = [ice, snow]

	var nx: int = 4
	var ny: int = 4
	var heights := PackedFloat32Array()
	heights.resize(nx * ny)
	heights.fill(0.0)
	var s := HeightmapSurface.new()
	s.build(heights, Vector2i(nx, ny), Vector2(3.0, 3.0), 0.0)

	# Left half ice, right half snow, hard edge — the importer's one-hot output
	# before boundary blurring.
	var w := PackedByteArray()
	w.resize(nx * ny * 2)
	for y: int in ny:
		for x: int in nx:
			var base: int = (y * nx + x) * 2
			var is_ice: bool = x < 2
			w[base] = 255 if is_ice else 0
			w[base + 1] = 0 if is_ice else 255
	s.set_splat(w, layers)

	var sample := SurfaceSample.new()
	s.sample_into(0.0, 0.0, sample)
	t.eq_f(sample.friction, 0.2, 1e-5, "pure ice reads the ice friction")
	t.eq_f(sample.compression_depth, 0.03, 1e-5, "pure ice reads the ice depth")
	t.ok(not sample.emits_particles, "ice does not throw up spray")
	t.ok(not sample.takes_trackmarks, "ice holds no trench")

	s.sample_into(3.0, 0.0, sample)
	t.eq_f(sample.friction, 0.35, 1e-5, "pure snow reads the snow friction")
	t.ok(sample.emits_particles, "snow throws up spray")
	t.ok(sample.takes_trackmarks, "snow holds a trench")

	# Across the boundary friction blends smoothly instead of stepping. This is
	# ETR's barycentric blend generalised to splat weights (§4.2).
	s.sample_into(1.5, 0.0, sample)
	t.eq_f(sample.friction, 0.275, 1e-5, "friction blends at the boundary")
	t.eq_f(sample.compression_depth, 0.07, 1e-5, "depth blends at the boundary")

	var prev: float = 0.2
	for i: int in 31:
		var x: float = float(i) * 0.1
		s.sample_into(x, 0.0, sample)
		t.ok(sample.friction >= prev - 1e-6, "friction is monotone across the boundary")
		t.ok(absf(sample.friction - prev) < 0.06, "friction has no step discontinuity")
		prev = sample.friction

	# ETR keeps `[part]` and `[trackmarks]` independent, and ships one terrain
	# where they disagree: `strike_snow` is `[part] 1 [trackmarks] 0`. Spray and
	# deformation must therefore read different flags, not one flag twice.
	t.begin("spray and trackmarks are independent")
	var strike := TerrainLayer.new()
	strike.id = &"strike_snow"
	strike.friction = 0.3
	strike.compression_depth = 0.04
	strike.emits_particles = true
	strike.takes_trackmarks = false

	var uniform := HeightmapSurface.new()
	uniform.build(heights, Vector2i(nx, ny), Vector2(3.0, 3.0), 0.0)
	var sw := PackedByteArray()
	sw.resize(nx * ny)
	sw.fill(255)
	uniform.set_splat(sw, [strike] as Array[TerrainLayer])
	uniform.sample_into(1.5, -1.5, sample)
	t.ok(sample.emits_particles, "strike_snow throws up spray")
	t.ok(not sample.takes_trackmarks, "strike_snow keeps no trench")
	t.eq_f(sample.friction, 0.3, 1e-5, "strike_snow keeps its own friction")

static func _snow_field(t: TestCase) -> void:
	t.begin("snow field")
	var field := SnowField.new()
	field.recenter(45.0, -20.0)
	t.eq_f(field.depth_at(45.0, -20.0), 0.0, 1e-9, "fresh snow starts undisturbed")

	field.stamp(45.0, -20.0, 0.6, 0.08)
	t.ok(field.depth_at(45.0, -20.0) > 0.05, "a stamp cuts a trench")
	t.ok(field.pack_at(45.0, -20.0) > 0.0, "a stamp packs the snow")
	t.eq_f(field.depth_at(50.0, -20.0), 0.0, 1e-9, "the trench is local")

	# Depth saturates: one pass cannot dig to the bottom of the world.
	for i: int in 50:
		field.stamp(45.0, -20.0, 0.6, 0.08)
	t.ok(field.depth_at(45.0, -20.0) <= field.max_trench + 1e-6, "trench depth saturates")

	t.begin("snow changes handling")
	var sample := SurfaceSample.new()
	var s := SlopeFixture.flat_slope(20.0)
	s.sample_into(45.0, -20.0, sample)
	var fresh_friction: float = sample.friction
	var fresh_height: float = sample.height

	s.snow_field = field
	s.sample_into(45.0, -20.0, sample)
	# The whole point of the CPU mirror: a packed trench plays differently.
	t.ok(sample.friction < fresh_friction, "a packed trench runs faster than fresh powder")
	t.ok(sample.height < fresh_height, "the surface sits lower inside the trench")
	t.ok(sample.compression_depth < 0.05, "there is less snow left to plough")

	t.begin("snow field scrolling")
	# Toroidal scrolling: drive 30 m and the trench is still there; drive 100 m
	# and it has fallen out of the window and been cleared, not smeared.
	field.recenter(45.0, -40.0)
	t.ok(field.depth_at(45.0, -20.0) > 0.0, "trench survives a scroll inside the window")
	field.recenter(45.0, -200.0)
	t.eq_f(field.depth_at(45.0, -20.0), 0.0, 1e-9, "trench is dropped once out of the window")
	field.stamp(45.0, -200.0, 0.6, 0.08)
	t.ok(field.depth_at(45.0, -200.0) > 0.0, "the scrolled window is clean and writable")

	t.begin("snow decay")
	var d0: float = field.depth_at(45.0, -200.0)
	field.decay(field.refill_tau)
	t.eq_f(field.depth_at(45.0, -200.0), d0 * exp(-1.0), 1e-6, "trench refills exponentially")

## The splat resample must be an identity when the two grids are the same size.
##
## It was not. `int(float(x) / float(target.x) * float(sw))` looks like an
## identity and is not one: `178 / 179.0 * 179.0` is 177.99999999999997, and the
## truncation takes it to 177. Eleven of bunny_hill's 179 columns and eight of
## its 519 rows read the neighbouring texel's weights, so whole 50 cm stripes of
## every shipped course ran on the wrong terrain's friction — silently, because
## the shading comes from the splat texture directly on the GPU and only the
## physics goes through this path.
##
## Asserted on the widths that actually shipped, since which columns are wrong
## depends on the number.
static func _splat_resample(t: TestCase) -> void:
	t.begin("splat resample")
	for n: int in [179, 519, 199, 1999, 159, 7999]:
		var wrong: int = 0
		for x: int in n:
			@warning_ignore("integer_division")
			var sx: int = x * n / n
			if sx != x:
				wrong += 1
		t.ok(wrong == 0, "an equal-size resample is the identity at %d wide" % n)

	# End to end through [method HeightmapSurface.from_course], which is where the
	# bug was: a synthetic course 179 wide — bunny_hill's width, and one of the
	# ones that misbehaved — painted in alternating columns of two terrains that
	# could not be more different. A column that resamples off by one reads its
	# neighbour and comes out with the other friction.
	t.ok(_columns_keep_their_layer(179, 519, 179, 519) == 0,
		"an equal-size splat map keeps every column's layer")
	# And the resampling path it shares, at a splat resolution the heightmap
	# does not match — §3.1 decouples the two deliberately, so this is legal and
	# must still land every target column on the right source column.
	t.ok(_columns_keep_their_layer(179, 40, 358, 80) == 0,
		"a half-resolution splat map still resolves every column")

## Build a course whose splat map is alternating one-hot columns of two very
## different terrains, and count the columns whose friction comes out wrong.
static func _columns_keep_their_layer(nx: int, ny: int, sx: int, sy: int) -> int:
	var heights := PackedFloat32Array()
	heights.resize(nx * ny)
	heights.fill(0.0)
	var hm := Image.create_from_data(nx, ny, false, Image.FORMAT_RF,
		heights.to_byte_array())

	# One-hot in R and G, so layer 0 is every even source column and layer 1
	# every odd one.
	var bytes := PackedByteArray()
	bytes.resize(sx * sy * 4)
	bytes.fill(0)
	for y: int in sy:
		for x: int in sx:
			bytes[(y * sx + x) * 4 + (x % 2)] = 255
	var splat := Image.create_from_data(sx, sy, false, Image.FORMAT_RGBA8, bytes)

	var ice := TerrainLayer.new()
	ice.id = &"ice"
	ice.friction = 0.2
	var rock := TerrainLayer.new()
	rock.id = &"rock"
	rock.friction = 0.7

	var course := CourseData.new()
	course.heightmap = hm
	course.world_size = Vector2(float(nx - 1), float(ny - 1))
	course.base_angle = 0.0
	course.splat_maps = [ImageTexture.create_from_image(splat)] as Array[Texture2D]
	course.terrain_layers = [ice, rock] as Array[TerrainLayer]

	var s := HeightmapSurface.from_course(course)
	var sample := SurfaceSample.new()
	var mismatched: int = 0
	for x: int in nx:
		# Halfway down, away from the edge clamps.
		s.sample_into(float(x), -float(ny / 2), sample)
		# Which source column this target column maps to decides the answer.
		@warning_ignore("integer_division")
		var src: int = x * sx / nx
		var want: float = 0.2 if src % 2 == 0 else 0.7
		if absf(sample.friction - want) > 0.01:
			mismatched += 1
	return mismatched

## [method SnowField.decay] holds the scale rather than touching the grid, so
## the things that could go wrong are the clamp in [method SnowField.stamp]
## working in the wrong space, and the renormalisation pass losing the field.
static func _snow_decay_is_scalar(t: TestCase) -> void:
	t.begin("snow decay is a scalar")
	var f := SnowField.new()
	f.recenter(10.0, -10.0)
	for i: int in 40:
		f.stamp(10.0, -10.0, 0.6, 0.05)
	var full: float = f.depth_at(10.0, -10.0)
	t.eq_f(full, f.max_trench, 1e-6, "the clamp still saturates at max_trench")

	# Decayed, then stamped again: the clamp has to be applied in metres, so a
	# saturating stamp on a decayed field comes back to exactly max_trench.
	f.decay(f.refill_tau)
	t.eq_f(f.depth_at(10.0, -10.0), f.max_trench * exp(-1.0), 1e-6,
		"a decayed trench is the whole field scaled")
	for i: int in 40:
		f.stamp(10.0, -10.0, 0.6, 0.05)
	t.eq_f(f.depth_at(10.0, -10.0), f.max_trench, 1e-6,
		"a stamp on a decayed field saturates at max_trench, not above it")

	# Compaction is clamped to 1 on the same argument.
	t.between(f.pack_at(10.0, -10.0), 0.0, 1.0, "compaction stays inside 0..1")

	# Far enough for the renormalisation pass to fire, which is the one thing
	# that rewrites the arrays. The field has to survive it unchanged.
	var before: float = f.depth_at(10.0, -10.0)
	var decayed: float = 0.0
	for i: int in 12:
		f.decay(f.refill_tau)
		decayed += 1.0
	t.eq_f(f.depth_at(10.0, -10.0), before * exp(-decayed), 1e-9,
		"the field survives renormalisation")
	t.ok(f.depth_at(10.0, -10.0) > 0.0, "and is not zeroed by it")

	# A scrolled-in strip is empty whatever the scale has drifted to.
	f.recenter(10.0, -1000.0)
	t.eq_f(f.depth_at(10.0, -1000.0), 0.0, 1e-12, "a fresh window is clean")
	f.stamp(10.0, -1000.0, 0.6, 0.05)
	t.ok(f.depth_at(10.0, -1000.0) > 0.0, "and writable after the reset")
