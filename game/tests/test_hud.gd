## The in-race HUD: the two numbers it derives rather than reports, and the
## inputs the gauge is fed.
##
## Nothing here draws. What [RaceHUD] does on screen is a `_draw` full of
## primitives and the way to check that is to take a screenshot; what it does
## *arithmetically* is turn a speed into a fraction of an arc and a clock into
## `MM:SS` and hundredths, and both of those are worth a golden value because a
## wrong one is invisible in a still frame. The speed ramp especially: it is
## piecewise with two bends in it, and a bend in the wrong place reads as "the
## bar feels sluggish" rather than as a bug.
##
## [b][RaceHUD] is loaded by path, not named.[/b] Naming it would make
## `run_tests.gd` — which is the `--script` entry point and is parsed before the
## autoloads exist — depend on it at parse time, and through it on [RaceScene]
## and [RacerRoster], both of which reach for `Config` and `Net`. The whole
## chain then fails to compile with "Identifier not found: Config", the suite
## drops to half its assertions, and the two shell scripts are reported broken
## while being perfectly fine. No other test names a shell class either; see the
## trap list.
class_name TestHUD
extends RefCounted

const HUD_SCRIPT := "res://scripts/shell/race_hud.gd"

static func run(t: TestCase) -> void:
	var hud: GDScript = load(HUD_SCRIPT)
	_speedbar(t, hud)
	_time_components(t)
	_wind(t)
	_scripted_jump(t)
	_anchors(t, hud)

## `draw_gauge`'s ramp. Half the sweep is spent below the paddling ceiling,
## where a racer spends most of a run; the rest is split between two bands
## twice as wide in km/h each.
static func _speedbar(t: TestCase, hud: GDScript) -> void:
	t.begin("hud/speedbar")
	var green_top: float = hud.SPEEDBAR_GREEN_MAX_SPEED
	t.eq_f(green_top, 60.0, 1e-6, "green ends at the paddling ceiling, 60 km/h")

	t.eq_f(hud.speedbar_fraction(0.0), 0.0, 1e-6, "stopped is an empty arc")
	t.eq_f(hud.speedbar_fraction(green_top * 0.5), 0.25, 1e-6,
		"halfway up the green band is a quarter of the sweep")
	t.eq_f(hud.speedbar_fraction(green_top), 0.5, 1e-6,
		"the paddling ceiling is exactly half")
	t.eq_f(hud.speedbar_fraction(80.0), 0.625, 1e-6,
		"80 km/h is halfway through the yellow band")
	t.eq_f(hud.speedbar_fraction(100.0), 0.75, 1e-6, "100 km/h ends yellow")
	t.eq_f(hud.speedbar_fraction(130.0), 0.875, 1e-6,
		"130 km/h is halfway through the red band")
	t.eq_f(hud.speedbar_fraction(160.0), 1.0, 1e-6, "160 km/h fills it")
	# The original has no clamp on the way out and relies on `std::min` at the
	# call site; ours clamps, because a fraction over 1 is an arc that sweeps
	# back round past its own start.
	t.eq_f(hud.speedbar_fraction(400.0), 1.0, 1e-6, "and nothing goes past full")

	# Monotone, which is the property a driver actually reads off it — a bar
	# that dips anywhere would say "slowing down" in the middle of a straight.
	var previous: float = -1.0
	for kmh in range(0, 200, 2):
		var f: float = hud.speedbar_fraction(float(kmh))
		if f < previous - 1e-9:
			t.ok(false, "the arc goes backwards at %d km/h" % kmh)
			return
		previous = f
	t.ok(true, "the arc never goes backwards between 0 and 200 km/h")

	# The band edges are fractions of the *sweep*, so they are the same three
	# angles at every speed: half green, a quarter yellow, a quarter red.
	t.eq_f(float(hud.SPEEDBAR_GREEN_FRACTION) + float(hud.SPEEDBAR_YELLOW_FRACTION)
		+ float(hud.SPEEDBAR_RED_FRACTION), 1.0, 1e-6, "the three bands fill the arc exactly")

## `GetTimeComponents` — and the hundredths round rather than truncate, which is
## what keeps the last digit of a finish time agreeing with the results screen.
static func _time_components(t: TestCase) -> void:
	t.begin("hud/clock")
	t.ok(_clock(0.0) == "00:00.00", "a race starts at zero")
	t.ok(_clock(2.515) == "00:02.52", "hundredths round")
	# Faithful quirk: the three components are computed independently, so a
	# hundredth that rounds up to 100 wraps to .00 without carrying into the
	# seconds. 59.999 s reads 00:59.00 in both games, for one frame, once.
	t.ok(_clock(59.999) == "00:59.00", "a hundredth that rounds up does not carry")
	t.ok(_clock(61.25) == "01:01.25", "and minutes roll over at sixty")
	t.ok(_clock(3600.0) == "60:00.00", "an hour is sixty minutes, not one")

static func _clock(seconds: float) -> String:
	return "%02d:%02d.%02d" % [int(seconds / 60.0), int(seconds) % 60,
		int(seconds * 100.0 + 0.5) % 100]

## The rose reads [method WindField.speed] and [method WindField.angle], not the
## force vector — the vector carries the original's 0.2 weight on `z` and would
## report a crosswind as weaker than it is drawn.
static func _wind(t: TestCase) -> void:
	t.begin("hud/wind")
	var calm := WindField.new()
	calm.init_wind(0)
	t.ok(not calm.windy, "grade 0 is calm, which is every course that ships")
	t.eq_f(calm.speed(), 0.0, 1e-6, "and a calm field reports no speed")

	var blowing := WindField.new()
	blowing.init_wind(2, 12345)
	t.ok(blowing.windy, "grade 2 blows")
	t.ok(blowing.speed() > 0.0, "with a speed the rose can colour itself by")
	for i in 200:
		blowing.update(1.0 / 60.0)
	t.between(blowing.speed(), 0.0, 200.0, "and it stays in a range a 3-digit readout fits")

	# Two fields on one seed evolve identically, which is what lets every racer
	# in a field carry its own rather than share one that would be stepped once
	# per racer. See [method RaceScene._build_simulation].
	var a := WindField.new()
	var b := WindField.new()
	a.init_wind(3, 99)
	b.init_wind(3, 99)
	for i in 120:
		a.update(1.0 / 60.0)
		b.update(1.0 / 60.0)
	t.eq_f(a.speed(), b.speed(), 1e-9, "one seed, one weather")
	t.eq_f(a.angle(), b.angle(), 1e-9, "in both directions")

## `--auto-input=jump` exists so the gauge's inner half can be captured at all.
## It has to actually reach the top of the charge and let go of it.
static func _scripted_jump(t: TestCase) -> void:
	t.begin("hud/scripted jump")
	var source := ScriptedInputSource.new("jump")
	var physics := RacePhysics.new()
	var out := RaceInput.new()
	var charged: bool = false
	var released: bool = false
	for tick in 240:
		physics.time = float(tick) / 60.0
		source.poll(out, physics, 1.0 / 60.0)
		if physics.time > ScriptedInputSource.JUMP_CHARGE - 0.05 \
				and physics.time < ScriptedInputSource.JUMP_CHARGE:
			charged = out.charging
		if physics.time > ScriptedInputSource.JUMP_CHARGE + 0.05 \
				and physics.time < ScriptedInputSource.JUMP_PERIOD:
			released = released or not out.charging
	t.ok(ScriptedInputSource.JUMP_CHARGE > RacePhysics.MAX_JUMP_AMT,
		"the charge is held past the top of the gauge, so a capture can hold still in it")
	t.ok(charged, "the key is still down at the end of the charge window")
	t.ok(released, "and comes up after it")

## Where every piece of the HUD sits when the canvas is not 1280x720.
##
## `window/stretch/aspect="expand"` made that the ordinary case rather than the
## impossible one: the canvas keeps the base's short side and grows along the
## long one, so a 21:9 window hands the HUD 1680x720 and a 4:3 window 1280x960.
## Each piece has to move to its own corner — one shared scale factor cannot do
## it, since the gauge must go right while the stopwatch stays put and neither
## may change size.
##
## This is the one part of the layout worth an assertion rather than a
## screenshot, because the screenshots are all 16:9: a capture at the design
## size is exactly the case where a piece anchored to the base instead of to the
## canvas still looks right.
static func _anchors(t: TestCase, hud: GDScript) -> void:
	t.begin("hud/anchors")
	var base := Vector2(1280.0, 720.0)
	# 16:9 as it has always been, then the same canvas made wider (21:9) and
	# taller (4:3) — the two directions `expand` can grow in.
	var wide := Vector2(1680.0, 720.0)
	var tall := Vector2(1280.0, 960.0)

	# Golden values at the design size. If these move, every screenshot in the
	# notes moved with them.
	t.ok(hud.gauge_center(base) == Vector2(1223.0, 665.0),
		"the gauge sits 57 px in from the right and 55 up from the bottom")
	t.ok(hud.herring_digits_at(base) == Vector2(1150.0, 12.0),
		"the herring count hangs off the right")
	t.ok(hud.wind_center(base) == Vector2(60.5, 659.5), "the wind rose off the bottom left")
	t.ok(hud.fps_digits_at(base) == Vector2(610.0, 10.0),
		"the frame rate across the middle of the top")

	# The invariant: a right-anchored piece keeps its distance from the right
	# edge, a bottom-anchored one from the bottom, and a centred one stays
	# centred. Written as distances rather than as positions so a failure says
	# which edge was lost.
	for canvas: Vector2 in [base, wide, tall]:
		t.eq_f(canvas.x - hud.gauge_center(canvas).x, 57.0, 1e-4,
			"the gauge stays 57 px off the right edge of a %.0fx%.0f canvas" % [canvas.x, canvas.y])
		t.eq_f(canvas.y - hud.gauge_center(canvas).y, 55.0, 1e-4,
			"and 55 px off the bottom")
		t.ok(hud.speed_digits_at(canvas) == canvas - Vector2(87.0, 73.0),
			"the speed reading goes with it")
		t.eq_f(canvas.x - hud.herring_digits_at(canvas).x, 130.0, 1e-4,
			"the herring count stays off the right edge")
		t.eq_f(hud.herring_digits_at(canvas).y, 12.0, 1e-4, "and stays at the top")
		t.eq_f(canvas.x - hud.position_bar_rect(canvas).position.x, 48.0, 1e-4,
			"the course-position bar stays off the right edge")
		t.eq_f(canvas.y - hud.position_bar_rect(canvas).end.y, 152.0, 1e-4,
			"and its foot stays 152 px off the bottom")
		t.eq_f(hud.wind_center(canvas).x, 60.5, 1e-4, "the wind rose stays on the left")
		t.eq_f(canvas.y - hud.wind_center(canvas).y, 60.5, 1e-4, "and off the bottom")
		t.eq_f(canvas.y - hud.wind_digits_at(canvas).y, 45.0, 1e-4,
			"the wind speed beside it tracks the bottom, not the base's 720")
		t.eq_f(hud.fps_digits_at(canvas).x * 2.0 + 60.0, canvas.x, 1e-4,
			"the frame rate stays centred")
		t.eq_f(canvas.y - hud.hint_top(canvas), 150.0, 1e-4,
			"and the start hint stays up from the bottom")

	# Nothing anchored to an edge may collide with the piece in the other
	# corner, which is the failure mode of a canvas narrower than the base:
	# 640 px of width with a 130 px herring count and a 215 px `Race Over`.
	var narrow := Vector2(640.0, 360.0)
	t.ok(hud.herring_digits_at(narrow).x > hud.FINISH_AT.x,
		"even at the 640x360 floor the herring count clears the top-left block")
	t.ok(hud.gauge_center(narrow).x - hud.SPEEDBAR_OUTER_RADIUS > hud.WIND_DIAMETER,
		"and the gauge clears the wind rose")
