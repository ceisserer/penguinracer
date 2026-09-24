// The atmosphere: the sky's gradient and glow, the distant ridges, the haze
// between the camera and a far surface, and the mist lying in the valley.
//
// One file, included by the sky and by every lit surface, so that the colour a
// distant slope fades to is by construction the colour of whatever is behind
// it. That is the whole reason the backdrop mountains are drawn here, as a
// function of direction, and not as meshes: ETR's fog (40-150 m here) washes
// terrain out completely long before the horizon, and a fully fogged slope has
// to become *something*. With a flat fog colour it becomes a flat shape cut out
// of the mountains behind it; with [code]atmo_background[/code] it becomes the
// mountains behind it. See [Atmosphere] for who fills the globals, and the
// sky/atmosphere deviation in AGENTS.md.
//
// Everything is linear, and everything is available to Compatibility: global
// uniforms, value noise from arithmetic hashes (no texture units — the terrain
// has three left) and a written [code]FOG[/code], which both renderers blend
// the same way.

// Advances with the frame, so a `--fixed-fps` capture is reproducible; `TIME`
// would do the same, but in a sky shader it also marks the radiance cubemap
// for a rebuild every frame.
global uniform float atmo_time;
// Where the bright disc is: the sun, or at night the moon. Not always the
// light's direction — see [member Atmosphere.MOON_DIRECTION].
global uniform vec3 atmo_sun_dir;
// The colour the disc tints the air around it, already scaled for the sky.
global uniform vec3 atmo_sun_color;
global uniform vec3 atmo_zenith;
global uniform vec3 atmo_horizon;
global uniform vec3 atmo_ground;
// ETR's `[fogcol]`, the fade target when `aerial` is 0.
global uniform vec3 atmo_fog_color;
// begin (m), end (m), aerial (0 = ETR's flat colour, 1 = the sky's), backdrop
// (0 = the migrated skybox is up and there are no ridges to fade to).
global uniform vec4 atmo_fog;
// base altitude (m), falloff height (m), density at the base (1/m), clear
// distance (m). Density 0 is no mist.
global uniform vec4 atmo_mist;
global uniform vec3 atmo_mist_color;
// How thickly mist lies at the foot of each ridge, 0..1.
global uniform float atmo_valley_mist;
// seed, sunlight on the ridges, haze scale, drop: how far below the horizon the camera's
// height above the valley floor puts the ridges, as a tangent. The ridges are
// a couple of kilometres off, so a racer at the top of a 200 m descent looks
// down on them and one at the finish looks across.
global uniform vec4 atmo_ridges;
// How far below the true horizon the backdrop's horizon sits, as a tangent:
// the sky, its clouds and the ridges are all drawn as if the world's horizon
// were this much lower. A chase camera at its pitch clamp sees nothing above
// -5 degrees, so a horizon at 0 is never in shot. See [method Atmosphere.horizon_dip].
global uniform float atmo_dip;
// 0 by day, 1 by night.
global uniform float atmo_night;
// The eight torches nearest the camera, as position and brightness, and the
// light they all share: colour times strength, and reach in metres. A reach
// of 0 is no torches, which is every daytime frame. Eight separate globals
// because a global uniform cannot be an array. See [CourseLights].
global uniform vec4 atmo_torch_0;
global uniform vec4 atmo_torch_1;
global uniform vec4 atmo_torch_2;
global uniform vec4 atmo_torch_3;
global uniform vec4 atmo_torch_4;
global uniform vec4 atmo_torch_5;
global uniform vec4 atmo_torch_6;
global uniform vec4 atmo_torch_7;
global uniform vec4 atmo_torch_light;

// ------------------------------------------------------------------
//        noise
// ------------------------------------------------------------------

// Dave Hoskins' hash without sine: stable across GPUs, which `fract(sin())` is
// not at the magnitudes a drifting cloud layer reaches.
float atmo_hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float atmo_hash13(vec3 p) {
	vec3 p3 = fract(p * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float atmo_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(atmo_hash12(i), atmo_hash12(i + vec2(1.0, 0.0)), u.x),
		mix(atmo_hash12(i + vec2(0.0, 1.0)), atmo_hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Value noise that repeats every [param period] cells in x, with its
// gradient — Inigo Quilez's analytic derivative. For the mountains' faces,
// whose x runs once round the horizon and has to meet itself.
vec3 atmo_noise_wrapped(vec2 p, float period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	vec2 du = 6.0 * f * (1.0 - f);
	float x0 = mod(i.x, period);
	float x1 = mod(i.x + 1.0, period);
	float a = atmo_hash12(vec2(x0, i.y));
	float b = atmo_hash12(vec2(x1, i.y));
	float c = atmo_hash12(vec2(x0, i.y + 1.0));
	float d = atmo_hash12(vec2(x1, i.y + 1.0));
	float k = a - b - c + d;
	return vec3(a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y,
		du * vec2(b - a + k * u.y, c - a + k * u.x));
}

// ------------------------------------------------------------------
//        the sky
// ------------------------------------------------------------------

// World direction [param d] as the backdrop sees it: tipped up by
// [code]atmo_dip[/code], so the backdrop's horizon lies that far below the
// true one. Everything that draws or fades to the backdrop goes through this,
// so the far terrain still fades into exactly what is behind it.
vec3 atmo_backdrop_dir(vec3 d) {
	float hl = max(length(d.xz), 1e-4);
	return normalize(vec3(d.x, d.y + atmo_dip * hl, d.z));
}

// The clear sky in direction [param d]: the gradient the migrated skybox was
// averaged into, a brighter band where the air is thickest, and the disc's
// glow. No clouds, stars or ridges — this is also what the air between the
// camera and a distant slope is lit by.
vec3 atmo_sky(vec3 d) {
	float up = clamp(d.y, 0.0, 1.0);
	vec3 c = mix(atmo_horizon, atmo_zenith, pow(up, 0.5));
	// Below the backdrop's horizon is the course's own terrain, down to about
	// a fifth under it on the steep ones. A gap there between the ridges and
	// the snow is far valley, so it stays the horizon's colour: fading to the
	// ground from 0 drew the dipped horizon as a grey arc over the ridges.
	c = mix(c, atmo_ground, smoothstep(0.2, 0.5, -d.y));
	// Looking along the horizon looks through the most air.
	float band = exp(-abs(d.y) * 9.0);
	c += atmo_horizon * 0.10 * band;
	// Forward scattering round the disc, strongest along the horizon under it.
	float mu = max(dot(d, atmo_sun_dir), 0.0);
	float halo = pow(mu, 48.0) * 0.45 + pow(mu, 6.0) * 0.18;
	float horizon_glow = pow(mu, 2.0) * band * 0.35;
	return c + atmo_sun_color * (halo + horizon_glow);
}

// ------------------------------------------------------------------
//        the ridges
// ------------------------------------------------------------------

const int ATMO_RIDGE_LAYERS = 3;

// The foot of layer [param layer], before the drop: where its valley is.
float atmo_ridge_base(float layer) {
	return -0.02 - layer * 0.04;
}

// The ridge line of layer [param layer] (0 farthest) above horizontal
// direction [param h], as the tangent of its elevation. Noise sampled round a
// circle, so it closes on itself at 360 degrees without a seam.
float atmo_ridge_top(vec2 h, float layer) {
	float radius = 2.6 + layer * 1.7;
	vec2 p = h * radius + vec2(atmo_ridges.x * 13.7 + layer * 41.3, layer * 17.9);
	float n = 0.0;
	float amp = 0.55;
	float freq = 1.0;
	for (int o = 0; o < 6; o++) {
		// Ridged: sharp crests, rounded valleys — the shape of eroded rock
		// rather than of dunes. Each octave rides on the last one's value, so
		// peaks stack on peaks and the lowlands stay smooth.
		float v = 1.0 - abs(atmo_noise(p * freq) * 2.0 - 1.0);
		n += v * v * amp * (o == 0 ? 1.0 : clamp(n * 1.6, 0.25, 1.0));
		freq *= 2.07;
		amp *= 0.5;
	}
	// The far range stands tallest and the near ranges lowest, so every layer
	// shows over the one in front of it. Kept low: this is measured from the
	// dipped horizon, and the sky above them is what makes a clear day read
	// as one.
	return atmo_ridge_base(layer) + (0.15 - layer * 0.025) * n - atmo_ridges.w;
}

// A layer's own colour where it is solid: a rock face with snow lying on
// whatever part of it is not too steep to hold any, lit from the disc's side.
//
// The face is a second noise field over (round the horizon, up), and its
// gradient tilts the normal. Shading off the crest line alone — the one piece
// of shape a silhouette has — gives every column of pixels one tone, which
// reads as a row of vertical planks.
vec3 atmo_ridge_shade(vec2 h, float t, float top, float layer) {
	// Cells round the horizon: the far range the finest, the foothills the
	// coarsest, as they would be at those distances.
	float period = floor(150.0 - layer * 40.0);
	float az = atan(h.y, h.x) / TAU + 0.5;
	vec2 p = vec2(az * period, t * period / TAU * 0.9 + layer * 7.0);
	vec2 g = vec2(0.0);
	float n = 0.0;
	float amp = 0.5;
	float per = period;
	for (int o = 0; o < 4; o++) {
		vec3 v = atmo_noise_wrapped(p, per);
		n += v.x * amp;
		g += v.yz * amp * pow(2.0, float(o));
		p = p * 2.0 + vec2(0.0, 3.7);
		per *= 2.0;
		amp *= 0.5;
	}
	vec3 out_dir = vec3(-h.x, 0.0, -h.y);
	vec3 along = vec3(-h.y, 0.0, h.x);
	vec3 face = normalize(out_dir * 0.8 + vec3(0.0, 0.55, 0.0)
		- along * g.x * 0.45 + vec3(0.0, 1.0, 0.0) * g.y * 0.25);
	float ndl = max(dot(face, atmo_sun_dir), 0.0);

	// Snow holds where the face turns upward, and more of it higher up.
	float below = (top - t) / 0.04;
	float holds = face.y + (n - 0.5) * 0.5 - below * 0.25 + 0.05 * layer;
	float snow = smoothstep(0.42, 0.62, holds);
	vec3 rock = vec3(0.16, 0.17, 0.2);
	// Forest on the lower flanks, dark and ragged at the tree line.
	float foot = atmo_ridge_base(layer) - atmo_ridges.w;
	float tree_line = foot + 0.035 + (n - 0.5) * 0.03;
	float forest = smoothstep(tree_line + 0.01, tree_line - 0.01, t) * (1.0 - snow * 0.6);
	rock = mix(rock, vec3(0.07, 0.10, 0.09), forest);
	vec3 albedo = mix(rock, vec3(0.88, 0.91, 0.97), snow * (1.0 - forest * 0.7));

	vec3 sky_light = mix(atmo_zenith, atmo_horizon, 0.5);
	return albedo * (sky_light + atmo_sun_color * atmo_ridges.y * ndl);
}

// The ridges at direction [param d], back to front, each hazed by its distance
// and misted at its foot: premultiplied colour and coverage, to lay over
// whatever sky is behind them. [param aa] is the edge's width in
// tangent-of-elevation, a pixel's worth.
vec4 atmo_ridge_stack(vec3 d, float aa) {
	if (atmo_fog.w < 0.5) {
		return vec4(0.0);
	}
	float hl = max(length(d.xz), 1e-4);
	vec2 h = d.xz / hl;
	float t = d.y / hl;
	// The haze a ridge takes is the sky along the horizon beneath it, not the
	// sky at its own pixel — a crest against the zenith is not zenith-blue.
	vec3 haze_sky = atmo_sky(normalize(vec3(h.x, max(t, 0.0) * 0.3, h.y)));
	vec4 stack = vec4(0.0);
	for (int i = 0; i < ATMO_RIDGE_LAYERS; i++) {
		float layer = float(i);
		float top = atmo_ridge_top(h, layer);
		float cover = clamp((top - t) / max(aa, 1e-5) + 0.5, 0.0, 1.0);
		if (cover <= 0.0) {
			continue;
		}
		vec3 col = atmo_ridge_shade(h, t, top, layer);
		float haze = clamp((0.62 - layer * 0.24) * atmo_ridges.z, 0.0, 1.0);
		col = mix(col, haze_sky, haze);
		// Mist pools in the valley at the foot of each range.
		float foot = atmo_ridge_base(layer) - atmo_ridges.w;
		float mist = smoothstep(foot + 0.025, foot - 0.015, t);
		col = mix(col, atmo_mist_color, mist * 0.92 * atmo_valley_mist);
		stack = vec4(col * cover, cover) + stack * (1.0 - cover);
	}
	return stack;
}

// What is behind a surface at direction [param d]: the ridges over the clear
// sky.
vec3 atmo_background(vec3 d, float aa) {
	vec4 ridges = atmo_ridge_stack(d, aa);
	return atmo_sky(d) * (1.0 - ridges.a) + ridges.rgb;
}

// ------------------------------------------------------------------
//        fog: aerial perspective and valley mist
// ------------------------------------------------------------------

// What to write to `FOG` for a surface at [param world] seen from
// [param camera]. `FOG.a` is how much of the surface is gone, `FOG.rgb` what
// replaces it; the engine mixes the two after lighting.
//
// Depth fog is ETR's range with Godot's own `smoothstep` ramp, so with
// `aerial` and the mist at 0 this is exactly the fog the engine would have
// drawn — which is how `[display] sky = etr` gets the old frame back.
vec4 atmo_fog_at(vec3 world, vec3 camera) {
	vec3 v = world - camera;
	float dist = length(v);
	vec3 d = v / max(dist, 1e-4);
	float depth = smoothstep(atmo_fog.x, atmo_fog.y, dist);

	// Exponential height fog, integrated along the ray: density
	// `k · exp(-(y - base) / H)`, whose integral over a straight line has a
	// closed form. Only past the clear distance, so the near field keeps the
	// tone it was fitted at.
	float mist = 0.0;
	if (atmo_mist.z > 0.0) {
		float run = max(dist - atmo_mist.w, 0.0);
		float h0 = max((camera.y - atmo_mist.x) / atmo_mist.y, -1.0);
		float h1 = max((world.y - atmo_mist.x) / atmo_mist.y, -1.0);
		float dh = h1 - h0;
		float mean = abs(dh) > 1e-3 ? (exp(-h0) - exp(-h1)) / dh : exp(-h0);
		mist = 1.0 - exp(-atmo_mist.z * run * mean);
	}
	float amount = 1.0 - (1.0 - depth) * (1.0 - mist);
	if (amount <= 0.0) {
		return vec4(0.0);
	}

	// Aerial perspective: the air in front of a slope is lit like the sky
	// along the horizon in that direction, sun glow included. As the slope
	// disappears altogether, what shows is whatever is behind it.
	vec3 far_colour = atmo_fog_color;
	if (atmo_fog.z > 0.0) {
		vec3 bd = atmo_backdrop_dir(d);
		vec3 flat_d = normalize(vec3(bd.x, max(bd.y, 0.0), bd.z));
		vec3 haze = atmo_sky(flat_d);
		if (depth > 0.3 && atmo_fog.w > 0.5) {
			haze = mix(haze, atmo_background(bd, 0.004), smoothstep(0.3, 1.0, depth));
		}
		far_colour = mix(atmo_fog_color, haze, atmo_fog.z);
	}
	vec3 colour = (atmo_mist_color * mist * (1.0 - depth) + far_colour * depth) / amount;
	return vec4(colour, amount);
}

// ------------------------------------------------------------------
//        torches
// ------------------------------------------------------------------

float atmo_torch_one(vec4 torch, vec3 world, vec3 n, float reach) {
	vec3 l = torch.xyz - world;
	float d = max(length(l), 1e-3);
	// Falls off with distance rather than its square: a pool with an edge, not
	// a wash over the whole slope.
	float fall = max(1.0 - d / reach, 0.0);
	// Wrapped, so snow on the far side of a hump still catches a little.
	float facing = max(dot(n, l / d), 0.0) * 0.75 + 0.25;
	return torch.w * fall * fall * facing;
}

// The torchlight reaching a surface at [param world] with world normal
// [param n]. It goes *inside* the illumination clamp with the ambient and the
// sun: a torch is one more light in ETR's fixed-function sum, and it cannot
// brighten snow past its own albedo any more than the sun can.
vec3 atmo_torch_glow(vec3 world, vec3 n) {
	if (atmo_torch_light.a <= 0.0) {
		return vec3(0.0);
	}
	float reach = atmo_torch_light.a;
	float sum = atmo_torch_one(atmo_torch_0, world, n, reach)
		+ atmo_torch_one(atmo_torch_1, world, n, reach)
		+ atmo_torch_one(atmo_torch_2, world, n, reach)
		+ atmo_torch_one(atmo_torch_3, world, n, reach)
		+ atmo_torch_one(atmo_torch_4, world, n, reach)
		+ atmo_torch_one(atmo_torch_5, world, n, reach)
		+ atmo_torch_one(atmo_torch_6, world, n, reach)
		+ atmo_torch_one(atmo_torch_7, world, n, reach);
	return atmo_torch_light.rgb * sum;
}
