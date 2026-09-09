## What sizes the window can usefully be opened at, on the display it is on.
##
## The resolution row of [SettingsMenu] used to offer six hardcoded sizes,
## which was arbitrary in both directions: a laptop was invited to open a
## 2560x1440 window it cannot show, and a 4K monitor was never offered its own
## resolution. This is the same drop-down filled from the display instead.
##
## [b]There is no mode enumeration to call.[/b] Godot has no equivalent of SDL's
## `SDL_GetDisplayMode` — [DisplayServer] reports a screen's size, its usable
## rect, its DPI, its scale and its refresh rate, and nothing lists the modes a
## monitor advertises. So "supported" here is derived rather than asked for: the
## panel's own resolution, plus the standard modes that share its shape and fit
## in the desktop's work area. That is the same set a monitor's mode list holds
## in practice, and it is the set a windowed game can actually use — the two
## differ only in the modes nobody has wanted since CRTs.
##
## Shape matters as much as size here because `project.godot` ships
## `window/stretch/mode="canvas_items"` with the default `aspect="keep"`: a
## window that is not the 1280x720 base's 16:9 renders letterboxed inside
## itself. Offering a 4:3 mode on a 16:9 panel is offering black bars.
##
## Pure and node-free on purpose — it names no autoload, so a test can call
## [method sizes_for] with screens no machine here has. See the trap list on
## what a static call does to a class that touches `Config`.
class_name DisplayModes
extends RefCounted

## The standard display modes, grouped by aspect ratio. The catalogue the
## screen filters, not what gets offered: on any one machine most of these rows
## are the wrong shape, too large, or both.
const STANDARD_SIZES: Array[Vector2i] = [
	# 4:3
	Vector2i(640, 480), Vector2i(800, 600), Vector2i(1024, 768),
	Vector2i(1152, 864), Vector2i(1280, 960), Vector2i(1400, 1050),
	Vector2i(1600, 1200),
	# 5:4
	Vector2i(1280, 1024),
	# 3:2
	Vector2i(1152, 768), Vector2i(1440, 960), Vector2i(1920, 1280),
	Vector2i(2256, 1504), Vector2i(3000, 2000),
	# 16:10
	Vector2i(1280, 800), Vector2i(1440, 900), Vector2i(1680, 1050),
	Vector2i(1920, 1200), Vector2i(2560, 1600), Vector2i(3840, 2400),
	# 16:9
	Vector2i(854, 480), Vector2i(1024, 576), Vector2i(1280, 720),
	Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(3840, 2160),
	# wider
	Vector2i(2560, 1080), Vector2i(3440, 1440), Vector2i(3840, 1600),
	Vector2i(5120, 1440),
]

## How far off the screen's own aspect ratio a size may be and still count as
## the same shape, as a fraction of it. 1366x768 misses 16:9 by 0.05 % and is
## one of its modes; 16:10 misses it by 10 % and is not.
const ASPECT_TOLERANCE := 0.02

## Below this many same-shape modes, [constant FILL_FRACTIONS] makes up the
## difference. A 21:9 desktop shares its shape with two rows of
## [constant STANDARD_SIZES] and a portrait panel with none, and neither wants a
## drop-down that is either one row long or full of 4:3.
const MIN_OFFERED := 3

## What a display nothing standard fits is offered instead: itself, scaled.
## Shape is the thing being preserved — a window the panel's own shape never
## letterboxes and always fits on it — so a size the monitor does not advertise
## as a mode is the better answer here than a standard mode of the wrong shape.
## Rounded to even pixels, because half a pixel of viewport is a seam.
const FILL_FRACTIONS: PackedFloat32Array = [0.9, 0.75, 0.6, 0.5]

## The smallest window worth offering: half the 1280x720 the menus and the HUD
## are laid out for. [method GameConfig.parse_resolution] floors a hand-edited
## file lower than this, at 320x240, because a file is somebody being deliberate.
const MIN_SIZE := Vector2i(640, 360)

## The list for the screen the game's window is currently on — not screen 0,
## because the second monitor is rarely the same size as the first.
##
## [param current] is the size in the settings file, which is on the list
## whether or not this display can show it; see [method sizes_for].
static func for_current_screen(current: Vector2i) -> Array[Vector2i]:
	if DisplayServer.get_screen_count() <= 0:
		return sizes_for(Vector2i.ZERO, Vector2i.ZERO, current)
	var screen: int = DisplayServer.window_get_current_screen()
	return sizes_for(DisplayServer.screen_get_size(screen),
		DisplayServer.screen_get_usable_rect(screen).size, current)

## The sizes to offer for a display of [param native] pixels whose windows have
## [param usable] pixels to sit in, with [constant Vector2i.ZERO] — "Auto", the
## platform's own choice — first and [param current] always present.
##
## A mode is offered when it fits inside [param usable] (the screen minus the
## taskbar or panel, so the window can be put down without hanging off the edge
## of the desktop) and has the shape of [param native]. The native size itself is
## always offered even though it does not fit in that sense: it is what
## fullscreen renders at, and it is the number a player goes looking for.
##
## Every row therefore has the display's shape, [constant FILL_FRACTIONS]
## included — that is the invariant, and it is what stops a 21:9 desktop being
## handed a page of 4:3.
##
## [param current] is added when the display disagrees with it, because a
## drop-down that cannot show what the file says would move someone's window the
## first time they pressed Ok. A [param native] of [constant Vector2i.ZERO] is a
## display that will not say what it is — headless, or a platform without one —
## and offers the whole catalogue rather than nothing.
static func sizes_for(native: Vector2i, usable: Vector2i,
		current: Vector2i) -> Array[Vector2i]:
	var sizes: Array[Vector2i] = []
	if native.x <= 0 or native.y <= 0:
		sizes.assign(STANDARD_SIZES)
	else:
		# A usable rect is only ever smaller than the screen, and a platform that
		# does not report one reports zero; either way the screen is the ceiling.
		var room := Vector2i(usable.x if usable.x > 0 else native.x,
			usable.y if usable.y > 0 else native.y)
		var aspect: float = float(native.x) / float(native.y)
		for size: Vector2i in STANDARD_SIZES:
			if size.x > room.x or size.y > room.y:
				continue
			if absf(float(size.x) / float(size.y) - aspect) <= aspect * ASPECT_TOLERANCE:
				sizes.push_back(size)
		if sizes.size() < MIN_OFFERED:
			for fraction: float in FILL_FRACTIONS:
				var scaled := Vector2i(roundi(native.x * fraction / 2.0) * 2,
					roundi(native.y * fraction / 2.0) * 2)
				if scaled.x < MIN_SIZE.x or scaled.y < MIN_SIZE.y:
					continue
				if scaled.x > room.x or scaled.y > room.y:
					continue
				if not _near_one_of(scaled, sizes):
					sizes.push_back(scaled)
		if not sizes.has(native):
			sizes.push_back(native)
	if current != Vector2i.ZERO and not sizes.has(current):
		sizes.push_back(current)
	sizes.push_back(Vector2i.ZERO)
	# `Vector2i` sorts by width and then height, so "Auto" lands at the top.
	sizes.sort()
	return sizes

## Whether [param size] is close enough to something already offered to be a
## duplicate. A 21:9 desktop matches 2560x1080 out of the catalogue and scales
## to 2580x1080, and two rows twenty pixels apart are a drop-down that looks
## broken. Widths within [constant ASPECT_TOLERANCE] of each other are the same
## row; heights follow, because everything here has one shape.
static func _near_one_of(size: Vector2i, offered: Array[Vector2i]) -> bool:
	for other: Vector2i in offered:
		if absf(float(other.x - size.x)) <= float(size.x) * ASPECT_TOLERANCE:
			return true
	return false
