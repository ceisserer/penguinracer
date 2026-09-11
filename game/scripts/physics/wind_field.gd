## Wind state machine, ported from ETR `CWind` (particles.cpp).
##
## Lerps speed and angle toward randomly chosen targets on a 0.04 s tick.
## Feeds air drag in [RacePhysics] and (later) flake drift in the snowfall VFX.
## Seeded so headless tests are deterministic — the original used global rand().
class_name WindField
extends RefCounted

const UPDATE_TIME := 0.04

var windy: bool = false
var vector: Vector3 = Vector3.ZERO

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

## `wind_id` 0 = calm, 1..3 = the original's wind grades.
func init_wind(wind_id: int, seed_value: int = 0) -> void:
	_rng.seed = seed_value
	if wind_id < 1 or wind_id > 3:
		windy = false
		vector = Vector3.ZERO
		_w_angle = 0.0
		_w_speed = 0.0
		return
	windy = true
	_set_params(wind_id - 1)
	_w_speed = _rand(_min_speed, (_min_speed + _max_speed) / 2.0)
	_w_angle = _rand(_min_angle, _max_angle)
	_calc_dest_speed()
	_calc_dest_angle()

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

	var xx: float = sin(deg_to_rad(_w_angle))
	var zz: float = sqrt(maxf(0.0, 1.0 - xx * xx))
	if (_w_angle > 90.0 and _w_angle < 270.0) or (_w_angle > 450.0 and _w_angle < 630.0):
		zz = -zz
	vector = Vector3(_w_speed * xx, 0.0, _w_speed * zz * 0.2)
