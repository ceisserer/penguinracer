## Generates **Mountain Forest**, the second course authored for this project:
## a narrow trail down the floor of a steep wooded gully. Where Forest Trail is
## a wide, even slope through open forest, this one is walled in — the banks
## either side climb 15–30 m, so the view runs down the valley and the trees
## on the walls close it in — and its fall line is uneven: steep chutes
## between near-level benches, and twice the gully pinches to a slot with a
## dead trunk lodged across it overhead, to race under. Bumps along it throw a
## racer into the air; boulders and fallen trunks lying from a bank half across
## the trail have to be steered round, or jumped. The sky over it is a near
## range, tall and wooded to the crests.
##
##     tools/gen_mountain_forest.sh
##
## which runs this twice with Godot's `--import` in between, like
## `gen_forest_trail.gd` (see there for why):
##
##     godot --headless --path game --script res://addons/course_gen/gen_mountain_forest.gd -- --stage=assets
##     godot --headless --path game --import
##     godot --headless --path game --script res://addons/course_gen/gen_mountain_forest.gd -- --stage=resources
##
## The same shape as every course — `res://courses/mountain_forest/` — and the
## same promises: deterministic, re-runnable, never visited by the importer.
## It reuses Forest Trail's four props and adds a fifth, `lodged_log`: a long
## trunk ([constant PropMesh.Kind.TRUNK]) drawn level (not laid on the slope), held above the ground by its
## marker's Y and leaning by its roll ([method CourseRoot.build_runtime]),
## and not collidable — a trunk overhead is something to duck under, and the
## collision grid only knows upright cylinders. The needle floor is this
## course's own copy of [method CourseGenKit.needle_texture], since a course's
## web pack carries only its own directory.
##
## [b]Obstacles on the trail.[/b] A boulder there is Forest Trail's boulder
## prefab under another type name (`trail_boulder`, so a test can tell it from
## the ones that must stay off the trail). A fallen trunk is two types: the
## trunk itself (`fallen_trunk`, the lodged trunk's prefab, lying from the
## bank onto the snow) and a row of `trunk_collider` markers along the part of
## it over the trail — a prefab with no mesh, only a collision cylinder each,
## as tall as the trunk there, so it can be jumped as well as hit. The grid
## knows only upright cylinders; a row of them is a log.
##
## [b]The uneven slope.[/b] The heightmap is relief over the analytic slope of
## [member CourseData.base_angle], which is the mean of [constant SECTIONS]'
## gradients; the steps are the difference, integrated down the course
## ([method _profile]). The occlusion bake is handed the relief *without*
## them: it measures against a uniformly tilted plane, and a change of
## gradient is not a bank that shades anything.
extends SceneTree

const DIR := "mountain_forest"
const OUT := "res://courses/mountain_forest"
const PREVIEW_SIZE := Vector2i(192, 144)

const DISPLAY_NAME := "Mountain Forest"
const AUTHOR := "PenguinRacer"
const DESCRIPTION := "Down the floor of a steep wooded gully. Short steep chutes drop " \
	+ "onto quiet benches, bumps throw you into the air, and boulders and fallen " \
	+ "trees lie on the trail: steer round them or jump. Twice the gully narrows " \
	+ "to a slot under a dead tree wedged across it overhead."

## Course extent, metres: width along +X, length along -Z.
const WORLD := Vector2(100.0, 1500.0)
## Where the finish line is, and how wide the play area.
const PLAY := Vector2(90.0, 1420.0)
const CELL := 0.5
const SEED := 20261001

## The fall line, top to bottom: `[metres down where it starts, degrees]`,
## each held to the next, eased over [constant SECTION_EASE] either side.
## Chutes of 24–31° and benches of 12–14°. A bench is under the angle at which
## snow's friction holds a racer ([constant TerrainLayer.friction] 0.35 is
## 19.3°), so it bleeds speed — short enough that a racer off the chute above
## carries across it. The top is steep enough to start from a standstill.
const SECTIONS: Array[Vector2] = [
	Vector2(0.0, 21.0), Vector2(70.0, 27.0), Vector2(210.0, 13.0),
	Vector2(300.0, 31.0), Vector2(400.0, 13.0), Vector2(480.0, 25.0),
	Vector2(650.0, 12.0), Vector2(740.0, 29.0), Vector2(850.0, 14.0),
	Vector2(950.0, 26.0), Vector2(1100.0, 12.0), Vector2(1180.0, 30.0),
	Vector2(1330.0, 16.0),
]
const SECTION_EASE := 14.0

## Metres down where a trunk lies lodged across the gully, which narrows round
## it to a slot. Twice: a third already read as a pattern.
const LOGS: Array[float] = [560.0, 1140.0]
## How far the slot reaches either side of a lodged trunk.
const PINCH_REACH := 22.0
## The trail's half-width in the slot.
const PINCH_HALF_WIDTH := 2.5
## How high a trunk's axis rests over the trail's floor at its lower bank, and
## how much higher the other bank may hold it. Clear of the chase camera,
## which rides [member ChaseCamera.height] 1.4 m over the racer and dips no
## lower than [constant ChaseCamera.MIN_CAMERA_HEIGHT] 1.5 m above the ground.
const LOG_REST_HEIGHT := 3.6
const LOG_LEAN := 1.0
## How far each end of a lodged trunk is sunk into its bank.
const LOG_BURIED := 1.8

## `[distance down, 0]` of each kicker: on a bench, just before the drop into
## the chute below it, so the landing is downhill.
const KICKERS: Array[float] = [462.0, 935.0]
## Bumps across the trail, lower and shorter than a kicker: a hop, not a
## flight. Each `[distance down, height]`; none within 30 m before an
## obstacle, so no landing is on one, and none on a lip, where the change of
## gradient would throw a racer higher than the bump.
const BUMPS: Array[Vector2] = [Vector2(150.0, 0.7), Vector2(270.0, 0.6),
	Vector2(345.0, 0.8), Vector2(620.0, 0.7), Vector2(700.0, 0.6), Vector2(810.0, 0.8),
	Vector2(1040.0, 0.7), Vector2(1300.0, 0.8)]
## Where down the trail a boulder lies on it. All obstacles stand where the
## trail runs nearly straight from 40 m before to 30 m after, so there is a
## line round them — on a bend a racer arrives on the outside and has none —
## and in a chute, never at its foot: a racer who hits one there crawls across
## the bench below, which is too flat to give the speed back. Which side it
## lies on is [method open_side]'s business.
const TRAIL_BOULDERS: Array[float] = [105.0, 590.0, 1030.0]
## Where a trunk has fallen from a bank onto the trail. Each stops a little
## short of the middle, leaving the other half open.
const FALLEN_TRUNKS: Array[float] = [330.0, 550.0, 775.0, 1235.0]
## How far past the trail's middle a fallen trunk reaches, in half-widths:
## negative stops short of it.
const FALLEN_REACH := -0.3
## How much wider (each side) the trail runs past a boulder or a fallen trunk,
## so there is a line round it: the computer picks among nine lines and found
## none in a 2.5 m gap.
const OBSTACLE_ROOM := 1.2
## Where down the course a pile of stones stands beside the trail, halfway
## down: a mound of boulders, the upper ones resting on the lower, off the play
## area. The first place from here on where the pile's foot is clear of a
## torch and of a wall's ice.
const STONE_PILE := 705.0
## The pile's radius at its foot.
const STONE_PILE_RADIUS := 2.2
## The obstacle types drawn with another type's prefab.
const PREFAB_OF: Dictionary[String, String] = {
	"trail_boulder": "boulder", "fallen_trunk": "lodged_log", "stone_pile": "boulder",
}
const STRAIGHT_START := 60.0
const STRAIGHT_END := 110.0

## How much stands on the course — see `gen_forest_trail.gd`. The walls close
## the view in, so the forest is thinner than Forest Trail's and stands where
## it is seen: on the lower walls and along the trail.
const WALL_FOREST_DENSITY := 0.75
const TREE_LINE_DENSITY := 0.55
const SHRUB_DENSITY := 0.6
const BOULDER_DENSITY := 1.0
const STONES_DENSITY := 1.5
const STUMP_DENSITY := 1.0
const LOG_DENSITY := 1.0

## Terrain layers, in splat order; the index is the channel.
const LAYERS: Array[String] = ["snow", "icy_forest_floor", "ice1", "thin_snow",
	"conifer_needles", "dirt", "snowy_rock06", "rock06"]
const L_SNOW := 0
const L_EDGE := 1
const L_ICE := 2
const L_FOREST_SNOW := 3
const L_NEEDLES := 4
const L_DIRT := 5
const L_SNOWY_ROCK := 6
const L_ROCK := 7
## How much of the walls (everything off the trail and its edge) is bare or
## snowed-on rock, and how much is ice. Each comes in a few long stretches of
## one wall, trail to ridge, not scattered about; no tree stands on them. The
## rest is earth and forest floor. Shares, not thresholds: [method
## _wall_thresholds] turns them into cut-offs on the scores below, so they
## hold whatever the noise does. Bare rock is a stretch's core, snowed-on rock
## its fringe.
const WALL_ROCK_SHARE := 0.10
const WALL_BARE_ROCK_SHARE := 0.04
const WALL_ICE_SHARE := 0.05
## Rock faces laid over the walls ([CliffBuilder]), as (from, to, side):
## metres down, and the wall, +1 the +X one. Where a stretch of wall is rock
## the heightmap draws it as a smooth sheet; a face stands real beds, ledges
## and joints out of it. One so far — the long stretch on the right bank by the
## first bumps, in view as the trail bends toward it.
const CLIFFS: Array[Vector3] = [Vector3(140.0, 198.0, 1.0)]
## Metres past the trail's edge where a face's rows start, where it starts to
## come up out of the wall, and how far across X it runs. The play area
## reaches [constant CORRIDOR_MARGIN] up the bank, so the rock — which leans
## out toward the trail by up to a metre and a half — stays clear of anything
## that races.
const CLIFF_FOOT := 1.3
const CLIFF_RISE := 2.2
const CLIFF_REACH := 30.0
const NEEDLES_LAYER := "res://courses/mountain_forest/conifer_needles.tres"
const NEEDLES_TEXTURE := "res://courses/mountain_forest/conifer_needles.png"
const NEEDLES_SIZE := 512

## The sky: a near range, twice the usual height, wooded almost to the crests
## ([member CourseData.backdrop_height] and the rest).
const BACKDROP_HEIGHT := 2.3
const BACKDROP_FOREST := 1.0
const BACKDROP_NEAR := 1.0

var _w: int
var _h: int
var _relief_noise := FastNoiseLite.new()
var _fine_noise := FastNoiseLite.new()
var _edge_noise := FastNoiseLite.new()
var _patch_noise := FastNoiseLite.new()
var _density_noise := FastNoiseLite.new()
var _wall_noise := FastNoiseLite.new()
var _crag_noise := FastNoiseLite.new()
var _seep_noise := FastNoiseLite.new()
var _outcrop_noise := FastNoiseLite.new()
## The cut-offs on [method _rock_score] and [method _ice_score] that give the
## walls their shares; see [method _wall_thresholds].
var _rock_cut: float = INF
var _bare_rock_cut: float = INF
var _ice_cut: float = INF
## One per ice patch: `{d, u (offset in half-widths), a, b (half-axes)}`.
var _ice: Array[Dictionary] = []
## [method _profile] at every metre down the course, and the slope it is
## measured from.
var _profile_m := PackedFloat32Array()
var _base_tan: float = 0.0
## [method gradient] down each heightmap row, for [method _steepness].
var _row_gradient := PackedFloat32Array()

func _initialize() -> void:
	var stage: String = "assets"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--stage="):
			stage = a.trim_prefix("--stage=")
	_w = int(round(WORLD.x / CELL)) + 1
	_h = int(round(WORLD.y / CELL)) + 1
	_setup_noise()
	_build_profile()
	_plan_ice()
	_wall_thresholds()
	DirAccess.make_dir_recursive_absolute(OUT)
	var start: int = Time.get_ticks_msec()
	if stage == "assets":
		_write_assets()
	elif stage == "resources":
		_write_resources()
	else:
		printerr("unknown stage '%s' (assets | resources)" % stage)
		quit(2)
		return
	print("mountain_forest: stage '%s' done in %.1f s"
		% [stage, float(Time.get_ticks_msec() - start) / 1000.0])
	quit(0)

func _setup_noise() -> void:
	var all: Array[FastNoiseLite] = [_relief_noise, _fine_noise, _edge_noise, _patch_noise,
		_density_noise, _wall_noise, _crag_noise, _seep_noise, _outcrop_noise]
	for i: int in all.size():
		all[i].seed = SEED + i
		all[i].noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_relief_noise.frequency = 1.0 / 30.0
	_relief_noise.fractal_octaves = 3
	_fine_noise.frequency = 1.0 / 5.0
	_fine_noise.fractal_octaves = 2
	_edge_noise.frequency = 1.0 / 8.0
	_edge_noise.fractal_octaves = 2
	_patch_noise.frequency = 1.0 / 12.0
	_density_noise.frequency = 1.0 / 40.0
	# How high and how steep each wall is, along the course: slow.
	_wall_noise.frequency = 1.0 / 160.0
	_wall_noise.fractal_octaves = 2
	# Ridged crags on the walls.
	_crag_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_crag_noise.frequency = 1.0 / 14.0
	_crag_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_crag_noise.fractal_octaves = 3
	# Where a wall is rock, or ice, all the way up: slow, along the course and
	# per side (see _rock_score).
	_outcrop_noise.frequency = 1.0 / 45.0
	_outcrop_noise.fractal_octaves = 1
	_seep_noise.frequency = 1.0 / 35.0
	_seep_noise.fractal_octaves = 1

# ================================================================ the fall line

## The gradient at [param d] metres down, as a tangent, before easing.
static func _section_tan(d: float) -> float:
	var deg: float = SECTIONS[0].y
	for s: Vector2 in SECTIONS:
		if d >= s.x:
			deg = s.y
	return tan(deg_to_rad(deg))

## The eased gradient: [method _section_tan] averaged over [constant
## SECTION_EASE] either side, so a lip rounds over rather than launching.
static func gradient(d: float) -> float:
	var sum: float = 0.0
	var n: int = 0
	var s: float = -SECTION_EASE
	while s <= SECTION_EASE:
		sum += _section_tan(d + s)
		n += 1
		s += 1.0
	return sum / n

## The mean gradient over the whole grid, as an angle: the course's
## [member CourseData.base_angle].
static func base_angle() -> float:
	var sum: float = 0.0
	var n: int = int(WORLD.y)
	for i: int in n:
		sum += gradient(float(i) + 0.5)
	return rad_to_deg(atan(sum / n))

## Integrate the steps: how far above the analytic base slope the fall line is
## at each metre down.
func _build_profile() -> void:
	_base_tan = tan(deg_to_rad(base_angle()))
	var n: int = int(WORLD.y) + 2
	_profile_m.resize(n)
	var p: float = 0.0
	_profile_m[0] = 0.0
	for i: int in range(1, n):
		p -= gradient(float(i) - 0.5) - _base_tan
		_profile_m[i] = p
	# Centred, so the relief is as near zero as it can be.
	var mean: float = 0.0
	for i: int in n:
		mean += _profile_m[i]
	mean /= n
	for i: int in n:
		_profile_m[i] -= mean

## [member _profile_m] at [param d], interpolated.
func _profile(d: float) -> float:
	var f: float = clampf(d, 0.0, float(_profile_m.size() - 1) - 0.001)
	var i: int = int(f)
	return lerpf(_profile_m[i], _profile_m[i + 1], f - i)

# ================================================================ the trail

## Centre line x at [param d] metres down.
static func centre_x(d: float) -> float:
	var amp: float = smoothstep(15.0, STRAIGHT_START, d) \
		* (1.0 - smoothstep(PLAY.y - STRAIGHT_END + 40.0, PLAY.y - 20.0, d))
	return WORLD.x * 0.5 + amp * (
		12.0 * sin(TAU * d / 330.0 + 0.4)
		+ 5.0 * sin(TAU * d / 140.0 + 1.9)
		+ 1.5 * sin(TAU * d / 63.0 + 0.2))

## How far into the slot round a lodged trunk [param d] is, 0 outside it, 1 at
## the trunk.
static func pinch(d: float) -> float:
	var p: float = 0.0
	for l: float in LOGS:
		p = maxf(p, 1.0 - smoothstep(4.0, PINCH_REACH, absf(d - l)))
	return p

## How near [param d] is to a boulder or fallen trunk on the trail: 1 beside
## it, 0 more than 25 m off.
static func obstacle_room(d: float) -> float:
	var r: float = 0.0
	for v: Array[float] in [TRAIL_BOULDERS, FALLEN_TRUNKS]:
		for o: float in v:
			r = maxf(r, 1.0 - smoothstep(6.0, 25.0, absf(d - o)))
	return r

## Which half of the trail an obstacle at [param d] leaves open, −1 left or 1
## right: the one the trail turns toward over the next 30 m. The computer
## aims a straight line 30 m ahead, and with the open half on the outside of
## the next bend its only lines round the obstacle left the play area — it
## drove into the trunk instead. A player would have been as badly served.
static func open_side(d: float) -> float:
	return 1.0 if centre_x(d + 30.0) >= centre_x(d) else -1.0

## Half the trail's width, square to it: 5–8 m wide, a slot of 5 m at the
## overhead trunks, about 2 m wider beside an obstacle, wide at the gates.
static func half_width(d: float) -> float:
	var w: float = 3.4 + 0.6 * sin(TAU * d / 210.0 + 1.1) + 0.35 * sin(TAU * d / 77.0)
	w = lerpf(w, PINCH_HALF_WIDTH, pinch(d))
	w += OBSTACLE_ROOM * obstacle_room(d)
	var ends: float = maxf(1.0 - smoothstep(25.0, 60.0, d),
		smoothstep(PLAY.y - 60.0, PLAY.y - 20.0, d))
	return lerpf(w, 9.0, ends)

## Half the width across X, the same to a racer on a bend.
static func lateral_half_width(d: float) -> float:
	var slope: float = centre_x(d + 0.5) - centre_x(d - 0.5)
	return half_width(d) * sqrt(1.0 + slope * slope)

## How far outside the trail's edge (x, z) is, across X: negative on it.
static func beyond_edge(x: float, z: float) -> float:
	var d: float = -z
	return absf(x - centre_x(d)) - lateral_half_width(d)

## The kickers and bumps at [param d]: a kicker a ramp up over 12 m to 1.2 m,
## a lip, a drop over 4 m; a bump the same over 7 m and 3 m.
static func _kicker(d: float) -> float:
	var h: float = 0.0
	for k: float in KICKERS:
		h = maxf(h, _ramp(d - k, 12.0, 4.0) * 1.2)
	for b: Vector2 in BUMPS:
		h = maxf(h, _ramp(d - b.x, 7.0, 3.0) * b.y)
	return h

static func _ramp(t: float, up: float, down: float) -> float:
	if t > -up and t < 0.0:
		return smoothstep(-up, 0.0, t)
	if t >= 0.0 and t < down:
		return 1.0 - smoothstep(0.0, down, t)
	return 0.0

## Everything on the trail a racer meets — kickers, bumps, obstacles — as
## distances down, for keeping the ice clear of them.
static func _features() -> Array[float]:
	var out: Array[float] = []
	out.append_array(KICKERS)
	for b: Vector2 in BUMPS:
		out.push_back(b.x)
	out.append_array(TRAIL_BOULDERS)
	out.append_array(FALLEN_TRUNKS)
	return out

## Ice on the chutes, one or two patches each, none by a kicker or a trunk.
func _plan_ice() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 100
	for i: int in SECTIONS.size() - 1:
		var from: float = SECTIONS[i].x
		var to: float = SECTIONS[i + 1].x
		if SECTIONS[i].y < 20.0 or from < 60.0:
			continue
		for k: int in (2 if to - from > 130.0 else 1):
			# A few tries each: the chutes are busy.
			for attempt: int in 8:
				var d: float = lerpf(from + 25.0, to - 25.0, rng.randf())
				var near_ice: bool = false
				for spot: Dictionary in _ice:
					near_ice = near_ice or absf(float(spot["d"]) - d) < 30.0
				if near_ice or pinch(d) > 0.0 or absf(_nearest(_features(), d) - d) < 30.0:
					continue
				_ice.push_back({"d": d, "u": rng.randf_range(-0.35, 0.35),
					"a": rng.randf_range(5.0, 9.0), "b": rng.randf_range(1.6, 2.6)})
				break

static func _nearest(list: Array[float], d: float) -> float:
	var best: float = INF
	for v: float in list:
		if absf(v - d) < absf(best - d):
			best = v
	return best

## Whether (x, z) is in a patch of ice, with a ragged edge.
func _on_ice(x: float, z: float) -> bool:
	var d: float = -z
	for spot: Dictionary in _ice:
		var sd: float = spot["d"]
		if absf(d - sd) > float(spot["a"]) + 2.0:
			continue
		var cx: float = centre_x(sd) + float(spot["u"]) * lateral_half_width(sd)
		var heading: float = centre_x(sd + 0.5) - centre_x(sd - 0.5)
		var along: Vector2 = Vector2(heading, 1.0).normalized()
		var off := Vector2(x - cx, d - sd)
		var ea: float = off.dot(along) / float(spot["a"])
		var eb: float = off.dot(Vector2(along.y, -along.x)) / float(spot["b"])
		if ea * ea + eb * eb + _edge_noise.get_noise_2d(x, z) * 0.35 < 1.0:
			return true
	return false

# ================================================================ the ground

## The walls' relief at (x, z), without the fall line's steps: a shallow
## trough for the trail, and either side a bank that climbs steeply off a
## narrow shoulder and levels off toward the ridge, rough with crags. How high
## and how steep drifts along the course, independently on each side; round
## a lodged trunk the walls stand higher and steeper, a slot.
func _walls(x: float, z: float) -> float:
	var d: float = -z
	var cx: float = centre_x(d)
	var hl: float = lateral_half_width(d)
	var across: float = absf(x - cx)
	var e: float = across / hl
	var beyond: float = across - hl
	var side: float = signf(x - cx)
	var h: float = -0.6 * (1.0 - smoothstep(0.6, 1.7, e))
	var on_trail: float = 1.0 - smoothstep(0.8, 1.5, e)
	var slot: float = pinch(d)
	# Height 14–30 m, reached over a 14–22 m length scale; the slot's walls
	# higher and nearly twice as steep.
	var wn: float = _wall_noise.get_noise_2d(d, side * 400.0)
	var height: float = lerpf(22.0, 30.0, slot) + 8.0 * wn
	var reach: float = lerpf(18.0 - 4.0 * wn, 10.0, slot)
	var b: float = maxf(beyond - 0.8, 0.0)
	h += clampf(beyond, 0.0, 0.8) * 0.3
	h += height * (1.0 - exp(-b / reach))
	# Crags: ridged noise, only up the wall, strongest on its steep middle.
	var up: float = smoothstep(1.0, 6.0, b)
	h += _crag_noise.get_noise_2d(x, z) * 3.0 * up * (1.0 - 0.5 * smoothstep(20.0, 40.0, b))
	h += _relief_noise.get_noise_2d(x, z) * 1.6 * lerpf(1.0, 0.2, on_trail)
	h += _fine_noise.get_noise_2d(x, z) * 0.3 * (1.0 - on_trail)
	h += _kicker(d) * on_trail
	return h

## The ground's world height at (x, z): the walls, the fall line's steps and
## the analytic slope — what [HeightmapSurface.height_at] will answer.
func _ground(x: float, z: float) -> float:
	return _walls(x, z) + _profile(-z) + _base_tan * z

# ================================================================ the rock faces

## How much a rock face stands out at (x, z), 0..1: on a [constant CLIFFS]
## stretch's wall, where the wall is rock, coming up from [constant
## CLIFF_RISE] past the trail's edge and going back under short of the far
## end of its rows.
func _cliff_mask(x: float, z: float) -> float:
	var d: float = -z
	var best: float = 0.0
	for c: Vector3 in CLIFFS:
		if d < c.x or d > c.y or signf(x - centre_x(d)) != c.z:
			continue
		var beyond: float = beyond_edge(x, z)
		var foot: float = smoothstep(CLIFF_RISE, CLIFF_RISE + 2.5, beyond)
		var top: float = 1.0 - smoothstep(CLIFF_REACH - 6.0, CLIFF_REACH - 1.0, beyond)
		var rock: float = smoothstep(_rock_cut - 0.02, _rock_cut + 0.08, _rock_score(x, z))
		best = maxf(best, foot * top * rock)
	return best

## Whether a footprint of radius [param r] at (x, z) is on a rock face, which
## would stand through anything placed there.
func _on_cliff(x: float, z: float, r: float) -> bool:
	for o: Vector2 in [Vector2.ZERO, Vector2(r, 0.0), Vector2(-r, 0.0), Vector2(0.0, r),
			Vector2(0.0, -r)]:
		if _cliff_mask(x + o.x, z + o.y) > 0.0:
			return true
	return false

## Lay the [constant CLIFFS] faces and save them as the course's [CliffSet].
## [param heights] is the heightmap's relief, for how far the rock stands over
## it.
func _write_cliffs(heights: PackedFloat32Array) -> void:
	var cliffs := CliffSet.new()
	cliffs.grid_size = Vector2i(_w, _h)
	cliffs.world_size = WORLD
	var lift: Dictionary = {}
	var grid_height := func(gx: int, gz: int) -> float:
		gx = clampi(gx, 0, _w - 1)
		gz = clampi(gz, 0, _h - 1)
		return heights[gz * _w + gx] - _base_tan * float(gz) * CELL
	var vertices: int = 0
	for i: int in CLIFFS.size():
		var c: Vector3 = CLIFFS[i]
		var builder := CliffBuilder.new(SEED + 500 + 10 * i)
		builder.ground = _ground
		builder.mask = _cliff_mask
		builder.floor_y = func(d: float) -> float:
			return _profile(d) - _base_tan * d - 0.6
		builder.foot_x = func(d: float) -> float:
			return centre_x(d) + c.z * (lateral_half_width(d) + CLIFF_FOOT)
		builder.side = c.z
		builder.reach = CLIFF_REACH
		builder.x_limits = Vector2(0.5, WORLD.x - 0.5)
		for mesh: ArrayMesh in builder.build(c.x, c.y, grid_height, CELL, lift):
			cliffs.meshes.push_back(mesh)
			vertices += mesh.surface_get_array_len(0)
	var keys: Array = lift.keys()
	keys.sort()
	for key: Vector2i in keys:
		cliffs.lift_index.push_back(key.y * _w + key.x)
		cliffs.lift.push_back(lift[key])
	ResourceSaver.save(cliffs, OUT.path_join("cliffs.res"), ResourceSaver.FLAG_COMPRESS)
	print("  cliffs: %d faces, %d meshes, %d vertices, lift over %d grid vertices"
		% [CLIFFS.size(), cliffs.meshes.size(), vertices, keys.size()])

# ================================================================ assets

func _write_assets() -> void:
	var heights := PackedFloat32Array()
	heights.resize(_w * _h)
	var walls := PackedFloat32Array()
	walls.resize(_w * _h)
	var trail_e := PackedFloat32Array()
	trail_e.resize(_w * _h)
	for gy: int in _h:
		var z: float = -float(gy) * CELL
		var d: float = -z
		var cx: float = centre_x(d)
		var hl: float = lateral_half_width(d)
		var step: float = _profile(d)
		for gx: int in _w:
			var x: float = float(gx) * CELL
			var wall: float = _walls(x, z)
			walls[gy * _w + gx] = wall
			heights[gy * _w + gx] = wall + step
			trail_e[gy * _w + gx] = absf(x - cx) / hl

	var himg: Image = ETRImport.heights_to_image(heights, _w, _h)
	ResourceSaver.save(himg, OUT.path_join("heightmap.res"))
	# From the walls alone — see the notes at the top.
	var ao: Image = TerrainOcclusion.bake(walls, _w, _h, WORLD, 2)
	ResourceSaver.save(ao, OUT.path_join("ambient_occlusion.res"), ResourceSaver.FLAG_COMPRESS)
	_write_cliffs(heights)

	_row_gradient.resize(_h)
	for gy: int in _h:
		_row_gradient[gy] = gradient(float(gy) * CELL)
	var canopy := _Canopy.new(_place_objects(_course_shape()))
	var index := PackedByteArray()
	index.resize(_w * _h)
	var wall_cells: int = 0
	var wall_share := PackedInt32Array()
	wall_share.resize(LAYERS.size())
	for gy: int in _h:
		var z: float = -float(gy) * CELL
		for gx: int in _w:
			var x: float = float(gx) * CELL
			var i: int = gy * _w + gx
			index[i] = _material(x, z, trail_e[i], _steepness(heights, gx, gy), canopy)
			if _on_wall(x, z, trail_e[i]):
				wall_cells += 1
				wall_share[index[i]] += 1

	var share := PackedInt32Array()
	share.resize(LAYERS.size())
	for i: int in index.size():
		share[index[i]] += 1
	for l: int in LAYERS.size():
		print("  %s: %.1f %% (walls %.1f %%)" % [LAYERS[l], 100.0 * share[l] / index.size(),
			100.0 * wall_share[l] / maxi(wall_cells, 1)])
	var maps: Array[Image] = CourseGenKit.splat_maps(index, _w, _h, LAYERS.size())
	for m: int in maps.size():
		var path: String = OUT.path_join("splat_%d.png" % m)
		maps[m].save_png(ProjectSettings.globalize_path(path))
		ETRImport.write_splat_import(path)
	CourseGenKit.needle_texture(NEEDLES_SIZE, SEED + 300).save_png(
		ProjectSettings.globalize_path(NEEDLES_TEXTURE))
	var preview: String = ProjectSettings.globalize_path(OUT.path_join("preview.png"))
	if not FileAccess.file_exists(preview):
		_preview(index).save_png(preview)
	_write_lodged_log_prefab()
	var lo: float = INF
	var hi: float = -INF
	for v: float in heights:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	print("  heightmap %dx%d, relief %.1f..%.1f m, base angle %.2f°, %d ice patches"
		% [_w, _h, lo, hi, base_angle(), _ice.size()])

## How steep the ground is across the walls at a vertex, as a tangent: the
## gradient across X (the course's own fall line is the trail's business, not
## the rock's).
func _steepness(heights: PackedFloat32Array, gx: int, gy: int) -> float:
	var x0: int = maxi(gx - 1, 0)
	var x1: int = mini(gx + 1, _w - 1)
	var y0: int = maxi(gy - 1, 0)
	var y1: int = mini(gy + 1, _h - 1)
	var dx: float = (heights[gy * _w + x1] - heights[gy * _w + x0]) / (float(x1 - x0) * CELL)
	var dz: float = (heights[y1 * _w + gx] - heights[y0 * _w + gx]) / (float(y1 - y0) * CELL)
	# The steps along the course are gentle beside the walls; take them out so a
	# chute's floor is not painted as rock.
	var along: float = _row_gradient[gy] - _base_tan
	return Vector2(dx, dz + along).length()

## Whether (x, z) is up a wall: past the trail's edge litter in [method _material].
func _on_wall(x: float, z: float, e: float) -> bool:
	return e + _edge_noise.get_noise_2d(x, z) * 0.18 >= 1.05

## How rocky a wall is at (x, z): a slow noise down the course, one per side,
## so that where it is high the whole wall is rock from the trail's edge to the
## ridge; the crags and a finer noise only rag its edges.
func _rock_score(x: float, z: float) -> float:
	var d: float = -z
	var side: float = signf(x - centre_x(d))
	return _outcrop_noise.get_noise_2d(d, side * 400.0) \
		+ 0.08 * _crag_noise.get_noise_2d(x, z) + 0.06 * _edge_noise.get_noise_2d(x, z)

## How icy a wall is at (x, z): [method _rock_score]'s shape, its own noise.
func _ice_score(x: float, z: float) -> float:
	var d: float = -z
	var side: float = signf(x - centre_x(d))
	return _seep_noise.get_noise_2d(d, side * 400.0) \
		+ 0.08 * _crag_noise.get_noise_2d(x, z) + 0.06 * _edge_noise.get_noise_2d(x, z)

## Whether (x, z) is up a wall and in a stretch of rock or ice, where no tree
## is planted.
func _bare_wall(x: float, z: float) -> bool:
	var d: float = -z
	if not _on_wall(x, z, absf(x - centre_x(d)) / lateral_half_width(d)):
		return false
	return _rock_score(x, z) >= _rock_cut or _ice_score(x, z) >= _ice_cut

## Whether a footprint of radius [param r] at (x, z) touches a wall's ice
## ([method _material]'s test): nothing stands on it — no tree, bush, stone or
## log — so it reads as a sheet of ice.
func _on_wall_ice(x: float, z: float, r: float) -> bool:
	for o: Vector2 in [Vector2.ZERO, Vector2(r, 0.0), Vector2(-r, 0.0), Vector2(0.0, r),
			Vector2(0.0, -r)]:
		var px: float = x + o.x
		var pz: float = z + o.y
		var d: float = -pz
		if _on_wall(px, pz, absf(px - centre_x(d)) / lateral_half_width(d)) \
				and _rock_score(px, pz) < _rock_cut and _ice_score(px, pz) >= _ice_cut:
			return true
	return false

## Sets [member _rock_cut], [member _bare_rock_cut] and [member _ice_cut] so
## that [constant WALL_ROCK_SHARE], [constant WALL_BARE_ROCK_SHARE] and
## [constant WALL_ICE_SHARE] of the wall cells come out rock, bare rock and
## ice; the ice from what the rock leaves. Both stages need them — the trees
## keep off both — so it reads only the course's shape, not the heightmap.
func _wall_thresholds() -> void:
	var rock := PackedFloat32Array()
	var ice := PackedFloat32Array()
	for gy: int in _h:
		var z: float = -float(gy) * CELL
		var d: float = -z
		var cx: float = centre_x(d)
		var hl: float = lateral_half_width(d)
		for gx: int in _w:
			var x: float = float(gx) * CELL
			if _on_wall(x, z, absf(x - cx) / hl):
				rock.push_back(_rock_score(x, z))
				ice.push_back(_ice_score(x, z))
	var n: int = rock.size()
	var sorted: PackedFloat32Array = rock.duplicate()
	sorted.sort()
	_rock_cut = sorted[clampi(int(n * (1.0 - WALL_ROCK_SHARE)), 0, n - 1)]
	_bare_rock_cut = sorted[clampi(int(n * (1.0 - WALL_BARE_ROCK_SHARE)), 0, n - 1)]
	var left := PackedFloat32Array()
	for k: int in n:
		if rock[k] < _rock_cut:
			left.push_back(ice[k])
	left.sort()
	var m: int = left.size()
	_ice_cut = left[clampi(m - int(n * WALL_ICE_SHARE), 0, m - 1)]

## Which terrain (x, z) is: snow on the trail, snow-dusted litter at its edge,
## ice in the patches; up the walls a few long stretches of rock — bare at
## their core, snowed on at the fringe — and of ice ([constant
## WALL_ROCK_SHARE], [constant WALL_ICE_SHARE]); elsewhere bare earth with
## snow lying in patches where the bank is too steep for a forest floor, and elsewhere the forest floor, needles
## under the crowns and snow in the gaps.
func _material(x: float, z: float, e: float, steep: float, canopy: _Canopy) -> int:
	var edge: float = e + _edge_noise.get_noise_2d(x, z) * 0.18
	if edge < 0.8 and _on_ice(x, z):
		return L_ICE
	if edge < 0.9:
		return L_SNOW
	if edge < 1.05:
		return L_EDGE
	var rock: float = _rock_score(x, z)
	if rock >= _bare_rock_cut:
		return L_ROCK
	if rock >= _rock_cut:
		return L_SNOWY_ROCK
	if _ice_score(x, z) >= _ice_cut:
		return L_ICE
	var patch: float = _patch_noise.get_noise_2d(x * 1.3, z * 1.3)
	if steep > 0.9:
		if patch > 0.25:
			return L_FOREST_SNOW
		return L_DIRT if patch < -0.1 else L_EDGE
	var cover: float = canopy.at(x, z) + _patch_noise.get_noise_2d(x, z) * 0.3
	if cover < 0.12:
		return L_FOREST_SNOW
	if cover < 0.32:
		return L_EDGE
	return L_DIRT if _patch_noise.get_noise_2d(x * 1.7, z * 1.7) < -0.4 else L_NEEDLES

## How much sky the crowns take over each metre — Forest Trail's, over this
## course's extent.
class _Canopy:
	const STEP := 1.0
	var _gw: int
	var _gh: int
	var _cover := PackedFloat32Array()

	func _init(objects: Dictionary) -> void:
		_gw = int(WORLD.x / STEP) + 1
		_gh = int(WORLD.y / STEP) + 1
		_cover.resize(_gw * _gh)
		_cover.fill(0.0)
		for o: Array in objects["tree"]:
			var s: Vector3 = o[2]
			_disc(o[0], o[1], s.x * 0.85, 1.0)
		for o: Array in objects["shrub"]:
			var s: Vector3 = o[2]
			_disc(o[0], o[1], s.x * 0.7, 0.6)

	func _disc(x: float, z: float, r: float, weight: float) -> void:
		var cx: int = roundi(x / STEP)
		var cz: int = roundi(-z / STEP)
		var n: int = ceili(r / STEP)
		for gz: int in range(maxi(cz - n, 0), mini(cz + n, _gh - 1) + 1):
			for gx: int in range(maxi(cx - n, 0), mini(cx + n, _gw - 1) + 1):
				var q: float = Vector2(gx * STEP - x, -gz * STEP - z).length() / r
				if q < 1.0:
					_cover[gz * _gw + gx] += weight * (1.0 - q * q)

	func at(x: float, z: float) -> float:
		var gx: int = clampi(roundi(x / STEP), 0, _gw - 1)
		var gz: int = clampi(roundi(-z / STEP), 0, _gh - 1)
		return _cover[gz * _gw + gx]

## A map of the course for the menu until a real capture replaces it, turned
## to run left to right: the trail white, ice blue, rock grey, forest dark.
func _preview(index: PackedByteArray) -> Image:
	var colours: Array[Color] = [Color(0.93, 0.95, 1.0), Color(0.62, 0.6, 0.55),
		Color(0.55, 0.75, 0.95), Color(0.85, 0.87, 0.9), Color(0.25, 0.18, 0.12),
		Color(0.2, 0.16, 0.1), Color(0.6, 0.6, 0.62), Color(0.4, 0.4, 0.42)]
	var img := Image.create_empty(PREVIEW_SIZE.x, PREVIEW_SIZE.y, false, Image.FORMAT_RGB8)
	for py: int in PREVIEW_SIZE.y:
		for px: int in PREVIEW_SIZE.x:
			var gy: int = clampi(int(float(px) / PREVIEW_SIZE.x * _h), 0, _h - 1)
			var gx: int = clampi(int(float(py) / PREVIEW_SIZE.y * _w), 0, _w - 1)
			img.set_pixel(px, py, colours[index[gy * _w + gx]])
	return img

## The lodged trunk: a [constant PropMesh.Kind.TRUNK], level, decorative; and
## the fallen trunk's collider, which has no mesh. Overwritten each run like the
## other props.
func _write_lodged_log_prefab() -> void:
	var prefab := ObjectPrefab.new()
	prefab.id = &"lodged_log"
	prefab.mesh = PropMesh.build(PropMesh.Kind.TRUNK, 53)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/object_prop.gdshader")
	prefab.material = mat
	prefab.collidable = false
	prefab.decorative = true
	prefab.ground_aligned = false
	ResourceSaver.save(prefab, "res://resources/objects/lodged_log.tres")
	# Nothing to draw, only something to hit: a fallen trunk's collision.
	var collider := ObjectPrefab.new()
	collider.id = &"trunk_collider"
	collider.collidable = true
	ResourceSaver.save(collider, "res://resources/objects/trunk_collider.tres")

# ================================================================ resources

func _write_resources() -> void:
	var course: CourseData = _course_shape()
	course.display_name = DISPLAY_NAME
	course.author = AUTHOR
	course.description = DESCRIPTION
	course.height_scale = 6.0
	course.heightmap_size = Vector2i(_w, _h)
	course.heightmap = load(OUT.path_join("heightmap.res"))
	course.ambient_occlusion = load(OUT.path_join("ambient_occlusion.res"))
	course.preview = load(OUT.path_join("preview.png"))
	ResourceSaver.save(CourseGenKit.needles_layer(load(NEEDLES_TEXTURE)), NEEDLES_LAYER)
	var layers: Array[TerrainLayer] = []
	for id: String in LAYERS:
		layers.push_back(load(NEEDLES_LAYER) if id == "conifer_needles"
			else load("res://resources/terrain/%s.tres" % id))
	course.terrain_layers = layers
	var splats: Array[Texture2D] = []
	for m: int in 2:
		splats.push_back(load(OUT.path_join("splat_%d.png" % m)))
	course.splat_maps = splats
	course.splat_size = Vector2i(_w, _h)
	course.cliffs = load(OUT.path_join("cliffs.res"))
	course.start_position = Vector2(centre_x(3.5), 3.5)
	course.finish_line_z = -PLAY.y
	course.environment_preset = load("res://resources/environments/etr_sunny.tres")
	course.music_theme = &"normal"
	course.finish_brake = 20.0
	course.use_keyframe = true
	course.backdrop_height = BACKDROP_HEIGHT
	course.backdrop_forest = BACKDROP_FOREST
	course.backdrop_near = BACKDROP_NEAR
	course.imported_from = ""
	ResourceSaver.save(course, OUT.path_join("course.tres"))

	var objects: Dictionary[String, Array] = _place_objects(course)
	CourseGenKit.write_scene(DIR, OUT, objects, PREFAB_OF)
	CourseGenKit.write_listing(DIR, OUT, course)

func _course_shape() -> CourseData:
	var course := CourseData.new()
	course.world_size = WORLD
	course.play_size = PLAY
	course.base_angle = base_angle()
	course.play_bounds = _corridor()
	return course

## How far up the walls the play area reaches either side of the trail: a
## metre, the foot of the bank. Any more and the computer, which plans inside
## it and reads no slope, carved up the walls on every bend and stalled on the
## rock.
const CORRIDOR_MARGIN := 1.0
const CORRIDOR_STEP := 24.0
## How far off the trail's edge anything collidable keeps its whole collision
## cylinder — a conifer's is as wide as its crown: out of the play area, and
## the slack a 24 m corridor piece cuts across a bend. With the tree line's
## cylinders reaching the edge, the computer, hugging a wall into the slot,
## hit a trunk it could not see at 84 km/h.
const PLAY_CLEARANCE := CORRIDOR_MARGIN + 0.8

## The play area: the trail and [constant CORRIDOR_MARGIN] of each bank.
func _corridor() -> PackedVector2Array:
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var d: float = -1.0
	var last: float = WORLD.y - 1.0
	while true:
		var at: float = maxf(d, 0.0)
		# The narrowest the trail gets within a piece either side: a straight
		# piece spans a slot's whole pinch, and one drawn from the width at its
		# ends cut across the slot's wall, which the computer then raced into.
		var narrowest: float = INF
		var k: float = -CORRIDOR_STEP
		while k <= CORRIDOR_STEP:
			narrowest = minf(narrowest, lateral_half_width(maxf(at + k, 0.0)))
			k += 2.0
		var reach: float = narrowest + CORRIDOR_MARGIN
		left.push_back(Vector2(clampf(centre_x(at) - reach, 1.0, WORLD.x - 1.0), -d))
		right.push_back(Vector2(clampf(centre_x(at) + reach, 1.0, WORLD.x - 1.0), -d))
		if d >= last:
			break
		d = minf(d + CORRIDOR_STEP, last)
	right.reverse()
	left.append_array(right)
	return left

const TORCH_CLEARING := 3.5

## Everything that stands on the course, as `{type: [[x, z, scale, yaw], …]}`;
## a lodged trunk's entry goes on with its height above the ground and its
## roll. Trunks and props first, so the trees make room for them.
func _place_objects(course: CourseData) -> Dictionary[String, Array]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 200
	var out: Dictionary[String, Array] = {}
	for t: String in ["start", "finish", "herring", "lodged_log", "trail_boulder",
			"fallen_trunk", "trunk_collider", "stone_pile", "boulder", "stones", "log", "stump", "tree",
			"shrub"]:
		out[t] = []
	var taken := CourseGenKit.Occupancy.new()

	var flat := HeightmapSurface.new()
	var zeros := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	flat.build(zeros, Vector2i(2, 2), WORLD, 0.0)
	for at: Vector3 in CourseLights.torch_positions(course, flat, null, []):
		taken.add(at.x, at.z, TORCH_CLEARING)

	out["start"].push_back([centre_x(10.0), -10.0, Vector3(9.0, 6.0, 9.0), 0.0])
	out["finish"].push_back([centre_x(PLAY.y), -PLAY.y, Vector3(9.0, 6.0, 9.0), 0.0])

	for d: float in LOGS:
		_lodge_log(rng, d, out["lodged_log"], taken)
	for d_b: float in TRAIL_BOULDERS:
		var diam: float = rng.randf_range(1.1, 1.6)
		var x: float = centre_x(d_b) - open_side(d_b) * rng.randf_range(0.4, 0.5) \
			* lateral_half_width(d_b)
		out["trail_boulder"].push_back([x, -d_b,
			Vector3(diam, diam * rng.randf_range(0.6, 0.8), diam), rng.randf() * TAU])
		taken.add(x, -d_b, diam * 0.5)
	for d_f: float in FALLEN_TRUNKS:
		_fell_trunk(rng, d_f, -open_side(d_f), out["fallen_trunk"], out["trunk_collider"],
			taken)
	_pile_stones(rng, out["stone_pile"], out["stones"], taken)

	# Herring in short lines that drift across the trail; one line runs under
	# every trunk, as bait.
	var lines: Array[float] = []
	var d: float = 60.0
	while d < PLAY.y - 40.0:
		lines.push_back(d)
		d += rng.randf_range(80.0, 130.0)
	for l: float in LOGS:
		lines.push_back(l - 10.0)
	for start: float in lines:
		var u0: float = rng.randf_range(-0.4, 0.4)
		var u1: float = clampf(u0 + rng.randf_range(-0.3, 0.3), -0.45, 0.45)
		for i: int in 5:
			var dd: float = start + i * 5.0
			var u: float = lerpf(u0, u1, i / 4.0)
			out["herring"].push_back([centre_x(dd) + u * lateral_half_width(dd), -dd,
				Vector3.ONE, 0.0])

	# Props, at the foot of the walls where they are seen.
	var area: float = WORLD.y * 30.0
	_scatter(rng, out["boulder"], taken, int(area / 300.0 * BOULDER_DENSITY), PLAY_CLEARANCE,
		14.0,
		func() -> Vector3:
			var diam: float = lerpf(1.0, 3.2, pow(rng.randf(), 1.8))
			return Vector3(diam, diam * rng.randf_range(0.55, 0.85), diam))
	_scatter(rng, out["stones"], taken, int(area / 160.0 * STONES_DENSITY), 0.4, 10.0,
		func() -> Vector3:
			var diam: float = rng.randf_range(0.8, 1.9)
			return Vector3(diam, diam * rng.randf_range(0.8, 1.2), diam))
	_scatter(rng, out["stump"], taken, int(area / 500.0 * STUMP_DENSITY), PLAY_CLEARANCE, 20.0,
		func() -> Vector3:
			var diam: float = rng.randf_range(0.5, 0.95)
			return Vector3(diam, diam * rng.randf_range(0.6, 1.0), diam))
	_scatter_logs(rng, out["log"], taken, int(area / 500.0 * LOG_DENSITY))

	# The tree line along both edges, close: the trail runs between trunks.
	d = 15.0
	while TREE_LINE_DENSITY > 0.0 and d < WORLD.y - 5.0:
		for side: float in [-1.0, 1.0]:
			if rng.randf() < 0.25:
				continue
			var height: float = lerpf(7.0, 16.0, pow(rng.randf(), 0.8))
			var diam: float = height * rng.randf_range(0.34, 0.44)
			var x: float = centre_x(d) + side * (lateral_half_width(d) + PLAY_CLEARANCE
				+ diam * 0.5 + rng.randf_range(0.0, 2.0))
			var z: float = -d - rng.randf_range(-1.0, 1.0)
			if x > 1.0 and x < WORLD.x - 1.0 \
					and beyond_edge(x, z) > PLAY_CLEARANCE + diam * 0.5 \
					and not _bare_wall(x, z) \
					and not _on_wall_ice(x, z, diam * 0.3) \
					and taken.is_free(x, z, diam * 0.3):
				out["tree"].push_back([x, z, Vector3(diam, height, diam), 0.0])
				taken.add(x, z, diam * 0.3)
		d += rng.randf_range(3.5, 6.5) / TREE_LINE_DENSITY

	# The walls' forest: a jittered grid, thinning up the wall and missing
	# where it is crag, and in clearings.
	var tree_step: float = 3.7 / sqrt(maxf(WALL_FOREST_DENSITY, 0.01))
	var gz: float = 0.0
	while WALL_FOREST_DENSITY > 0.0 and gz < WORLD.y:
		var gx: float = 0.0
		while gx < WORLD.x:
			var x: float = gx + rng.randf_range(0.1, 0.9) * tree_step
			var z: float = -(gz + rng.randf_range(0.1, 0.9) * tree_step)
			var height: float = lerpf(6.0, 17.0, pow(rng.randf(), 0.8))
			var diam: float = height * rng.randf_range(0.34, 0.44)
			var beyond: float = beyond_edge(x, z)
			var keep: float = 0.55 + _density_noise.get_noise_2d(x, z) \
				- 0.7 * smoothstep(10.0, 30.0, beyond) \
				- 0.8 * maxf(_crag_noise.get_noise_2d(x, z) - 0.4, 0.0)
			if rng.randf() < keep \
					and beyond > PLAY_CLEARANCE + diam * 0.5 \
					and not _bare_wall(x, z) \
					and not _on_wall_ice(x, z, diam * 0.3) \
					and taken.is_free(x, z, diam * 0.3):
				out["tree"].push_back([x, z, Vector3(diam, height, diam), 0.0])
				taken.add(x, z, diam * 0.3)
			gx += tree_step
		gz += tree_step

	var shrub_size := func() -> Vector3:
		var height: float = rng.randf_range(0.8, 2.0)
		var diam: float = height * rng.randf_range(1.0, 1.3)
		return Vector3(diam, height, diam)
	d = 30.0
	while SHRUB_DENSITY > 0.0 and d < WORLD.y - 10.0:
		for side: float in [-1.0, 1.0]:
			if rng.randf() < 0.4:
				continue
			var s: Vector3 = shrub_size.call()
			var x: float = centre_x(d) + side * (lateral_half_width(d)
				+ s.x * 0.5 + rng.randf_range(0.5, 6.0))
			if beyond_edge(x, -d) > 0.4 + s.x * 0.5 and not _on_wall_ice(x, -d, s.x * 0.5) \
					and taken.is_free(x, -d, s.x * 0.45):
				# On a rock face, not planted but its footprint kept — see _scatter.
				if not _on_cliff(x, -d, s.x * 0.5):
					out["shrub"].push_back([x, -d, s, 0.0])
				taken.add(x, -d, s.x * 0.45)
		d += rng.randf_range(4.0, 9.0) / SHRUB_DENSITY
	for t: String in out:
		print("  %s: %d" % [t, out[t].size()])
	return out

## Lodge a trunk across the slot at [param d]: square to the trail, resting on
## each bank where the wall first stands [constant LOG_REST_HEIGHT] (and on one
## side up to [constant LOG_LEAN] more) over the trail's floor, its ends sunk
## [constant LOG_BURIED] into the banks. Keeps the trees off it.
func _lodge_log(rng: RandomNumberGenerator, d: float, into: Array,
		taken: CourseGenKit.Occupancy) -> void:
	var heading: float = centre_x(d + 0.5) - centre_x(d - 0.5)
	# Across the trail toward +X, in (x, z): square to its heading
	# `(heading, −1)`.
	var across := Vector2(1.0, heading).normalized()
	var mid := Vector2(centre_x(d), -d)
	var floor_y: float = _ground(mid.x, mid.y)
	var lean: float = rng.randf_range(0.0, LOG_LEAN)
	var rests: Array[Vector3] = []
	for side: float in [-1.0, 1.0]:
		var want: float = LOG_REST_HEIGHT + (lean if side > 0.0 else LOG_LEAN - lean)
		var s: float = 0.0
		var p: Vector2 = mid
		while s < 40.0:
			s += 0.1
			p = mid + across * side * s
			if _ground(p.x, p.y) - floor_y >= want:
				break
		rests.push_back(Vector3(p.x, floor_y + want, p.y))
	var a: Vector3 = rests[0]
	var b: Vector3 = rests[1]
	var span: Vector3 = b - a
	var run: float = Vector2(span.x, span.z).length()
	var length: float = span.length() + 2.0 * LOG_BURIED
	var thick: float = rng.randf_range(0.6, 0.85)
	var centre: Vector3 = (a + b) * 0.5
	# The marker's +X is (cos yaw, −sin yaw) in (x, z), and a roll about its Z
	# lifts +X: toward bank b.
	var yaw: float = atan2(-span.z, span.x)
	var roll: float = atan2(span.y, run)
	# The mesh's axis is [constant PropMesh.LOG_AXIS_Y] of its thickness above
	# its origin, and the origin stands on the ground plus the marker's Y.
	var lift: float = centre.y - PropMesh.LOG_AXIS_Y * thick - _ground(centre.x, centre.z)
	into.push_back([centre.x, centre.z, Vector3(length, thick, thick), yaw, lift, roll])
	var t: float = -0.5
	while t <= 0.5:
		var at: Vector3 = centre + span.normalized() * length * t
		taken.add(at.x, at.z, 1.2)
		t += 0.1

## A trunk fallen from the bank on [param side] at [param d]: its crown end on
## the snow [constant FALLEN_REACH] past the trail's middle, resting on the
## bank where that first stands 1.2 m, and running on along the same line
## into it — turned up to 25° off square to the trail. Its trail part is a row of collision cylinders,
## each as tall as the trunk's top over the snow there. Keeps the trees off it.
func _fell_trunk(rng: RandomNumberGenerator, d: float, side: float, into: Array,
		colliders: Array, taken: CourseGenKit.Occupancy) -> void:
	var heading: float = centre_x(d + 0.5) - centre_x(d - 0.5)
	var square := Vector2(1.0, heading).normalized()
	var across: Vector2 = square.rotated(rng.randf_range(-0.45, 0.45))
	var mid := Vector2(centre_x(d), -d)
	var thick: float = rng.randf_range(0.45, 0.65)
	# From the crown end, on the snow, out toward the bank.
	var tip: Vector2 = mid - across * side * FALLEN_REACH * lateral_half_width(d)
	var root: Vector2 = tip
	var s: float = 0.0
	while s < 30.0:
		s += 0.1
		root = tip + across * side * s
		if beyond_edge(root.x, root.y) > 0.0 and _ground(root.x, root.y) \
				- _ground(tip.x, tip.y) >= 1.2:
			break
	# Axis: from the crown resting on the snow to where it rests on the bank,
	# then on into the bank.
	var a := Vector3(tip.x, _ground(tip.x, tip.y) + thick * 0.5, tip.y)
	var rest := Vector3(root.x, _ground(root.x, root.y) + thick * 0.3, root.y)
	var b: Vector3 = rest + (rest - a).normalized() * LOG_BURIED
	# The marker's +X runs from a to b.
	var span: Vector3 = b - a
	var run: float = Vector2(span.x, span.z).length()
	var extra: float = 0.6
	var length: float = span.length() + extra
	var centre: Vector3 = a + span.normalized() * (length * 0.5 - extra)
	var yaw: float = atan2(-span.z, span.x)
	var roll: float = atan2(span.y, run)
	var lift: float = centre.y - PropMesh.LOG_AXIS_Y * thick - _ground(centre.x, centre.z)
	into.push_back([centre.x, centre.z, Vector3(length, thick, thick), yaw, lift, roll])
	var t: float = 0.0
	var dir: Vector3 = span.normalized()
	while t <= length:
		var at: Vector3 = a - dir * extra + dir * t
		var ground: float = _ground(at.x, at.z)
		if beyond_edge(at.x, at.z) <= 0.5:
			colliders.push_back([at.x, at.z,
				Vector3(thick + 0.1, maxf(at.y + thick * 0.5 - ground, 0.3), thick + 0.1), 0.0])
		taken.add(at.x, at.z, 0.9)
		t += 0.5

## The pile of stones at [constant STONE_PILE]: on the bank the trail turns
## away from, so it is in view ahead, its foot [constant PLAY_CLEARANCE] off
## the trail's edge. Big boulders round a core, smaller ones lifted onto them,
## one on top, and loose stones round the foot.
func _pile_stones(rng: RandomNumberGenerator, into: Array, loose: Array,
		taken: CourseGenKit.Occupancy) -> void:
	var r: float = STONE_PILE_RADIUS
	var d: float = STONE_PILE
	var x: float = 0.0
	var z: float = 0.0
	while d < STONE_PILE + 60.0:
		var side: float = -open_side(d)
		x = centre_x(d) + side * (lateral_half_width(d) + PLAY_CLEARANCE + r)
		z = -d
		if beyond_edge(x, z) > PLAY_CLEARANCE + r and not _on_wall_ice(x, z, r + 1.0) \
				and not _on_cliff(x, z, r + 1.0) and taken.is_free(x, z, r + 1.0):
			break
		d += 2.0
	var boulder := func(bx: float, bz: float, diam: float, lift: float) -> void:
		into.push_back([bx, bz, Vector3(diam, diam * rng.randf_range(0.6, 0.8), diam),
			rng.randf() * TAU, lift, 0.0])
	boulder.call(x, z, 2.4, 0.0)
	var base: int = 6
	for i: int in base:
		var a: float = TAU * (i + rng.randf_range(-0.2, 0.2)) / base
		var reach: float = r - 0.8 + rng.randf_range(-0.2, 0.2)
		boulder.call(x + cos(a) * reach, z + sin(a) * reach, rng.randf_range(1.3, 1.8), 0.0)
	for i: int in 3:
		var a: float = TAU * (i + 0.5 + rng.randf_range(-0.2, 0.2)) / 3.0
		boulder.call(x + cos(a) * 0.7, z + sin(a) * 0.7, rng.randf_range(1.0, 1.3),
			rng.randf_range(0.7, 0.9))
	boulder.call(x + rng.randf_range(-0.2, 0.2), z + rng.randf_range(-0.2, 0.2),
		rng.randf_range(0.8, 1.0), 1.4)
	for i: int in 5:
		var a: float = rng.randf() * TAU
		var reach: float = r + rng.randf_range(0.2, 0.9)
		var diam: float = rng.randf_range(0.8, 1.4)
		var sx: float = x + cos(a) * reach
		var sz: float = z + sin(a) * reach
		if beyond_edge(sx, sz) > PLAY_CLEARANCE:
			loose.push_back([sx, sz, Vector3(diam, diam, diam), rng.randf() * TAU])
	taken.add(x, z, r + 1.0)

## Scatter [param count] tries of a round prop up the walls within [param
## spread] m of the trail's edge, kept [param margin] m plus its radius off it.
func _scatter(rng: RandomNumberGenerator, into: Array, taken: CourseGenKit.Occupancy,
		count: int, margin: float, spread: float, size: Callable) -> void:
	for i: int in count:
		var s: Vector3 = size.call()
		var r: float = s.x * 0.5
		var d: float = rng.randf_range(5.0, WORLD.y - 5.0)
		var side: float = -1.0 if rng.randf() < 0.5 else 1.0
		var x: float = centre_x(d) + side * (lateral_half_width(d) + margin + r
			+ spread * pow(rng.randf(), 1.5))
		var z: float = -d
		if x < 1.0 or x > WORLD.x - 1.0:
			continue
		if beyond_edge(x, z) > margin + r and not _on_wall_ice(x, z, r) \
				and taken.is_free(x, z, r):
			if _on_cliff(x, z, r):
				# Not placed, but its draw spent and its footprint kept, so
				# everything placed after it lands where it did before the
				# face was there: a rock face on one wall must not reshuffle
				# the whole course.
				rng.randf()
				taken.add(x, z, r)
				continue
			into.push_back([x, z, s, rng.randf() * TAU])
			taken.add(x, z, r)

## Fallen logs on the lower walls, lying roughly across the fall line; both
## ends and the middle off the trail.
func _scatter_logs(rng: RandomNumberGenerator, into: Array, taken: CourseGenKit.Occupancy,
		count: int) -> void:
	for i: int in count:
		var length: float = rng.randf_range(2.5, 6.0)
		var thick: float = rng.randf_range(0.3, 0.55)
		var yaw: float = rng.randf_range(-0.6, 0.6) + (PI if rng.randf() < 0.5 else 0.0)
		var d: float = rng.randf_range(5.0, WORLD.y - 5.0)
		var z: float = -d
		var side: float = -1.0 if rng.randf() < 0.5 else 1.0
		var x: float = centre_x(d) + side * (lateral_half_width(d) + 1.5 + length * 0.5
			+ rng.randf_range(0.0, 14.0))
		var half := Vector2(cos(yaw), -sin(yaw)) * length * 0.5
		var ok: bool = true
		for t: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var px: float = x + half.x * t
			var pz: float = z + half.y * t
			ok = ok and px > 1.0 and px < WORLD.x - 1.0 and beyond_edge(px, pz) > 1.0 \
				and not _on_wall_ice(px, pz, thick) and taken.is_free(px, pz, thick)
		if not ok:
			continue
		# On a rock face, not laid but its footprint kept — see _scatter.
		var on_rock: bool = false
		for t: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			on_rock = on_rock or _on_cliff(x + half.x * t, z + half.y * t, thick)
		if not on_rock:
			into.push_back([x, z, Vector3(length, thick, thick), yaw])
		for t: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			taken.add(x + half.x * t, z + half.y * t, thick)
