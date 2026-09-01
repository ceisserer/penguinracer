// Camera-facing billboard for migrated course objects — trees, shrubs, herring,
// flags. ETR drew these as billboards and so do we (§3.3); this exists only
// because StandardMaterial3D cannot billboard and keep a stable shading normal
// at the same time.
//
// A BILLBOARD_FIXED_Y quad turns to face the camera, and a QuadMesh's normal is
// its own +Z, so the shading normal tracks the camera too. N·L then swings as
// the player rides past and **every tree visibly changes brightness with the
// view angle** — the quad is flat, so the whole cutout brightens and darkens
// together. Fixing it means decoupling the shading normal from the quad's
// orientation, which is what the impostor normal below does.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;

// The quad is shaded as a vertical cylinder rather than as a flat card: a
// cylinder lit by a directional light presents the same aggregate brightness
// from every azimuth, so riding around a tree no longer changes its overall
// tone, while the across-quad gradient still gives it volume. 0 = flat card
// (the old behaviour), 1 = full cylinder.
uniform float normal_roundness : hint_range(0.0, 1.0) = 0.75;
// How far the normal leans toward world up. Foliage catches sky light from
// above; without this a billboard reads as a wall.
uniform float normal_up_bias : hint_range(0.0, 1.0) = 0.35;

// Billboard basis in view space, so the impostor normal can be built in the
// fragment stage without recovering the orientation there.
varying vec3 axis_right;
varying vec3 axis_up;
varying vec3 axis_out;

void vertex() {
	// BILLBOARD_FIXED_Y, matching what StandardMaterial3D generates: keep the
	// instance's own Y (these objects stand upright on the slope) and spin
	// about it to face the camera.
	vec3 up = normalize(MODEL_MATRIX[1].xyz);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 out_dir = normalize(cross(right, up));

	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(right, 0.0),
		vec4(up, 0.0),
		vec4(out_dir, 0.0),
		MODEL_MATRIX[3]);
	// billboard_keep_scale: the per-instance transform carries diameter and
	// height, and dropping it would collapse every object to a unit quad.
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));

	axis_right = mat3(VIEW_MATRIX) * right;
	axis_up = mat3(VIEW_MATRIX) * up;
	axis_out = mat3(VIEW_MATRIX) * out_dir;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV) * albedo_tint;
	ALBEDO = tex.rgb;

	// Sharpen the cutout back to a one-pixel edge before scissoring. Mip
	// filtering blurs a branch's alpha ramp over several texels, and a hard
	// threshold through a blurred ramp turns thin twigs into chunky blobs that
	// change shape with distance. Rescaling by the screen-space derivative
	// keeps the silhouette on the same alpha isoline at every mip level.
	ALPHA = clamp((tex.a - alpha_scissor) / max(fwidth(tex.a), 0.0001) + 0.5, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
	SPECULAR = 0.2;

	// Cylinder impostor: bulge the normal across the quad's width only. The
	// vertical axis is left alone because a tree is tall and round, not
	// spherical, and because a y-dependent term would make the canopy and the
	// trunk light differently for no gain at this size on screen.
	float u = clamp(UV.x, 0.0, 1.0) * 2.0 - 1.0;
	vec3 curved = axis_right * u + axis_out * sqrt(max(0.0, 1.0 - u * u));
	vec3 n = mix(axis_out, curved, normal_roundness);
	NORMAL = normalize(mix(n, axis_up, normal_up_bias));
}
