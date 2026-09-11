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
]
const INCLUDE_PATH := "res://shaders/etr_illumination.gdshaderinc"

static func run(t: TestCase) -> void:
	_the_include_exists(t)
	_every_lit_shader_clamps(t)
	_nobody_multiplies_the_albedo_twice(t)
	_the_mirror_takes_its_share(t)
	_the_renderer_rule(t)
	_the_project_ships_two_renderers(t)

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
