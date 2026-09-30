## Generates **Forest Trail**, a course authored for this project rather than
## imported from ETR: a narrow snowy trail winding down through a conifer
## forest, forking in the middle into two branches that run apart through the
## trees and join again. A few patches of ice lie on it. The forest floor is
## conifer litter — a needle texture drawn here — with snow lying wherever the
## crowns leave a gap overhead, and boulders, stones, fallen logs and stumps on
## it.
##
##     tools/gen_forest_trail.sh
##
## which runs this twice with Godot's `--import` in between, as the importer
## does — the splat PNGs and the needle texture have to be imported before
## `course.tres` can hold them as textures:
##
##     godot --headless --path game --script res://addons/course_gen/gen_forest_trail.gd -- --stage=assets
##     godot --headless --path game --import
##     godot --headless --path game --script res://addons/course_gen/gen_forest_trail.gd -- --stage=resources
##
## The output has the importer's shape — `res://courses/forest_trail/` holds a
## float32 heightmap of local relief, the occlusion bake, splat maps over six
## terrain layers and a `course.tscn` of markers — so the race loads it like any
## other course. It is deterministic (fixed seeds, no clock) and re-runnable:
## both stages place the same objects, the first to lay the snow round them, the
## second to write them. `CourseData.imported_from` is empty and the listing's
## group is [constant CourseListing.AUTHORED_GROUP]: the ETR importer never
## visits the directory, and its catalog merge keeps the row.
##
## Two things here are not ETR's. The props are new object types (`boulder`,
## `stones`, `log`, `stump`): a [PropMesh] each, `object_prop.gdshader`,
## written to `res://resources/objects/` beside the imported prefabs. And the
## needle floor is a [TerrainLayer] of this course's own, `conifer_needles`,
## kept in the course's directory with its texture: `resources/terrain/` is
## `terrains.lst`'s, record for record.
extends SceneTree

const DIR := "forest_trail"
const OUT := "res://courses/forest_trail"
const PREVIEW_SIZE := Vector2i(192, 144)

const DISPLAY_NAME := "Forest Trail"
const AUTHOR := "PenguinRacer"
const DESCRIPTION := "A narrow snowy trail through a dark pine forest. Halfway down " \
	+ "it splits in two: pick a branch, they meet again further down. Stay on the " \
	+ "snow, the forest floor is full of rocks and fallen trees, and watch for ice."

## Course extent, metres: width along +X, length along -Z.
const WORLD := Vector2(120.0, 1600.0)
## Where the finish line is, and how wide the play area.
const PLAY := Vector2(110.0, 1500.0)
const ANGLE := 19.0
## Heightmap spacing: the importer's 2x upsample of ETR's ~1 m grid.
const CELL := 0.5
const SEED := 20260930

## How much stands on the course, each a multiplier of the shipped amount: 1 is
## Forest Trail as committed, 2 twice as many, 0.5 half, 0 none. Both stages
## read them — the snow is laid round the forest — so re-run the whole
## `tools/gen_forest_trail.sh` after changing one.
##
## The forest away from the trail: its grid spacing shrinks as 1/√density.
## Trees keep clear of each other, so past ~2 it fills up rather than doubling.
const FOREST_DENSITY := 0.2
## The tree line along both edges of the trail: its spacing along the trail.
const TREE_LINE_DENSITY := 0.5
## Bushes, in the forest and along the trail's edges.
const SHRUB_DENSITY := 1.0
## Tries at placing each prop; one that lands on the trail or on something
## already there is dropped, so a crowded forest takes fewer than asked.
const BOULDER_DENSITY := 1.0
const STONES_DENSITY := 2.0
const STUMP_DENSITY := 2.0
const LOG_DENSITY := 1.0

## Terrain layers, in splat order; the index is the channel. A path is a layer
## of this course's own; a bare id is one of `resources/terrain/`.
const LAYERS: Array[String] = ["snow", "icy_forest_floor", "ice1", "thin_snow",
	"conifer_needles", "dirt"]
const L_SNOW := 0
const L_EDGE := 1
const L_ICE := 2
const L_FOREST_SNOW := 3
const L_NEEDLES := 4
const L_DIRT := 5
## The needle floor: this course's own layer and the texture drawn for it.
const NEEDLES_LAYER := "res://courses/forest_trail/conifer_needles.tres"
const NEEDLES_TEXTURE := "res://courses/forest_trail/conifer_needles.png"
const NEEDLES_SIZE := 512

## The fork: the trail is one from the start to [constant SPLIT_START], two
## branches until [constant SPLIT_END], one again to the finish, and the
## branches part and meet over [constant SPLIT_RAMP].
const SPLIT_START := 540.0
const SPLIT_END := 1100.0
const SPLIT_RAMP := 110.0
## How far each branch runs from the middle once they have parted.
const SPLIT_SEPARATION := 18.0
const BRANCHES := 2

## `[distance down, branch]` of each kicker; branch -1 is wherever the trail is
## one. The one inside the fork is on the left branch only.
const KICKERS: Array[Vector2] = [Vector2(330.0, -1), Vector2(800.0, 0), Vector2(1250.0, -1)]
## How far the trail is kept straight at the top and bottom.
const STRAIGHT_START := 90.0
const STRAIGHT_END := 180.0

var _w: int
var _h: int
var _relief_noise := FastNoiseLite.new()
var _fine_noise := FastNoiseLite.new()
var _edge_noise := FastNoiseLite.new()
var _patch_noise := FastNoiseLite.new()
var _density_noise := FastNoiseLite.new()
## One per ice patch: `{d, branch, u (offset in half-widths), a, b (half-axes)}`.
var _ice: Array[Dictionary] = []

func _initialize() -> void:
	var stage: String = "assets"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--stage="):
			stage = a.trim_prefix("--stage=")
	_w = int(round(WORLD.x / CELL)) + 1
	_h = int(round(WORLD.y / CELL)) + 1
	_setup_noise()
	_plan_ice()
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
	print("forest_trail: stage '%s' done in %.1f s"
		% [stage, float(Time.get_ticks_msec() - start) / 1000.0])
	quit(0)

func _setup_noise() -> void:
	var all: Array[FastNoiseLite] = [_relief_noise, _fine_noise, _edge_noise, _patch_noise,
		_density_noise]
	for i: int in all.size():
		all[i].seed = SEED + i
		all[i].noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_relief_noise.frequency = 1.0 / 38.0
	_relief_noise.fractal_octaves = 3
	_fine_noise.frequency = 1.0 / 6.0
	_fine_noise.fractal_octaves = 2
	_edge_noise.frequency = 1.0 / 9.0
	_edge_noise.fractal_octaves = 2
	_patch_noise.frequency = 1.0 / 14.0
	_density_noise.frequency = 1.0 / 45.0

# ================================================================ the trail

## How far apart the branches are at [param d], 0 where the trail is one and 1
## where they run separately.
##
## Eased out of the fork and into the join, not smoothstepped: the branches
## leave each other at ~20° and are clear of each other within ~20 m. A slow
## start leaves them overlapping for half the ramp, one snowfield three
## trails wide.
static func split(d: float) -> float:
	var t: float = clampf(minf(d - SPLIT_START, SPLIT_END - d) / SPLIT_RAMP, 0.0, 1.0)
	return 1.0 - (1.0 - t) * (1.0 - t)

## The centre line of [param branch] as x at [param d] metres down from the
## start. Both branches are the same line outside the fork. Inside it the
## common line calms down and each branch wanders on its own.
static func centre_x(d: float, branch: int = 0) -> float:
	var amp: float = smoothstep(20.0, STRAIGHT_START, d) \
		* (1.0 - smoothstep(WORLD.y - STRAIGHT_END, WORLD.y - STRAIGHT_END + 70.0, d))
	var s: float = split(d)
	var main: float = WORLD.x * 0.5 + amp * (1.0 - 0.65 * s) * (
		15.0 * sin(TAU * d / 420.0 + 0.7)
		+ 4.5 * sin(TAU * d / 170.0 + 2.1)
		+ 0.8 * sin(TAU * d / 71.0 + 0.3))
	var own: float
	if branch == 0:
		own = -SPLIT_SEPARATION + 4.5 * sin(TAU * d / 125.0 + 0.4)
	else:
		own = SPLIT_SEPARATION + 3.5 * sin(TAU * d / 180.0 + 2.3)
	return main + s * own

## Half the width of [param branch], measured square to it: 8–12 m wide, a
## little narrower in the fork, wide at the gates where the banners stand.
static func half_width(d: float, branch: int = 0) -> float:
	var w: float = 4.9 + 1.0 * sin(TAU * d / 260.0 + 1.3) \
		+ 0.6 * sin(TAU * d / 97.0 + 1.7 * branch * split(d))
	w *= 1.0 - 0.12 * split(d)
	var ends: float = maxf(1.0 - smoothstep(30.0, 70.0, d),
		smoothstep(PLAY.y - 60.0, PLAY.y - 20.0, d))
	return lerpf(w, 10.0, ends)

## Half the width across X — wider than [method half_width] where the branch
## runs diagonally, so it is the same width to a racer on every bend.
static func lateral_half_width(d: float, branch: int = 0) -> float:
	var slope: float = centre_x(d + 0.5, branch) - centre_x(d - 0.5, branch)
	return half_width(d, branch) * sqrt(1.0 + slope * slope)

## How far outside the nearest trail edge (x, z) is, in metres across X:
## negative on the trail, either branch.
static func beyond_edge(x: float, z: float) -> float:
	var d: float = -z
	var out: float = INF
	for b: int in BRANCHES:
		out = minf(out, absf(x - centre_x(d, b)) - lateral_half_width(d, b))
	return out

## A kicker on [param branch]: a ramp up over 14 m, a lip, a drop over 4 m.
static func _kicker(d: float, branch: int) -> float:
	var h: float = 0.0
	for k: Vector2 in KICKERS:
		if k.y >= 0.0 and int(k.y) != branch:
			continue
		var t: float = d - k.x
		if t > -14.0 and t < 0.0:
			h = maxf(h, smoothstep(-14.0, 0.0, t))
		elif t >= 0.0 and t < 4.0:
			h = maxf(h, 1.0 - smoothstep(0.0, 4.0, t))
	return h * 1.4

## Ice every 80–150 m. In the fork the right branch gets more — the fast,
## slippery way — and the left has the kicker instead.
func _plan_ice() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 100
	var d: float = 160.0
	while d < PLAY.y - 120.0:
		var near_kicker: bool = false
		for k: Vector2 in KICKERS:
			near_kicker = near_kicker or absf(d - k.x) < 40.0
		var forked: bool = split(d) > 0.8
		for b: int in (BRANCHES if forked else 1):
			if b == 0 and (near_kicker or (forked and rng.randf() < 0.5)):
				continue
			var count: int = 2 if forked and b == 1 else 1
			for i: int in count:
				_ice.push_back({"d": d + i * 30.0, "branch": b,
					"u": rng.randf_range(-0.4, 0.4),
					"a": rng.randf_range(5.0, 10.0), "b": rng.randf_range(2.0, 3.8)})
		d += rng.randf_range(80.0, 150.0)

## Whether (x, z) is in a patch of ice, with a ragged edge.
func _on_ice(x: float, z: float) -> bool:
	var d: float = -z
	for spot: Dictionary in _ice:
		var sd: float = spot["d"]
		if absf(d - sd) > float(spot["a"]) + 2.0:
			continue
		var b: int = spot["branch"]
		var cx: float = centre_x(sd, b) + float(spot["u"]) * lateral_half_width(sd, b)
		var heading: float = centre_x(sd + 0.5, b) - centre_x(sd - 0.5, b)
		# Square to the trail's heading, so a patch lies along it.
		var along: Vector2 = Vector2(heading, 1.0).normalized()
		var off := Vector2(x - cx, d - sd)
		var ea: float = off.dot(along) / float(spot["a"])
		var eb: float = off.dot(Vector2(along.y, -along.x)) / float(spot["b"])
		if ea * ea + eb * eb + _edge_noise.get_noise_2d(x, z) * 0.35 < 1.0:
			return true
	return false

# ================================================================ assets

func _write_assets() -> void:
	var heights := PackedFloat32Array()
	heights.resize(_w * _h)
	# Per vertex: distance from the nearest branch's centre in its half-widths.
	var trail_e := PackedFloat32Array()
	trail_e.resize(_w * _h)
	var cx := PackedFloat32Array([0.0, 0.0])
	var hl := PackedFloat32Array([0.0, 0.0])
	var kick := PackedFloat32Array([0.0, 0.0])
	for gy: int in _h:
		var z: float = -float(gy) * CELL
		var d: float = -z
		for b: int in BRANCHES:
			cx[b] = centre_x(d, b)
			hl[b] = lateral_half_width(d, b)
			kick[b] = _kicker(d, b)
		for gx: int in _w:
			var x: float = float(gx) * CELL
			var e: float = INF
			var beyond: float = INF
			var on_trail: float = 0.0
			var jump: float = 0.0
			for b: int in BRANCHES:
				var across: float = absf(x - cx[b])
				var eb: float = across / hl[b]
				e = minf(e, eb)
				beyond = minf(beyond, across - hl[b])
				var on_b: float = 1.0 - smoothstep(0.8, 1.5, eb)
				on_trail = maxf(on_trail, on_b)
				jump = maxf(jump, kick[b] * on_b)
			# The trail runs in a shallow trough, and the forest climbs gently
			# away from it — its banks are what a racer carves against, and
			# the island between the branches is a low hill.
			var h: float = -0.9 * (1.0 - smoothstep(0.6, 1.7, e))
			h += clampf(beyond * 0.05, 0.0, 2.5)
			var rolling: float = _relief_noise.get_noise_2d(x, z) * 1.8
			h += rolling * lerpf(1.0, 0.3, on_trail)
			h += _fine_noise.get_noise_2d(x, z) * 0.3 * (1.0 - on_trail)
			h += jump
			heights[gy * _w + gx] = h
			trail_e[gy * _w + gx] = e

	var himg: Image = ETRImport.heights_to_image(heights, _w, _h)
	ResourceSaver.save(himg, OUT.path_join("heightmap.res"))
	var ao: Image = TerrainOcclusion.bake(heights, _w, _h, WORLD, 2)
	ResourceSaver.save(ao, OUT.path_join("ambient_occlusion.res"), ResourceSaver.FLAG_COMPRESS)

	# The forest decides where the snow lies, so it is planted before the
	# ground is painted — the same forest the resources stage writes.
	var canopy: _Canopy = _Canopy.new(_place_objects(_course_shape()))
	var index := PackedByteArray()
	index.resize(_w * _h)
	for gy: int in _h:
		var z: float = -float(gy) * CELL
		for gx: int in _w:
			var x: float = float(gx) * CELL
			index[gy * _w + gx] = _material(x, z, trail_e[gy * _w + gx], canopy)

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
	CourseGenKit.needle_texture(NEEDLES_SIZE, SEED + 300).save_png(ProjectSettings.globalize_path(NEEDLES_TEXTURE))
	# A map stands in until a capture of the course replaces it; a re-run
	# keeps whatever is there.
	var preview: String = ProjectSettings.globalize_path(OUT.path_join("preview.png"))
	if not FileAccess.file_exists(preview):
		_preview(index).save_png(preview)
	_write_prop_prefabs()
	print("  heightmap %dx%d, %d ice patches" % [_w, _h, _ice.size()])

## Which terrain (x, z) is: snow on the trail, snow-dusted litter along its
## edge, ice in the patches; in the forest, needle litter under the crowns and
## snow in the gaps between them, with a dusting where a crown only half
## covers the ground, and here and there bare earth.
func _material(x: float, z: float, e: float, canopy: _Canopy) -> int:
	var edge: float = e + _edge_noise.get_noise_2d(x, z) * 0.18
	if edge < 0.8 and _on_ice(x, z):
		return L_ICE
	if edge < 0.9:
		return L_SNOW
	if edge < 1.05:
		return L_EDGE
	var cover: float = canopy.at(x, z) + _patch_noise.get_noise_2d(x, z) * 0.3
	if cover < 0.12:
		return L_FOREST_SNOW
	if cover < 0.32:
		return L_EDGE
	return L_DIRT if _patch_noise.get_noise_2d(x * 1.7, z * 1.7) < -0.45 else L_NEEDLES

## How much sky the crowns take above each metre of the forest floor: the
## trees' crowns as soft discs, summed, a bush counting for less. Snow that
## falls through a gap lies; under a crown it never reaches the ground.
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

## A map of the course for the menu until a real capture replaces it: the
## trail in white, ice in blue, the forest dark. Turned so the course runs
## left to right, as a 4:3 thumbnail has room for.
func _preview(index: PackedByteArray) -> Image:
	var colours: Array[Color] = [Color(0.93, 0.95, 1.0), Color(0.62, 0.6, 0.55),
		Color(0.55, 0.75, 0.95), Color(0.85, 0.87, 0.9), Color(0.25, 0.18, 0.12),
		Color(0.2, 0.16, 0.1)]
	var img := Image.create_empty(PREVIEW_SIZE.x, PREVIEW_SIZE.y, false, Image.FORMAT_RGB8)
	for py: int in PREVIEW_SIZE.y:
		for px: int in PREVIEW_SIZE.x:
			var gy: int = clampi(int(float(px) / PREVIEW_SIZE.x * _h), 0, _h - 1)
			var gx: int = clampi(int(float(py) / PREVIEW_SIZE.y * _w), 0, _w - 1)
			img.set_pixel(px, py, colours[index[gy * _w + gx]])
	return img

# ================================================================ props

## The four prop prefabs. Built here, not by the ETR importer, which knows only
## `object_types.lst`.
const PROPS: Dictionary = {
	"boulder": {"kind": PropMesh.Kind.BOULDER, "collidable": true, "seed": 11},
	"stones": {"kind": PropMesh.Kind.STONES, "collidable": false, "seed": 23},
	"log": {"kind": PropMesh.Kind.LOG, "collidable": false, "seed": 37},
	"stump": {"kind": PropMesh.Kind.STUMP, "collidable": true, "seed": 41},
}

func _write_prop_prefabs() -> void:
	var shader: Shader = load("res://shaders/object_prop.gdshader")
	for id: String in PROPS:
		var spec: Dictionary = PROPS[id]
		var prefab := ObjectPrefab.new()
		prefab.id = StringName(id)
		prefab.mesh = PropMesh.build(spec["kind"], spec["seed"])
		var mat := ShaderMaterial.new()
		mat.shader = shader
		prefab.material = mat
		prefab.collidable = spec["collidable"]
		prefab.decorative = not spec["collidable"]
		prefab.ground_aligned = true
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
	_write_needles_layer()
	for id: String in LAYERS:
		layers.push_back(load(NEEDLES_LAYER) if id == "conifer_needles"
			else load("res://resources/terrain/%s.tres" % id))
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
	course.imported_from = ""
	ResourceSaver.save(course, OUT.path_join("course.tres"))

	var objects: Dictionary[String, Array] = _place_objects(course)
	CourseGenKit.write_scene(DIR, OUT, objects)
	CourseGenKit.write_listing(DIR, OUT, course)

## What object placement needs of the course — its size and its play area —
## so the assets stage can plant the forest before `course.tres` exists.
func _course_shape() -> CourseData:
	var course := CourseData.new()
	course.world_size = WORLD
	course.play_size = PLAY
	course.base_angle = ANGLE
	course.play_bounds = _corridor()
	return course

## The needle floor as this course's own [TerrainLayer] ([method
## CourseGenKit.needles_layer]).
func _write_needles_layer() -> void:
	ResourceSaver.save(CourseGenKit.needles_layer(load(NEEDLES_TEXTURE)), NEEDLES_LAYER)

## How far into the forest the play area reaches either side of the trail.
const CORRIDOR_MARGIN := 5.0
## Length of the corridor's straight pieces. At least [constant
## CourseLights.SPACING], so each piece of edge stands a torch at night.
const CORRIDOR_STEP := 24.0

## The play area: the trail and [constant CORRIDOR_MARGIN] of forest either
## side, down its left edge and back up its right. In the fork it spans both
## branches, the wooded island between them included: a polygon has no holes,
## and the island's trees are there to hit. [RacePhysics] keeps a racer
## inside it and [AIInputSource] plans inside it, so the forest's edge is there
## to crash into but nobody wanders off through the woods — and a computer
## opponent, which reads no terrain but friction, follows the bends.
func _corridor() -> PackedVector2Array:
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var d: float = -1.0
	var last: float = WORLD.y - 1.0
	while true:
		var at: float = maxf(d, 0.0)
		var lo: float = INF
		var hi: float = -INF
		for b: int in BRANCHES:
			var reach: float = lateral_half_width(at, b) + CORRIDOR_MARGIN
			lo = minf(lo, centre_x(at, b) - reach)
			hi = maxf(hi, centre_x(at, b) + reach)
		left.push_back(Vector2(clampf(lo, 1.0, WORLD.x - 1.0), -d))
		right.push_back(Vector2(clampf(hi, 1.0, WORLD.x - 1.0), -d))
		if d >= last:
			break
		d = minf(d + CORRIDOR_STEP, last)
	right.reverse()
	left.append_array(right)
	return left

## Radius kept clear round a torch's spot: enough that the widest conifer the
## forest grows is outside [constant CourseLights.TREE_CLEARANCE] of it.
const TORCH_CLEARING := 3.5

## Everything that stands on the course, as `{type: [[x, z, scale, yaw], …]}`.
## Props first, so the trees make room for them.
func _place_objects(course: CourseData) -> Dictionary[String, Array]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 200
	var out: Dictionary[String, Array] = {}
	for t: String in ["start", "finish", "herring", "boulder", "stones", "log", "stump",
			"tree", "shrub"]:
		out[t] = []
	var taken := CourseGenKit.Occupancy.new()

	# A clearing where each night torch will stand. [CourseLights] drops a
	# torch that has a tree within reach, and the corridor's edge runs through
	# the forest, so without these the trail would be dark.
	# Only where they stand matters here, not how high: a flat stand-in for the
	# ground, so both stages plant the same forest whether or not the
	# heightmap has been written yet.
	var flat := HeightmapSurface.new()
	var zeros := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	flat.build(zeros, Vector2i(2, 2), WORLD, 0.0)
	for at: Vector3 in CourseLights.torch_positions(course, flat, null, []):
		taken.add(at.x, at.z, TORCH_CLEARING)

	out["start"].push_back([centre_x(10.0), -10.0, Vector3(9.0, 6.0, 9.0), 0.0])
	out["finish"].push_back([centre_x(PLAY.y), -PLAY.y, Vector3(9.0, 6.0, 9.0), 0.0])

	# Herring in short lines that drift across the trail.
	var d: float = 70.0
	while d < PLAY.y - 40.0:
		var u0: float = rng.randf_range(-0.45, 0.45)
		var u1: float = clampf(u0 + rng.randf_range(-0.3, 0.3), -0.5, 0.5)
		var b: int = rng.randi() % BRANCHES
		for i: int in 5:
			var dd: float = d + i * 5.0
			var u: float = lerpf(u0, u1, i / 4.0)
			out["herring"].push_back([centre_x(dd, b) + u * lateral_half_width(dd, b), -dd,
				Vector3.ONE, 0.0])
		d += rng.randf_range(85.0, 135.0)

	# Props, denser near the trail where they are seen.
	var area: float = WORLD.x * WORLD.y
	_scatter(rng, out["boulder"], taken, int(area / 420.0 * BOULDER_DENSITY), 1.6,
		func() -> Vector3:
			var diam: float = lerpf(1.0, 3.4, pow(rng.randf(), 1.8))
			return Vector3(diam, diam * rng.randf_range(0.55, 0.85), diam))
	_scatter(rng, out["stones"], taken, int(area / 220.0 * STONES_DENSITY), 0.4,
		func() -> Vector3:
			var diam: float = rng.randf_range(0.8, 1.9)
			return Vector3(diam, diam * rng.randf_range(0.8, 1.2), diam))
	_scatter(rng, out["stump"], taken, int(area / 650.0 * STUMP_DENSITY), 1.2,
		func() -> Vector3:
			var diam: float = rng.randf_range(0.5, 0.95)
			return Vector3(diam, diam * rng.randf_range(0.6, 1.0), diam))
	_scatter_logs(rng, out["log"], taken, int(area / 600.0 * LOG_DENSITY))

	# A tree line along both edges of every branch, so the trail runs between
	# walls of trees rather than across a snowfield with a forest beside it.
	d = 15.0
	while TREE_LINE_DENSITY > 0.0 and d < WORLD.y - 5.0:
		for b: int in BRANCHES:
			if b == 1 and split(d) < 0.01:
				continue
			for side: float in [-1.0, 1.0]:
				if rng.randf() < 0.2:
					continue
				var height: float = lerpf(6.0, 14.0, pow(rng.randf(), 0.9))
				var diam: float = height * rng.randf_range(0.36, 0.46)
				var x: float = centre_x(d, b) + side * (lateral_half_width(d, b) + 0.4
					+ diam * 0.5 + rng.randf_range(0.0, 1.5))
				var z: float = -d - rng.randf_range(-1.0, 1.0)
				if x > 1.0 and x < WORLD.x - 1.0 \
						and beyond_edge(x, z) > 0.3 + diam * 0.5 \
						and taken.is_free(x, z, diam * 0.3):
					out["tree"].push_back([x, z, Vector3(diam, height, diam), 0.0])
					taken.add(x, z, diam * 0.3)
		d += rng.randf_range(3.5, 6.0) / TREE_LINE_DENSITY

	# The forest: a jittered grid of conifers, with clearings.
	var tree_step: float = 3.7 / sqrt(maxf(FOREST_DENSITY, 0.01))
	var gz: float = 0.0
	while FOREST_DENSITY > 0.0 and gz < WORLD.y:
		var gx: float = 0.0
		while gx < WORLD.x:
			var x: float = gx + rng.randf_range(0.1, 0.9) * tree_step
			var z: float = -(gz + rng.randf_range(0.1, 0.9) * tree_step)
			var height: float = lerpf(5.5, 14.0, pow(rng.randf(), 0.9))
			var diam: float = height * rng.randf_range(0.36, 0.46)
			var dense: float = _density_noise.get_noise_2d(x, z)
			if rng.randf() > 0.3 + dense \
					and beyond_edge(x, z) > 0.3 + diam * 0.5 \
					and taken.is_free(x, z, diam * 0.3):
				out["tree"].push_back([x, z, Vector3(diam, height, diam), 0.0])
				taken.add(x, z, diam * 0.3)
			gx += tree_step
		gz += tree_step

	# Bushes: under the trees, and a broken row along the trail's edges.
	var shrub_size := func() -> Vector3:
		var height: float = rng.randf_range(0.8, 2.2)
		var diam: float = height * rng.randf_range(1.0, 1.3)
		return Vector3(diam, height, diam)
	for i: int in int(area / 110.0 * SHRUB_DENSITY):
		var x: float = rng.randf_range(1.0, WORLD.x - 1.0)
		var z: float = -rng.randf_range(1.0, WORLD.y - 1.0)
		var s: Vector3 = shrub_size.call()
		if beyond_edge(x, z) > 0.4 + s.x * 0.5 and taken.is_free(x, z, s.x * 0.45):
			out["shrub"].push_back([x, z, s, 0.0])
			taken.add(x, z, s.x * 0.45)
	d = 30.0
	while SHRUB_DENSITY > 0.0 and d < WORLD.y - 10.0:
		for side: float in [-1.0, 1.0]:
			if rng.randf() < 0.45:
				continue
			var s: Vector3 = shrub_size.call()
			var b: int = rng.randi() % BRANCHES
			var x: float = centre_x(d, b) + side * (lateral_half_width(d, b)
				+ s.x * 0.5 + rng.randf_range(0.6, 2.5))
			if beyond_edge(x, -d) > 0.4 + s.x * 0.5 and taken.is_free(x, -d, s.x * 0.45):
				out["shrub"].push_back([x, -d, s, 0.0])
				taken.add(x, -d, s.x * 0.45)
		d += rng.randf_range(5.0, 11.0) / SHRUB_DENSITY
	for t: String in out:
		print("  %s: %d" % [t, out[t].size()])
	return out

## Scatter [param count] tries of a round prop, kept [param margin] m plus its
## own radius off the trail. Half the tries are drawn within 25 m of the edge.
func _scatter(rng: RandomNumberGenerator, into: Array, taken: CourseGenKit.Occupancy, count: int,
		margin: float, size: Callable) -> void:
	for i: int in count:
		var s: Vector3 = size.call()
		var r: float = s.x * 0.5
		var z: float = -rng.randf_range(5.0, WORLD.y - 5.0)
		var x: float
		if i % 2 == 0:
			var d: float = -z
			var side: float = -1.0 if rng.randf() < 0.5 else 1.0
			var b: int = rng.randi() % BRANCHES
			x = centre_x(d, b) + side * (lateral_half_width(d, b) + margin + r
				+ rng.randf_range(0.0, 25.0))
		else:
			x = rng.randf_range(2.0, WORLD.x - 2.0)
		if x < 1.0 or x > WORLD.x - 1.0:
			continue
		if beyond_edge(x, z) > margin + r and taken.is_free(x, z, r):
			into.push_back([x, z, s, rng.randf() * TAU])
			taken.add(x, z, r)

## Fallen logs, lying roughly across the fall line; both ends and the middle
## must be off the trail.
func _scatter_logs(rng: RandomNumberGenerator, into: Array, taken: CourseGenKit.Occupancy,
		count: int) -> void:
	for i: int in count:
		var length: float = rng.randf_range(2.5, 7.0)
		var thick: float = rng.randf_range(0.3, 0.6)
		var yaw: float = rng.randf_range(-0.6, 0.6) + (PI if rng.randf() < 0.5 else 0.0)
		var z: float = -rng.randf_range(5.0, WORLD.y - 5.0)
		var d: float = -z
		var x: float
		if i % 2 == 0:
			var side: float = -1.0 if rng.randf() < 0.5 else 1.0
			var b: int = rng.randi() % BRANCHES
			x = centre_x(d, b) + side * (lateral_half_width(d, b) + 1.5 + length * 0.5
				+ rng.randf_range(0.0, 20.0))
		else:
			x = rng.randf_range(4.0, WORLD.x - 4.0)
		# The marker's +X, turned by the yaw about +Y.
		var half := Vector2(cos(yaw), -sin(yaw)) * length * 0.5
		var ok: bool = true
		for t: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var px: float = x + half.x * t
			var pz: float = z + half.y * t
			ok = ok and px > 1.0 and px < WORLD.x - 1.0 and beyond_edge(px, pz) > 1.0 \
				and taken.is_free(px, pz, thick)
		if not ok:
			continue
		into.push_back([x, z, Vector3(length, thick, thick), yaw])
		for t: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			taken.add(x + half.x * t, z + half.y * t, thick)
