// Snow deformation field — one ping-pong pass.
//
// The Compatibility renderer has no compute shaders and no RenderingDevice
// access, so the field is advanced by a fragment pass between two SubViewport
// render targets (plan §1, §4.3). This is the pre-compute-era technique and it
// ports forward to a compute dispatch unchanged if Godot gains WebGPU.
//
// Channels: R = trench depth (normalised), G = compaction, B = age, A = spare
// (reserved for wind drift).
shader_type canvas_item;
render_mode blend_disabled, unshaded;

uniform sampler2D prev_tex : filter_linear, repeat_disable;

// Toroidal scrolling: the window follows the player, and only the newly exposed
// edge is cleared. `scroll_uv` is the previous window's origin expressed in this
// window's UV space.
uniform vec2 scroll_uv = vec2(0.0);
uniform bool first_frame = false;

// Trench refill and compaction fade, as per-frame multipliers.
uniform float depth_decay = 0.9995;
uniform float pack_decay = 0.99995;

// Up to 8 contact stamps per frame, in window UV. `xy` = centre, `z` = radius
// in UV, `w` = amount added at the centre.
uniform int stamp_count = 0;
uniform vec4 stamps[8];

void fragment() {
	vec2 uv = UV;
	vec4 prev = vec4(0.0);
	if (!first_frame) {
		vec2 src = uv + scroll_uv;
		// Outside the retained window is snow we have never touched.
		if (all(greaterThanEqual(src, vec2(0.0))) && all(lessThanEqual(src, vec2(1.0)))) {
			prev = texture(prev_tex, src);
		}
	}

	prev.r *= depth_decay;
	prev.g *= pack_decay;
	prev.b = min(1.0, prev.b + 0.0005);

	for (int i = 0; i < 8; i++) {
		if (i >= stamp_count) { break; }
		vec4 s = stamps[i];
		float d = distance(uv, s.xy);
		// Flat-bottomed with a feathered rim: the contact patch is a belly, not
		// a point, and a dome would read as a dent rather than a carve.
		float coverage = clamp((s.z - d) / max(s.z * 0.35, 1e-5), 0.0, 1.0);
		prev.r = min(1.0, prev.r + s.w * coverage);
		prev.g = min(1.0, prev.g + coverage * 0.35);
		prev.b = mix(prev.b, 0.0, coverage);
	}

	COLOR = prev;
}
