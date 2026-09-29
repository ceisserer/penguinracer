## Weather on the lens: the odd flake that lands on the camera while it is
## snowing, sits there out of focus for a second or two and melts away.
##
## DEVIATION: ETR has nothing like it. Its snow is all in the world, and so is
## [SnowFall]'s — deliberately, see there: an overlay is what made ETR's snow
## read as confetti in front of the camera. This is the one piece of snow that
## *is* on the camera, and it is kept to what a real lens shows: a few soft
## blobs, far too close to be in focus, never more than a handful at once.
##
## [b]How much[/b] follows the grade ([constant GRADES]): how many may sit on
## the lens at once, how often one lands, how big and how long they stay. And
## within a grade it follows the camera's speed into the snow
## ([method landing_factor]) — a lens riding at 80 km/h sweeps up far more of
## the air than one standing at the start, which is why the intro and a
## spectator standing still see almost none.
##
## [b]Never in the middle.[/b] The penguin and the line ahead of it are the
## middle of the frame, and nothing here may cover them: a flake lands only
## where its whole disc clears the ellipse [constant CLEAR_CENTRE] /
## [constant CLEAR_HALF] ([method is_clear]). What is left is a band round the
## edges, where a real camera's flakes are noticed least anyway.
##
## Presentation only and on the frame's clock like [SnowFall] (architecture rule
## 7); it reads the camera and nothing the simulation owns. Deterministic from
## [constant SEED] and [method restart], so a snowing capture reproduces.
## Plain 2D under the HUD's layer, so both renderers draw it alike: each blob
## blurs and lightens the frame behind it (`shaders/lens_snow.gdshader`).
class_name LensSnow
extends CanvasLayer

## One row per [member SnowFall.grade]: how many flakes may be on the lens at
## once, how many land a second at [constant REFERENCE_SPEED], the radius range
## as a share of the canvas height, and how long one stays, in seconds.
const GRADES: Array = [
	[0, 0.0, 0.0, 0.0, 0.0, 0.0],
	[2, 0.35, 0.040, 0.065, 0.8, 1.6],
	[4, 0.8, 0.045, 0.080, 1.0, 2.2],
	[6, 1.5, 0.050, 0.095, 1.2, 2.8],
]
## The approach speed, m/s, at which a grade lands its own rate.
const REFERENCE_SPEED := 20.0
## What a lens standing still still catches, as a share of that rate — the
## flakes falling onto a camera that looks a little down the hill.
const STILL_SHARE := 0.1
## And the most it catches, however fast it goes.
const MAX_FACTOR := 1.5
## How fast a flake falls, as [constant SnowFall.FALL_SPEED]; its own motion is
## part of what the lens runs into.
const FALL_SPEED := 1.1
## A frame in which the camera jumps further than this is a cut, not speed.
const CUT_DISTANCE := 5.0

## The middle kept clear, in canvas shares: the centre of the ellipse (a little
## below the middle, where the penguin rides) and its half-width and
## half-height. A flake's whole disc stays outside it.
const CLEAR_CENTRE := Vector2(0.5, 0.54)
const CLEAR_HALF := Vector2(0.30, 0.34)
## How many places one landing tries before giving up on that flake.
const PLACE_TRIES := 8

## Seconds a flake takes to arrive — it hits, it does not fade in.
const LAND_TIME := 0.06
## The share of its stay a flake spends melting: fainter, and shrinking toward
## [constant MELT_SCALE] of its size.
const MELT_SHARE := 0.45
const MELT_SCALE := 0.75

## The blob atlas: [constant BLOB_CELLS]² shapes of [constant BLOB_CELL] texels.
const BLOB_CELLS := 2
const BLOB_CELL := 128

const SEED := 4417

## Which grade is on the hill. Set through [method set_grade].
var grade: int = 0
## The environment's `[partcol]`, as [member SnowFall.tint]. Display space,
## which is what a canvas item draws in.
var tint: Color = Color(0.85, 0.9, 1.0)
## Canvas width over height. Read from the viewport on every [method update];
## a field so the placement can be tested without one.
var aspect: float = 16.0 / 9.0

var _flakes: Array[LensFlake] = []
var _rng := RandomNumberGenerator.new()
## Seconds of reference-rate landing left before the next flake arrives.
var _next_in: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _tracking: bool = false
var _canvas: Node2D
var _texture: ImageTexture

func _init() -> void:
	# Under the HUD (layer 1) and every menu, over the 3D frame.
	layer = 0
	visible = false
	restart()

func _ready() -> void:
	_canvas = Node2D.new()
	_canvas.name = "Flakes"
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Not white paint: the scene behind, blurred and lifted — see the shader.
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/lens_snow.gdshader")
	_canvas.material = material
	_canvas.draw.connect(_draw_flakes)
	add_child(_canvas)

## Put [param value] grades of snow on the lens. Wipes it when the grade moves.
func set_grade(value: int) -> void:
	var wanted: int = clampi(value, 0, GRADES.size() - 1)
	if wanted == grade:
		return
	grade = wanted
	restart()

## A clean lens and the landing sequence from its start, as
## [method SnowFall.restart] does for the falling snow.
func restart() -> void:
	_flakes.clear()
	_rng.seed = SEED
	_tracking = false
	_next_in = _interval()
	visible = grade > 0
	if _canvas != null:
		_canvas.queue_redraw()

## Advance the lens by [param delta] with the drawing camera at [param view].
func update(view: Transform3D, delta: float) -> void:
	if grade <= 0 or delta <= 0.0:
		return
	if is_inside_tree():
		var size: Vector2 = get_viewport().get_visible_rect().size
		if size.y > 0.0:
			aspect = size.x / size.y
	var velocity := Vector3.ZERO
	if _tracking:
		var moved: Vector3 = view.origin - _last_pos
		if moved.length() <= CUT_DISTANCE:
			velocity = moved / delta
	_last_pos = view.origin
	_tracking = true
	step(landing_factor(velocity, -view.basis.z.normalized()), delta)
	if _canvas != null:
		_canvas.queue_redraw()

## How many times the grade's rate lands on a lens moving at [param velocity]
## and looking along [param forward]: the air it runs into, counted along the
## way it faces, over [constant REFERENCE_SPEED].
static func landing_factor(velocity: Vector3, forward: Vector3) -> float:
	var approach: float = (velocity - Vector3(0.0, -FALL_SPEED, 0.0)).dot(forward)
	return clampf(STILL_SHARE + maxf(approach, 0.0) / REFERENCE_SPEED, 0.0, MAX_FACTOR)

## Age the flakes on the lens and land new ones, [param factor] times the
## grade's rate. Split from [method update] so a test can drive it.
func step(factor: float, delta: float) -> void:
	for i: int in range(_flakes.size() - 1, -1, -1):
		_flakes[i].age += delta
		if _flakes[i].age >= _flakes[i].life:
			_flakes.remove_at(i)
	_next_in -= delta * factor
	while _next_in <= 0.0:
		_next_in += _interval()
		if _flakes.size() < int(GRADES[grade][0]):
			_land()

## Reference-rate seconds to the next landing: exponential, so they come as
## weather does, in no rhythm.
func _interval() -> float:
	var rate: float = float(GRADES[grade][1])
	if rate <= 0.0:
		return INF
	return -log(maxf(1.0 - _rng.randf(), 1e-6)) / rate

func _land() -> void:
	var row: Array = GRADES[grade]
	var flake := LensFlake.new()
	flake.radius = _rng.randf_range(float(row[2]), float(row[3]))
	flake.life = _rng.randf_range(float(row[4]), float(row[5]))
	flake.rotation = _rng.randf() * TAU
	flake.cell = _rng.randi() % (BLOB_CELLS * BLOB_CELLS)
	for _try: int in PLACE_TRIES:
		# A little past the edges too: a flake half off the lens is still on it.
		var at := Vector2(_rng.randf_range(-0.03, 1.03), _rng.randf_range(-0.03, 1.03))
		if is_clear(at, flake.radius, aspect):
			flake.position = at
			_flakes.push_back(flake)
			return

## Whether a flake of [param radius] (a share of the canvas height) centred at
## [param at] (canvas shares) keeps its whole disc out of the middle.
static func is_clear(at: Vector2, radius: float, canvas_aspect: float) -> bool:
	# In units of the canvas height, where a flake is round.
	var d := Vector2((at.x - CLEAR_CENTRE.x) * canvas_aspect, at.y - CLEAR_CENTRE.y)
	var half := Vector2(CLEAR_HALF.x * canvas_aspect + radius, CLEAR_HALF.y + radius)
	return (d.x * d.x) / (half.x * half.x) + (d.y * d.y) / (half.y * half.y) >= 1.0

# ==================================================================
#                        what a test can see
# ==================================================================

func flake_count() -> int:
	return _flakes.size()

## Canvas shares.
func flake_position(i: int) -> Vector2:
	return _flakes[i].position

## Share of the canvas height, as drawn now — shrinking while it melts.
func flake_radius(i: int) -> float:
	return _flakes[i].radius * _flakes[i].scale()

func flake_alpha(i: int) -> float:
	return _flakes[i].alpha()

# ==================================================================
#                              drawing
# ==================================================================

func _draw_flakes() -> void:
	if _flakes.is_empty():
		return
	if _texture == null:
		_texture = ImageTexture.create_from_image(make_blob_image())
	var size: Vector2 = _canvas.get_viewport_rect().size
	var cell := Vector2(BLOB_CELL, BLOB_CELL)
	for flake: LensFlake in _flakes:
		var r: float = flake.radius * flake.scale() * size.y
		var region := Rect2(Vector2(float(flake.cell % BLOB_CELLS),
			float(flake.cell / BLOB_CELLS)) * cell, cell)
		_canvas.draw_set_transform(flake.position * size, flake.rotation)
		_canvas.draw_texture_rect_region(_texture, Rect2(-r, -r, 2.0 * r, 2.0 * r),
			region, Color(tint.r, tint.g, tint.b, flake.alpha()))
	_canvas.draw_set_transform(Vector2.ZERO)

## The blobs a flake is drawn from: [constant BLOB_CELLS]² out-of-focus flakes,
## white with the alpha doing the shaping. What a lens a few centimetres from a
## clump of snow records is not the clump but a disc of its light: a soft,
## slightly irregular outline, a faint brighter rim where the blur piles up,
## and a body mottled by the crystals in it. Deterministic.
static func make_blob_image() -> Image:
	var side: int = BLOB_CELLS * BLOB_CELL
	var img := Image.create_empty(side, side, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 1
	var cell := float(BLOB_CELL)
	for q: int in BLOB_CELLS * BLOB_CELLS:
		var origin := Vector2i((q % BLOB_CELLS) * BLOB_CELL, (q / BLOB_CELLS) * BLOB_CELL)
		# Outline: a circle bent by three low harmonics.
		var bends: Array[Vector2] = []
		for _h: int in 3:
			bends.push_back(Vector2(rng.randf_range(0.02, 0.06), rng.randf() * TAU))
		# Mottle: a few soft patches denser or thinner than the body.
		var patches: Array[Vector4] = []
		for _p: int in 6:
			patches.push_back(Vector4(rng.randf_range(-0.25, 0.25), rng.randf_range(-0.25, 0.25),
				rng.randf_range(0.08, 0.18), rng.randf_range(-0.18, 0.18)))
		for y: int in BLOB_CELL:
			for x: int in BLOB_CELL:
				var p := (Vector2(float(x) + 0.5, float(y) + 0.5) - Vector2(cell, cell) * 0.5) / cell
				var theta: float = p.angle()
				var outline: float = 0.44 * (1.0 + bends[0].x * sin(2.0 * theta + bends[0].y)
					+ bends[1].x * sin(3.0 * theta + bends[1].y)
					+ bends[2].x * sin(5.0 * theta + bends[2].y))
				var d: float = p.length() / outline
				if d >= 1.0:
					continue
				var body: float = 0.7
				for patch: Vector4 in patches:
					var o: float = (p - Vector2(patch.x, patch.y)).length() / patch.z
					body += patch.w * exp(-o * o)
				var rim: float = 0.3 * exp(-pow((d - 0.82) / 0.1, 2.0))
				var edge: float = smoothstep(1.0, 0.55, d)
				var a: float = clampf((body + rim) * edge, 0.0, 1.0)
				img.set_pixel(origin.x + x, origin.y + y, Color(1.0, 1.0, 1.0, a))
	img.generate_mipmaps()
	return img

## One flake on the lens.
class LensFlake extends RefCounted:
	## Canvas shares.
	var position: Vector2 = Vector2.ZERO
	## Share of the canvas height, before it melts.
	var radius: float = 0.05
	var rotation: float = 0.0
	var cell: int = 0
	var age: float = 0.0
	var life: float = 1.0

	## 0..1: up over [constant LAND_TIME], down over the melt.
	func alpha() -> float:
		var landed: float = clampf(age / LAND_TIME, 0.0, 1.0)
		return landed * (1.0 - smoothstep(1.0 - MELT_SHARE, 1.0, age / life))

	## The flake's size against [member radius]: a touch small as it hits,
	## shrinking as it melts.
	func scale() -> float:
		var landed: float = lerpf(0.8, 1.0, clampf(age / LAND_TIME, 0.0, 1.0))
		return landed * lerpf(1.0, MELT_SCALE,
			smoothstep(1.0 - MELT_SHARE, 1.0, age / life))
