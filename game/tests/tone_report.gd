## Per-region tone statistics over a capture, for fitting a look against a
## reference frame.
##
##     godot --headless --path game --script res://tests/tone_report.gd -- \
##         <png> <exposure> <name>:<x0>,<y0>,<x1>,<y1> ...
##
## Prints, per channel: the 5th percentile, median, 95th percentile, mean, what
## fraction of the region is clipped, and the mean of the pre-tonemap linear
## value implied by the capture's exposure. Every one of those matters when the
## surface under test is snow: the mean says where the level is, the percentiles
## say whether the *shape* matches, and the clip fraction is the only one that
## notices a channel that has run out of range — which is what "the snow looks
## too bright" turns out to mean.
##
## [b]This is not a test[/b], it just lives here because it has to run inside the
## project to use Godot's PNG decoder. `tools/regionstats.py` computes the same
## sRGB statistics and is the reference implementation, but it decodes PNGs in
## pure Python and takes minutes for one 1280x720 frame; the fitting method in
## history §11 is a gradient measured over half a dozen renders, which that
## makes impractical. This does the same frame in about a second.
##
## [b]Read the exposure column with care.[/b] Rendering at `tonemap_exposure`
## 0.25 to see past a clip is a real technique and it is in the trap list, but
## the two exposures are not related by a clean factor of four at the bright end
## — a pixel measured at 0.9131 linear at exposure 1.0 comes back as 0.8117 at
## exposure 0.25, while a mid-tone agrees to 1%. Fit against the exposure the
## game ships at; use the dim render to see *that* a channel has headroom left,
## not to put a number on it.
extends SceneTree

func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 3:
		print("usage: <png> <exposure> name:x0,y0,x1,y1 ...")
		quit(1)
		return
	var img := Image.load_from_file(args[0])
	if img == null:
		print("cannot read ", args[0])
		quit(1)
		return
	var exposure := float(args[1])
	print("== %s (%dx%d) exposure=%s" % [args[0], img.get_width(), img.get_height(), exposure])
	for i: int in range(2, args.size()):
		var parts: PackedStringArray = args[i].split(":")
		var box: PackedStringArray = parts[1].split(",")
		_region(img, parts[0], int(box[0]), int(box[1]), int(box[2]), int(box[3]), exposure)
	quit(0)

func _region(img: Image, name: String, x0: int, y0: int, x1: int, y1: int,
		exposure: float) -> void:
	x1 = mini(x1, img.get_width())
	y1 = mini(y1, img.get_height())
	# One local per channel: indexing an [Array] of packed arrays hands out a
	# copy, so `cols[ch].append(v)` lands on a temporary. See the trap list.
	var r := PackedInt32Array()
	var g := PackedInt32Array()
	var b := PackedInt32Array()
	var lin := [0.0, 0.0, 0.0]
	var n := 0
	for y: int in range(y0, y1):
		for x: int in range(x0, x1):
			var c: Color = img.get_pixel(x, y)
			var vr := int(round(c.r * 255.0))
			var vg := int(round(c.g * 255.0))
			var vb := int(round(c.b * 255.0))
			r.append(vr)
			g.append(vg)
			b.append(vb)
			lin[0] += _to_linear(float(vr) / 255.0)
			lin[1] += _to_linear(float(vg) / 255.0)
			lin[2] += _to_linear(float(vb) / 255.0)
			n += 1
	if n == 0:
		print("  %s: empty region" % name)
		return
	var cols: Array[PackedInt32Array] = [r, g, b]
	print("  %s" % name)
	for ch: int in range(3):
		var v: PackedInt32Array = cols[ch]
		v.sort()
		var m: int = v.size()
		var total := 0
		var clipped := 0
		for t: int in v:
			total += t
			if t >= 254:
				clipped += 1
		print("     %s p5=%3d med=%3d p95=%3d mean=%6.1f clip=%5.1f%% lin=%.4f" % [
			"RGB"[ch], v[m / 20], v[m / 2], v[int(m * 0.95)], float(total) / m,
			100.0 * clipped / m, lin[ch] / n / exposure])

func _to_linear(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)
