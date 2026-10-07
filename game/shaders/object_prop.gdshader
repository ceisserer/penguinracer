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
// own coordinates in metres. Read from the two built-in UVs, so it costs no
// varying (`test_shader_budget.gd`). A mesh without them reads 0: plain, as
// every prop was.
//
// Two ways to draw a surface. Procedurally, below (`building_surface`): no
// picture, nothing to download, and what every preset below MEDIUM and every
// build without the material pack draws. Or, compiled in with
// `PROP_TEXTURES` ([method CourseRoot.prop_shader]), from photographs: six CC0
// materials (`assets/materials/`, `CREDITS.md`) in two texture arrays —
// colour with roughness in alpha, and a normal map — for the logs, boards,
// rubble stone and shingles of the buildings, and the rock and bark of the
// boulders, stones, logs and stumps (`ROCK`, `BARK`; plain without the
// photographs). Plaster and concrete stay procedural either way. A photograph
// does not bring its own colour: it is divided by its own mean (its last mip)
// and multiplied into the painted one, as the terrain's rock detail is, so a
// boulder keeps its grey and its moss, a shutter its paint, and the photo
// gives the grain, the relief under the sun and the roughness.
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

#ifdef PROP_TEXTURES
// The photographed materials, a layer each — see `tools/pack_prop_materials.sh`.
// Two samplers for all six (the terrain's texture-unit trap).
uniform sampler2DArray prop_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray prop_normal : filter_linear_mipmap_anisotropic, repeat_enable;
// How far the photograph's light and dark move the painted colour (0: not at
// all), and how deep its relief reads (0: flat).
uniform float photo_detail : hint_range(0.0, 1.0) = 1.0;
uniform float photo_relief : hint_range(0.0, 2.0) = 1.0;
#endif

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
// A `source_color` uniform or sampler, linear on both renderers.
vec3 source_linear(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
#else
	return c;
#endif
}

vec3 snow_linear() {
	return source_linear(snow_color);
}

vec3 albedo_out(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
#else
	return c;
#endif
}

#ifdef PROP_TEXTURES
// [enum PropMesh.Surface], as `UV2.x` carries it.
const float SURFACE_LOGS = 1.0;
const float SURFACE_BOARDS = 2.0;
const float SURFACE_STONE = 3.0;
const float SURFACE_SHINGLES = 5.0;
const float SURFACE_ROCK = 7.0;
const float SURFACE_BARK = 8.0;
// PropMesh.LOG_COURSE, and where the log wall's photograph has its seams: at
// this share of its width, then every seventh (fitted to its normal map, whose
// slope across each log is a sawtooth that jumps at the seam).
const float LOG_COURSE = 0.34;
const float LOG_PHOTO_SEAM = 0.135;

// What a photograph gives a fragment: its colour as a ratio over the
// material's mean (rgb) and its roughness (a), and the slope its normal map
// adds, in the instance's own frame.
struct Photo {
	vec4 tint_rough;
	vec3 slope;
};

// The mean colour of [param layer]: its last mip, 1x1 at 1024².
vec3 photo_mean(float layer) {
	return max(source_linear(textureLod(prop_albedo, vec3(0.5, 0.5, layer), 10.0).rgb),
		vec3(0.01));
}

// [param layer] laid flat on the plane through [param u] and [param v] (unit
// axes of the instance's frame; [param v] runs down the picture), one
// [param tile] metres across, at [param p].
Photo photo_plane(float layer, vec3 mean, vec3 p, vec3 u, vec3 v, float tile) {
	vec2 at = vec2(dot(p, u), dot(p, v)) / tile;
	vec4 c = texture(prop_albedo, vec3(at, layer));
	vec3 n = texture(prop_normal, vec3(at, layer)).rgb * 2.0 - 1.0;
	Photo o;
	o.tint_rough = vec4(min(source_linear(c.rgb) / mean, vec3(3.0)), c.a);
	// An OpenGL normal map: green leans up the picture, against v.
	o.slope = n.x * u - n.y * v;
	return o;
}

Photo photo_blend(Photo a, Photo b, Photo c, vec3 w) {
	Photo o;
	o.tint_rough = a.tint_rough * w.x + b.tint_rough * w.y + c.tint_rough * w.z;
	o.slope = a.slope * w.x + b.slope * w.y + c.slope * w.z;
	return o;
}

// The photograph on a face of surface [param kind] at [param p] — metres in the
// instance's own frame, which for a building is the frame [PropMesh] built it
// in — whose normal there, in that frame, is [param n]. A building's face is
// one plane, picked as [method PropMesh._tri_shaded] picks its UV; a rock and
// bark are blended across all three, since neither has a face to follow.
// [param grain] is the axis a bark's grain runs along (0 X, a log; 1 Y, a
// stump). False for a surface with no photograph.
bool photo_surface(float kind, float grain, vec3 p, vec3 n, out Photo o) {
	vec3 a = abs(n);
	const vec3 X = vec3(1.0, 0.0, 0.0);
	const vec3 Y = vec3(0.0, 1.0, 0.0);
	const vec3 Z = vec3(0.0, 0.0, 1.0);
	if (kind < 0.5) {
		return false;
	}
	if (kind > SURFACE_ROCK - 0.5) {
		bool bark = kind > SURFACE_BARK - 0.5;
		float layer = bark ? 5.0 : 4.0;
		// Pine bark's plates at a 1.5 m tile, a boulder's fractures at 2 m.
		float tile = bark ? 1.5 : 2.0;
		vec3 mean = photo_mean(layer);
		vec3 w = a * a;
		w *= w;
		w /= w.x + w.y + w.z;
		// Each plane read with the picture upright; bark's furrows, which run
		// down its picture, turned along the grain wherever the plane holds it.
		Photo px = photo_plane(layer, mean, p, Z, -Y, tile);
		Photo py = photo_plane(layer, mean, p, bark && grain < 0.5 ? Z : X,
			bark && grain < 0.5 ? X : Z, tile);
		Photo pz = photo_plane(layer, mean, p, bark && grain < 0.5 ? Y : X,
			bark && grain < 0.5 ? X : -Y, tile);
		o = photo_blend(px, py, pz, w);
		if (bark) {
			// Pine bark is red under its grey plates; on a dead log's brown
			// that read as rust. Keep its light and dark, and a little of it.
			float grey = dot(o.tint_rough.rgb, vec3(0.2126, 0.7152, 0.0722));
			o.tint_rough.rgb = mix(vec3(grey), o.tint_rough.rgb, 0.4);
		}
		return true;
	}
	float layer;
	float tile;
	if (kind < SURFACE_LOGS + 0.5) {
		// Seven logs in the picture, drawn the height of seven courses.
		layer = 0.0;
		tile = 7.0 * LOG_COURSE;
	} else if (kind < SURFACE_BOARDS + 0.5) {
		layer = 1.0;
		tile = 1.8;
	} else if (kind < SURFACE_STONE + 0.5) {
		layer = 2.0;
		tile = 2.0;
	} else if (abs(kind - SURFACE_SHINGLES) < 0.5) {
		layer = 3.0;
		tile = 1.4;
	} else {
		return false;
	}
	vec3 mean = photo_mean(layer);
	vec3 u;
	vec3 v;
	if (a.y >= a.x && a.y >= a.z) {
		// Level, or a roof: shingles in rows along the ridge (Z), each row
		// lower down the pitch than the last, from the ridge at X = 0.
		bool shingles = layer > 2.5;
		u = shingles ? Z : X;
		v = shingles ? X * sign(p.x) : Z;
	} else {
		vec3 along = a.x >= a.z ? Z : X;
		// The picture's logs run down it, and its boards across it: the logs
		// turned to lie along the wall, the boards to stand up it.
		u = layer < 1.5 ? Y : along;
		v = layer < 1.5 ? along : -Y;
	}
	if (layer < 0.5) {
		// The picture's seams on the courses' (up the wall, its u)...
		p.y += LOG_PHOTO_SEAM * tile;
	}
	o = photo_plane(layer, mean, p, u, v, tile);
	if (layer < 0.5 && u.y > 0.5) {
		// ...and each log's round face falling away into the seam's shadow,
		// as the procedural logs do: the photograph's own shading is too
		// faint to part one log from the next.
		float f = fract((p.y - LOG_PHOTO_SEAM * tile) / LOG_COURSE);
		o.tint_rough.rgb *= mix(0.55, 1.08, sqrt(sin(3.14159 * f)));
	}
	return true;
}
#endif

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
	vec3 world_n = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
#ifdef PROP_TEXTURES
	// The instance's own frame, in metres: its axes without their scale (a
	// marker turns and stretches, never shears).
	mat3 frame = mat3(normalize(MODEL_MATRIX[0].xyz), normalize(MODEL_MATRIX[1].xyz),
		normalize(MODEL_MATRIX[2].xyz));
	vec3 local_n = world_n * frame;
	Photo photo;
	bool photographed = photo_surface(UV2.x, UV2.y, (grain_pos - MODEL_MATRIX[3].xyz) * frame,
		local_n, photo);
#else
	const bool photographed = false;
#endif
	if (photographed) {
#ifdef PROP_TEXTURES
		// The painted colour, a trace of the mottle, and the photograph's
		// light and dark over it.
		base = COLOR.rgb * (1.0 + (n - 0.5) * 0.5 * mottle)
			* mix(vec3(1.0), photo.tint_rough.rgb, photo_detail);
		rough = photo.tint_rough.a;
#endif
	} else if (UV2.x > 0.5 && UV2.x < 6.5) {
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
#ifdef PROP_TEXTURES
	// The photograph's relief, in the face's own plane, under the sun — and
	// not under snow, which lies smooth over it.
	if (photographed && snow < 0.5) {
		vec3 slope = photo.slope - local_n * dot(photo.slope, local_n);
		vec3 shade_n = frame * normalize(local_n + slope * photo_relief);
		NORMAL = normalize(mat3(VIEW_MATRIX) * shade_n);
	}
#endif
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
