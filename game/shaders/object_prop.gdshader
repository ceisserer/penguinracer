// Solid course props — boulders, stones, logs, stumps ([PropMesh]).
//
// ETR has no such objects: everything it stands on a course is a picture on
// crossed quads. These are real meshes, so this is an ordinary opaque surface:
// the colour is the mesh's vertex colour (the mesh builder paints rock, bark
// and cut wood), broken up by a little object-space noise so two instances of
// one mesh do not read as copies, and dusted with snow wherever a face looks
// up. Lit through ETR's clamp and faded by the atmosphere like everything else.
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx,
	ambient_light_disabled;

#include "res://shaders/etr_illumination.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

// Torchlight on this fragment, handed from `fragment()` to `light()`, which
// sums it inside the clamp. Black by day. See `atmo_torch_glow`.
varying vec3 torch_glow;

// How much of an upward face is snow, 0..1. A forest floor keeps less snow
// than open ground, so the default is a dusting rather than a cap.
uniform float snow_cover : hint_range(0.0, 1.0) = 0.55;
uniform vec3 snow_color : source_color = vec3(0.92, 0.95, 1.0);
// How strongly the object-space noise mottles the painted colour.
uniform float mottle : hint_range(0.0, 1.0) = 0.35;
// Metres per noise cell, before the instance's scale.
uniform float mottle_scale = 0.18;

// Where on the mesh, in world metres from the instance's origin — so the noise
// has the same grain on a boulder and on a pebble, and a different pattern on
// every instance (the origin is part of the hash).
varying vec3 grain_pos;

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x),
			mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x),
			mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

// [b]`ALBEDO` is not in the same units on the two renderers.[/b] Mobile takes
// it as linear; Compatibility sRGB-decodes it, and hands a `source_color`
// uniform in undecoded — so a textured surface agrees by accident (sRGB in,
// decoded once) and this one, whose colours are the mesh's *linear* vertex
// colours ([PropMesh] stores them `srgb_to_linear`), was decoded twice. Measured
// with a constant: `ALBEDO = vec3(0.18)` fully lit read 118 on Mobile and 45 on
// Compatibility, which is `srgb_to_linear(0.18)`; the rock faces that get no
// snow — the undersides a racer on the trail looks up at — went near black.
// So the colour is built in linear on both, and encoded for Compatibility.
vec3 snow_linear() {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return mix(snow_color / 12.92, pow((snow_color + 0.055) / 1.055, vec3(2.4)),
		step(vec3(0.04045), snow_color));
#else
	return snow_color;
#endif
}

vec3 albedo_out(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
#else
	return c;
#endif
}

void vertex() {
	grain_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 p = grain_pos / mottle_scale;
	float n = value_noise(p) * 0.6 + value_noise(p * 2.7) * 0.4;
	vec3 base = COLOR.rgb * (1.0 + (n - 0.5) * 2.0 * mottle);

	// Snow on whatever faces the sky, thinned by the same noise so its edge is
	// ragged rather than a contour line.
	vec3 world_n = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	float up = smoothstep(0.35, 0.8, world_n.y + (n - 0.5) * 0.5);
	float snow = up * snow_cover;
	ALBEDO = albedo_out(clamp(mix(base, snow_linear(), snow), 0.0, 1.0));
	ROUGHNESS = 0.9;
	METALLIC = 0.0;

	torch_glow = atmo_torch_glow(grain_pos, world_n);
	// The sky's haze and the valley mist, not the engine's flat fog: see
	// `atmosphere.gdshaderinc`.
	FOG = atmo_fog_at((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD);
}

// ETR's clamp, as on every other lit surface (`etr_illumination.gdshaderinc`).
void light() {
	DIFFUSE_LIGHT += min(etr_illumination(LIGHT_COLOR / PI,
		max(dot(NORMAL, LIGHT), 0.0), ATTENUATION, vec3(1.0)) + torch_glow,
		vec3(1.0));
}
