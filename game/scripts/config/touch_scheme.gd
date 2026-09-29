## How a player without a keyboard races: which on-screen controls are drawn,
## and whether the device's tilt steers.
##
## Five schemes, `[controls] touch` in the settings file. Tilt has two halves —
## roll steers, pitch paddles and brakes ([TiltSteering]) — and each can be
## left to the device or to a pair of buttons:
##
## - **buttons** — nothing moves the device. Steering, paddling, braking, jump
##   and the trick modifier are all buttons. See [TouchControls].
## - **tilt_steer** — rolling the device steers (analogue); paddle and brake
##   are buttons.
## - **tilt_speed** — steering is buttons; tipping the top edge away paddles
##   and tipping it back brakes.
## - **tilt** — the phone is the steering wheel and the pedals both; only jump,
##   the trick modifier and the small taps are buttons. The phone's default.
## - **off** — no overlay at all, for a tablet with a keyboard or a gamepad.
##
## The enum's order is the settings screen's; the file stores the name, so a
## file written before the two mixed schemes still reads.
##
## [b]Whether any of this appears is the platform's question, not the file's.[/b]
## A desktop never draws the overlay and a phone always does (unless it says
## off): [method platform_is_mobile] asks Android and iOS directly, and a
## browser through the `web_android`/`web_ios` feature tags Godot sets from the
## user agent. `--touch` on the command line (`?touch` in the URL) forces it on
## a desktop, which is how the overlay is looked at without a phone, and may name
## a scheme for that run: `--touch=buttons`.
##
## DEVIATION: ETR is keyboard-only; nothing here is migrated.
##
## Names no autoload, so [GameConfig] — itself one — can reach for it without a
## parse cycle. See the trap list.
class_name TouchScheme
extends RefCounted

enum Kind { BUTTONS, TILT_STEER, TILT_SPEED, TILT, OFF }

## The file's spelling of each [enum Kind], in order.
const NAMES: PackedStringArray = ["buttons", "tilt_steer", "tilt_speed", "tilt", "off"]
## What the settings screen shows for each, in order — translation keys.
const LABELS: PackedStringArray = ["TOUCH_BUTTONS", "TOUCH_TILT_STEER", "TOUCH_TILT_SPEED",
	"TOUCH_TILT", "OPTION_OFF"]

static func parse(text: String, fallback: Kind = Kind.TILT) -> Kind:
	var index: int = NAMES.find(text.strip_edges().to_lower())
	return fallback if index < 0 else index as Kind

static func name_of(kind: Kind) -> String:
	return NAMES[kind]

## Whether the device's roll steers under [param kind].
static func tilt_steers(kind: Kind) -> bool:
	return kind == Kind.TILT or kind == Kind.TILT_STEER

## Whether the device's pitch paddles and brakes under [param kind].
static func tilt_speeds(kind: Kind) -> bool:
	return kind == Kind.TILT or kind == Kind.TILT_SPEED

## Whether [param kind] reads the sensor at all.
static func uses_tilt(kind: Kind) -> bool:
	return tilt_steers(kind) or tilt_speeds(kind)

## Whether this is a phone or a tablet: an Android or iOS build, or a browser
## running on one. A touch-screen laptop is not — it has a keyboard, and
## [method DisplayServer.is_touchscreen_available] cannot tell the two apart.
static func platform_is_mobile() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("web_android") \
		or OS.has_feature("web_ios")

## The scheme this run races with: [param configured] (the settings file) on a
## phone, [constant Kind.OFF] on a desktop, and whatever [param forced] says
## when it is set — `--touch` ("on": the configured scheme, or tilt where the
## file says off) or `--touch=<name>`, any of [constant NAMES].
##
## Pure, so [TestTouch] can walk the matrix without a phone.
static func resolve(configured: Kind, mobile: bool, forced: String) -> Kind:
	var wanted: String = forced.strip_edges().to_lower()
	if wanted.is_empty():
		return configured if mobile else Kind.OFF
	if wanted in NAMES:
		return parse(wanted)
	return Kind.TILT if configured == Kind.OFF else configured
