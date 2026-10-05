// [MotionBlur]: the smear a moving camera leaves on a frame that was exposed
// for part of its time on screen. Camera motion only — there is no velocity
// buffer on either renderer, so every pixel's motion is worked out from the
// depth buffer: rebuilt into the world, put through the camera as it was the
// frame before, and the frame is gathered along the line between the two.
//
// The racers are the one exception, because the chase camera moves with the
// one it watches: taken as part of the world, the penguin in the middle of the
// frame would smear as hard as the snow beside it. Each racer in shot is a
// sphere that carries its own displacement, so a body moves with itself and
// stays sharp against the camera that follows it, and a tap from one side of
// its edge never counts on the other: the snow does not pick the penguin up
// and the penguin does not pick up the snow.
//
// First in the transparent pass, over a screen copy taken after the opaque
// one, so nothing transparent is in what it smears — the falling snow streaks
// itself ([SnowFall]), the spray and a ghost are drawn over it — and the HUD
// and the lens snow are canvas layers on top of the 3D frame altogether.
//
// The copy is linear light under Mobile and display values under
// Compatibility; the taps are averaged in linear on both (squared there, a
// near enough sRGB curve for an average), and handed back in the copy's own
// units, which both renderers write back unchanged.
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never,
	cull_disabled, fog_disabled, shadows_disabled;

#define MAX_RACERS 4

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
// World to the camera's view as it was when the shutter opened: the last
// frame's view, with its travel and its turn each scaled by its own exposure
// ([MotionBlur]), so the whole smear is the difference from this frame's.
uniform mat4 previous_view = mat4(1.0);
// The same for the racers: turn and travel both exposed as long as the turn.
// The chase camera holds the racer it follows still on screen by turning and
// travelling together, so only one shutter for both keeps that racer sharp.
uniform mat4 body_view = mat4(1.0);
// The longest smear, as a share of the canvas height.
uniform float max_smear = 0.035;
// The racers in shot, nearest first: centre in this frame's view space and
// radius in xyz/w, and how far that centre moved in the world while the
// shutter was open for `body_view`.
uniform int racer_count = 0;
uniform vec4 racer_body[MAX_RACERS];
uniform vec3 racer_moved[MAX_RACERS];

// Taps along a smear: one every TAP_SPACING pixels, at least MIN_TAPS and at
// most MAX_TAPS, so a short smear is cheap and a long one is not a row of
// copies.
const int MIN_TAPS = 4;
const int MAX_TAPS = 16;
const float TAP_SPACING = 4.0;

void vertex() {
	// The clip-space square, as in `sun_shafts.gdshader`: every pixel of the
	// one camera that draws it ([MotionBlur] is on the near-field layer).
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

// The view-space point drawn at `uv`. Depth is reversed on both renderers,
// and the sky — which writes none — rebuilds onto the far plane, where it
// turns with the camera and its travel is nothing. Compatibility's clip space
// spans -1..1 in depth as well; Vulkan's spans 0..1.
vec3 view_at(vec2 uv, mat4 inv_projection) {
	float depth = texture(depth_tex, uv).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
#endif
	vec4 v = inv_projection * vec4(ndc, 1.0);
	return v.xyz / v.w;
}

// How much the view-space point `p` belongs to a racer: 1 in the body, easing
// to 0 at the sphere's surface, and which racer (-1 for none).
float racer_share(vec3 p, out int which) {
	float best = 0.0;
	which = -1;
	for (int i = 0; i < racer_count; i++) {
		vec4 body = racer_body[i];
		float share = 1.0 - smoothstep(body.w * 0.6, body.w, distance(p, body.xyz));
		if (share > best) {
			best = share;
			which = i;
		}
	}
	return best;
}

// How far the world point `world` has moved on screen, in SCREEN_UV, since
// the camera stood at `then_view`. Nothing for a point that was behind it.
vec2 smear_from(mat4 then_view, vec3 world, vec2 uv, mat4 projection) {
	vec4 then = projection * (then_view * vec4(world, 1.0));
	if (then.w <= 1e-4) {
		return vec2(0.0);
	}
	return uv - (then.xy / then.w * 0.5 + 0.5);
}

vec3 to_light(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return c * c;
#else
	return c;
#endif
}

vec3 from_light(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return sqrt(c);
#else
	return c;
#endif
}

void fragment() {
	vec3 here = view_at(SCREEN_UV, INV_PROJECTION_MATRIX);
	int which;
	float body = racer_share(here, which);
	vec3 world = (INV_VIEW_MATRIX * vec4(here, 1.0)).xyz;
	vec2 smear = smear_from(previous_view, world, SCREEN_UV, PROJECTION_MATRIX);
	if (which >= 0) {
		smear = mix(smear, smear_from(body_view, world - racer_moved[which], SCREEN_UV,
			PROJECTION_MATRIX), body);
	}
	float aspect = VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;
	float span = length(smear * vec2(aspect, 1.0));
	if (span > max_smear) {
		smear *= max_smear / span;
		span = max_smear;
	}

	// The pixel itself counts as one tap, so a smear whose every tap is
	// across a racer's edge still has something to show.
	vec3 sum = to_light(texture(screen_tex, SCREEN_UV).rgb);
	float weight = 1.0;
	if (span * VIEWPORT_SIZE.y > 0.5) {
		// Interleaved gradient noise, as in the sun's rays: each pixel starts
		// its taps a different part of a step along, trading banding for grain.
		float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		int taps = clamp(int(span * VIEWPORT_SIZE.y / TAP_SPACING), MIN_TAPS, MAX_TAPS);
		for (int i = 0; i < taps; i++) {
			vec2 uv = clamp(SCREEN_UV + smear * ((float(i) + jitter) / float(taps) - 0.5),
				vec2(0.0), vec2(1.0));
			float w = 1.0;
			if (racer_count > 0) {
				int other;
				w -= abs(racer_share(view_at(uv, INV_PROJECTION_MATRIX), other) - body);
			}
			sum += to_light(texture(screen_tex, uv).rgb) * w;
			weight += w;
		}
	}
	ALBEDO = from_light(sum / weight);
	ALPHA = 1.0;
}
