## Lightning in a thunderstorm: a strike every few seconds somewhere ahead of
## the camera, flickering in a few quick return strokes, lighting the cloud
## deck from inside and — for as long as it lasts — the whole hill.
##
## DEVIATION: ETR has no storm (see [constant LightCondition.Kind.THUNDERSTORM]).
##
## [b]The hill is lit by the sun.[/b] Every lit shader sums its lights and the
## ambient inside ETR's clamp (`etr_illumination.gdshaderinc`), and each
## `light()` call adds the ambient again, so a second light would light the
## hill twice over. The flash is added to the one [DirectionalLight3D] instead,
## turned toward the strike as the flash outshines the sky's own light: the
## terrain, the trees, the objects and the racers all flash together and stay
## inside the clamp. The storm casts no shadows, so moving the light moves
## nothing else. The sky reads the same flash from two globals, `atmo_flash`
## and `atmo_bolt` (`atmosphere.gdshaderinc`), and since the haze in front of a
## far slope is the sky's colour, the far terrain flashes with it.
##
## [b]Presentation only[/b], like [Atmosphere]: it runs on the frame's clock,
## from a seed, so a `--fixed-fps` capture is reproducible and nothing in the
## simulation can tell a storm from a cloudy day.
class_name Lightning
extends RefCounted

## Seconds before the first strike, and between one strike and the next.
const FIRST_STRIKE := Vector2(2.0, 5.0)
const INTERVAL := Vector2(3.5, 11.0)
## Return strokes in one strike, and the seconds between them.
const STROKES := Vector2i(1, 4)
const STROKE_GAP := Vector2(0.05, 0.18)
## A stroke's rise and its e-folding decay, in seconds. Fast in, slower out:
## the afterglow is what the eye keeps.
const RISE := 0.012
const DECAY := 0.075
## How far either side of where the camera looks a strike may land, radians.
## Wide enough that some strikes are only a flash at the edge of the frame.
const SPREAD := 1.0
## How often a strike shows its channel; the rest is sheet lightning, lit
## inside the cloud.
const BOLT_CHANCE := 0.65
## How much a strike at full strength adds to the sky, and to the light on the
## hill — both linear. The hill's is enough to lift the storm's lit snow to
## about where a sunny day has it, briefly, and blue-white.
const SKY_FLASH := Color(0.55, 0.58, 0.72)
const LIGHT_FLASH := Color(0.80, 0.86, 1.05)
## How steeply the flash comes down onto the hill: the light is from the cloud
## over the strike, not from the horizon.
const FLASH_ELEVATION := 1.6

## Whether this sky has lightning at all ([constant Atmosphere.LOOKS]'s
## `lightning`).
var active: bool = false
## The flash now, 0..1.
var intensity: float = 0.0

var _rng := RandomNumberGenerator.new()
var _clock: float = 0.0
var _next_strike: float = 0.0
## The current strike's strokes, as (start, peak).
var _strokes: Array[Vector2] = []
## Where the current strike is, flat, and whether its channel shows.
var _toward := Vector2(0.0, -1.0)
var _bolt_seed: float = 0.0
var _bolt_shown: float = 0.0
## The light as the preset gives it: linear colour and direction.
var _sun: DirectionalLight3D
var _base_color := Color.BLACK
var _base_dir := Vector3.UP
## What was last written, so a quiet frame writes nothing.
var _written: float = -1.0

## Start the storm, or stop it, for [param preset] with [param sun] already lit
## by it ([method EnvironmentPreset.apply_sun]). [param seed] fixes every
## strike, so the same course has the same storm.
func start(sun: DirectionalLight3D, preset: EnvironmentPreset, seed: int) -> void:
	active = preset != null and float(Atmosphere.look_for(preset)["lightning"]) > 0.0
	_sun = sun
	intensity = 0.0
	_strokes.clear()
	_clock = 0.0
	_written = -1.0
	if not active:
		return
	_base_color = EnvironmentPreset.as_light_color(preset.sun_color, preset.sun_gain) \
		.srgb_to_linear()
	_base_dir = preset.sun_direction.normalized()
	_rng.seed = seed
	_next_strike = _rng.randf_range(FIRST_STRIKE.x, FIRST_STRIKE.y)

## Advance by [param delta] seconds, with the camera looking along
## [param forward], and flash the sky and the light.
func advance(delta: float, forward: Vector3) -> void:
	if not active:
		return
	_clock += delta
	if _clock >= _next_strike:
		_strike(forward)
	intensity = envelope(_strokes, _clock)
	if intensity == _written:
		return
	_written = intensity
	_apply()

## How bright [param strokes] ((start, peak) each) are together at time
## [param t]: each rises in [constant RISE] and decays over [constant DECAY],
## and the sum clips at 1. Pure, for the tests.
static func envelope(strokes: Array[Vector2], t: float) -> float:
	var sum: float = 0.0
	for stroke: Vector2 in strokes:
		var age: float = t - stroke.x
		if age < 0.0:
			continue
		var rise: float = minf(age / RISE, 1.0)
		var tail: float = exp(-maxf(age - RISE, 0.0) / DECAY)
		if tail < 0.002:
			continue
		sum += stroke.y * rise * tail
	return minf(sum, 1.0)

func _strike(forward: Vector3) -> void:
	var flat := Vector2(forward.x, forward.z)
	if flat.length_squared() < 1e-6:
		flat = Vector2(0.0, -1.0)
	_toward = flat.normalized().rotated(_rng.randf_range(-SPREAD, SPREAD))
	_bolt_shown = 1.0 if _rng.randf() < BOLT_CHANCE else 0.0
	_bolt_seed = _rng.randf_range(0.0, 100.0)
	# Near strikes and far ones: the whole strike at one strength.
	var strength: float = _rng.randf_range(0.45, 1.0)
	_strokes.clear()
	var at: float = _clock
	for i: int in range(_rng.randi_range(STROKES.x, STROKES.y)):
		_strokes.append(Vector2(at, strength * _rng.randf_range(0.5, 1.0)))
		at += _rng.randf_range(STROKE_GAP.x, STROKE_GAP.y)
	_next_strike = at + _rng.randf_range(INTERVAL.x, INTERVAL.y)

func _apply() -> void:
	var f: float = intensity
	var sky: Color = SKY_FLASH * f
	RenderingServer.global_shader_parameter_set(&"atmo_flash",
		Vector4(sky.r, sky.g, sky.b, f))
	RenderingServer.global_shader_parameter_set(&"atmo_bolt",
		Vector4(_toward.x, _toward.y, _bolt_seed, _bolt_shown * f))
	if _sun == null:
		return
	var flash: Color = LIGHT_FLASH * f
	var light: Color = _base_color + flash
	# A light's colour is a colour; how bright it is goes on the energy.
	var peak: float = maxf(maxf(light.r, light.g), maxf(light.b, 1e-4))
	_sun.light_color = Color(light.r / peak, light.g / peak, light.b / peak).linear_to_srgb()
	_sun.light_energy = peak
	# Turned toward the strike by as much of the light as the flash is.
	var share: float = _luminance(flash) / maxf(_luminance(light), 1e-4)
	var from_strike := Vector3(_toward.x, FLASH_ELEVATION, _toward.y).normalized()
	var dir: Vector3 = _base_dir.lerp(from_strike, share).normalized()
	_sun.look_at_from_position(Vector3.ZERO, -dir, Vector3.UP)

static func _luminance(c: Color) -> float:
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
