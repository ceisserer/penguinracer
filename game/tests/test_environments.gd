## Tests for the generated [EnvironmentPreset] set under `res://resources/environments`.
##
## What is guarded here is one property and it is not a number: the values
## `light.lst` gives are **display-space multipliers**, and Godot sRGB-decodes
## anything it is handed as a light colour. A migrated 0.9 therefore reaches the
## shader as 0.787 unless something encodes it on the way in, and every ratio
## between the channels is stretched with it — the ambient's blue-to-red went
## from 1.43 in the file to 2.23 in the shader, which put two of the three
## channels on the clip ceiling and left shading variation reaching the frame
## through red alone.
##
## None of that fails visibly. The scene still renders, the fitted energies still
## place red on the reference, and the only symptom is snow that reads as a white
## sheet with cyan in the hollows — which is indistinguishable from "snow is
## bright" until someone measures a shaded bank. So the assertion is on the
## round trip rather than on the look: whatever a preset hands Godot must come
## back out of `srgb_to_linear` as the number the file wrote, times its gain.
class_name TestEnvironments
extends RefCounted

const ENV_DIR := "res://resources/environments"
## One display level at 8 bits, which is the resolution anything downstream has.
const EPS := 1.0 / 255.0

static func run(t: TestCase) -> void:
	var presets: Array[EnvironmentPreset] = _load_all(t)
	_round_trip(t, presets)
	_reaches_the_environment(t, presets)
	_reaches_the_terrain(t, presets)
	_the_ice_reflects_a_sky(t, presets)
	_the_shadow_gate(t, presets)
	_reaches_the_sun(t, presets)
	_still_traceable(t, presets)
	_every_sky_reproduces_etr(t, presets)
	_the_fit_is_the_fixed_point(t)
	_the_wrap_matches_the_shader(t)
	_choosing_a_time_of_day(t)

static func _load_all(t: TestCase) -> Array[EnvironmentPreset]:
	t.begin("environments/on disk")
	var out: Array[EnvironmentPreset] = []
	var dir := DirAccess.open(ENV_DIR)
	t.ok(dir != null, "the environment presets are on disk")
	if dir == null:
		return out
	for file: String in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var preset: EnvironmentPreset = load(ENV_DIR.path_join(file))
		t.ok(preset != null, "%s loads as an EnvironmentPreset" % file)
		if preset != null:
			out.push_back(preset)
	t.ok(out.size() == 8, "all eight environments are there (%d)" % out.size())
	return out

## The property the whole fix rests on: encode, let Godot decode, get the file's
## number back. Asserted on the conversion itself so it holds for a preset that
## no shipped course selects.
static func _round_trip(t: TestCase, presets: Array[EnvironmentPreset]) -> void:
	t.begin("environments/display-space round trip")
	for preset: EnvironmentPreset in presets:
		for pair: Array in [[preset.sun_color, preset.sun_gain, "sun"],
				[preset.ambient_color, preset.ambient_gain, "ambient"]]:
			var display: Color = pair[0]
			var gain: Color = pair[1]
			var back: Color = EnvironmentPreset.as_light_color(display, gain).srgb_to_linear()
			for ch: int in range(3):
				t.ok(absf(back[ch] - display[ch] * gain[ch]) < EPS,
					"%s: %s %s reaches the shader as %.4f, wanted %.4f" % [
						preset.id, pair[2], "RGB"[ch], back[ch], display[ch] * gain[ch]])

## The ambient half of the trip, through the built [Environment].
##
## The energy has to be 1.0 as well: a scalar over three channels is exactly
## what could not reproduce a per-channel clamp, and one left behind here would
## silently rescale a fit that has the gain in the colour already.
static func _reaches_the_environment(t: TestCase, presets: Array[EnvironmentPreset]) -> void:
	t.begin("environments/ambient reaches the Environment")
	for preset: EnvironmentPreset in presets:
		var env: Environment = preset.to_environment()
		t.ok(is_equal_approx(env.ambient_light_energy, 1.0),
			"%s: the ambient gain is in the colour, not in an energy" % preset.id)
		var linear: Color = env.ambient_light_color.srgb_to_linear()
		for ch: int in range(3):
			t.ok(absf(linear[ch] - preset.ambient_color[ch] * preset.ambient_gain[ch]) < EPS,
				"%s: ambient %s survives the Environment" % [preset.id, "RGB"[ch]])
		t.ok(is_equal_approx(env.ambient_light_sky_contribution, 0.0),
			"%s: the ambient still comes from [amb] and not from the sky" % preset.id)

## The third copy of the ambient, and the one that draws the snow.
##
## `shaders/terrain.gdshader` is `ambient_light_disabled` — ETR sums the ambient
## and the sun and clamps the total before either touches the albedo, and the
## engine adds its ambient after the light loop, where that sum cannot happen —
## so the terrain is told the number instead, through
## [method EnvironmentPreset.ambient_illumination]. Two copies of one value is
## two chances to disagree, and a disagreement here is invisible: the terrain
## and everything else in the frame would simply be lit by slightly different
## skies. Assert they are the same number.
static func _reaches_the_terrain(t: TestCase, presets: Array[EnvironmentPreset]) -> void:
	t.begin("environments/ambient reaches the terrain shader")
	for preset: EnvironmentPreset in presets:
		var shader_side: Vector3 = preset.ambient_illumination()
		var engine_side: Color = preset.to_environment().ambient_light_color.srgb_to_linear()
		for ch: int in range(3):
			t.ok(absf(shader_side[ch] - engine_side[ch]) < EPS,
				"%s: the terrain's ambient %s is the Environment's" % [preset.id, "RGB"[ch]])

## What the ice reflects has to be a sky, and `fog_color` is not one.
##
## ETR's `[fogcol]` is a fade target — 40 of the 44 shipped courses declare
## `1 1 1`, "distance washes out to white" — and for a phase that was handed
## straight to the terrain shader as the radiance of the horizon. A mirror fed a
## full-radiance sky out-brightens the skybox drawn beside it, which is what
## "ice at a flat angle is almost white" was: measured on `penguins_cant_fly`, a
## lit bowl reading 115/132/150 came back 250/255/255.
##
## The assertion is the invariant rather than a fitted number, so it survives a
## re-import: the horizon the ice reflects must be dimmer than white, and it
## must not be the fog. `etr_sunny`'s band measures (184, 196, 218).
static func _the_ice_reflects_a_sky(t: TestCase, presets: Array[EnvironmentPreset]) -> void:
	t.begin("environments/the ice reflects a sky, not the fog")
	for preset: EnvironmentPreset in presets:
		var sky: Color = preset.sky_horizon_color
		# Headroom below white. Without it the Fresnel term at a grazing angle —
		# which reaches 1 - `ice_roughness` — pins the surface at the ceiling
		# whatever its own albedo is.
		t.ok(maxf(maxf(sky.r, sky.g), sky.b) < 1.0 - EPS,
			"%s: the reflected horizon is below white (%.3f)"
				% [preset.id, maxf(maxf(sky.r, sky.g), sky.b)])
		# The specific wrong answer, named so a future re-plumbing cannot walk
		# back into it silently.
		var is_fog: bool = absf(sky.r - preset.fog_color.r) < EPS \
			and absf(sky.g - preset.fog_color.g) < EPS \
			and absf(sky.b - preset.fog_color.b) < EPS
		t.ok(not is_fog,
			"%s: it is the skybox's haze band, not fog_color" % preset.id)

## `CCharShape::DrawShadow` opens with
## `if (g_game.light_id == 1 || g_game.light_id == 3) return;` and the light
## conditions are indexed `sunny, cloudy, evening, night` — so the original
## draws no shadow under an overcast or a night sky. The importer reads that off
## the directory name rather than off an index; this is the assertion that it
## still lands on all eight presets.
##
## It is one of three gates and the only one that is data. The other two are the
## renderer ([RenderBackend], which refuses on the web build) and the player
## ([member GameConfig.shadows]).
static func _the_shadow_gate(t: TestCase, presets: Array[EnvironmentPreset]) -> void:
	t.begin("environments/who casts a shadow")
	for preset: EnvironmentPreset in presets:
		var id: String = String(preset.id)
		var overcast: bool = id.ends_with("_cloudy") or id.ends_with("_night")
		t.ok(preset.casts_shadows != overcast,
			"%s: casts_shadows is %s, as DrawShadow's light_id gate says" % [
				id, not overcast])

## The sun half. It is a separate assertion because the bug this replaces was
## the two halves disagreeing — the ambient went through the conversion in
## `to_environment` and the sun was assigned straight onto the light in
## `RaceScene`, so a fix applied to one of them would have left the other wrong
## and the frame would still have rendered.
static func _reaches_the_sun(t: TestCase, presets: Array[EnvironmentPreset]) -> void:
	t.begin("environments/sun reaches the light")
	# In the tree, because `look_at_from_position` reads a global transform and
	# returns the identity with an error outside one — which would leave the
	# direction half of `apply_sun` untested while looking like it passed.
	var light := DirectionalLight3D.new()
	var tree := Engine.get_main_loop() as SceneTree
	t.ok(tree != null, "there is a tree to hang a light in")
	if tree == null:
		return
	tree.root.add_child(light)
	for preset: EnvironmentPreset in presets:
		preset.apply_sun(light)
		t.ok(is_equal_approx(light.light_energy, 1.0),
			"%s: the sun gain is in the colour, not in an energy" % preset.id)
		var linear: Color = light.light_color.srgb_to_linear()
		for ch: int in range(3):
			t.ok(absf(linear[ch] - preset.sun_color[ch] * preset.sun_gain[ch]) < EPS,
				"%s: sun %s survives apply_sun" % [preset.id, "RGB"[ch]])
		# `look_at_from_position` points -Z down the direction it is given, so
		# the light's forward is the direction the sunlight travels.
		t.ok((-light.global_basis.z).dot(-preset.sun_direction.normalized()) > 0.99,
			"%s: the sun still points where light.lst put it" % preset.id)
	tree.root.remove_child(light)
	light.free()

## The migrated colours are still the file's, undistorted.
##
## The fit lives in `sun_gain`/`ambient_gain` precisely so that a rendering
## correction never gets baked into data that has to stay traceable to
## `light.lst`. `tuxracer/sunny` is the one both fits were measured on:
## `[diff] 1.0 0.9 1.0` and `[amb] 0.45 0.53 0.75`, the latter plus the GL
## light-model floor of 0.2 and the fill light's 0.3 x 0.175.
static func _still_traceable(t: TestCase, presets: Array[EnvironmentPreset]) -> void:
	t.begin("environments/migrated values are undistorted")
	for preset: EnvironmentPreset in presets:
		if preset.id != &"tuxracer_sunny" and preset.id != &"etr_sunny":
			continue
		t.ok(preset.sun_color.is_equal_approx(Color(1.0, 0.9, 1.0)),
			"%s: [diff] is still 1.0 0.9 1.0" % preset.id)
		var amb := Color(0.45 + 0.2 + 0.3 * 0.175, 0.53 + 0.2 + 0.3 * 0.175, 1.0)
		for ch: int in range(3):
			t.ok(absf(preset.ambient_color[ch] - amb[ch]) < 1e-4,
				"%s: ambient %s is [amb] plus the light model and the fill" % [
					preset.id, "RGB"[ch]])

## What the gains are actually for, at both ends of the range, on every preset.
##
## ETR shades in display space: a fragment is `texture * clamp([amb] + [diff] *
## N·L)`. Here the same fragment is `texture * srgb(ambient_lin + sun_lin *
## shaped)`, and the gains are what make the second read like the first. So the
## assertion is the arithmetic rather than either gain:
##
##   - [b]shaded[/b] (N·L = 0, ambient only) has to land on the original's own
##     `[amb]` times [method EnvironmentPreset.fit_correction] — the one measured
##     correction, which is a tenth of a stop and which the sunny fit carries.
##   - [b]lit[/b] (N·L = 1) has to land on the original's `[amb] + [diff]`,
##     clamped. Where ETR clips, we clip; where it does not — night's red stops
##     at 0.59 — neither may.
##
## This is the assertion that was missing when all eight presets shared one pair
## of gains. It passed the round trip, it rendered, and `night` came out at
## 105/255 of shaded snow against the original's 47: sharing a *gain* shares it
## in linear space, where undoing an sRGB decode raises a dark value far more
## than a bright one. Both ends are checked to within two display levels, which
## is what a Color stored as a 32-bit float and read back through two transfer
## functions is good for.
static func _every_sky_reproduces_etr(t: TestCase, presets: Array[EnvironmentPreset]) -> void:
	t.begin("environments/ETR's arithmetic, on every sky")
	var k: Color = EnvironmentPreset.fit_correction()
	for preset: EnvironmentPreset in presets:
		var amb: Color = preset.ambient_color
		var lin: Vector3 = preset.ambient_illumination()
		var shaded: Color = Color(lin.x, lin.y, lin.z, 1.0).linear_to_srgb()
		var lit: Color = Color(minf(lin.x + preset.sun_color.r * preset.sun_gain.r, 1.0),
			minf(lin.y + preset.sun_color.g * preset.sun_gain.g, 1.0),
			minf(lin.z + preset.sun_color.b * preset.sun_gain.b, 1.0), 1.0).linear_to_srgb()
		for ch: int in range(3):
			var want_shaded: float = minf(amb[ch] * k[ch], 1.0)
			t.ok(absf(shaded[ch] - want_shaded) < EPS * 2.0,
				"%s: shaded %s renders at %.3f, ETR's [amb] x the fit is %.3f" % [
					preset.id, "RGB"[ch], shaded[ch], want_shaded])
			# The fill light the importer folds into `[amb]` is ours, so the lit
			# end is only asserted where it cannot hide the answer: a preset with
			# a fill has both sides over the ceiling anyway.
			var want_lit: float = minf(amb[ch] + preset.sun_color[ch], 1.0)
			t.ok(absf(lit[ch] - want_lit) < EPS * 2.0,
				"%s: lit %s renders at %.3f, ETR's [amb] + [diff] is %.3f" % [
					preset.id, "RGB"[ch], lit[ch], want_lit])

## The fit is the fixed point of the derivation, not an exception to it.
##
## [method EnvironmentPreset.derive_ambient_gain] is defined in terms of the
## measured correction, so handing it the surface that correction was measured on
## has to give the measured gain back. If it does not, the six derived presets
## are hanging off a number that no longer means what the fit means.
##
## The sun half is a looser claim and is asserted as such: the derivation is the
## one [member EnvironmentPreset.sun_gain] documents, and run on `tuxracer_sunny`
## it returns 1.948 in red against the fitted 1.95 — the channel the derivation
## was written for, to a tenth of a per cent.
static func _the_fit_is_the_fixed_point(t: TestCase) -> void:
	t.begin("environments/the derivation reproduces the fit")
	var back: Color = EnvironmentPreset.derive_ambient_gain(EnvironmentPreset.FIT_AMBIENT)
	for ch: int in range(3):
		t.ok(absf(back[ch] - EnvironmentPreset.FIT_AMBIENT_GAIN[ch]) < 1e-4,
			"ambient_gain %s derives back to the fitted %.4f (%.4f)" % [
				"RGB"[ch], EnvironmentPreset.FIT_AMBIENT_GAIN[ch], back[ch]])
	# `[diff] 1.0 0.9 1.0` under the GL floor plus light 0's own `[amb] 0.45`,
	# which is the equation [member EnvironmentPreset.sun_gain] is derived from.
	var sun: Color = EnvironmentPreset.derive_sun_gain(Color(1.0, 0.9, 1.0),
		EnvironmentPreset.FIT_AMBIENT, Color(0.65, 0.73, 0.95))
	t.ok(absf(sun.r - EnvironmentPreset.FIT_SUN_GAIN.r) < 0.01,
		"and sun_gain red derives to the fitted 1.95 (%.4f)" % sun.r)

## The one number the sun derivation shares with a shader it cannot import.
##
## [method EnvironmentPreset.derive_sun_gain] places the clamp at an angle, and
## on snow the angle is read through the terrain shader's half-Lambert wrap. If
## `wrap_amount` moves and [constant EnvironmentPreset.SNOW_WRAP] does not, every
## derived preset quietly lands its ceiling somewhere else.
static func _the_wrap_matches_the_shader(t: TestCase) -> void:
	t.begin("environments/the wrap the derivation assumes")
	var text: String = FileAccess.get_file_as_string("res://shaders/terrain.gdshader")
	t.ok(not text.is_empty(), "the terrain shader is readable")
	var wanted: String = "uniform float wrap_amount : hint_range(0.0, 1.0) = %s;" % \
		String.num(EnvironmentPreset.SNOW_WRAP, 1)
	t.ok(text.contains(wanted),
		"terrain.gdshader still wraps at SNOW_WRAP (%s)" % wanted)

## [LightCondition]: a course names a place and the shell names a time of day.
static func _choosing_a_time_of_day(t: TestCase) -> void:
	t.begin("environments/choosing a time of day")
	var sunny: EnvironmentPreset = load(ENV_DIR.path_join("tuxracer_sunny.tres"))
	t.ok(sunny != null, "the default sky loads")
	if sunny == null:
		return
	t.ok(LightCondition.location_of(sunny) == "tuxracer", "its location reads back off the id")
	t.ok(LightCondition.preset_for(sunny, LightCondition.Kind.SUNNY) == sunny,
		"asking for the sky it already is changes nothing")
	var night: EnvironmentPreset = LightCondition.preset_for(sunny, LightCondition.Kind.NIGHT)
	t.ok(night != null and night.id == &"tuxracer_night",
		"and asking for night gets the same location after dark")
	t.ok(not night.casts_shadows, "which is a sky nothing casts a shadow under")
	var cloudy: EnvironmentPreset = LightCondition.preset_for(
		load(ENV_DIR.path_join("etr_sunny.tres")), LightCondition.Kind.CLOUDY)
	t.ok(cloudy != null and cloudy.id == &"etr_cloudy", "the other location too")
	# A preset that is nobody's migrated sky has no siblings to swap to, and a
	# course lit by the wrong time of day beats a race that will not load.
	var authored := EnvironmentPreset.new()
	authored.id = &"handmade"
	t.ok(LightCondition.preset_for(authored, LightCondition.Kind.NIGHT) == authored,
		"an authored preset is left exactly as it is")
	t.ok(LightCondition.preset_for(null, LightCondition.Kind.NIGHT) == null,
		"and no preset at all is not an error")

	t.begin("environments/naming a time of day")
	for kind: LightCondition.Kind in LightCondition.KINDS:
		t.ok(LightCondition.parse(LightCondition.name_of(kind)) == kind,
			"%s survives the settings file" % LightCondition.name_of(kind))
		t.ok(LightCondition.of(int(kind)) == kind,
			"%s survives the wire, where it is an int" % LightCondition.name_of(kind))
	t.ok(LightCondition.parse("EVENING") == LightCondition.Kind.SUNNY,
		"a light that is not offered reads as sunny rather than as an error")
	t.ok(LightCondition.of(2) == LightCondition.Kind.SUNNY,
		"and so does its index, which is the gap in the enum")
	t.ok(LightCondition.parse("  Night ") == LightCondition.Kind.NIGHT,
		"a hand-edited file has spaces and capitals in it")
	t.ok(LightCondition.index_of(LightCondition.Kind.NIGHT) == 2,
		"night is the third row offered, not the third value")
