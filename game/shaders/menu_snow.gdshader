// [MenuSnow]'s flakes: one quadrant of the puff atlas per instance, picked by
// INSTANCE_CUSTOM.xy (0 or 0.5 each) — ETR's `setTextureRect` over
// `snowparticles.png`, as a MultiMesh reads it.
shader_type canvas_item;

void vertex() {
	UV = UV * 0.5 + INSTANCE_CUSTOM.xy;
}
