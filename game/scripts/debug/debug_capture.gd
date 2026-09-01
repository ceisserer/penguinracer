## Development helper: capture a screenshot after N frames and quit.
##
##     godot --path game -- --capture=/tmp/shot.png --capture-frames=180
##
## Inert unless `--capture=` is passed, so it costs nothing in a shipped build.
## Used to verify the renderer from a headless container and, with the same
## flags, from a browser-driven web export.
extends Node

var _path: String = ""
var _frames: int = 120
var _count: int = 0
var _armed: bool = false

func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="):
			_path = arg.trim_prefix("--capture=")
			_armed = true
		elif arg.begins_with("--capture-frames="):
			_frames = arg.trim_prefix("--capture-frames=").to_int()
	set_process(_armed)

func _process(_delta: float) -> void:
	_count += 1
	if _count < _frames:
		return
	set_process(false)
	# Wait one more draw so the frame we grab is fully composited.
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(_path)
	print("captured %s after %d frames" % [_path, _count])
	get_tree().quit(0)
