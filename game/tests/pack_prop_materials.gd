## Packs the photographed prop materials into the two layered textures
## `object_prop.gdshader` reads. Not a test.
##
##     tools/pack_prop_materials.sh
##
## Each argument is a directory holding one material's `colour.jpg`,
## `normal.jpg` (OpenGL convention, +Y up) and, if it has one, `rough.jpg`, in
## layer order.
## Written as two vertical strips, one 1024² slice per material, imported as
## [Texture2DArray]s (the `.import` sidecars are written here on the first
## pack): `props_albedo.png` — colour, roughness in alpha — and
## `props_normal.png`. Two samplers for every material, where one per map per
## material would be eighteen (the texture-unit trap).
extends SceneTree

const SIZE := 1024
## The normal maps at half the size: relief is read at a few millimetres a
## texel even so, and in Basis Universal a normal map costs more than the
## colour (7.8 MB at 1024², against 7.0 MB for colour and roughness).
const NORMAL_SIZE := 512
const OUT_DIR := "res://assets/materials/"
## For a material that ships no roughness map: weathered wood, matt.
const MISSING_ROUGHNESS := 0.9

func _initialize() -> void:
	var dirs: PackedStringArray = OS.get_cmdline_user_args()
	if dirs.is_empty():
		push_error("pack_prop_materials: no material directories given")
		quit(1)
		return
	var albedo := Image.create(SIZE, SIZE * dirs.size(), false, Image.FORMAT_RGBA8)
	var normal := Image.create(NORMAL_SIZE, NORMAL_SIZE * dirs.size(), false, Image.FORMAT_RGB8)
	for i: int in dirs.size():
		var colour: Image = _load(dirs[i].path_join("colour.jpg"), Image.FORMAT_RGB8)
		var rough: Image = _load(dirs[i].path_join("rough.jpg"), Image.FORMAT_L8) \
			if FileAccess.file_exists(dirs[i].path_join("rough.jpg")) else _flat(MISSING_ROUGHNESS)
		var nor: Image = _load(dirs[i].path_join("normal.jpg"), Image.FORMAT_RGB8, NORMAL_SIZE)
		if colour == null or rough == null or nor == null:
			quit(1)
			return
		for y: int in SIZE:
			for x: int in SIZE:
				var c: Color = colour.get_pixel(x, y)
				c.a = rough.get_pixel(x, y).r
				albedo.set_pixel(x, i * SIZE + y, c)
		normal.blit_rect(nor, Rect2i(0, 0, NORMAL_SIZE, NORMAL_SIZE), Vector2i(0, i * NORMAL_SIZE))
		print("layer %d: %s" % [i, dirs[i]])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for pair: Array in [["props_albedo", albedo], ["props_normal", normal]]:
		var path: String = OUT_DIR + pair[0] + ".png"
		(pair[1] as Image).save_png(path)
		_write_import(path, dirs.size())
	quit(0)

func _load(path: String, format: Image.Format, size: int = SIZE) -> Image:
	var img := Image.load_from_file(path)
	if img == null:
		push_error("pack_prop_materials: cannot read %s" % path)
		return null
	img.convert(format)
	if img.get_size() != Vector2i(size, size):
		img.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return img

func _flat(value: float) -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_L8)
	img.fill(Color(value, value, value))
	return img

## A [Texture2DArray] of [param layers] slices stacked down the image, in
## Basis Universal — one copy, transcoded at load to whatever the GPU takes,
## where VRAM compression ships a desktop and a phone copy side by side (25 MB
## for the web pack, against 14.7) — and mipmapped: the shader reads the last
## mip as each material's mean colour.
## Left alone once written, so a hand-tuned sidecar survives a re-pack.
func _write_import(path: String, layers: int) -> void:
	var sidecar: String = path + ".import"
	if FileAccess.file_exists(sidecar):
		return
	var f := FileAccess.open(sidecar, FileAccess.WRITE)
	f.store_string("""[remap]

importer="2d_array_texture"
type="CompressedTexture2DArray"

[deps]

source_file="%s"

[params]

compress/mode=4
compress/high_quality=false
compress/lossy_quality=0.7
compress/hdr_compression=1
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
slices/horizontal=1
slices/vertical=%d
""" % [path, layers])
	f.close()
