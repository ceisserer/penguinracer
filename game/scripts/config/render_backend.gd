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

## A short name for the running renderer, for a log line or a capture's
## provenance. Not parsed by anything.
static func describe() -> String:
	if is_compatibility():
		return "Compatibility"
	return str(ProjectSettings.get_setting("rendering/renderer/rendering_method",
		"forward_plus"))
