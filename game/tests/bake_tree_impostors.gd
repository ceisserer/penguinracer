## Bakes the tree impostors' two atlases each, from LOD 0 of [ConiferMesh] and
## [BareTreeMesh]. Not a test.
##
##     tools/bake_tree_impostors.sh [conifer|bare]
##
## Needs a real renderer — `--headless` draws nothing — which is what the
## wrapper arranges. Re-run for a species whenever its mesh changes shape; the
## atlases are committed, so the game and the web build never bake anything.
## Both species share [ConiferMesh]'s grid, tile, bounding sphere and view
## basis, which is what lets them share `conifer_impostor.gdshader`.
##
## All 64 views are drawn in one frame: an orthographic camera looks down −Z at
## a grid of copies of the tree, each turned by the inverse of
## [method ConiferMesh.view_basis] for its view direction, so the camera sees
## that copy exactly as a viewer along that direction would. The card the
## impostor shader draws is built from the same basis, so a frame and the card
## showing it line up.
extends SceneTree

const BAKE_SHADER := "res://shaders/conifer_bake.gdshader"
const TREE_TEXTURE := "res://assets/objects/snowy_tree1.png"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var which: String = "all"
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty():
		which = args[0]
	var ok: bool = true
	if which == "all" or which == "conifer":
		ok = await _bake(Forest.Species.CONIFER) and ok
	if which == "all" or which == "bare":
		ok = await _bake(Forest.Species.BARE) and ok
	quit(0 if ok else 1)

## The bare tree is drawn at twice the atlas size and averaged down, since its
## limbs are a pixel or two wide in a tile and aliased they break into dashes.
## The conifer is a solid silhouette and is drawn at size, as it always was.
const BARE_SUPERSAMPLE := 2

func _bake(species: Forest.Species) -> bool:
	var bare: bool = species == Forest.Species.BARE
	var ss: int = BARE_SUPERSAMPLE if bare else 1
	var grid: int = ConiferMesh.ATLAS_GRID
	var size: int = grid * ConiferMesh.ATLAS_TILE * ss
	var r: float = ConiferMesh.IMPOSTOR_RADIUS

	var vp := SubViewport.new()
	vp.size = Vector2i(size, size)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	# Nothing between ALBEDO and the target: no fog, a linear tone map at unit
	# exposure, no glow.
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = float(grid) * 2.0 * r
	cam.near = 0.1
	cam.far = 20.0
	cam.position = Vector3(0.0, 0.0, 10.0)
	vp.add_child(cam)
	cam.make_current()

	var mat := ShaderMaterial.new()
	mat.shader = load(BAKE_SHADER)
	mat.set_shader_parameter("albedo_texture",
		BareTreeMesh.texture() if bare else load(TREE_TEXTURE))
	if bare:
		# A tree of the bare type's typical 4 m, where the impostor takes over.
		mat.set_shader_parameter("min_radius",
			Forest.BARE_MIN_RADIUS_PER_METRE * Forest.LOD_ENDS[-1] / 4.0)
	var tree: ArrayMesh = Forest.level_mesh(species, Forest.impostor_source_level(species))
	for j: int in grid:
		for i: int in grid:
			var d: Vector3 = ConiferMesh.frame_direction(i, j)
			var turn: Basis = ConiferMesh.view_basis(d).transposed()
			var tile_centre := Vector3((float(i) + 0.5) * 2.0 * r - float(grid) * r,
				float(grid) * r - (float(j) + 0.5) * 2.0 * r, 0.0)
			var mi := MeshInstance3D.new()
			mi.mesh = tree
			mi.material_override = mat
			mi.transform = Transform3D(turn, tile_centre) \
				* Transform3D(Basis(), -ConiferMesh.IMPOSTOR_CENTER)
			vp.add_child(mi)

	var ok: bool = true
	for mode: int in 2:
		mat.set_shader_parameter("bake_mode", mode)
		for f: int in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		if ss > 1:
			img = _downsample(img, ss)
		var path: String = Forest.atlases(species)[mode]
		var out: String = ProjectSettings.globalize_path(path)
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var err: Error = img.save_png(out)
		print("baked %s (%dx%d): %s" % [path, img.get_width(), img.get_height(), error_string(err)])
		ok = ok and err == OK
		if mode == 1 and not bare:
			# The tile nearest the pole looks mostly down on whorl tops, so its
			# middle should pack to roughly +Y: (~0.5, >0.8, ~0.5). A green
			# channel near 1 with red and blue near 0.2 means the target started
			# encoding sRGB, and `conifer_bake.gdshader` has to follow.
			var probe: Color = _probe_pole(img, grid)
			print("pole tile normal, packed: %s (want ~0.5, >0.8, ~0.5)" % probe)
	vp.queue_free()
	await process_frame
	return ok

## [param img] shrunk by [param factor], each texel the alpha-weighted mean of
## its block — so the transparent background's black does not bleed into a
## limb's edge, as a plain resize would — and alpha the plain mean, which is
## the coverage.
func _downsample(img: Image, factor: int) -> Image:
	var w: int = img.get_width() / factor
	var h: int = img.get_height() / factor
	var out := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var n: float = float(factor * factor)
	for y: int in h:
		for x: int in w:
			var rgb := Color(0, 0, 0, 0)
			var a: float = 0.0
			for dy: int in factor:
				for dx: int in factor:
					var p: Color = img.get_pixel(x * factor + dx, y * factor + dy)
					rgb += Color(p.r * p.a, p.g * p.a, p.b * p.a, 0.0)
					a += p.a
			if a > 0.0:
				out.set_pixel(x, y, Color(rgb.r / a, rgb.g / a, rgb.b / a, a / n))
	return out

## The average opaque colour in the middle of the tile nearest the pole.
func _probe_pole(img: Image, grid: int) -> Color:
	var tile: int = ConiferMesh.ATLAS_TILE
	var ij: int = (grid - 1) / 2
	var x0: int = ij * tile + tile / 2 - 8
	var y0: int = ij * tile + tile / 2 - 8
	var sum := Color(0, 0, 0, 0)
	var n: int = 0
	for y: int in range(y0, y0 + 16):
		for x: int in range(x0, x0 + 16):
			var p: Color = img.get_pixel(x, y)
			if p.a > 0.5:
				sum += p
				n += 1
	return sum / float(maxi(n, 1))
