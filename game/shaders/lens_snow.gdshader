// [LensSnow]'s flakes: a clump of snow on the lens, far too close to be in
// focus. What a camera records through one is not white paint but the scene
// behind it, smeared by the blob and lifted by the light it scatters — which
// is also what keeps it visible over snow, where a white blob is not.
//
// The blob atlas says where the flake is (alpha: coverage, peaking at the
// rim); the vertex colour carries the environment's `[partcol]` in rgb and the
// flake's life (landing, melting) in alpha. Plain 2D in display space under
// both renderers; the screen read is the canvas's own back buffer.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
// How far the blur reaches, as a share of the canvas height.
uniform float blur_radius = 0.03;
// How much of the flake's own scattered light — the tint — goes over the blur
// at its densest.
uniform float haze = 0.45;

const int TAPS = 24;
const float GOLDEN_ANGLE = 2.39996323;

// The flake's life and tint, as the vertex colour carried them: by the
// fragment stage `COLOR` has the atlas multiplied in.
varying vec4 flake;

void vertex() {
	flake = COLOR;
}

void fragment() {
	float mask = texture(TEXTURE, UV).a;
	// Canvas height in screen UV is 1; its width is the aspect.
	vec2 reach = vec2(SCREEN_PIXEL_SIZE.x / SCREEN_PIXEL_SIZE.y, 1.0) * blur_radius;
	vec3 sum = vec3(0.0);
	for (int i = 0; i < TAPS; i++) {
		float r = sqrt((float(i) + 0.5) / float(TAPS));
		float a = float(i) * GOLDEN_ANGLE;
		sum += texture(screen_tex, SCREEN_UV + vec2(cos(a), sin(a)) * r * reach).rgb;
	}
	vec3 blurred = sum / float(TAPS);
	vec3 lit = mix(blurred, max(blurred, flake.rgb), haze * mask);
	COLOR = vec4(lit, smoothstep(0.0, 0.6, mask) * flake.a);
}
