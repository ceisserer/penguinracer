// Terrain splat shader for the Compatibility (WebGL2) renderer.
//
// Everything here is on the Compatibility feature list: no compute, no
// RenderingDevice, no HDR. Up to 8 PBR layers blended from two RGBA8 splat
// textures, plus vertex displacement from the snow trail map and normal
// reconstruction from it, so lighting reads the trench (plan §4.3, §4.4).
//
// Snow and ice then get the two things a splat-blended albedo cannot give them:
// procedural micro-relief, because a 1 m/texel albedo photograph of snow has no
// form at arm's length; and a view-dependent term each — a twinkling crystal
// glint for snow, a Fresnel sky reflection for ice — because both materials are
// defined by how they change when you move, and a static texture never does.
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
// Per-layer tables, split low/high because GLSL ES 3.0 has no `float[8]`
// uniform worth relying on and a pair of vec4s indexes for free. `_hi` covers
// layers 4-7; courses that use them used to fall off the end of these tables
// and get "rough, not snow, not ice" — visible on the eight-layer courses as a
// slope that stops sparkling halfway across a blend.
uniform vec4 layer_roughness = vec4(0.85);
uniform vec4 layer_roughness_hi = vec4(0.85);
// Per-layer "is this snow", driving the wrap term, the micro-relief and the
// glint. Read from each TerrainLayer rather than guessed from the layer index:
// the splat's second channel is whatever terrain the course happens to use
// next, which on bunny_hill is rock — and rock has no business getting snow's
// subsurface wrap or its glint.
uniform vec4 layer_snowness = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 layer_snowness_hi = vec4(0.0);
// Per-layer "is this ice" — `TerrainLayer.is_ice()`, i.e. ETR's `[shiny]`
// widened by the friction test that catches the two ice terrains the data
// forgot to mark. Ice is not snow with a lower roughness: it is the one
// terrain in the game that reflects its surroundings.
uniform vec4 layer_iceness = vec4(0.0);
uniform vec4 layer_iceness_hi = vec4(0.0);

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
// Ambient occlusion inside the trench. A groove in snow is shaded by its own
// walls, and that self-shadowing is the whole reason a real track reads as
// carved rather than painted. Applied to the ambient term only
// (`AO_LIGHT_AFFECT` 0): the sun is a single direction and already handled by
// the tilted normal, so occluding it as well would double-count.
uniform float trench_ao : hint_range(0.0, 1.0) = 0.25;
// The snow ploughed out of the trench lands on its lip, and freshly turned snow
// is brighter than the wind-crusted surface it came from — the pale line either
// side of a ski track. Multiplies albedo on the ridge the vertex stage raises,
// so the two always agree about where the ridge is.
uniform float ridge_brighten : hint_range(0.0, 1.0) = 0.18;

group_uniforms Surface_Detail;
// Procedural micro-relief. RG = the gradient of a tiling height field, packed
// around 0.5 and scaled by `detail_gradient_scale`; B = the height itself.
//
// Storing the gradient rather than the height is what makes two octaves
// affordable: a normal reconstructed from a heightmap costs three taps per
// octave and this costs one. It also means the perturbation is exact at every
// mip level instead of collapsing as neighbouring taps converge.
//
// The height field is normalised to 0..1; `detail_slope` therefore returns the
// slope of a **unit-amplitude** field, which the caller scales by a relief in
// metres.
uniform sampler2D detail_map : filter_linear_mipmap, repeat_enable;
uniform float detail_gradient_scale = 1.0;
// Metres per repeat. Fine is the wind crust you see at the ski tips; coarse is
// the drift structure that gives a whole slope its shape.
uniform float detail_scale_fine = 1.1;
uniform float detail_scale_coarse = 9.0;
// Relief amplitude, **in metres**. The baked height field is normalised to
// 0..1 and `detail_gradient_scale` carries its per-UV gradient, so the world
// slope is (gradient / metres-per-repeat) * relief and these read as what they
// are: 8 mm of wind crust and 5 cm of drift. Writing them as a unitless 0..1
// strength is how the first version of this ended up tilting the near field by
// 60 degrees — the peak per-UV gradient is around 12, not around 1.
uniform float detail_relief_fine = 0.05;
uniform float detail_relief_coarse = 0.35;
// The fine octave is sub-pixel well before the coarse one is, and letting the
// mip chain retire it is not the same as fading it: a mipped gradient averages
// toward zero slope, which is right, but it does so while the term is still
// large enough to alias. Fade explicitly, and fade fine first.
uniform float detail_fade_fine = 22.0;
uniform float detail_fade_coarse = 90.0;
// Sastrugi. Wind does not sculpt snow isotropically — it draws the coarse
// octave out into ridges running downwind, which is most of what distinguishes
// a snowfield from a dune field. Stretching the UV along the wind axis and
// carrying the stretch through the chain rule gives that for one normalize.
uniform vec2 wind_direction = vec2(0.35, 0.94);
uniform float wind_stretch : hint_range(1.0, 8.0) = 3.4;
// Ice has micro-relief too — refrozen ripples and skate scars — but far
// flatter, and only the fine octave: inheriting snow's wind drifts would stop
// it reading as a hard surface.
uniform float ice_relief_scale : hint_range(0.0, 1.0) = 0.25;

group_uniforms Snow_Shading;
// White noise, one facet direction per texel. Mipmapped on purpose: the mip
// chain averages facets toward the flat normal with distance, which is what
// a field of sub-pixel crystals actually does.
uniform sampler2D sparkle_noise : filter_linear_mipmap, repeat_enable;
// Wrap lighting fakes the subsurface scattering that snow really does. No SSS
// under Compatibility, and snow is the worst possible subject to lose it on.
// Kept small: it lifts the shaded side of every slope, and the original had no
// such term at all — a wide wrap on top of the fitted ambient washes the hill
// out until it has no form left.
uniform float wrap_amount : hint_range(0.0, 1.0) = 0.2;
uniform float sparkle_strength : hint_range(0.0, 2.0) = 0.6;
// How far a crystal facet tilts away from the surface. This is what makes the
// glint *twinkle*: a facet only fires while it happens to bisect eye and sun,
// so moving the camera lights a different scatter of them every frame. The old
// term was a static `pow(noise, 24)` painted into SPECULAR — it survived being
// looked at but not being ridden past, because it never changed.
uniform float sparkle_spread : hint_range(0.0, 1.0) = 0.45;
// Facet lobe exponent. Sharp enough that individual crystals wink rather than
// smear into a sheen.
uniform float sparkle_sharpness : hint_range(16.0, 512.0) = 220.0;
// Godot's `SPECULAR`, which remaps to F0 as 0.16 * s * s: 0.5 is the default and
// means F0 = 0.04, the usual dielectric value, and snow's real F0 of about 0.02
// would be s = 0.35. This sits below even that, because the original has no
// specular term on terrain at all — ETR's `light.lst` gives light 0 a black
// `[spec]` — and every unit of it lands on a surface that is already close to
// the ceiling. Snow that reads as snow is diffuse; the glint above is the part
// worth keeping.
uniform float specular_f0 : hint_range(0.0, 1.0) = 0.15;
uniform float specular_strength : hint_range(0.0, 2.0) = 0.35;
// Metres per repeat of the noise. This used to *multiply* the world position
// by 40, i.e. ask for 40 repeats per metre — well under one texel after any
// minification, so the noise mipped to flat grey everywhere but arm's length
// from the camera, which is exactly where it then aliased. Two metres over a
// 256-texel map puts a crystal at about 8 mm, which is a pixel or so at the
// near edge of the chase camera and safely gone by the fade distance.
uniform float sparkle_scale = 2.0;
// Glints are sub-pixel at distance and average out; fading them explicitly is
// cheaper and steadier than letting the mip chain do it by accident.
uniform float sparkle_fade_distance = 45.0;

group_uniforms Ice_Shading;
// The sky the ice reflects, as the two colours `EnvironmentPreset` already
// derives from the migrated skybox faces. Sampling the skybox itself would be
// the honest thing and is not available here: `Sky` is not bound to a spatial
// shader in Compatibility, and the environment reflection that would do it is
// deliberately switched off (it was pinning the snow at white — PROGRESS §11).
// A two-colour vertical ramp is enough, because what sells ice is not the
// content of the reflection but that it is Fresnel-weighted and moves.
uniform vec3 sky_zenith : source_color = vec3(0.24, 0.39, 0.75);
uniform vec3 sky_horizon : source_color = vec3(0.75, 0.82, 0.92);
uniform float ice_reflection : hint_range(0.0, 2.0) = 1.0;
// Ice's real F0 is about 0.018, the same dielectric ballpark as snow. The
// difference is roughness: snow scatters the lobe away and ice keeps it, so ice
// gets the sun as a hard highlight rather than a wash.
uniform float ice_roughness : hint_range(0.0, 1.0) = 0.12;
uniform float ice_specular_strength : hint_range(0.0, 4.0) = 1.6;
uniform float ice_gloss : hint_range(16.0, 1024.0) = 300.0;
// Ice is darker than snow, and it has to be, because everything that makes it
// read as ice is additive: a Schlick term at the 65 degree incidence a chase
// camera sits at is only about 0.09, and 0.09 of sky laid over an albedo that
// is already three-quarters of the way to white is four levels nobody sees.
// Lowering the diffuse gives the reflection and the sun glare somewhere to
// land, which is also the physics — a smooth dielectric reflects the light that
// a snowpack would have scattered back at you.
//
// DEVIATION: ETR has no such term; its ice terrains differ from its snow only
// by texture and by `[friction]`.
uniform float ice_albedo : hint_range(0.0, 1.0) = 0.82;

varying vec3 world_pos;
varying vec2 splat_uv;
varying float snow_mask;
varying float ice_mask;
// Schlick weight for the ice terms, shared by the sky reflection in fragment
// and the sun glare in light().
varying float ice_fresnel;
// The lip of the trench, from the vertex stage that raises it — geometry-rate
// on purpose, so the highlight and the displacement cannot disagree.
varying float ridge_lip;
// Glint intensity and the view-space facet direction it fires along. Both are
// computed in fragment and consumed by the custom light function, where
// SPECULAR is write-only and there is no texture sampling worth doing.
varying float sparkle;
varying vec3 glint_normal;

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

	ridge_lip = 0.0;
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
		float rise = max(0.0, laplacian) * ridge_height / max(texel, 0.001);
		VERTEX.y -= d;
		VERTEX.y += rise;
		// Normalised against the ridge height so the shading term is a 0..1
		// "how much fresh snow is piled here" rather than a distance.
		ridge_lip = clamp(rise / max(ridge_height, 1e-4), 0.0, 1.0);
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

// One octave of micro-relief, as a world-space slope (dh/dx, 0, dh/dz).
//
// `stretch` draws the pattern out along `wind_direction`. The chain rule has to
// carry that stretch, or the ridges light as though they ran the other way:
// with u = dot(p, f) / (m * stretch) and v = dot(p, s) / m, the world gradient
// is dh/du * du/dp + dh/dv * dv/dp, and du/dp is the stretched axis.
vec3 detail_slope(vec2 p, float metres, float stretch) {
	vec2 f = normalize(wind_direction);
	vec2 s = vec2(-f.y, f.x);
	float du = 1.0 / max(metres * stretch, 0.01);
	float dv = 1.0 / max(metres, 0.01);
	vec2 g = (texture(detail_map, vec2(dot(p, f) * du, dot(p, s) * dv)).rg - 0.5)
		* 2.0 * detail_gradient_scale;
	vec2 world_g = g.x * f * du + g.y * s * dv;
	return vec3(world_g.x, 0.0, world_g.y);
}

void fragment() {
	vec4 w0 = texture(splat_0, splat_uv);
	vec4 w1 = layer_count > 4 ? texture(splat_1, splat_uv) : vec4(0.0);
	float total = dot(w0, vec4(1.0)) + dot(w1, vec4(1.0));
	w0 /= max(total, 0.001);
	w1 /= max(total, 0.001);

	vec2 uv = world_pos.xz / uv_scale;
	ALBEDO = sample_layers(uv, w0, w1).rgb;
	METALLIC = 0.0;

	snow_mask = clamp(dot(layer_snowness, w0) + dot(layer_snowness_hi, w1), 0.0, 1.0);
	ice_mask = clamp(dot(layer_iceness, w0) + dot(layer_iceness_hi, w1), 0.0, 1.0);
	float rough = dot(layer_roughness, w0) + dot(layer_roughness_hi, w1);
	ROUGHNESS = mix(rough, ice_roughness, ice_mask);

	float view_dist = length(VERTEX);

	// Everything below perturbs one world-space normal and normalizes once.
	//
	// Perturbing is the whole point and it is not interchangeable with mixing.
	// Both the trail map and the detail field are *additions* to the geometric
	// normal: a reconstructed normal is (0, 1, 0) wherever the field is flat,
	// which for the trail map is almost everywhere, and mixing toward it
	// flattened the entire hill into a fake horizontal plane the first time
	// this was written.
	vec3 n_world = mat3(INV_VIEW_MATRIX) * NORMAL;

	// --- procedural micro-relief -------------------------------------------
	// A splat-blended photograph of snow carries no relief at all: it is one
	// texel per metre of terrain, so from the chase camera the near field is a
	// flat pale sheet and the only shading variation on the course comes from
	// the heightmap. Two octaves of tiling gradient noise put the crust and the
	// drift structure back, at two taps and no extra geometry.
	float fine_w = snow_mask + ice_mask * ice_relief_scale;
	if (fine_w > 0.0) {
		float fade_fine = 1.0 - smoothstep(0.0, detail_fade_fine, view_dist);
		float fade_coarse = 1.0 - smoothstep(0.0, detail_fade_coarse, view_dist);
		// Both take the fine octave; only snow takes the wind-stretched coarse
		// one, because ice has skate scars, not drifts.
		vec3 slope = detail_slope(world_pos.xz, detail_scale_fine, 1.0)
				* (detail_relief_fine * fade_fine * fine_w)
			+ detail_slope(world_pos.xz, detail_scale_coarse, wind_stretch)
				* (detail_relief_coarse * fade_coarse * snow_mask);
		// A height field h tilts the normal by (-dh/dx, 0, -dh/dz).
		n_world -= slope;
	}

	if (trail_enabled) {
		// Tilt the normal by the trench gradient so the trail lights correctly
		// without re-tessellating the mesh.
		float texel = trail_extent / 1024.0;
		float dx = trail_depth(world_pos.xz + vec2(texel, 0.0))
			- trail_depth(world_pos.xz - vec2(texel, 0.0));
		float dz = trail_depth(world_pos.xz + vec2(0.0, texel))
			- trail_depth(world_pos.xz - vec2(0.0, texel));
		// The vertex stage displaces by -depth, so the slope it adds to the
		// surface is +d(depth)/dxz on the normal's horizontal axes.
		n_world += vec3(dx, 0.0, dz) / (2.0 * texel) * trail_normal_strength;

		// Freshly disturbed snow is brighter and rougher than the packed track.
		// Guard the window the same way trail_depth() does: the sampler clamps
		// to edge, so an unguarded read smears the border texel of the window
		// across every chunk on the course.
		vec2 tuv = trail_uv_of(world_pos.xz);
		float inside = float(all(greaterThanEqual(tuv, vec2(0.0)))
			&& all(lessThanEqual(tuv, vec2(1.0))));
		vec4 trail = texture(trail_map, clamp(tuv, vec2(0.0), vec2(1.0)));
		float packed = trail.g * inside;
		float depth_n = clamp(trail.r * inside, 0.0, 1.0);
		ALBEDO = mix(ALBEDO, ALBEDO * 0.92, packed * snow_mask);
		ROUGHNESS = mix(ROUGHNESS, ROUGHNESS * 0.75, packed * snow_mask);
		// Snow on the lip was turned over a moment ago; it has not had time to
		// crust or to pack.
		ALBEDO *= 1.0 + ridge_lip * ridge_brighten * snow_mask;
		// The trench shades itself. Ambient only — see `trench_ao`.
		AO = 1.0 - depth_n * trench_ao * snow_mask;
		AO_LIGHT_AFFECT = 0.0;
	}

	NORMAL = normalize(mat3(VIEW_MATRIX) * normalize(n_world));

	// --- crystal glint ------------------------------------------------------
	// Snow is not a rough white dielectric; it is a heap of specular facets
	// pointed in every direction, and the reason a real snowfield does not read
	// as paper is that a different scatter of them catches the sun every time
	// you move. Reproduce that literally: give each noise texel a facet normal
	// and let the light function ask whether it happens to bisect eye and sun.
	// The mip chain then averages the facets back toward the surface normal
	// with distance, which is exactly what a field of sub-pixel crystals does.
	vec3 facet = texture(sparkle_noise, world_pos.xz / max(sparkle_scale, 0.001)).rgb
		* 2.0 - 1.0;
	// Perturb the surface normal isotropically rather than around world up: a
	// crystal on a 30 degree slope is not more likely to point at the sky, and
	// biasing it that way makes every slope glint hardest at the same angle.
	//
	// `facet` is deliberately not normalized first. White noise mips toward
	// middle grey, which decodes to the zero vector, and `normalize` of that is
	// a NaN that survives being multiplied by a zero distance fade and poisons
	// SPECULAR_LIGHT. Adding it raw degenerates the other way: as the facets
	// average out with distance the glint normal slides back to the surface
	// normal, which is what a field of sub-pixel crystals should do anyway.
	glint_normal = normalize(NORMAL
		+ mat3(VIEW_MATRIX) * facet * sparkle_spread);
	float sparkle_fade = 1.0 - smoothstep(0.0, sparkle_fade_distance, view_dist);
	sparkle = sparkle_strength * snow_mask * sparkle_fade;

	// --- ice reflection -----------------------------------------------------
	// Fresnel against the perturbed normal, so the ripples above shear the
	// reflection the way a frozen lake does. This is an unshaded addition —
	// the sky reaches ice regardless of where the sun is — so it goes through
	// EMISSION, the one additive channel a custom light() leaves alone.
	ice_fresnel = 0.0;
	if (ice_mask > 0.0) {
		float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
		// Schlick, with ice's F0 of about 0.018. Nearly all of the effect is in
		// the grazing rise, which is the angle a chase camera lives at.
		ice_fresnel = 0.018 + 0.982 * pow(1.0 - ndv, 5.0);
		vec3 refl = mat3(INV_VIEW_MATRIX) * reflect(-VIEW, NORMAL);
		vec3 sky = mix(sky_horizon, sky_zenith, smoothstep(0.0, 0.6, refl.y));
		EMISSION += sky * ice_fresnel * ice_reflection * ice_mask;
		ALBEDO = mix(ALBEDO, ALBEDO * ice_albedo, ice_mask);
	}

	SPECULAR = specular_f0;
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
	// Snow keeps ETR's near-absent terrain specular — `light.lst` gives its
	// terrain light a black `[spec]`, and the surface is already near the
	// ceiling. Ice gets a real mirror lobe instead: tight, and Fresnel-weighted
	// by the same term as the sky reflection, so the sun's image brightens as
	// the slope turns away exactly as the sky's does.
	float gloss = mix(mix(16.0, 90.0, 1.0 - ROUGHNESS), ice_gloss, ice_mask);
	float strength = mix(specular_f0 * specular_strength,
		ice_specular_strength * ice_fresnel, ice_mask);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * pow(ndh, gloss) * strength / PI;

	// The facet lobe, separately: it needs its own normal and a far sharper
	// exponent than the surface, and folding it into the term above would only
	// widen it back into the sheen it exists to avoid.
	if (sparkle > 0.0) {
		float fdh = max(dot(glint_normal, h), 0.0);
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION
			* pow(fdh, sparkle_sharpness) * sparkle / PI;
	}
}
