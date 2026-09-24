## The course screen's crosswind: [method WindField.init_crosswind], what it does
## to a racer (only in flight, only a little) and how it travels from the menu
## to the race and over the wire.
class_name TestWind
extends RefCounted

const DT := 1.0 / 60.0

static func run(t: TestCase) -> void:
	_strengths(t)
	_side(t)
	_ground_is_untouched(t)
	_flight_drifts_downwind(t)
	_carried(t)

static func _strengths(t: TestCase) -> void:
	t.begin("wind/strengths")
	var calm := WindField.new()
	calm.init_crosswind(WindField.Strength.NONE, 7)
	t.ok(not calm.windy, "none is calm")
	t.ok(calm.flight_force() == Vector3.ZERO, "and pushes nothing")

	var light_sum: float = 0.0
	var strong_sum: float = 0.0
	for s: int in 20:
		var light := WindField.new()
		var strong := WindField.new()
		light.init_crosswind(WindField.Strength.LIGHT, s)
		strong.init_crosswind(WindField.Strength.STRONG, s)
		t.ok(light.windy and strong.windy, "light and strong blow (seed %d)" % s)
		t.ok(not light.drives_drag() and not strong.drives_drag(),
			"and neither goes through ETR's drag (seed %d)" % s)
		for i: int in 600:
			light.update(DT)
			strong.update(DT)
			light_sum += light.speed()
			strong_sum += strong.speed()
			if light.speed() > 35.0 + 1e-3 or strong.speed() > 85.0 + 1e-3:
				t.ok(false, "a gust stays under its strength's top speed (seed %d)" % s)
				break
	t.ok(strong_sum > light_sum * 2.0,
		"strong blows well over twice as hard as light on average (%.0f vs %.0f)"
		% [strong_sum / 12000.0, light_sum / 12000.0])

	var etr := WindField.new()
	etr.init_wind(2, 5)
	t.ok(etr.drives_drag() and etr.flight_force() == Vector3.ZERO,
		"ETR's grades keep their drag and gain no flight push")

	t.ok(WindField.parse_strength("strong") == WindField.Strength.STRONG, "parses a word")
	t.ok(WindField.parse_strength("1") == WindField.Strength.LIGHT, "and a number")
	t.ok(WindField.parse_strength("gale") == WindField.Strength.NONE, "and calms nonsense")
	t.ok(WindField.strength_of(9) == WindField.Strength.NONE, "out of range is calm")

## Left or right, from the seed, and it stays on that side.
static func _side(t: TestCase) -> void:
	t.begin("wind/side")
	var seen := {}
	for s: int in 40:
		var w := WindField.new()
		w.init_crosswind(WindField.Strength.STRONG, s)
		seen[w.side] = true
		var across: bool = true
		for i: int in 900:
			w.update(DT)
			if w.speed() > 1.0 and signf(w.vector.x) != float(w.side):
				across = false
			if absf(w.vector.z) > absf(w.vector.x):
				across = false
		t.ok(across, "seed %d blows across the hill from its own side the whole way" % s)
	t.ok(seen.has(1) and seen.has(-1), "both sides come up across seeds")

	var a := WindField.new()
	var b := WindField.new()
	a.init_crosswind(WindField.Strength.LIGHT, 1234)
	b.init_crosswind(WindField.Strength.LIGHT, 1234)
	for i: int in 300:
		a.update(DT)
		b.update(DT)
	t.ok(a.side == b.side, "one seed, one side")
	t.eq_f(a.speed(), b.speed(), 1e-9, "and the same gusts")

static func _sim(level: WindField.Strength, seed_value: int) -> RacePhysics:
	var p := RacePhysics.new()
	p.surface = SlopeFixture.flat_slope(20.0)
	p.play_min_x = 2.5
	p.play_max_x = 87.5
	p.play_length = 470.0
	p.init_at(45.0, -5.0)
	p.wind.init_crosswind(level, seed_value)
	return p

## On the ground the crosswind is not a force at all: the same run, to the bit.
static func _ground_is_untouched(t: TestCase) -> void:
	t.begin("wind/ground")
	var calm: RacePhysics = _sim(WindField.Strength.NONE, 3)
	var windy: RacePhysics = _sim(WindField.Strength.STRONG, 3)
	var input := RaceInput.new()
	var was_airborne: bool = false
	for i: int in 300:
		calm.step(input, DT)
		windy.step(input, DT)
		was_airborne = was_airborne or windy.airborne
	t.ok(not was_airborne, "the fixture never leaves the ground")
	t.eq_v(windy.pos, calm.pos, 1e-9, "a strong crosswind moves nobody on the ground")

## Thrown off the same ledge, a racer in a strong wind lands a little downwind.
static func _flight_drifts_downwind(t: TestCase) -> void:
	t.begin("wind/flight")
	for s: int in [1, 2]:
		var calm: RacePhysics = _sim(WindField.Strength.NONE, s)
		var windy: RacePhysics = _sim(WindField.Strength.STRONG, s)
		var input := RaceInput.new()
		for i: int in 60:
			calm.step(input, DT)
			windy.step(input, DT)
		# Up into the air, both of them, the same way.
		calm.pos.y += 4.0
		windy.pos.y += 4.0
		var flown: float = 0.0
		for i: int in 240:
			calm.step(input, DT)
			windy.step(input, DT)
			if windy.airborne:
				flown += DT
		var drift: float = (windy.pos.x - calm.pos.x) * float(windy.wind.side)
		t.ok(flown > 0.5, "the racer really flew (%.2f s)" % flown)
		t.between(drift, 0.3, 4.0,
			"seed %d: lands %.2f m downwind — noticeable, not a line taken away" % [s, drift])
		var heading: float = rad_to_deg(atan2(windy.vel.x, -windy.vel.z)) * float(windy.wind.side)
		t.ok(heading > rad_to_deg(atan2(calm.vel.x, -calm.vel.z)) * float(windy.wind.side),
			"seed %d: and comes down pointed a little downwind" % s)

static func _carried(t: TestCase) -> void:
	t.begin("wind/carried")
	var setup := RaceSetup.practice().in_wind(WindField.Strength.LIGHT, 42)
	var copy: RaceSetup = setup.copy()
	t.ok(copy.wind == WindField.Strength.LIGHT and copy.wind_seed == 42,
		"a copy keeps the wind and its seed")
	t.ok(RaceSetup.practice().wind_seed == RaceSetup.ROLL_WIND_SEED,
		"a fresh setup rolls its side on every start")
	t.ok(setup.matches(RaceSetup.practice()), "the wind is weather, not the field")
	t.ok(setup.describe().contains("light wind"), "and says so in the log line")

	var lobby := LobbyServer.new()
	lobby.add_peer(1, "admin", "tux")
	var id: int = int(lobby.create_room(1, "Windy", "", "bunny_hill", 0, 0,
		WindField.Strength.STRONG)["room"])
	var room: LobbyServer.Room = lobby.rooms[id]
	t.ok(room.wind == WindField.Strength.STRONG, "a room carries its wind")
	t.ok(int(lobby.room_state(room)["wind"]) == WindField.Strength.STRONG,
		"and tells the people in it")
	lobby.set_course(1, "tuxway", 0, 0, 7)
	t.ok(room.wind == WindField.Strength.NONE, "an unknown strength is calm")
	t.ok(bool(lobby.start_race(1)["ok"]), "the race starts")
	t.ok(room.wind_seed >= 0, "with one seed, rolled by the server, for everybody")
