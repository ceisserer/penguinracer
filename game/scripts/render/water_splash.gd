## The water a racer throws up wading through a puddle: two sheets of
## droplets, one off either side of the body, and a crown of white water
## where the body shoves into it — all as strong as the racer is fast and
## deep.
##
## DEVIATION: ETR has no water. Built the [SprayEmitter]'s way for the same
## reason — Compatibility cannot `emit_particle()`, so each sheet is a
## rate-driven emitter steered every frame (`amount_ratio`, direction, speed) —
## but driven from a [RacerState] rather than from the substeps, so a ghost
## and a remote peer splash exactly like the player (architecture rule 8).
## [WaterRenderer] owns one per racer that has been in the water.
class_name WaterSplash
extends Node3D

## Droplets a sheet may have in flight.
const POOL := 360
## Seconds a droplet lives at most; each lives a random share of it.
const LIFETIME := 0.7
## Droplets a second per sheet, wading at full depth at [constant FULL_SPEED].
const RATE := 900.0
## The crown: soft puffs of white water at the bow, short-lived and slow.
const CROWN_POOL := 90
const CROWN_LIFETIME := 0.4
const CROWN_RATE := 260.0
const CROWN_SIZE := 0.32
## Metres per second at which the sheets are at full strength.
const FULL_SPEED := 12.0
## How far either side of the body's line the sheets leave the water.
const HALF_WIDTH := 0.24
## Side of a droplet at the end of its life, metres.
const DROP_SIZE := 0.09

var _left: GPUParticles3D
var _right: GPUParticles3D
var _crown: GPUParticles3D
var _left_mat: ParticleProcessMaterial
var _right_mat: ParticleProcessMaterial
var _crown_mat: ParticleProcessMaterial
var _draw: StandardMaterial3D
var _crown_draw: StandardMaterial3D

## Sets up the sheets and the crown, drawing every droplet with
## [param droplet] and every puff of the crown with [param puff].
func _init(droplet: Texture2D, puff: Texture2D) -> void:
	_draw = _draw_material(droplet)
	_crown_draw = _draw_material(puff)
	# [method SprayEmitter.make_puff_image] is a 2x2 atlas: one puff a particle,
	# picked at birth by the anim offset, as the snow spray does it.
	_crown_draw.particles_anim_h_frames = 2
	_crown_draw.particles_anim_v_frames = 2
	_crown_draw.particles_anim_loop = false
	_left_mat = _process_material()
	_right_mat = _process_material()
	_left = _emitter("SplashLeft", _left_mat, _draw, POOL, LIFETIME, DROP_SIZE)
	_right = _emitter("SplashRight", _right_mat, _draw, POOL, LIFETIME, DROP_SIZE)
	_crown_mat = _crown_material()
	_crown = _emitter("Crown", _crown_mat, _crown_draw, CROWN_POOL, CROWN_LIFETIME, CROWN_SIZE)

static func _draw_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = tex
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

## The environment's `[partcol]`, as the snow spray takes it — the droplets are
## lit by the same sky.
func set_color(c: Color) -> void:
	_draw.albedo_color = Color(c.r * 0.92, c.g * 0.97, c.b, 0.9)
	_crown_draw.albedo_color = Color(c.r, c.g, c.b, 0.4)

func _emitter(node_name: String, mat: ParticleProcessMaterial, draw: Material, pool: int,
		lifetime: float, size: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = node_name
	p.amount = pool
	p.lifetime = lifetime
	p.local_coords = false
	p.emitting = false
	p.amount_ratio = 0.0
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	# Round the racer, so out of the world probe with it, as the snow spray.
	p.layers = IceEnvironment.NEAR_FIELD_LAYER
	p.process_material = mat
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = draw
	p.draw_pass_1 = quad
	add_child(p)
	return p

## Puffs that rise a little, swell and fade: water broken white at the bow.
func _crown_material() -> ParticleProcessMaterial:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.18
	mat.direction = Vector3.UP
	mat.spread = 70.0
	mat.gravity = Vector3(0.0, -6.0, 0.0)
	mat.damping_min = 1.0
	mat.damping_max = 2.5
	mat.lifetime_randomness = 0.5
	mat.scale_min = 0.5
	mat.scale_max = 1.2
	mat.anim_offset_min = 0.0
	mat.anim_offset_max = 1.0
	mat.anim_speed_min = 0.0
	mat.anim_speed_max = 0.0
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.35))
	curve.add_point(Vector2(1.0, 1.0))
	var growth := CurveTexture.new()
	growth.curve = curve
	mat.scale_curve = growth
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([Color(1, 1, 1, 0.8), Color(1, 1, 1, 0.0)])
	var fade := GradientTexture1D.new()
	fade.gradient = grad
	mat.color_ramp = fade
	return mat

func _process_material() -> ParticleProcessMaterial:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.12
	mat.gravity = Vector3(0.0, -9.81, 0.0)
	mat.damping_min = 0.2
	mat.damping_max = 0.8
	mat.spread = 18.0
	mat.lifetime_randomness = 0.6
	mat.scale_min = 0.4
	mat.scale_max = 1.6
	# Born as a fleck, grown to a drop: a sheet tearing into droplets.
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.4))
	curve.add_point(Vector2(1.0, 1.0))
	var growth := CurveTexture.new()
	growth.curve = curve
	mat.scale_curve = growth
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	grad.colors = PackedColorArray([Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0.0)])
	var fade := GradientTexture1D.new()
	fade.gradient = grad
	mat.color_ramp = fade
	return mat

## Throw this frame's water. [param at] is the racer's point on the water's
## surface, [param velocity] its velocity, [param wade] how deep it is wading
## (0..1, 0 = dry or flying: the sheets stop).
func update(at: Vector3, velocity: Vector3, wade: float) -> void:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	var speed: float = flat.length()
	var strength: float = wade * clampf(speed / FULL_SPEED, 0.0, 1.5)
	if strength <= 0.02 or speed < 0.5:
		stop()
		return
	var fwd: Vector3 = flat / speed
	_crown.global_position = at + fwd * 0.4
	_crown_mat.initial_velocity_min = 0.6 + 0.05 * speed
	_crown_mat.initial_velocity_max = 1.4 + 0.12 * speed
	_crown.amount_ratio = clampf(CROWN_RATE * strength * CROWN_LIFETIME / float(CROWN_POOL),
		0.0, 1.0)
	_crown.emitting = true
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	for k: int in 2:
		var node: GPUParticles3D = _left if k == 0 else _right
		var mat: ParticleProcessMaterial = _left_mat if k == 0 else _right_mat
		var out: Vector3 = side * (1.0 if k == 1 else -1.0)
		node.global_position = at + out * HALF_WIDTH
		# Up and out of the body's sides, and carried a little way on with it:
		# what a planing hull throws, without inheriting the racer's whole speed.
		var launch: Vector3 = out * (1.2 + 0.18 * speed) + Vector3.UP * (1.4 + 0.16 * speed) \
			+ fwd * (0.35 * speed)
		var mag: float = launch.length()
		mat.direction = launch / mag
		mat.initial_velocity_min = mag * 0.55
		mat.initial_velocity_max = mag * 1.15
		node.amount_ratio = clampf(RATE * strength * LIFETIME / float(POOL), 0.0, 1.0)
		node.emitting = true

## Stop throwing water at once, as when the racer leaves the hill.
func stop() -> void:
	_left.emitting = false
	_right.emitting = false
	_crown.emitting = false

## A drop of water seen against the light: a bright core in a soft rim, white,
## the alpha doing the shaping. Drawn here, as the spray's puffs are, so there
## is nothing for the licence audit.
static func make_droplet_image(size: int = 32) -> Image:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var r: float = size * 0.5 - 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (x + 0.5 - size * 0.5) / r
			var dy: float = (y + 0.5 - size * 0.5) / r
			var d2: float = dx * dx + dy * dy
			if d2 >= 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, 0))
				continue
			var body: float = pow(1.0 - d2, 1.6)
			var core: float = exp(-d2 * 9.0)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(0.55 * body + 0.6 * core, 0.0, 1.0)))
	img.generate_mipmaps()
	return img
