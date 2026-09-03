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

## Particle pool per side. The original had no budget and simply allocated;
## a fixed pool is what keeps a brake-slide from spiking a frame on a phone.
@export var pool_size: int = 700
@export var particle_lifetime: float = 1.1
@export var particle_color: Color = Color(0.92, 0.95, 1.0)

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
	_left_mat = _make_process_material()
	_right_mat = _make_process_material()
	_left = _make_emitter("SprayLeft", _left_mat)
	_right = _make_emitter("SprayRight", _right_mat)

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
	mat.scale_min = 0.35
	mat.scale_max = 1.0
	# ETR gave every flake a random velocity offset scaled by player speed;
	# `spread` plus a velocity range is the same idea in a rate-based system.
	mat.spread = 25.0
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(0.35, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	var tex := CurveTexture.new()
	tex.curve = curve
	mat.scale_curve = tex
	return mat

func _make_mesh() -> Mesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.08, 0.08)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = particle_color
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
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
