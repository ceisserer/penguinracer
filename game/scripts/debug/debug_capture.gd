## Development helper: capture a screenshot after N frames and quit.
##
##     godot --path game -- --capture=/tmp/shot.png --capture-frames=180
##
## `?capture=` and `?capture-frames=` say the same thing in a browser; see
## [LaunchArgs].
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
	var args: LaunchArgs = LaunchArgs.current()
	_path = args.capture_path
	_frames = args.capture_frames
	_armed = not _path.is_empty()
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
	# Through the audio director rather than straight to the tree, so a capture
	# run that was not given `--no-audio` still exits without a leak warning
	# printed over the screenshot. See `AudioDirector.quit_game`.
	Audio.quit_game(0)
