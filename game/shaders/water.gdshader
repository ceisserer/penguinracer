// Shallow standing water: the puddles of a course that has any
// ([CourseData.water], drawn by [WaterRenderer]).
//
// DEVIATION: ETR has no water. This is the ice's treatment of a smooth
// dielectric — the same sky ramp, the same world probe ([IceEnvironment]),
// the same mirrored racers ([IceReflection]), the same Fresnel *split* — on a
// surface that moves: the wind raises waves on it (none, very small or small,
// by [WindField]), a racer wading through it leaves a trough, a bow wave and a
// wake of rings, and what is under it shows through by how deep it is.
//
// [b]Transparent, and why the blend is worked out here.[/b] A puddle is mostly
// the ground under it, darkened and tinted by the water, with the reflection
// laid over that by Fresnel. With `blend_mix` the frame is
// `src · α + ground · (1 − α)`, so the water's own share of the light is
// divided by α before it is written (`inv_alpha`) and the ground's share is
// what α leaves: `α = 1 − t · (1 − F)`, `t` the light that comes back up
// through the water. Both of the terms that are divided stay below one —
// `F / α ≤ 1`, and the murk is dark — so nothing is lost to an 8-bit target
// on the web.
//
// The illumination clamp holds as everywhere else (`etr_illumination`): the
// murk is lit inside it, the reflection is added on SPECULAR_LIGHT and taken
// out of the murk's share, never on EMISSION (the trap list's renderer split).
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley,
	specular_schlick_ggx, ambient_light_disabled;

#include "res://shaders/etr_illumination.gdshaderinc"
#include "res://shaders/atmosphere.gdshaderinc"

// The mesh is built in world space ([WaterRenderer]); UV.x carries the
// signed depth at the vertex (metres of water over the ground, negative on a
// bank), which the fragment stage reads to shade and to find the shore.
varying vec4 v_world_depth;  // vertex: world position, depth
varying vec4 v_sky;          // fragment: water_sky, fresnel
varying vec4 v_glow;         // fragment: torch_glow, inv_alpha

#define world_pos v_world_depth.xyz
#define water_depth v_world_depth.w
// What the water reflects, Fresnel-weighted and already divided by alpha —
// added in light() on SPECULAR_LIGHT, like the ice's `ice_sky`.
#define water_sky v_sky.rgb
#define fresnel v_sky.a
#define torch_glow v_glow.rgb
#define inv_alpha v_glow.a

group_uniforms Water;
// What the water does to the light that goes down through it and comes back
// up, per metre of the path: red first, so a deep puddle reads brown-green
// over its floor and a shallow one is barely there.
uniform vec3 absorption = vec3(5.0, 3.4, 2.8);
// The silt in it, lit like everything else: what the light that does not
// come back up from the floor is turned into. Linear.
uniform vec3 murk_color = vec3(0.045, 0.05, 0.035);
// Metres of water over which the surface comes up out of the ground at the
// shore. The shore itself is where the signed depth crosses zero, the same
// line the physics wades in ([HeightmapSurface.water_depth_at]).
uniform float shore_fade = 0.02;
// As the ice's `ice_reflection` and `ice_roughness`: how soon the surface
// reaches a full mirror as the view flattens, and how far short of one it
// stops. Water is smoother than any ice.
uniform float water_reflection : hint_range(0.0, 2.0) = 1.3;
uniform float water_roughness : hint_range(0.0, 1.0) = 0.06;
uniform float water_specular_strength : hint_range(0.0, 8.0) = 3.0;
uniform float water_gloss : hint_range(16.0, 4096.0) = 900.0;

group_uniforms Waves;
// Seconds, advanced by [WaterRenderer] at the screen's rate; stops on a pause.
uniform float water_time = 0.0;
// Which way the wind blows, flat (x, z), and how steep the waves it raises
// are — 0 on a calm day, which is a still mirror. See
// [method WaterRenderer.wave_steepness_for].
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_steepness = 0.0;
// The ripples a wading racer leaves: one ring per drop, `xy` where, `z` when,
// `w` how hard. A ring of zero strength is an empty slot.
uniform vec4 drops[32];
// The racers in the water now: `xy` where, `zw` their velocity on the flat;
// and how deep each is wading, 0..1, in the matching component.
uniform vec4 bodies[4];
uniform vec4 body_wade = vec4(0.0);

group_uniforms Ice_Shading;
// The same names and the same meaning as `terrain.gdshader`'s, so the
// terrain's setters hand the water everything they hand the ice.
uniform vec3 sky_zenith : source_color = vec3(0.24, 0.39, 0.75);
uniform vec3 sky_horizon : source_color = vec3(0.75, 0.82, 0.92);
uniform vec3 ice_distant_tint : source_color = vec3(1.0);
uniform float ice_horizon_span : hint_range(0.02, 1.0) = 0.5;
uniform float ice_horizon_distance : hint_range(1.0, 300.0) = 80.0;

group_uniforms Character_Reflection;
uniform sampler2D character_reflection : filter_linear, repeat_disable,
	hint_default_transparent;
uniform bool character_reflection_enabled = false;
uniform float character_reflection_opacity : hint_range(0.0, 4.0) = 1.0;
uniform vec3 reflection_plane_point = vec3(0.0);
uniform vec3 reflection_plane_normal = vec3(0.0, 1.0, 0.0);
uniform float reflection_fade_distance : hint_range(0.5, 40.0) = 8.0;
uniform float character_reflection_attachment : hint_range(0.0, 1.0) = 1.0;
// How far the waves drag the mirrored racers sideways, in screen widths per
// unit of slope. More than the ice's: water moves.
uniform float character_reflection_shear : hint_range(0.0, 0.5) = 0.08;

group_uniforms Ice_Environment;
// [IceEnvironment]'s atlas, as on the ice. Declared unconditionally: the
// water's material binds three samplers, nowhere near the 15 a Windows browser
// allows, so it needs no variant the way the terrain does.
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
uniform sampler2D ice_env_atlas : filter_linear, repeat_disable;
#else
uniform sampler2D ice_env_atlas : source_color, filter_linear, repeat_disable;
#endif
uniform float ice_env_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3 ice_env_origin = vec3(0.0);
uniform float ice_env_radius = 60.0;
uniform float ice_env_face_size = 128.0;

// --- the wind's waves -------------------------------------------------------
// Five trains, fanned either side of the wind and short enough to be ripples
// on a puddle (the fetch of a few metres raises nothing longer), each moving
// at its own deep-water speed `sqrt(g / k)`. Lengths are not multiples of each
// other and every train comes and goes in groups of its own (a slow noise per
// train), or their crossings read as a woven grid. The shorter trains are a
// little less steep. A wind-borne noise gusts the whole field in patches, which
// is what a breeze on a puddle looks like.
const float WAVE_TURN[5] = { 0.0, 0.38, -0.52, 0.83, -1.0 };
const float WAVE_LENGTH[5] = { 1.31, 0.83, 0.57, 0.37, 0.23 };
const float WAVE_PHASE[5] = { 0.0, 1.7, 4.1, 2.6, 5.3 };
const float WAVE_SHARE[5] = { 1.0, 0.9, 0.75, 0.6, 0.45 };

// Height and gradient (d/dx, d/dz) of the wind's waves at [param p].
vec3 wind_waves(vec2 p) {
	vec3 sum = vec3(0.0);
	if (wind_steepness <= 0.0) {
		return sum;
	}
	float n = atmo_noise(p * 0.22 - wind_dir * water_time * 0.8);
	float gust = 0.1 + 1.7 * n * n;
	for (int i = 0; i < 5; i++) {
		float c = cos(WAVE_TURN[i]);
		float s = sin(WAVE_TURN[i]);
		vec2 dir = vec2(wind_dir.x * c - wind_dir.y * s, wind_dir.x * s + wind_dir.y * c);
		float k = 6.2831853 / WAVE_LENGTH[i];
		float speed = sqrt(9.81 / k);
		float group = 0.25 + 1.2 * atmo_noise(p * (0.9 / WAVE_LENGTH[i])
			+ vec2(float(i) * 17.3, float(i) * 5.1) - dir * water_time * speed * 0.3);
		float amp = wind_steepness * WAVE_SHARE[i] * group / k;
		float phase = k * (dot(dir, p) - speed * water_time) + WAVE_PHASE[i];
		sum.x += amp * sin(phase);
		sum.yz += amp * k * cos(phase) * dir;
	}
	return sum * gust;
}

// --- the racers' wakes ------------------------------------------------------
// A ring per drop, travelling out at RIPPLE_SPEED as a packet of waves that
// lengthen and spread as it goes, its height falling with the distance run
// and the time. Laid every few tenths of a metre along a racer's path
// ([WaterRenderer]), the rings overlap into a V behind it.
const int MAX_DROPS = 32;
const float RIPPLE_SPEED = 1.1;
const float RIPPLE_LIFE = 3.0;
const float RIPPLE_WIDTH = 0.08;
const float RIPPLE_SPREAD = 0.22;
const float RIPPLE_LENGTH = 0.4;
const float RIPPLE_HEIGHT = 0.03;
const float RIPPLE_DAMPING = 0.9;

vec3 ripples(vec2 p) {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < MAX_DROPS; i++) {
		vec4 d = drops[i];
		float age = water_time - d.z;
		if (d.w <= 0.0 || age < 0.0 || age > RIPPLE_LIFE) {
			continue;
		}
		vec2 off = p - d.xy;
		float r = length(off);
		float front = RIPPLE_SPEED * age;
		float width = RIPPLE_WIDTH + RIPPLE_SPREAD * age;
		float x = r - front;
		if (abs(x) > 3.0 * width) {
			continue;
		}
		float k = 6.2831853 / (RIPPLE_LENGTH * (1.0 + 0.7 * age));
		float env = d.w * RIPPLE_HEIGHT * exp(-x * x / (width * width))
			* exp(-age * RIPPLE_DAMPING) / (1.0 + 2.0 * front);
		float c = cos(k * x);
		float s = sin(k * x);
		sum.x += env * c;
		float dh = env * (-2.0 * x / (width * width) * c - k * s);
		sum.yz += dh * off / max(r, 1e-3);
	}
	return sum;
}

// A gaussian mound of [param amp] centred [param u0] ahead of a body, [param a]
// long and [param b] wide, as height and gradient.
vec3 mound(vec2 q, vec2 fwd, vec2 side, float amp, float u0, float a, float b) {
	float u = dot(q, fwd) - u0;
	float w = dot(q, side);
	float g = amp * exp(-(u * u / (a * a) + w * w / (b * b)));
	return vec3(g, g * (-2.0 * u / (a * a)) * fwd + g * (-2.0 * w / (b * b)) * side);
}

// The water a wading body pushes aside: the trough it sits in, drawn out
// behind it with speed, and the bow wave it shoves ahead.
vec3 wakes(vec2 p) {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		float wade = body_wade[i];
		if (wade <= 0.0) {
			continue;
		}
		vec2 v = bodies[i].zw;
		float speed = length(v);
		vec2 fwd = speed > 0.1 ? v / speed : vec2(0.0, -1.0);
		vec2 side = vec2(-fwd.y, fwd.x);
		vec2 q = p - bodies[i].xy;
		float rush = clamp(speed / 10.0, 0.0, 1.0);
		sum += mound(q, fwd, side, -0.06 * wade, -0.25 * rush, 0.35 + 0.5 * rush, 0.32);
		sum += mound(q, fwd, side, 0.035 * wade * rush, 0.5, 0.22, 0.4);
	}
	return sum;
}

// The atlas lookup of `terrain.gdshader`, verbatim — the face order is
// [IceEnvironment]'s contract with both.
vec2 ice_env_uv(vec3 d) {
	vec3 a = abs(d);
	vec3 f;
	vec3 up;
	float face;
	if (a.x >= a.y && a.x >= a.z) {
		face = d.x > 0.0 ? 0.0 : 1.0;
		f = vec3(sign(d.x), 0.0, 0.0);
		up = vec3(0.0, 1.0, 0.0);
	} else if (a.y >= a.z) {
		face = d.y > 0.0 ? 2.0 : 3.0;
		f = vec3(0.0, sign(d.y), 0.0);
		up = vec3(0.0, 0.0, sign(d.y));
	} else {
		face = d.z > 0.0 ? 4.0 : 5.0;
		f = vec3(0.0, 0.0, sign(d.z));
		up = vec3(0.0, 1.0, 0.0);
	}
	vec3 right = cross(f, up);
	vec2 s = vec2(dot(d, right), dot(d, up)) / max(dot(d, f), 1e-4);
	float inset = 0.5 / ice_env_face_size;
	vec2 uv = clamp(vec2(s.x + 1.0, 1.0 - s.y) * 0.5, vec2(inset), vec2(1.0 - inset));
	vec2 cell = vec2(mod(face, 3.0), floor(face / 3.0));
	return (cell + uv) / vec2(3.0, 2.0);
}

vec3 ice_env_sample(vec3 d) {
	vec3 c = texture(ice_env_atlas, ice_env_uv(d)).rgb;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	c = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
#endif
	return c;
}

// ALBEDO in the units each renderer wants: built in linear, encoded for
// Compatibility, which decodes it (`object_prop.gdshader`, the trap list).
vec3 albedo_out(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
#else
	return c;
#endif
}

// How much the surface may move at [param depth]: none at the shore, so the
// waterline stays where the ground and the physics put it.
float freedom(float depth) {
	return smoothstep(0.0, 0.06, depth);
}

void vertex() {
	float depth = UV.x;
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// The wind and the bodies move the mesh; the ripples are too fine for its
	// 17 cm grid and live in the normal alone.
	vec3 lift = wind_waves(world.xz) + wakes(world.xz);
	world.y += lift.x * freedom(depth);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	v_world_depth = vec4(world, depth);
}

void fragment() {
	float shore = smoothstep(0.0, shore_fade, water_depth);
	if (shore <= 0.0) {
		discard;
	}
	vec3 wave = (wind_waves(world_pos.xz) + ripples(world_pos.xz) + wakes(world_pos.xz))
		* freedom(water_depth);
	vec3 n_geo = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 n = normalize(n_geo - vec3(wave.y, 0.0, wave.z));
	vec3 n_view = normalize(mat3(VIEW_MATRIX) * n);
	NORMAL = n_view;

	float ndv = clamp(dot(n_view, VIEW), 0.0, 1.0);
	float view_dist = length(world_pos - CAMERA_POSITION_WORLD);
	// Schlick at water's F0, capped short of a mirror as the ice is.
	fresnel = clamp(mix(0.02, 1.0 - water_roughness, pow(1.0 - ndv, 5.0)) * water_reflection,
		0.0, 1.0 - water_roughness);

	vec3 refl = mat3(INV_VIEW_MATRIX) * reflect(-VIEW, n_view);
	vec3 reflected = mix(sky_horizon, sky_zenith, smoothstep(0.0, 0.6, refl.y));
	float low_ray = 1.0 - smoothstep(0.0, ice_horizon_span, refl.y);
	float far_off = smoothstep(ice_horizon_distance * 0.25, ice_horizon_distance, view_dist);
	reflected = mix(reflected, ice_distant_tint, low_ray * far_off);

	// One of [IceEnvironment]'s faces: no screen-space terms (see the terrain).
	bool probe_pass = abs(abs(PROJECTION_MATRIX[0][0]) - 1.0) < 1e-3
		&& abs(abs(PROJECTION_MATRIX[1][1]) - 1.0) < 1e-3;
	if (ice_env_strength > 0.0 && !probe_pass) {
		vec3 q = world_pos - ice_env_origin;
		float b = dot(q, refl);
		float c = dot(q, q) - ice_env_radius * ice_env_radius;
		float t = -b + sqrt(max(b * b - c, 0.0));
		vec3 env = ice_env_sample(normalize(q + refl * max(t, 0.0)));
		float inside = 1.0 - smoothstep(ice_env_radius * 0.6, ice_env_radius, length(q));
		reflected = mix(reflected, env, ice_env_strength * inside);
	}
	if (character_reflection_enabled && !probe_pass) {
		float off = abs(dot(world_pos - reflection_plane_point, reflection_plane_normal));
		float plane_fade = 1.0 - smoothstep(reflection_fade_distance * 0.5,
			reflection_fade_distance, off);
		if (plane_fade > 0.0) {
			// The waves drag the mirror sideways by how far they have bent the
			// normal off the mesh's, as the ice's relief does.
			vec2 shear = (n_view.xy - (mat3(VIEW_MATRIX) * n_geo).xy)
				* character_reflection_shear;
			vec4 mirror = texture(character_reflection,
				clamp(SCREEN_UV + shear, vec2(0.0), vec2(1.0)));
			vec3 mirror_rgb = mirror.rgb / max(mirror.a, 0.001);
			float cover = clamp(mirror.a * plane_fade * character_reflection_attachment
				* character_reflection_opacity, 0.0, 1.0);
			reflected = mix(reflected, mirror_rgb, cover);
		}
	}

	// What comes back up through the water from its floor: the path is down
	// and up again, slanted by the view.
	vec3 through = exp(-absorption * water_depth * (1.0 + 1.0 / max(ndv, 0.25)));
	float t = dot(through, vec3(0.3, 0.5, 0.2));
	float alpha = clamp(1.0 - t * (1.0 - fresnel), 0.0, 1.0);
	inv_alpha = 1.0 / max(alpha, 0.02);
	ALPHA = alpha * shore;
	// The murk's share is the light the floor did not send back, less the
	// mirror's; the mirror's is F. Both over alpha — see the top of the file.
	ALBEDO = albedo_out(clamp(murk_color * (vec3(1.0) - through) * (1.0 - fresnel) * inv_alpha,
		0.0, 1.0));
	water_sky = reflected * fresnel * inv_alpha;
	ROUGHNESS = water_roughness;
	SPECULAR = 0.5;

	torch_glow = atmo_torch_glow(world_pos, n);
	FOG = atmo_fog_at(world_pos, CAMERA_POSITION_WORLD);
}

void light() {
	DIFFUSE_LIGHT += min(etr_illumination(LIGHT_COLOR / PI, max(dot(NORMAL, LIGHT), 0.0),
		ATTENUATION, vec3(1.0)) + torch_glow, vec3(1.0));
	// The sun's own image, as tight as the surface is smooth and Fresnel-
	// weighted with the sky's, so the waves break it into glitter.
	vec3 h = normalize(LIGHT + VIEW);
	float ndh = max(dot(NORMAL, h), 0.0);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * pow(ndh, water_gloss)
		* water_specular_strength * fresnel * inv_alpha / PI;
	SPECULAR_LIGHT += water_sky;
}
