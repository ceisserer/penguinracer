## Physics constants transcribed verbatim from Extreme Tux Racer 0.8.4 `src/physics.h`.
##
## These numbers *are* the game. Do not "clean them up" — a change here changes the
## feel of every course. See ../../../etracer.md §4.1.
class_name PhysConst
extends RefCounted

const MAX_PADDLING_SPEED := 60.0 / 3.6   ## m/s; paddling stops helping past this
const PADDLE_FACT := 1.0

const EARTH_GRAV := 9.81
const JUMP_FORCE_DURATION := 0.20
const TUX_MASS := 20.0
const MIN_TUX_SPEED := 1.4
const INIT_TUX_SPEED := 3.0
const COLL_TOLERANCE := 0.1

const MAX_SURF_PEN := 0.2
const TUX_Y_CORR := 0.36
const IDEAL_ROLL_SPEED := 6.0
const IDEAL_ROLL_FRIC := 0.35
const WIND_FACTOR := 1.5

const MIN_FRICT_SPEED := 2.8
const MAX_FRICT_FORCE := 800.0
const MAX_TURN_ANGLE := 45.0
const MAX_TURN_PERP := 400.0
const MAX_TURN_PEN := 0.15
const PADDLING_DURATION := 0.40
const IDEAL_PADD_FRIC := 0.35
const MAX_PADD_FORCE := 122.5
const BRAKE_FORCE := 200.0

const MIN_TIME_STEP := 0.01
const MAX_TIME_STEP := 0.10
const MAX_STEP_DIST := 0.20
const MAX_POS_ERR := 0.005
const MAX_VEL_ERR := 0.05

const MAX_ROLL_ANGLE := 30.0
const BRAKING_ROLL_ANGLE := 55.0

## Half-width of the character, used for particle emission points and the
## collision proxy radius (ETR: TUX_WIDTH / 2).
const TUX_WIDTH := 0.45

## Reynolds-number air-drag table (ETR physics.cpp). `airlog` is log10(Re),
## `airdrag` is log10(drag coefficient).
const AIRLOG: PackedFloat64Array = [-1.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
const AIRDRAG: PackedFloat64Array = [2.25, 1.35, 0.6, 0.0, -0.35, -0.45, -0.33, -0.9]

## ETR's `clamp(minimum, x, maximum)` macro: max(min(x, maximum), minimum).
## Note the argument order and that `minimum` wins when the bounds cross.
static func etr_clamp(minimum: float, x: float, maximum: float) -> float:
	return maxf(minf(x, maximum), minimum)

## Piecewise-linear interpolation matching ETR `LinearInterp` — extrapolates
## linearly off both ends of the table rather than clamping.
static func linear_interp(xs: PackedFloat64Array, ys: PackedFloat64Array, val: float) -> float:
	var n: int = xs.size()
	var i: int = 0
	if val < xs[0]:
		i = 0
	elif val >= xs[n - 1]:
		i = n - 2
	else:
		while i < n - 1 and val >= xs[i + 1]:
			i += 1
	var m: float = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
	var b: float = ys[i] - m * xs[i]
	return m * val + b
