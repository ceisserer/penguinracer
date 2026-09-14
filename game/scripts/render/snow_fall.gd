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
## the flakes in them get bigger and fall faster with distance, so the three
## together read as one field with depth in it while every flake stays about the
## same size on screen. The whole of the per-frame motion is two numbers an area
## shares, so this is a [MultiMesh] with static instance data and
## `shaders/snow_flakes.gdshader` doing the wrap in the vertex stage — see that
## file. Nothing spawns, nothing dies, and the field is identical on every run,
## which is what a byte-comparable reference capture needs and what the spray's
## [GPUParticles3D] deliberately is not.
##
## [b]Curtains[/b] ([constant CURTAINS]) are the far half: three rings of big
## textured quads at 40, 50 and 60 m, each quad 15–32 m across and drawn from a
## sparse tile of flake specks, turning slowly around the player and sinking.
## They are what makes heavy snow read as weather rather than as confetti in
## front of the camera — at that distance individual quads are below a pixel and
## a tile of them is not. Thirty-odd quads a ring, so this half is CPU-updated
## like the original.
##
## [b]The player is followed, but not exactly.[/b] `CFlakes::Update` moves every
## flake by `YDRIFT` (0.8) of how far the player fell and `ZDRIFT` (0.6) of how
## far they travelled down the hill, and not at all sideways. That fraction is
## the entire feel of the effect: at 1.0 the snow is painted on the camera, at
## 0.0 it is a wall you fly through at 80 km/h and every flake is a streak. The
## residue — the fifth of the fall and the two fifths of the travel the snow
## does *not* follow, plus the wind — is what this class accumulates into the
## shader's `drift`.
##
## [b]DEVIATION, licence-forced, and the same one the spray takes.[/b] ETR's
## flakes are drawn from `snowparticles.png` and its curtains from
## `snow1/2/3.png`; both are `data/textures` art waiting on the licence audit.
## The flakes borrow [method SprayEmitter.make_puff_image], which is the atlas
## ETR binds for them too (`SNOW_PART`), and the curtain tiles are
## [method make_curtain_image] — redrawn to the originals' measured flake count
## and coverage (1.5 %, 4.6 %, 14.7 % of a 512² tile), white with the alpha
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
## The tenth column of `TFlakeArea` is `rotate`, which is true for the near area
## only; it is not here because every area billboards — see the shader.
const FLAKE_AREAS: Array = [
	[],
	[
		[400, 5.0, 4.0, 4.0, -2.0, 4.0, 0.015, 0.03, 5.0],
		[400, 12.0, 5.0, 8.0, 2.0, 8.0, 0.045, 0.07, 5.0],
		[400, 30.0, 6.0, 15.0, 10.0, 15.0, 0.09, 0.18, 5.0],
	],
	[
		[500, 5.0, 4.0, 4.0, -2.0, 4.0, 0.03, 0.045, 5.0],
		[500, 12.0, 5.0, 8.0, 2.0, 8.0, 0.07, 0.1, 5.0],
		[500, 30.0, 6.0, 15.0, 10.0, 15.0, 0.15, 0.22, 5.0],
	],
	[
		[1000, 5.0, 4.0, 4.0, -2.0, 4.0, 0.037, 0.05, 5.0],
		[1000, 12.0, 5.0, 9.0, 2.0, 8.0, 0.09, 0.15, 5.0],
		[1000, 30.0, 6.0, 15.0, 10.0, 15.0, 0.18, 0.35, 5.0],
	],
]

## ETR `CCurtain::Init`. One row per ring: rows, z_dist, tile size, fall speed,
## start angle, minimum height, and which of the three tiles to draw it with.
const CURTAINS: Array = [
	[],
	[
		[3, 60.0, 15.0, 3.0, -100.0, -10.0, 1],
		[3, 50.0, 19.0, 3.0, -100.0, -10.0, 1],
		[3, 40.0, 23.0, 3.0, -100.0, -10.0, 1],
	],
	[
		[3, 60.0, 22.0, 3.0, -100.0, -10.0, 2],
		[3, 50.0, 25.0, 3.0, -100.0, -10.0, 2],
		[3, 40.0, 30.0, 3.0, -100.0, -10.0, 2],
	],
	[
		[3, 60.0, 22.0, 3.0, -100.0, -10.0, 3],
		[3, 50.0, 27.0, 3.0, -100.0, -10.0, 2],
		[3, 40.0, 32.0, 3.0, -100.0, -10.0, 2],
	],
]

## How much of the player's own motion the flakes follow. ETR `YDRIFT`/`ZDRIFT`.
const Y_DRIFT := 0.8
const Z_DRIFT := 0.6
## What the wind does to a flake, and to a curtain. ETR `SNOW_WIND_DRIFT` and
## `CURTAIN_WINDDRIFT` — the curtains are blown three and a half times harder,
## which at their size is a slow swing rather than a gust.
const WIND_DRIFT := 0.1
const CURTAIN_WIND_DRIFT := 0.35

## The six triangle-wave oscillators every curtain row picks one of, and how
## fast they run. ETR `NUM_CHANGES`, `CHANGE_SPEED`, `CHANGE_DRIFT`: a row turns
## at up to `0.15 × 15` = 2.25 degrees a second, and the six of them going at
## different phases is what stops the rings turning as one piece.
const NUM_CHANGES := 6
const CHANGE_SPEED := 0.05
const CHANGE_DRIFT := 15.0

## ETR's own cap on how many quads a ring is cut into.
const MAX_CURTAIN_COLS := 16

## Side of a redrawn curtain tile, as ETR's `snow1/2/3.png`.
const CURTAIN_TILE := 512
## Specks per tile and their radii, measured off the originals by connected
## component: 251 / 882 / 2184 blobs, median area 4–5 px², tailing to 380.
## The cubed uniform reproduces that skew, and the counts then land the coverage
## at 1.6 / 5.6 / 13.9 % against the originals' 1.5 / 4.6 / 14.7 %.
const CURTAIN_SPECKS: Array[int] = [0, 251, 882, 2184]
const SPECK_MIN_RADIUS := 0.8
const SPECK_RADIUS_RANGE := 4.5

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

var _areas: Array[FlakeArea] = []
var _curtains: Array[Curtain] = []
## The oscillators shared by every curtain row. ETR keeps them in a file-static
## `changes[NUM_CHANGES]` and updates them once per frame for all three rings.
var _change_value := PackedFloat32Array()
var _change_min := PackedFloat32Array()
var _change_max := PackedFloat32Array()
var _change_forward: Array[bool] = []

## Where the tracked racer was last frame, and whether there is a last frame.
## The first [method update] after a restart establishes the position rather
## than treating the whole course as one frame of travel.
var _last_pos: Vector3 = Vector3.ZERO
var _tracking: bool = false
## Whether the weather has been placed on the hill yet — see the `visible` flag
## in [method _build_area].
var _placed: bool = false

## The four-puff atlas every flake is drawn from, and one curtain tile per
## density actually asked for — a grade uses at most two of the three, and
## building one is tens of thousands of pixels.
##
## Members rather than script statics, for the reason [SprayEmitter] gives for
## its own atlas: a static would outlive every race and be the one thing still
## referenced when the game exits.
var _puff: ImageTexture
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
		_areas.push_back(_build_area(row, rng))
	_init_changes(rng)
	for row: Array in CURTAINS[grade]:
		_curtains.push_back(_build_curtain(row, rng))
	_apply_tint()
	restart()

## Put the weather back to how it starts. Called on every restart of the race so
## that the first frame of a run is the first frame of the snowfall too — the
## drift and the fall are accumulators, and without this a course restarted after
## five minutes opens on five minutes of drift.
func restart() -> void:
	_tracking = false
	for area: FlakeArea in _areas:
		area.drift = Vector3.ZERO
		area.fall = 0.0
	for curtain: Curtain in _curtains:
		_reset_curtain(curtain)

func _clear() -> void:
	for area: FlakeArea in _areas:
		area.node.queue_free()
	for curtain: Curtain in _curtains:
		curtain.node.queue_free()
	_areas.clear()
	_curtains.clear()

func _build_area(row: Array, rng: RandomNumberGenerator) -> FlakeArea:
	var area := FlakeArea.new()
	var count: int = int(row[0])
	area.extent = Vector3(float(row[1]), float(row[3]), float(row[5]))
	# The box corner relative to the racer: left, bottom, front.
	area.offset = Vector3(-float(row[1]) * 0.5, float(row[2]) - float(row[3]),
		-float(row[4]) - float(row[5]))
	area.speed = float(row[8])

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	area.material = ShaderMaterial.new()
	area.material.shader = load("res://shaders/snow_flakes.gdshader")
	area.material.set_shader_parameter("flake_texture", _flake_texture())
	area.material.set_shader_parameter("box_range", area.extent)
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
		# ETR draws `type = rand() % 4` — one quadrant of the puff atlas per
		# flake, chosen at birth and kept. The index modulo four is what that
		# converges to over four hundred flakes whose *positions* are random,
		# and it keeps the whole of the generator in one function.
		var q: int = i % 4
		mm.set_instance_custom_data(i, Color(float(q % 2) * 0.5, float(q / 2) * 0.5, 0.0, 0.0))

	area.node = MultiMeshInstance3D.new()
	area.node.name = "Flakes%d" % _areas.size()
	area.node.multimesh = mm
	area.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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

func _build_curtain(row: Array, rng: RandomNumberGenerator) -> Curtain:
	var curtain := Curtain.new()
	curtain.rows = int(row[0])
	curtain.z_dist = float(row[1])
	curtain.size = float(row[2])
	curtain.speed = float(row[3])
	curtain.start_angle = float(row[4])
	curtain.min_height = float(row[5])
	# How wide one quad is in degrees seen from the middle, and therefore how
	# many of them go round. `atan(size/2/zdist) * 360/PI` is two half-angles in
	# degrees, written as one expression in the original.
	curtain.angle_dist = atan(curtain.size / 2.0 / curtain.z_dist) * 360.0 / PI
	curtain.cols = mini(int(-2.0 * curtain.start_angle / curtain.angle_dist) + 1,
		MAX_CURTAIN_COLS)
	curtain.last_angle = curtain.start_angle + float(curtain.cols - 1) * curtain.angle_dist
	curtain.row_change.resize(curtain.rows)
	for r: int in curtain.rows:
		curtain.row_change[r] = rng.randi_range(0, NUM_CHANGES - 1)

	var quad := QuadMesh.new()
	quad.size = Vector2(curtain.size, curtain.size)
	curtain.material = StandardMaterial3D.new()
	curtain.material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	curtain.material.albedo_texture = _curtain_texture(int(row[6]))
	curtain.material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	curtain.material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# A ring is drawn from inside it and the quads never overlap each other, so
	# there is nothing for a depth write to resolve — and writing depth from a
	# tile that is 85 % empty would punch the terrain behind it.
	curtain.material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	quad.material = curtain.material

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = curtain.cols * curtain.rows
	curtain.angles.resize(mm.instance_count)
	curtain.heights.resize(mm.instance_count)

	curtain.node = MultiMeshInstance3D.new()
	curtain.node.name = "Curtain%d" % _curtains.size()
	curtain.node.multimesh = mm
	curtain.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	curtain.node.visible = false
	add_child(curtain.node)
	return curtain

## `TCurtain::SetStartParams`: the columns evenly around the arc, the rows
## stacked a tile apart from `minheight` up.
func _reset_curtain(curtain: Curtain) -> void:
	for col: int in curtain.cols:
		for r: int in curtain.rows:
			var i: int = col * curtain.rows + r
			curtain.angles[i] = float(col) * curtain.angle_dist + curtain.start_angle
			curtain.heights[i] = curtain.min_height + float(r) * curtain.size

func _init_changes(rng: RandomNumberGenerator) -> void:
	_change_value.resize(NUM_CHANGES)
	_change_min.resize(NUM_CHANGES)
	_change_max.resize(NUM_CHANGES)
	_change_forward.clear()
	for i: int in NUM_CHANGES:
		_change_min[i] = rng.randf_range(-0.15, -0.05)
		_change_max[i] = rng.randf_range(0.05, 0.15)
		_change_value[i] = (_change_min[i] + _change_max[i]) * 0.5
		_change_forward.push_back(true)

func _apply_tint() -> void:
	for area: FlakeArea in _areas:
		area.material.set_shader_parameter("tint", tint)
	for curtain: Curtain in _curtains:
		curtain.material.albedo_color = tint

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
	var wind_vec: Vector3 = Vector3.ZERO
	if wind != null and wind.windy:
		wind_vec = wind.vector
	_update_flakes(view_pos, wind_vec, moved, delta)
	_update_curtains(view_pos, wind_vec, delta)
	if not _placed:
		_placed = true
		for area: FlakeArea in _areas:
			area.node.visible = true
		for curtain: Curtain in _curtains:
			curtain.node.visible = true

## `CFlakes::Update`, as the residue the shader needs.
##
## The original adds `xcoeff`/`ycoeff`/`zcoeff` to every flake in world space
## while the box itself follows the player exactly; in box-local metres that is
## the same motion minus however far the player moved, which is what the two
## follow fractions leave behind. The `.z` of the wind in the y term is the
## original's — `ycoeff` reads `winddrift.z`, not `.y`, and a vertical gust is
## not a thing `CWind` produces anyway (its vector has a zero y).
func _update_flakes(view_pos: Vector3, wind_vec: Vector3, moved: Vector3,
		delta: float) -> void:
	var step := Vector3(
		wind_vec.x * WIND_DRIFT * delta - moved.x,
		(Y_DRIFT - 1.0) * moved.y + wind_vec.z * WIND_DRIFT * delta,
		(Z_DRIFT - 1.0) * moved.z + wind_vec.z * WIND_DRIFT * delta)
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

## `UpdateChanges` + `TCurtain::Update`: the rings turn, sink, and wrap in both.
func _update_curtains(view_pos: Vector3, wind_vec: Vector3, delta: float) -> void:
	for i: int in NUM_CHANGES:
		if _change_forward[i]:
			_change_value[i] += CHANGE_SPEED * delta
			if _change_value[i] > _change_max[i]:
				_change_forward[i] = false
		else:
			_change_value[i] -= CHANGE_SPEED * delta
			if _change_value[i] < _change_min[i]:
				_change_forward[i] = true

	var wind_turn: float = wind_vec.x * delta * CURTAIN_WIND_DRIFT
	for curtain: Curtain in _curtains:
		var mm: MultiMesh = curtain.node.multimesh
		for col: int in curtain.cols:
			for r: int in curtain.rows:
				var i: int = col * curtain.rows + r
				var angle: float = curtain.angles[i]
				angle += _change_value[curtain.row_change[r]] * delta * CHANGE_DRIFT
				angle += wind_turn
				if angle > curtain.last_angle + curtain.angle_dist:
					angle = curtain.start_angle
				elif angle < curtain.start_angle - curtain.angle_dist:
					angle = curtain.last_angle
				curtain.angles[i] = angle

				var height: float = curtain.heights[i] - curtain.speed * delta
				if height < curtain.min_height - curtain.size:
					height += float(curtain.rows) * curtain.size
				curtain.heights[i] = height

				var at: Vector3 = view_pos + curtain_vector(angle, curtain.z_dist)
				at.y = view_pos.y + height
				# Turned by −angle about Y, which is what faces a quad placed at
				# `angle` back at the middle of the ring.
				mm.set_instance_transform(i, Transform3D(
					Basis(Vector3.UP, deg_to_rad(-angle)), at))

## `TCurtain::CurtainVec`: where on the ring an angle is, in metres from the
## player. Zero degrees is straight ahead — down −z, the way the course runs —
## and the sign flip past ±90° is what puts the back of the ring behind you.
static func curtain_vector(angle_deg: float, z_dist: float) -> Vector3:
	var x: float = z_dist * sin(deg_to_rad(angle_deg))
	var z: float = sqrt(maxf(z_dist * z_dist - x * x, 0.0))
	if angle_deg <= 90.0 and angle_deg >= -90.0:
		z = -z
	return Vector3(x, 0.0, z)

# ==================================================================
#                            the redraw
# ==================================================================

## ETR binds `SNOW_PART` for the flakes and for the spray alike, so this is the
## spray's redrawn atlas and not a second one.
func _flake_texture() -> ImageTexture:
	if _puff == null:
		_puff = ImageTexture.create_from_image(SprayEmitter.make_puff_image())
	return _puff

func _curtain_texture(density: int) -> ImageTexture:
	if not _tiles.has(density):
		_tiles[density] = ImageTexture.create_from_image(make_curtain_image(density))
	return _tiles[density]

## A redrawn `snow<density>.png`: a 512² tile of soft white specks on nothing,
## at the density the original's tile has. [param density] is 1, 2 or 3.
##
## The originals are a field of bluish-white blobs — 251, 882 and 2184 of them,
## covering 1.5 %, 4.6 % and 14.7 % of the tile, mostly 2 px across with a few
## up to 22 — and they are modulated by `[partcol]` when they are drawn. These
## are white, with the alpha doing all of the shaping and the tint doing all of
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
		# Cubed, so most specks are the 2 px ones and a few are the 20 px ones —
		# the skew the originals' component sizes have.
		var u: float = rng.randf()
		var radius: float = SPECK_MIN_RADIUS + SPECK_RADIUS_RANGE * u * u * u
		_draw_speck(img, cx, cy, radius)
	# The curtains are seen at 40–60 m and the flake tile is 512²; without mips
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
#                          the two layers
# ==================================================================

## One of ETR's `TFlakeArea`s: a box of wrapping flakes, and the two
## accumulators the shader turns into their positions.
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
	## The integral of [member speed]; a flake falls this times its own size.
	var fall: float = 0.0

## One of ETR's `TCurtain`s: a ring of big tiles that turns and sinks.
class Curtain extends RefCounted:
	var node: MultiMeshInstance3D
	var material: StandardMaterial3D
	var rows: int = 3
	var cols: int = 0
	var z_dist: float = 60.0
	var size: float = 15.0
	var speed: float = 3.0
	var start_angle: float = -100.0
	var last_angle: float = 100.0
	var angle_dist: float = 0.0
	var min_height: float = -10.0
	## Per element, indexed `col * rows + row`.
	var angles := PackedFloat32Array()
	var heights := PackedFloat32Array()
	## Which of the six oscillators each row turns with.
	var row_change := PackedInt32Array()
