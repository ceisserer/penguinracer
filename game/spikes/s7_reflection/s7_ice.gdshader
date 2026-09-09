// Spike S7 — the ice half of a planar character reflection.
//
// This is the shape the addition to `terrain.gdshader` takes: one texture read
// at SCREEN_UV, weighted by the Fresnel term the ice branch already computes
// and by `ice_mask`, added through EMISSION beside the sky ramp.
shader_type spatial;

uniform sampler2D reflection_map : filter_linear, hint_default_transparent;
uniform float reflection_strength : hint_range(0.0, 16.0) = 1.0;

void fragment() {
	ALBEDO = vec3(0.62, 0.68, 0.78);
	ROUGHNESS = 0.12;

	// Schlick against the view, exactly as the ice branch does it today.
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = 0.018 + 0.982 * pow(1.0 - ndv, 5.0);

	// Straight alpha against the transparent clear: alpha is the character's
	// coverage, so this adds nothing where the reflection pass drew nothing.
	vec4 refl = texture(reflection_map, SCREEN_UV);
	EMISSION += refl.rgb * refl.a * fresnel * reflection_strength;
}
