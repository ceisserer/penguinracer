// The three mesh levels of a tree — the conifer (`ConiferMesh`) or the bare
// tree (`BareTreeMesh`); see those for what the geometry is, and
// `conifer.gdshaderinc` for the level hand-over, the wind and the snow, which
// the impostor shares.
//
// Every tree on the course is in every level's batches; the vertex stage
// collapses a tree that is outside this level's band to a point, so it costs
// its vertices and nothing else. `Forest` cuts the batches into cells with node
// visibility ranges, so a level only runs over the cells that can be in its band.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx,
	ambient_light_disabled;

#include "res://shaders/etr_illumination.gdshaderinc"
#include "res://shaders/conifer.gdshaderinc"

group_uniforms Surface;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;
// The thinnest a tube may look, as world radius per metre from `lod_origin`.
// A vertex whose `COLOR.b` codes a tube radius (`BareTreeMesh`) is pushed out
// along its normal to at least this; 0 — the conifer, whose vertices code no
// radius — leaves every vertex where it is. Without it a bare tree's far limbs
// are thinner than a pixel and break into crawling dashes.
uniform float min_radius_per_metre = 0.0;
// `BareTreeMesh.RADIUS_CODE_SCALE`.
const float RADIUS_CODE_SCALE = 10.0;

varying flat vec2 lod_fade;
// The shading normal in view space, carried by hand. With `cull_disabled` the
// engine flips `NORMAL` on back faces, which is right for a branch card (its
// underside is a different surface) and wrong for a fin (whose normal is the
// crown's, whichever side you see the fin from). `COLOR.r` says which.
varying vec3 shade_normal;
varying float flips;

void vertex() {
	lod_fade = conifer_lod_fade(MODEL_MATRIX[3].xyz);
	if (conifer_lod_drawn(lod_fade)) {
		if (COLOR.b > 0.0 && min_radius_per_metre > 0.0) {
			// The instance scale is (diameter, height, diameter) and a limb's
			// girth is across, so the diameter scale is the one to divide out.
			float scale = length(MODEL_MATRIX[0].xyz);
			float radius = COLOR.b / RADIUS_CODE_SCALE * scale;
			float d = distance(lod_origin, (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
			VERTEX += NORMAL * max(min_radius_per_metre * d - radius, 0.0) / scale;
		}
		VERTEX += conifer_sway(MODEL_MATRIX, COLOR.g, TIME);
	} else {
		VERTEX = vec3(0.0);
	}
	shade_normal = MODELVIEW_NORMAL_MATRIX * NORMAL;
	flips = COLOR.r;
}

void fragment() {
	if (conifer_dithered_out(FRAGCOORD.xy, lod_fade)) {
		discard;
	}
	vec4 tex = texture(albedo_texture, UV);
	tex.a = conifer_alpha(tex.a, UV, vec2(textureSize(albedo_texture, 0)));
	vec3 n = normalize(shade_normal);
	if (flips > 0.5 && dot(n, VIEW) < 0.0) {
		n = -n;
	}
	NORMAL = n;
	ALBEDO = conifer_snow(tex.rgb, (INV_VIEW_MATRIX * vec4(n, 0.0)).xyz);
	// The same one-pixel sharpen the cross shader does before its scissor.
	ALPHA = clamp((tex.a - alpha_scissor) / max(fwidth(tex.a), 0.0001) + 0.5, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
}

// ETR's sum-then-clamp, as every lit object here. See `object_cross.gdshader`.
void light() {
	DIFFUSE_LIGHT += etr_illumination(LIGHT_COLOR / PI,
		max(dot(NORMAL, LIGHT), 0.0), ATTENUATION, 1.0);
}
