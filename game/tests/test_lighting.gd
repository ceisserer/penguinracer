## Tests for the two things that decide how a frame is lit: which renderer is
## running, and whether every lit shader reproduces ETR's illumination clamp.
##
## Neither can be checked by rendering here. The headless suite has no
## rasteriser at all, so what a shader *does* is not observable — but what a
## shader is *written to do* is, and both of the bugs this guards against are
## textual. They are also both silent:
##
## - a shader that includes `etr_illumination.gdshaderinc` and forgets
##   `ambient_light_disabled` gets the engine's ambient on top of `etr_ambient`,
##   which is a plausible-looking frame that is ambient-twice-over;
## - a shader that writes `DIFFUSE_LIGHT += ALBEDO * ...` squares the albedo,
##   because Godot multiplies the accumulated diffuse by it once after the light
##   loop. On snow that is a 16 % darkening of the sun term and nothing at all
##   to the ambient, which is why it survived two phases and was absorbed into
##   `sun_gain`.
##
## The renderer half asserts the *shape* of the rule rather than a platform: a
## test binary is headless and answers "Compatibility" to everything, so
## asserting "the desktop uses Mobile" here would assert the harness. What is
## worth holding is that the two questions [RenderBackend] answers are each
## other's negation, and that `project.godot` still says what it is supposed to
## for the two platforms that ship.
class_name TestLighting
extends RefCounted

## Every shader that lights a surface. `etr_skybox` is not one — a sky shader
## has no light loop — and `snow_trail`/`s1_displace` draw into render targets.
const LIT_SHADERS: Array[String] = [
	"res://shaders/terrain.gdshader",
	"res://shaders/object_cross.gdshader",
	"res://shaders/object_billboard.gdshader",
	"res://shaders/object_prop.gdshader",
	"res://shaders/water.gdshader",
]
const INCLUDE_PATH := "res://shaders/etr_illumination.gdshaderinc"

static func run(t: TestCase) -> void:
	_the_include_exists(t)
	_every_lit_shader_clamps(t)
	_nobody_multiplies_the_albedo_twice(t)
	_the_mirror_takes_its_share(t)
	_the_renderer_rule(t)
	_the_project_ships_two_renderers(t)
	_the_player_picks_the_renderer(t)

static func _read(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()

static func _the_include_exists(t: TestCase) -> void:
	t.begin("lighting/the shared clamp")
	var text: String = _read(INCLUDE_PATH)
	t.ok(not text.is_empty(), "etr_illumination.gdshaderinc is on disk")
	t.ok(text.contains("uniform vec3 etr_ambient"),
		"it declares the ambient the engine is no longer providing")
	# The clamp itself. `min(..., vec3(1.0))` is ETR's `clamp(illum, 0, 1)` — the
	# lower half is free, since neither term can be negative.
	t.ok(text.contains("min(") and text.contains("vec3(1.0)"),
		"it clamps the summed illumination before anything multiplies the albedo")

static func _every_lit_shader_clamps(t: TestCase) -> void:
	t.begin("lighting/every lit shader")
	for path: String in LIT_SHADERS:
		var text: String = _read(path)
		var name: String = path.get_file()
		t.ok(not text.is_empty(), "%s is on disk" % name)
		t.ok(text.contains("#include \"%s\"" % INCLUDE_PATH),
			"%s includes the ETR illumination" % name)
		# Without this the engine adds its own ambient outside the light loop,
		# on top of the one the include just clamped in.
		t.ok(text.contains("ambient_light_disabled"),
			"%s disables the engine's ambient, which the include replaces" % name)
		t.ok(text.contains("etr_illumination("),
			"%s actually calls it — including the file is not using it" % name)

static func _nobody_multiplies_the_albedo_twice(t: TestCase) -> void:
	t.begin("lighting/the albedo is the engine's to apply")
	for path: String in LIT_SHADERS:
		var name: String = path.get_file()
		var found: bool = false
		for line: String in _read(path).split("\n"):
			var code: String = line.strip_edges()
			if code.begins_with("//"):
				continue
			if code.contains("DIFFUSE_LIGHT") and code.contains("ALBEDO"):
				found = true
		t.ok(not found,
			"%s does not put ALBEDO into DIFFUSE_LIGHT — the engine does that" % name)

## The ice reflection is the one term that lands outside the clamp the include
## exists to enforce, so it has to bound itself: Fresnel splits the incoming
## light between the mirror and the diffuse under it, and a shader that adds the
## mirror without taking its share out of `ALBEDO` can push a surface past its
## own albedo — which is the exact thing `etr_illumination` was written to stop.
##
## Textual for the same reason as the two above: adding rather than mixing
## renders a completely plausible frame at the ~65 degree incidence the ice was
## fitted at, where the term is four levels. It only shows at a grazing angle,
## and then it is +135.
static func _the_mirror_takes_its_share(t: TestCase) -> void:
	t.begin("lighting/the ice mirror is a split, not an addition")
	var text: String = _read("res://shaders/terrain.gdshader")
	t.ok(text.contains("mirror_share"),
		"terrain.gdshader names the share the mirror takes")
	t.ok(text.contains("* (1.0 - mirror_share)"),
		"and removes it from ALBEDO, so the two halves sum to the surface")
	# The grazing end of Schlick is the roughness, not 1: a rough dielectric
	# never becomes a perfect mirror, and unity here is what let a white sky in
	# at full strength.
	t.ok(text.contains("max(1.0 - ice_roughness"),
		"the grazing Fresnel is capped by the roughness the surface declares")
	# The far field a low ray lands on is gated on distance as well as on the
	# ray's elevation, and dropping the distance half is the silent half: it
	# brightens a distant lake and *darkens* a near gully, because up close a low
	# ray lands on the near bank rather than on fog.
	t.ok(text.contains("ice_horizon_distance") and text.contains("far_off"),
		"the distant-field reflection is gated on distance, not just elevation")

static func _the_renderer_rule(t: TestCase) -> void:
	t.begin("lighting/which renderer")
	# The negation, not the platform: under `--headless` there is no
	# [RenderingDevice], so this run answers "Compatibility" whatever the
	# desktop build does, and asserting otherwise would assert the harness.
	t.ok(RenderBackend.supports_light_shadows() == (not RenderBackend.is_compatibility()),
		"shadows are available exactly where the renderer is not Compatibility")
	t.ok(not RenderBackend.describe().is_empty(), "the renderer has a name")
	# Compatibility is what a headless run has, and it is also the answer the
	# web build gives — which is the one that matters, because the sRGB-blended
	# shadow pass is what `shadow_enabled` has to stay away from there.
	t.ok(RenderBackend.is_compatibility(),
		"a headless run has no RenderingDevice, so it reads as Compatibility")

static func _the_project_ships_two_renderers(t: TestCase) -> void:
	t.begin("lighting/what project.godot ships")
	# Read the file rather than `ProjectSettings`, which resolves the override
	# for *this* platform and so cannot see the other one.
	var text: String = _read("res://project.godot")
	t.ok(text.contains("renderer/rendering_method=\"mobile\""),
		"the desktop default is the Mobile renderer, which lights in linear")
	t.ok(text.contains("renderer/rendering_method.web=\"gl_compatibility\""),
		"the web build is Compatibility, because WebGL2 has nothing else")
	# Godot files a phone's shadow filter under the `mobile` tag as Hard — one
	# depth tap, every texel a stair on the snow. Only a phone reads the tagged
	# key, so only a phone showed it.
	t.ok(ProjectSettings.property_get_revert(
		"rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality.mobile") == 0,
		"the engine ships phones a hard-edged sun shadow")
	# Soft Medium on both: Soft Low's per-pixel rotated taps wait for a TAA
	# that Mobile does not have, and leave the penumbra dithered.
	t.ok(text.contains("directional_shadow/soft_shadow_filter_quality=3"),
		"the desktop filters the sun's shadow at Soft Medium")
	t.ok(text.contains("directional_shadow/soft_shadow_filter_quality.mobile=3"),
		"and so does a phone, which would otherwise read the tagged Hard default")

static func _the_player_picks_the_renderer(t: TestCase) -> void:
	t.begin("lighting/android and the desktop pick their renderer")
	# The engine reads the choice before any script runs, and only through this
	# setting, so a menu row without it would be a dead knob.
	var text: String = _read("res://project.godot")
	t.ok(text.contains('config/project_settings_override.android="%s"'
		% RenderBackend.CHOICE_PATH),
		"on Android the engine reads the player's renderer choice at launch")
	t.ok(text.contains('config/project_settings_override.pc="%s"'
		% RenderBackend.CHOICE_PATH),
		"and on a desktop")
	t.ok(not text.contains("config/project_settings_override="),
		"and nowhere else, so a browser keeps its own renderer")
	t.ok(RenderBackend.can_choose(), "so a desktop run offers the choice")
	t.ok(RenderBackend.choices() == [RenderBackend.FORWARD_PLUS, RenderBackend.MOBILE,
		RenderBackend.COMPATIBILITY], "between all three renderers")

	# Through the real file, which this run has already read; put back
	# whatever a previous run left there.
	var kept: PackedByteArray = FileAccess.get_file_as_bytes(RenderBackend.CHOICE_PATH)
	var had: bool = FileAccess.file_exists(RenderBackend.CHOICE_PATH)
	t.ok(RenderBackend.choose(RenderBackend.COMPATIBILITY) == OK, "Compatibility can be chosen")
	t.ok(RenderBackend.chosen() == RenderBackend.COMPATIBILITY, "and is what the next launch asks for")
	# The file is a `project.godot` fragment: the section and key have to be
	# the ones the engine looks up, not merely ones `chosen` can read back.
	var file := ConfigFile.new()
	file.load(RenderBackend.CHOICE_PATH)
	t.ok(file.get_value("rendering", "renderer/rendering_method", "") == "gl_compatibility",
		"written under the project setting the engine reads")
	# Godot's own `rendering_method.mobile = "mobile"` outranks the plain key on
	# a phone, which has the `mobile` tag; a file without the tagged key is read
	# and ignored there, and a desktop run cannot show it.
	# Asked of the engine's default rather than the live value, which a desktop
	# run has already read from a choice left in the file.
	t.ok(ProjectSettings.property_get_revert("rendering/renderer/rendering_method.mobile")
		== "mobile", "the engine still ships a tagged Mobile default for phones")
	t.ok(file.get_value("rendering", "renderer/rendering_method.mobile", "") == "gl_compatibility",
		"so the choice overrides the tagged key too")
	t.ok(RenderBackend.choose(RenderBackend.FORWARD_PLUS) == OK, "Forward+ can be chosen")
	t.ok(RenderBackend.chosen() == RenderBackend.FORWARD_PLUS, "and is read back")
	t.ok(RenderBackend.choose(RenderBackend.MOBILE) == OK, "Mobile can be chosen")
	t.ok(not FileAccess.file_exists(RenderBackend.CHOICE_PATH),
		"which is the project default, so it leaves no file behind")
	t.ok(RenderBackend.chosen() == RenderBackend.MOBILE, "and no file reads as Mobile")
	if had:
		var f: FileAccess = FileAccess.open(RenderBackend.CHOICE_PATH, FileAccess.WRITE)
		f.store_buffer(kept)
