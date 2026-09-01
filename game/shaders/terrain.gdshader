// Terrain splat shader for the Compatibility (WebGL2) renderer.
//
// Everything here is on the Compatibility feature list: no compute, no
// RenderingDevice, no HDR. Up to 8 PBR layers blended from two RGBA8 splat
// textures, plus vertex displacement from the snow trail map and normal
// reconstruction from it, so lighting reads the trench (plan §4.3, §4.4).
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

group_uniforms Splat;
// Two things about these samplers matter and neither is obvious.
//
// `filter_linear` ignores the mip chain even when the texture has one. A splat
// map carries roughly one texel per half metre and is read across the whole
// course, so at the grazing angles a ski slope is mostly made of, unmipped
// sampling scrambles the layer weights from pixel to pixel.
//
// And these are **weights, not colour**: `source_color` sRGB-decodes them,
// which crushes a minority layer's weight by roughly 10× (a 0.12 blend weight
// decodes to 0.013). That silently undid the importer's boundary blur and
// turned the soft blends it authors back into the hard, aliasing-prone edges
// the splat format exists to avoid.
uniform sampler2D splat_0 : filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D splat_1 : filter_linear_mipmap_anisotropic, repeat_disable;
uniform int layer_count : hint_range(1, 8) = 1;

group_uniforms Layers;
uniform sampler2D albedo_0 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D albedo_1 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D albedo_2 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D albedo_3 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D albedo_4 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D albedo_5 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D albedo_6 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D albedo_7 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
// ETR generated terrain UVs at 1/6 world scale; keep that as the default.
uniform float uv_scale = 6.0;
uniform vec4 layer_roughness = vec4(0.85, 0.85, 0.85, 0.85);
// Per-layer "is this snow", driving the wrap term and the sparkle. Read from
// each TerrainLayer rather than guessed from the layer index: the splat's
// second channel is whatever terrain the course happens to use next, which on
// bunny_hill is rock — and rock has no business getting snow's subsurface wrap
// or its glint. Four layers, matching layer_roughness; courses using layers
// 4-7 fall back to "not snow" until both tables are widened.
uniform vec4 layer_snowness = vec4(1.0, 0.0, 0.0, 0.0);

group_uniforms Course;
// World extent of the course in metres, for splat UV lookup.
uniform vec2 world_size = vec2(90.0, 520.0);

group_uniforms Snow;
// Trail map: R = trench depth (m), G = compaction, B = age, A = wind drift.
uniform sampler2D trail_map : filter_linear, repeat_disable;
uniform bool trail_enabled = false;
// World-space window the trail map covers, and its size in metres.
uniform vec2 trail_origin = vec2(0.0);
uniform float trail_extent = 64.0;
uniform float trail_depth_scale = 1.0;
// Height of the ridge thrown up at the trench edges, in metres. The ridge is
// what actually sells a carve — a trench alone reads as a texture.
uniform float ridge_height = 0.05;
// How hard the trench gradient tilts the terrain normal. This is a
// perturbation of the real normal, so 0.0 is "trench invisible to lighting"
// and 1.0 is "geometrically correct for the depth field".
//
// Geometrically correct is not what the original looks like. The trail map is
// 6.25 cm per texel and the trench walls fall most of `max_depth` across one or
// two of them, so an exact normal stands the wall nearly vertical, it catches
// no sun, and the track reads as a black canyon rather than a groove in snow.
// ETR drew track marks as a decal barely a shade off the snow around them; half
// strength keeps the trench legible as depth without that.
uniform float trail_normal_strength : hint_range(0.0, 2.0) = 0.5;

group_uniforms Snow_Shading;
uniform sampler2D sparkle_noise : filter_linear_mipmap, repeat_enable;
// Wrap lighting fakes the subsurface scattering that snow really does. No SSS
// under Compatibility, and snow is the worst possible subject to lose it on.
// Kept small: it lifts the shaded side of every slope, and the original had no
// such term at all — a wide wrap on top of the fitted ambient washes the hill
// out until it has no form left.
uniform float wrap_amount : hint_range(0.0, 1.0) = 0.2;
uniform float sparkle_strength : hint_range(0.0, 2.0) = 0.6;
// Godot's `SPECULAR`, which remaps to F0 as 0.16 * s * s: 0.5 is the default and
// means F0 = 0.04, the usual dielectric value, and snow's real F0 of about 0.02
// would be s = 0.35. This sits below even that, because the original has no
// specular term on terrain at all — ETR's `light.lst` gives light 0 a black
// `[spec]` — and every unit of it lands on a surface that is already close to
// the ceiling. Snow that reads as snow is diffuse; the glint below is the part
// worth keeping.
uniform float specular_f0 : hint_range(0.0, 1.0) = 0.15;
uniform float specular_strength : hint_range(0.0, 2.0) = 0.35;
// Metres per repeat of the noise. This used to *multiply* the world position
// by 40, i.e. ask for 40 repeats per metre — well under one texel after any
// minification, so the noise mipped to flat grey everywhere but arm's length
// from the camera, which is exactly where it then aliased.
uniform float sparkle_scale = 0.5;
// Glints are sub-pixel at distance and average out; fading them explicitly is
// cheaper and steadier than letting the mip chain do it by accident.
uniform float sparkle_fade_distance = 45.0;

varying vec3 world_pos;
varying vec2 splat_uv;
varying float snow_mask;
// Sparkle intensity, computed in fragment and consumed by the custom light
// function — SPECULAR is write-only there.
varying float sparkle;

vec2 trail_uv_of(vec2 world_xz) {
	return (world_xz - trail_origin) / trail_extent;
}

// Trench depth in metres at a world position, zero outside the window.
float trail_depth(vec2 world_xz) {
	vec2 uv = trail_uv_of(world_xz);
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return 0.0;
	}
	vec4 t = texture(trail_map, uv);
	// Displace down inside the trench, and up into a ridge just outside it:
	// the gradient of the depth field is where the ploughed snow piles up.
	return t.r * trail_depth_scale;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	splat_uv = vec2(world_pos.x / world_size.x, -world_pos.z / world_size.y);

	if (trail_enabled) {
		float texel = trail_extent / 1024.0;
		float d = trail_depth(world_pos.xz);
		// Ridge term: the Laplacian of the depth field is positive at the
		// trench lip, so snow rises exactly where it was pushed aside.
		float dl = trail_depth(world_pos.xz - vec2(texel * 2.0, 0.0));
		float dr = trail_depth(world_pos.xz + vec2(texel * 2.0, 0.0));
		float db = trail_depth(world_pos.xz - vec2(0.0, texel * 2.0));
		float dt = trail_depth(world_pos.xz + vec2(0.0, texel * 2.0));
		float laplacian = (dl + dr + db + dt) * 0.25 - d;
		VERTEX.y -= d;
		VERTEX.y += max(0.0, laplacian) * ridge_height / max(texel, 0.001);
	}
}

vec4 sample_layers(vec2 uv, vec4 w0, vec4 w1) {
	vec4 c = texture(albedo_0, uv) * w0.r;
	if (layer_count > 1) { c += texture(albedo_1, uv) * w0.g; }
	if (layer_count > 2) { c += texture(albedo_2, uv) * w0.b; }
	if (layer_count > 3) { c += texture(albedo_3, uv) * w0.a; }
	if (layer_count > 4) { c += texture(albedo_4, uv) * w1.r; }
	if (layer_count > 5) { c += texture(albedo_5, uv) * w1.g; }
	if (layer_count > 6) { c += texture(albedo_6, uv) * w1.b; }
	if (layer_count > 7) { c += texture(albedo_7, uv) * w1.a; }
	return c;
}

void fragment() {
	vec4 w0 = texture(splat_0, splat_uv);
	vec4 w1 = layer_count > 4 ? texture(splat_1, splat_uv) : vec4(0.0);
	float total = dot(w0, vec4(1.0)) + dot(w1, vec4(1.0));
	w0 /= max(total, 0.001);
	w1 /= max(total, 0.001);

	vec2 uv = world_pos.xz / uv_scale;
	ALBEDO = sample_layers(uv, w0, w1).rgb;
	ROUGHNESS = dot(layer_roughness, w0);
	METALLIC = 0.0;

	snow_mask = clamp(dot(layer_snowness, w0), 0.0, 1.0);

	if (trail_enabled) {
		// Tilt the normal by the trench gradient so the trail lights correctly
		// without re-tessellating the mesh.
		//
		// This has to be a *perturbation* of the geometric normal, never a
		// replacement. The trail map is empty on undisturbed snow and outside
		// its own 64 m window, so a reconstructed normal is (0, 1, 0) almost
		// everywhere: mixing NORMAL toward it flattened the entire hill into a
		// fake horizontal plane and left the trench as the only shaded detail
		// on the course — relief appearing only within a short radius of the
		// player. Adding the gradient instead is a no-op where there is no
		// trail, which is what it should be.
		float texel = trail_extent / 1024.0;
		float dx = trail_depth(world_pos.xz + vec2(texel, 0.0))
			- trail_depth(world_pos.xz - vec2(texel, 0.0));
		float dz = trail_depth(world_pos.xz + vec2(0.0, texel))
			- trail_depth(world_pos.xz - vec2(0.0, texel));
		// The vertex stage displaces by -depth, so the slope it adds to the
		// surface is +d(depth)/dxz on the normal's horizontal axes.
		vec3 slope = vec3(dx, 0.0, dz) / (2.0 * texel);
		vec3 n_world = mat3(INV_VIEW_MATRIX) * NORMAL + slope * trail_normal_strength;
		NORMAL = normalize(mat3(VIEW_MATRIX) * normalize(n_world));

		// Freshly disturbed snow is brighter and rougher than the packed track.
		// Guard the window the same way trail_depth() does: the sampler clamps
		// to edge, so an unguarded read smears the border texel of the window
		// across every chunk on the course.
		vec2 tuv = trail_uv_of(world_pos.xz);
		float inside = float(all(greaterThanEqual(tuv, vec2(0.0)))
			&& all(lessThanEqual(tuv, vec2(1.0))));
		float packed = texture(trail_map, clamp(tuv, vec2(0.0), vec2(1.0))).g * inside;
		ALBEDO = mix(ALBEDO, ALBEDO * 0.92, packed * snow_mask);
		ROUGHNESS = mix(ROUGHNESS, ROUGHNESS * 0.75, packed * snow_mask);
	}

	// View-dependent glint. Cheap stand-in for the specular sparkle of real
	// snow crystals; without it, an LDR snow field reads as flat white paper.
	float sp = texture(sparkle_noise, world_pos.xz / max(sparkle_scale, 0.001)).r;
	sp = pow(clamp(sp, 0.0, 1.0), 24.0);
	float sparkle_fade = 1.0 - smoothstep(0.0, sparkle_fade_distance, length(VERTEX));
	sparkle = sp * sparkle_strength * snow_mask * sparkle_fade;
	SPECULAR = specular_f0 + sparkle;
}

void light() {
	// Half-Lambert wrap: light bleeds around the terminator the way it does in
	// a translucent medium. Not physical, but it is what stops snow reading as
	// plaster in a renderer with no subsurface scattering.
	float ndl = dot(NORMAL, LIGHT);
	float wrapped = clamp((ndl + wrap_amount) / (1.0 + wrap_amount), 0.0, 1.0);
	float shaped = mix(max(ndl, 0.0), wrapped * wrapped, snow_mask);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * shaped / PI;

	// LIGHT_COLOR arrives premultiplied by PI, because Godot folds the 1/PI of
	// the diffuse BRDF into it. Both terms divide it back out so they stay in
	// the same units as each other and as `sun_energy`.
	vec3 h = normalize(LIGHT + VIEW);
	float ndh = max(dot(NORMAL, h), 0.0);
	float gloss = mix(16.0, 90.0, 1.0 - ROUGHNESS);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * pow(ndh, gloss)
		* (specular_f0 + sparkle) * specular_strength / PI;
}
