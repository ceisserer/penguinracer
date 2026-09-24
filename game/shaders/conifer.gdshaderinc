// What every level of the conifer does the same way: which level a tree is
// drawn at, the wind, and the snow. Included by `conifer.gdshader` (the three
// mesh levels) and `conifer_impostor.gdshader` (the card beyond them), and it
// has to be the same arithmetic in both — two levels cross-fading are two
// draws of one tree, and anything that differs between them is what the eye
// sees pop.

group_uniforms LevelOfDetail;
// Where the distances are measured from: the main camera, written every frame
// by `Forest`. Not `CAMERA_POSITION_WORLD`, because in the shadow pass that is
// the sun, and a tree has to cast the level it is drawn at.
uniform vec3 lod_origin = vec3(0.0);
// This level's band, in metres from `lod_origin`. `lod_begin` = -1e6 on the
// nearest level and `lod_end` huge on the impostor mean "no edge there".
uniform float lod_begin = -1.0e6;
uniform float lod_end = 1.0e6;
// How wide each hand-over is. Inside it both neighbouring levels draw the tree,
// each on the complementary half of a 4×4 Bayer pattern.
uniform float lod_fade_width = 4.0;

group_uniforms Wind;
// Direction the wind blows toward, on the ground plane, and how hard, 0..1
// (`WindField.speed() / 100`). Both from `Forest.set_weather`.
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_strength = 0.0;
// 0..1: `SnowFall.grade / MAX_GRADE`. Loaded branches swing further.
uniform float snow_level = 0.0;
// Tip movement as a fraction of the tree's height. `sway_calm` is what a still
// day still does — a conifer is never quite motionless — and the other two add
// to it. `lean_per_wind` is the steady bend downwind under the oscillation.
uniform float sway_calm = 0.004;
uniform float sway_per_wind = 0.02;
uniform float sway_per_snow = 0.006;
uniform float lean_per_wind = 0.02;

group_uniforms Snow;
// DEVIATION: ETR's trees are only as snowy as their texture. Here the surfaces
// that face up are whitened in the shader — the texture is unchanged — and
// heavier snowfall both whitens harder and lowers how steep a face has to be to
// hold snow.
uniform vec3 snow_albedo : source_color = vec3(0.93, 0.95, 0.98);
uniform float snow_calm = 0.3;
uniform float snow_heavy = 0.7;

// Fade-in and fade-out factors for this tree, 0..1 each. The tree is drawn
// where `fade.y <= dither < fade.x`.
vec2 conifer_lod_fade(vec3 tree_origin) {
	float d = distance(lod_origin, tree_origin);
	float h = lod_fade_width * 0.5;
	float fade_in = clamp((d - (lod_begin - h)) / lod_fade_width, 0.0, 1.0);
	float fade_out = clamp((d - (lod_end - h)) / lod_fade_width, 0.0, 1.0);
	return vec2(fade_in, fade_out);
}

bool conifer_lod_drawn(vec2 fade) {
	return fade.x > 0.0 && fade.y < 1.0;
}

// Ordered 4×4 Bayer threshold at this pixel, (k + 0.5) / 16. Screen-anchored,
// so the two levels crossing over at a pixel read the same threshold and cover
// it exactly once between them.
float conifer_bayer(vec2 frag) {
	ivec2 p = ivec2(mod(frag, 4.0));
	int i = p.x + p.y * 4;
	int m[16] = int[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i]) + 0.5) / 16.0;
}

bool conifer_dithered_out(vec2 frag, vec2 fade) {
	float b = conifer_bayer(frag);
	return b >= fade.x || b < fade.y;
}

// The wind bend, in model space, for a point at height fraction `h`.
//
// A cantilever's deflection goes as the square of the height, so the trunk
// stays planted and the tip moves most. The displacement is decided in the
// world (metres, along the wind) and taken back into the instance's frame
// through its basis, whose columns are orthogonal — a yaw times a
// (diameter, height, diameter) scale — so each axis divides out on its own.
vec3 conifer_sway(mat4 model, float h, float time) {
	vec3 origin = model[3].xyz;
	float tree_height = length(model[1].xyz);
	float phase = dot(origin.xz, vec2(0.37, 0.61));
	float osc = sin(time * 1.3 + phase) * 0.7 + sin(time * 2.9 + phase * 1.7) * 0.3;
	float swing = sway_calm + sway_per_wind * wind_strength + sway_per_snow * snow_level;
	float amount = lean_per_wind * wind_strength + swing * osc;
	vec3 dw = vec3(wind_direction.x, 0.0, wind_direction.y) * tree_height * h * h * amount;
	vec3 c0 = model[0].xyz;
	vec3 c1 = model[1].xyz;
	vec3 c2 = model[2].xyz;
	return vec3(dot(c0, dw) / dot(c0, c0), dot(c1, dw) / dot(c1, c1), dot(c2, dw) / dot(c2, c2));
}

// Whiten what faces up. `n_world` is the shading normal in world space.
// Brighter texels — the snow the picture already has — take more, the dark
// gaps between branches less, so the whitening follows the needles' structure
// instead of painting over it.
vec3 conifer_snow(vec3 albedo, vec3 n_world) {
	// Never below 0.6: a fin's crown normal has y ≈ 0.52, and a threshold under
	// it snows the whole silhouette, which reads as a white cone, not a loaded
	// tree.
	float lo = mix(0.8, 0.6, snow_level);
	float hi = mix(0.97, 0.88, snow_level);
	float facing = smoothstep(lo, hi, n_world.y);
	float lum = dot(albedo, vec3(0.3, 0.59, 0.11));
	float cover = mix(snow_calm, snow_heavy, snow_level) * facing * (0.5 + 0.5 * sqrt(lum));
	return mix(albedo, snow_albedo, clamp(cover, 0.0, 1.0));
}
