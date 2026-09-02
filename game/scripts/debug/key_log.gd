## Keyboard delivery probe — run this over a remote-desktop session to find out
## whether held keys survive the trip.
##
##     godot --path game res://scenes/key_log.tscn
##
## Why it exists: the race polls steering with `Input.is_action_pressed()` (a
## level: true from press until release) while restart uses
## `Input.is_action_just_pressed()` (an edge: true for the one frame the press
## landed in). Godot latches the edge even when the release arrives in the same
## inter-frame gap, so a remote desktop that forwards a key as a zero-length
## down/up pulse — RustDesk's translate/legacy keyboard mode does exactly that —
## leaves `r` working and WASD/space doing nothing at all. This prints both
## views side by side so that guess can be settled by looking.
extends Node

## A press that never survived to the next frame poll.
var _pulses: int = 0
## A press the next frame poll still saw held.
var _holds: int = 0
var _events: int = 0
var _press_usec: Dictionary[int, int] = {}
## Keycodes pressed since the last poll, waiting to be classified.
var _pending: Array[int] = []
var _lines: PackedStringArray = []
var _label: Label

const WATCHED := ["steer_left", "steer_right", "paddle", "brake", "jump",
	"trick_modifier", "reset_race", "menu"]

func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 16)
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.offset_left = 12.0
	_label.offset_top = 8.0
	layer.add_child(_label)
	_say("PenguinRacer keyboard probe — hold W, A, S, D and space for a second each, then tap r.")
	_say("")

func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null:
		return
	_events += 1
	var now: int = Time.get_ticks_usec()
	var name: String = OS.get_keycode_string(key.keycode if key.keycode != 0 else key.physical_keycode)
	if key.pressed and not key.echo:
		_press_usec[key.keycode] = now
		_pending.append(key.keycode)
		_say("%7.3f s  DOWN %-8s keycode=%d physical=%d unicode=%d%s" % [
			now / 1e6, name, key.keycode, key.physical_keycode, key.unicode,
			"  [modifiers]" if key.get_modifiers_mask() != 0 else ""])
	elif key.pressed and key.echo:
		_say("%7.3f s  ECHO %-8s (autorepeat)" % [now / 1e6, name])
	else:
		var held_ms: float = -1.0
		if _press_usec.has(key.keycode):
			held_ms = (now - int(_press_usec[key.keycode])) / 1000.0
		_say("%7.3f s  UP   %-8s after %.1f ms" % [now / 1e6, name, held_ms])

func _process(_delta: float) -> void:
	# Classify last frame's presses the way the game would see them: anything
	# already released by the time the poll runs can never drive steering.
	for keycode: int in _pending:
		if Input.is_key_pressed(keycode as Key):
			_holds += 1
		else:
			_pulses += 1
			_say("           ^ released before the next frame poll — a zero-length pulse")
	_pending.clear()

	var held: PackedStringArray = []
	var edges: PackedStringArray = []
	for action: String in WATCHED:
		if Input.is_action_pressed(action):
			held.append(action)
		if Input.is_action_just_pressed(action):
			edges.append(action)
	if not edges.is_empty():
		_say("           frame poll: just_pressed=%s  pressed=%s" % [
			", ".join(edges), ", ".join(held) if not held.is_empty() else "(nothing)"])

	_label.text = "\n".join(_lines) + "\n\n" + _verdict(held)

func _verdict(held: PackedStringArray) -> String:
	var lines: PackedStringArray = []
	lines.append("held right now: %s" % [", ".join(held) if not held.is_empty() else "(nothing)"])
	lines.append("key events: %d    presses that survived to a frame poll: %d    zero-length pulses: %d" % [
		_events, _holds, _pulses])
	if _pulses > 0 and _holds == 0:
		lines.append("")
		lines.append("VERDICT: no press ever survived to the next frame. The keyboard is being")
		lines.append("forwarded as down/up pulses, so every held control (WASD, space, ctrl) is dead")
		lines.append("while every edge-triggered one (r, Esc, menu keys) works. In RustDesk this is")
		lines.append("the keyboard mode: switch the session from Legacy/Translate to Map mode. If that")
		lines.append("is not available, `godot --path game -- --remote-keyboard` bridges the pulses.")
	elif _holds > 0 and _pulses == 0 and _events > 0:
		lines.append("")
		lines.append("VERDICT: presses arrive held. Key delivery is not the problem — look elsewhere.")
	return "\n".join(lines)

func _say(line: String) -> void:
	print(line)
	_lines.append(line)
	if _lines.size() > 24:
		_lines.remove_at(0)

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		Audio.quit_game(0)
