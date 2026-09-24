// The procedural sky: gradient, sun disc, two drifting cloud layers, the
// distant ridges, and at night stars, a moon and an aurora.
//
// DEVIATION: ETR draws three photographs on three flat quads
// (`etr_skybox.gdshader`, still here behind `[display] sky = etr`). This draws
// the sky from the same data — the gradient is the migrated faces' own averages
// ([member EnvironmentPreset.sky_zenith_color] and its siblings) — and adds
// what a photograph cannot do: move, sit behind a fogged slope in the right
// colour, and change with the time of day. The gradient, the glow and the
// ridges live in `atmosphere.gdshaderinc`, shared with every lit surface; this
// file adds only what nothing in front of the sky needs to agree with.
//
// Compatibility draws a sky shader like any other; nothing here reads a texture.
shader_type sky;

#include "res://shaders/atmosphere.gdshaderinc"

group_uniforms Sun;
// Angular radius of the disc, radians. The real sun is 0.0047; a game's has to
// read at 1280 pixels.
uniform float sun_radius = 0.012;
// How much of the disc shows: 1 on a clear day, low under overcast.
uniform float sun_disc = 1.0;
uniform vec3 sun_disc_color = vec3(8.0, 7.2, 6.0);

group_uniforms Clouds;
// 0 clear .. 1 overcast.
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.4;
// How far the lower deck has drifted, in its own units; [Atmosphere]
// accumulates it so a change of wind turns the clouds rather than moving them.
// The upper deck rides further on the same heading, so the two decks shear.
uniform vec2 cloud_offset = vec2(0.0);
uniform vec3 cloud_lit = vec3(1.0, 0.98, 0.95);
uniform vec3 cloud_shade = vec3(0.55, 0.6, 0.7);

group_uniforms Night;
uniform float moon_radius = 0.022;
uniform vec3 moon_color = vec3(0.95, 0.97, 1.0);
uniform float star_brightness = 1.0;
uniform float aurora = 1.0;

float fbm(vec2 p, int octaves) {
	float n = 0.0;
	float a = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) {
			break;
		}
		n += atmo_noise(p) * a;
		p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p + vec2(3.1, 1.7);
		a *= 0.5;
	}
	return n;
}

// One cloud deck on a plane above the camera, as (colour, coverage).
vec4 cloud_deck(vec3 d, float height, float scale, vec2 drift, float cover,
		float softness) {
	// The plane projection runs to infinity at the horizon; flattening it with
	// an offset keeps the far clouds from shrinking into noise.
	vec2 uv = d.xz / (d.y + 0.14) * height * scale + drift;
	float n = fbm(uv, 6);
	float threshold = 1.0 - cover;
	float density = smoothstep(threshold - softness, threshold + softness, n * 1.25 - 0.1);
	// Light arriving through the cloud from the disc's side: sample again a
	// step toward it and darken by what is in the way.
	vec2 toward = normalize(atmo_sun_dir.xz + vec2(1e-4)) * 0.18;
	float ahead = fbm(uv + toward, 4);
	float lit = clamp(0.55 + (n - ahead) * 3.0, 0.0, 1.0);
	float mu = max(dot(d, atmo_sun_dir), 0.0);
	vec3 col = mix(cloud_shade, cloud_lit, lit);
	// Silver lining: thin edges toward the disc glow.
	col += atmo_sun_color * pow(mu, 12.0) * (1.0 - density) * 1.5;
	return vec4(col, density);
}

vec3 stars(vec3 d) {
	const float CELLS = 180.0;
	vec3 p = d * CELLS;
	vec3 cell = floor(p);
	vec3 f = fract(p);
	float h = atmo_hash13(cell);
	// The Milky Way: a band of extra stars and a faint glow round one great
	// circle, tilted so it crosses the sky ahead of a racer.
	vec3 band_axis = normalize(vec3(0.35, 0.55, 0.76));
	float in_band = exp(-pow(dot(d, band_axis) / 0.22, 2.0));
	float threshold = mix(0.955, 0.90, in_band);
	vec3 c = vec3(0.0);
	if (h > threshold) {
		vec3 at = vec3(atmo_hash13(cell + 1.7), atmo_hash13(cell + 5.3),
			atmo_hash13(cell + 9.1)) * 0.6 + 0.2;
		float dist = length(f - at);
		// At least a pixel wide, dimmed to keep the energy, or a star smaller
		// than a pixel crawls as the camera moves.
		float pixel = length(fwidth(p));
		float r = max(0.09, pixel * 0.8);
		float mag = pow((h - threshold) / (1.0 - threshold), 2.0);
		float twinkle = 0.75 + 0.25 * sin(atmo_time * (2.0 + h * 7.0) + h * 91.0);
		float core = exp(-dist * dist / (r * r)) * (0.09 * 0.09) / (r * r);
		vec3 tint = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.9, 0.75), atmo_hash13(cell + 3.3));
		c += tint * core * (0.4 + 2.2 * mag) * twinkle;
	}
	float glow = fbm(vec2(dot(d, vec3(1.0, 0.0, 0.3)), dot(d, vec3(0.0, 1.0, -0.4))) * 7.0, 4);
	c += vec3(0.05, 0.055, 0.075) * in_band * smoothstep(0.35, 0.8, glow);
	return c * star_brightness;
}

// The moon as a lit sphere: a gibbous phase from a light off to one side,
// darker maria, a soft edge a pixel wide, and a halo. At night the disc
// direction is the moon's — see [constant Atmosphere.MOON_DIRECTION].
vec3 moon(vec3 d) {
	vec3 m = normalize(atmo_sun_dir);
	float mu = dot(d, m);
	vec3 c = moon_color * (pow(max(mu, 0.0), 900.0) * 0.18 + pow(max(mu, 0.0), 40.0) * 0.035);
	vec3 u = normalize(cross(m, vec3(0.0, 1.0, 0.0)));
	vec3 v = cross(u, m);
	vec2 q = vec2(dot(d, u), dot(d, v)) / moon_radius;
	float r = length(q);
	if (mu > 0.0 && r < 1.2) {
		float edge = fwidth(r);
		float disc = 1.0 - smoothstep(1.0 - edge, 1.0 + edge, r);
		vec3 n = vec3(q, sqrt(max(1.0 - r * r, 0.0)));
		float phase = clamp(dot(n, normalize(vec3(-0.75, 0.25, 0.6))) * 1.4 + 0.15, 0.0, 1.0);
		float maria = fbm(q * 2.2 + 4.0, 4);
		float albedo = 0.72 + 0.32 * smoothstep(0.35, 0.65, maria);
		vec3 lit = moon_color * albedo * (phase * 1.3 + 0.03);
		c = mix(c, lit, disc);
	}
	return c;
}

// Curtains of light on a plane high above the course, ahead of the racer:
// a wavy line in the plane, streaked along its length and stacked in height.
vec3 aurora_light(vec3 d) {
	if (d.y < 0.01) {
		return vec3(0.0);
	}
	vec3 acc = vec3(0.0);
	for (int i = 0; i < 10; i++) {
		float k = float(i) / 9.0;
		float height = 1.0 + k * 0.9;
		vec2 p = d.xz / d.y * height;
		float wave = fbm(vec2(p.x * 0.25 + atmo_time * 0.015, 1.3), 3) * 3.0
			+ sin(p.x * 0.35 + atmo_time * 0.05) * 0.6;
		float across = p.y + 5.0 + wave;
		float curtain = exp(-across * across * 3.0);
		float streak = 0.35 + 0.65 * atmo_noise(vec2(p.x * 6.0 - atmo_time * 0.4, k * 3.0));
		vec3 tint = mix(vec3(0.1, 1.0, 0.45), vec3(0.55, 0.2, 0.9), k * k);
		acc += tint * curtain * streak * (1.0 - k * 0.5);
	}
	float horizon = smoothstep(0.01, 0.12, d.y);
	return acc * 0.09 * horizon;
}

// Compatibility's sky pass writes what the shader returns without encoding it:
// the migrated skybox never noticed, because its `source_color` faces are not
// decoded there either and sRGB went in and came out. This sky is built in
// linear from the global uniforms, so it has to encode for itself or the whole
// backdrop lands an sRGB curve too dark — and stops matching the far terrain,
// whose `FOG` both renderers treat as linear.
vec3 display_encoded(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
#else
	return c;
#endif
}

void sky() {
	vec3 d = atmo_backdrop_dir(EYEDIR);
	if (AT_CUBEMAP_PASS) {
		// The radiance map: nothing lights anything from it here (the ambient is
		// `[amb]` and reflections are off), so the gradient is plenty.
		COLOR = display_encoded(atmo_sky(d));
	} else {
		vec3 c = atmo_sky(d);
		if (atmo_night > 0.0) {
			float clear_air = smoothstep(-0.01, 0.1, d.y);
			vec3 night = stars(d) * clear_air + moon(d) + aurora_light(d) * aurora;
			c += night * atmo_night;
		} else {
			float mu = dot(d, normalize(atmo_sun_dir));
			float angle = length(d - normalize(atmo_sun_dir));
			float edge = fwidth(angle) + 1e-5;
			float disc = 1.0 - smoothstep(sun_radius - edge, sun_radius + edge, angle);
			c += sun_disc_color * disc * sun_disc * step(0.0, mu);
		}
		if (d.y > 0.0 && cloud_cover > 0.0) {
			float fade = smoothstep(0.0, 0.08, d.y);
			vec4 low = cloud_deck(d, 1.0, 1.1, cloud_offset, cloud_cover, 0.12);
			vec4 high = cloud_deck(d, 2.2, 0.8, cloud_offset * 1.7 + 11.0,
				cloud_cover * 0.75, 0.25);
			c = mix(c, high.rgb, high.a * 0.6 * fade);
			c = mix(c, low.rgb, low.a * fade);
		}
		// The ridges go over everything, clouds and moon included, and sharp.
		vec4 ridges = atmo_ridge_stack(d, fwidth(d.y / max(length(d.xz), 1e-4)));
		c = c * (1.0 - ridges.a) + ridges.rgb;
		COLOR = display_encoded(c);
	}
}
