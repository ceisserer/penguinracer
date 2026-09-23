## Snow spray thrown up by the carve, ported from ETR `generate_particles`
## (particles.cpp §4.4 item 2).
##
## The signature visual of the original is the [b]asymmetry[/b]: spray is emitted
## from two points either side of the belly, and the counts either side are keyed
## to the sign of the steering input, so a hard left throws snow left and a brake
## throws it both ways. Those counts and velocities are ETR's formulas verbatim.
##
## [b]DEVIATION forced by the platform.[/b] The Compatibility (WebGL2) renderer
## does not support [method GPUParticles3D.emit_particle] — manual emission is a
## `RenderingDevice` path. So instead of spawning N particles at computed
## velocities, two rate-driven emitters are steered every frame: ETR's per-frame
## count becomes an emission rate via [member GPUParticles3D.amount_ratio], and
## its spray velocity becomes the emitter's direction and initial speed. The
## logic that matters — which side, how much, how fast, how wide — is unchanged.
##
## The look is ported as far as the art allows. `Particle::Draw` textured every
## particle from `snowparticles.png` — a 64×64 atlas of four soft puffs, one
## quadrant picked per particle at birth — born at [constant NEW_PART_SIZE] and
## grown over its whole life toward a per-particle base of
## `(FRandom() + 0.5) × [constant OLD_PART_SIZE]`, fading out linearly
## (`alpha = (death − age) / death`) across a per-particle lifetime of
## `FRandom() × [constant MAX_AGE]`. [b]DEVIATION, licence-forced.[/b] The atlas
## itself is [method make_puff_image], redrawn procedurally rather than copied:
## the original is `data/textures` art and waits on the licence audit, the same
## standing as the checkbox icons. The lifetime distribution halves the
## steady-state live count against the old fixed 1.1 s, which is also ETR's: its
## own average death is 0.5 s.
class_name SprayEmitter
extends Node3D

const TUX_WIDTH := 0.45
const MAX_TURN_PARTICLES := 500.0
const BRAKE_PARTICLES := 2000.0
const MAX_ROLL_PARTICLES := 3000.0
const PARTICLE_SPEED_FACTOR := 40.0
const MAX_PARTICLE_ANGLE := 80.0
const MAX_PARTICLE_ANGLE_SPEED := 50.0
const PARTICLE_SPEED_MULTIPLIER := 0.3
const MAX_PARTICLE_SPEED := 2.0
const VARIANCE_FACTOR := 0.8

## ETR `particles.cpp`: a particle is born this small,
const NEW_PART_SIZE := 0.035
## grows to this much times its per-particle base over its whole life,
const OLD_PART_SIZE := 0.12
## and dies at a random fraction of this.
const MAX_AGE := 1.0

## Side of the puff atlas, as ETR's 64×64 `snowparticles.png`.
const PUFF_SIZE := 64

## (peak alpha, edge hardness) per quadrant of the puff atlas, in the order
## `Particle::Draw`'s `type = rand() % 4` reads them. ETR's atlas runs from a
## hard bright puff to a faint one; these are redrawn by eye to the same
## spread, not traced from it.
const PUFF_QUADRANTS: Array[Vector2] = [
	Vector2(1.0, 2.0), Vector2(0.55, 1.4),
	Vector2(0.30, 2.4), Vector2(0.95, 1.2),
]

var _puff: ImageTexture

## Particle pool per side. The original had no budget and simply allocated;
## a fixed pool is what keeps a brake-slide from spiking a frame on a phone.
@export var pool_size: int = 700
## ETR's [constant MAX_AGE]. Each particle's actual life is shorter by a random
## factor ([member ParticleProcessMaterial.lifetime_randomness]), so the
## steady-state live count at a given emission rate is about half of what a
## fixed lifetime of this length would hold — as in the original.
@export var particle_lifetime: float = MAX_AGE
## The environment's `[partcol]` — [member EnvironmentPreset.particle_color],
## pushed in by [RaceScene] whenever the environment is applied. The default,
## (0.85, 0.9, 1.0), is what both sunny presets ship.
##
## A setter, not a plain field: the environment is applied to a racer whose
## emitters were built long ago, and a colour only read when the material is
## made left every spray in daylight under a night sky.
@export var particle_color: Color = Color(0.85, 0.9, 1.0):
	set(value):
		particle_color = value
		_apply_color()

var _left: GPUParticles3D
var _right: GPUParticles3D
var _left_mat: ParticleProcessMaterial
var _right_mat: ParticleProcessMaterial

# Accumulated over the frame's ODE substeps, applied once in [method flush].
var _left_count: float = 0.0
var _right_count: float = 0.0
var _left_pt: Vector3 = Vector3.ZERO
var _right_pt: Vector3 = Vector3.ZERO
var _left_vel: Vector3 = Vector3.UP
var _right_vel: Vector3 = Vector3.UP
var _speed: float = 0.0
var _active: bool = false

func _ready() -> void:
	# One atlas per emitter, shared by both draw passes. Not a script static:
	# a static would outlive every race and be the one thing still referenced
	# at exit.
	_puff = ImageTexture.create_from_image(make_puff_image())
	_left_mat = _make_process_material()
	_right_mat = _make_process_material()
	_left = _make_emitter("SprayLeft", _left_mat)
	_right = _make_emitter("SprayRight", _right_mat)

func _apply_color() -> void:
	for p: GPUParticles3D in [_left, _right]:
		if p == null:
			continue
		var mat := (p.draw_pass_1 as QuadMesh).material as StandardMaterial3D
		mat.albedo_color = particle_color

func _make_emitter(node_name: String, mat: ParticleProcessMaterial) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = node_name
	p.amount = pool_size
	p.lifetime = particle_lifetime
	p.local_coords = false
	p.emitting = false
	p.amount_ratio = 0.0
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.process_material = mat
	p.draw_pass_1 = _make_mesh()
	add_child(p)
	return p

func _make_process_material() -> ParticleProcessMaterial:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.08
	mat.gravity = Vector3(0.0, -9.81, 0.0)
	mat.damping_min = 0.6
	mat.damping_max = 1.6
	# ETR's per-particle base_size = (FRandom() + 0.5) * OLD_PART_SIZE.
	mat.scale_min = 0.5
	mat.scale_max = 1.5
	# ETR gave every flake a random velocity offset scaled by player speed;
	# `spread` plus a velocity range is the same idea in a rate-based system.
	mat.spread = 25.0
	# death = FRandom() * MAX_AGE.
	mat.lifetime_randomness = 1.0
	# `type = rand() % 4`: one quadrant of the puff atlas per particle, chosen
	# at birth and kept. The particle-anim UVs do exactly that with a random
	# phase and no speed.
	mat.anim_offset_min = 0.0
	mat.anim_offset_max = 1.0
	mat.anim_speed_min = 0.0
	mat.anim_speed_max = 0.0
	# cur_size = NEW_PART_SIZE + (base_size − NEW_PART_SIZE) * (age / death):
	# a particle grows for its whole life. The scale range above carries the
	# per-particle base; this ramp carries the growth, so a newborn reads
	# NEW_PART_SIZE on average no matter which base it drew.
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, NEW_PART_SIZE / OLD_PART_SIZE))
	curve.add_point(Vector2(1.0, 1.0))
	var growth := CurveTexture.new()
	growth.curve = curve
	mat.scale_curve = growth
	# alpha = (death - age) / death — strictly linear, and the stray
	# glColor4f(1, 1, 1, 0.8) in draw_particles is overridden per particle
	# before anything is drawn, so it starts at 1.
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([Color(1.0, 1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0, 0.0)])
	var fade := GradientTexture1D.new()
	fade.gradient = grad
	mat.color_ramp = fade
	return mat

## A redrawn `snowparticles.png`: 64×64, a 2×2 atlas of soft puffs, RGB white
## everywhere with the alpha doing all the shaping — [ParticleProcessMaterial.color_ramp]
## and the tint then modulate it, exactly as ETR's `GL_MODULATE` did. Deterministic
## by construction (no RNG anywhere), so captures stay comparable.
static func make_puff_image() -> Image:
	var img := Image.create_empty(PUFF_SIZE, PUFF_SIZE, false, Image.FORMAT_RGBA8)
	var half := PUFF_SIZE / 2
	# Inscribed in the quadrant, minus half a texel so the falloff reaches zero
	# *at* the rim pixel rather than just past it — no puff bleeds into its
	# neighbour's UV rect, the visible diameter is the quad's, and the square
	# silhouette of the atlas tile never shows. ETR's puffs fill their
	# quadrants too.
	var radius: float = half / 2.0 - 0.5
	for q: int in 4:
		var params: Vector2 = PUFF_QUADRANTS[q]
		var cx := half * (0 if q % 2 == 0 else 1) + half / 2.0
		var cy := half * (0 if q < 2 else 1) + half / 2.0
		for y: int in PUFF_SIZE:
			for x: int in PUFF_SIZE:
				var dx := (x + 0.5 - cx) / radius
				var dy := (y + 0.5 - cy) / radius
				var d2 := dx * dx + dy * dy
				if d2 >= 1.0:
					continue
				var a: float = params.x * pow(1.0 - d2, params.y)
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	# Soft alpha edges are low-frequency, but the plume sits in the lower frame
	# at grazing angles; the terrain textures got mips for exactly that crawl.
	img.generate_mipmaps()
	return img

func _make_mesh() -> Mesh:
	var quad := QuadMesh.new()
	# A particle reaches OLD_PART_SIZE across at the end of its life; the process
	# material's scale range and growth ramp shape everything before that.
	quad.size = Vector2(OLD_PART_SIZE, OLD_PART_SIZE)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = particle_color
	mat.albedo_texture = _puff
	# BILLBOARD_PARTICLES, not BILLBOARD_ENABLED: this mode is what reads the
	# particle-anim phase and maps the quad onto one atlas quadrant.
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.particles_anim_h_frames = 2
	mat.particles_anim_v_frames = 2
	mat.particles_anim_loop = false
	# The color_ramp arrives as COLOR, so it must reach the albedo or nothing
	# would fade.
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	quad.material = mat
	return quad

## Called once per accepted ODE substep, exactly where ETR called this.
## Accumulates; nothing is pushed to the renderer until [method flush].
##
## [param sample] is the terrain under [param pos], sampled by the caller. It
## used to be sampled here, into a freshly allocated [SurfaceSample] — which
## meant one allocation and one full surface query per substep for a point
## [method SimulatedRacer._on_substep] had just queried into a reused member two
## lines earlier. Taking it as an argument removes both, and makes the spray and
## the deformation stamp agree about the terrain by construction rather than by
## having asked the same question twice.
func emit_for_substep(physics: RacePhysics, dt: float, pos: Vector3, speed: float,
		sample: SurfaceSample) -> void:
	if sample == null:
		return
	# Only when the terrain throws spray and the player is actually in the snow.
	if not sample.emits_particles or pos.y >= sample.height:
		return

	var xvec: Vector3 = physics.direction.cross(physics.plane_nml)
	if xvec.length_squared() < 1e-8:
		return
	xvec = xvec.normalized()

	_right_pt = pos + xvec * (TUX_WIDTH / 2.0)
	_left_pt = pos - xvec * (TUX_WIDTH / 2.0)
	_right_pt.y = sample.height
	_left_pt.y = sample.height

	var speed_ramp: float = minf(speed / PARTICLE_SPEED_FACTOR, 1.0)
	var brake: float = dt * BRAKE_PARTICLES * (1.0 if physics.is_braking else 0.0) * speed_ramp
	var turn: float = dt * MAX_TURN_PARTICLES * speed_ramp
	var roll: float = dt * MAX_ROLL_PARTICLES * speed_ramp

	_left_count += turn * absf(minf(physics.turn_fact, 0.0)) + brake \
		+ roll * absf(minf(physics.turn_animation, 0.0))
	_right_count += turn * absf(maxf(physics.turn_fact, 0.0)) + brake \
		+ roll * absf(maxf(physics.turn_animation, 0.0))

	# The spray fans outward, tilted away from the travel direction by up to 80°
	# and ramped in with speed — a crawling player kicks straight up.
	var angle: float = minf(MAX_PARTICLE_ANGLE,
		MAX_PARTICLE_ANGLE * speed / MAX_PARTICLE_ANGLE_SPEED)
	var axis: Vector3 = physics.direction.normalized()
	if axis.length_squared() < 0.5:
		return
	_left_vel = Basis(axis, deg_to_rad(-angle)) * physics.plane_nml
	_right_vel = Basis(axis, deg_to_rad(angle)) * physics.plane_nml
	_speed = speed
	_active = true

## Push the frame's accumulated emission to the two rate-driven emitters.
func flush(delta: float) -> void:
	if delta <= 0.0:
		return
	if not _active:
		_left.emitting = false
		_right.emitting = false
		_left_count = 0.0
		_right_count = 0.0
		return
	_apply(_left, _left_mat, _left_pt, _left_vel, _left_count, delta)
	_apply(_right, _right_mat, _right_pt, _right_vel, _right_count, delta)
	_left_count = 0.0
	_right_count = 0.0
	_active = false

func _apply(node: GPUParticles3D, mat: ParticleProcessMaterial, point: Vector3,
		direction: Vector3, count: float, delta: float) -> void:
	if count <= 0.0:
		node.emitting = false
		return
	node.global_position = point
	if direction.length_squared() > 1e-8:
		mat.direction = direction.normalized()
	var mag: float = minf(MAX_PARTICLE_SPEED, _speed * PARTICLE_SPEED_MULTIPLIER)
	mat.initial_velocity_min = mag * (1.0 - VARIANCE_FACTOR * 0.5)
	mat.initial_velocity_max = mag * (1.0 + VARIANCE_FACTOR * 0.5)
	# ETR's per-frame count becomes a rate; a full pool over one lifetime is
	# amount_ratio 1.0, so this is just that ratio.
	var rate: float = count / delta
	node.amount_ratio = clampf(rate * particle_lifetime / float(pool_size), 0.0, 1.0)
	node.emitting = true
