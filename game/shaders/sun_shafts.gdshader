// [SunShafts]: light scattered by the air between the camera and the sun,
// showing as rays wherever something — a trunk, a crest, the penguin — breaks
// the bright sky round the disc. A radial blur toward the sun of the open sky
// near it (Mitchell, "Volumetric Light Scattering as a Post-Process", GPU Gems
// 3 ch. 13), drawn over the frame by one full-screen quad.
//
// A spatial pass and not a canvas one like [LensFlare], because the question
// "is this pixel sky?" has to be asked of the depth buffer: sunlit snow at the
// illumination clamp is as white as the sky round the disc, and a brightness
// test alone would send rays out of every sunlit bank in the frame. Sky is
// what nothing was drawn over — the cleared depth. The distant ridges are sky
// by that test (the sky shader draws them), so only the brightness one keeps
// them out: a ridge as bright as the air by the disc would send rays too.
//
// Gentle, like the flare: a few levels of light along a ray, up to ~45 at the
// disc. Worked out in display space and handed to each renderer in its own
// units (`to_output`), so the two draw it alike.
shader_type spatial;
render_mode unshaded, blend_add, depth_test_disabled, depth_draw_never,
	cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
// Where the disc's centre is, in SCREEN_UV. May be off the canvas.
uniform vec2 sun_uv = vec2(0.8, 0.1);
// The sky's rays times how much of the sun is still near the canvas.
uniform float strength = 0.0;
// How far round the disc the sky sends rays, as a share of the canvas height.
uniform float source_radius = 0.18;
// What share of the way to the sun each pixel's ray walks. Short of 1 so a
// ray reads the sky beside the disc rather than the disc alone.
uniform float reach = 0.9;
// Sunlight through haze: warm, a little short of white.
uniform vec3 tint = vec3(1.0, 0.93, 0.8);

const int TAPS = 20;
// Display-space brightness at which the sky starts to scatter, and is in full.
const float LIT_FROM = 0.7;
const float LIT_TO = 0.96;
// Display-space light added along a ray that crossed all of the bright sky
// round the disc unbroken, at the disc.
const float GAIN = 0.6;
// How far from the disc, in canvas heights, a ray has faded to 1/e.
const float RAY_LENGTH = 0.42;

void vertex() {
	// The quad is the clip-space square: every pixel of whatever camera draws
	// it, which is the main one alone ([SunShafts] puts it on the near-field
	// layer that the ice's probe and mirror leave out). Mid-depth, inside the
	// clip range of both renderers' depth conventions.
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

vec3 encode(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 decode(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// The frame at `uv` in display space. Mobile's screen copy is the 3D buffer,
// in linear light; Compatibility's holds what it will display.
vec3 display_at(vec2 uv) {
	vec3 c = texture(screen_tex, uv).rgb;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return c;
#else
	return encode(c);
#endif
}

// Nothing drawn here but the sky. Both renderers keep depth reversed — the far
// plane, where the clear leaves it, is 0 — Compatibility included: its GLES3
// scene clears depth to 0 and tests GL_GEQUAL, so the textbook `>= 1.0` test
// found no sky at all there.
bool is_sky(vec2 uv) {
	return texture(depth_tex, uv).r <= 0.00001;
}

// How much light the frame at `uv` throws along a ray, in display space: open,
// bright sky near the disc. `near` is that nearness, worked out by the caller
// before any texture is read.
vec3 source(vec2 uv, float near) {
	if (near < 0.004 || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))
			|| !is_sky(uv)) {
		return vec3(0.0);
	}
	vec3 c = display_at(uv);
	float lit = smoothstep(LIT_FROM, LIT_TO, dot(c, vec3(0.2126, 0.7152, 0.0722)));
	return c * lit * near;
}

// What the added light comes to in the units this renderer blends in, over a
// frame that reads `under` in display space. Compatibility blends display
// values; Mobile blends linear light, so the step is taken there.
vec3 to_output(vec3 add, vec3 under) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return add;
#else
	vec3 over = min(under + add, vec3(1.0));
	return max(decode(over) - decode(min(under, vec3(1.0))), vec3(0.0));
#endif
}

void fragment() {
	float aspect = VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;
	vec2 to_sun = sun_uv - SCREEN_UV;
	float dist = length(to_sun * vec2(aspect, 1.0));
	vec2 step_uv = to_sun * reach / float(TAPS);
	// Interleaved gradient noise: each pixel starts its walk a different part
	// of a step along, which trades the taps' banding for a fine grain.
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	vec2 uv = SCREEN_UV + step_uv * jitter;
	vec3 sum = vec3(0.0);
	for (int i = 0; i < TAPS; i++) {
		vec2 off = (uv - sun_uv) * vec2(aspect, 1.0);
		float near = exp(-dot(off, off) / (source_radius * source_radius));
		sum += source(uv, near);
		uv += step_uv;
	}
	// The light the ray picked up, as a share of what a ray crossing the
	// whole of the bright sky on one side of the disc would: the integral of
	// the source along it over that of the Gaussian, sqrt(pi) / 2 radii.
	// Integrated rather than averaged, so what a ray carries is how much sky it
	// crossed, not how short it was: averaged, every pixel by the disc read
	// nothing but source and the middle swelled into a second glare.
	vec3 lit = sum * (dist * reach / float(TAPS)) / (0.886 * source_radius);
	vec3 add = tint * min(lit, vec3(1.0)) * exp(-dist / RAY_LENGTH) * (strength * GAIN);
	ALBEDO = to_output(add, display_at(SCREEN_UV));
}
