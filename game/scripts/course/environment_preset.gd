## Per-environment, per-time-of-day lighting, migrated from `env/<env>/<light>/light.lst`.
##
## The original drove four fixed-function GL lights and linear fog. Under a PBR
## renderer that becomes one directional sun plus ambient, so the extra lights
## are folded into the ambient and specular terms rather than dropped: their
## contribution is what made ETR's evening and night courses read.
@tool
class_name EnvironmentPreset
extends Resource

## The one preset whose two gains were measured against a reference capture of
## the original, and the surface they were measured on: `tuxracer_sunny`'s
## assembled `[amb]`, i.e. Bunny Hill's shaded bank. Both sunny presets carry
## these verbatim; the other six are derived from them by
## [method derive_ambient_gain] and [method derive_sun_gain]. See history §22
## for the fit and the trap list for why it is a `Color` and not a scalar.
const FIT_AMBIENT := Color(0.7025, 0.78249997, 1.0)
const FIT_AMBIENT_GAIN := Color(0.841, 0.905, 0.980)
const FIT_SUN_GAIN := Color(1.95, 1.95, 1.95)

## `shaders/terrain.gdshader`'s `wrap_amount`, which is the one number the sun
## derivation has to share with the shader: snow is shaded at
## `((N·L + wrap) / (1 + wrap))²` rather than at N·L, so the angle a gain places
## the clamp at depends on it. [TestEnvironments] asserts the two still agree.
const SNOW_WRAP := 0.2

@export var id: StringName = &""
@export var sun_direction: Vector3 = Vector3(1, 1, 0).normalized()
## `[diff]` of light 0, verbatim. **This is a display-space multiplier**, not an
## sRGB colour — see [method apply_sun] for why that distinction is the whole
## difference between blue snow and white snow.
@export var sun_color: Color = Color.WHITE
## `[amb]` of light 0 plus the GL light-model floor plus the fill light, as the
## importer assembled it. Display-space, exactly like [member sun_color].
@export var ambient_color: Color = Color(0.45, 0.53, 0.75)

## DEVIATION: not migrated. Where [member ambient_gain] places the shaded end of
## the range, this sets *how steeply the sun climbs to the ceiling* — and since
## `shaders/terrain.gdshader` reproduces ETR's illumination clamp, it has a
## derived answer rather than a fitted one.
##
## ETR saturates red at `0.2 + 0.45 + 1.0 * ndl >= 1`, i.e. at `ndl = 0.35`.
## Here the same fragment has `ambient_illumination().r + sun * shaped >= 1`,
## with the half-Lambert `shaped` of `((ndl + 0.2) / 1.2)^2` = 0.210 at that
## angle, so `sun = (1 - 0.591) / 0.210 = 1.95` puts the ceiling at the same
## angle. Green crosses within 5 % of that at the same number, and blue is over
## the ceiling on the ambient alone in both games — which is why this is one
## scalar on the migrated `[diff]` and not three fitted numbers. The per-channel
## behaviour that needed three of them is the clamp, and the clamp is where ETR
## puts it now.
##
## [b]That paragraph is about the sunny sky and only that one.[/b] Under `night`
## red never reaches the ceiling at all and blue crosses it at `ndl` 0.52, so no
## one scalar can be both. [method derive_sun_gain] is the same derivation
## generalised to a sky that never clips, and it is what the six presets that
## were never fitted now carry — per channel, for the reason above.
##
## It was `(0.103, 0.069, 0.103)` until 2026-09-10, an order of magnitude under
## what a linear pipeline wants, because it had been fitted against
## Compatibility's sRGB-blended shadow pass — see [RenderBackend] and history
## §24 for what that pass was doing to the sun.
@export var sun_gain: Color = FIT_SUN_GAIN
## DEVIATION: fitted, not migrated. ETR adds ambient straight onto the texture in
## display space and clamps; Godot decodes the texture to linear first and
## multiplies there, and the same constants land with a far wider spread between
## a lit slope and a shaded one than the original has. Solved against one
## measured point on one frame of Bunny Hill — the shaded bank — captured from
## both games. The procedure is in history §11 and §22; redo it there rather than
## nudging this by eye.
##
## [b]This end never went through the sRGB additive pass[/b] that broke
## [member sun_gain]: a shaded fragment is ambient only, and the ambient was
## always in the base pass. So these three numbers are the ones §22 fitted, kept
## verbatim through the 2026-09-10 rework.
##
## [b]Why a Color and not a scalar.[/b] ETR clamps per channel in display space,
## and on snow the blue channel is already at the ceiling before any light is
## applied: `snow.png` is (236, 245, [b]255[/b]) and `[amb]` is (0.70, 0.78,
## [b]1.00[/b]). One scalar that brings red down to the reference necessarily
## takes blue down with it, off a ceiling the original never leaves — which is
## how shaded snow ended up 33 levels too dark in red and the lit near field
## ended up with green pinned at 255 over three quarters of its area. Three
## numbers per end is the smallest thing that can reproduce a per-channel clamp.
## The blue gains are near 1.0 for exactly that reason.
##
## Pre-distorting the migrated `[amb]` colour to the same effect would hide a
## rendering correction inside data that has to stay traceable to `light.lst`.
## The GL light-model floor that *is* part of the original's state is a different
## thing and is added in the importer, where it shows up in the generated preset.
@export var ambient_gain: Color = FIT_AMBIENT_GAIN
## Migrated from the fill light's `[spec]`. Nothing reads it yet — the terrain
## shader keeps ETR's black terrain specular and the object shaders have no
## specular term at all.
@export var specular_color: Color = Color.BLACK

## Whether anything on a course under this preset throws a shadow.
##
## Migrated, and from an odd place: `CCharShape::DrawShadow` opens with
## `if (g_game.light_id == 1 || g_game.light_id == 3) return;`, and the four
## light conditions are indexed `sunny, cloudy, evening, night` — so the
## original draws Tux's shadow under a sunny or an evening sun and under nothing
## else. It reads like an arbitrary rule and is not: those two are the presets
## whose sun is a fill light rather than a source, and a hard shadow under an
## overcast sky is the single most obviously wrong thing a renderer can draw.
##
## Extended here to the trees, which the original never shadows at all, so that
## a course does not go half-shadowed on a cloudy afternoon. It is one of three
## gates — see [member GameConfig.shadows] and
## [method RenderBackend.supports_light_shadows].
@export var casts_shadows: bool = true

@export_group("Fog")
@export var fog_enabled: bool = true
@export var fog_color: Color = Color.WHITE
## The original used linear fog and doubled it as a draw-distance hider.
@export var fog_start: float = 0.0
@export var fog_end: float = 75.0
## Kept as a knob, but at 1.0: the migrated range *is* the look. ETR's white fog
## reaches full strength at 75 m, which is why its snow sits in a narrow band at
## the top of the range instead of falling away to shaded blue. Stretching it to
## 2.5x to "recover draw distance" was what made this build read colder and
## higher-contrast than the original — corrected 2026-09-01.
@export var fog_distance_scale: float = 1.0
## How much the fog swallows the sky. The original fogged terrain only and drew
## its skybox on top, so this is near zero; at 1.0 the sky is a flat wall of fog
## colour and the imported skybox may as well not exist.
@export_range(0.0, 1.0) var fog_sky_affect: float = 0.05
@export var fog_height: float = 0.0
## Snow particles were tinted to match the fog so they did not pop out of it.
@export var particle_color: Color = Color(0.85, 0.9, 1.0)

@export_group("Sky")
## ETR's half-skybox: three flat faces on a cube centred on the camera. Set by
## the importer from `env/<location>/<light>/{front,left,right}.png` (or their
## `H` variants where `environment.lst` says the location is high-res).
@export var sky_front: Texture2D
@export var sky_left: Texture2D
@export var sky_right: Texture2D
## Averages of the front face's top and bottom rows, filling the directions the
## three faces do not cover. See `shaders/etr_skybox.gdshader`.
@export var sky_zenith_color: Color = Color(0.24, 0.39, 0.75)
@export var sky_nadir_color: Color = Color(0.55, 0.6, 0.7)
## The sky's own haze band, averaged across the middle of the three faces —
## the direction a grazing reflection off the ice actually looks in.
##
## [b]Not [member fog_color], which is what the ice used to reflect.[/b] ETR's
## `[fogcol]` is a fade target, not a radiance: 40 of the 44 shipped courses
## declare `1 1 1`, meaning "distance washes out to white", and handing that to
## the mirror told the ice it was reflecting a sky at full radiance. Measured on
## `etr_sunny`, the skybox's horizon band is sRGB (184, 196, 218) and the frame
## draws it at linear 0.59/0.62/0.73, so the ice was mirroring a sky about 1.6x
## brighter than the one beside it — and achromatic where the real one is blue.
## A mirror cannot out-brighten what it mirrors. See the ice block in
## `shaders/terrain.gdshader`.
@export var sky_horizon_color: Color = Color(0.75, 0.82, 0.92)
## Equirectangular sky, for authored replacements. Takes precedence over the
## migrated faces.
@export var sky_panorama: Texture2D

## Build a Godot [Environment] from the preset. Everything here is available in
## the Compatibility renderer — no volumetric fog, no SSR, no SDFGI (§1).
##
## DEVIATION: the tone mapper is linear rather than filmic. ETR shaded in
## display space with a hard clamp — its snow really does clip to white, and its
## midtones really are that flat. ACES redistributes both: it pulls the shaded
## side of a slope down and rolls the lit side off, which turned this build's
## snow into the high-contrast blue-and-blown-white it should never have been.
## Reproducing a fixed-function look means reproducing its transfer curve.
func to_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = _build_sky()

	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = as_light_color(ambient_color, ambient_gain)
	# The gain is already in the colour: an energy is one more scalar over three
	# channels, which is the thing this fit had to stop using.
	env.ambient_light_energy = 1.0
	# Ambient comes from the migrated `[amb]`, not from the sky. This defaults to
	# 1.0, which hands the whole ambient term to the skybox — and this skybox is
	# a wall of sunlit snow, so on a snow course it is far brighter than the
	# colour it replaces and it is not scaled by anything in `light.lst`.
	env.ambient_light_sky_contribution = 0.0

	env.fog_enabled = fog_enabled
	env.fog_light_color = fog_color
	env.fog_mode = Environment.FOG_MODE_DEPTH
	# The migrated range. A race overwrites both distances through
	# `GameConfig.apply_fog` — that is where the player's fog setting lives —
	# so anything building an Environment straight off a preset gets the data.
	env.fog_depth_begin = fog_start * fog_distance_scale
	env.fog_depth_end = fog_end * fog_distance_scale
	# `fog_density` is not exponential-mode-only: depth fog multiplies its
	# smoothstepped ramp by it as well, and it defaults to 0.01. Leaving it there
	# renders the whole range at one per cent, which looks exactly like fog that
	# is simply switched off — and ETR's white haze is what holds its snow inside
	# a narrow band. Depth fog wants full strength; the range is the knob.
	env.fog_density = 1.0
	env.fog_sky_affect = fog_sky_affect
	env.fog_height = fog_height

	# No environment reflection either. ETR's terrain has no reflective term at
	# all, and Godot's is not a small correction here: it is Fresnel-weighted, so
	# on a slope seen at the grazing angle a chase camera spends all its time at,
	# a sky made of sunlit snow adds roughly a fifth of a unit of light — enough
	# on its own to pin the near field at white, and invisible to any amount of
	# `sun_gain` tuning because it does not come from the sun.
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

	# No bloom and no ambient occlusion in the original, and both work against
	# the target: glow smears the clipped highlights snow is mostly made of,
	# and SSAO is a Forward+ pass the shipped renderer does not run anyway.
	env.glow_enabled = false
	env.ssao_enabled = false
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	return env

## Point a [DirectionalLight3D] at the course and give it this preset's sun.
##
## Here rather than in the caller because the sun and the ambient have to make
## the same trip through [method as_light_color], and the version of this bug
## that shipped was one of them making it and the other not.
func apply_sun(light: DirectionalLight3D) -> void:
	light.light_color = as_light_color(sun_color, sun_gain)
	light.light_energy = 1.0
	light.look_at_from_position(Vector3.ZERO, -sun_direction, Vector3.UP)

## A display-space multiplier from `light.lst`, times its fitted gain, packed
## into the [Color] Godot wants for a light.
##
## [b]Godot sRGB-decodes `light_color` and `ambient_light_color`.[/b] They are
## authored as colours you pick in the Inspector, so a stored 0.9 reaches the
## shader as 0.787. But `[diff] 1.0 0.9 1.0` and `[amb] 0.45 0.53 0.75` are not
## colours — they are the numbers ETR multiplies its display-space texture by,
## and the decode stretches every ratio between them: the migrated ambient's
## blue-to-red ratio goes from 1.43 in the file to 2.23 in the shader. Encoding
## on the way in makes the decode give the file's number back. Without it no
## amount of level fitting helps, because the *balance* is wrong: two of the
## three channels sat on the clip ceiling and shading variation only ever
## reached the frame through red, which is what made the snow read as a flat
## white sheet with cyan in the hollows.
static func as_light_color(display: Color, gain: Color) -> Color:
	return Color(display.r * gain.r, display.g * gain.g, display.b * gain.b,
		1.0).linear_to_srgb()

# ------------------------------------------------------------------
#        giving the other six presets a gain of their own
# ------------------------------------------------------------------
#
# Until the light conditions were offered to the player, only the sunny presets
# were ever selected, and all eight shared one pair of gains: the sunny fit,
# sitting on the script as the default. That is the wrong thing to share, and it
# is wrong in a way that only shows up on a dark sky — see [method
# fit_correction]. The two functions below are how the other six get their own,
# and the importer is the only caller: gains are written onto the resource so a
# preset can still be read on sight, the same arrangement the migrated colours
# have.

## The correction the one fitted preset carries, as a per-channel factor on
## `light.lst`'s own `[amb]` — and the only thing the derived presets inherit
## from the fit.
##
## A shaded fragment renders at `srgb(ambient_color * ambient_gain)`. On
## `tuxracer_sunny` that is (0.79, 0.86, 0.99) where the file says
## (0.70, 0.78, 1.00), so the bank the fit was measured on wanted about a tenth
## more light than `[amb]` alone gives. This returns that tenth.
##
## [b]It is inherited in display space, which is the whole point.[/b] Sharing the
## gain itself — one default across all eight presets, which is what shipped —
## shares it in linear space, and undoing an sRGB decode raises a dark value far
## more than a bright one: `night`'s `[amb] 0.2` came back as a shaded snow of
## about 105/255 against the original's 47, which is why the light conditions
## could not be offered. The same correction applied in the space ETR's
## arithmetic actually lives in puts night's shaded snow at 53 — the original's
## 47 times this same correction, which every other preset is off by too.
static func fit_correction() -> Color:
	var shaded: Color = as_light_color(FIT_AMBIENT, FIT_AMBIENT_GAIN)
	return Color(shaded.r / FIT_AMBIENT.r, shaded.g / FIT_AMBIENT.g,
		shaded.b / FIT_AMBIENT.b, 1.0)

## The [member ambient_gain] for a preset whose assembled `[amb]` is
## [param ambient]: whatever makes a shaded fragment render at the original's
## own display-space ambient, times [method fit_correction].
##
## Returns [constant FIT_AMBIENT_GAIN] exactly when handed
## [constant FIT_AMBIENT], by construction — the fit is the fixed point of this,
## not an exception to it.
static func derive_ambient_gain(ambient: Color) -> Color:
	var k: Color = fit_correction()
	var target: Color = Color(minf(ambient.r * k.r, 1.0), minf(ambient.g * k.g, 1.0),
		minf(ambient.b * k.b, 1.0), 1.0).srgb_to_linear()
	return Color(_ratio(target.r, ambient.r), _ratio(target.g, ambient.g),
		_ratio(target.b, ambient.b), 1.0)

## The [member sun_gain] for a preset, by the derivation [member sun_gain]
## documents, generalised to a sky that never reaches the clamp.
##
## [param sun] is `[diff]`, [param ambient] the assembled `[amb]` that
## [method derive_ambient_gain] takes, and [param etr_ambient] the original's own
## display-space ambient — the GL light-model floor plus light 0's `[amb]`, and
## [i]not[/i] the fill light the importer folds in on top, because the fill is
## ours and this side of the equation has to be ETR's.
##
## Per channel, ETR's snow reaches white at `N·L = (1 - etr_ambient) / diff`.
## Where that angle exists, matching it is the whole requirement — past it both
## games are clipped and neither has anything left to say — and it is what gives
## the fitted 1.95 back for `tuxracer_sunny`'s red. Where it does not, because
## the sky is too dark for `[diff]` ever to reach the ceiling, there is no clamp
## to place and the sun is matched at full N·L instead: `night` reaches
## 0.2 + 0.39 = 0.59 in red and has to arrive there too. The two cases meet
## continuously at an angle of exactly 1.
##
## [b]Per channel, unlike the fitted preset's one scalar.[/b] Sunny can use one
## because its blue is over the ceiling on the ambient alone; night's blue
## crosses at N·L 0.52 while its red never crosses at all, and one number cannot
## be both — the same argument [member ambient_gain] makes about the clamp, one
## end further along.
static func derive_sun_gain(sun: Color, ambient: Color, etr_ambient: Color) -> Color:
	var gain: Color = derive_ambient_gain(ambient)
	var ndl := Vector3(
		_clamp_angle(etr_ambient.r, sun.r),
		_clamp_angle(etr_ambient.g, sun.g),
		_clamp_angle(etr_ambient.b, sun.b))
	# Decoded together rather than one at a time: this is the same display-space
	# number `as_light_color` encodes, taken the other way.
	var target: Color = Color(
		minf(etr_ambient.r + sun.r * ndl.x, 1.0),
		minf(etr_ambient.g + sun.g * ndl.y, 1.0),
		minf(etr_ambient.b + sun.b * ndl.z, 1.0), 1.0).srgb_to_linear()
	return Color(
		_sun_gain_channel(target.r, ambient.r * gain.r, sun.r, ndl.x),
		_sun_gain_channel(target.g, ambient.g * gain.g, sun.g, ndl.y),
		_sun_gain_channel(target.b, ambient.b * gain.b, sun.b, ndl.z), 1.0)

## Where ETR's snow reaches white in one channel, or 1.0 for a sky that never
## gets there. A channel with no sun in it at all has no angle either.
static func _clamp_angle(etr_ambient: float, diff: float) -> float:
	if diff <= 0.0:
		return 1.0
	return clampf((1.0 - etr_ambient) / diff, 0.0, 1.0)

## One channel of [method derive_sun_gain]: the gain that lands the sum on
## [param target_lin] at [param ndl], through the snow's half-Lambert wrap.
static func _sun_gain_channel(target_lin: float, ambient_lin: float, diff: float,
		ndl: float) -> float:
	if diff <= 0.0:
		return 1.0
	var shaped: float = pow((ndl + SNOW_WRAP) / (1.0 + SNOW_WRAP), 2.0)
	return maxf((target_lin - ambient_lin) / (diff * shaped), 0.0)

## A channel that a black ambient would otherwise divide by: a gain on nothing
## is 1.0, not an error and not an infinity.
static func _ratio(num: float, den: float) -> float:
	return num / den if den > 0.0 else 1.0

## The same ambient [method to_environment] hands Godot, but as the linear
## number a shader works in rather than packed into a [Color] for the decode.
##
## `shaders/terrain.gdshader` needs it as a number because it is
## `ambient_light_disabled`: the terrain sums the ambient and the sun and clamps
## the total before either touches the albedo, the way ETR's fixed-function
## pipeline does, and the engine adds its ambient outside the light loop where
## that sum cannot happen. Derived from the same two fields as the
## [Environment]'s copy so the two cannot drift — [TestEnvironments] asserts
## they agree.
func ambient_illumination() -> Vector3:
	return Vector3(ambient_color.r * ambient_gain.r,
		ambient_color.g * ambient_gain.g,
		ambient_color.b * ambient_gain.b)

func _build_sky() -> Sky:
	var sky := Sky.new()
	if sky_panorama != null:
		var pano := PanoramaSkyMaterial.new()
		pano.panorama = sky_panorama
		sky.sky_material = pano
		return sky
	if sky_front != null and sky_left != null and sky_right != null:
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/etr_skybox.gdshader")
		mat.set_shader_parameter("face_front", sky_front)
		mat.set_shader_parameter("face_left", sky_left)
		mat.set_shader_parameter("face_right", sky_right)
		mat.set_shader_parameter("zenith_color", sky_zenith_color)
		mat.set_shader_parameter("nadir_color", sky_nadir_color)
		sky.sky_material = mat
		return sky
	# No migrated faces — a plain gradient rather than a flat clear colour, so a
	# course with a missing environment still has a horizon to read against.
	var proc := ProceduralSkyMaterial.new()
	proc.sky_top_color = sky_zenith_color
	proc.sky_horizon_color = fog_color
	proc.ground_horizon_color = fog_color
	proc.ground_bottom_color = sky_nadir_color
	sky.sky_material = proc
	return sky
