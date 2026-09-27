## Which way is down, in the screen's own coordinates, on whatever this runs on.
##
## [TiltSteering] wants gravity with x to the right of the picture, y up it and
## z out of the glass, pointing at the ground. Getting that is different on
## every platform, and this is where the differences stop:
##
## - [b]Android (and iOS) builds[/b] ask [method Input.get_gravity], which the
##   engine already turns into the screen's frame for the display's rotation and
##   signs toward the ground. It is opt-in: `input_devices/sensors/enable_gravity`
##   and `enable_accelerometer` in `project.godot`, or it reads zero. Where a
##   device has no fused gravity sensor, the raw accelerometer is the fallback —
##   noisier, which [TiltSteering]'s filter is for.
## - [b]A browser[/b] gets nothing from the engine: Godot 4's web platform does
##   not feed the accelerometer, and [method Input.get_gravity] is zero there. So
##   [method install] puts a `devicemotion` listener on the page through
##   [JavaScriptBridge], and [method read] pulls its latest reading. Two things
##   differ from the native path and [method web_to_screen] fixes both: the
##   reading is in the device's [i]natural[/i] (portrait) frame, so it is turned
##   by the screen's orientation angle; and the spec's sign is the reaction
##   force — +9.8 up out of a phone lying face up — which iOS Safari
##   historically inverts, so the sign follows the platform.
##
## [b]The browser needs a gesture.[/b] iOS asks permission for motion data, and
## only from inside a real touch handler — a Godot input event is dispatched
## later, off the gesture, and would be refused. The installed script asks from
## its own `touchend` listener, and from the same one requests fullscreen and a
## landscape lock (the address bar otherwise takes a fifth of a phone's height).
## A page must also be a secure context for `devicemotion` to fire at all; the
## threaded web build needs HTTPS (or localhost) for COOP/COEP anyway.
##
## DEVIATION: ETR reads no sensors.
class_name MotionSensor
extends RefCounted

const WEB_OBJECT := "penguinTilt"

## Installed by [method install], idempotent on the page side too.
const WEB_SCRIPT := """
(function () {
	if (window.penguinTilt) return;
	var t = window.penguinTilt = { x: 0, y: 0, z: 0, angle: 0, events: 0, ios: false, asked: false };
	var ua = navigator.userAgent || '';
	t.ios = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
	function angle() {
		if (screen.orientation && typeof screen.orientation.angle === 'number') return screen.orientation.angle;
		return typeof window.orientation === 'number' ? window.orientation : 0;
	}
	window.addEventListener('devicemotion', function (e) {
		var g = e.accelerationIncludingGravity;
		if (!g || g.x === null || g.y === null || g.z === null) return;
		t.x = g.x; t.y = g.y; t.z = g.z; t.angle = angle(); t.events++;
	});
	function gesture() {
		if (!t.asked && typeof DeviceMotionEvent !== 'undefined'
				&& typeof DeviceMotionEvent.requestPermission === 'function') {
			t.asked = true;
			DeviceMotionEvent.requestPermission().catch(function () {});
		}
		var root = document.documentElement;
		if (!document.fullscreenElement && root.requestFullscreen) {
			root.requestFullscreen({ navigationUI: 'hide' }).then(function () {
				if (screen.orientation && screen.orientation.lock) {
					screen.orientation.lock('landscape').catch(function () {});
				}
			}).catch(function () {});
		}
	}
	window.addEventListener('touchend', gesture, { capture: true, passive: true });
})();
"""

static var _web: JavaScriptObject = null

## Put the listener on the page. Does nothing off the web; safe to call again.
static func install() -> void:
	if not OS.has_feature("web") or _web != null:
		return
	JavaScriptBridge.eval(WEB_SCRIPT, true)
	_web = JavaScriptBridge.get_interface(WEB_OBJECT)

## Gravity in the screen's frame, toward the ground, in whatever units the
## platform uses; [constant Vector3.ZERO] when nothing has been read.
static func read() -> Vector3:
	if OS.has_feature("web"):
		if _web == null or int(_web.events) == 0:
			return Vector3.ZERO
		return web_to_screen(Vector3(float(_web.x), float(_web.y), float(_web.z)),
			float(_web.angle), bool(_web.ios))
	var gravity: Vector3 = Input.get_gravity()
	if gravity == Vector3.ZERO:
		gravity = Input.get_accelerometer()
	return gravity

## A browser's `accelerationIncludingGravity`, in the device's natural frame, to
## gravity in the screen's frame. [param angle_deg] is `screen.orientation.angle`:
## how far the device is turned counter-clockwise from natural, which is also
## how far the picture is turned the other way to stay upright. Pure, so
## [TestTouch] can hold it to the native path's rotations.
static func web_to_screen(device: Vector3, angle_deg: float, ios: bool) -> Vector3:
	# The spec reports the reaction to gravity; iOS reports gravity itself.
	var down: Vector3 = device if ios else -device
	var a: float = deg_to_rad(angle_deg)
	return Vector3(down.x * cos(a) - down.y * sin(a),
		down.x * sin(a) + down.y * cos(a), down.z)
