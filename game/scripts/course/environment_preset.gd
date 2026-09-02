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
@export var sun_color: Color = Color.WHITE
## DEVIATION: fitted, not migrated. See [member ambient_energy] — the two are
## solved as a pair, because one scalar cannot place both ends of the range and
## the ends are what "looks like the original" means.
@export var sun_energy: float = 0.24
@export var ambient_color: Color = Color(0.45, 0.53, 0.75)
## DEVIATION: fitted, not migrated, together with [member sun_energy]. ETR adds
## ambient straight onto the texture in display space and clamps; Godot decodes
## the texture to linear first and multiplies there, and the same constants land
## with a far wider spread between a lit slope and a shaded one than the original
## has. The pair is solved against two measured points on one frame of Bunny Hill
## — a lit near-field slope, where ETR sits at 0.90 linear, and a shaded bank,
## where it sits at 0.51 — captured from both games at the same moment. The
## procedure is in PROGRESS.md §11; redo it there rather than nudging these by
## eye, because the two ends trade off against each other.
##
## Pre-distorting the migrated `[amb]` colour to the same effect would hide a
## rendering correction inside data that has to stay traceable to `light.lst`.
## The GL light-model floor that *is* part of the original's state is a different
## thing and is added in the importer, where it shows up in the generated preset.
@export var ambient_energy: float = 0.92
@export var specular_color: Color = Color.BLACK

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
	env.ambient_light_color = ambient_color
	env.ambient_light_energy = ambient_energy
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
	# `sun_energy` tuning because it does not come from the sun.
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

	# No bloom and no ambient occlusion in the original, and both work against
	# the target: glow smears the clipped highlights snow is mostly made of,
	# and SSAO is a Forward+ pass the shipped renderer does not run anyway.
	env.glow_enabled = false
	env.ssao_enabled = false
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	return env

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
