## Generates **Snow Park**, the third course authored for this project: a
## ski resort's mountain, from the summit restaurant to the village in the
## valley, with a terrain park built into its piste. Where Forest Trail and
## Mountain Forest are trails through the woods, this is a piste shaped by
## machines, and it goes as a real one does: open and wide above the trees,
## a narrow fenced catwalk through them, wide again, steep pitches and flats
## after each other. Top to bottom:
##
## - the start beside the summit restaurant and the lift's top station, and a
##   steep, wide-open face above the treeline;
## - rollers — a train of waves across the whole run, to pump or to pop off;
## - a narrow catwalk, fenced either side, winding through the forest, and a
##   steep pitch out of the trees;
## - a jump line: three table-tops of growing size down the left half, and on
##   the right the chicken line with three fun boxes to slide (glazed ice);
## - a narrow, nearly flat path past the mid-mountain restaurant and its sun
##   terrace, then a steep pitch;
## - a banked slalom: four turns round gate flags, each with a berm on its
##   outside;
## - a wide, flat meadow (and two igloos);
## - a half-pipe, 180 m long and 4.5 m deep;
## - a narrow, steep chute through the forest, fenced, and a flat run-out;
## - a mogul field;
## - the big jump — an inrun, a take-off table, a 37° landing hill lined with
##   orange safety nets — and the outrun to the finish, fenced, in the village.
##
## Herring hang in the air over the jumps — collecting one is a 3D distance
## ([method RacePhysics._check_item_collection]), so only a flight reaches
## them — and line the walls of the half-pipe and the berms. Beside the run a
## chairlift climbs the hill from a station in the village to one beside the
## start. Every building stands on a pad levelled into the slope; snowmen
## stand about the park, and the conifers start below the treeline, thickest
## along the catwalks.
##
##     tools/gen_snow_park.sh
##
## which runs this twice with Godot's `--import` in between, like
## `gen_forest_trail.gd` (see there for why):
##
##     godot --headless --path game --script res://addons/course_gen/gen_snow_park.gd -- --stage=assets
##     godot --headless --path game --import
##     godot --headless --path game --script res://addons/course_gen/gen_snow_park.gd -- --stage=resources
##
## The same shape as every course — `res://courses/snow_park/` — and the same
## promises: deterministic, re-runnable, never visited by the importer.
##
## [b]Every feature is relief in the heightmap[/b], since that and upright
## cylinders are all the simulation knows: a racer rides a kicker, a wall or a
## box exactly as it rides the slope. Nothing solid stands on the run. The
## resort's furniture is [PropMesh]'s (`snowman`, `igloo`, `lift_*`, the
## buildings, the fences and the nets). The play area reaches far past the
## run into the woods ([constant PLAY_MARGIN]), so the trees, boulders and
## snowmen out there can be hit; it keeps clear of the buildings and the lift,
## which are not solid. Along the catwalks ([constant FENCED]) a fence stands
## in the trees at its edge — the fence is where a racer stops.
##
## [b]The fall line[/b] is [constant SECTIONS], each eased into the next over
## its own length — the big jump's lip over 3 m, so a racer leaves the ground
## there, the outrun over 22 m, so the landing hill bends out gently. As on
## Mountain Forest, the heightmap holds the steps' difference from
## [member CourseData.base_angle], integrated down the course ([method
## _profile]), and the occlusion bake is handed the relief without it.
extends SceneTree

const DIR := "snow_park"
const OUT := "res://courses/snow_park"
const PREVIEW_SIZE := Vector2i(192, 144)

const DISPLAY_NAME := "Snow Park"
const AUTHOR := "PenguinRacer"
const DESCRIPTION := "A ski resort on a sunny mountain, from the summit restaurant " \
	+ "to the village. Drop the open face, squeeze down the catwalks through the woods, " \
	+ "fly the table-tops or slide the boxes, carve the berms of the slalom, ride the " \
	+ "half-pipe, plunge down the chute, hammer through the moguls and finish off the " \
	+ "big jump. Herring hang in the air: catch them in flight."

## Course extent, metres: width along +X, length along -Z.
const WORLD := Vector2(140.0, 1925.0)
## Where the finish line is, and how wide the play area may get.
const PLAY := Vector2(130.0, 1835.0)
const CELL := 0.5
const SEED := 20261005

## The fall line, top to bottom: `(metres down where it starts, degrees,
## metres eased either side)`. Each section's gradient takes over from the last
## along a smoothstep over its ease. The start is steep enough to set off from
## a standstill (snow holds a racer up to 19.3°). Steep pitches and flats take
## turns, as on a real mountain: the summit face, the pitch out of the woods,
## the one into the slalom, the chute and the inrun at 27–32°; the catwalk, the
## path past the restaurant, the meadow and the run-out at 14–17°, short enough
## that a racer carries speed across them. The half-pipe is under snow's
## 19.3° too, and bleeds a little speed over its 180 m.
const SECTIONS: Array[Vector3] = [
	Vector3(0.0, 24.0, 0.0), Vector3(55.0, 31.0, 12.0), Vector3(138.0, 19.0, 12.0),
	Vector3(258.0, 17.0, 12.0), Vector3(392.0, 28.0, 9.0), Vector3(422.0, 21.0, 9.0),
	Vector3(652.0, 14.0, 10.0), Vector3(703.0, 27.0, 8.0), Vector3(724.0, 20.0, 8.0),
	Vector3(936.0, 15.0, 10.0), Vector3(985.0, 18.0, 10.0), Vector3(1186.0, 30.0, 11.0),
	Vector3(1292.0, 15.0, 11.0), Vector3(1337.0, 23.0, 10.0), Vector3(1460.0, 32.0, 14.0),
	Vector3(1552.0, 12.0, 10.0), Vector3(BIG_LIP, 37.0, BIG_LIP_EASE),
	Vector3(1680.0, 13.0, 22.0), Vector3(1765.0, 9.0, 15.0),
]
## Where the profile is sampled, metres.
const PROFILE_STEP := 0.25

## The run's middle stands here across X, left of the world's middle: the
## chairlift has the right side.
const RUN_X := 62.0
## The run's half-width at points down the course, `(metres down, metres)`,
## smoothstepped between: wide open faces (the summit, the jump line, the
## meadow, the finish) and narrow ways (the catwalk, the restaurant's path, the
## slalom, the chute) after each other. At the half-pipe it is the pipe out to
## its coping.
const WIDTHS: Array[Vector2] = [
	Vector2(0.0, 12.0), Vector2(42.0, 12.0), Vector2(72.0, 24.0), Vector2(126.0, 24.0),
	Vector2(150.0, 16.0), Vector2(250.0, 16.0), Vector2(268.0, 4.5), Vector2(382.0, 4.5),
	Vector2(402.0, 11.0), Vector2(428.0, 18.0), Vector2(642.0, 18.0), Vector2(658.0, 6.0),
	Vector2(700.0, 6.0), Vector2(714.0, 7.0), Vector2(930.0, 7.0), Vector2(946.0, 22.0),
	Vector2(966.0, 22.0), Vector2(990.0, 9.42), Vector2(1176.0, 9.42), Vector2(1192.0, 6.0),
	Vector2(1286.0, 6.0), Vector2(1302.0, 12.0), Vector2(1334.0, 12.0), Vector2(1350.0, 15.0),
	Vector2(1450.0, 15.0), Vector2(1475.0, 12.0), Vector2(1560.0, 12.0), Vector2(1585.0, 16.0),
	Vector2(1680.0, 16.0), Vector2(1710.0, 18.0), Vector2(1795.0, 20.0), Vector2(1925.0, 20.0),
]
## Where the woods begin, past the run's edge: [constant WOODS_MARGIN] on the
## open slopes, [constant WOODS_FENCED] along [constant FENCED] (eased over
## [constant FENCE_EASE]). Trees, boulders, shrubs, snowmen and buildings stand
## beyond it, so the run looks as a groomed piste does.
const WOODS_MARGIN := 8.0
const WOODS_FENCED := 2.0
## How far past the run's edge a racer may go: far out into the woods on the
## open slopes ([constant PLAY_MARGIN]), so a racer can leave the piste, explore
## and hit a tree; on the narrow ways to a fence standing in the trees
## ([constant FENCE_MARGIN]); and along the big jump's nets and round the
## finish only to the woods' edge ([constant WOODS_MARGIN]). Each change eased
## over [constant MARGIN_EASE] either side, so the edge narrows as a funnel a
## racer slides along, never a step that snaps them sideways.
const PLAY_MARGIN := 30.0
const FENCE_MARGIN := 10.0
const MARGIN_EASE := 30.0
## The play area keeps this far off the world's left edge, and out of the
## lift's clearing on the right.
const PLAY_EDGE := 6.0
## How far the play area keeps off a building's levelled pad.
const HOUSE_CLEARANCE := 1.5
## The narrow ways through the woods, `(metres down from, to)`: the catwalk,
## the restaurant's path and the chute. There the woods close in on the run,
## and a wooden fence stands along the play area's edge (from [constant
## MARGIN_EASE] before to after, where the fence follows the play area out).
const FENCED: Array[Vector2] = [Vector2(268.0, 384.0), Vector2(658.0, 702.0),
	Vector2(1192.0, 1288.0)]
const FENCE_EASE := 10.0
## The finish area's fence, from where to where down, along the play area's
## edge; and the big jump's orange nets, from the take-off table to the foot of
## its landing.
const FINISH_FENCE := Vector2(PLAY.y - 45.0, WORLD.y - 3.0)
const NETS := Vector2(BIG_LIP - 25.0, BIG_LANDING_END + 20.0)
## A fence's posts this far apart, a net's poles this far, and either this far
## outside the play area's edge.
const POST_SPACING := 2.4
const POLE_SPACING := 4.0
const FENCE_OUTSET := 0.6
## How far off the play area's edge anything solid keeps its whole cylinder.
const PLAY_CLEARANCE := 1.5
## Edge piece length of the play area, and of the run's polygon — at least
## [constant CourseLights.SPACING], or no torch stands along it.
const CORRIDOR_STEP := 6.0
const TRAIL_STEP := 22.0

# ---------------------------------------------------------------- features

## Rollers: `(metres down where the first starts, wavelength, how many)`, and
## their height: a crest 8 m round, so anything over about 8 m/s leaves it.
const ROLLERS := Vector3(150.0, 13.0, 8.0)

## The catwalk through the woods: from, to, and how far its one S-bend swings
## either side.
const CATWALK := Vector2(255.0, 395.0)
const CATWALK_SWING := 11.0
## The restaurant's path: from, to, and how far it bulges out toward the
## restaurant (−X); the chute: from, to, and its bend (+X).
const RESTAURANT_PATH := Vector3(645.0, 715.0, -7.0)
const CHUTE := Vector3(1185.0, 1295.0, 6.0)
const ROLLER_HEIGHT := 1.1

## The table-tops, `(metres down to the lip, height)`, on the run's left half
## between [constant TABLE_SPAN]'s offsets from its middle (with a [constant
## TABLE_SIDE] slope down either side). Each rises over [constant TABLE_RAMP]
## times its height along `H·(t/L)²` — a lip 25° over the slope, a park
## kicker's —, holds [constant TABLE_TOP] + [constant TABLE_TOP_PER_M]·H flat,
## and lands down a smoothstep over [constant TABLE_LANDING] +
## [constant TABLE_LANDING_PER_M]·H. At the ~15 m/s a racer brings there, each
## flight clears its table and comes down on the landing
## (`tools/probe_course.sh --follow=-8.75 --from=225 --to=450`).
const TABLES: Array[Vector2] = [Vector2(448.0, 1.3), Vector2(522.0, 2.0), Vector2(604.0, 2.8)]
const TABLE_SPAN := Vector2(-15.0, -2.5)
const TABLE_SIDE := 3.0
const TABLE_RAMP := 4.3
const TABLE_RAMP_POWER := 2.0
const TABLE_TOP := 2.0
const TABLE_TOP_PER_M := 2.0
const TABLE_LANDING := 12.0
const TABLE_LANDING_PER_M := 6.0

## The fun boxes on the chicken line: `(metres down where the top starts, its
## length, offset from the run's middle)`. Each [constant BOX_HEIGHT] high and
## 2·[constant BOX_HALF] wide on top, up a [constant BOX_RAMP] m ramp and off a
## [constant BOX_DROP] m drop; the top is glazed ice ([constant L_BOX]).
const BOXES: Array[Vector3] = [Vector3(452.0, 10.0, 8.0), Vector3(528.0, 12.0, 8.5),
	Vector3(614.0, 12.0, 8.0)]
const BOX_HEIGHT := 0.7
const BOX_HALF := 1.0
const BOX_EDGE := 0.5
const BOX_RAMP := 3.5
const BOX_DROP := 1.5

## The slalom: from, to, the bends' wavelength and their swing either side.
## Four turns, a radius of ~28 m at the apex; the swing is wider than the run,
## so there is no straight line through.
const SLALOM := Vector2(730.0, 930.0)
const SLALOM_WAVE := 100.0
const SLALOM_SWING := 9.0
## How high the berm stands on the outside of a turn at its apex.
const BERM_HEIGHT := 2.4

## The half-pipe: from, to, how long its walls take to rise at the top and to
## fall at the bottom; its floor's half-width, its walls' radius, and how far
## round a quarter circle they go (80°: 4.5 m up, nearly vertical at the
## coping); the deck along the top and the bank down outside it.
const PIPE := Vector2(995.0, 1175.0)
const PIPE_RISE := 25.0
const PIPE_FALL := 15.0
const PIPE_FLOOR := 4.0
const PIPE_RADIUS := 5.5
const PIPE_ANGLE := 80.0
const PIPE_DECK := 3.0
const PIPE_BANK := 6.0

## The moguls: from, to, the lattice spacing and their height.
const MOGULS := Vector2(1340.0, 1450.0)
const MOGUL_SPACING := 3.6
const MOGUL_HEIGHT := 0.6

## The big jump's lip: where [constant SECTIONS] turns 12° into 37°.
const BIG_LIP := 1570.0
## How far either side of the lip its ease reaches ([constant SECTIONS]).
const BIG_LIP_EASE := 3.0
## Where its landing hill ends.
const BIG_LANDING_END := 1680.0

## How fast a racer typically leaves each lip, m/s — for the herring arcs
## ([method _arc]). Off `tools/probe_course.sh`: ~15 m/s at every table,
## holding their line; 16 (medium) to 27 (hard) at the big jump, whose arc is
## pitched between.
const TABLE_LIP_SPEEDS: Array[float] = [14.5, 14.5, 14.5]
const BIG_LIP_SPEED := 23.0
## How far up from the ground to the flight a herring hangs: lower over the
## table-tops, where flights spread, than over the big jump, where a racer
## arrives only fast and the arc is the flight.
const TABLE_ARC_SHARE := 0.75
const BIG_ARC_SHARE := 0.9

# ---------------------------------------------------------------- the lift

## The chairlift's line across X, and how much of either side of it is clear
## of trees.
const LIFT_X := 116.0
const LIFT_CLEARING := 8.0
## Metres down to the top station (beside the start) and the bottom one
## (in the village, below the finish).
const LIFT_TOP := 12.0
const LIFT_BOTTOM := PLAY.y + 38.0
## Towers are spaced up to this far apart, and stand this tall at least;
## taller where the cable would pass too low over the ground between.
const TOWER_SPACING := 70.0
const TOWER_HEIGHT := 9.0
const TOWER_MAX_HEIGHT := 16.0
const CABLE_CLEARANCE := 5.0
const CABLE_THICKNESS := 0.06
## Metres of cable between chairs on either line.
const CHAIR_SPACING := 18.0

## Terrain layers, in splat order; the index is the channel.
const LAYERS: Array[String] = ["snow", "strike_snow", "thin_snow", "hockey_ice", "dirty_snow"]
const L_SNOW := 0
const L_FEATURE := 1
const L_WOODS := 2
const L_BOX := 3
const L_WORN := 4

## The sky: the Alps — taller than the usual skyline, some forest up their
## flanks, a little nearer.
const BACKDROP_HEIGHT := 1.6
const BACKDROP_FOREST := 0.25
const BACKDROP_NEAR := 0.3

## How much stands in the woods beside the run.
const FOREST_DENSITY := 0.6
const SHRUB_DENSITY := 0.5
## The treeline, metres down: no tree above the first, the woods at their
## fullest from the second. And how much thicker they stand along a catwalk.
const TREELINE := Vector2(90.0, 260.0)
const CATWALK_WOODS := 0.7

# ---------------------------------------------------------------- buildings

## The resort's buildings: a prefab, metres down, and either the side of the
## run it stands beside (`side`, just past the woods' edge) or where it stands
## across (`x`), and a `scale`. Each faces the run, turned a little.
const HOUSES: Array[Dictionary] = [
	{"id": "mountain_hut", "d": 24.0, "side": -1.0},
	{"id": "mountain_hut", "d": 676.0, "side": -1.0},
	{"id": "shed", "d": 1540.0, "side": 1.0},
	# The village round the finish: a row and a second one behind it on the
	# left, one between the run and the lift, and a row beyond the lift.
	{"id": "chalet", "d": 1850.0, "side": -1.0},
	{"id": "chalet_b", "d": 1873.0, "side": -1.0},
	{"id": "chalet", "d": 1896.0, "side": -1.0},
	{"id": "chalet_b", "d": 1918.0, "side": -1.0, "scale": 0.9},
	{"id": "chalet_b", "d": 1860.0, "x": 9.5},
	{"id": "chalet", "d": 1906.0, "x": 9.5},
	{"id": "chalet", "d": 1902.0, "side": 1.0, "scale": 0.85},
	{"id": "chalet_b", "d": 1846.0, "x": 132.5, "scale": 0.8},
	{"id": "shed", "d": 1878.0, "x": 132.5},
	{"id": "chalet", "d": 1905.0, "x": 132.5, "scale": 0.8},
]
## How far past its footprint the ground round a building is levelled, and over
## how many metres the pad blends back into the slope.
const PAD_SLACK := 1.0
const PAD_BLEND := 6.0
## A station's pad: its radius, and how far down the hill of the marker its
## middle is (the hut stands behind the bullwheel).
const STATION_PAD := 6.5

## The park's furniture: prefab id → how [PropMesh] builds it and what it is.
const FURNITURE: Dictionary[String, Dictionary] = {
	"snowman": {"kind": PropMesh.Kind.SNOWMAN, "collidable": true, "aligned": false,
		"seed": 61, "mottle": 0.08},
	"igloo": {"kind": PropMesh.Kind.IGLOO, "collidable": true, "aligned": true, "seed": 67,
		"mottle": 0.1},
	"lift_tower": {"kind": PropMesh.Kind.LIFT_TOWER, "collidable": false, "aligned": false,
		"seed": 71, "mottle": 0.15},
	"lift_cable": {"kind": PropMesh.Kind.LIFT_CABLE, "collidable": false, "aligned": false,
		"seed": 73, "mottle": 0.0},
	"lift_chair": {"kind": PropMesh.Kind.LIFT_CHAIR, "collidable": false, "aligned": false,
		"seed": 79, "mottle": 0.15},
	"lift_station": {"kind": PropMesh.Kind.LIFT_STATION, "collidable": false, "aligned": false,
		"seed": 83, "mottle": 0.3},
	# An odd seed builds a chalet with a plastered ground floor, an even one
	# all timber ([method PropMesh._chalet]). Their roofs carry more snow than
	# the default leaves a prop.
	"chalet": {"kind": PropMesh.Kind.CHALET, "collidable": false, "aligned": false, "seed": 89,
		"mottle": 0.12, "snow": 0.75},
	"chalet_b": {"kind": PropMesh.Kind.CHALET, "collidable": false, "aligned": false, "seed": 98,
		"mottle": 0.12, "snow": 0.75},
	"mountain_hut": {"kind": PropMesh.Kind.MOUNTAIN_HUT, "collidable": false, "aligned": false,
		"seed": 101, "mottle": 0.12, "snow": 0.75},
	"shed": {"kind": PropMesh.Kind.SHED, "collidable": false, "aligned": false, "seed": 103,
		"mottle": 0.15, "snow": 0.75},
	"fence_post": {"kind": PropMesh.Kind.FENCE_POST, "collidable": false, "aligned": false,
		"seed": 107, "mottle": 0.25},
	"fence_rail": {"kind": PropMesh.Kind.FENCE_RAIL, "collidable": false, "aligned": false,
		"seed": 109, "mottle": 0.25},
	"net_pole": {"kind": PropMesh.Kind.NET_POLE, "collidable": false, "aligned": false,
		"seed": 113, "mottle": 0.05},
	"net_panel": {"kind": PropMesh.Kind.NET_PANEL, "collidable": false, "aligned": false,
		"seed": 127, "mottle": 0.05},
}

var _w: int
var _h: int
var _relief_noise := FastNoiseLite.new()
var _fine_noise := FastNoiseLite.new()
var _piste_noise := FastNoiseLite.new()
var _edge_noise := FastNoiseLite.new()
var _density_noise := FastNoiseLite.new()
## [method _profile] every [constant PROFILE_STEP] down the course, and the
## slope it is measured from.
var _profile_s := PackedFloat32Array()
var _base_tan: float = 0.0
## The towers, `[x, z, height]`, from [method _plan_lift].
var _towers: Array[Vector3] = []
## The buildings, `[prefab, x, z, yaw, scale]`, from [method _plan_houses].
var _houses: Array[Array] = []
## The ground levelled under each building and station, `(x, z, radius, world
## height)`, from [method _plan_pads]; and which of them are trodden grey
## (`(x, z, radius)`: the stations and the restaurants).
var _pads: Array[Vector4] = []
var _worn: Array[Vector3] = []

func _initialize() -> void:
	var stage: String = "assets"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--stage="):
			stage = a.trim_prefix("--stage=")
	_w = int(round(WORLD.x / CELL)) + 1
	_h = int(round(WORLD.y / CELL)) + 1
	_setup_noise()
	_build_profile()
	_plan_houses()
	_plan_pads()
	_plan_lift()
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
	print("snow_park: stage '%s' done in %.1f s"
		% [stage, float(Time.get_ticks_msec() - start) / 1000.0])
	quit(0)

func _setup_noise() -> void:
	var all: Array[FastNoiseLite] = [_relief_noise, _fine_noise, _piste_noise, _edge_noise,
		_density_noise]
	for i: int in all.size():
		all[i].seed = SEED + i
		all[i].noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_relief_noise.frequency = 1.0 / 35.0
	_relief_noise.fractal_octaves = 3
	_fine_noise.frequency = 1.0 / 5.0
	_fine_noise.fractal_octaves = 2
	_piste_noise.frequency = 1.0 / 12.0
	_piste_noise.fractal_octaves = 1
	_edge_noise.frequency = 1.0 / 8.0
	_edge_noise.fractal_octaves = 2
	_density_noise.frequency = 1.0 / 45.0

# ================================================================ the fall line

## The gradient at [param d] metres down, as a tangent: each section's taking
## over from the one before along a smoothstep over its ease.
static func gradient(d: float) -> float:
	var g: float = tan(deg_to_rad(SECTIONS[0].y))
	for i: int in range(1, SECTIONS.size()):
		var s: Vector3 = SECTIONS[i]
		var step: float = smoothstep(s.x - s.z, s.x + s.z, d) if s.z > 0.0 \
			else (1.0 if d >= s.x else 0.0)
		g += (tan(deg_to_rad(s.y)) - tan(deg_to_rad(SECTIONS[i - 1].y))) * step
	return g

## The mean gradient over the whole grid, as an angle: the course's
## [member CourseData.base_angle].
static func base_angle() -> float:
	var sum: float = 0.0
	var n: int = int(WORLD.y / PROFILE_STEP)
	for i: int in n:
		sum += gradient((float(i) + 0.5) * PROFILE_STEP)
	return rad_to_deg(atan(sum / n))

## Integrate the sections: how far above the analytic base slope the fall line
## is at each [constant PROFILE_STEP] down.
func _build_profile() -> void:
	_base_tan = tan(deg_to_rad(base_angle()))
	var n: int = int(WORLD.y / PROFILE_STEP) + 2
	_profile_s.resize(n)
	var p: float = 0.0
	_profile_s[0] = 0.0
	for i: int in range(1, n):
		p -= (gradient((float(i) - 0.5) * PROFILE_STEP) - _base_tan) * PROFILE_STEP
		_profile_s[i] = p
	var mean: float = 0.0
	for i: int in n:
		mean += _profile_s[i]
	mean /= n
	for i: int in n:
		_profile_s[i] -= mean

## [member _profile_s] at [param d], interpolated.
func _profile(d: float) -> float:
	var f: float = clampf(d / PROFILE_STEP, 0.0, float(_profile_s.size() - 1) - 0.001)
	var i: int = int(f)
	return lerpf(_profile_s[i], _profile_s[i + 1], f - i)

# ================================================================ the run

## The run's middle across X at [param d] metres down: straight where the
## features want it, a gentle swing through the rollers and the moguls, the
## catwalk's S-bend through the woods, the restaurant's path bulging out
## toward it, the chute's one bend and the slalom's turns.
static func centre_x(d: float) -> float:
	var x: float = RUN_X
	x += 4.0 * sin(TAU * (d - ROLLERS.x) / 300.0) * _window(d, ROLLERS.x, CATWALK.x, 25.0)
	x += CATWALK_SWING * sin(TAU * (d - CATWALK.x) / (CATWALK.y - CATWALK.x)) \
		* _window(d, CATWALK.x, CATWALK.y, 20.0)
	x += RESTAURANT_PATH.z * _bulge(d, RESTAURANT_PATH.x, RESTAURANT_PATH.y)
	x += CHUTE.z * _bulge(d, CHUTE.x, CHUTE.y)
	x += 3.0 * sin(TAU * (d - (MOGULS.x - 5.0)) / 240.0) \
		* _window(d, MOGULS.x - 5.0, MOGULS.y + 5.0, 25.0)
	x += SLALOM_SWING * sin(TAU * (d - SLALOM.x) / SLALOM_WAVE) \
		* _window(d, SLALOM.x, SLALOM.y, SLALOM_WAVE * 0.25)
	return x

## 1 inside [param from]..[param to], easing to 0 over [param ease] at both ends.
static func _window(d: float, from: float, to: float, ease: float) -> float:
	return smoothstep(from, from + ease, d) * (1.0 - smoothstep(to - ease, to, d))

## 0 at [param from] and [param to], 1 halfway, and level at all three: one
## bend out and back.
static func _bulge(d: float, from: float, to: float) -> float:
	if d <= from or d >= to:
		return 0.0
	return 0.5 - 0.5 * cos(TAU * (d - from) / (to - from))

## How far [param d] is into one of [constant FENCED], 0..1.
static func fenced(d: float) -> float:
	var f: float = 0.0
	for r: Vector2 in FENCED:
		f = maxf(f, _window(d, r.x - FENCE_EASE, r.y + FENCE_EASE, FENCE_EASE))
	return f

## How far past the run's edge the woods begin at [param d].
static func woods_margin(d: float) -> float:
	return lerpf(WOODS_MARGIN, WOODS_FENCED, fenced(d))

## How far past the run's edge the play area reaches at [param d] (before
## [method _edges] keeps it off the world's edges and the buildings).
static func play_margin(d: float) -> float:
	var f: float = 0.0
	for r: Vector2 in FENCED:
		f = maxf(f, _window(d, r.x - MARGIN_EASE, r.y + MARGIN_EASE, MARGIN_EASE))
	var held: float = maxf(_window(d, NETS.x - MARGIN_EASE, NETS.y + MARGIN_EASE, MARGIN_EASE),
		smoothstep(FINISH_FENCE.x - MARGIN_EASE, FINISH_FENCE.x, d))
	return lerpf(lerpf(PLAY_MARGIN, FENCE_MARGIN, f), WOODS_MARGIN, held)

## Half the run's width, square to it: [constant WIDTHS], smoothstepped.
static func half_width(d: float) -> float:
	for i: int in range(1, WIDTHS.size()):
		if d <= WIDTHS[i].x:
			var a: Vector2 = WIDTHS[i - 1]
			var b: Vector2 = WIDTHS[i]
			return lerpf(a.y, b.y, smoothstep(a.x, b.x, d))
	return WIDTHS[WIDTHS.size() - 1].y

## Half the width across X, the same to a racer on a bend.
static func lateral_half_width(d: float) -> float:
	var slope: float = centre_x(d + 0.5) - centre_x(d - 0.5)
	return half_width(d) * sqrt(1.0 + slope * slope)

## How far outside the run's edge (x, z) is, across X: negative on it.
static func beyond_edge(x: float, z: float) -> float:
	var d: float = -z
	return absf(x - centre_x(d)) - lateral_half_width(d)

## How the run bends at [param d]: the centre line's second difference over a
## metre. Positive bends toward +X.
static func bend(d: float) -> float:
	return centre_x(d + 1.0) - 2.0 * centre_x(d) + centre_x(d - 1.0)

## The sharpest [method bend] the slalom reaches, at an apex.
static func max_bend() -> float:
	return SLALOM_SWING * pow(TAU / SLALOM_WAVE, 2.0)

## The slalom's apexes, metres down: where each turn bends hardest.
static func apexes() -> Array[float]:
	var out: Array[float] = []
	var d: float = SLALOM.x + SLALOM_WAVE * 0.25
	while d < SLALOM.y:
		out.push_back(d)
		d += SLALOM_WAVE * 0.5
	return out

# ================================================================ the features

## The rollers' height at [param d], across the whole run.
static func rollers(d: float) -> float:
	var t: float = d - ROLLERS.x
	if t < 0.0 or t > ROLLERS.y * ROLLERS.z:
		return 0.0
	return ROLLER_HEIGHT * (0.5 - 0.5 * cos(TAU * t / ROLLERS.y))

## Where each roller's crest is, metres down.
static func roller_crests() -> Array[float]:
	var out: Array[float] = []
	for k: int in int(ROLLERS.z):
		out.push_back(ROLLERS.x + ROLLERS.y * (k + 0.5))
	return out

## A table-top's ramp, table and landing at [param d] down its middle; its
## extent along the course is [method table_extent].
static func table_profile(d: float, table: Vector2) -> float:
	var h: float = table.y
	var up: float = TABLE_RAMP * h
	var top: float = table_top_length(table)
	var down: float = TABLE_LANDING + TABLE_LANDING_PER_M * h
	var t: float = d - table.x
	if t <= -up or t >= top + down:
		return 0.0
	if t < 0.0:
		return h * pow((t + up) / up, TABLE_RAMP_POWER)
	if t < top:
		return h
	return h * (1.0 - smoothstep(top, top + down, t))

static func table_top_length(table: Vector2) -> float:
	return TABLE_TOP + TABLE_TOP_PER_M * table.y

## From where a table-top's ramp starts to where its landing ends, metres down.
static func table_extent(table: Vector2) -> Vector2:
	return Vector2(table.x - TABLE_RAMP * table.y,
		table.x + table_top_length(table) + TABLE_LANDING + TABLE_LANDING_PER_M * table.y)

## The table-tops at [param d], [param a] metres across from the run's middle.
static func tables(d: float, a: float) -> float:
	var across: float = smoothstep(TABLE_SPAN.x - TABLE_SIDE, TABLE_SPAN.x, a) \
		* (1.0 - smoothstep(TABLE_SPAN.y, TABLE_SPAN.y + TABLE_SIDE, a))
	if across <= 0.0:
		return 0.0
	var h: float = 0.0
	for table: Vector2 in TABLES:
		h = maxf(h, table_profile(d, table))
	return h * across

## The fun boxes at [param d], [param a] across.
static func boxes(d: float, a: float) -> float:
	var h: float = 0.0
	for box: Vector3 in BOXES:
		var across: float = 1.0 - smoothstep(BOX_HALF, BOX_HALF + BOX_EDGE, absf(a - box.z))
		if across <= 0.0:
			continue
		var t: float = d - box.x
		var along: float = 0.0
		if t > -BOX_RAMP and t < 0.0:
			along = (t + BOX_RAMP) / BOX_RAMP
		elif t >= 0.0 and t <= box.y:
			along = 1.0
		elif t > box.y and t < box.y + BOX_DROP:
			along = 1.0 - smoothstep(box.y, box.y + BOX_DROP, t)
		h = maxf(h, BOX_HEIGHT * along * across)
	return h

## Whether (d, a) is on a box's glazed top.
static func on_box_top(d: float, a: float) -> bool:
	for box: Vector3 in BOXES:
		if absf(a - box.z) <= BOX_HALF + 0.2 and d >= box.x - 0.5 and d <= box.y + box.x + 0.3:
			return true
	return false

## The slalom's berms at [param d], [param a] across of [param hl]: on the
## outside of each turn the run banks up, as high as the turn is sharp, and
## the bank goes on past the run's edge before falling back.
static func berm(d: float, a: float, hl: float) -> float:
	if d < SLALOM.x or d > SLALOM.y:
		return 0.0
	var b: float = bend(d)
	var strength: float = clampf(absf(b) / max_bend(), 0.0, 1.0)
	if strength < 1e-3:
		return 0.0
	# Across, 1 at the outside edge: a turn bending toward +X throws a racer
	# toward −X.
	var o: float = a * -signf(b) / hl
	var rise: float = pow(smoothstep(-0.2, 1.15, o), 1.5)
	var fall: float = 1.0 - smoothstep(1.3, 2.1, o)
	return BERM_HEIGHT * strength * rise * fall

## How far in the half-pipe's walls have risen at [param d], 0..1.
static func pipe_rise(d: float) -> float:
	return smoothstep(PIPE.x, PIPE.x + PIPE_RISE, d) * (1.0 - smoothstep(PIPE.y - PIPE_FALL,
		PIPE.y, d))

## Where the coping is, across from the floor's middle.
static func pipe_coping() -> float:
	return PIPE_FLOOR + PIPE_RADIUS * sin(deg_to_rad(PIPE_ANGLE))

## The walls' full height at the coping.
static func pipe_height() -> float:
	return PIPE_RADIUS * (1.0 - cos(deg_to_rad(PIPE_ANGLE)))

## The half-pipe at [param d], [param a] across: a flat floor, quarter-circle
## walls to the coping, the deck, and a bank down outside it — all scaled by
## how far its walls have risen.
static func halfpipe(d: float, a: float) -> float:
	var k: float = pipe_rise(d)
	if k <= 0.0:
		return 0.0
	var s: float = absf(a)
	var coping: float = pipe_coping()
	var h: float = 0.0
	if s <= PIPE_FLOOR:
		h = 0.0
	elif s <= coping:
		var q: float = s - PIPE_FLOOR
		h = PIPE_RADIUS - sqrt(maxf(PIPE_RADIUS * PIPE_RADIUS - q * q, 0.0))
	elif s <= coping + PIPE_DECK:
		h = pipe_height()
	else:
		h = pipe_height() * (1.0 - smoothstep(coping + PIPE_DECK, coping + PIPE_DECK + PIPE_BANK,
			s))
	return h * k

## The moguls at [param d], [param a] across: a diamond lattice of bumps.
static func moguls(d: float, a: float) -> float:
	var w: float = _window(d, MOGULS.x, MOGULS.y, 12.0)
	if w <= 0.0:
		return 0.0
	var u: float = a / MOGUL_SPACING
	var v: float = d / MOGUL_SPACING
	var m: float = (0.5 + 0.5 * cos(PI * (u + v))) * (0.5 + 0.5 * cos(PI * (u - v)))
	return MOGUL_HEIGHT * w * m

## Everything machines have shaped at (x, z): the features, which stand on the
## run, faded out at its edge where they are not walls of their own.
func _features(x: float, z: float) -> float:
	var d: float = -z
	var cx: float = centre_x(d)
	var hl: float = lateral_half_width(d)
	var a: float = x - cx
	var inside: float = 1.0 - smoothstep(0.85, 1.05, absf(a) / hl)
	return (rollers(d) + moguls(d, a)) * inside + tables(d, a) + boxes(d, a) \
		+ berm(d, a, hl) + halfpipe(d, a)

# ================================================================ the ground

## The relief at (x, z) without the fall line's steps: the features on a
## groomed run, a low ridge the groomer leaves along each edge, and beyond it
## the untouched snow, rising gently away from the run and rougher the further
## out.
func _relief(x: float, z: float) -> float:
	var d: float = -z
	var off: float = maxf(beyond_edge(x, z), 0.0)
	var h: float = 0.5 * smoothstep(0.0, 1.5, off) * (1.0 - smoothstep(2.5, 6.0, off))
	h += 0.06 * maxf(off - 6.0, 0.0)
	var wild: float = smoothstep(1.0, 8.0, off)
	h += _relief_noise.get_noise_2d(x, z) * 2.2 * wild
	h += _fine_noise.get_noise_2d(x, z) * 0.25 * wild
	var shaped: float = _features(x, z)
	# The piste itself is groomed, not glass — but the features are clean, and
	# so is the big jump from its inrun to the foot of its landing: at 25 m/s
	# a ripple of the piste's 1.5° threw a racer 20 m down the inrun.
	var calm: float = (1.0 - smoothstep(0.0, 0.3, absf(shaped))) * (1.0 - pipe_rise(d)) \
		* (1.0 - _window(d, BIG_LIP - 120.0, BIG_LANDING_END + 10.0, 10.0))
	h += _piste_noise.get_noise_2d(x, z) * 0.08 * (1.0 - wild) * calm
	h += shaped
	# The pads levelled for the buildings: the world height of each pad's
	# middle, eased back into the slope round it.
	for pad: Vector4 in _pads:
		var reach: float = pad.z + PAD_BLEND
		if absf(x - pad.x) > reach or absf(z - pad.y) > reach:
			continue
		var w: float = 1.0 - smoothstep(pad.z, reach, Vector2(x - pad.x, z - pad.y).length())
		if w > 0.0:
			h = lerpf(h, pad.w - _profile(d) - _base_tan * z, w)
	return h

## The ground's world height at (x, z): the relief, the fall line's steps and
## the analytic slope — what [HeightmapSurface.height_at] will answer.
func _ground(x: float, z: float) -> float:
	return _relief(x, z) + _profile(-z) + _base_tan * z

# ================================================================ buildings

## Stand each of [constant HOUSES] beside the run or where it says, facing the
## run and turned a little off square (a stream of its own, so the rest of the
## course does not move with it).
func _plan_houses() -> void:
	_houses.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 300
	for h: Dictionary in HOUSES:
		var id: String = h["id"]
		var d: float = h["d"]
		var scale: float = h.get("scale", 1.0)
		# Turned a quarter, its own Z runs across the slope: that is how far it
		# reaches toward the run.
		var reach: float = PropMesh.park_size(FURNITURE[id]["kind"]).z * 0.5 * scale
		var x: float = h["x"] if h.has("x") else _outside(d, h["side"], reach + PAD_SLACK)
		# Its front (+Z) toward the run.
		var yaw: float = (PI * 0.5 if x < centre_x(d) else -PI * 0.5) + rng.randf_range(-0.12, 0.12)
		_houses.push_back([id, x, -d, yaw, scale])

## How far round its middle a building's ground has to be level.
static func pad_radius(id: String, scale: float) -> float:
	return PropMesh.footprint(FURNITURE[id]["kind"]).length() * scale + PAD_SLACK

## Level a pad under every building and both lift stations, each at the height
## the slope had at its middle: cut in on the uphill side, built up below.
func _plan_pads() -> void:
	_pads.clear()
	_worn.clear()
	for house: Array in _houses:
		var r: float = pad_radius(house[0], house[4])
		_pads.push_back(Vector4(house[1], house[2], r, _ground(house[1], house[2])))
		if house[0] == "mountain_hut":
			_worn.push_back(Vector3(house[1], house[2], r))
	for d: float in [LIFT_TOP, LIFT_BOTTOM]:
		var at: Vector2 = station_pad(d)
		_pads.push_back(Vector4(at.x, at.y, STATION_PAD, _ground(at.x, at.y)))
		_worn.push_back(Vector3(at.x, at.y, STATION_PAD + 1.5))

## The middle of a lift station's pad, `(x, z)`: the station at [param d]
## metres down stands with its hut behind its bullwheel, away from the rest of
## the lift.
static func station_pad(d: float) -> Vector2:
	var toward: float = 1.0 if d > (LIFT_TOP + LIFT_BOTTOM) * 0.5 else -1.0
	return Vector2(LIFT_X, -d - toward * 0.5)

# ================================================================ the lift

## Stand the towers up the lift's line from the bottom station to the top one:
## spans of up to [constant TOWER_SPACING], each tower [constant TOWER_HEIGHT]
## tall or more where the cable would pass under [constant CABLE_CLEARANCE]
## over the ground between (the big jump's knuckle).
func _plan_lift() -> void:
	_towers.clear()
	var n: int = ceili((LIFT_BOTTOM - LIFT_TOP - 30.0) / TOWER_SPACING)
	var step: float = (LIFT_BOTTOM - LIFT_TOP - 30.0) / n
	for i: int in n:
		var d: float = LIFT_BOTTOM - 15.0 - step * i
		_towers.push_back(Vector3(LIFT_X, -d, TOWER_HEIGHT))
	_towers.push_back(Vector3(LIFT_X, -(LIFT_TOP + 15.0), TOWER_HEIGHT))
	for round_i: int in 6:
		for i: int in _towers.size() - 1:
			var lack: float = CABLE_CLEARANCE - _clearance(_towers[i], _towers[i + 1])
			if lack > 0.0:
				_towers[i].z = minf(_towers[i].z + lack, TOWER_MAX_HEIGHT)
				_towers[i + 1].z = minf(_towers[i + 1].z + lack, TOWER_MAX_HEIGHT)

## Where the cable passes over a tower, either line.
func _cable_point(tower: Vector3, side: float) -> Vector3:
	return Vector3(tower.x + side * PropMesh.LIFT_LINE_OFFSET,
		_ground(tower.x, tower.y) + tower.z * PropMesh.TOWER_CABLE_SHARE, tower.y)

## The least height of the cable over the ground between two towers.
func _clearance(a: Vector3, b: Vector3) -> float:
	var least: float = INF
	for side: float in [-1.0, 1.0]:
		var p: Vector3 = _cable_point(a, side)
		var q: Vector3 = _cable_point(b, side)
		for i: int in range(1, 40):
			var at: Vector3 = p.lerp(q, i / 40.0)
			least = minf(least, at.y - _ground(at.x, at.z))
	return least

## A station's bullwheel, where the cable turns: the station stands at
## [param d] metres down, its wheel toward the rest of the lift.
func _wheel_point(d: float, side: float) -> Vector3:
	var toward: float = 1.0 if d > (LIFT_TOP + LIFT_BOTTOM) * 0.5 else -1.0
	var x: float = LIFT_X + side * PropMesh.LIFT_LINE_OFFSET
	var z: float = -d + toward * PropMesh.STATION_WHEEL.z
	return Vector3(x, _ground(LIFT_X, -d) + PropMesh.STATION_WHEEL.y, z)

## The lift's two cables, each a chain of points from the bottom station's
## wheel over every tower to the top's: `[up line, down line]`.
func _cables() -> Array[PackedVector3Array]:
	var out: Array[PackedVector3Array] = []
	for side: float in [-1.0, 1.0]:
		var line := PackedVector3Array()
		line.push_back(_wheel_point(LIFT_BOTTOM, side))
		for t: Vector3 in _towers:
			line.push_back(_cable_point(t, side))
		line.push_back(_wheel_point(LIFT_TOP, side))
		out.push_back(line)
	return out

## The towers, the cable spans, the chairs and both stations, into [param out].
func _place_lift(out: Dictionary[String, Array]) -> void:
	for d: float in [LIFT_TOP, LIFT_BOTTOM]:
		# The bottom station's wheel faces up the hill (+Z), the top's down it.
		var yaw: float = 0.0 if d > (LIFT_TOP + LIFT_BOTTOM) * 0.5 else PI
		out["lift_station"].push_back([LIFT_X, -d,
			PropMesh.park_size(PropMesh.Kind.LIFT_STATION), yaw])
	for t: Vector3 in _towers:
		var size: Vector3 = PropMesh.park_size(PropMesh.Kind.LIFT_TOWER)
		out["lift_tower"].push_back([t.x, t.y, Vector3(size.x, t.z, size.z), 0.0])
	var lines: Array[PackedVector3Array] = _cables()
	var chair_size: Vector3 = PropMesh.park_size(PropMesh.Kind.LIFT_CHAIR)
	for l: int in lines.size():
		var line: PackedVector3Array = lines[l]
		# Riders on the up line (−X) face up the hill, +Z; the down line's
		# empty chairs face down it.
		var facing: float = 0.0 if l == 0 else PI
		var carried: float = CHAIR_SPACING * (0.5 if l == 0 else 0.0)
		for i: int in line.size() - 1:
			var a: Vector3 = line[i]
			var b: Vector3 = line[i + 1]
			var span: Vector3 = b - a
			_span(out["lift_cable"], a, b, Vector2(CABLE_THICKNESS, CABLE_THICKNESS))
			# Chairs along the span, kept off the towers' sheaves.
			var s: float = carried
			while s < span.length():
				if s > 2.0 and s < span.length() - 2.0:
					var at: Vector3 = a + span.normalized() * s
					out["lift_chair"].push_back([at.x, at.z, chair_size, facing,
						at.y - PropMesh.CHAIR_HANG - _ground(at.x, at.z), 0.0])
				s += CHAIR_SPACING
			carried = s - span.length()

## A length of something strung from [param a] to [param b] — a cable, a rail,
## a net — as a marker into [param into]: at its middle, that far over the
## ground, [param section] thick (Y, Z). Its +X runs from a to b: a yaw about
## Y, then a roll about its own Z lifts it toward b.
func _span(into: Array, a: Vector3, b: Vector3, section: Vector2) -> void:
	var span: Vector3 = b - a
	var mid: Vector3 = (a + b) * 0.5
	var yaw: float = atan2(-span.z, span.x)
	var roll: float = atan2(span.y, Vector2(span.x, span.z).length())
	into.push_back([mid.x, mid.z, Vector3(span.length(), section.x, section.y), yaw,
		mid.y - _ground(mid.x, mid.z), roll])

## Whether a footprint of radius [param r] at (x, z) is in the lift's clearing
## or on a station's pad.
static func _on_lift(x: float, z: float, r: float) -> bool:
	if absf(x - LIFT_X) < LIFT_CLEARING + r:
		return true
	return false

# ================================================================ assets

func _write_assets() -> void:
	var heights := PackedFloat32Array()
	heights.resize(_w * _h)
	var relief := PackedFloat32Array()
	relief.resize(_w * _h)
	for gy: int in _h:
		var z: float = -float(gy) * CELL
		var step: float = _profile(-z)
		for gx: int in _w:
			var x: float = float(gx) * CELL
			var r: float = _relief(x, z)
			relief[gy * _w + gx] = r
			heights[gy * _w + gx] = r + step
	var himg: Image = ETRImport.heights_to_image(heights, _w, _h)
	ResourceSaver.save(himg, OUT.path_join("heightmap.res"))
	# From the relief alone — see the notes at the top.
	var ao: Image = TerrainOcclusion.bake(relief, _w, _h, WORLD, 2)
	ResourceSaver.save(ao, OUT.path_join("ambient_occlusion.res"), ResourceSaver.FLAG_COMPRESS)

	var objects: Dictionary[String, Array] = _place_objects(_course_shape())
	var woods := _Woods.new(objects)
	var index := PackedByteArray()
	index.resize(_w * _h)
	for gy: int in _h:
		var z: float = -float(gy) * CELL
		for gx: int in _w:
			index[gy * _w + gx] = _material(float(gx) * CELL, z, woods)
	var share := PackedInt32Array()
	share.resize(LAYERS.size())
	for i: int in index.size():
		share[index[i]] += 1
	for l: int in LAYERS.size():
		print("  %s: %.1f %%" % [LAYERS[l], 100.0 * share[l] / index.size()])
	var maps: Array[Image] = CourseGenKit.splat_maps(index, _w, _h, LAYERS.size())
	for m: int in maps.size():
		var path: String = OUT.path_join("splat_%d.png" % m)
		maps[m].save_png(ProjectSettings.globalize_path(path))
		ETRImport.write_splat_import(path)
	var preview: String = ProjectSettings.globalize_path(OUT.path_join("preview.png"))
	if not FileAccess.file_exists(preview):
		_preview(index).save_png(preview)
	_write_prefabs()
	var lo: float = INF
	var hi: float = -INF
	for v: float in heights:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	print("  heightmap %dx%d, relief %.1f..%.1f m, base angle %.2f°, %d lift towers"
		% [_w, _h, lo, hi, base_angle(), _towers.size()])

## Which terrain (x, z) is: hard-packed snow on every feature, glazed ice on
## the boxes' tops and the big jump's take-off and landing packed hard too;
## the groomed run soft snow; beside it untouched snow, thinner under the
## trees, and worn round the lift's stations and towers and the restaurants.
func _material(x: float, z: float, woods: _Woods) -> int:
	var d: float = -z
	var cx: float = centre_x(d)
	var hl: float = lateral_half_width(d)
	var a: float = x - cx
	var edge: float = absf(a) / hl + _edge_noise.get_noise_2d(x, z) * 0.04
	if boxes(d, a) > BOX_HEIGHT * 0.6 and on_box_top(d, a):
		return L_BOX
	var shaped: float = tables(d, a) + boxes(d, a) + halfpipe(d, a) + berm(d, a, hl)
	if shaped > 0.15:
		return L_FEATURE
	if edge < 1.0:
		if d > BIG_LIP - 32.0 and d < BIG_LANDING_END:
			return L_FEATURE
		return L_SNOW
	for w: Vector3 in _worn:
		if Vector2(x - w.x, z - w.y).length() < w.z + _edge_noise.get_noise_2d(x, z) * 2.0:
			return L_WORN
	for t: Vector3 in _towers:
		if Vector2(x - t.x, z - t.y).length() < 2.2 + _edge_noise.get_noise_2d(x, z):
			return L_WORN
	if woods.at(x, z) + _edge_noise.get_noise_2d(x * 0.7, z * 0.7) * 0.3 > 0.35:
		return L_WOODS
	return L_SNOW

## How much the crowns cover each metre, for the thinner snow under them.
class _Woods:
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
			_disc(o[0], o[1], s.x * 0.8)

	func _disc(x: float, z: float, r: float) -> void:
		var cx: int = roundi(x / STEP)
		var cz: int = roundi(-z / STEP)
		var n: int = ceili(r / STEP)
		for gz: int in range(maxi(cz - n, 0), mini(cz + n, _gh - 1) + 1):
			for gx: int in range(maxi(cx - n, 0), mini(cx + n, _gw - 1) + 1):
				var q: float = Vector2(gx * STEP - x, -gz * STEP - z).length() / r
				if q < 1.0:
					_cover[gz * _gw + gx] += 1.0 - q * q

	func at(x: float, z: float) -> float:
		var gx: int = clampi(roundi(x / STEP), 0, _gw - 1)
		var gz: int = clampi(roundi(-z / STEP), 0, _gh - 1)
		return _cover[gz * _gw + gx]

## A map of the course for the menu until a real capture replaces it, turned
## to run left to right.
func _preview(index: PackedByteArray) -> Image:
	var colours: Array[Color] = [Color(0.93, 0.95, 1.0), Color(0.75, 0.82, 0.92),
		Color(0.3, 0.42, 0.3), Color(0.55, 0.75, 0.95), Color(0.6, 0.58, 0.55)]
	var img := Image.create_empty(PREVIEW_SIZE.x, PREVIEW_SIZE.y, false, Image.FORMAT_RGB8)
	for py: int in PREVIEW_SIZE.y:
		for px: int in PREVIEW_SIZE.x:
			var gy: int = clampi(int(float(px) / PREVIEW_SIZE.x * _h), 0, _h - 1)
			var gx: int = clampi(int(float(py) / PREVIEW_SIZE.y * _w), 0, _w - 1)
			img.set_pixel(px, py, colours[index[gy * _w + gx]])
	return img

## The park's furniture as prefabs in `res://resources/objects/`, overwritten
## each run like the other props.
func _write_prefabs() -> void:
	for id: String in FURNITURE:
		var spec: Dictionary = FURNITURE[id]
		var prefab := ObjectPrefab.new()
		prefab.id = StringName(id)
		prefab.mesh = PropMesh.build(spec["kind"], spec["seed"])
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/object_prop.gdshader")
		mat.set_shader_parameter("mottle", spec["mottle"])
		if spec.has("snow"):
			mat.set_shader_parameter("snow_cover", spec["snow"])
		prefab.material = mat
		prefab.collidable = spec["collidable"]
		prefab.decorative = not spec["collidable"]
		prefab.ground_aligned = spec["aligned"]
		ResourceSaver.save(prefab, "res://resources/objects/%s.tres" % id)

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
	var layers: Array[TerrainLayer] = []
	for id: String in LAYERS:
		layers.push_back(load("res://resources/terrain/%s.tres" % id))
	course.terrain_layers = layers
	var splats: Array[Texture2D] = []
	for m: int in 2:
		splats.push_back(load(OUT.path_join("splat_%d.png" % m)))
	course.splat_maps = splats
	course.splat_size = Vector2i(_w, _h)
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
	CourseGenKit.write_scene(DIR, OUT, objects)
	CourseGenKit.write_listing(DIR, OUT, course)

func _course_shape() -> CourseData:
	var course := CourseData.new()
	course.world_size = WORLD
	course.play_size = PLAY
	course.base_angle = base_angle()
	course.play_bounds = _corridor(true)
	course.trail_bounds = _corridor(false)
	return course

## The play area ([param play]) or the run itself — where the computer's
## opponents are held and the night's torches stand — as a polygon.
func _corridor(play: bool) -> PackedVector2Array:
	var edges: Array[PackedVector2Array] = _edges(play)
	var left: PackedVector2Array = edges[0]
	var right: PackedVector2Array = edges[1].duplicate()
	right.reverse()
	left.append_array(right)
	return left

## The two sides of [method _corridor], `[left, right]`, each top to bottom:
## the run widened by [method play_margin] either side for the play area, by
## nothing for the run. Built from the narrowest it gets within each piece, so
## a piece never cuts across a narrowing.
##
## The run's pieces are [constant TRAIL_STEP] long, because [CourseLights]
## stands one torch per 22 m of edge and a shorter piece gets none; a piece
## that long cuts across a slalom bend's inside, so each side is then pulled in
## until no piece leaves the run.
func _edges(play: bool) -> Array[PackedVector2Array]:
	var step: float = CORRIDOR_STEP if play else TRAIL_STEP
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var d: float = -1.0
	var last: float = WORLD.y - 1.0
	while true:
		var at: float = maxf(d, 0.0)
		var reach: float = INF
		var k: float = -step
		while k <= step:
			var there: float = maxf(at + k, 0.0)
			reach = minf(reach, lateral_half_width(there) + (play_margin(there) if play else 0.0))
			k += 1.0
		var reach_l: float = reach
		var reach_r: float = reach
		if play:
			reach_l = minf(reach_l, _short_of_houses(at, -1.0, step))
			reach_r = minf(reach_r, _short_of_houses(at, 1.0, step))
		left.push_back(Vector2(clampf(centre_x(at) - reach_l, PLAY_EDGE, WORLD.x - 1.0), -d))
		right.push_back(Vector2(clampf(centre_x(at) + reach_r, 1.0, LIFT_X - LIFT_CLEARING), -d))
		if d >= last:
			break
		d = minf(d + step, last)
	if not play:
		_hold_inside_run(left, -1.0)
		_hold_inside_run(right, 1.0)
	return [left, right]

## How far across from the run's middle at [param d] the play area may reach on
## [param side] and still keep every building's pad, plus [constant
## HOUSE_CLEARANCE], out of the pieces within [param step] of it. The buildings
## are not collidable: a play area reaching over one would let a racer through
## its walls.
func _short_of_houses(d: float, side: float, step: float) -> float:
	var reach: float = INF
	for house: Array in _houses:
		var r: float = pad_radius(house[0], house[4]) + HOUSE_CLEARANCE
		var k: float = -step
		while k <= step:
			var there: float = maxf(d + k, 0.0)
			var dz: float = absf(-there - house[2])
			var across: float = side * (house[1] - centre_x(there))
			if dz < r and across > 0.0:
				reach = minf(reach, across - sqrt(r * r - dz * dz))
			k += 1.0
	return reach

## Pull the run's edge on [param side] in wherever a straight piece of it
## passes outside the run, a few passes, since a moved vertex moves two pieces.
func _hold_inside_run(edge: PackedVector2Array, side: float) -> void:
	for pass_i: int in 6:
		for i: int in edge.size() - 1:
			var worst: float = 0.0
			for k: int in 23:
				var p: Vector2 = edge[i].lerp(edge[i + 1], k / 22.0)
				var d: float = maxf(-p.y, 0.0)
				var over: float = side * (p.x - centre_x(d)) - lateral_half_width(d)
				worst = maxf(worst, over)
			if worst > 0.0:
				edge[i] = edge[i] - Vector2(side * (worst + 0.05), 0.0)
				edge[i + 1] = edge[i + 1] - Vector2(side * (worst + 0.05), 0.0)

# ================================================================ objects

## Everything that stands on the course, as `{type: [[x, z, scale, yaw], …]}`;
## an entry held off the ground goes on with its height above it and its roll
## (a cable, a chair, a herring in the air).
func _place_objects(course: CourseData) -> Dictionary[String, Array]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 200
	var out: Dictionary[String, Array] = {}
	for t: String in ["start", "finish", "herring", "flag", "lift_station", "lift_tower",
			"lift_cable", "lift_chair", "mountain_hut", "chalet", "chalet_b", "shed", "fence_post",
			"fence_rail", "net_pole", "net_panel", "snowman", "igloo", "boulder", "tree", "shrub"]:
		out[t] = []
	var taken := CourseGenKit.Occupancy.new()
	var flat := HeightmapSurface.new()
	var zeros := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	flat.build(zeros, Vector2i(2, 2), WORLD, 0.0)
	for at: Vector3 in CourseLights.torch_positions(course, flat, null, []):
		taken.add(at.x, at.z, 3.0)

	out["start"].push_back([centre_x(10.0), -10.0, Vector3(12.0, 6.0, 12.0), 0.0])
	out["finish"].push_back([centre_x(PLAY.y), -PLAY.y, Vector3(14.0, 7.0, 14.0), 0.0])

	_place_lift(out)
	for d: float in [LIFT_TOP, LIFT_BOTTOM]:
		var at: Vector2 = station_pad(d)
		_reserve(taken, at.x, at.y, STATION_PAD + 1.0)
	for t: Array in out["lift_tower"]:
		taken.add(t[0], t[1], 2.0)
	# The buildings, each with a clearing round its pad.
	for house: Array in _houses:
		out[house[0]].push_back([house[1], house[2],
			PropMesh.park_size(FURNITURE[house[0]]["kind"]) * house[4], house[3]])
		# Wide enough that no crown reaches over a roof: a trunk keeps only its
		# own footprint clear.
		_reserve(taken, house[1], house[2], pad_radius(house[0], house[4]) + 6.0)
	_place_fences(out, taken)

	_place_herring(out["herring"])
	_place_flags(out["flag"])
	_place_snowmen(rng, out["snowman"], out["igloo"], taken)

	# A few boulders breaking the snow out in the woods.
	for i: int in 50:
		var diam: float = lerpf(1.2, 3.5, pow(rng.randf(), 1.6))
		var d: float = rng.randf_range(20.0, WORLD.y - 20.0)
		var side: float = -1.0 if rng.randf() < 0.5 else 1.0
		var x: float = centre_x(d) + side * (lateral_half_width(d) + woods_margin(d)
			+ PLAY_CLEARANCE + diam * 0.5 + rng.randf_range(2.0, 40.0))
		var yaw: float = rng.randf() * TAU
		if x > 2.0 and x < WORLD.x - 2.0 and not _on_lift(x, -d, diam * 0.5) \
				and taken.is_free(x, -d, diam * 0.5):
			out["boulder"].push_back([x, -d, Vector3(diam, diam * rng.randf_range(0.5, 0.8),
				diam), yaw])
			taken.add(x, -d, diam * 0.5)

	# The woods: a jittered grid, empty near the run and in the lift's
	# clearing, thickening further out, in stands where the noise says; none
	# above the treeline, thick along the catwalks, thinner in the village.
	var step: float = 4.2 / sqrt(maxf(FOREST_DENSITY, 0.01))
	var gz: float = 0.0
	while FOREST_DENSITY > 0.0 and gz < WORLD.y:
		var gx: float = 0.0
		while gx < WORLD.x:
			var x: float = gx + rng.randf_range(0.1, 0.9) * step
			var z: float = -(gz + rng.randf_range(0.1, 0.9) * step)
			var height: float = lerpf(5.0, 16.0, pow(rng.randf(), 0.8))
			var diam: float = height * rng.randf_range(0.34, 0.44)
			var off: float = beyond_edge(x, z) - woods_margin(-z)
			var keep: float = (0.2 + 0.9 * _density_noise.get_noise_2d(x, z)
				+ 0.4 * smoothstep(5.0, 30.0, off)) * smoothstep(TREELINE.x, TREELINE.y, -z) \
				* (1.0 - 0.5 * smoothstep(PLAY.y - 40.0, PLAY.y, -z)) \
				+ CATWALK_WOODS * fenced(-z) * (1.0 - smoothstep(0.0, 20.0, off))
			if rng.randf() < keep and off > PLAY_CLEARANCE + diam * 0.5 \
					and x > 1.0 and x < WORLD.x - 1.0 \
					and not _on_lift(x, z, diam * 0.3) and taken.is_free(x, z, diam * 0.3):
				out["tree"].push_back([x, z, Vector3(diam, height, diam), 0.0])
				taken.add(x, z, diam * 0.3)
			gx += step
		gz += step

	var d_s: float = 20.0
	while SHRUB_DENSITY > 0.0 and d_s < WORLD.y - 10.0:
		for side: float in [-1.0, 1.0]:
			if rng.randf() < 0.5:
				continue
			var height: float = rng.randf_range(0.7, 1.6)
			var s := Vector3(height * 1.2, height, height * 1.2)
			var x: float = centre_x(d_s) + side * (lateral_half_width(d_s) + woods_margin(d_s)
				+ PLAY_CLEARANCE + s.x * 0.5 + rng.randf_range(0.5, 10.0))
			if x > 1.0 and x < WORLD.x - 1.0 and not _on_lift(x, -d_s, s.x * 0.5) \
					and taken.is_free(x, -d_s, s.x * 0.45):
				out["shrub"].push_back([x, -d_s, s, 0.0])
				taken.add(x, -d_s, s.x * 0.45)
		d_s += rng.randf_range(6.0, 14.0) / SHRUB_DENSITY
	for t: String in out:
		print("  %s: %d" % [t, out[t].size()])
	return out

## Keep a disc of radius [param r] at (x, z) free of anything placed later,
## as discs a cell of [CourseGenKit.Occupancy] wide: one disc that wide is
## further than the grid looks round a later placement.
static func _reserve(taken: CourseGenKit.Occupancy, x: float, z: float, r: float) -> void:
	const STEP := 3.0
	var n: int = ceili(r / STEP)
	for i: int in range(-n, n + 1):
		for j: int in range(-n, n + 1):
			var o := Vector2(i * STEP, j * STEP)
			if o.length() <= r:
				taken.add(x + o.x, z + o.y, STEP)

## The fences: a wooden one either side along each of [constant FENCED] and
## round the finish area, and the orange nets either side of the big jump —
## each along the play area's edge, [constant FENCE_OUTSET] outside it, so it
## stands where a racer is stopped.
func _place_fences(out: Dictionary[String, Array], taken: CourseGenKit.Occupancy) -> void:
	var play: PackedVector2Array = _corridor(true)
	var edges: Array[PackedVector2Array] = _edges(true)
	var wooden: Array[Vector2] = []
	for r: Vector2 in FENCED:
		wooden.push_back(Vector2(r.x - MARGIN_EASE, r.y + MARGIN_EASE))
	wooden.push_back(Vector2(FINISH_FENCE.x - MARGIN_EASE, FINISH_FENCE.y))
	for side: int in 2:
		var sign_x: float = -1.0 if side == 0 else 1.0
		for r: Vector2 in wooden:
			var posts: PackedVector2Array = _along_edge(edges[side], play, sign_x, r, POST_SPACING)
			for p: Vector2 in posts:
				out["fence_post"].push_back([p.x, p.y, PropMesh.park_size(PropMesh.Kind.FENCE_POST),
					0.0])
				taken.add(p.x, p.y, 0.4)
			for i: int in posts.size() - 1:
				if posts[i].distance_to(posts[i + 1]) > POST_SPACING * 1.5:
					continue
				for h: float in PropMesh.RAIL_HEIGHTS:
					_span(out["fence_rail"], _post_top(posts[i], h), _post_top(posts[i + 1], h),
						Vector2(0.09, 0.06))
		var poles: PackedVector2Array = _along_edge(edges[side], play, sign_x,
			Vector2(NETS.x - MARGIN_EASE, NETS.y), POLE_SPACING)
		for p: Vector2 in poles:
			out["net_pole"].push_back([p.x, p.y, PropMesh.park_size(PropMesh.Kind.NET_POLE), 0.0])
			taken.add(p.x, p.y, 0.4)
		for i: int in poles.size() - 1:
			if poles[i].distance_to(poles[i + 1]) > POLE_SPACING * 1.5:
				continue
			_span(out["net_panel"], _post_top(poles[i], PropMesh.NET_MIDDLE),
				_post_top(poles[i + 1], PropMesh.NET_MIDDLE), Vector2(PropMesh.NET_HEIGHT, 0.03))

## (x, z) of a post, [param h] metres up from the ground there, in the world.
func _post_top(p: Vector2, h: float) -> Vector3:
	return Vector3(p.x, _ground(p.x, p.y) + h, p.y)

## Posts every [param spacing] metres along [param edge] (one side of the play
## area, top to bottom) while it is between [param span]'s metres down,
## [constant FENCE_OUTSET] out on [param side] (−1 left, +1 right). A post the
## outset left inside the play area, or right on its edge — where two pieces
## meet at a corner turned in — is left out.
static func _along_edge(edge: PackedVector2Array, play: PackedVector2Array, side: float,
		span: Vector2, spacing: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var carried: float = 0.0
	for i: int in edge.size() - 1:
		var a: Vector2 = edge[i]
		var piece: Vector2 = edge[i + 1] - a
		var length: float = piece.length()
		if length < 1e-4:
			continue
		var outward := Vector2(-piece.y, piece.x) / length
		if signf(outward.x) != side:
			outward = -outward
		var s: float = carried
		while s < length:
			var p: Vector2 = a + piece * (s / length) + outward * FENCE_OUTSET
			if -p.y >= span.x and -p.y <= span.y \
					and not CourseGenKit.near_polygon(p, play, FENCE_OUTSET * 0.6):
				out.push_back(p)
			s += spacing
		carried = s - length
	return out

## A herring at (x, −[param d]), [param lift] metres over the ground.
func _herring(into: Array, x: float, d: float, lift: float = 0.0) -> void:
	if lift > 0.0:
		into.push_back([x, -d, Vector3.ONE, 0.0, lift, 0.0])
	else:
		into.push_back([x, -d, Vector3.ONE, 0.0])

## The herring: lines down the plain stretches, a slalom of them down the
## summit face, one on every roller's crest, down the middle of every narrow
## way, arcs in the air over every table-top and the big jump, a row along
## every box's top, the berms' faces at each apex, up and down the half-pipe's
## walls, and a zipper line through the moguls.
func _place_herring(into: Array) -> void:
	for d: float in [30.0, 36.0, 42.0, 48.0, 54.0]:
		_herring(into, centre_x(d), d)
	for k: int in 4:
		var d: float = 78.0 + k * 14.0
		_herring(into, centre_x(d) + (8.0 if k % 2 == 0 else -8.0), d)
	# The narrow ways: on the middle, which the run's polygon never cuts.
	for r: Vector2 in FENCED:
		var d_f: float = r.x + 8.0
		while d_f < r.y - 4.0:
			_herring(into, centre_x(d_f), d_f)
			d_f += 18.0
	for d: float in [950.0, 958.0]:
		for side: float in [-1.0, 1.0]:
			_herring(into, centre_x(d) + side * 6.0, d)
	var crests: Array[float] = roller_crests()
	for k: int in crests.size():
		var d: float = crests[k]
		_herring(into, centre_x(d) + (4.0 if k % 2 == 0 else -4.0), d)
	for i: int in TABLES.size():
		var table: Vector2 = TABLES[i]
		var x: float = centre_x(table.x) + (TABLE_SPAN.x + TABLE_SPAN.y) * 0.5
		_arc(into, table.x, x, TABLE_LIP_SPEEDS[i], 0.0, TABLE_ARC_SHARE)
	for box: Vector3 in BOXES:
		for k: int in 3:
			var d: float = box.x + box.y * (k + 0.5) / 3.0
			_herring(into, centre_x(d) + box.z, d)
	for d: float in apexes():
		var outside: float = -signf(bend(d))
		_herring(into, centre_x(d) + outside * lateral_half_width(d) * 0.35, d)
	# The pipe's walls, a metre and a half up, swapping sides every 24 m.
	var wall: float = PIPE_FLOOR + sqrt(PIPE_RADIUS * PIPE_RADIUS
		- pow(PIPE_RADIUS - 1.5, 2.0))
	var side: float = -1.0
	var d_p: float = PIPE.x + PIPE_RISE + 12.0
	while d_p < PIPE.y - PIPE_FALL - 8.0:
		_herring(into, centre_x(d_p) + side * wall, d_p)
		side = -side
		d_p += 24.0
	var d_m: float = MOGULS.x + 15.0
	while d_m < MOGULS.y - 12.0:
		_herring(into, centre_x(d_m) + 2.0 * sin(d_m * 0.35), d_m)
		d_m += 9.0
	for d: float in [1300.0, 1314.0]:
		_herring(into, centre_x(d), d)
	for d: float in [BIG_LIP - 85.0, BIG_LIP - 75.0, BIG_LIP - 65.0]:
		_herring(into, centre_x(d), d)
	# The table's own slope, before the lip's ease starts to turn it over.
	_arc(into, BIG_LIP, centre_x(BIG_LIP), BIG_LIP_SPEED, BIG_LIP_EASE, BIG_ARC_SHARE)
	var d_o: float = BIG_LANDING_END + 35.0
	while d_o < PLAY.y - 30.0:
		_herring(into, centre_x(d_o) + 3.0 * sin(d_o * 0.07), d_o)
		d_o += 20.0

## Herring along the flight off a lip at [param lip_d] metres down, [param x]
## across: thrown at [param speed] along the slope the racer leaves on — the
## last 0.8 m before [param lip_d] − [param before] —, gravity only,
## one every few metres down while it is more than 1.2 m over the ground — each
## [param share] of the way up from the ground to the flight, so a racer
## slower than [param speed] still reaches the first few.
func _arc(into: Array, lip_d: float, x: float, speed: float, before: float,
		share: float) -> void:
	const G := 9.81
	var y0: float = _ground(x, -lip_d)
	# That slope, metres up per metre down (negative: it runs downhill).
	var slope: float = (_ground(x, -(lip_d - before)) - _ground(x, -(lip_d - before - 0.8))) / 0.8
	var vd: float = speed / sqrt(1.0 + slope * slope)
	var vy: float = vd * slope
	var spacing: float = clampf(speed * 0.25, 3.5, 7.0)
	var d: float = lip_d + spacing
	while true:
		var t: float = (d - lip_d) / vd
		var y: float = y0 + vy * t - 0.5 * G * t * t
		var above: float = y - _ground(x, -d)
		if above < 1.2:
			break
		# The item's middle stands half its height over its marker.
		_herring(into, x, d, maxf(above * share - 0.5, 0.1))
		d += spacing

## Gate flags: one just past the run's inside edge at each slalom turn, so
## the turn is round it whatever line is taken; a pair at the big jump's lip; and the landing hill's
## edges marked every 20 m.
func _place_flags(into: Array) -> void:
	var flag := Vector3(1.2, 1.6, 1.2)
	for d: float in apexes():
		var inside: float = signf(bend(d))
		into.push_back([centre_x(d) + inside * (lateral_half_width(d) + 0.8), -d, flag, 0.0])
	for side: float in [-1.0, 1.0]:
		into.push_back([centre_x(BIG_LIP) + side * (lateral_half_width(BIG_LIP) + 0.8),
			-BIG_LIP, flag, 0.0])
		var d: float = BIG_LIP + 20.0
		while d < BIG_LANDING_END:
			into.push_back([centre_x(d) + side * (lateral_half_width(d) + 0.8), -d, flag, 0.0])
			d += 20.0

## Snowmen beside the run at the start, at each feature's gate and round the
## finish, a big one beyond the finish line, and two igloos out on the meadow
## — all past the woods' edge, so a racer exploring can hit them.
func _place_snowmen(rng: RandomNumberGenerator, snowmen: Array, igloos: Array,
		taken: CourseGenKit.Occupancy) -> void:
	var size: Vector3 = PropMesh.park_size(PropMesh.Kind.SNOWMAN)
	var spots: Array[Vector2] = [Vector2(16.0, 1.0), Vector2(142.0, -1.0), Vector2(250.0, 1.0),
		Vector2(432.0, -1.0), Vector2(718.0, 1.0), Vector2(985.0, -1.0), Vector2(1180.0, 1.0),
		Vector2(1332.0, -1.0), Vector2(1468.0, 1.0), Vector2(1705.0, -1.0), Vector2(1817.0, 1.0)]
	for spot: Vector2 in spots:
		var d: float = spot.x
		var scale: float = rng.randf_range(0.8, 1.35)
		var x: float = _outside(d, spot.y, size.x * scale * 0.5 + 2.0)
		# Facing the run, turned a little toward the racers coming down.
		var yaw: float = (-PI * 0.5 if spot.y > 0.0 else PI * 0.5) + spot.y * 0.5
		snowmen.push_back([x, -d, size * scale, yaw])
		taken.add(x, -d, size.x * scale * 0.5)
	var d_big: float = PLAY.y + 18.0
	var x_big: float = _outside(d_big, 1.0, 4.0)
	snowmen.push_back([x_big, -d_big, size * 2.2, -PI * 0.5 + 0.6])
	taken.add(x_big, -d_big, 2.5)
	var igloo: Vector3 = PropMesh.park_size(PropMesh.Kind.IGLOO)
	for k: int in 2:
		var d: float = 948.0 + k * 9.0
		var x: float = _outside(d, -1.0, 3.5 + k * 6.0)
		igloos.push_back([x, -d, igloo * rng.randf_range(0.9, 1.1), rng.randf_range(0.8, 1.6)])
		taken.add(x, -d, 3.0)

## Across X, [param extra] metres beyond the woods' edge ([method
## woods_margin]) on [param side] at [param d] metres down: past the widest it
## reaches anywhere within two of the play area's pieces, bends included.
func _outside(d: float, side: float, extra: float) -> float:
	var reach: float = 0.0
	var k: float = -CORRIDOR_STEP * 2.0
	while k <= CORRIDOR_STEP * 2.0:
		var at: float = maxf(d + k, 0.0)
		reach = maxf(reach, side * (centre_x(at) - centre_x(d)) + lateral_half_width(at)
			+ woods_margin(at))
		k += 1.0
	return centre_x(d) + side * (reach + PLAY_CLEARANCE + extra)
