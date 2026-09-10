## Per-environment, per-time-of-day lighting, migrated from `env/<env>/<light>/light.lst`.
##
## The original drove four fixed-function GL lights and linear fog. Under a PBR
## renderer that becomes one directional sun plus ambient, so the extra lights
## are folded into the ambient and specular terms rather than dropped: their
## contribution is what made ETR's evening and night courses read.
@tool
class_name EnvironmentPreset
extends Resource

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
## It was `(0.103, 0.069, 0.103)` until 2026-09-10, an order of magnitude under
## what a linear pipeline wants, because it had been fitted against
## Compatibility's sRGB-blended shadow pass — see [RenderBackend] and history
## §24 for what that pass was doing to the sun.
@export var sun_gain: Color = Color(1.95, 1.95, 1.95)
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
@export var ambient_gain: Color = Color(0.841, 0.905, 0.980)
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
