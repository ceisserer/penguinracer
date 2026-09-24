// Static crossed-quad impostor for the course objects that stand still —
// trees and shrubs, i.e. everything `object_types.lst` marks `[coll] 1`.
//
// **These are not billboards in the original and must not be here.**
// `DrawTrees` in `course_render.cpp` draws each collidable object as eight
// vertices: one quad spanning ±radius in X and one spanning ±radius in Z, both
// rising from the ground to `height`, with no rotation toward the camera at
// all. A camera-facing quad is what it draws for the *items* — herring and
// flags, the `NocollArr` loop — and that half is `object_billboard.gdshader`.
// One card turned to face you reads as a cardboard cutout that swivels as you
// ride past it; two fixed cards do not, and they are also what gives a tree a
// silhouette that changes as you go round it.
//
// The fragment half is `object_billboard.gdshader`'s, minus the reconstruction
// of the billboard basis: the mesh carries a real NORMAL and TANGENT per face,
// so the cylinder impostor can be built straight off them.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx,
	ambient_light_disabled;

#include "res://shaders/etr_illumination.gdshaderinc"

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;

// 0 = shade each quad as the flat card it is, 1 = shade the pair as the
// vertical cylinder of foliage they stand in for. The original gives every
// vertex of both quads `glNormal3i(0, 0, 1)`, so its trees are lit flat and
// identically from every azimuth; a real per-face normal instead splits a tree
// into a bright half and a dark half at 90 degrees to it, which is worse than
// either. The cylinder keeps ETR's even aggregate brightness and adds the
// across-quad gradient that gives it volume.
uniform float normal_roundness : hint_range(0.0, 1.0) = 0.75;
// How far the normal leans toward the object's own up. Foliage catches sky
// light from above; without this a tree reads as a wall.
uniform float normal_up_bias : hint_range(0.0, 1.0) = 0.35;

// The instance's up axis in view space. Taken off the model matrix rather than
// the world's, so an object placed leaning still lights as though its trunk
// were its up.
varying vec3 axis_up;

void vertex() {
	axis_up = normalize((MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV) * albedo_tint;
	ALBEDO = tex.rgb;

	// Sharpen the cutout back to a one-pixel edge before scissoring — see
	// `object_billboard.gdshader`. Mip filtering blurs a branch's alpha ramp
	// over several texels and a hard threshold through it blobs thin twigs.
	ALPHA = clamp((tex.a - alpha_scissor) / max(fwidth(tex.a), 0.0001) + 0.5, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;

	// `cull_disabled` means half of every tree is seen from behind, and a face
	// normal pointing away from the camera lights the back of a leaf. Flip it,
	// then bulge across the quad's width: `u` runs −1..1 with the texture, so
	// `TANGENT * u` is the horizontal offset from the trunk and the square root
	// is what is left of a unit circle there. The vertical axis is deliberately
	// left alone — a tree is tall and round, not spherical.
	vec3 face = FRONT_FACING ? NORMAL : -NORMAL;
	float u = clamp(UV.x, 0.0, 1.0) * 2.0 - 1.0;
	vec3 curved = TANGENT * u + face * sqrt(max(0.0, 1.0 - u * u));
	vec3 n = mix(face, curved, normal_roundness);
	NORMAL = normalize(mix(n, axis_up, normal_up_bias));
}

// ETR clamps every fragment it draws, not just the terrain: `DrawTrees` goes
// through the same fixed-function pipeline as everything else, so a sunlit tree
// reads its own texture and no brighter. Without this the sun that puts a snow
// slope on the ceiling — where the terrain's clamp holds it — bleaches the
// forest instead, which is what it did for one afternoon on 2026-09-10 while
// only `terrain.gdshader` had the clamp. See `etr_illumination.gdshaderinc`.
//
// Plain Lambert, no wrap: the half-Lambert in the terrain shader is a snow
// deviation (there is no subsurface term in this renderer and snow reads as
// plaster without one), and foliage has no such excuse. `normal_up_bias` is
// already doing the "catches light from above" job the wrap would do here.
void light() {
	DIFFUSE_LIGHT += etr_illumination(LIGHT_COLOR / PI,
		max(dot(NORMAL, LIGHT), 0.0), ATTENUATION, vec3(1.0));
}
