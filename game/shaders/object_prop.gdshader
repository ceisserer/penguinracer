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
	ambient_light_disabled, skip_vertex_transform;

#include "res://shaders/etr_illumination.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

// Torchlight on this fragment, handed from `fragment()` to `light()`, which
// sums it inside the clamp. Black by day. See `atmo_torch_glow`.
varying vec3 torch_glow;

// How much of what faces the sky is snowed on, 0..1: the snow lies in whole
// patches with bark or rock between them, never as a tint. A forest floor
// keeps less snow than open ground, so the default leaves gaps even on top:
// 0.45 covers about 40 % of a level face, 15 % of one tilted 30 degrees and
// next to nothing on a flank. (It used to be how much snow was mixed into every
// upward face, which painted a log's whole top one flat grey; and then, with the
// patch noise too weak to cross the threshold, every level face went wholly white.)
uniform float snow_cover : hint_range(0.0, 1.0) = 0.45;
// Metres per snow patch.
uniform float snow_patch_scale = 0.6;
uniform vec3 snow_color : source_color = vec3(0.92, 0.95, 1.0);
// How strongly the object-space noise mottles the painted colour.
uniform float mottle : hint_range(0.0, 1.0) = 0.35;
// Metres per noise cell, before the instance's scale.
uniform float mottle_scale = 0.18;
// How high, in metres, snow lies banked against a prop's foot where the ground
// round it is all snow — on a level face; half that up a flank. The prop meets
// the ground's own snow there rather than standing on it: a stump's root flare
// looks up but stands only a few centimetres high, and painted as bark it was a
// dark skirt laid out on the snow (Forest Trail, once `snow_cover` dropped from
// 0.55 to 0.45 and stopped covering every level face).
uniform float foot_drift = 0.1;

// Where on the mesh, in world metres from the instance's origin — so the noise
// has the same grain on a boulder and on a pebble, and a different pattern on
// every instance (the origin is part of the hash).
varying vec3 grain_pos;
// x: metres above the ground plane the instance stands on, along its own up.
// y: how much of the ground there is snow, 0..1 — `INSTANCE_CUSTOM.r`, which
// [CourseRoot] fills from the course's splat; 0 (no drift) for anything not
// laid on the ground, and wherever nobody filled it.
varying vec2 foot;

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

// [b]The normal is transformed here, not by the engine.[/b] Godot turns a
// MultiMesh instance's normal with the instance matrix itself, and swaps in the
// inverse-transpose only when the *node* is non-uniformly scaled (the
// `NON_UNIFORM_SCALE` flag, in `scene_forward_mobile.glsl` and the
// Compatibility `scene.glsl` alike) — never for a per-instance scale. A prop's
// marker stretches it: a trunk is 10-20 times longer than thick. Turned by the
// plain matrix, the small along-the-axis tilt every bark facet has in the unit
// mesh is multiplied by that ratio, the two triangles of each slightly
// non-planar quad point far apart, and the trunk lights and snows in a
// checkerboard (Mountain Forest's fallen and lodged trunks, 2026-09-30).
void vertex() {
	grain_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 up = MODEL_MATRIX[1].xyz;
	foot = vec2(dot(grain_pos - MODEL_MATRIX[3].xyz, up) / max(length(up), 1e-4),
		INSTANCE_CUSTOM.r);
	mat3 normal_matrix = transpose(inverse(mat3(MODEL_MATRIX)));
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	NORMAL = normalize(mat3(VIEW_MATRIX) * (normal_matrix * NORMAL));
}

void fragment() {
	vec3 p = grain_pos / mottle_scale;
	float n = value_noise(p) * 0.6 + value_noise(p * 2.7) * 0.4;
	vec3 base = COLOR.rgb * (1.0 + (n - 0.5) * 2.0 * mottle);

	// Snow on whatever faces the sky, in patches: a coarse noise decides where
	// it lies, the fine one rags the patch's edge, and the more a face looks up
	// the more of it is covered. `snow_cover` moves the threshold.
	vec3 world_n = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	// The finer octave is for props smaller than a patch: a stone would
	// otherwise sit inside one and go wholly white on white.
	float patch = value_noise(grain_pos / snow_patch_scale) * 0.6
		+ value_noise(grain_pos / (snow_patch_scale * 0.3)) * 0.4;
	// The two octaves average out: `patch` has a spread of only ~0.13 round 0.5,
	// so it needs a large weight to open gaps on a level top at all.
	float lie = world_n.y + (patch - 0.5) * 1.2 + (n - 0.5) * 0.25;
	float threshold = mix(1.45, 0.55, snow_cover);
	float snow = smoothstep(threshold - 0.05, threshold + 0.05, lie);
	// The drift round the foot: as high as the ground is snowy, higher on what
	// faces up, its top line ragged by the same noise.
	float reach = foot_drift * foot.y * (0.5 + 0.5 * max(world_n.y, 0.0))
		* (1.0 + (n - 0.5) * 1.2 + (patch - 0.5) * 1.5);
	snow = max(snow, step(0.001, foot.y) * (1.0 - smoothstep(reach - 0.01, reach + 0.01, foot.x)));
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
