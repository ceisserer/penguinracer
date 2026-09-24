// Writes one of the conifer impostor's two atlases: the texture's colour
// (`bake_mode` 0) or the unit tree's shading normal in its own frame, packed
// to 0..1 (`bake_mode` 1). Used only by `tools/bake_conifer_impostor.gd`.
//
// Baked under Compatibility (the wrapper pins it), which draws an unshaded
// material without converting anything: a `source_color` texture is not
// decoded on the way in and ALBEDO is not encoded on the way out (measured: a
// constant 0.214 reads back 0.212; the texture's colour comes back as its own
// sRGB bytes). So both atlases are written raw — the colour arrives as the
// sRGB texture it came from, for the impostor to decode like any other, and
// the normal arrives packed to 0..1 exactly as written. Under Mobile both would
// be wrong by an sRGB curve.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform int bake_mode = 0;

varying vec3 object_normal;
varying vec3 view_normal;
varying float flips;

void vertex() {
	object_normal = NORMAL;
	view_normal = MODELVIEW_NORMAL_MATRIX * NORMAL;
	flips = COLOR.r;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	vec3 n = normalize(object_normal);
	// The camera looks down −Z, so a face seen from behind points away from +Z.
	// Same rule as `conifer.gdshader`.
	if (flips > 0.5 && view_normal.z < 0.0) {
		n = -n;
	}
	ALBEDO = bake_mode == 0 ? tex.rgb : n * 0.5 + 0.5;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
