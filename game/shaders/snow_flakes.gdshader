// The near half of ETR's falling snow: `TFlakeArea` from particles.cpp, one
// draw call per area instead of one `glDrawArrays` per flake.
//
// A flake area is a **box that follows the player and wraps**. The original
// keeps a fixed set of flakes, translates every one of them each frame — by
// their own fall speed, by the wind, and by a fraction of how far the player
// moved — and teleports any that leave the box to the opposite face
// (`TFlakeArea::Update`). Nothing is ever spawned or killed, which is why this
// is a [MultiMesh] with static per-instance data and not a particle system:
// the whole of the motion is two numbers the whole area shares.
//
//   `drift`         — everything the area has moved by that is the same for
//                     every flake in it: the wind, and the part of the player's
//                     own motion the snow does *not* follow. Accumulated on the
//                     CPU in box-local metres and kept wrapped there.
//   `fall_distance` — the integral of the area's fall speed. ETR gives a flake
//                     `vel.y = -size * speed`, so the per-flake drop is this
//                     times its own size, and one uniform serves the area.
//
// Which makes the position of flake `i` at time `t` a pure function of its base
// position — no state, no readback, and identical on every run, which the spray
// (a `GPUParticles3D`, seeded per run) is not. Reference captures depend on
// that: see the trap list on comparing frames byte for byte.
shader_type spatial;
// Unlit, both faces, blended, no depth write. ETR's `PARTICLES` render mode is
// unlit and two-sided too; what it does differently is alpha-test at 0.5 with
// `glDepthMask(GL_TRUE)`, i.e. hard-edged flakes that write depth. Soft alpha
// is the same deviation `SprayEmitter` already takes for the same atlas — a
// half-covered edge texel of a 16-pixel flake is a visible staircase here and
// was not at 640x480 — and dropping the depth write is what that costs: the
// flakes within one area do not sort against each other. They are sub-degree
// puffs of a flat colour, so there is nothing in one to sort.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

// ETR binds `SNOW_PART` — the same four-puff atlas the spray draws from, one
// quadrant per flake chosen at birth. `SprayEmitter.make_puff_image` redraws it.
uniform sampler2D flake_texture : source_color, filter_linear_mipmap, repeat_disable;
// The environment's `[partcol]`, modulated onto the puff exactly as ETR's
// `glColor(Env.ParticleColor())` does. `source_color` is not decoration: the
// original multiplies a display-space texture by a display-space number, and
// the decode is what turns that into the equivalent linear factor here. See the
// `light.lst`-is-not-colours trap for the same argument at the other end.
uniform vec4 tint : source_color = vec4(0.85, 0.9, 1.0, 1.0);

// The box's minimum corner in world space — `(left, bottom, front)` of
// `TFlakeArea`. The node sits on it, so this is also the node's own origin;
// it arrives as a uniform because the wrap has to happen in box-local metres
// and a vertex shader cannot take the node transform back out of MODEL_MATRIX.
uniform vec3 box_origin;
// `(xrange, yrange, zrange)`.
uniform vec3 box_range = vec3(5.0, 4.0, 4.0);
uniform vec3 drift = vec3(0.0);
uniform float fall_distance = 0.0;

varying vec2 quadrant;

void vertex() {
	// The per-instance transform carries the flake's base position in the box
	// and its size, which is all the per-flake state ETR keeps as well.
	float flake_size = length(MODEL_MATRIX[0].xyz);
	vec3 local = MODEL_MATRIX[3].xyz - box_origin + drift;
	local.y -= flake_size * fall_distance;
	// The wrap. `mod` lands in [0, range) for a negative argument too, which is
	// the whole of `TFlakeArea::Update`'s six-way teleport — except that it
	// wraps however many box-lengths it has to rather than exactly one, so a
	// frame that moves further than the box is short cannot leave a flake
	// outside it.
	local = mod(local, box_range);

	// ETR turns the near area's flakes about Y by the view direction's yaw
	// (`rotate_flake`) and leaves the two far ones facing world +Z, which is
	// close enough to the camera while the course runs down -Z and is edge-on
	// the moment you look sideways. DEVIATION: all three areas billboard about
	// Y. The far areas are what a slalom swings the view across.
	vec3 flat_right = vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z);
	float right_len = length(flat_right);
	vec3 right = right_len > 0.0001 ? flat_right / right_len : vec3(1.0, 0.0, 0.0);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 out_dir = cross(right, up);

	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(right * flake_size, 0.0),
		vec4(up * flake_size, 0.0),
		vec4(out_dir * flake_size, 0.0),
		vec4(box_origin + local, 1.0));

	quadrant = INSTANCE_CUSTOM.xy;
}

void fragment() {
	vec4 puff = texture(flake_texture, UV * 0.5 + quadrant);
	ALBEDO = tint.rgb * puff.rgb;
	ALPHA = tint.a * puff.a;
}
