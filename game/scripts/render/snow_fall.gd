## Weather: the snow that falls on the course, ported from ETR `CFlakes` and
## `CCurtain` (particles.cpp §4.4 items 3 and 4).
##
## This is the *weather* snow, not the snow the course is made of and not the
## spray the carve throws up — `g_game.snow_id`, which the original's race-select
## screen offers as four levels and which [member RaceSetup.snowfall] carries
## here. It has no effect on the simulation whatsoever: ETR draws it and nothing
## else, and so does this. It is presentation, and it runs on the frame's clock
## (architecture rule 7).
##
## [b]Two layers, and they are two different effects.[/b]
##
## [b]Flakes[/b] ([constant FLAKE_AREAS]) are three nested boxes around the
## player — 5 m, 12 m and 30 m wide — each holding a fixed set of quads that
## wrap when they leave it. The boxes are staggered *ahead* of the player and
## hold flakes of one world size, so the three together read as one field with
## depth in it: the near flakes are the big, fast ones on screen and the far
## ones small and slow. The whole of the per-frame motion is two numbers an area
## shares, so this is a [MultiMesh] with static instance data and
## `shaders/snow_flakes.gdshader` doing the wrap in the vertex stage — see that
## file. Nothing spawns, nothing dies, and the field is identical on every run,
## which is what a byte-comparable reference capture needs and what the spray's
## [GPUParticles3D] deliberately is not.
##
## [b]Far snow[/b] ([constant FAR_AREAS]) is the other half, and it is what
## makes heavy snow read as weather rather than as confetti in front of the
## camera: beyond 25 m a single flake is below a pixel and a patch of them is
## not. ETR's `CCurtain` draws it as three rings of big speck-textured quads at
## 40, 50 and 60 m, centred on the player, turning and sinking. DEVIATION: a
## ring centred on the player moves with the player — no parallax, no looming as
## you ride into it — and that, more than anything the flakes did, is what made
## the snow read as an overlay. So the far half is a fourth flake area with the
## same world-anchored shader: a box 150 m square holding two thousand-odd quads
## 5–6.5 m wide, each a random patch cut from a curtain tile, drawn only in a
## shell 25–72 m from the camera ([constant FAR_FADE]). Same specks per square
## metre as the curtains, and now they hang in the world like the flakes do.
##
## [b]The player is not followed.[/b] DEVIATION. `CFlakes::Update` moves every
## flake by `YDRIFT` (0.8) of how far the player fell and `ZDRIFT` (0.6) of how
## far they travelled down the hill, so the snow half-rides with the camera: at
## 80 km/h it comes at you at two fifths of your speed, every flake in a box
## moves as one sheet, and the whole field reads as an overlay unrelated to the
## racer. ETR did it because at 0.0 "every flake is a streak" — which is what
## snow does look like at that speed, on film and to the eye. So here the flakes
## hang in the world ([method _update_flakes] only takes the box's own motion
## back out of it) and the shader draws each one stretched along how it moved
## against the camera. Two more things stop the sheets: every flake falls at its
## own speed and sways on its own phase ([method flake_seed]), and the fall is a
## real one — [constant FALL_SPEED] for every flake, where ETR's is its size
## times five, which keeps screen speed equal across the three boxes and so
## throws away the parallax that says how far away a flake is.
##
## [b]DEVIATION, licence-forced, and the same one the spray takes.[/b] ETR's
## flakes are drawn from `snowparticles.png` and its curtains from
## `snow1/2/3.png`; both are `data/textures` art waiting on the licence audit.
## The flakes are drawn from [method make_flake_image] — irregular clumps,
## where ETR binds the spray's round puffs for them (`SNOW_PART`) — and the
## curtain tiles are [method make_curtain_image], redrawn to the originals'
## coverage (1.5 %, 4.6 %, 14.7 % of a 512² tile). Both white with the alpha
## doing the shaping, deterministic so captures stay comparable.
class_name SnowFall
extends Node3D

## `g_game.snow_id` runs 0–3: none, and the original's three grades.
const MAX_GRADE := 3

## ETR `CFlakes::Init`. One row per area, in the order the original pushes them:
## count, xrange, ytop, yrange, zback, zrange, min_size, max_size, fall speed.
##
## The box is `x ∈ [cpos.x − xrange/2, +xrange/2]`, `y ∈ [cpos.y + ytop − yrange,
## cpos.y + ytop]`, `z ∈ [cpos.z − zback − zrange, cpos.z − zback]` — and since
## the course runs down −z, a positive `zback` is an area that sits entirely
## *in front of* the player. The near box straddles them (`zback` −2), the middle
## one covers 2–10 m ahead and the far one 10–25 m.
##
## DEVIATION: every area holds flakes of the same *world* size, where ETR grows
## them with distance (up to 0.35 m in the outer box) so that all three read the
## same size on screen. On a camera that holds still that is invisible; on one
## that moves it is the one thing the eye checks. A flake's size and its speed
## across the screen both scale as one over its distance, so their ratio says
## nothing about depth and must be the same for every flake — ETR's outer
## flakes were big *and* slow, which no real flake can be, and read as round
## blobs drifting in front of the lens while the small ones rushed past. Here
## the near box's sizes hold everywhere: what is close is big and fast, what is
## far is small and slow, and a far flake that would fall below a pixel is drawn
## at one and faded by the area it lost (the shader's `MIN_PIXELS`). The outer
## boxes hold more of them, because each now covers so much less of the screen.
##
## The tenth column of `TFlakeArea` is `rotate`, which is true for the near area
## only; it is not here because every area billboards — see the shader.
const FLAKE_AREAS: Array = [
	[],
	[
		[400, 5.0, 4.0, 4.0, -2.0, 4.0, 0.015, 0.03, 5.0],
		[800, 12.0, 5.0, 8.0, 2.0, 8.0, 0.015, 0.03, 5.0],
		[1600, 30.0, 6.0, 15.0, 10.0, 15.0, 0.015, 0.03, 5.0],
	],
	[
		[500, 5.0, 4.0, 4.0, -2.0, 4.0, 0.03, 0.045, 5.0],
		[1000, 12.0, 5.0, 8.0, 2.0, 8.0, 0.03, 0.045, 5.0],
		[2000, 30.0, 6.0, 15.0, 10.0, 15.0, 0.03, 0.045, 5.0],
	],
	[
		[1000, 5.0, 4.0, 4.0, -2.0, 4.0, 0.037, 0.05, 5.0],
		[2000, 12.0, 5.0, 9.0, 2.0, 8.0, 0.037, 0.05, 5.0],
		[4000, 30.0, 6.0, 15.0, 10.0, 15.0, 0.037, 0.05, 5.0],
	],
]

## The far snow, one area per grade, in the column order of [constant
## FLAKE_AREAS] up to the sizes; the ninth column is which curtain tile the
## patches are cut from. The box is 150 m square about the player, so the view
## looks into it whichever way it turns — a slalom, the start animation facing
## back up the hill. ETR's rings covered ±100° about the fall line and left the
## back of the view empty. The counts are the curtains' density over that
## whole square; at a few thousand quads that is still nothing. The patches
## top out at 6.5 m rather than the 8 that matches the rings' specks, because
## the biggest specks read as blobs, and the counts rise to cover the same
## ground. The specks themselves are far smaller than the originals' — see
## [constant CURTAIN_SPECKS]. Which tile
## follows the curtains' own: grade 1 was three rings of tile 1, grade 2 of
## tile 2, grade 3 mostly tile 2 with its nearest ring in 3.
const FAR_AREAS: Array = [
	[],
	[2300, 150.0, 25.0, 65.0, -75.0, 150.0, 5.0, 6.5, 1],
	[2300, 150.0, 25.0, 65.0, -75.0, 150.0, 5.0, 6.5, 2],
	[2150, 150.0, 25.0, 65.0, -75.0, 150.0, 5.0, 6.5, 3],
]
## Where the far snow is drawn: fading in from 25 to 35 m from the camera, where
## the near boxes are thinning out, and out again from 60 to 72, short of the
## box's far face. The curtains stood at 40–60 m.
const FAR_FADE := Vector4(25.0, 35.0, 60.0, 72.0)
## The box is big, so its faces fade over a smaller share of it.
const FAR_EDGE_FADE := 0.08
## How much of a curtain tile one patch shows: a 128² cut of the 512², which at
## 5–6.5 m makes a speck 4–5 cm a texel — the density and speck size the rings
## had at 15–32 m for a whole tile.
const FAR_UV_SCALE := 0.25

## How fast a flake falls, m/s, before its own ±30 %. Real snow falls at about
## one metre a second whatever its size. DEVIATION — see the class notes; the
## ninth column of [constant FLAKE_AREAS] is ETR's and is no longer read.
const FALL_SPEED := 1.1
## What the wind does to a flake, near or far. ETR `SNOW_WIND_DRIFT`; its
## `CURTAIN_WINDDRIFT` turned a ring, and there is no ring any more.
const WIND_DRIFT := 0.1
## A frame in which the camera jumps further than this is a cut — a restart, a
## spectator switch — and draws no streak rather than one across the course.
const CUT_DISTANCE := 5.0

## Side of a redrawn curtain tile, as ETR's `snow1/2/3.png`. The far snow's
## patches are cut from these.
const CURTAIN_TILE := 512
## Specks per tile and their radii. The originals measure 251 / 882 / 2184
## blobs by connected component, median area 4–5 px² but tailing to 380, and
## covering 1.5 / 4.6 / 14.7 % of the tile. DEVIATION: the coverage is kept and
## the tail is not. A texel of a far patch is 4–5 cm, so the originals' biggest
## specks are half-metre flakes 30–70 m out — big and slow on screen, the same
## blob the outer flake box made (see [constant FLAKE_AREAS]). Here every speck
## is one or two texels, about a pixel at that distance, and there are more of
## them, at about the same coverage.
const CURTAIN_SPECKS: Array[int] = [0, 1000, 3000, 10500]
const SPECK_MIN_RADIUS := 0.8
const SPECK_RADIUS_RANGE := 0.8

## The near flakes' atlas: [constant FLAKE_CELLS]² shapes, each in a square of
## [constant FLAKE_CELL] texels — enough for a flake a metre from the lens.
const FLAKE_CELLS := 4
const FLAKE_CELL := 64
## How far out of its cell's centre a shape may reach, as a share of the cell.
## Short of the half, so a spun cell never reads its neighbour and the mips of
## one shape do not bleed into the next.
const FLAKE_REACH := 0.44
## How fast a flake turns as it falls, in rad/s before its own factor.
const FLAKE_TUMBLE := 1.2

## Fixed, because a race that looks different every time it is loaded cannot be
## captured and compared. ETR seeded from the global `rand()`.
const SEED := 8731

## Which grade is on the hill. Set through [method set_grade].
var grade: int = 0

## The environment's `[partcol]`. [RaceScene] hands the preset's over when it
## lights the course, exactly as it does for the spray.
var tint: Color = Color(0.85, 0.9, 1.0):
	set(value):
		tint = value
		_apply_tint()

## The near areas in [constant FLAKE_AREAS] order, then the far one.
var _areas: Array[FlakeArea] = []

## Where the tracked racer was last frame, and whether there is a last frame.
## The first [method update] after a restart establishes the position rather
## than treating the whole course as one frame of travel.
var _last_pos: Vector3 = Vector3.ZERO
var _tracking: bool = false
## The camera's view matrix at the last [method update], for the streaks.
var _last_view: Transform3D = Transform3D.IDENTITY
## Seconds since [method restart], for the sway. Not the shader's `TIME`, which
## keeps running across restarts and would make no two captures alike.
var _clock: float = 0.0
## Whether the weather has been placed on the hill yet — see the `visible` flag
## in [method _build_area].
var _placed: bool = false

## The clump atlas every flake is drawn from, and the curtain tile the far
## snow is cut from — one per density actually asked for, because building one
## is tens of thousands of pixels.
##
## Members rather than script statics, for the reason [SprayEmitter] gives for
## its own atlas: a static would outlive every race and be the one thing still
## referenced when the game exits.
var _flakes: ImageTexture
var _tiles: Dictionary[int, ImageTexture] = {}

# ==================================================================
#                             building
# ==================================================================

## Put [param value] grades of snow on the course. Rebuilds if it changed and
## does nothing at all if it did not, so it is safe to call whenever the shell
## hands a [RaceSetup] over.
func set_grade(value: int) -> void:
	var wanted: int = clampi(value, 0, MAX_GRADE)
	if wanted == grade and (wanted == 0 or not _areas.is_empty()):
		return
	grade = wanted
	_clear()
	_placed = false
	if grade == 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for row: Array in FLAKE_AREAS[grade]:
		_areas.push_back(_build_area(row, rng, false))
	_areas.push_back(_build_area(FAR_AREAS[grade], rng, true))
	_apply_tint()
	restart()

## Put the weather back to how it starts. Called on every restart of the race so
## that the first frame of a run is the first frame of the snowfall too — the
## drift and the fall are accumulators, and without this a course restarted after
## five minutes opens on five minutes of drift.
func restart() -> void:
	_tracking = false
	_clock = 0.0
	for area: FlakeArea in _areas:
		area.drift = Vector3.ZERO
		area.fall = 0.0

func _clear() -> void:
	for area: FlakeArea in _areas:
		area.node.queue_free()
	_areas.clear()

## One wrapping box of quads. [param row] is a row of [constant FLAKE_AREAS], or
## of [constant FAR_AREAS] when [param far] is set, which cuts the quads from a
## curtain tile and draws them only in [constant FAR_FADE].
func _build_area(row: Array, rng: RandomNumberGenerator, far: bool) -> FlakeArea:
	var area := FlakeArea.new()
	var count: int = int(row[0])
	area.extent = Vector3(float(row[1]), float(row[3]), float(row[5]))
	# The box corner relative to the racer: left, bottom, front.
	area.offset = Vector3(-float(row[1]) * 0.5, float(row[2]) - float(row[3]),
		-float(row[4]) - float(row[5]))
	area.speed = FALL_SPEED

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	area.material = ShaderMaterial.new()
	area.material.shader = load("res://shaders/snow_flakes.gdshader")
	if far:
		area.material.set_shader_parameter("flake_texture", _curtain_texture(int(row[8])))
		area.material.set_shader_parameter("uv_scale", FAR_UV_SCALE)
		area.material.set_shader_parameter("fade_band", FAR_FADE)
		area.material.set_shader_parameter("edge_fade", FAR_EDGE_FADE)
	else:
		area.material.set_shader_parameter("flake_texture", _flake_texture())
		area.material.set_shader_parameter("uv_scale", 1.0 / float(FLAKE_CELLS))
		area.material.set_shader_parameter("tumble", FLAKE_TUMBLE)
	area.material.set_shader_parameter("box_range", area.extent)
	area.material.set_shader_parameter("fall_speed", area.speed)
	quad.material = area.material

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = count
	var field: Array[Vector4] = flake_field(row, rng)
	for i: int in count:
		var flake: Vector4 = field[i]
		var size: float = flake.w
		mm.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3.ONE * size),
			Vector3(flake.x, flake.y, flake.z)))
		# ETR draws `type = rand() % 4` — one quadrant of its atlas per flake,
		# chosen at birth and kept. Here one of sixteen cells, by the index
		# modulo sixteen: what that converges to over hundreds of flakes whose
		# *positions* are random, and it keeps the generator in one function.
		var cells: int = FLAKE_CELLS * FLAKE_CELLS
		var q: int = i % cells
		var origin := Vector2(float(q % FLAKE_CELLS), float(q / FLAKE_CELLS)) \
			/ float(FLAKE_CELLS)
		if far:
			# A patch anywhere in the tile that does not run off its edge, so
			# the sampler never has to repeat.
			origin = Vector2(rng.randf(), rng.randf()) * (1.0 - FAR_UV_SCALE)
		var seed: Vector2 = flake_seed(i)
		mm.set_instance_custom_data(i, Color(origin.x, origin.y, seed.x, seed.y))

	area.node = MultiMeshInstance3D.new()
	area.node.name = "FarSnow" if far else "Flakes%d" % _areas.size()
	area.node.multimesh = mm
	area.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The instances only span the box, but a streak reaches past it by up to the
	# shader's `MAX_STREAK`, and a culled box is a hole in the snow.
	area.node.custom_aabb = AABB(-Vector3.ONE * 2.0, area.extent + Vector3.ONE * 4.0)
	# Nothing is drawn until the first [method update] has said where the racer
	# is: a box that has not been placed yet is a box at the world origin, which
	# on a course is a real place the camera could be looking at.
	area.node.visible = false
	add_child(area.node)
	return area

## What is in one flake area, as the numbers the batch is built from: a base
## position in box-local metres, packed with the flake's own size. [param row]
## is a row of [constant FLAKE_AREAS].
##
## Split out of [method _build_area] so it can be asserted. A [MultiMesh]'s
## transforms live in the [RenderingServer], which keeps none of them under the
## dummy renderer — `get_instance_transform` reads back the identity in a
## headless test (see the trap list), so what feeds the batch is the only thing
## there is to check.
## Flake [param index]'s own two numbers in [0, 1), which set its fall speed,
## sway rate and sway phase in the shader. The R2 low-discrepancy sequence
## rather than the area's generator, so adding them left [method flake_field]
## — and every flake position — exactly as it was, and so neighbouring flakes
## are never alike.
static func flake_seed(index: int) -> Vector2:
	return Vector2(fposmod(0.5 + float(index) * 0.7548776662, 1.0),
		fposmod(0.5 + float(index) * 0.5698402910, 1.0))

static func flake_field(row: Array, rng: RandomNumberGenerator) -> Array[Vector4]:
	var count: int = int(row[0])
	var extent := Vector3(float(row[1]), float(row[3]), float(row[5]))
	var min_size: float = float(row[6])
	var max_size: float = float(row[7])
	var out: Array[Vector4] = []
	out.resize(count)
	for i: int in count:
		# ETR scatters a flake over the whole box. `MakeSnowFlake` then *negates*
		# the y it drew, which puts every flake below the world and lets
		# `Update`'s one-wrap-per-frame walk it back up over the first second of
		# the race; not ported, because it is a start-up artefact of a sign and
		# the wrap it exploits is the same one used here.
		out[i] = Vector4(
			rng.randf() * extent.x, rng.randf() * extent.y, rng.randf() * extent.z,
			rng.randf_range(min_size, max_size))
	return out

func _apply_tint() -> void:
	for area: FlakeArea in _areas:
		area.material.set_shader_parameter("tint", tint)

# ==================================================================
#                            every frame
# ==================================================================

## Move the weather with [param view_pos] — the racer being watched, which is
## `ctrl->cpos` in the original. [param wind] is that racer's [WindField], or
## null on a course with no wind; nothing here writes to it.
##
## Presentation only: called from [method RaceScene._present], on the frame's
## clock rather than the tick's, and reading nothing the simulation owns.
func update(view_pos: Vector3, wind: WindField, delta: float) -> void:
	if grade <= 0 or delta <= 0.0:
		return
	if not _tracking:
		_last_pos = view_pos
		_tracking = true
	var moved: Vector3 = view_pos - _last_pos
	_last_pos = view_pos
	_clock += delta
	var wind_vec: Vector3 = Vector3.ZERO
	if wind != null and wind.windy:
		wind_vec = wind.vector
	_update_flakes(view_pos, wind_vec, moved, delta)
	if not _placed:
		_placed = true
		for area: FlakeArea in _areas:
			area.node.visible = true

## `CFlakes::Update`, as the numbers the shader needs.
##
## The box follows the player exactly and the flakes do not follow at all, so
## the drift is the wind less however far the box moved. The wind is carried
## level: ETR adds `winddrift.z` to the fall as well (`ycoeff`), which only made
## sense while the flakes were half-following, and `CWind` has no vertical gust
## to carry. The camera is read here rather than handed in because the intro
## borrows it and a spectator switch moves it; whichever one is drawing is the
## one the streaks are measured against.
func _update_flakes(view_pos: Vector3, wind_vec: Vector3, moved: Vector3,
		delta: float) -> void:
	var air := Vector3(wind_vec.x, 0.0, wind_vec.z) * WIND_DRIFT
	var step: Vector3 = air * delta - moved
	var view: Transform3D = _last_view
	var camera: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		view = camera.global_transform.affine_inverse()
	var before: Transform3D = _last_view
	if not _placed or moved.length() > CUT_DISTANCE \
			or view.inverse().origin.distance_to(before.inverse().origin) > CUT_DISTANCE:
		before = view
	_last_view = view
	for area: FlakeArea in _areas:
		# Kept wrapped here as well as in the shader, so a long race cannot walk
		# the accumulator out of the range where a metre is still a metre.
		area.drift = (area.drift + step).posmodv(area.extent)
		area.fall += area.speed * delta
		var corner: Vector3 = view_pos + area.offset
		area.node.global_position = corner
		area.material.set_shader_parameter("box_origin", corner)
		area.material.set_shader_parameter("drift", area.drift)
		area.material.set_shader_parameter("fall_distance", area.fall)
		area.material.set_shader_parameter("clock", _clock)
		area.material.set_shader_parameter("air", air)
		area.material.set_shader_parameter("prev_view", Projection(before))
		area.material.set_shader_parameter("frame_time", delta)

# ==================================================================
#                            the redraw
# ==================================================================

## DEVIATION: ETR binds `SNOW_PART` for the flakes and the spray alike — four
## round puffs. A round puff is fine as a spray particle, which is gone in a
## second; a flake drifting a metre from the lens is looked at, and a perfect
## disc there reads as a dot rather than as snow. So the flakes get their own
## atlas of irregular clumps ([method make_flake_image]), and the shader turns
## and tumbles each one as it falls.
func _flake_texture() -> ImageTexture:
	if _flakes == null:
		_flakes = ImageTexture.create_from_image(make_flake_image())
	return _flakes

## The near flakes' atlas: [constant FLAKE_CELLS]² cells, each one clump of
## snow. A flake big enough to see is an aggregate — crystals that collided and
## stuck on the way down — so each cell is grown the same way: a seed lobe, and
## then six to twelve smaller ones, each fused onto the rim of one already
## there. Soft-edged and white, with the alpha doing the shaping as in
## [method make_curtain_image]. Everything stays within [constant FLAKE_REACH]
## of the cell's centre, which is what lets the shader spin a cell in place.
## Deterministic.
static func make_flake_image() -> Image:
	var side: int = FLAKE_CELLS * FLAKE_CELL
	var img := Image.create_empty(side, side, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 100
	var cell := float(FLAKE_CELL)
	for q: int in FLAKE_CELLS * FLAKE_CELLS:
		var centre := (Vector2(float(q % FLAKE_CELLS), float(q / FLAKE_CELLS)) \
			+ Vector2(0.5, 0.5)) * cell
		# Lobes as (x, y, radius) about the cell's centre.
		var lobes: Array[Vector3] = [Vector3(0.0, 0.0, rng.randf_range(0.17, 0.22) * cell)]
		var wanted: int = rng.randi_range(6, 12)
		var tries: int = 0
		while lobes.size() < wanted and tries < 200:
			tries += 1
			var parent: Vector3 = lobes[rng.randi() % lobes.size()]
			var radius: float = rng.randf_range(0.08, 0.15) * cell
			var at := Vector2(parent.x, parent.y) + Vector2.from_angle(rng.randf() * TAU) \
				* (parent.z + radius) * rng.randf_range(0.35, 0.7)
			if at.length() + radius > FLAKE_REACH * cell:
				continue
			lobes.push_back(Vector3(at.x, at.y, radius))
		for lobe: Vector3 in lobes:
			_draw_lobe(img, centre + Vector2(lobe.x, lobe.y), lobe.z,
				rng.randf_range(0.8, 1.0))
	img.generate_mipmaps()
	return img

## One soft lobe of a clump: opaque over most of its disc and falling off at
## the rim, the brighter of two overlapping lobes winning.
static func _draw_lobe(img: Image, c: Vector2, radius: float, peak: float) -> void:
	var r: int = int(ceil(radius))
	for dy: int in range(-r, r + 1):
		for dx: int in range(-r, r + 1):
			var x: int = int(floor(c.x)) + dx
			var y: int = int(floor(c.y)) + dy
			var d2: float = (Vector2(float(x) + 0.5, float(y) + 0.5) - c).length_squared() \
				/ (radius * radius)
			if d2 >= 1.0:
				continue
			var a: float = peak * minf(1.0, 1.3 * (1.0 - d2))
			if a > img.get_pixel(x, y).a:
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))

func _curtain_texture(density: int) -> ImageTexture:
	if not _tiles.has(density):
		_tiles[density] = ImageTexture.create_from_image(make_curtain_image(density))
	return _tiles[density]

## A redrawn `snow<density>.png`: a 512² tile of soft white specks on nothing,
## at the density the original's tile has. [param density] is 1, 2 or 3. ETR
## draws its curtains with these; here the far snow's patches are cut from them.
##
## The originals are a field of bluish-white blobs — 251, 882 and 2184 of them,
## covering 1.5 %, 4.6 % and 14.7 % of the tile, mostly 2 px across with a few
## up to 22 — and they are modulated by `[partcol]` when they are drawn. These
## cover the same share in specks that are all small ([constant
## CURTAIN_SPECKS]), and are white, with the alpha doing all of the shaping and the tint doing all of
## the colour, which is the same division [method SprayEmitter.make_puff_image]
## makes and avoids tinting twice. Deterministic: same seed, same tile, every
## run on every machine.
static func make_curtain_image(density: int) -> Image:
	var img := Image.create_empty(CURTAIN_TILE, CURTAIN_TILE, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 0.0))
	var count: int = CURTAIN_SPECKS[clampi(density, 0, CURTAIN_SPECKS.size() - 1)]
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + density
	for i: int in count:
		var cx: float = rng.randf() * float(CURTAIN_TILE)
		var cy: float = rng.randf() * float(CURTAIN_TILE)
		var radius: float = SPECK_MIN_RADIUS + SPECK_RADIUS_RANGE * rng.randf()
		_draw_speck(img, cx, cy, radius)
	# The far snow is seen at 25–72 m and the tile is 512²; without mips
	# that is the crawling speckle the terrain textures got theirs for.
	img.generate_mipmaps()
	return img

## One speck, wrapped at the tile edges so a ring of quads has no seam and no
## flake-free border. Alpha saturates over the middle half of the disc and falls
## off outside it, which is the profile the originals measure: about half of a
## covered pixel is above 224.
static func _draw_speck(img: Image, cx: float, cy: float, radius: float) -> void:
	var r: int = int(ceil(radius))
	for dy: int in range(-r, r + 1):
		for dx: int in range(-r, r + 1):
			var nx: float = (float(dx) + 0.5) / radius
			var ny: float = (float(dy) + 0.5) / radius
			var d2: float = nx * nx + ny * ny
			if d2 >= 1.0:
				continue
			var a: float = minf(1.0, 2.0 * (1.0 - d2))
			var x: int = posmod(int(floor(cx)) + dx, CURTAIN_TILE)
			var y: int = posmod(int(floor(cy)) + dy, CURTAIN_TILE)
			# Specks overlap; the brighter one wins rather than the two summing
			# past white.
			if a > img.get_pixel(x, y).a:
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))

# ==================================================================
#                            the areas
# ==================================================================

## One of ETR's `TFlakeArea`s — or the far snow, which is one too: a box of
## wrapping quads, and the two accumulators the shader turns into their
## positions.
class FlakeArea extends RefCounted:
	var node: MultiMeshInstance3D
	var material: ShaderMaterial
	## `(xrange, yrange, zrange)`.
	var extent: Vector3 = Vector3.ONE
	## The box's minimum corner, relative to the racer being watched.
	var offset: Vector3 = Vector3.ZERO
	var speed: float = 5.0
	## Box-local metres of shared motion, kept inside [member extent].
	var drift: Vector3 = Vector3.ZERO
	## The integral of [member speed]; a flake falls this times its own factor.
	var fall: float = 0.0

