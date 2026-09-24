## The sky and the air: the procedural sky, the haze a distant slope fades
## into, the mist lying in the valley, and the ridges on the horizon.
##
## DEVIATION: ETR has three photographs on three quads and a flat linear fog of
## `[fogcol]` — white on 40 of the 44 courses. Here the sky is drawn
## (`shaders/procedural_sky.gdshader`), and the air in front of a distant slope
## takes the colour of the sky along the horizon in that direction, glow round
## the sun included, fading at the far end into whatever stands behind it. Most
## of it lives in `shaders/atmosphere.gdshaderinc`, which the sky and every lit
## surface include; this class owns the global uniforms that file reads.
##
## [b]Why the mountains are not meshes.[/b] The race keeps ETR's fog range
## (40–150 m), which fogs terrain out completely long before it reaches the
## horizon. A fully fogged slope has to turn into *some* colour, and whatever it
## turns into is a shape cut out of the backdrop unless that colour is the
## backdrop's own. So the ridges are a function of direction, evaluated by the
## sky for the pixels it owns and by the fog for the pixels a far slope owns —
## a mesh backdrop would have a flat-fogged hillside painted across its foot.
## They are three layers of ridged noise, each hazed by its distance and misted
## where it meets the valley, and seeded per course.
##
## [b]Presentation only.[/b] Nothing here reaches [RacePhysics], and nothing in
## it runs on the simulation's clock: [member atmo_time] advances with the frame,
## which under `--fixed-fps` is still reproducible.
##
## `[display] sky = etr` in the settings file ([member GameConfig.procedural_sky])
## turns all of it off: the migrated skybox, the flat fog, no mist, no ridges.
class_name Atmosphere
extends RefCounted

## Where the moon is drawn at night.
##
## DEVIATION: not the light's direction. ETR's night light is `[pos] 1 1 1` —
## up and *behind* a racer heading down -Z — and a chase camera looking down
## the fall line sees about 25 degrees above the horizon at most, so a moon
## placed where the light comes from would never be in shot. It stands ahead and
## to the right instead, 9 degrees up — above the dipped horizon
## ([method horizon_dip]), like the rest of the sky. Nothing casts a shadow under a night sky
## (ETR's rule, [member EnvironmentPreset.casts_shadows]), which is what makes
## the two directions impossible to tell apart on the snow.
const MOON_DIRECTION := Vector3(0.40, 0.16, -0.90)

## How far below the lowest point of the course the mist settles, and how fast
## it thins with height, in metres. A falloff of 16 m puts a racer at the top
## of a 200 m descent in clear air looking down into it, and one at the finish
## inside its thin upper edge.
const MIST_BELOW_COURSE := 4.0
const MIST_FALLOFF := 16.0
## Extinction per metre at the mist's base. At the finish of a typical course
## a slope 150 m away is about half gone.
const MIST_DENSITY := 0.009

## What changes with the time of day. Keyed by [LightCondition]'s names, and
## found off the preset's id the same way [method LightCondition.location_of]
## finds the location, so an authored preset with no light in its id is day.
##
## - `cover`: cloud cover, 0 clear to 1 overcast.
## - `disc`: how much of the sun's disc shows through it.
## - `glow`: the disc's colour in the air round it, linear.
## - `night`: stars, the moon and the aurora, 0 or 1.
## - `mist`: how much of [constant MIST_DENSITY] this sky has, and — through
##   [method valley_mist] — how thickly it lies at the foot of the ridges.
##   Light on the clear skies: mist greys everything it lies over, and a sunny
##   or moonlit day reads by its colour.
## - `ridge_light`: how strongly the disc lights the ridges' faces.
## - `ridge_haze`: how far the air between here and the ridges fades them to
##   the horizon's colour. Clear air carries further.
## - `blue`: how far the gradient is turned toward a clear sky's blue
##   ([constant SKY_BLUE_ZENITH], [constant SKY_BLUE_HORIZON]), keeping the
##   migrated brightness. Those colours are averages over photographs that are
##   half mountain, so drawn unaltered they are the grey of a mountainside;
##   0 is the data.
## - `zenith_lift`: how much brighter than its migrated average the zenith is.
const LOOKS: Dictionary[String, Dictionary] = {
	"sunny": {"cover": 0.3, "disc": 1.0, "glow": Color(0.95, 0.84, 0.66),
		"night": 0.0, "mist": 0.35, "ridge_light": 1.5,
		"ridge_haze": 0.55, "blue": 0.85, "zenith_lift": 1.8},
	"cloudy": {"cover": 0.93, "disc": 0.15, "glow": Color(0.22, 0.22, 0.23),
		"night": 0.0, "mist": 1.6, "ridge_light": 1.2,
		"ridge_haze": 1.0, "blue": 0.0, "zenith_lift": 1.0},
	"evening": {"cover": 0.4, "disc": 1.0, "glow": Color(1.0, 0.5, 0.24),
		"night": 0.0, "mist": 0.8, "ridge_light": 1.5,
		"ridge_haze": 0.85, "blue": 0.2, "zenith_lift": 1.0},
	"night": {"cover": 0.2, "disc": 0.0, "glow": Color(0.16, 0.19, 0.27),
		"night": 1.0, "mist": 0.3, "ridge_light": 3.5,
		"ridge_haze": 0.7, "blue": 0.5, "zenith_lift": 1.0},
}

## The hue a clear sky is turned toward, linear, at the zenith and along the
## horizon. Only the hue is used: [method toward_blue] keeps the migrated
## brightness.
const SKY_BLUE_ZENITH := Color(0.10, 0.25, 0.70)
const SKY_BLUE_HORIZON := Color(0.45, 0.60, 0.85)

## The parameters the sky shader reads, in `atmo_time` seconds.
var atmo_time: float = 0.0
var _sky_material: ShaderMaterial
## `atmo_ridges` as last applied, and the valley floor its drop is measured
## from; the drop is the one part that moves with the camera.
var _ridges := Vector4(0.0, 1.0, 1.0, 0.0)
var _valley_floor: float = 0.0
## Where the cloud decks have drifted to, and how fast they are going.
var _cloud_offset := Vector2.ZERO
var _cloud_velocity := CALM_DRIFT

## Sky units a second the lower cloud deck moves: on a calm day, slowly toward
## the valley; in a wind, at [constant CLOUD_SPEED] downwind of it.
const CALM_DRIFT := Vector2(0.004, -0.012)
const CLOUD_SPEED := 0.02

## How far off the ridges are, in metres, for the one thing that distance
## decides: how much lower they look from higher up. 4 km puts them 3 degrees
## down from the top of a 200 m course.
const RIDGE_DISTANCE := 4000.0
## The most the drop may take, as a tangent (about 4 degrees). A long course
## starts 700 m above its finish, and ranges of real mountains do not sink out
## of sight over one ski run — nor should the skyline over one race.
const MAX_RIDGE_DROP := 0.07

## How much of a course's slope the backdrop's horizon is lowered by
## ([method horizon_dip]), and the most it may be lowered, in degrees.
const DIP_OF_SLOPE := 0.7
const MAX_DIP_DEGREES := 30.0

## Which [constant LOOKS] entry [param preset] is under.
static func light_name(preset: EnvironmentPreset) -> String:
	var id: String = String(preset.id) if preset != null else ""
	for light: String in LightCondition.ALL_NAMES:
		if id.ends_with("_%s" % light):
			return light
	return "sunny"

## The look for [param preset].
static func look_for(preset: EnvironmentPreset) -> Dictionary:
	return LOOKS[light_name(preset)]

## Where the lowest part of [param course] is, in world metres — the valley
## floor the mist settles toward. The heightmap stores local relief over an
## analytic slope, so the far edge of the grid is the bottom.
static func valley_floor(course: CourseData, surface: SurfaceProvider) -> float:
	if course == null or surface == null:
		return 0.0
	var z: float = -course.world_size.y + 1.0
	var lowest: float = INF
	for i: int in range(5):
		var x: float = course.world_size.x * (0.1 + 0.2 * float(i))
		lowest = minf(lowest, surface.height_at(x, z))
	return lowest

## A seed for the ridges, from the course's name, so every course has its own
## skyline and the same one every time.
static func ridge_seed(course: CourseData) -> float:
	if course == null:
		return 0.0
	return float(hash(course.display_name) & 0xffff) / 655.36

## How far below the true horizon [param course]'s backdrop horizon sits, as a
## tangent — `atmo_dip`.
##
## DEVIATION, and a cheat. A chase camera on anything steeper than about 21
## degrees sits at its [constant ChaseCamera.MAX_PITCH_DEGREES] clamp, 40
## degrees down with 35 either side of that, so the top of the frame is 5
## degrees *below* the horizon: a sky drawn where the sky is is never in shot,
## and ridges on the true horizon fill every pixel the terrain leaves. ETR's
## photographs hid this because their lower halves are a sunlit mountainside.
## Here the whole backdrop — gradient, sun, clouds, ridges — is lowered to
## just above where the fall line meets the fog, so a racer sees the ridges
## rise off the far end of the course and open sky over them.
static func horizon_dip(course: CourseData) -> float:
	if course == null:
		return 0.0
	return tan(deg_to_rad(clampf(course.base_angle * DIP_OF_SLOPE, 0.0, MAX_DIP_DEGREES)))

## Every global uniform `atmosphere.gdshaderinc` reads, for [param preset]
## under a fog from [param fog_begin] to [param fog_end] metres (or none, if
## [param fog_on] is false), over a valley floor at [param valley] metres, with
## ridges seeded by [param seed] and the backdrop's horizon [param dip] below
## the true one ([method horizon_dip]). [param procedural] false is ETR's sky:
## flat `[fogcol]`, no mist, no ridges, no dip. `atmo_time` and the torches are not here —
## they move every frame.
##
## Pure, so the headless suite can hold it: the renderer it would otherwise
## have to read the globals back from is a dummy there.
static func globals_for(preset: EnvironmentPreset, fog_begin: float, fog_end: float,
		fog_on: bool, valley: float, seed: float, procedural: bool,
		dip: float = 0.0) -> Dictionary:
	var look: Dictionary = look_for(preset)
	var colours: Dictionary = sky_colours(preset)
	var zenith: Color = colours["zenith"]
	var horizon: Color = colours["horizon"]
	var night: float = float(look["night"])
	var glow: Color = look["glow"]
	var disc_dir: Vector3 = MOON_DIRECTION.normalized() if night > 0.0 \
		else preset.sun_direction.normalized()
	# Mist: lit like the horizon, and paler than it by day, as a cloud is.
	var mist_colour: Color = horizon.lerp(Color(0.92, 0.94, 0.97), 0.25 * (1.0 - night))
	var g: Dictionary = {
		"atmo_sun_dir": disc_dir,
		"atmo_sun_color": _vec(glow),
		"atmo_zenith": _vec(zenith),
		"atmo_horizon": _vec(horizon),
		"atmo_ground": _vec(colours["ground"]),
		"atmo_fog_color": _vec(preset.fog_color.srgb_to_linear()),
		"atmo_night": night,
		"atmo_mist_color": _vec(mist_colour),
		"atmo_valley_mist": valley_mist(look) if procedural else 0.0,
	}
	if procedural:
		var density: float = MIST_DENSITY * float(look["mist"]) if fog_on else 0.0
		g["atmo_fog"] = Vector4(fog_begin, fog_end, 1.0, 1.0)
		g["atmo_mist"] = Vector4(valley - MIST_BELOW_COURSE, MIST_FALLOFF, density, fog_begin)
		g["atmo_ridges"] = Vector4(seed, float(look["ridge_light"]), float(look["ridge_haze"]), 0.0)
		g["atmo_dip"] = dip
	else:
		g["atmo_fog"] = Vector4(fog_begin, fog_end, 0.0, 0.0)
		g["atmo_mist"] = Vector4(0.0, MIST_FALLOFF, 0.0, 0.0)
		g["atmo_ridges"] = Vector4(0.0, 1.0, 1.0, 0.0)
		g["atmo_dip"] = 0.0
	return g

## The gradient the procedural sky is drawn from, linear: the migrated faces'
## averages, made as blue as [constant LOOKS] says.
static func sky_colours(preset: EnvironmentPreset) -> Dictionary:
	var look: Dictionary = look_for(preset)
	var blue: float = float(look["blue"])
	return {
		"zenith": toward_blue(preset.sky_zenith_color.srgb_to_linear(), SKY_BLUE_ZENITH,
			blue, float(look["zenith_lift"])),
		"horizon": toward_blue(preset.sky_horizon_color.srgb_to_linear(), SKY_BLUE_HORIZON,
			blue, 1.0),
		"ground": preset.sky_nadir_color.srgb_to_linear(),
	}

## Put [param preset]'s sky on [param env] and point every shader in the frame
## at it. [param env] has to have had its fog range set already —
## [method GameConfig.apply_fog] — because the shaders' copy is read off it.
func apply(env: Environment, preset: EnvironmentPreset, course: CourseData,
		surface: SurfaceProvider, procedural: bool) -> void:
	_valley_floor = valley_floor(course, surface)
	var g: Dictionary = globals_for(preset, env.fog_depth_begin, env.fog_depth_end,
		env.fog_enabled, _valley_floor, ridge_seed(course), procedural, horizon_dip(course))
	for name: String in g:
		_global(name, g[name])
	_ridges = g["atmo_ridges"]
	if not procedural:
		_sky_material = null
		return
	var colours: Dictionary = sky_colours(preset)
	env.sky = _build_sky(look_for(preset), colours["zenith"], colours["horizon"])
	# The sky is the backdrop the fog fades *to*; fogging it as well would lay
	# the flat colour back over the ridges.
	env.fog_sky_affect = 0.0
	# What the engine's own fog fades to on the few materials that do not write
	# `FOG` themselves — the characters, the spray, the falling snow. The
	# horizon, which is what the shaders' haze is along the ground.
	env.fog_light_color = (colours["horizon"] as Color).linear_to_srgb()

## Advance the clouds, the stars' twinkle and the aurora by [param delta], and
## lower the ridges for a camera at height [param camera_y]. The clouds move
## toward [param downwind] (horizontal; zero is a calm day's slow drift).
func advance(delta: float, camera_y: float, downwind: Vector2 = Vector2.ZERO) -> void:
	atmo_time += delta
	_global("atmo_time", atmo_time)
	var drop: float = clampf((camera_y - _valley_floor) / RIDGE_DISTANCE, 0.0, MAX_RIDGE_DROP)
	if not is_equal_approx(drop, _ridges.w):
		_ridges.w = drop
		_global("atmo_ridges", _ridges)
	if _sky_material == null:
		return
	# Accumulated rather than `direction * time`, so a wind that swings round
	# turns the clouds' course instead of teleporting every one of them. And
	# the course eases round: a gust is not the sky's business.
	var wanted: Vector2 = CALM_DRIFT if downwind.length_squared() < 1e-6 \
		else downwind.normalized() * CLOUD_SPEED
	_cloud_velocity = _cloud_velocity.lerp(wanted, clampf(delta * 0.2, 0.0, 1.0))
	_cloud_offset += _cloud_velocity * delta
	_sky_material.set_shader_parameter("cloud_offset", _cloud_offset)

func _build_sky(look: Dictionary, zenith: Color, horizon: Color) -> Sky:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/procedural_sky.gdshader")
	mat.set_shader_parameter("cloud_cover", float(look["cover"]))
	mat.set_shader_parameter("sun_disc", float(look["disc"]))
	var glow: Color = look["glow"]
	# Clouds are lit by the horizon's light plus the disc's, and shaded by the
	# sky above them — so a night's clouds are night-dark without a case.
	mat.set_shader_parameter("cloud_lit", _vec(horizon) * 1.3 + _vec(glow) * 0.35)
	mat.set_shader_parameter("cloud_shade", _vec(zenith.lerp(horizon, 0.6)) * 0.85)
	_sky_material = mat
	var sky := Sky.new()
	sky.sky_material = mat
	# Nothing reads the radiance map (the ambient is `[amb]`, reflections are
	# off), so the smallest there is.
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	return sky

## [param c] turned [param amount] of the way toward the hue of [param blue],
## at [param c]'s own luminance times [param lift].
static func toward_blue(c: Color, blue: Color, amount: float, lift: float) -> Color:
	var target: Color = blue * (_luminance(c) / _luminance(blue)) * lift
	var out: Color = c.lerp(target, amount)
	out.a = 1.0
	return out

static func _luminance(c: Color) -> float:
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722

## How thickly mist lies at the foot of each range, 0..1, for [param look].
static func valley_mist(look: Dictionary) -> float:
	return clampf(0.1 + 0.9 * float(look["mist"]), 0.0, 1.0)

static func _vec(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

static func _global(name: StringName, value: Variant) -> void:
	RenderingServer.global_shader_parameter_set(name, value)
