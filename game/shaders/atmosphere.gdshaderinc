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
// light's direction — see [constant Atmosphere.SUN_DIRECTION] and
// [constant Atmosphere.MOON_DIRECTION].
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
// The ridges' shape, per course ([method Atmosphere.ridge_shape]): how tall the
// ranges stand (1 the usual low skyline), how far up their flanks the forest
// climbs (0 a fringe at the foot, 1 almost to the crests), how near they are
// (0 kilometres off, 1 the next valley over: broader, less hazed). w unused.
// (1, 0, 0, 0) is the skyline every imported course has.
global uniform vec4 atmo_ridge_shape;
// How far below the true horizon the backdrop's horizon sits, as a tangent:
// the sky, its clouds and the ridges are all drawn as if the world's horizon
// were this much lower. A chase camera at its pitch clamp sees nothing above
// -5 degrees, so a horizon at 0 is never in shot. See [method Atmosphere.horizon_dip].
global uniform float atmo_dip;
// 0 by day, 1 by night.
global uniform float atmo_night;
// A lightning flash lighting the cloud deck from inside: the light it adds to
// the sky, linear, and in w the flash's strength 0..1. Zero under every sky but
// the storm's, and between its flashes. See [Lightning].
global uniform vec4 atmo_flash;
// Where the flash is: the horizontal direction of the strike (x, z), a seed
// for the shape of its bolt, and how brightly the bolt itself shows — 0 when
// the flash is sheet lightning, lit inside the cloud with no channel to see.
global uniform vec4 atmo_bolt;
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

// How much a lightning flash brightens the sky in direction [param d]: the
// whole deck a little, the part of it over the strike most. In the sky's
// gradient, so the haze in front of a far slope flashes with the sky behind it
// and a fogged slope never shows as a dark cut-out against a lit sky.
vec3 atmo_flash_at(vec3 d) {
	if (atmo_flash.w <= 0.0) {
		return vec3(0.0);
	}
	vec2 h = normalize(d.xz + vec2(1e-5));
	float toward = max(dot(h, atmo_bolt.xy), 0.0);
	float over = 0.3 + 0.7 * toward * toward * toward;
	// Brightest in the cloud, fading down to the horizon.
	float height = 0.45 + 0.55 * smoothstep(-0.05, 0.25, d.y);
	return atmo_flash.rgb * over * height;
}

// The clear sky in direction [param d]: the gradient the migrated skybox was
// averaged into, a brighter band where the air is thickest, and the disc's
// glow. No clouds, stars or ridges — this is also what the air between the
// camera and a distant slope is lit by.
vec3 atmo_sky(vec3 d) {
	float up = clamp(d.y, 0.0, 1.0);
	vec3 c = mix(atmo_horizon, atmo_zenith, sqrt(up));
	// Below the backdrop's horizon is the course's own terrain, down to about
	// a fifth under it on the steep ones. A gap there between the ridges and
	// the snow is far valley, so it stays the horizon's colour: fading to the
	// ground from 0 drew the dipped horizon as a grey arc over the ridges.
	c = mix(c, atmo_ground, smoothstep(0.2, 0.5, -d.y));
	// Looking along the horizon looks through the most air.
	float band = exp(-abs(d.y) * 9.0);
	c += atmo_horizon * 0.10 * band;
	// Forward scattering round the disc, strongest along the horizon under it.
	// Tight: the disc stands in shot now (see [constant Atmosphere.SUN_DIRECTION]),
	// and the wide halo it had while it stood out of shot clipped a fifth of
	// the frame to white round it, disc and all. The lens adds the bloom
	// ([LensFlare]).
	float mu = max(dot(d, atmo_sun_dir), 0.0);
	float halo = pow(mu, 3000.0) * 0.35 + pow(mu, 120.0) * 0.08 + pow(mu, 6.0) * 0.06;
	float horizon_glow = mu * mu * band * 0.35;
	return c + atmo_sun_color * (halo + horizon_glow) + atmo_flash_at(d);
}

// ------------------------------------------------------------------
//        the ridges
// ------------------------------------------------------------------

const int ATMO_RIDGE_LAYERS = 3;

// The foot of layer [param layer], before the drop: where its valley is.
float atmo_ridge_base(float layer) {
	return -0.02 - layer * 0.04;
}

// How tall layer [param layer]'s crests can stand over its foot, per unit of
// noise. The far range stands tallest and the near ranges lowest, so every
// layer shows over the one in front of it.
float atmo_ridge_amplitude(float layer) {
	return (0.15 - layer * 0.025) * atmo_ridge_shape.x;
}

// The ridge line of layer [param layer] (0 farthest) above horizontal
// direction [param h], as the tangent of its elevation before the drop
// (`atmo_ridges.w`): everything about a ridge is worked out in that frame, so
// the ranges sink as one rigid picture. Noise sampled round a circle, so it
// closes on itself at 360 degrees without a seam.
float atmo_ridge_top(vec2 h, float layer) {
	// A near range is broader: fewer peaks round the horizon.
	float radius = (2.6 + layer * 1.7) * (1.0 - 0.4 * atmo_ridge_shape.z);
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
	return atmo_ridge_base(layer) + atmo_ridge_amplitude(layer) * n;
}

// The most the octaves above can sum to: every `v` at 1 and every clamp at 1,
// 0.55 · (1 + 1/2 + … + 1/32).
const float ATMO_RIDGE_NOISE_MAX = 1.0828125;

// The highest [code]atmo_ridge_top[/code] can reach for [param layer], without
// the noise: 0.1425 for the far range. Above it the layer covers nothing, and
// that is most of the sky.
float atmo_ridge_crest_max(float layer) {
	return atmo_ridge_base(layer) + atmo_ridge_amplitude(layer) * ATMO_RIDGE_NOISE_MAX;
}

// Firs on a wooded range, at azimuth [param az] (0..1 round the horizon) and
// tangent-of-elevation [param t], for a layer whose face noise has
// [param period] cells round the horizon: x is 1 on a tree and 0 in the dark
// between trees, y the snow lying on one. The canopy seen from across a
// valley is the pointed tops of trees standing behind one another, so each
// cell of a grid (four to a face cell round the horizon, rows staggered up
// the slope) holds one top — shifted, sized and shaded at random, or none —
// and the rest is shadow. The grid wraps at 360 degrees like the face.
vec2 atmo_ridge_firs(float az, float t, float period, float layer) {
	float cols = period * 4.0;
	// The same angular unit up the slope as round it: a top about as tall as
	// it is wide.
	float v = t * cols / TAU * 1.1;
	float row = floor(v);
	float u = az * cols + atmo_hash12(vec2(row, layer + 11.0));
	float cell = mod(floor(u), cols);
	vec2 f = vec2(fract(u) - 0.5, fract(v));
	vec2 key = vec2(cell, row + layer * 97.0);
	float r1 = atmo_hash12(key);
	float r2 = atmo_hash12(key + vec2(31.7, 5.3));
	if (r2 < 0.18) {
		return vec2(0.0);
	}
	float base = r1 * 0.3;
	float g = clamp((f.y - base) / (1.0 - base), -1.0, 1.0);
	float half_width = (1.0 - g) * mix(0.32, 0.55, r2) * step(0.0, g);
	float edge = abs(f.x + (r1 - 0.5) * 0.35);
	float tree = smoothstep(half_width + 0.06, half_width - 0.06, edge);
	float snow = tree * smoothstep(0.55, 0.25, g) * step(0.85, r1);
	return vec2(tree * mix(0.55, 1.0, r2), snow);
}

// A layer's own colour where it is solid: a rock face with snow lying on
// whatever part of it is not too steep to hold any, lit from the disc's side.
// [param t] and [param top] are before the drop, like [code]atmo_ridge_top[/code].
//
// The face is a second noise field over (round the horizon, up), and its
// gradient tilts the normal. Shading off the crest line alone — the one piece
// of shape a silhouette has — gives every column of pixels one tone, which
// reads as a row of vertical planks.
vec3 atmo_ridge_shade(vec2 h, float t, float top, float layer) {
	// Cells round the horizon: the far range the finest, the foothills the
	// coarsest, as they would be at those distances.
	float period = floor((150.0 - layer * 40.0) * (1.0 - 0.4 * atmo_ridge_shape.z));
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
	float below = (top - t) / (0.04 * atmo_ridge_shape.x);
	float holds = face.y + (n - 0.5) * 0.5 - below * 0.25 + 0.05 * layer;
	float snow = smoothstep(0.42, 0.62, holds);
	vec3 rock = vec3(0.16, 0.17, 0.2);
	// Forest on the lower flanks, dark and ragged at the tree line — or, on a
	// wooded range, up to just under the crests, following them.
	float foot = atmo_ridge_base(layer);
	float tree_line = mix(foot + 0.035, top - 0.02 * atmo_ridge_shape.x, atmo_ridge_shape.y)
		+ (n - 0.5) * 0.03 * mix(1.0, atmo_ridge_shape.x, atmo_ridge_shape.y);
	float forest = smoothstep(tree_line + 0.01, tree_line - 0.01, t)
		* (1.0 - snow * mix(0.6, 0.25, atmo_ridge_shape.y));
	// A wooded face is trees, not a flat green: fir silhouettes, lit green
	// against dark gaps, snow on their tiers. Only there, so the usual fringe
	// keeps its one colour.
	vec3 woods = vec3(0.07, 0.10, 0.09);
	if (atmo_ridge_shape.y > 0.0) {
		vec2 firs = atmo_ridge_firs(az, t, period, layer);
		woods = mix(vec3(0.012, 0.022, 0.015), vec3(0.045, 0.09, 0.05), firs.x);
		woods = mix(woods, vec3(0.45, 0.5, 0.54), firs.y * 0.35);
	}
	rock = mix(rock, woods, forest);
	vec3 albedo = mix(rock, vec3(0.88, 0.91, 0.97), snow * (1.0 - forest * 0.7));

	vec3 sky_light = mix(atmo_zenith, atmo_horizon, 0.5);
	return albedo * (sky_light + atmo_sun_color * atmo_ridges.y * ndl);
}

// The ridges round horizontal direction [param h] at tangent-of-elevation
// [param t] before the drop, each hazed by its distance and misted at its
// foot, as premultiplied colour and coverage — *without* the haze's colour,
// whose share comes back in [param haze]: the full colour is
// `rgb + haze * atmo_ridge_haze_sky(...)`. The haze is the one term that
// depends on where the ridges stand after the drop, so leaving it out is what
// lets `atmo_ridge_map` be baked once for the whole race.
//
// Composited front to back, which is the same "over" as back to front, so it
// can stop at the first range that covers the pixel outright.
vec4 atmo_ridge_layers(vec2 h, float t, float aa, out float haze) {
	vec4 stack = vec4(0.0);
	haze = 0.0;
	for (int i = ATMO_RIDGE_LAYERS - 1; i >= 0; i--) {
		float layer = float(i);
		// Clear of the tallest crest this layer can have: no coverage, and no
		// six octaves of noise to find that out.
		if (t >= atmo_ridge_crest_max(layer) + 0.5 * max(aa, 1e-5)) {
			continue;
		}
		float top = atmo_ridge_top(h, layer);
		float cover = clamp((top - t) / max(aa, 1e-5) + 0.5, 0.0, 1.0);
		if (cover <= 0.0) {
			continue;
		}
		vec3 col = atmo_ridge_shade(h, t, top, layer);
		float hz = clamp((0.62 - layer * 0.24) * atmo_ridges.z
			* (1.0 - 0.7 * atmo_ridge_shape.z), 0.0, 1.0);
		// Mist pools in the valley at the foot of each range.
		float foot = atmo_ridge_base(layer);
		float mist = smoothstep(foot + 0.025, foot - 0.015, t) * 0.92 * atmo_valley_mist;
		// mix(mix(col, haze_sky, hz), mist_color, mist), with haze_sky left out.
		float share = cover * (1.0 - stack.a);
		stack += vec4(((1.0 - mist) * (1.0 - hz) * col + mist * atmo_mist_color) * share, share);
		haze += (1.0 - mist) * hz * share;
		if (stack.a >= 1.0) {
			break;
		}
	}
	return stack;
}

// The haze a ridge takes: the sky along the horizon beneath it, not the sky at
// its own pixel — a crest against the zenith is not zenith-blue. [param t] is
// after the drop.
vec3 atmo_ridge_haze_sky(vec2 h, float t) {
	return atmo_sky(normalize(vec3(h.x, max(t, 0.0) * 0.3, h.y)));
}

// The ridges at direction [param d]: premultiplied colour and coverage, to lay
// over whatever sky is behind them. [param aa] is the edge's width in
// tangent-of-elevation, a pixel's worth. Evaluated in full — the sky's own
// pixels, where the crests have to be sharp at any resolution.
vec4 atmo_ridge_stack(vec3 d, float aa) {
	if (atmo_fog.w < 0.5) {
		return vec4(0.0);
	}
	float hl = max(length(d.xz), 1e-4);
	vec2 h = d.xz / hl;
	float t = d.y / hl;
	float haze;
	vec4 stack = atmo_ridge_layers(h, t + atmo_ridges.w, aa, haze);
	if (stack.a <= 0.0) {
		return vec4(0.0);
	}
	return vec4(stack.rgb + haze * atmo_ridge_haze_sky(h, t), stack.a);
}

// `atmo_ridge_map`: [code]atmo_ridge_layers[/code] baked once per race by
// [RidgeMap], so that the fog — which asks for the ridges behind every far
// fragment of every lit surface — reads two texels instead of evaluating three
// layers of noise. The evaluation cost about a millisecond a frame on the
// desktop's iGPU. Columns go once round the horizon (the same azimuth as
// `atmo_ridge_shade`); rows run over tangent-of-elevation before the drop from
// ATMO_MAP_T_MIN to atmo_map_t_max(), which clears the tallest crest the noise
// can make (0.1425). Steeper down than T_MIN reads the bottom row: a surface
// fogged past 80 m that far under the dipped horizon did not show in captures
// of the five steepest courses. The upper half holds colour and coverage, the
// lower half the haze's share in red. RGBA8, so the colour is stored as
// sqrt(rgb / ATMO_MAP_RANGE): a square root spends the eight bits where the
// dark rock needs them. Keep the sizes in step with [RidgeMap].
const float ATMO_MAP_WIDTH = 4096.0;
const float ATMO_MAP_ROWS = 512.0;
const float ATMO_MAP_T_MIN = -0.6;
// The top row: 0.16, or over a taller range ([code]atmo_ridge_shape.x[/code])
// just over its tallest crest.
float atmo_map_t_max() {
	return max(0.16, atmo_ridge_crest_max(0.0) + 0.01);
}
const float ATMO_MAP_RANGE = 2.0;
// The edge width the fog has always asked the ridges for.
const float ATMO_FOG_RIDGE_AA = 0.004;

// The map's own bake shader includes this file too, and must not be handed the
// texture it is drawing.
#ifndef ATMO_RIDGE_MAP_BAKE
// 1 once [RidgeMap] has baked the map for this race. Anywhere else — the
// editor, a scene without a race — far surfaces fade into the plain sky.
//
// There is deliberately no fallback to evaluating the ridges here. A branch
// that is never taken still costs: the shader is allocated registers for its
// widest path, and with the noise compiled in every lit shader ran about as
// slowly as with no map at all (0.6-0.9 ms a frame on the desktop's iGPU).
global uniform float atmo_ridge_baked;
global uniform sampler2D atmo_ridge_map : filter_linear, repeat_enable;

// [code]atmo_ridge_stack[/code] at the fog's edge width, from the map.
vec4 atmo_ridge_stack_far(vec3 d) {
	if (atmo_fog.w < 0.5) {
		return vec4(0.0);
	}
	float hl = max(length(d.xz), 1e-4);
	vec2 h = d.xz / hl;
	float t = d.y / hl;
	if (atmo_ridge_baked < 0.5) {
		return vec4(0.0);
	}
	float t0 = t + atmo_ridges.w;
	float row = clamp((t0 - ATMO_MAP_T_MIN) / (atmo_map_t_max() - ATMO_MAP_T_MIN), 0.0, 1.0)
		* (ATMO_MAP_ROWS - 1.0) + 0.5;
	float u = atan(h.y, h.x) / TAU + 0.5;
	vec4 texel = texture(atmo_ridge_map, vec2(u, row / (2.0 * ATMO_MAP_ROWS)));
	if (texel.a <= 0.0) {
		return vec4(0.0);
	}
	float haze = texture(atmo_ridge_map, vec2(u, (row + ATMO_MAP_ROWS) / (2.0 * ATMO_MAP_ROWS))).r;
	vec3 rgb = texel.rgb * texel.rgb * ATMO_MAP_RANGE;
	return vec4(rgb + haze * atmo_ridge_haze_sky(h, t), texel.a);
}
#else
// The bake draws no fog; this only keeps `atmo_fog_at` compiling.
vec4 atmo_ridge_stack_far(vec3 d) {
	return vec4(0.0);
}
#endif

// What is behind a far surface at direction [param d]: the ridges over the
// clear sky.
vec3 atmo_background(vec3 d) {
	vec4 ridges = atmo_ridge_stack_far(d);
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
	if (atmo_mist.z > 0.0 && dist > atmo_mist.w) {
		float run = dist - atmo_mist.w;
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
			haze = mix(haze, atmo_background(bd), smoothstep(0.3, 1.0, depth));
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
