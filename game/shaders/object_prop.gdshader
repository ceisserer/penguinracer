// Solid course props — boulders, stones, logs, stumps ([PropMesh]) — and Snow
// Park's furniture: the snowmen, the lift, the buildings and the fences.
//
// ETR has no such objects: everything it stands on a course is a picture on
// crossed quads. These are real meshes, so this is an ordinary opaque surface:
// the colour is the mesh's vertex colour (the mesh builder paints rock, bark
// and cut wood), broken up by a little object-space noise so two instances of
// one mesh do not read as copies, and dusted with snow wherever a face looks
// up. Lit through ETR's clamp and faded by the atmosphere like everything else.
//
// A building's faces are drawn as what they are made of — courses of logs,
// boards, rubble stone, plaster, shingles, concrete — from `UV2.x`, the
// [enum PropMesh.Surface] its builder tagged them with, over `UV`, the face's
// own coordinates in metres. Drawn here rather than from a picture, so
// nothing has to pass the licence audit; and read from the two built-in UVs,
// so it costs no varying (`test_shader_budget.gd`). A mesh without them reads
// 0: plain, as every prop was.
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

float hash2(vec2 p) {
	return hash3(vec3(p, 7.13));
}

float noise2(vec2 p) {
	return value_noise(vec3(p, 0.37));
}

// The nearest and second-nearest of a jittered lattice's points to `p`, and
// the nearest one's cell: rubble stones and their mortar.
vec4 cells(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float d1 = 8.0;
	float d2 = 8.0;
	vec2 id = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = vec2(hash2(i + g), hash2(i + g + 31.7)) * 0.8 + 0.1;
			float d = length(g + o - f);
			if (d < d1) {
				d2 = d1;
				d1 = d;
				id = i + g;
			} else if (d < d2) {
				d2 = d;
			}
		}
	}
	return vec4(d1, d2, id);
}

// What [param kind] of building face looks like at [param uv] (metres on it),
// over its painted colour [param base]. [param tilt] comes back for the
// logs: how far their round faces turn up (+) or down (−) here, −1..1.
vec3 building_surface(float kind, vec2 uv, vec3 base, inout float rough, out float tilt) {
	tilt = 0.0;
	if (kind < 1.5) {
		// Logs, a course every LOG_COURSE (PropMesh), seams on its multiples:
		// each log round between them, its own shade, grain along it, knots.
		float v = uv.y / 0.34;
		float row = floor(v);
		float f = fract(v);
		float shade = 0.8 + 0.35 * hash2(vec2(row, 3.1));
		float round_face = sin(3.14159 * f);
		tilt = (f - 0.5) * 2.0;
		// Broad streaks along the log, and the fine lines of its rings, wavering.
		float grain = noise2(vec2(uv.x * 0.7 + row * 13.1, f * 9.0)) * 0.6
			+ noise2(vec2(uv.x * 2.3, f * 31.0 + row)) * 0.4;
		grain *= 0.85 + 0.15 * sin(f * 90.0 + noise2(vec2(uv.x * 0.9, row * 3.0)) * 12.0);
		vec2 knot_cell = vec2(floor(uv.x / 1.1), row);
		vec2 knot_at = vec2((knot_cell.x + 0.2 + 0.6 * hash2(knot_cell)) * 1.1,
			(row + 0.5) * 0.34);
		float knot = hash2(knot_cell + 5.3) > 0.6
			? 1.0 - smoothstep(0.02, 0.05, length((uv - knot_at) * vec2(0.6, 1.0))) : 0.0;
		rough = 0.85;
		return base * shade * mix(0.55, 1.08, sqrt(round_face)) * (0.82 + 0.3 * grain)
			* (1.0 - 0.45 * knot);
	}
	if (kind < 2.5) {
		// Boards 16 cm wide, a dark gap between, each its own shade, grain
		// along it.
		float u = uv.x / 0.16;
		float col = floor(u);
		float f = fract(u);
		float gap = smoothstep(0.0, 0.07, f) * smoothstep(1.0, 0.93, f);
		float grain = noise2(vec2(f * 6.0 + col * 7.7, uv.y * 1.6)) * 0.6
			+ noise2(vec2(f * 19.0, uv.y * 5.0 + col)) * 0.4;
		grain *= 0.86 + 0.14 * sin(f * 60.0 + noise2(vec2(col * 3.0, uv.y * 0.8)) * 10.0);
		rough = 0.85;
		return base * (0.85 + 0.3 * hash2(vec2(col, 1.7))) * (0.84 + 0.28 * grain)
			* mix(0.45, 1.0, gap);
	}
	if (kind < 3.5) {
		// Rubble stone: flat stones laid in courses, each its own grey, a
		// little warm or cool, with pale mortar between, and pitted.
		vec4 c = cells(uv * vec2(2.3, 3.4));
		float h = hash2(c.zw);
		float t = hash2(c.zw + 11.0);
		vec3 stone = base * (0.7 + 0.5 * h) * mix(vec3(1.06, 1.0, 0.92), vec3(0.94, 0.98, 1.06), t);
		stone *= 0.88 + 0.24 * noise2(uv * 14.0);
		float edge = c.y - c.x;
		stone *= mix(0.7, 1.0, smoothstep(0.03, 0.2, edge));
		vec3 mortar = vec3(dot(base, vec3(0.33))) * 1.35;
		rough = 0.95;
		return mix(mortar, stone, smoothstep(0.035, 0.07, edge));
	}
	if (kind < 4.5) {
		// Plaster: trowelled unevenly, a fine grain, and grey splash where it
		// meets the plinth.
		float cloud = noise2(uv * 1.3) * 0.6 + noise2(uv * 4.1) * 0.4;
		float grain = noise2(uv * 40.0);
		float splash = (1.0 - smoothstep(0.55, 1.4, uv.y)) * (0.6 + 0.4 * noise2(uv * 9.0));
		rough = 0.95;
		return mix(base * (0.93 + 0.1 * cloud + 0.05 * grain), base * vec3(0.62, 0.6, 0.57),
			splash * 0.5);
	}
	if (kind < 5.5) {
		// Shingles in rows down the pitch from the ridge, each row's offset by
		// half a shingle, each one its own shade, a shadow under each row.
		float r = abs(uv.x) / 0.2;
		float row = floor(r);
		float f = fract(r);
		float u = uv.y / 0.28 + 0.5 * mod(row, 2.0);
		float col = floor(u);
		float gap = smoothstep(0.0, 0.06, fract(u)) * smoothstep(1.0, 0.94, fract(u));
		rough = 0.9;
		return base * (0.75 + 0.45 * hash2(vec2(row, col))) * mix(0.5, 1.0, gap)
			* mix(1.0, 0.6, smoothstep(0.75, 1.0, f));
	}
	// Concrete: cast in shuttering half a metre high, a seam at each lift,
	// clouded, pitted with pores.
	float cloud = noise2(uv * 2.0) * 0.6 + noise2(uv * 7.0) * 0.4;
	float lift = 1.0 - (1.0 - smoothstep(0.0, 0.025, fract(uv.y / 0.5)))
		* (1.0 - smoothstep(1.0, 0.975, fract(uv.y / 0.5)));
	// Round pores, a few millimetres across, not every lattice point one.
	vec4 pore = cells(uv * 28.0);
	float pores = (1.0 - smoothstep(0.08, 0.16, pore.x)) * step(0.55, hash2(pore.zw));
	rough = 0.95;
	return base * (0.86 + 0.24 * cloud + 0.06 * noise2(uv * 35.0)) * mix(0.68, 1.0, lift)
		* (1.0 - 0.35 * pores);
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
	float rough = 0.9;
	float tilt = 0.0;
	vec3 base;
	if (UV2.x > 0.5) {
		// A building's face: drawn as what it is made of, the mottle only a
		// trace over it.
		base = building_surface(UV2.x, UV, COLOR.rgb * (1.0 + (n - 0.5) * 0.5 * mottle), rough,
			tilt);
	} else {
		base = COLOR.rgb * (1.0 + (n - 0.5) * 2.0 * mottle);
	}

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
	ROUGHNESS = rough;
	// A log's round face, turned up toward its top and down toward its foot —
	// after the snow, which reads the face as built.
	if (tilt != 0.0 && snow < 0.5) {
		vec3 up = normalize(mat3(VIEW_MATRIX) * MODEL_MATRIX[1].xyz);
		NORMAL = normalize(NORMAL + up * tilt * 0.45);
	}
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
