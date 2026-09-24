## Wind state machine, ported from ETR `CWind` (particles.cpp).
##
## Lerps speed and angle toward randomly chosen targets on a 0.04 s tick.
## Seeded so headless tests are deterministic — the original used global rand().
##
## Two ways in, and they differ in what the wind is allowed to do to a racer:
##
## - [method init_wind] is ETR's: a `wind_id` grade 1..3 that blows from
##   anywhere its tables allow and feeds [RacePhysics]'s air drag through
##   [constant PhysConst.WIND_FACTOR] on the ground and in the air alike —
##   30–100 units of crosswind, which is a hard course. Only `--wind=` asks.
## - [method init_crosswind] is the course screen's: [enum Strength] NONE,
##   LIGHT or STRONG, blowing across the hill from one side picked by the seed,
##   gusting on the same state machine. It sways the trees, drives the snow and
##   shows on the HUD's rose like ETR's, but only nudges a racer [i]in flight[/i]
##   ([method flight_force]); the drag stays ETR's still-air drag.
class_name WindField
extends RefCounted

const UPDATE_TIME := 0.04

## The course screen's wind. The values are what is stored in the settings
## file, carried on a lobby room and recorded with a run, so they are not
## renumbered.
enum Strength { NONE, LIGHT, STRONG }
const STRENGTHS: Array[Strength] = [Strength.NONE, Strength.LIGHT, Strength.STRONG]
const _STRENGTH_NAMES: Array[String] = ["none", "light", "strong"]
const _STRENGTH_LABELS: Array[String] = ["None", "Light", "Strong"]

## Metres per second squared of sideways push in flight per unit of wind
## [method speed]. A jump is around a second in the air, so a strong wind
## (~50) drifts a racer a metre or so downwind over one — enough to lean into,
## never enough to take a line away. DEVIATION: ETR has no flight-only term; its
## wind goes through the drag everywhere (see the class note).
const FLIGHT_ACCEL_PER_SPEED := 0.04

var windy: bool = false
var vector: Vector3 = Vector3.ZERO
## The course screen's [enum Strength], or NONE for calm and for an ETR grade.
var strength: Strength = Strength.NONE
## +1 when the crosswind blows toward `+x` — from the left, as a racer facing
## downhill (`-z`) sees it — and -1 from the right. Zero when there is none.
var side: int = 0
## What the field was seeded with, so a recording can say which wind it ran in.
var seed_used: int = 0

var _rng := RandomNumberGenerator.new()
var _curr_time: float = 0.0
var _speed_mode: int = 0
var _angle_mode: int = 0
var _w_speed: float = 0.0
var _w_angle: float = 0.0
var _dest_speed: float = 0.0
var _dest_angle: float = 0.0
var _wind_change: float = 0.0
var _angle_change: float = 0.0

# TWindParams
var _min_speed: float = 0.0
var _max_speed: float = 0.0
var _min_change: float = 0.0
var _max_change: float = 0.0
var _min_angle: float = 0.0
var _max_angle: float = 0.0
var _min_angle_change: float = 0.0
var _max_angle_change: float = 0.0
var _top_speed: float = 0.0
var _top_probability: float = 0.0
var _null_probability: float = 0.0

func _rand(a: float, b: float) -> float:
	return _rng.randf_range(a, b)

## Where the wind is blowing, in degrees from `+z` toward `+x`. `CWind::Angle`.
## The HUD's wind rose is the only thing that asks: the physics wants
## [member vector], which is this and [method speed] resolved.
func angle() -> float:
	return _w_angle

## How hard it is blowing. `CWind::Speed`. Not the length of [member vector] —
## that one has the original's 0.2 weight on the `z` component in it.
func speed() -> float:
	return _w_speed

## Whether this wind goes through the air drag, as ETR's does. False for a
## crosswind from the course screen, which pushes only in flight.
func drives_drag() -> bool:
	return windy and strength == Strength.NONE

## `wind_id` 0 = calm, 1..3 = the original's wind grades.
func init_wind(wind_id: int, seed_value: int = 0) -> void:
	_calm(seed_value)
	if wind_id < 1 or wind_id > 3:
		return
	windy = true
	_set_params(wind_id - 1)
	_start()

## The course screen's wind: calm, or a crosswind of [param level] from a side
## the seed picks. Every racer in a race is given the same seed, so they all
## feel the same gusts from the same side.
func init_crosswind(level: Strength, seed_value: int) -> void:
	_calm(seed_value)
	if level == Strength.NONE:
		return
	windy = true
	strength = level
	side = 1 if _rng.randf() < 0.5 else -1
	_set_crosswind_params(level)
	_start()

## Sideways push in flight, in newtons: along the wind, level, and zero on the
## ground and for anything but a course-screen crosswind.
func flight_force() -> Vector3:
	if not windy or strength == Strength.NONE:
		return Vector3.ZERO
	return Vector3(vector.x, 0.0, vector.z) * (PhysConst.TUX_MASS * FLIGHT_ACCEL_PER_SPEED)

func _calm(seed_value: int) -> void:
	_rng.seed = seed_value
	seed_used = seed_value
	windy = false
	strength = Strength.NONE
	side = 0
	vector = Vector3.ZERO
	_w_angle = 0.0
	_w_speed = 0.0
	_curr_time = 0.0

func _start() -> void:
	_w_speed = _rand(_min_speed, (_min_speed + _max_speed) / 2.0)
	_w_angle = _rand(_min_angle, _max_angle)
	_calc_dest_speed()
	_calc_dest_angle()
	# Resolved now rather than on the first 0.04 s update, so the first frame
	# of a race already sways the trees and drives the snow.
	_resolve_vector()

## Tables in the shape of [method _set_params], for a wind that stays across
## the hill: within 15° of square to the fall line, on [member side]'s side.
## Speeds are in the same units the HUD's rose prints.
func _set_crosswind_params(level: Strength) -> void:
	var base_speed: float
	var speed_var: float
	if level == Strength.LIGHT:
		base_speed = _rand(12.0, 20.0)
		speed_var = 12.0
		_min_change = 0.05; _max_change = 0.3
		_top_speed = 35.0; _top_probability = 0.0; _null_probability = 8.0
	else:
		base_speed = _rand(40.0, 55.0)
		speed_var = 30.0
		_min_change = 0.1; _max_change = 0.8
		_top_speed = 85.0; _top_probability = 8.0; _null_probability = 2.0
	_min_speed = maxf(0.0, base_speed - speed_var / 2.0)
	_max_speed = minf(_top_speed, base_speed + speed_var / 2.0)
	var toward: float = 90.0 if side > 0 else 270.0
	_min_angle = toward - 15.0
	_max_angle = toward + 15.0
	_min_angle_change = 0.05; _max_angle_change = 0.5

static func strength_name(level: Strength) -> String:
	return _STRENGTH_NAMES[clampi(level, 0, _STRENGTH_NAMES.size() - 1)]

## What the course screen and the lobby call a strength. Literals, not `tr()`
## keys, for the reason [CourseMenu] gives for the snow's.
static func strength_label(level: Strength) -> String:
	return _STRENGTH_LABELS[clampi(level, 0, _STRENGTH_LABELS.size() - 1)]

## [param value] as a [enum Strength], NONE for anything out of range — a room
## from another build, a hand-edited settings file.
static func strength_of(value: int) -> Strength:
	return (value as Strength) if value >= 0 and value < STRENGTHS.size() else Strength.NONE

## A settings-file or command-line word, or its number. NONE if it is neither.
static func parse_strength(text: String) -> Strength:
	var word: String = text.strip_edges().to_lower()
	var at: int = _STRENGTH_NAMES.find(word)
	if at >= 0:
		return STRENGTHS[at]
	return strength_of(word.to_int()) if word.is_valid_int() else Strength.NONE

func _set_params(grade: int) -> void:
	var min_base_speed: float = 0.0
	var max_base_speed: float = 0.0
	var min_speed_var: float = 0.0
	var max_speed_var: float = 0.0
	var min_base_angle: float = 0.0
	var max_base_angle: float = 0.0
	var min_angle_var: float = 0.0
	var max_angle_var: float = 0.0
	var alt_angle: float = 0.0

	if grade == 0:
		min_base_speed = 20.0; max_base_speed = 35.0
		min_speed_var = 20.0; max_speed_var = 20.0
		_min_change = 0.1; _max_change = 0.3
		min_base_angle = 70.0; max_base_angle = 110.0
		min_angle_var = 0.0; max_angle_var = 90.0
		_min_angle_change = 0.1; _max_angle_change = 1.0
		_top_speed = 100.0; _top_probability = 0.0; _null_probability = 6.0
		alt_angle = 180.0
	elif grade == 1:
		min_base_speed = 30.0; max_base_speed = 60.0
		min_speed_var = 40.0; max_speed_var = 40.0
		_min_change = 0.1; _max_change = 0.5
		min_base_angle = 70.0; max_base_angle = 110.0
		min_angle_var = 0.0; max_angle_var = 90.0
		_min_angle_change = 0.1; _max_angle_change = 1.0
		_top_speed = 100.0; _top_probability = 0.0; _null_probability = 10.0
		alt_angle = 180.0
	else:
		min_base_speed = 40.0; max_base_speed = 80.0
		min_speed_var = 30.0; max_speed_var = 60.0
		_min_change = 0.1; _max_change = 1.0
		min_base_angle = 0.0; max_base_angle = 180.0
		min_angle_var = 180.0; max_angle_var = 360.0
		_min_angle_change = 0.1; _max_angle_change = 1.0
		_top_speed = 100.0; _top_probability = 10.0; _null_probability = 10.0
		alt_angle = 0.0

	var speed: float = _rand(min_base_speed, max_base_speed)
	var variance: float = _rand(min_speed_var, max_speed_var) / 2.0
	_min_speed = maxf(0.0, speed - variance)
	_max_speed = minf(100.0, speed + variance)

	var angle: float = _rand(min_base_angle, max_base_angle)
	if _rand(0.0, 100.0) > 50.0:
		angle += alt_angle
	variance = _rand(min_angle_var, max_angle_var) / 2.0
	_min_angle = angle - variance
	_max_angle = angle + variance

func _calc_dest_speed() -> void:
	var r: float = _rand(0.0, 100.0)
	if r > (100.0 - _top_probability):
		_dest_speed = _rand(_max_speed, _top_speed)
		_wind_change = _max_change
	elif r < _null_probability:
		_dest_speed = 0.0
		_wind_change = _rand(_min_change, _max_change)
	else:
		_dest_speed = _rand(_min_speed, _max_speed)
		_wind_change = _rand(_min_change, _max_change)
	_speed_mode = 1 if _dest_speed > _w_speed else 0

func _calc_dest_angle() -> void:
	_dest_angle = _rand(_min_angle, _max_angle)
	_angle_change = _rand(_min_angle_change, _max_angle_change)
	_angle_mode = 1 if _dest_angle > _w_angle else 0

func update(timestep: float) -> void:
	if not windy:
		return
	_curr_time += timestep
	if _curr_time <= UPDATE_TIME:
		return
	_curr_time = 0.0

	if _speed_mode == 1:
		if _w_speed < _dest_speed: _w_speed += _wind_change
		else: _calc_dest_speed()
	else:
		if _w_speed > _dest_speed: _w_speed -= _wind_change
		else: _calc_dest_speed()
	_w_speed = clampf(_w_speed, 0.0, _top_speed)

	if _angle_mode == 1:
		if _w_angle < _dest_angle: _w_angle += _angle_change
		else: _calc_dest_angle()
	else:
		if _w_angle > _dest_angle: _w_angle -= _angle_change
		else: _calc_dest_angle()
	_w_angle = clampf(_w_angle, _min_angle, _max_angle)
	_resolve_vector()

func _resolve_vector() -> void:
	var xx: float = sin(deg_to_rad(_w_angle))
	var zz: float = sqrt(maxf(0.0, 1.0 - xx * xx))
	if (_w_angle > 90.0 and _w_angle < 270.0) or (_w_angle > 450.0 and _w_angle < 630.0):
		zz = -zz
	vector = Vector3(_w_speed * xx, 0.0, _w_speed * zz * 0.2)
