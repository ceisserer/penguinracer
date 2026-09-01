// ETR's three-sided skybox, as a Godot sky shader.
//
// `env.cpp DrawSkybox` draws a unit cube centred on the camera *position* but
// never rotated with it, and — with `param.full_skybox` off, which is the
// shipped default — binds only three of its six faces: front at z = -1, left at
// x = -1, right at x = +1. The course runs downhill along -Z here as it does
// there, so "front" is the direction of travel and the three faces cover the
// 270 degrees a player can actually see.
//
// The faces are flat quads, not a spherical projection, so the mapping below is
// the same cube-face intersection the fixed-function pipeline did per vertex,
// evaluated per pixel instead. Texture coordinates match the quads in
// DrawSkybox: u runs left to right along the view, v runs top to bottom, which
// is also how Godot indexes an imported PNG, so no flip is needed.
//
// Everything the three faces do not cover — above them, below them, and the 90
// degrees directly behind the player — is filled by fading to two flat colours
// the importer averages off the edge rows of the front face. ETR simply left
// those directions unpainted (you see them only mid-trick), but a Godot sky has
// to return something for every direction.
shader_type sky;

uniform sampler2D face_front : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D face_left : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D face_right : source_color, filter_linear_mipmap, repeat_disable;

// Beyond the top and bottom edges of the faces. Averaged from the front face's
// edge rows at import so they meet it without a visible join.
uniform vec3 zenith_color : source_color = vec3(0.24, 0.39, 0.75);
uniform vec3 nadir_color : source_color = vec3(0.55, 0.60, 0.70);
// Fade length past a face edge, in face-heights. 0.5 is a quarter of the sky.
uniform float fade_span : hint_range(0.05, 2.0) = 0.5;
uniform float energy : hint_range(0.0, 4.0) = 1.0;

void sky() {
	vec3 d = EYEDIR;
	// Which of the three faces this direction hits. `left` and `right` are
	// exact opposites, so at most one of them can win.
	float toward_front = -d.z;
	float sideways = abs(d.x);
	bool is_front = toward_front >= sideways;
	bool is_left = !is_front && d.x < 0.0;

	// Ray/plane intersection per face. Each of these is smooth across the
	// boundary where its own face stops winning, so all three are sampled
	// unconditionally: a texture fetch inside divergent control flow has no
	// defined derivative, and the seams are exactly where that would show.
	vec2 pf = d.xy / max(toward_front, 1e-4);
	vec2 pl = vec2(d.z, d.y) / max(-d.x, 1e-4);
	vec2 pr = vec2(d.z, d.y) / max(d.x, 1e-4);
	vec2 uv_front = vec2(pf.x * 0.5 + 0.5, 0.5 - pf.y * 0.5);
	vec2 uv_left = vec2(0.5 - pl.x * 0.5, 0.5 - pl.y * 0.5);
	vec2 uv_right = vec2(pr.x * 0.5 + 0.5, 0.5 - pr.y * 0.5);

	// The samplers clamp to edge, so a horizontal overshoot — the 90 degrees
	// behind the player — continues the outermost column of whichever side face
	// is in front of it. Vertically we fade instead: a stretched column of
	// cloud running to the zenith reads as a smear, a flat sky does not.
	vec3 cf = texture(face_front, clamp(uv_front, 0.0, 1.0)).rgb;
	vec3 cl = texture(face_left, clamp(uv_left, 0.0, 1.0)).rgb;
	vec3 cr = texture(face_right, clamp(uv_right, 0.0, 1.0)).rgb;

	vec3 c = is_front ? cf : (is_left ? cl : cr);
	float v = is_front ? uv_front.y : (is_left ? uv_left.y : uv_right.y);

	float span = max(fade_span, 1e-3);
	c = mix(c, zenith_color, smoothstep(0.0, 1.0, -v / span));
	c = mix(c, nadir_color, smoothstep(0.0, 1.0, (v - 1.0) / span));
	COLOR = c * energy;
}
