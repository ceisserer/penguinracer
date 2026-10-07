## The fidelity/speed knobs on the Configuration screen, and the five presets
## that set them all at once.
##
## Not ETR's: the original has one `perf_level` and a handful of detail toggles
## in `options.txt`. These are the desktop's additions measured against the
## frame they cost — the procedural sky, the 3D trees and their hand-over
## distances, the shadow map — plus the two knobs that were already here
## (render scale, ice reflections). See the 2026-09-25 entry in `PROGRESS.md`
## for what each one buys.
##
## A preset is not stored. [method matching] works out which one the current
## values are, so a hand-edited file or a row moved on the screen simply reads
## as "Custom", and there is no second copy of the truth to fall out of step.
## [constant Kind.HIGH] is exactly the frame the game shipped with before these
## knobs existed, and it is [GameConfig]'s default, so every reference capture
## still means what it meant.
##
## Plain [RefCounted] with no autoload names, so the tests can call it
## statically (see the trap list).
class_name QualityPreset
extends RefCounted

enum Kind { FASTEST, FAST, MEDIUM, HIGH, BEST }

## What [method matching] answers when the values are no preset's.
const CUSTOM := -1
## Each [enum Kind] as `--quality=` spells it.
const NAMES: PackedStringArray = ["fastest", "fast", "medium", "high", "best"]

## The anti-aliasing choices, in the order `[quality] antialiasing` names them.
const ANTIALIASING_NAMES: PackedStringArray = ["off", "2x", "4x"]
## The procedural sky's detail: how many octaves its clouds are built from, and
## whether its ridges are evaluated or read from [RidgeMap]'s bake.
const SKY_DETAIL_NAMES: PackedStringArray = ["low", "medium", "high"]
const SKY_DETAIL_HIGH := 2
## Which tree levels go into the sun's shadow map: none, the nearest mesh
## level, or every level down to the impostor.
const TREE_SHADOW_NAMES: PackedStringArray = ["off", "near", "all"]
const TREE_SHADOWS_ALL := 2
## Where the trees' shadows come from: the sun's shadow map, with
## [constant TREE_SHADOW_NAMES] saying which trees go into it, or baked into
## the terrain once per sun ([TreeShadowBake]) — softer, still while the trees
## sway, and free a frame. Compatibility has no shadow map to choose, and bakes
## whatever this says.
const TREE_SHADOW_KIND_NAMES: PackedStringArray = ["dynamic", "baked"]
const TREE_SHADOWS_DYNAMIC := 0
const TREE_SHADOWS_BAKED := 1
## The sun's shadow map: atlas size and cascade count.
const SHADOW_DETAIL_NAMES: PackedStringArray = ["low", "medium", "high", "best"]
## How the sun's shadow edge is filtered: Godot's [enum RenderingServer.ShadowQuality]
## up to Soft High, index for index. Ultra is left out — 64 taps a pixel for an
## edge Soft High already draws smooth.
const SHADOW_FILTER_NAMES: PackedStringArray = ["hard", "very_low", "low", "medium", "high"]
const SHADOW_FILTER_MEDIUM := 3

## The render scales the Configuration screen offers, and so the only ones a
## preset may use. The file still takes anything in 0.25..2.0.
const RENDER_SCALES: PackedFloat32Array = [0.25, 0.5, 0.75, 1.0]

## Range of `[quality] tree_detail`, a multiple of [constant Forest.LOD_ENDS].
const TREE_DETAIL_MIN := 0.5
const TREE_DETAIL_MAX := 1.5

## Every [GameConfig] property a preset sets, in the order the screen shows them.
const KEYS: PackedStringArray = ["render_scale", "antialiasing", "procedural_sky",
	"sky_detail", "tree_detail", "shadows", "tree_shadow_kind", "tree_shadows",
	"shadow_detail", "shadow_filter", "ice_reflections", "ice_world_reflections",
	"sun_shafts", "motion_blur", "prop_textures"]

## One row per [enum Kind]. HIGH must stay [GameConfig]'s defaults.
##
## Measured one knob at a time against HIGH on the iGPU (Mobile, Bunny Hill /
## `bronze_set`, ms a frame saved): a 2048 shadow atlas 1.1 / 0.6 (and 1.7 / 1.0
## with two splits), no tree shadows 1.5 / 0.2, no MSAA 0.7 / 0.8, low sky 0.6 /
## 0.6, trees at 0.5x 0.4 / 0.2; medium sky and 4096 in two splits next to
## nothing. The 8192 atlas costs 3.9 / 1.9, and a paired capture against 4096
## differs by a few hundred pixels in 230 000, so no preset uses it; it stays a
## row for a big GPU. The low end gives those up in that order, and render
## scale — the one knob that cuts every pixel's work — with them; at 0.6 the
## hand-overs are back near the old 22 / 45 / 75 m. BEST spends the headroom on
## edges and later hand-overs, short of the fog's end, past which a finer tree
## is invisible.
##
## The shadow filter is not in those numbers: it was added for phones, where
## its taps are paid per pixel on a GPU that has few to spare. Soft Medium is
## what `project.godot` shipped (see the trap list on its dither), so MEDIUM and
## up keep it; FAST takes Soft Low and its grain for the taps it saves, and
## FASTEST, which draws no shadow, names the cheapest.
##
## FAST bakes its tree shadows ([TreeShadowBake]): it had none, and baked ones
## cost the frame nothing — a vertex colour the terrain already carries — where
## even the nearest trees in the shadow map cost it the most of any knob.
##
## The ice's world reflection is off below HIGH. It costs nothing on a course
## without ice and ~5 ms a frame on the iGPU on one (`tuxway`, six faces every
## frame, most of it the sun's shadow cascades drawn again per face — see
## [IceEnvironment]), and a phone, which starts at MEDIUM, would pay for those
## at a rate nobody has measured yet.
##
## The sun's rays ([SunShafts]) are off below HIGH too. They cost nothing while
## the sun is out of shot, which is most of a run, and with it in shot ~1.3 ms
## under Mobile and ~1.1 ms under Compatibility on the iGPU (Forest Trail, the
## sun held in frame) — most of that the screen and depth copies, which a
## phone pays at a rate nobody has measured either.
##
## Motion blur ([MotionBlur]) is on only at BEST, so that HIGH, the shipped
## frame, stays the one every reference capture was taken of: the pass smears
## every frame the camera moves in. It costs the same copies as the rays plus
## ten taps a pixel while the camera moves, which is all of a run.
##
## The props' photographs ([member GameConfig.prop_textures]) are off at FAST
## and FASTEST: ~10 MB of GPU memory and, on the web, a download of their own,
## for what is mostly seen up close. MEDIUM, a phone's first run, keeps them.
const VALUES: Array[Dictionary] = [
	{ # FASTEST
		"render_scale": 0.5, "antialiasing": 0, "procedural_sky": false,
		"sky_detail": 0, "tree_detail": 0.5, "shadows": false,
		"tree_shadow_kind": TREE_SHADOWS_DYNAMIC, "tree_shadows": 0,
		"shadow_detail": 0, "shadow_filter": 0, "ice_reflections": false,
		"ice_world_reflections": false,
		"sun_shafts": false, "motion_blur": false, "prop_textures": false,
	},
	{ # FAST
		"render_scale": 0.75, "antialiasing": 0, "procedural_sky": true,
		"sky_detail": 0, "tree_detail": 0.6, "shadows": true,
		"tree_shadow_kind": TREE_SHADOWS_BAKED, "tree_shadows": 0,
		"shadow_detail": 0, "shadow_filter": 2, "ice_reflections": false,
		"ice_world_reflections": false,
		"sun_shafts": false, "motion_blur": false, "prop_textures": false,
	},
	{ # MEDIUM
		"render_scale": 1.0, "antialiasing": 1, "procedural_sky": true,
		"sky_detail": 0, "tree_detail": 0.8, "shadows": true,
		"tree_shadow_kind": TREE_SHADOWS_DYNAMIC, "tree_shadows": 1,
		"shadow_detail": 1, "shadow_filter": 3, "ice_reflections": true,
		"ice_world_reflections": false,
		"sun_shafts": false, "motion_blur": false, "prop_textures": true,
	},
	{ # HIGH — the shipped frame
		"render_scale": 1.0, "antialiasing": 1, "procedural_sky": true,
		"sky_detail": 2, "tree_detail": 1.0, "shadows": true,
		"tree_shadow_kind": TREE_SHADOWS_DYNAMIC, "tree_shadows": 2,
		"shadow_detail": 2, "shadow_filter": 3, "ice_reflections": true,
		"ice_world_reflections": true,
		"sun_shafts": true, "motion_blur": false, "prop_textures": true,
	},
	{ # BEST
		"render_scale": 1.0, "antialiasing": 2, "procedural_sky": true,
		"sky_detail": 2, "tree_detail": 1.2, "shadows": true,
		"tree_shadow_kind": TREE_SHADOWS_DYNAMIC, "tree_shadows": 2,
		"shadow_detail": 2, "shadow_filter": 3, "ice_reflections": true,
		"ice_world_reflections": true,
		"sun_shafts": true, "motion_blur": true, "prop_textures": true,
	},
]

## What the screen calls each [enum Kind]: a translation key from `i18n/ui.csv`,
## which the drop-down translates as it draws it.
static func label(kind: int) -> String:
	match kind:
		Kind.FASTEST: return "QUALITY_FASTEST"
		Kind.FAST: return "QUALITY_FAST"
		Kind.MEDIUM: return "QUALITY_MEDIUM"
		Kind.HIGH: return "QUALITY_HIGH"
		Kind.BEST: return "QUALITY_BEST"
	return "QUALITY_CUSTOM"

## Preset [param kind]'s values, keyed by [constant KEYS].
static func values_of(kind: int) -> Dictionary:
	return VALUES[kind].duplicate()

## The [constant KEYS] of [param config] (a [GameConfig], or anything with the
## same properties) as a [Dictionary] [method matching] can read.
static func of(config: Object) -> Dictionary:
	var out: Dictionary = {}
	for key: String in KEYS:
		out[key] = config.get(key)
	return out

## Write preset [param kind] onto [param config].
static func apply(kind: int, config: Object) -> void:
	var v: Dictionary = VALUES[kind]
	for key: String in KEYS:
		config.set(key, v[key])

## The [enum Kind] whose values are [param values], or [constant CUSTOM].
static func matching(values: Dictionary) -> int:
	for kind: int in VALUES.size():
		if _same(VALUES[kind], values):
			return kind
	return CUSTOM

static func _same(a: Dictionary, b: Dictionary) -> bool:
	for key: String in KEYS:
		if not b.has(key):
			return false
		if a[key] is float:
			if not is_equal_approx(float(a[key]), float(b[key])):
				return false
		elif a[key] != b[key]:
			return false
	return true

## `"4x"` → 2, and so on through [param names]; anything else keeps
## [param fallback], so a typo in a hand-edited file changes nothing.
static func parse(text: String, names: PackedStringArray, fallback: int) -> int:
	var i: int = names.find(text.strip_edges().to_lower())
	return i if i >= 0 else fallback

## [member Viewport.msaa_3d] for an `antialiasing` index.
static func msaa_for(antialiasing: int) -> Viewport.MSAA:
	match antialiasing:
		0: return Viewport.MSAA_DISABLED
		2: return Viewport.MSAA_4X
	return Viewport.MSAA_2X

## How many of a [Forest]'s levels cast a shadow for a `tree_shadows` index:
## none, the nearest mesh, or all of them. Most of the bill is the few trees
## close by, drawn at full detail into the finest cascades — the two nearest
## levels together cost as much as all four — so "near" keeps only LOD 0, the
## shadows a racer actually rides through.
static func tree_shadow_levels(tree_shadows: int) -> int:
	match tree_shadows:
		0: return 0
		1: return 1
	return 1 << 16

## `(atlas size, cascades)` of the sun's shadow map for a `shadow_detail`
## index. HIGH is Godot's default 4096 atlas and the four blended splits
## `race.tscn` ships. On an integrated GPU the atlas size is the lever — a
## 2048 atlas saves more than dropping to two splits does — so MEDIUM halves
## the atlas and LOW also halves the splits. BEST's 8192 atlas is 128 MB at
## 16 bits and costs several milliseconds: a big GPU's setting.
static func shadow_map_for(shadow_detail: int) -> Vector2i:
	match shadow_detail:
		0: return Vector2i(2048, 2)
		1: return Vector2i(2048, 4)
		3: return Vector2i(8192, 4)
	return Vector2i(4096, 4)

## [enum RenderingServer.ShadowQuality] for a `shadow_filter` index — the same
## number, named, so a caller cannot hand the renderer a value past Soft High.
static func shadow_filter_for(shadow_filter: int) -> RenderingServer.ShadowQuality:
	return clampi(shadow_filter, 0, SHADOW_FILTER_NAMES.size() - 1) \
		as RenderingServer.ShadowQuality
