// Bakes `atmo_ridge_map` — see the map's notes in `atmosphere.gdshaderinc`
// and [RidgeMap], which draws this once per race on a rect covering its
// viewport. Raw values in, raw values out: a 2D target converts nothing on
// either renderer, and nothing samples the map as colour.
shader_type canvas_item;
render_mode blend_disabled, unshaded;

#define ATMO_RIDGE_MAP_BAKE
#include "res://shaders/atmosphere.gdshaderinc"

void fragment() {
	// The rect's UV rather than FRAGCOORD, so the bake and the lookup share one
	// convention: row 0 is the top of the texture in both.
	float column = floor(UV.x * ATMO_MAP_WIDTH);
	float row = floor(UV.y * 2.0 * ATMO_MAP_ROWS);
	bool haze_half = row >= ATMO_MAP_ROWS;
	if (haze_half) {
		row -= ATMO_MAP_ROWS;
	}
	// Column centres are where `atan(h.y, h.x) / TAU + 0.5` lands on them.
	float angle = ((column + 0.5) / ATMO_MAP_WIDTH - 0.5) * TAU;
	vec2 h = vec2(cos(angle), sin(angle));
	float t = ATMO_MAP_T_MIN + row / (ATMO_MAP_ROWS - 1.0) * (ATMO_MAP_T_MAX - ATMO_MAP_T_MIN);
	float haze;
	vec4 stack = atmo_ridge_layers(h, t, ATMO_FOG_RIDGE_AA, haze);
	if (haze_half) {
		COLOR = vec4(haze, 0.0, 0.0, 1.0);
	} else {
		COLOR = vec4(sqrt(max(stack.rgb, vec3(0.0)) / ATMO_MAP_RANGE), stack.a);
	}
}
