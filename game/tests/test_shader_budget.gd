## Holds every 3D shader to the varying budget of the smallest GPU it ships on.
##
## Godot's Mobile renderer spends one whole varying slot per declaration — a
## `float` costs as much as a `vec4` — and keeps [constant ENGINE_SLOTS] of them
## for itself. The limit is the GPU's, `maxFragmentInputComponents / 4`: 32 on
## the desktop's Radeon, 28 on the Adreno 650 in a Poco F3. `terrain.gdshader`
## at 15 + 14 = 29 compiled everywhere but the phone, which logged
## "Too many varyings" and drew the whole course in the default material, white
## and grey by the sun. Nothing on the desktop can see that happen, so it is
## held here in writing: pack small varyings into a vec4 (terrain.gdshader
## names the components with #define).
class_name TestShaderBudget
extends RefCounted

const SHADER_DIR := "res://shaders"
## `actions.base_varying_index` in Godot's `scene_shader_forward_mobile.cpp`.
const ENGINE_SLOTS := 15
## The Adreno 650's 112 fragment input components, in slots.
const DEVICE_SLOTS := 28

static func run(t: TestCase) -> void:
	_the_counter_counts(t)
	_every_spatial_shader_fits(t)

static func _read(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()

## Slots declared by [param text], following its `#include`s. One per
## declaration, times the length of an array; commented-out lines do not count.
static func varying_slots(text: String) -> int:
	var decl := RegEx.create_from_string(
		"^\\s*(?:flat\\s+|smooth\\s+)?varying\\s+(?:\\w+\\s+)?\\w+\\s+\\w+\\s*(?:\\[(\\d+)\\])?\\s*;")
	var include := RegEx.create_from_string("^\\s*#include\\s+\"([^\"]+)\"")
	var slots: int = 0
	for line: String in text.split("\n"):
		var code: String = line.get_slice("//", 0)
		var inc: RegExMatch = include.search(code)
		if inc != null:
			slots += varying_slots(_read(inc.get_string(1)))
			continue
		var m: RegExMatch = decl.search(code)
		if m != null:
			slots += int(m.get_string(1)) if m.get_string(1) != "" else 1
	return slots

static func _the_counter_counts(t: TestCase) -> void:
	t.begin("shader budget/the counter")
	t.ok(varying_slots("varying float a;\nvarying vec4 b;") == 2,
		"a float costs a slot, the same as a vec4")
	t.ok(varying_slots("flat varying highp int c;\nvarying vec3 d[3];") == 4,
		"qualifiers are read past, an array costs its length")
	t.ok(varying_slots("// varying float e;\n#define f v.x\nuniform float varying_g;") == 0,
		"comments, aliases and look-alike names cost nothing")

static func _every_spatial_shader_fits(t: TestCase) -> void:
	t.begin("shader budget/every 3D shader fits an Adreno 650")
	var dir: DirAccess = DirAccess.open(SHADER_DIR)
	t.ok(dir != null, "%s opens" % SHADER_DIR)
	if dir == null:
		return
	var checked: int = 0
	for file: String in dir.get_files():
		if not file.ends_with(".gdshader"):
			continue
		var text: String = _read(SHADER_DIR.path_join(file))
		if not text.contains("shader_type spatial"):
			continue
		var used: int = ENGINE_SLOTS + varying_slots(text)
		t.ok(used <= DEVICE_SLOTS, "%s uses %d varying slots of %d" % [file, used, DEVICE_SLOTS])
		checked += 1
	t.ok(checked >= 5, "found the terrain, trees and objects (%d spatial shaders)" % checked)
