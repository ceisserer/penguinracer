// A torch's flame and the glow round it: one upright camera-facing quad per
// torch, drawn additively, flickering on its own seed. See [CourseLights].
//
// Unshaded and additive, so the engine's fog is off — fogging an additive
// quad toward the fog colour would *add* the fog colour — and the flame is
// dimmed by the atmosphere's own fog amount instead.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled,
	shadows_disabled, skip_vertex_transform;

#include "res://shaders/atmosphere.gdshaderinc"

uniform vec3 flame_color = vec3(1.0, 0.55, 0.18);
uniform vec3 core_color = vec3(1.0, 0.9, 0.6);
uniform float brightness = 1.6;

varying float seed;
varying float clear;

void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	float size = length(MODEL_MATRIX[1].xyz);
	seed = fract(centre.x * 0.1373 + centre.z * 0.7117);
	// Upright, turned to the camera about the vertical only: a flame leans
	// with the air, never with the view.
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	right = normalize(vec3(right.x, 0.0, right.z) + vec3(1e-4, 0.0, 0.0));
	vec3 world = centre + right * VERTEX.x * size + vec3(0.0, VERTEX.y * size, 0.0);
	clear = 1.0 - atmo_fog_at(world, CAMERA_POSITION_WORLD).a;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec2 q = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	float t = atmo_time * 3.0 + seed * 40.0;
	// A teardrop narrowing upward, its edge licked by noise rising through it.
	float lick = atmo_noise(vec2(q.x * 3.0 + seed * 9.0, q.y * 2.5 - t * 1.6)) - 0.5;
	float body_y = q.y + 0.35;
	float width = 0.26 * (1.0 - smoothstep(-0.2, 0.75, body_y)) + 0.02;
	float body = smoothstep(width + 0.05, width - 0.05, abs(q.x + lick * 0.18 * body_y))
		* smoothstep(-0.45, -0.25, q.y) * (1.0 - smoothstep(0.2, 0.7, body_y + lick * 0.3));
	float core = body * smoothstep(0.25, -0.15, body_y + abs(q.x) * 2.0);
	float flicker = 0.85 + 0.15 * sin(t * 2.3) * sin(t * 1.7 + 1.3);
	float glow = exp(-dot(q, q) * 3.5) * 0.18 * flicker;
	vec3 c = flame_color * body + core_color * core + flame_color * glow;
	ALBEDO = c * brightness * flicker * clear;
}
