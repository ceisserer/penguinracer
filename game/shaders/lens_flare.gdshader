// [LensFlare]: what the sun does to a camera looking near it. A soft glare
// round the disc, a faint streak through it, and a few ghosts — reflections
// between the lens elements — strung along the line from the sun through the
// middle of the frame. Added over the frame, in display space, alike under
// both renderers.
//
// Gentle on purpose. The glare is most of it; each ghost adds a few levels to
// what is behind it and is gone against the snow.
//
// Whether anything stands in front of the sun is read off the frame itself:
// the disc is white (it is drawn at eight times white and clips), so a probe of
// a few taps inside it says how much of it shows. No readback — every pixel of
// the flare asks the same few texels, which the cache answers.
shader_type canvas_item;
render_mode blend_add, unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
// Where the disc's centre is, in SCREEN_UV.
uniform vec2 sun_uv = vec2(0.8, 0.1);
// The sky's flare times how much of the sun is still on the canvas.
uniform float strength = 0.0;
// The probe's radius, a share of the canvas height.
uniform float probe = 0.004;
// Sunlight through glass: warm, a little short of white.
uniform vec3 tint = vec3(1.0, 0.9, 0.74);

const int PROBE_TAPS = 7;
// Along the axis from the sun (0) through the middle of the frame (1): where
// each ghost sits, its radius as a share of the canvas height, and how bright
// it is at its densest.
const vec3 GHOSTS[5] = vec3[](
	vec3(0.42, 0.030, 0.08),
	vec3(0.70, 0.012, 0.12),
	vec3(1.28, 0.050, 0.06),
	vec3(1.55, 0.020, 0.09),
	vec3(1.95, 0.090, 0.045)
);
// Each ghost's colour: the coatings pass some wavelengths and not others.
const vec3 GHOST_TINTS[5] = vec3[](
	vec3(1.0, 0.75, 0.45),
	vec3(0.55, 1.0, 0.65),
	vec3(0.55, 0.7, 1.0),
	vec3(1.0, 0.8, 0.5),
	vec3(0.6, 0.75, 1.0)
);

// How much of the disc shows: the share of the probe's taps that are white.
float sun_showing(float aspect) {
	float seen = 0.0;
	for (int i = 0; i < PROBE_TAPS; i++) {
		vec2 o = vec2(0.0);
		if (i > 0) {
			float a = float(i) * (6.2831853 / float(PROBE_TAPS - 1));
			o = vec2(cos(a) / aspect, sin(a)) * probe;
		}
		vec3 c = texture(screen_tex, clamp(sun_uv + o, vec2(0.0), vec2(1.0))).rgb;
		seen += smoothstep(0.88, 0.98, min(c.r, min(c.g, c.b)));
	}
	return seen / float(PROBE_TAPS);
}

void fragment() {
	// Canvas height in screen UV is 1; its width is the aspect.
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float k = strength * sun_showing(aspect);
	vec3 col = vec3(0.0);
	if (k > 0.0) {
		vec2 from_sun = (SCREEN_UV - sun_uv) * vec2(aspect, 1.0);
		float r = length(from_sun);
		// Glare: a bright core fading into a wide, faint veil.
		col += tint * (exp(-r * r / 0.0012) * 0.14 + exp(-r / 0.16) * 0.035);
		// A thin horizontal streak through the disc, as a lens's coating smears it.
		col += tint * exp(-abs(from_sun.y) / 0.0035) * exp(-abs(from_sun.x) / 0.22) * 0.05;
		// The ghosts: soft discs, a little brighter at the rim.
		vec2 axis = vec2(0.5) - sun_uv;
		for (int i = 0; i < 5; i++) {
			vec3 g = GHOSTS[i];
			vec2 at = sun_uv + axis * g.x;
			float d = length((SCREEN_UV - at) * vec2(aspect, 1.0)) / g.y;
			float disc = 1.0 - smoothstep(0.75, 1.0, d);
			float rim = 0.6 + 0.4 * smoothstep(0.4, 0.95, d);
			col += GHOST_TINTS[i] * disc * rim * g.z;
		}
		col *= k;
	}
	COLOR = vec4(col, 1.0);
}
