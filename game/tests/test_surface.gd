## Tests for [HeightmapSurface] and the [SnowField] CPU mirror.
class_name TestSurface
extends RefCounted

static func run(t: TestCase) -> void:
	_analytic_slope(t)
	_bilinear(t)
	_splat_blending(t)
	_snow_field(t)

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
