## Minimal assertion helpers for the headless suite. Deliberately tiny — the
## simulation is the thing under test, not the harness.
class_name TestCase
extends RefCounted

var passed: int = 0
var failed: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _current: String = ""

func begin(name: String) -> void:
	_current = name

func ok(condition: bool, message: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		_failures.push_back("%s: %s" % [_current, message])

func eq_f(actual: float, expected: float, tolerance: float, message: String) -> void:
	var good: bool = absf(actual - expected) <= tolerance
	if not good:
		message = "%s (expected %.6f ± %.6f, got %.6f)" % [message, expected, tolerance, actual]
	ok(good, message)

func eq_v(actual: Vector3, expected: Vector3, tolerance: float, message: String) -> void:
	var good: bool = actual.distance_to(expected) <= tolerance
	if not good:
		message = "%s (expected %v ± %.6f, got %v)" % [message, expected, tolerance, actual]
	ok(good, message)

func between(actual: float, lo: float, hi: float, message: String) -> void:
	var good: bool = actual >= lo and actual <= hi
	if not good:
		message = "%s (expected %.6f..%.6f, got %.6f)" % [message, lo, hi, actual]
	ok(good, message)

func failures() -> PackedStringArray:
	return _failures
