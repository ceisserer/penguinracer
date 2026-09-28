## Which of Godot's renderers this build is running on, and the one thing that
## follows from it.
##
## The game ships two. The desktop build runs **Mobile** — clustered forward
## lighting on Vulkan — and the web build runs **Compatibility**, because WebGL2
## is the only thing a browser offers and Compatibility is the only renderer
## that targets it. `project.godot` sets both: `rendering_method` is `mobile`
## and `rendering_method.web` is `gl_compatibility`.
##
## [b]The one thing that follows is shadows.[/b] Under Compatibility a light
## that casts them is drawn in a second, additive pass, and that pass is blended
## in sRGB rather than in linear space — a deliberate engine trade-off
## (godotengine/godot#77496, #90259) so that a shadowed light cannot flicker
## between the two blend spaces. What arrives is `srgb(sun)` added to
## `srgb(ambient)` instead of `srgb(ambient + sun)`: five to ten times too much
## sun, with its N·L gradient crushed into the top of the range, so every slope
## facing the sun lands on the same flat value. It is a framebuffer blend, so no
## shader can reach it and no gain can fit around it — the sun's *shape* is
## gone, not just its level. That is what "the snow is way too bright" was, and
## it is why `Sun.shadow_enabled` is decided here and not in `race.tscn`.
##
## Mobile has no such pass. One light loop, one blend, in linear, with the
## shadow arriving as `ATTENUATION` inside it — which is where
## `shaders/terrain.gdshader` wants it anyway, since ETR's illumination clamp
## needs the sun and the ambient summed before either reaches the albedo.
##
## No autoload is named anywhere in this file, deliberately: a static call from
## a test drags the whole class in eagerly, and a script that reaches an
## autoload cannot survive that. See the trap list.
##
## [b]On Android the player picks.[/b] The renderer is chosen before a single
## script runs, so it cannot be switched from the settings screen directly.
## Instead `project.godot` points `application/config/project_settings_override`
## at [constant CHOICE_PATH] on Android only, and the engine reads that file at
## the next launch, as if it were part of `project.godot`. [method choose]
## writes it. Compatibility's driver, OpenGL ES, comes with it: Godot derives
## the driver from the method.
class_name RenderBackend
extends RefCounted

## Whether this build is running the Compatibility renderer.
##
## Asked of the server rather than of `ProjectSettings`, because the setting is
## a per-platform override with a `--rendering-method` on top of it and neither
## is visible from the value: a desktop run passing `--rendering-method
## gl_compatibility` — which is how the web look is checked without a browser —
## has to answer the same as the browser does. A [RenderingDevice] is exactly
## what Compatibility does not have.
##
## `--headless` also answers yes, since the dummy renderer has no device either.
## That is the right answer for the only thing that reads this: a headless run
## draws nothing, and shadows off is the cheaper of the two wrong pictures.
static func is_compatibility() -> bool:
	return RenderingServer.get_rendering_device() == null

## Whether a [Light3D] here can cast a shadow without wrecking the frame.
##
## The same question as [method is_compatibility] with the reason attached, and
## the name callers should use: what they want to know is not which renderer
## this is, it is whether turning the shadow map on is a thing they may do.
static func supports_light_shadows() -> bool:
	return not is_compatibility()

## Where the player's renderer choice lives: a `project.godot` fragment, not a
## [GameConfig] key, because the engine reads it before any autoload exists.
const CHOICE_PATH := "user://renderer.cfg"
const MOBILE := "mobile"
const COMPATIBILITY := "gl_compatibility"

## The keys [constant CHOICE_PATH] sets, relative to its `[rendering]` section.
## The tagged one is the one that counts on a phone: Godot ships a built-in
## `rendering_method.mobile = "mobile"`, Android carries the `mobile` feature
## tag, and a tagged key outranks the plain one — so a file that set only the
## plain key would be read and then ignored. The plain one stays for a platform
## without the tag.
const CHOICE_KEYS: Array[String] = ["renderer/rendering_method",
	"renderer/rendering_method.mobile"]

## Whether this build reads [constant CHOICE_PATH] at startup: only then is
## choosing a renderer something the player can do. Android today.
static func can_choose() -> bool:
	return ProjectSettings.get_setting_with_override(
		"application/config/project_settings_override") == CHOICE_PATH

## The renderer the next launch will ask for: [constant MOBILE] or
## [constant COMPATIBILITY]. Not necessarily the running one: a choice takes
## effect on the next launch, and a phone without Vulkan falls back to
## Compatibility whatever was asked for.
static func chosen() -> String:
	var file := ConfigFile.new()
	if file.load(CHOICE_PATH) != OK:
		return MOBILE
	var method: String = file.get_value("rendering", CHOICE_KEYS[1], MOBILE)
	return COMPATIBILITY if method == COMPATIBILITY else MOBILE

## Ask for [param method] from the next launch on. Mobile is the project's own
## default, so choosing it deletes the file instead of writing it: nothing is
## left to go stale.
static func choose(method: String) -> Error:
	if method != COMPATIBILITY:
		if not FileAccess.file_exists(CHOICE_PATH):
			return OK
		return DirAccess.remove_absolute(CHOICE_PATH)
	var file := ConfigFile.new()
	for key: String in CHOICE_KEYS:
		file.set_value("rendering", key, COMPATIBILITY)
	return file.save(CHOICE_PATH)

## A short name for the running renderer, for a log line or a capture's
## provenance. Not parsed by anything.
static func describe() -> String:
	if is_compatibility():
		return "Compatibility"
	return str(ProjectSettings.get_setting("rendering/renderer/rendering_method",
		"forward_plus"))
