## The snow that falls behind the main menu and scatters out of the pointer's
## way — ETR's "gui particles 2D" (`particles.cpp`, `init_ui_snow`,
## `update_ui_snow`, `push_ui_snow`), which every one of its menu screens draws
## before its widgets.
##
## Each flake is ETR's `TGuiParticle`: a position and a velocity in fractions of
## the screen, and a size in pixels that sets how big it is drawn *and* how fast
## it moves — [method step] multiplies both the push it takes and the distance
## it covers by `size / PARTICLE_SIZE_RANGE`, so the big near flakes fall and
## scatter faster than the small far ones, which is all the depth the effect
## has. A flake that falls out of the bottom starts again just above the top.
##
## The push is the pointer's velocity: how far it moved since the last frame
## over how long that frame took, times `PUSH_FACTOR`, clamped per axis, and
## falling off with the squared distance from where the pointer is now. A still
## pointer pushes nothing. A drag on a touch screen pushes the same way, which
## ETR never had to think about; a new touch starts a new push rather than
## sweeping from wherever the last one ended.
##
## Positions are kept as fractions of the screen, as ETR keeps them, so a resize
## stretches the field rather than leaving bare stripes at the edges — the
## problem ETR solved by re-seeding (`config_screen.cpp`).
##
## [b]DEVIATION, cost.[/b] ETR starts with `BASE_snowparticles` flakes per pixel
## of width (one per pixel, near enough) and then keeps spawning towards
## `MAX_num_snowparticles` while culling only a fifth of the flakes that fall
## out — a field that settles at roughly 2400 on a 1280-wide window a minute
## later. Here the count is the starting one and stays put: the update is
## GDScript, about 0.8 µs a flake natively and several times that in a browser,
## and the difference between 1300 flakes and 2400 is not one a menu needs.
##
## [b]DEVIATION, licence-forced, and the same one the spray takes.[/b] ETR draws
## these from `snowparticles.png`; this draws them from
## [method SprayEmitter.make_puff_image], its redrawn stand-in. ETR binds the
## same texture for both.
##
## Deterministic from [constant SEED] given the same frame times, so a capture
## of the menu does not reshuffle the snow from one run to the next.
class_name MenuSnow
extends Control

## ETR `particles.cpp`, "gui particles 2D". Positions and velocities are in
## fractions of the screen per second; sizes are pixels.
const BASE_SNOWPARTICLES := 1000.0 / 1024.0
const GRAVITY_FACTOR := 0.015
const BASE_VELOCITY := 0.05
const VELOCITY_RANGE := 0.02
const PUSH_DIST_DECAY := 100.0
const PUSH_FACTOR := 0.5
const MAX_PUSH_FORCE := 5.0
const AIR_DRAG := 0.4
const PARTICLE_MIN_SIZE := 1.0
const PARTICLE_SIZE_RANGE := 10.0
## `sf::Color(255, 255, 255, 76)` on every sprite.
const FLAKE_ALPHA := 76.0 / 255.0

## Floats per instance in the MultiMesh buffer: a 2D transform (8) and the
## custom data that picks the atlas quadrant (4).
const STRIDE := 12
const SEED := 0x5e0f1a4e

var _rng := RandomNumberGenerator.new()
## Per flake, in ETR's units. Packed rather than objects: this runs over every
## flake every frame, and a packed array is what keeps that at a millisecond.
var _x := PackedFloat32Array()
var _y := PackedFloat32Array()
var _vx := PackedFloat32Array()
var _vy := PackedFloat32Array()
var _size := PackedFloat32Array()
var _buffer := PackedFloat32Array()
var _multimesh := MultiMesh.new()

## Where the pointer is, and where it was at the last [method step], in
## fractions of the screen. ETR's `push_position` / `last_push_position`.
var _push_at := Vector2.ZERO
var _last_push_at := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	seed_flakes(int(BASE_SNOWPARTICLES * get_viewport_rect().size.x))

	var texture := ImageTexture.create_from_image(SprayEmitter.make_puff_image())
	var drawn := MultiMeshInstance2D.new()
	drawn.multimesh = _multimesh
	drawn.texture = texture
	drawn.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	drawn.self_modulate = Color(1.0, 1.0, 1.0, FLAKE_ALPHA)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/menu_snow.gdshader")
	drawn.material = material
	add_child(drawn)


## ETR `init_ui_snow`: [param count] flakes anywhere on the screen. Also sizes
## the MultiMesh, whose quad is a unit square from the origin — a sprite's
## top-left is its position, as SFML draws one.
func seed_flakes(count: int) -> void:
	_rng.seed = SEED
	for array: PackedFloat32Array in [_x, _y, _vx, _vy, _size]:
		array.resize(count)
	_buffer.resize(count * STRIDE)
	_buffer.fill(0.0)
	for i: int in count:
		_respawn(i, _rng.randf(), _rng.randf())
		# `rand() % 4`: one quadrant of the atlas for the flake's whole life.
		var quadrant: int = _rng.randi() % 4
		_buffer[i * STRIDE + 8] = 0.5 * (quadrant % 2)
		_buffer[i * STRIDE + 9] = 0.5 if quadrant >= 2 else 0.0
	_push_at = Vector2.ZERO
	_last_push_at = Vector2.ZERO

	var quad := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var corners := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_VERTEX] = corners
	arrays[Mesh.ARRAY_TEX_UV] = corners
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_multimesh.instance_count = 0
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_custom_data = true
	_multimesh.mesh = quad
	_multimesh.instance_count = count


func flake_count() -> int:
	return _x.size()


func flake_position(i: int) -> Vector2:
	return Vector2(_x[i], _y[i])


func flake_size(i: int) -> float:
	return _size[i]


## A new flake at ([param x], [param y]): the `TGuiParticle` constructor, and
## the re-roll a flake gets when it falls out of the bottom.
func _respawn(i: int, x: float, y: float) -> void:
	var p_dist: float = _rng.randf()
	_x[i] = x
	_y[i] = y
	_size[i] = PARTICLE_MIN_SIZE + (1.0 - p_dist) * PARTICLE_SIZE_RANGE
	_vx[i] = 0.0
	_vy[i] = BASE_VELOCITY + p_dist * VELOCITY_RANGE


## ETR `push_ui_snow`: the pointer is at [param at], in this control's pixels.
## [param fresh] starts a new stroke — a finger coming down somewhere else.
func push(at: Vector2, fresh: bool = false) -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_push_at = at / size
	if fresh:
		_last_push_at = _push_at


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventMouseMotion or event is InputEventScreenDrag:
		push(make_input_local(event).position)
	elif event is InputEventScreenTouch and event.pressed:
		push(make_input_local(event).position, true)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	step(delta)
	var width: float = size.x
	var height: float = size.y
	for i: int in _x.size():
		var o: int = i * STRIDE
		var s: float = _size[i]
		_buffer[o] = s
		_buffer[o + 3] = _x[i] * width
		_buffer[o + 5] = s
		_buffer[o + 7] = _y[i] * height
	_multimesh.buffer = _buffer


## ETR `update_ui_snow` and `TGuiParticle::Update`, [param dt] seconds on.
##
## ETR also decays a `push_vector` at the end of the update, but that vector is
## a local rebuilt from the pointer at the start of the next one, so the decay
## never reaches a flake; it is not reproduced.
func step(dt: float) -> void:
	if dt <= 0.0:
		return
	var moved: Vector2 = _push_at - _last_push_at
	_last_push_at = _push_at
	var pushing: bool = moved != Vector2.ZERO
	var force := Vector2.ZERO
	if pushing:
		force = (PUSH_FACTOR / dt * moved).clamp(
				Vector2(-MAX_PUSH_FORCE, -MAX_PUSH_FORCE), Vector2(MAX_PUSH_FORCE, MAX_PUSH_FORCE))
	var px: float = _push_at.x
	var py: float = _push_at.y
	for i: int in _x.size():
		var x: float = _x[i]
		var y: float = _y[i]
		# How far this flake is from the viewer: the push it takes and the
		# distance it covers both scale with it.
		var k: float = _size[i] / PARTICLE_SIZE_RANGE
		var fx: float = 0.0
		var fy: float = 0.0
		if pushing:
			var dx: float = x - px
			var dy: float = y - py
			var reach: float = k / (PUSH_DIST_DECAY * (dx * dx + dy * dy) + 1.0)
			fx = force.x * reach
			fy = force.y * reach
		var vx: float = _vx[i] + (fx - _vx[i] * AIR_DRAG) * dt
		var vy: float = _vy[i] + (fy + GRAVITY_FACTOR - _vy[i] * AIR_DRAG) * dt
		_vx[i] = vx
		_vy[i] = vy
		y += vy * dt * k
		if y > 1.05:
			# Out of the bottom: anywhere across the top, a little above it.
			_respawn(i, _rng.randf(), -_rng.randf() * BASE_VELOCITY)
			continue
		_x[i] = clampf(x + vx * dt * k, -0.05, 1.05)
		_y[i] = y
