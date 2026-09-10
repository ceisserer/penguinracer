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
	_the_shadow_gate(t, presets)
	_reaches_the_sun(t, presets)
	_still_traceable(t, presets)

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
