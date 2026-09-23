## Tests for the spray's look — what a particle *is*, not just how many spawn.
##
## The first cut drew ETR's counts and velocities faithfully and every particle
## as a flat white square: a QuadMesh with a textureless StandardMaterial3D, at
## full size at birth, fading never. Nothing failed — a spray of white squares
## against snow is plausible at a glance — which is exactly why the properties
## of `Particle::Draw` get asserted instead of trusted: every particle is
## textured from a four-puff atlas (one quadrant per particle, chosen at birth),
## grows from NEW_PART_SIZE toward its per-particle base for its whole life, and
## fades out linearly across a lifetime that is itself randomized
## (`death = FRandom() * MAX_AGE`).
##
## All of it is plain data — an Image and material properties — so the group
## runs headless, where the RenderingServer keeps nothing (see the MultiMesh
## trap: assert what feeds the batch, not what a dummy renderer would draw).
class_name TestSpray
extends RefCounted

static func run(t: TestCase) -> void:
	_atlas(t)
	var e := _emitter(t)
	if e == null:
		return
	_billboard(t, e)
	_grows_over_life(t, e)
	_fades_over_life(t, e)
	_etr_lifetime(t, e)
	_retints(t, e)
	e.free()

static func _emitter(t: TestCase) -> SprayEmitter:
	var e := SprayEmitter.new()
	var tree := Engine.get_main_loop() as SceneTree
	t.ok(tree != null, "there is a tree to hang the emitter in")
	if tree == null:
		e.free()
		return null
	# `_ready` builds both emitters; nothing here renders, so headless is fine.
	tree.root.add_child(e)
	return e

## The redrawn atlas: four distinct puffs, self-contained in their quadrants,
## RGB white with the alpha doing the shaping, and byte-identical on every call.
static func _atlas(t: TestCase) -> void:
	t.begin("spray/puff atlas")
	var img := SprayEmitter.make_puff_image()
	t.ok(img.get_width() == 64 and img.get_height() == 64,
		"the atlas is ETR's 64x64")
	var half := 32
	for q: int in 4:
		var cx := half * (0 if q % 2 == 0 else 1) + 16
		var cy := half * (0 if q < 2 else 1) + 16
		var c := img.get_pixel(cx, cy)
		t.ok(c.r > 0.99 and c.g > 0.99 and c.b > 0.99,
			"quadrant %d is white where it is visible" % q)
		t.ok(c.a > 0.01, "quadrant %d has a puff" % q)
		# The puff decays to a whisper by its own quadrant's rim — 1 px inside
		# on both axes. A fat falloff that still painted at the rim would read
		# as a hard square edge again, and one that spilled past the mid-line
		# would paint over the neighbour's UV rect.
		var rim_x := img.get_pixel(cx + (15 if q % 2 == 0 else -15), cy).a
		var rim_y := img.get_pixel(cx, cy + (15 if q < 2 else -15)).a
		t.ok(rim_x < 0.1 * c.a and rim_y < 0.1 * c.a,
			"quadrant %d decays before its edge" % q)
	var corners := [img.get_pixel(0, 0).a, img.get_pixel(63, 0).a,
			img.get_pixel(0, 63).a, img.get_pixel(63, 63).a]
	t.ok(corners.all(func(a: float) -> bool: return a < 0.01),
		"the atlas corners are empty")
	var peaks: Array[float] = []
	for q: int in 4:
		peaks.push_back(img.get_pixel(16 + (q % 2) * 32, 16 + (q / 2) * 32).a)
	t.ok(peaks.max() > 0.9 and peaks.min() < 0.4,
		"the atlas spans a faint puff to a bright one, as ETR's does")
	t.ok(peaks[0] != peaks[1] and peaks[1] != peaks[2] and peaks[2] != peaks[3],
		"the four puffs are four different puffs")
	t.ok(SprayEmitter.make_puff_image().get_data() == img.get_data(),
		"the atlas is deterministic — no RNG anywhere in it")

static func _billboard(t: TestCase, e: SprayEmitter) -> void:
	t.begin("spray/a particle is textured")
	var quad := e._left.draw_pass_1 as QuadMesh
	t.ok(quad != null, "the draw pass is a quad")
	if quad == null:
		return
	t.ok(is_equal_approx(quad.size.x, SprayEmitter.OLD_PART_SIZE),
		"the quad is OLD_PART_SIZE across — the size a grown particle reaches")
	var mat := quad.material as StandardMaterial3D
	t.ok(mat != null, "the quad carries a material")
	if mat == null:
		return
	t.ok(mat.albedo_texture != null, "a particle is textured, not a flat quad")
	t.ok(mat.billboard_mode == BaseMaterial3D.BILLBOARD_PARTICLES,
		"particle billboards — the mode that reads the anim phase for the atlas UVs")
	t.ok(mat.particles_anim_h_frames == 2 and mat.particles_anim_v_frames == 2,
		"the atlas is 2x2")
	t.ok(not mat.particles_anim_loop, "a particle keeps its quadrant for life")
	t.ok(mat.vertex_color_use_as_albedo,
		"the alpha ramp reaches the material via COLOR")
	t.ok(mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA,
		"soft alpha, as ETR's blend did")
	t.ok(mat.albedo_color.is_equal_approx(e.particle_color),
		"the tint is the one property, not a second copy")
	t.ok(absf(e.particle_color.r - 0.85) < 1e-4 and absf(e.particle_color.g - 0.9) < 1e-4,
		"the tint is sunny's [partcol] 0.85 0.9 1.0, the preset every course selects")

## The environment is applied to racers that already exist, so a colour pushed
## after `_ready` has to reach the material. It did not: the setter was missing,
## and every night race threw daylight-white spray under a blue sky.
static func _retints(t: TestCase, e: SprayEmitter) -> void:
	t.begin("spray/an environment applied later retints it")
	var night := Color(0.39, 0.51, 0.88)
	e.particle_color = night
	for p: GPUParticles3D in [e._left, e._right]:
		var mat := (p.draw_pass_1 as QuadMesh).material as StandardMaterial3D
		t.ok(mat.albedo_color.is_equal_approx(night),
			"%s takes the new [partcol]" % p.name)

static func _grows_over_life(t: TestCase, e: SprayEmitter) -> void:
	t.begin("spray/a particle grows over its life")
	var mat := e._left_mat
	t.ok(is_equal_approx(mat.scale_min, 0.5) and is_equal_approx(mat.scale_max, 1.5),
		"base_size = (FRandom() + 0.5) * OLD_PART_SIZE, as ETR drew it")
	var growth := mat.scale_curve as CurveTexture
	t.ok(growth != null and growth.curve != null, "a growth curve is set")
	if growth == null or growth.curve == null:
		return
	var curve := growth.curve
	t.ok(absf(curve.sample_baked(0.0) - SprayEmitter.NEW_PART_SIZE / SprayEmitter.OLD_PART_SIZE) < 1e-4,
		"born at NEW_PART_SIZE, not at full size")
	t.ok(is_equal_approx(curve.sample_baked(1.0), 1.0),
		"reaching its base at death")
	t.ok(curve.sample_baked(0.5) > curve.sample_baked(0.0)
		and curve.sample_baked(1.0) > curve.sample_baked(0.5),
		"monotonically — the shrink-at-the-end curve this replaced was the bug")

static func _fades_over_life(t: TestCase, e: SprayEmitter) -> void:
	t.begin("spray/a particle fades out linearly")
	var ramp := e._left_mat.color_ramp as GradientTexture1D
	t.ok(ramp != null and ramp.gradient != null, "an alpha ramp is set")
	if ramp == null or ramp.gradient == null:
		return
	# The gradient is exactly ETR's two ends, so its points are the assertion:
	# a two-point linear gradient *is* alpha = (death - age) / death.
	var grad := ramp.gradient
	t.ok(grad.get_point_count() == 2, "two ends, nothing eased between them")
	t.ok(is_equal_approx(grad.get_color(0).a, 1.0),
		"alpha starts at 1 — the stray glColor4f(1,1,1,0.8) is overridden per particle")
	t.ok(is_equal_approx(grad.get_color(1).a, 0.0), "and reaches 0 at death")
	t.ok(grad.interpolation_mode == Gradient.GRADIENT_INTERPOLATE_LINEAR,
		"linearly, as (death - age) / death")
	t.ok(grad.get_color(1).r > 0.99,
		"the ramp carries no colour of its own; the tint stays albedo_color")

static func _etr_lifetime(t: TestCase, e: SprayEmitter) -> void:
	t.begin("spray/the lifetime is ETR's distribution")
	var mat := e._left_mat
	t.ok(is_equal_approx(mat.lifetime_randomness, 1.0),
		"death = FRandom() * MAX_AGE, not one fixed lifetime for all")
	t.ok(is_equal_approx(e._left.lifetime, SprayEmitter.MAX_AGE),
		"nominal lifetime is MAX_AGE")
	t.ok(is_equal_approx(mat.anim_offset_min, 0.0)
		and is_equal_approx(mat.anim_offset_max, 1.0),
		"a random quadrant per particle")
	t.ok(is_zero_approx(mat.anim_speed_min) and is_zero_approx(mat.anim_speed_max),
		"chosen at birth and kept — `type = rand() % 4`")
