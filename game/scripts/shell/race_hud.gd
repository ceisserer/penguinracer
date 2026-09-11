## Extreme Tux Racer's in-race HUD, redrawn as vector art.
##
## `hud.cpp` draws six things and this draws the same six: the stopwatch and the
## time top left ([method _draw_time]), the herring count top right
## ([method _draw_herring]), the round gauge bottom right — jump charge inside,
## speed around the outside — with the speed in numbers at its centre
## ([method _draw_gauge], [method _draw_speed]), a bar up the right edge for how
## far down the course you are ([method _draw_course_position]), the wind rose
## bottom left when the course has wind ([method _draw_wind]), and the frame
## rate across the top when it is asked for ([method _draw_fps]).
##
## [b]Redrawn, not copied.[/b] Every one of those is a textured quad in the
## original — `gaugeoutline.png`, `timeicon.png`, `herringicon.png`,
## `ziff032.png` and the rest — and none of that art is in this tree, for the
## same reason the menus wear ETR's palette without ETR's corner ornaments: the
## licence audit is open. What is portable is the *geometry*, which lives in
## `hud.cpp`'s constants rather than in the art, so the layout constants below
## are the original's numbers and the shapes are built from them with
## [CanvasItem] primitives. The one thing that could not be reproduced is the
## typeface: ETR's numbers are a 12-glyph bitmap strip and these are the theme
## font emboldened, drawn on the strip's own fixed 22x32 cell so a rolling
## hundredths digit still does not shove the seconds sideways.
## See [method _font] and [method _draw_digits].
##
## [b]Positions are canvas pixels, and the canvas is 1280x720.[/b] ETR anchors
## the HUD to the corners of the real window, so at 1920x1080 its gauge is the
## same 128 px it is at 640x480 and reads half the size. `canvas_items` stretch
## means the numbers below are a *design* resolution that scales with the
## window, which is how the rest of this shell already works — see the results
## panel's 80 px in the trap list.
##
## [b]Three things here are not in the original[/b], and each is marked
## `DEVIATION` where it is drawn: the status line under the time (the ghost
## delta, or the standings — this game has opponents and ghosts and ETR has
## neither), the `PRESS ANY KEY TO START` hint over the start animation, and
## `Race Over` beside the time for the three seconds between the line and the
## results panel. Everything else on screen is `DrawHud`.
class_name RaceHUD
extends CanvasLayer

# ------------------------------------------------------------------
#                        the original's numbers
# ------------------------------------------------------------------
# Every constant in this block is from `etr-0.8.4/src/hud.cpp` unless it says
# otherwise. The few that are measured off the art rather than named in the
# source say so: the artist put the speed ring's edges in the texture, not in a
# `#define`, and a redraw needs them as numbers.

## The gauge's box, bottom-right corner of the screen. `GAUGE_IMG_SIZE`.
const GAUGE_SIZE := 128.0
## Centre of both the jump-charge disc and the speed ring, measured from the
## bottom-left of that box. `ENERGY_GAUGE_CENTER_X/Y`.
const GAUGE_CENTER := Vector2(71.0, 55.0)
## Radius of the jump-charge disc. Measured off `gaugeenergymask.png`: the
## source only ever draws that texture on a full-box quad, so the disc's size is
## in the art.
const ENERGY_RADIUS := 53.0
## Where the charge fill sits at empty and how far it travels to full.
## `ENERGY_GAUGE_BOTTOM`, `ENERGY_GAUGE_HEIGHT` — together they sweep the disc
## from its bottom edge to its top.
const ENERGY_BOTTOM := 3.0
const ENERGY_HEIGHT := 103.0
## Inner and outer edge of the speed ring, measured off `gaugespeedmask.png` by
## fitting a circle to its opaque pixels; the fit lands the centre on
## [constant GAUGE_CENTER] to within half a pixel, which is what says the ring
## and the wedge that reveals it really are concentric.
const SPEEDBAR_INNER_RADIUS := 52.0
const SPEEDBAR_OUTER_RADIUS := 68.0
## The sweep, in ETR's y-up degrees: empty at the lower left, full at the upper
## right, going up the left side and over the top. `SPEEDBAR_BASE_ANGLE`,
## `SPEEDBAR_MAX_ANGLE`.
const SPEEDBAR_BASE_ANGLE := 225.0
const SPEEDBAR_MAX_ANGLE := 45.0
## Where the coloured bands end, in km/h, and how much of the sweep each gets.
## Green runs to the speed past which paddling stops helping, so the bar says
## something the physics also says.
const SPEEDBAR_GREEN_MAX_SPEED := PhysConst.MAX_PADDLING_SPEED * 3.6
const SPEEDBAR_YELLOW_MAX_SPEED := 100.0
const SPEEDBAR_RED_MAX_SPEED := 160.0
const SPEEDBAR_GREEN_FRACTION := 0.5
const SPEEDBAR_YELLOW_FRACTION := 0.25
const SPEEDBAR_RED_FRACTION := 0.25

## Top-left stopwatch, then the minutes and seconds, then the hundredths at 0.7
## scale. `draw_time`.
const TIME_ICON_AT := Vector2(10.0, 10.0)
const TIME_ICON_SIZE := Vector2(32.0, 38.0)
const TIME_DIGITS_AT := Vector2(50.0, 12.0)
const HUNDREDTHS_AT := Vector2(170.0, 12.0)
const HUNDREDTHS_SCALE := 0.7

## Top-right count, then the fish, both offset from the right edge.
## `draw_herring_count`.
const HERRING_ICON_INSET := 59.0
const HERRING_ICON_SIZE := Vector2(50.0, 32.0)
const HERRING_DIGITS_INSET := 130.0
const HERRING_DIGITS_TOP := 12.0

## The speed, in numbers, inside the gauge. `DrawSpeed`.
const SPEED_DIGITS_INSET := Vector2(87.0, 73.0)

## The course-position bar: 32x128 up the right edge, 280 px of screen above the
## bottom. `DrawCoursePosition` + `DrawPercentBar`.
const POSITION_BAR_INSET := 48.0
const POSITION_BAR_SIZE := Vector2(32.0, 128.0)
const POSITION_BAR_BOTTOM := 152.0

## The wind rose, bottom left, and the wind speed beside it. `DrawWind`.
const WIND_INSET := 5.0
const WIND_DIAMETER := 111.0
const WIND_ARROW_LENGTH := 45.0
const WIND_ARROW_HALF_WIDTH := 5.0
const WIND_HEADING_LENGTH := 50.0
const WIND_HEADING_HALF_WIDTH := 2.0
const WIND_KNOB_SIZE := 16.0
const WIND_DIGITS_AT := Vector2(120.0, 45.0)
## Above this the arrow is fully opaque and starts going red. `DrawWind`.
const WIND_FULL_ALPHA_SPEED := 50.0

## Frame rate, centred across the top. `DrawFps`, and the same 50-frame average.
const FPS_DIGITS_INSET := 60.0
const FPS_DIGITS_TOP := 10.0
const FPS_AVERAGE_FRAMES := 50

## One cell of ETR's number strip: 22 wide, 32 tall, the glyph 0.9 of the cell.
## `CTexture::DrawNumChr`.
const DIGIT_CELL := Vector2(22.0, 32.0)
const DIGIT_GLYPH_WIDTH := 0.9
## Theme font size as a multiple of the cell height. 1.2 is as large as the
## digits go before their advance outgrows the 22 px cell and `00` closes up —
## ETR's strip is a condensed face and the theme font is not.
const DIGIT_FONT_RATIO := 1.2
## Where the baseline sits in the cell, and how thick the outline around a
## glyph is. ETR's strip has the dark edge painted into it; over snow it is not
## decoration, it is the only reason a white number is readable at all.
const DIGIT_BASELINE := 0.92
const DIGIT_OUTLINE := 3

# ------------------------------------------------------------------
#                              colours
# ------------------------------------------------------------------

## The jump-charge fill. `energy_foreground_color`, half-transparent, which is
## why the snow shows through a charging gauge.
const ENERGY_FILL := Color(0.541, 0.588, 1.0, 0.5)
## The three bands of the speed ring, off `gaugespeedmask.png`.
const SPEEDBAR_GREEN := Color(0.0, 1.0, 0.0, 1.0)
const SPEEDBAR_YELLOW := Color(1.0, 0.898, 0.012, 1.0)
const SPEEDBAR_RED := Color(1.0, 0.0, 0.0, 1.0)
## `gaugeoutline.png` is black line art and this is the line.
const OUTLINE := Color(0.0, 0.0, 0.0, 1.0)
const OUTLINE_WIDTH := 3.0
## `colDYell` from `common.cpp` — the icons are drawn in the menus' focus
## yellow, which is also what the original's two icons are painted.
const ICON_FILL := Color(1.0, 0.8, 0.0, 1.0)
## The course-position bar: `energymask2.png` is a cyan pill with a vertical
## ramp in it, `mask_outline2.png` the white frame around it.
const POSITION_FILL_TOP := Color(0.21, 0.78, 0.95, 0.85)
const POSITION_FILL_BOTTOM := Color(0.05, 0.35, 0.62, 0.85)
const POSITION_FRAME := Color(1.0, 1.0, 1.0, 0.85)
const POSITION_BACK := Color(0.0, 0.0, 0.0, 0.35)

## DEVIATION: ahead of the ghost is green, behind it is the same amber the menus
## give whatever has focus. Both stay legible over snow, which most colours do
## not. The original has no ghost to be ahead of.
const AHEAD_COLOR := Color(0.55, 1.0, 0.6)
const BEHIND_COLOR := Color(1.0, 0.83, 0.3)

## DEVIATION: the status line, and the two hints. Sizes and places that no
## constant in `hud.cpp` corresponds to, because none of this is in `hud.cpp`.
const STATUS_AT := Vector2(14.0, 56.0)
const STATUS_FONT_SIZE := 19
const FINISH_AT := Vector2(215.0, 14.0)
const FINISH_FONT_SIZE := 26
const HINT_FROM_BOTTOM := 150.0
const HINT_FONT_SIZE := 22

@export var race: RaceScene

## The [Control] everything is drawn on. A [CanvasLayer] is not a [CanvasItem]
## and has no `_draw` of its own, so the layer owns one child that does nothing
## but hand `_draw` back here.
var _face: Control

## The theme font, emboldened — see [method _font].
var _hud_font: FontVariation

## `DrawFps`'s running average, kept the same way: sum 50 frames, divide, start
## again. A per-frame reciprocal flickers too fast to read.
var _fps_frames: int = 0
var _fps_sum: float = 0.0
var _fps_average: float = 0.0

func _ready() -> void:
	if race == null:
		race = get_parent() as RaceScene
	_face = Control.new()
	_face.set_anchors_preset(Control.PRESET_FULL_RECT)
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.draw.connect(_on_face_draw)
	add_child(_face)

func _process(delta: float) -> void:
	if race == null or race.physics == null:
		return
	# The course menu and the results screen both draw over this corner, and a
	# frozen time and speed behind either read as a bug.
	visible = not race.paused
	if not visible:
		return
	_accumulate_fps(delta)
	# Everything here is read fresh out of the simulation at paint time, so the
	# only thing a frame has to do is ask for one.
	_face.queue_redraw()

func _on_face_draw() -> void:
	if race == null or race.physics == null:
		return
	var size: Vector2 = _face.size
	_draw_gauge(size)
	_draw_time(size)
	_draw_herring(size)
	_draw_speed(size)
	_draw_course_position(size)
	_draw_wind(size)
	_draw_fps(size)
	_draw_status(size)

# ==================================================================
#                            the time
# ==================================================================

## `draw_time` — the stopwatch, `MM:SS`, and the hundredths at 0.7 scale
## trailing it like a superscript.
##
## ETR draws the time white in a practice run and in a medal colour when a cup
## race is counting down to one of the three thresholds. There are no cups here
## (see the game shell row in AGENTS.md), so this is the white half only; the
## medal half is waiting on the same thing `RaceEvent.time` is.
func _draw_time(_size: Vector2) -> void:
	_draw_stopwatch(TIME_ICON_AT, TIME_ICON_SIZE)
	var seconds: float = race.race_time
	# `GetTimeComponents` — and the hundredths round rather than truncate, so
	# the last digit of a finish time agrees with the results screen's.
	var minutes: int = int(seconds / 60.0)
	var secs: int = int(seconds) % 60
	var hundredths: int = int(seconds * 100.0 + 0.5) % 100
	_draw_digits("%02d:%02d" % [minutes, secs], TIME_DIGITS_AT, 1.0, Color.WHITE)
	_draw_digits("%02d" % hundredths, HUNDREDTHS_AT, HUNDREDTHS_SCALE, Color.WHITE)
	# DEVIATION: the original has nothing to say here — it leaves the racing
	# loop at the line and `CGameOver` takes the screen. This build keeps
	# drawing for [constant RaceScene.FINISH_MENU_DELAY] seconds so the finish
	# animation is watchable, and for those three seconds a stopped clock with
	# no explanation is exactly the bug it looks like.
	if race.physics.finished:
		_draw_text(tr("RACE_OVER"), FINISH_AT, FINISH_FONT_SIZE, ICON_FILL)

# ==================================================================
#                           the herring
# ==================================================================

## `draw_herring_count` — three zero-padded digits, then the fish, both hung off
## the right edge. Cup racing colours this by how many are still owed for a
## medal; practice draws it white, and practice is all there is here.
func _draw_herring(size: Vector2) -> void:
	_draw_digits("%03d" % race.herring,
		Vector2(size.x - HERRING_DIGITS_INSET, HERRING_DIGITS_TOP), 1.0, Color.WHITE)
	_draw_fish(Vector2(size.x - HERRING_ICON_INSET, HERRING_DIGITS_TOP), HERRING_ICON_SIZE)

# ==================================================================
#                            the gauge
# ==================================================================

## `draw_gauge` — one dial carrying two unrelated numbers, which is most of what
## makes the original's HUD read as a HUD rather than as a row of text.
##
## Inside: the jump charge, a translucent fill that rises up the disc while the
## key is held. Outside: the speed, an arc that fills green then yellow then red
## around the top. Both are drawn as a coloured shape under a black outline,
## which is what the original's three textures amount to — a mask, a mask and
## the line art over them.
func _draw_gauge(size: Vector2) -> void:
	var center := Vector2(size.x - GAUGE_SIZE + GAUGE_CENTER.x, size.y - GAUGE_CENTER.y)
	var bottom: float = size.y

	# --- jump charge -------------------------------------------------
	# The fill line travels from the disc's bottom edge to its top as the
	# charge goes 0..1, and everything below it is filled.
	var charge: float = clampf(race.physics.jump_amt / RacePhysics.MAX_JUMP_AMT, 0.0, 1.0)
	var fill_y: float = bottom - (ENERGY_BOTTOM + charge * ENERGY_HEIGHT)
	var segment: PackedVector2Array = _circle_below(center, ENERGY_RADIUS, fill_y)
	if segment.size() >= 3:
		_face.draw_colored_polygon(segment, ENERGY_FILL)

	# --- speed -------------------------------------------------------
	# ETR draws the whole sweep first in a colour whose alpha is zero and then
	# the filled part over it, which is a long way of saying the empty part of
	# the ring is not drawn at all. Only the outline says where it would go.
	var speed_kmh: float = race.physics.vel.length() * 3.6
	var fraction: float = speedbar_fraction(speed_kmh)
	var base: float = deg_to_rad(-SPEEDBAR_BASE_ANGLE)
	var full: float = deg_to_rad(-SPEEDBAR_MAX_ANGLE)
	var mid_radius: float = (SPEEDBAR_INNER_RADIUS + SPEEDBAR_OUTER_RADIUS) * 0.5
	var thickness: float = SPEEDBAR_OUTER_RADIUS - SPEEDBAR_INNER_RADIUS
	# The band edges are fractions of the sweep, not of the speed range, so
	# they are the same three angles at every speed — which is what lets the
	# player read "past green" without reading the number.
	var bands: Array[Array] = [
		[0.0, SPEEDBAR_GREEN_FRACTION, SPEEDBAR_GREEN],
		[SPEEDBAR_GREEN_FRACTION, SPEEDBAR_GREEN_FRACTION + SPEEDBAR_YELLOW_FRACTION,
			SPEEDBAR_YELLOW],
		[SPEEDBAR_GREEN_FRACTION + SPEEDBAR_YELLOW_FRACTION, 1.0, SPEEDBAR_RED],
	]
	for band: Array in bands:
		var from: float = float(band[0])
		var to: float = minf(float(band[1]), fraction)
		if to <= from:
			continue
		_face.draw_arc(center, mid_radius, lerpf(base, full, from), lerpf(base, full, to),
			32, band[2] as Color, thickness, true)

	# --- outline -----------------------------------------------------
	# `gaugeoutline.png`: the disc's circle and both edges of the ring, with the
	# ring's ends capped. Drawn last so it sits over both fills, exactly as the
	# original's quad does.
	_face.draw_arc(center, SPEEDBAR_INNER_RADIUS, base, full, 48, OUTLINE, OUTLINE_WIDTH, true)
	_face.draw_arc(center, SPEEDBAR_OUTER_RADIUS, base, full, 48, OUTLINE, OUTLINE_WIDTH, true)
	for angle: float in [base, full]:
		var dir := Vector2(cos(angle), sin(angle))
		_face.draw_line(center + dir * SPEEDBAR_INNER_RADIUS,
			center + dir * SPEEDBAR_OUTER_RADIUS, OUTLINE, OUTLINE_WIDTH, true)
	_face.draw_arc(center, ENERGY_RADIUS, 0.0, TAU, 64, OUTLINE, OUTLINE_WIDTH, true)

## How much of the speed ring is filled at [param speed_kmh], 0..1.
##
## `draw_gauge`'s piecewise ramp, kept whole: the first half of the sweep is
## 0 km/h to the paddling ceiling, the third quarter is that to 100, the last
## quarter is 100 to 160, and past 160 it is full. The bends are the point —
## the bar is fine-grained where a racer spends most of a run and coarse at
## speeds a course has to be pointed downhill to reach.
static func speedbar_fraction(speed_kmh: float) -> float:
	var fraction: float = 0.0
	if speed_kmh > SPEEDBAR_GREEN_MAX_SPEED:
		fraction = SPEEDBAR_GREEN_FRACTION
		if speed_kmh > SPEEDBAR_YELLOW_MAX_SPEED:
			fraction += SPEEDBAR_YELLOW_FRACTION
			if speed_kmh > SPEEDBAR_RED_MAX_SPEED:
				fraction += SPEEDBAR_RED_FRACTION
			else:
				fraction += (speed_kmh - SPEEDBAR_YELLOW_MAX_SPEED) \
					/ (SPEEDBAR_RED_MAX_SPEED - SPEEDBAR_YELLOW_MAX_SPEED) \
					* SPEEDBAR_RED_FRACTION
		else:
			fraction += (speed_kmh - SPEEDBAR_GREEN_MAX_SPEED) \
				/ (SPEEDBAR_YELLOW_MAX_SPEED - SPEEDBAR_GREEN_MAX_SPEED) \
				* SPEEDBAR_YELLOW_FRACTION
	else:
		fraction += speed_kmh / SPEEDBAR_GREEN_MAX_SPEED * SPEEDBAR_GREEN_FRACTION
	return clampf(fraction, 0.0, 1.0)

## `DrawSpeed` — three zero-padded digits in the middle of the gauge. Truncated
## rather than rounded, which is the original's `(int)speed`.
func _draw_speed(size: Vector2) -> void:
	var speed_kmh: int = int(race.physics.vel.length() * 3.6)
	_draw_digits("%03d" % clampi(speed_kmh, 0, 999),
		size - SPEED_DIGITS_INSET, 1.0, Color.WHITE)

# ==================================================================
#                        course position
# ==================================================================

## `DrawCoursePosition` — how far down the course the racer is, as a bar up the
## right edge that fills from the bottom.
##
## The original's fraction is `cpos.z / play_dimensions.y`, and it is *negative*
## going down the hill — which is why `DrawPercentBar` is handed `-fact` and why
## the two negatives together are what make the bar fill upward. Written here
## with the flip in one place, as [member RacerState.progress] also does it.
## It clamps at the far end, which the original does not: a course is drivable
## past its play length, and a bar that grows out of its own frame is worse than
## one that sits full.
func _draw_course_position(size: Vector2) -> void:
	var course: CourseData = race.course_root.course_data if race.course_root != null else null
	if course == null or course.play_size.y <= 0.0:
		return
	var fraction: float = clampf(-race.physics.pos.z / course.play_size.y, 0.0, 1.0)
	var rect := Rect2(
		Vector2(size.x - POSITION_BAR_INSET, size.y - POSITION_BAR_BOTTOM - POSITION_BAR_SIZE.y),
		POSITION_BAR_SIZE)
	var pill: PackedVector2Array = _stadium(rect)
	_face.draw_colored_polygon(pill, POSITION_BACK)
	if fraction > 0.0:
		var filled: PackedVector2Array = _clip_below(pill, rect.end.y - fraction * rect.size.y)
		if filled.size() >= 3:
			_face.draw_polygon(filled, _vertical_ramp(filled, rect,
				POSITION_FILL_TOP, POSITION_FILL_BOTTOM))
	_draw_closed(pill, POSITION_FRAME, OUTLINE_WIDTH)

# ==================================================================
#                             the wind
# ==================================================================

## `DrawWind` — a rose bottom left with two needles: a fat one for where the
## wind is blowing, colouring from blue to red as it gets up, and a thin dark
## green one for where the racer is pointed, so the angle between them is the
## crosswind you are about to be pushed by.
##
## Drawn only when the course has wind, which is `g_game.wind_id < 1` in the
## original and [member WindField.windy] here. Nothing in this build sets it
## yet except `--wind=`: wind is a property of a *cup race* in `events.lst`
## and there are no cups, so a practice run is calm in both games. The rose is
## ported anyway because the state machine behind it already is, and a HUD
## control with no way to see it is a control nobody will notice is broken.
func _draw_wind(size: Vector2) -> void:
	var wind: WindField = race.physics.wind
	if wind == null or not wind.windy:
		return
	var center := Vector2(WIND_INSET + WIND_DIAMETER * 0.5,
		size.y - WIND_INSET - WIND_DIAMETER * 0.5)
	var speed: float = wind.speed()
	_face.draw_arc(center, WIND_DIAMETER * 0.5, 0.0, TAU, 64, OUTLINE, OUTLINE_WIDTH, true)

	# Alpha is how hard it is blowing up to 50, colour is how hard past it.
	var alpha: float = minf(speed / WIND_FULL_ALPHA_SPEED, 1.0)
	var red: float = clampf((speed - WIND_FULL_ALPHA_SPEED) / WIND_FULL_ALPHA_SPEED, 0.0, 1.0)
	var wind_dir: float = deg_to_rad(wind.angle())
	_draw_needle(center, wind_dir, WIND_ARROW_HALF_WIDTH, WIND_ARROW_LENGTH,
		Color(red, 0.0, 1.0 - red, alpha))

	# `atan2(cvel.x, cvel.z)` — the racer's heading. The original stacks a
	# second `glRotatef` of `dir_angle - dir` on top of the first, which is a
	# roundabout way of writing an absolute heading; written absolutely here,
	# because the roundabout way is what makes it look like a relative angle.
	var vel: Vector3 = race.physics.vel
	_draw_needle(center, atan2(vel.x, vel.z), WIND_HEADING_HALF_WIDTH, WIND_HEADING_LENGTH,
		Color(0.0, 0.5, 0.0, 1.0))

	_face.draw_circle(center, WIND_KNOB_SIZE * 0.5, ICON_FILL)
	_face.draw_arc(center, WIND_KNOB_SIZE * 0.5, 0.0, TAU, 24, OUTLINE, 2.0, true)
	_draw_digits("%03d" % clampi(int(speed), 0, 999),
		Vector2(WIND_DIGITS_AT.x, size.y - WIND_DIGITS_AT.y), 1.0, Color.WHITE)

## One needle of the wind rose: a rectangle [param half_width] either side of
## the centre, [param length] long — the original's vertex list, rotated.
##
## Zero points *down* the screen, because the original's untransformed needle
## runs from the origin to `-len` in a y-up scene and `glRotatef` turns it
## anticlockwise from there. Both angles are measured from `+z` toward `+x` and
## a course runs toward `-z`, so a racer going straight down the hill holds the
## heading needle at the top of the rose — the original's orientation, kept.
func _draw_needle(center: Vector2, angle: float, half_width: float, length: float,
		color: Color) -> void:
	var forward := Vector2(sin(angle), cos(angle))
	var across := Vector2(forward.y, -forward.x) * half_width
	_face.draw_colored_polygon(PackedVector2Array([
		center - across, center + across,
		center + across + forward * length, center - across + forward * length]), color)

# ==================================================================
#                          the frame rate
# ==================================================================

## `DrawFps` — the 50-frame average across the top, and only when it is asked
## for. ETR asks with `param.display_fps` in its config file; this asks with
## `--fps` on the command line or `?fps` in the URL, because a debug readout is
## something you turn on for a session rather than a preference you keep.
func _draw_fps(size: Vector2) -> void:
	if not LaunchArgs.current().show_fps or _fps_average < 1.0:
		return
	_draw_digits("%d" % int(_fps_average),
		Vector2((size.x - FPS_DIGITS_INSET) * 0.5, FPS_DIGITS_TOP), 1.0, Color.WHITE)

func _accumulate_fps(delta: float) -> void:
	if _fps_frames >= FPS_AVERAGE_FRAMES:
		_fps_average = float(FPS_AVERAGE_FRAMES) / maxf(_fps_sum, 0.0001)
		_fps_frames = 0
		_fps_sum = 0.0
	else:
		_fps_sum += delta
		_fps_frames += 1

# ==================================================================
#                    the status line (DEVIATION)
# ==================================================================

## DEVIATION: the ghost delta if there is a ghost, otherwise where the player is
## in the field, otherwise nothing. The original races the clock alone and has
## neither to report.
##
## Never both: two numbers on one line, one of them signed and one of them not,
## is a line nobody reads at 60 km/h. Which one it is decides itself — a race
## against opponents does not draw a ghost (see [method RaceScene._setup_ghost]),
## so [method RaceScene.ghost_delta] is infinite there and the standings take
## the line.
func _draw_status(size: Vector2) -> void:
	# DEVIATION: the original draws its ordinary HUD over the start animation
	# and says nothing about the fact that any key skips it. The string is one
	# of the migrated ones — it is what ETR puts under its splash screen — and a
	# four-and-a-half second wait nobody knows they can cut short is worse than
	# a line of text. It sits low and centred rather than in the corner now that
	# the corner has a clock in it.
	if race.intro_running:
		_draw_centered(tr("PRESS_ANY_KEY_TO_START"), size.y - HINT_FROM_BOTTOM, size,
			HINT_FONT_SIZE, Color.WHITE)
		return
	var delta: float = race.ghost_delta()
	if is_finite(delta):
		_draw_text("%s %+.2f s" % [RaceScene.GHOST_LABEL, delta], STATUS_AT, STATUS_FONT_SIZE,
			BEHIND_COLOR if delta > 0.0 else AHEAD_COLOR)
		return
	if race.roster.all.size() < 2:
		return
	_draw_standings()

## Where the player is, and who is either side of them.
##
## Not the whole field: ten names on one line is a line nobody reads, and the
## only rows that change how you drive are the one you are chasing and the one
## chasing you. The gap is metres down the course rather than seconds, because
## metres is what [member RacerState.progress] holds for everybody — a racer who
## has not reached your point yet has no time to be compared against, which is
## the thing that makes a ghost delta a different measurement from this one.
func _draw_standings() -> void:
	var ordered: Array[Racer] = race.standings()
	var place: int = ordered.find(race.roster.local) + 1
	if place < 1:
		return
	var parts := PackedStringArray(["%d / %d" % [place, ordered.size()]])
	if place > 1:
		parts.push_back(_gap_line("↑", ordered[place - 2]))
	if place < ordered.size():
		parts.push_back(_gap_line("↓", ordered[place]))
	_draw_text("    ".join(parts), STATUS_AT, STATUS_FONT_SIZE,
		AHEAD_COLOR if place == 1 else Color.WHITE)

func _gap_line(arrow: String, other: Racer) -> String:
	return "%s %s %.0f m" % [arrow, other.display_name,
		absf(other.state.progress - race.roster.local.state.progress)]

# ==================================================================
#                              icons
# ==================================================================

## The stopwatch, in a box the size of `timeicon.png`: a yellow ring with a
## black edge, a crown on its shoulder and two hands. Built from primitives
## rather than migrated — see the class doc.
func _draw_stopwatch(at: Vector2, box: Vector2) -> void:
	var scale: float = box.x / TIME_ICON_SIZE.x
	var center: Vector2 = at + Vector2(16.0, 23.0) * scale
	var outer: float = 14.0 * scale
	var inner: float = 8.0 * scale
	var edge: float = 2.0 * scale
	# The crown and the neck joining it to the case, drawn as one black
	# silhouette with the yellow laid inside it. Two outlined circles left a
	# seam where they met; the original's art has them share an edge, and this
	# is the cheap way to the same thing.
	var crown: Vector2 = at + Vector2(7.0, 6.0) * scale
	var neck: Vector2 = center + (crown - center).normalized() * outer
	_face.draw_line(crown, neck, OUTLINE, 5.0 * scale + edge * 2.0, true)
	_face.draw_circle(crown, 5.0 * scale + edge, OUTLINE)
	_face.draw_line(crown, neck, ICON_FILL, 5.0 * scale, true)
	_face.draw_circle(crown, 5.0 * scale, ICON_FILL)
	# The ring is one thick arc; the two outlines are the edges of it.
	_face.draw_arc(center, (outer + inner) * 0.5, 0.0, TAU, 48, ICON_FILL, outer - inner, true)
	_face.draw_arc(center, outer, 0.0, TAU, 48, OUTLINE, edge, true)
	_face.draw_arc(center, inner, 0.0, TAU, 48, OUTLINE, edge, true)
	_face.draw_line(center, center + Vector2(0.0, -5.5) * scale, OUTLINE, edge, true)
	_face.draw_line(center, center + Vector2(4.5, 1.5) * scale, OUTLINE, edge, true)

## The herring, in a box the size of `herringicon.png`. A body, a forked tail, a
## dorsal fin and an eye — the original's silhouette rebuilt as a vertex list,
## not traced off it.
func _draw_fish(at: Vector2, box: Vector2) -> void:
	var s: Vector2 = box / HERRING_ICON_SIZE
	var body := PackedVector2Array()
	for p: Vector2 in [
		Vector2(2, 17), Vector2(8, 10), Vector2(16, 6), Vector2(24, 5), Vector2(30, 7),
		Vector2(35, 11), Vector2(39, 14), Vector2(48, 3), Vector2(44, 16), Vector2(48, 29),
		Vector2(39, 18), Vector2(34, 22), Vector2(27, 26), Vector2(18, 27), Vector2(9, 24),
	]:
		body.push_back(at + p * s)
	var fin := PackedVector2Array()
	for p: Vector2 in [Vector2(19, 6), Vector2(26, 0), Vector2(30, 7)]:
		fin.push_back(at + p * s)
	_face.draw_colored_polygon(fin, ICON_FILL)
	_draw_closed(fin, OUTLINE, 2.0 * s.y)
	_face.draw_colored_polygon(body, ICON_FILL)
	_draw_closed(body, OUTLINE, 2.0 * s.y)
	_face.draw_circle(at + Vector2(9, 14) * s, 2.0 * s.y, OUTLINE)

# ==================================================================
#                             drawing
# ==================================================================

## The theme font, synthetically emboldened.
##
## `ziff032.png` is a heavy condensed face with a dark edge painted into every
## glyph, and the thing it buys is weight: a hairline number over sunlit snow is
## unreadable however big it is. There is no font file in this tree to swap in
## (see the licence note on the class), so the weight comes from
## [member FontVariation.variation_embolden] over whatever the theme hands out.
## Built on first use rather than in `_ready`, because a [Control] has no theme
## to ask until it is in the tree.
func _font() -> Font:
	if _hud_font == null:
		var base: Font = _face.get_theme_default_font()
		if base == null:
			return null
		_hud_font = FontVariation.new()
		_hud_font.base_font = base
		_hud_font.variation_embolden = 0.3
	return _hud_font

## ETR's numbers are a 12-glyph strip drawn on a fixed 22x32 cell at 0.9 of the
## cell wide, so `00:02` is exactly as wide as `19:59` and a rolling hundredths
## digit never shoves the seconds sideways. The strip is not in this tree, so
## the glyphs are the theme font — but the *cell* is the original's, and each
## character is centred in its own one, which is the half of a bitmap font that
## the layout actually depends on.
func _draw_digits(text: String, at: Vector2, scale: float, color: Color) -> void:
	var font: Font = _font()
	if font == null:
		return
	var cell: Vector2 = DIGIT_CELL * scale
	var font_size: int = int(roundf(cell.y * DIGIT_FONT_RATIO))
	var baseline: float = at.y + cell.y * DIGIT_BASELINE
	for i in text.length():
		var glyph: String = text[i]
		var width: float = font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			font_size).x
		var pos := Vector2(
			at.x + float(i) * cell.x + (cell.x * DIGIT_GLYPH_WIDTH - width) * 0.5, baseline)
		_face.draw_string_outline(font, pos, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size,
			DIGIT_OUTLINE, OUTLINE)
		_face.draw_string(font, pos, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)

## A line of ordinary text with the same dark edge the numbers get, because it
## is over the same snow.
func _draw_text(text: String, at: Vector2, font_size: int, color: Color) -> void:
	var font: Font = _font()
	if font == null:
		return
	var pos := at + Vector2(0.0, float(font_size))
	_face.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size,
		DIGIT_OUTLINE, OUTLINE)
	_face.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)

func _draw_centered(text: String, y: float, size: Vector2, font_size: int, color: Color) -> void:
	var font: Font = _font()
	if font == null:
		return
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	_draw_text(text, Vector2((size.x - width) * 0.5, y), font_size, color)

## A closed outline around a polygon. [method CanvasItem.draw_polyline] leaves
## the last edge open, which on a shape with a point on it is very visible.
func _draw_closed(points: PackedVector2Array, color: Color, width: float) -> void:
	if points.size() < 2:
		return
	var loop: PackedVector2Array = points.duplicate()
	loop.push_back(points[0])
	_face.draw_polyline(loop, color, width, true)

## The part of a circle below [param y], as a polygon: the arc from where the
## line crosses the right side, round the bottom, to where it crosses the left,
## closed by the chord. This is the jump-charge fill — a disc with a flat top
## that rises.
func _circle_below(center: Vector2, radius: float, y: float) -> PackedVector2Array:
	var s: float = (y - center.y) / radius
	var points := PackedVector2Array()
	if s >= 1.0:
		return points
	var from: float = asin(clampf(s, -1.0, 1.0))
	var to: float = PI - from
	var steps: int = 48
	for i in steps + 1:
		var a: float = lerpf(from, to, float(i) / float(steps))
		points.push_back(center + Vector2(cos(a), sin(a)) * radius)
	return points

## A rounded-ended vertical bar — `energymask2.png`'s pill, as geometry.
func _stadium(rect: Rect2) -> PackedVector2Array:
	var radius: float = rect.size.x * 0.5
	var top := Vector2(rect.position.x + radius, rect.position.y + radius)
	var bottom := Vector2(top.x, rect.end.y - radius)
	var points := PackedVector2Array()
	var steps: int = 16
	for i in steps + 1:
		var a: float = lerpf(0.0, PI, float(i) / float(steps))
		points.push_back(bottom + Vector2(cos(a), sin(a)) * radius)
	for i in steps + 1:
		var a: float = lerpf(PI, TAU, float(i) / float(steps))
		points.push_back(top + Vector2(cos(a), sin(a)) * radius)
	return points

## The part of a convex polygon below [param y]. One half-plane of
## Sutherland–Hodgman, which is all a horizontal fill line needs.
func _clip_below(points: PackedVector2Array, y: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var count: int = points.size()
	for i in count:
		var a: Vector2 = points[i]
		var b: Vector2 = points[(i + 1) % count]
		var a_in: bool = a.y >= y
		var b_in: bool = b.y >= y
		if a_in:
			out.push_back(a)
		if a_in != b_in and not is_equal_approx(a.y, b.y):
			out.push_back(a.lerp(b, (y - a.y) / (b.y - a.y)))
	return out

## Per-vertex colours for a vertical gradient across [param rect] — the ramp
## painted into `energymask2.png`, as vertex colour instead of as a texture.
func _vertical_ramp(points: PackedVector2Array, rect: Rect2, top: Color,
		bottom: Color) -> PackedColorArray:
	var colors := PackedColorArray()
	for p: Vector2 in points:
		colors.push_back(top.lerp(bottom, clampf((p.y - rect.position.y) / rect.size.y, 0.0, 1.0)))
	return colors
