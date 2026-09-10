// ETR's fixed-function illumination, for every shader in the game that is lit.
//
// The original sums the ambient and the sun into one value, **clamps that to
// one**, and only then multiplies the texture:
//
//     colour = texture * clamp(ambient + diffuse * N·L, 0, 1)
//
// A PBR renderer does it the other way round — multiply first, clamp the
// product — and the difference is not subtle on a snow course. `snow.png` is
// (236, 245, 255), so in the original a fully sunlit slope reads exactly that
// and keeps every bit of its texture, however hard the sun is shining. Multiply
// first and the same slope goes to flat 255 white the moment the illumination
// passes `1 / albedo`, which on snow is about 1.2 — and then no choice of gain
// helps, because two courses under the same sun want gains a factor of 1.75
// apart. That was "the left bank at Bumpy Ride is a white sheet with no form in
// it". See history §24.
//
// Reproducing it needs two things of every shader that includes this:
//
//   1. `render_mode ambient_light_disabled`, because the engine adds its
//      ambient *after* the light loop, where the sum can no longer happen. The
//      ambient arrives as `etr_ambient` instead.
//   2. a `light()` that writes `DIFFUSE_LIGHT += etr_illumination(...)` and
//      **no `ALBEDO`**. Godot multiplies the accumulated diffuse light by
//      `ALBEDO` once, after the light loop, so a shader that writes
//      `ALBEDO * ...` squares it.
//
// Both are easy to half-do and neither fails loudly: forget (1) and the ambient
// lands twice, forget (2) and every surface is its own albedo too dark.
// `tests/test_shaders.gd` asserts that every shader including this file does
// both.
//
// [b]This replaces the engine's specular as well as its diffuse[/b], simply by
// existing: a shader with a `light()` gets no lighting the function does not
// write, and only `shaders/terrain.gdshader` writes `SPECULAR_LIGHT`. That is
// the original — `light.lst` gives its lights a black `[spec]` and the trees
// and the character have no specular term at all.

// The environment's ambient, in the linear units a shader works in. What
// `Environment.ambient_light_color` carries after Godot's decode, which is
// [method EnvironmentPreset.ambient_illumination]; whoever owns the material
// pushes it in when the environment is applied.
//
// The default is `tuxracer_sunny`'s, so a material built without a preset — the
// editor, a spike scene, the character preview — still renders in daylight
// rather than in the dark. Which it would otherwise: with the engine's ambient
// off and nothing here, there is no light at all.
uniform vec3 etr_ambient = vec3(0.591, 0.708, 0.980);

// One illumination value, ETR's way round.
//
// [param sun] is the sun's linear colour — `LIGHT_COLOR / PI`, since Godot
// hands `light()` the colour premultiplied by the diffuse BRDF's 1/PI.
// [param shaped] is N·L after whatever the surface does to it (snow wraps it;
// everything else does not). [param shadow] is `ATTENUATION`, and it multiplies
// the sun term alone — a shadowed fragment is one the sun has stopped reaching
// and the ambient still does, which is both the physics and what makes a shadow
// on snow read as blue-white rather than as grey. It is inside the sum, so the
// fragment falls to the ambient and stops there, and outside the clamp, so a
// slope that was sitting on the ceiling actually darkens instead of spending
// the shadow on headroom it had anyway. On the web build it is 1 everywhere —
// see [RenderBackend] — and this is then exactly the original, which has no
// shadow map either.
//
// [param occlusion] scales the ambient only, for a surface that shades itself.
// 1.0 is "nothing in the way".
vec3 etr_illumination(vec3 sun, float shaped, float shadow, float occlusion) {
	return min(etr_ambient * occlusion + sun * shaped * shadow, vec3(1.0));
}
