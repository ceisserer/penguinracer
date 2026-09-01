// Spike S1: vertex texture fetch displacement from the ping-pong trail map.
//
// Deliberately minimal. The question this answers is not "does it look good"
// but "does a Compatibility/WebGL2 export sample a SubViewport render target in
// the vertex stage and displace geometry with it" (plan §7, risk S1).
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D trail_map : filter_linear, repeat_disable;
uniform vec2 plane_size = vec2(64.0, 64.0);
uniform float depth_scale = 1.5;

varying float displaced;

void vertex() {
	vec2 uv = VERTEX.xz / plane_size + vec2(0.5);
	float d = texture(trail_map, uv).r;
	VERTEX.y -= d * depth_scale;
	displaced = d;
}

void fragment() {
	// Trench in red, untouched snow in white, so a screenshot is unambiguous.
	ALBEDO = mix(vec3(0.9, 0.93, 1.0), vec3(0.9, 0.15, 0.1), clamp(displaced * 2.0, 0.0, 1.0));
	ROUGHNESS = 0.8;
}
