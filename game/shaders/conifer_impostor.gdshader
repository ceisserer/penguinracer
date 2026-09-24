// The conifer beyond its last mesh level: one card per tree, turned to the
// camera, showing the view of the tree baked from the nearest directions.
//
// An *octahedral* impostor rather than a billboard. A billboard shows one
// picture from every side, so a forest of them turns with the camera, and its
// lighting follows the card rather than the tree — both read as pulsing. Here
// the atlas holds 64 views over the upper hemisphere (`ConiferMesh`, hemi-
// octahedral), the card blends the three nearest to the true view direction,
// and it is lit from a baked normal atlas, so it shades as the mesh does and
// takes the same snow.
//
// Baked by `tools/bake_tree_impostors.sh` from LOD 0; re-bake whenever
// `ConiferMesh` changes shape. The bare tree (`BareTreeMesh`) draws through
// this same shader, with its own two atlases.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx,
	ambient_light_disabled;

#include "res://shaders/etr_illumination.gdshaderinc"
#include "res://shaders/conifer.gdshaderinc"

// Must match `ConiferMesh`.
const float GRID = 8.0;
const float TILE = 128.0;
const vec3 CENTER = vec3(0.0, 0.5, 0.0);
const float RADIUS = 0.7072;

group_uniforms Surface;
uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap, repeat_disable;
// Not `hint_normal`: that would let the importer re-detect the atlas as a
// tangent-space normal map and rebuild its blue channel, and these normals are
// in the tree's own frame, with z of either sign.
uniform sampler2D normal_atlas : filter_linear_mipmap, repeat_disable;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;

varying flat vec2 lod_fade;
// The three views blended and how much of each.
varying flat vec2 frame_a;
varying flat vec2 frame_b;
varying flat vec2 frame_c;
varying flat vec3 frame_w;

vec2 hemi_oct_encode(vec3 d) {
	d.y = max(d.y, 0.0);
	vec2 p = d.xz / max(abs(d.x) + d.y + abs(d.z), 1.0e-6);
	return vec2(p.x + p.y, p.x - p.y) * 0.5 + 0.5;
}

void vertex() {
	lod_fade = conifer_lod_fade(MODEL_MATRIX[3].xyz);
	mat3 m = mat3(MODEL_MATRIX);
	vec3 center_world = (MODEL_MATRIX * vec4(CENTER, 1.0)).xyz;
	// Toward the camera of *this* pass. For the sun's orthographic shadow pass
	// that is its direction, not its position — and then the card shows the
	// tree as the sun sees it, which is the shadow it should cast.
	vec3 to_camera = PROJECTION_MATRIX[3][3] != 0.0
		? INV_VIEW_MATRIX[2].xyz : CAMERA_POSITION_WORLD - center_world;
	// Into the unit tree's frame: the instance scale is not uniform, and the
	// view of a stretched tree along v is the view of the unit tree along M⁻¹v.
	vec3 d = inverse(m) * to_camera;
	d.y = max(d.y, 0.0);
	d = normalize(d + vec3(0.0, 1.0e-4, 0.0));

	vec2 g = hemi_oct_encode(d) * (GRID - 1.0);
	vec2 cell = clamp(floor(g), vec2(0.0), vec2(GRID - 2.0));
	vec2 f = g - cell;
	if (f.x + f.y < 1.0) {
		frame_a = cell;
		frame_b = cell + vec2(1.0, 0.0);
		frame_c = cell + vec2(0.0, 1.0);
		frame_w = vec3(1.0 - f.x - f.y, f.x, f.y);
	} else {
		frame_a = cell + vec2(1.0, 1.0);
		frame_b = cell + vec2(1.0, 0.0);
		frame_c = cell + vec2(0.0, 1.0);
		frame_w = vec3(f.x + f.y - 1.0, 1.0 - f.y, 1.0 - f.x);
	}

	// `ConiferMesh.view_basis`.
	vec3 ref = abs(d.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, -1.0);
	vec3 bx = normalize(cross(ref, d));
	vec3 by = cross(d, bx);
	VERTEX = CENTER + ((UV.x * 2.0 - 1.0) * bx + (1.0 - UV.y * 2.0) * by) * RADIUS;
	if (conifer_lod_drawn(lod_fade)) {
		VERTEX += conifer_sway(MODEL_MATRIX, clamp(VERTEX.y, 0.0, 1.0), TIME);
	} else {
		VERTEX = vec3(0.0);
	}
}

vec2 atlas_uv(vec2 frame, vec2 uv) {
	// Half a texel in from the tile's edge, so filtering never reads the
	// neighbouring view.
	uv = clamp(uv, vec2(0.5 / TILE), vec2(1.0 - 0.5 / TILE));
	return (frame + uv) / GRID;
}

void fragment() {
	if (conifer_dithered_out(FRAGCOORD.xy, lod_fade)) {
		discard;
	}
	vec2 ua = atlas_uv(frame_a, UV);
	vec2 ub = atlas_uv(frame_b, UV);
	vec2 uc = atlas_uv(frame_c, UV);
	vec4 tex = texture(albedo_atlas, ua) * frame_w.x
		+ texture(albedo_atlas, ub) * frame_w.y
		+ texture(albedo_atlas, uc) * frame_w.z;
	tex.a = conifer_alpha(tex.a, ua, vec2(textureSize(albedo_atlas, 0)));
	vec3 n_obj = (texture(normal_atlas, ua).rgb * frame_w.x
		+ texture(normal_atlas, ub).rgb * frame_w.y
		+ texture(normal_atlas, uc).rgb * frame_w.z) * 2.0 - 1.0;
	// Model → world for a normal: the inverse transpose, which for a basis with
	// orthogonal columns is each column over its squared length.
	vec3 c0 = MODEL_MATRIX[0].xyz;
	vec3 c1 = MODEL_MATRIX[1].xyz;
	vec3 c2 = MODEL_MATRIX[2].xyz;
	vec3 n_world = normalize(c0 * (n_obj.x / dot(c0, c0)) + c1 * (n_obj.y / dot(c1, c1))
		+ c2 * (n_obj.z / dot(c2, c2)));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	// Straight colour: the importer's `fix_alpha_border` has already spread the
	// edge colour into the transparent texels, so neither the blend nor the
	// mips drag a tree's rim toward black.
	ALBEDO = conifer_snow(tex.rgb, n_world);
	ALPHA = clamp((tex.a - alpha_scissor) / max(fwidth(tex.a), 0.0001) + 0.5, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
}

void light() {
	DIFFUSE_LIGHT += etr_illumination(LIGHT_COLOR / PI,
		max(dot(NORMAL, LIGHT), 0.0), ATTENUATION, 1.0);
}
