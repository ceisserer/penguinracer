// The falling snow: ETR's `TFlakeArea` from particles.cpp, one draw call per
// area instead of one `glDrawArrays` per flake — and, with a different texture
// and a distance band, the far snow that replaces its `CCurtain` rings.
//
// A flake area is a **box that follows the player and wraps**. The flakes in it
// do not follow: each one hangs in the world, falls, sways and is carried by
// the wind, and the box is only the window of that endless field that gets
// drawn — a flake the box leaves behind reappears at the opposite face, where
// the snowfall it stands for would have had another one. Nothing is ever
// spawned or killed, which is why this is a [MultiMesh] with static
// per-instance data and not a particle system: the whole of the motion is a
// handful of numbers the whole area shares.
//
//   `drift`         — everything the area has moved by that is the same for
//                     every flake in it: the wind, minus how far the box moved
//                     with the player, which is what keeps the flakes where
//                     they are in the world. Accumulated on the CPU in
//                     box-local metres and kept wrapped there.
//   `fall_distance` — the integral of the fall speed; each flake scales it by
//                     a factor of its own.
//   `clock`         — seconds since the run started, for the sway.
//
// Which makes the position of flake `i` at time `t` a pure function of its base
// position — no state, no readback, and identical on every run, which the spray
// (a `GPUParticles3D`, seeded per run) is not. Reference captures depend on
// that: see the trap list on comparing frames byte for byte.
//
// DEVIATION: ETR moves its flakes by only 80 % of the player's drop and 60 % of
// their travel down the hill, so the snow half-follows the camera and reads as
// an overlay; its reason was that at 0 % "every flake is a streak". Here the
// flakes stay put and *are* drawn as streaks — each quad is stretched along how
// far the flake moved against the camera over [param shutter], which is what a
// film camera records and what the eye reads as speed. SnowFall carries the
// rest of the argument.

shader_type spatial;

// Unlit, both faces, blended, no depth write. ETR's `PARTICLES` render mode is
// unlit and two-sided too; what it does differently is alpha-test at 0.5 with
// `glDepthMask(GL_TRUE)`, i.e. hard-edged flakes that write depth. Soft alpha
// is the same deviation `SprayEmitter` already takes for the same atlas — a
// half-covered edge texel of a 16-pixel flake is a visible staircase here and
// was not at 640x480 — and dropping the depth write is what that costs: the
// flakes within one area do not sort against each other. They are sub-degree
// puffs of a flat colour, so there is nothing in one to sort.
//
// `skip_vertex_transform` because the quad is built in view space: a streak's
// length and direction are only known there.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, skip_vertex_transform;

// What a quad is cut from. A near area binds `SnowFall.make_flake_image` — an
// atlas of irregular clumps, one cell per flake chosen at birth — and the far
// area a curtain tile, one random patch of specks per quad. The instance data
// says where in the texture its cut starts and [param uv_scale] how big it is.
uniform sampler2D flake_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform float uv_scale = 0.5;
// How fast a flake turns in its cell, rad/s before its own factor, and at the
// same time how much it tumbles — a clump turning edge-on narrows. 0 for the
// far area: its patches are sheets of specks, and a turned sheet reads as snow
// on rotating planes (see below).
uniform float tumble = 0.0;
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
uniform float clock = 0.0;

// What a flake's velocity is made of, in m/s, for the streak: the air that
// carries it and the speed it falls at before its own factor.
uniform vec3 air = vec3(0.0);
uniform float fall_speed = 1.0;
// The camera's view matrix one frame ago, and how long that frame was. What
// the flake moved by against the camera over the frame, rescaled to
// [param shutter], is the streak — so camera travel and camera turn both smear
// the snow, as they would on film, and the length does not depend on the
// frame rate.
uniform mat4 prev_view = mat4(1.0);
uniform float frame_time = 0.016667;
// A 180° shutter at 30 fps.
uniform float shutter = 0.016667;
// The distances from the camera, in metres, over which a quad fades in and
// then out again: `(in_start, in_end, out_start, out_end)`. A near area only
// fades in — one that passes the lens would otherwise fill the screen for a
// frame. The far area is a shell, drawn only beyond where the near ones end.
uniform vec4 fade_band = vec4(0.25, 0.9, 1e5, 2e5);
// The share of each box axis over which a quad fades in at one face and out at
// the other, so the wrap is never a pop.
uniform float edge_fade = 0.12;

// How far a sway carries a flake, and how fast it turns, per the flake's own
// two random numbers.
const float SWAY = 0.12;
const float SWAY_RATE = 1.4;
// A flake falls at 0.7..1.3 of [param fall_speed].
const float FALL_SPREAD = 0.3;
// The longest a streak is drawn, in metres. A camera cut is caught on the CPU;
// this is the backstop for whatever it misses.
const float MAX_STREAK = 2.0;
// The smallest a quad is drawn, in pixels. Every flake is the same size in the
// world, so the far ones fall below a pixel — and a sub-pixel quad is not a
// faint flake, it is one that flickers in and out as it crosses pixel centres.
// Drawn at this size instead, and faded by the area that adds, so what it
// covers on screen stays what the real flake would.
const float MIN_PIXELS = 1.5;

varying vec2 cut;
varying float fade;
// The flake's turn as (cos, sin), and how edge-on it is: the cell is read
// 1 / squash times wider across one axis.
varying vec3 spin;

void vertex() {
	// The per-instance transform carries the flake's base position in the box
	// and its size, which is all the per-flake state ETR keeps as well; the
	// custom data adds where its cut of the texture starts and two fixed random
	// numbers.
	float world_size = length(MODEL_MATRIX[0].xyz);
	vec2 seed = INSTANCE_CUSTOM.zw;
	float fall_k = 1.0 + FALL_SPREAD * (2.0 * seed.x - 1.0);
	float rate = SWAY_RATE * (0.7 + 0.6 * seed.y);
	float phase_a = 6.2831853 * seed.x;
	float phase_b = 6.2831853 * seed.y;
	vec3 sway = SWAY * vec3(sin(rate * clock + phase_a), 0.0, sin(0.8 * rate * clock + phase_b));
	vec3 sway_vel = SWAY * rate * vec3(cos(rate * clock + phase_a), 0.0,
		0.8 * cos(0.8 * rate * clock + phase_b));

	vec3 local = MODEL_MATRIX[3].xyz - box_origin + drift + sway;
	local.y -= fall_k * fall_distance;
	// The wrap. `mod` lands in [0, range) for a negative argument too, which is
	// the whole of `TFlakeArea::Update`'s six-way teleport — except that it
	// wraps however many box-lengths it has to rather than exactly one, so a
	// frame that moves further than the box is short cannot leave a flake
	// outside it.
	local = mod(local, box_range);
	vec3 edge = min(local, box_range - local) / (edge_fade * box_range);
	fade = smoothstep(0.0, 1.0, clamp(min(edge.x, min(edge.y, edge.z)), 0.0, 1.0));

	vec3 world = box_origin + local;
	vec3 velocity = air + sway_vel - vec3(0.0, fall_k * fall_speed, 0.0);
	vec3 head = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	vec3 before = (prev_view * vec4(world - velocity * frame_time, 1.0)).xyz;
	vec3 streak = (head - before) * (shutter / max(frame_time, 0.0001));
	float streak_len = length(streak);
	if (streak_len > MAX_STREAK) {
		streak *= MAX_STREAK / streak_len;
	}
	vec3 tail = head - streak;
	// Keep the tail in front of the lens, or its projection flips.
	tail.z = min(tail.z, -0.05);
	float depth = max(-head.z, 0.05);
	// One pixel's height in metres at the head's depth.
	float pixel = 2.0 * depth / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float flake_size = max(world_size, MIN_PIXELS * pixel);
	float coverage = world_size / flake_size;
	fade *= coverage * coverage;

	// Which way the streak runs on screen, and how long it is there — in metres
	// at the head's depth, so it adds to the flake's own size.
	vec2 screen = head.xy / depth - tail.xy / -tail.z;
	float screen_len = length(screen);
	vec2 along = screen_len > 1e-6 ? screen / screen_len : vec2(0.0, 1.0);

	// The quad stays upright on screen and is *stretched* toward the tail, never
	// turned to face along the streak. A turned quad turns its texture with it:
	// invisible on one round puff, but a far patch is a sheet of specks, and a
	// sheet that swings round whenever its motion against the camera changes
	// direction — and spins on noise when it barely moves — reads as snow on
	// rotating planes. Each corner goes toward the tail by how far it points
	// away from the head: the leading corner stays, the trailing one goes all
	// the way, the two beside it half. Continuous in the direction, and exactly
	// ETR's camera-facing square when nothing moves.
	// UV runs down the quad; view space runs up.
	vec2 corner = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	float toward_tail = clamp(0.5 - 0.5 * dot(corner, along) * 0.70710678, 0.0, 1.0);
	vec3 centre = mix(head, tail, toward_tail);
	vec2 offset = corner * 0.5 * flake_size;
	VERTEX = centre + vec3(offset * (-centre.z / depth), 0.0);

	// A streak is fainter than the flake it smears, but by the square root of
	// how much longer it is rather than all of it: spreading the light exactly
	// leaves a flake at speed about as visible as the terrain's grain, and the
	// eye reads a streak's length before its brightness anyway.
	fade *= sqrt(flake_size / (flake_size + screen_len * depth));
	float distance = length(head);
	fade *= smoothstep(fade_band.x, fade_band.y, distance)
		* (1.0 - smoothstep(fade_band.z, fade_band.w, distance));
	cut = INSTANCE_CUSTOM.xy;

	// Each flake turns one way or the other at its own rate from its own start,
	// and wobbles edge-on at a rate of its own — a clump in free fall flutters.
	// Two more numbers out of the flake's pair, decorrelated from the fall and
	// the sway that already use them.
	vec2 more = fract(seed.yx * vec2(12.9898, 78.233) + seed * 37.719);
	float turn_rate = tumble * (0.4 + 0.8 * more.x) * (more.y < 0.5 ? -1.0 : 1.0);
	// None at all without a tumble, not even the start: a far patch turned in
	// its quad reads past its own edge at the corners, where the clamp below
	// repeats the edge texels, and every speck on an edge becomes a line.
	float angle = (6.2831853 * more.y + turn_rate * clock) * step(0.0001, tumble);
	float wobble = 0.5 + 0.5 * cos(1.7 * turn_rate * clock + 6.2831853 * more.x);
	spin = vec3(cos(angle), sin(angle), mix(1.0, 0.55 + 0.45 * wobble, step(0.0001, tumble)));
}

void fragment() {
	// Turned and squashed about the cell's centre. The shape stays within
	// `SnowFall.FLAKE_REACH` of it, so whatever turns in from past the cell's
	// inscribed circle is cut away rather than read from the neighbour. With
	// no tumble this is the plain cut, corners and all.
	vec2 p = UV - 0.5;
	p = vec2(spin.x * p.x + spin.y * p.y, -spin.y * p.x + spin.x * p.y);
	p.y /= spin.z;
	float inside = tumble > 0.0 ? step(length(p), 0.5) : 1.0;
	vec4 puff = texture(flake_texture, (clamp(p, -0.5, 0.5) + 0.5) * uv_scale + cut);
	puff.a *= inside;
	ALBEDO = tint.rgb * puff.rgb;
	ALPHA = tint.a * puff.a * fade;
}
