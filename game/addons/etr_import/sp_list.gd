## Parser for ETR's "SP list" format (`src/spx.cpp`) — the line-oriented
## `[tag] value` format behind every `.lst` and `.dim` file in the original.
##
## Read-only and import-time only. Nothing in the shipping game parses this;
## it exists so the migration is mechanical and re-runnable (plan §5.3).
@tool
class_name SPList
extends RefCounted

## Parse SP-list text into one dictionary of tag → raw string per record.
##
## Faithful to the original's quirks, which real data files depend on:
## a line starting with `*` opens a record and any following line is appended
## to it; a line starting with `#` is dropped entirely; and a value runs from
## after its `[tag]` to the next `[` or `#`, whichever comes first.
## `newline_mode` matches `CSPList(true)`: every line is its own record, with a
## trailing backslash continuing onto the next. Only `env/environment.lst` uses
## it in the original — and its records carry no leading `*`, so parsing it in
## the default mode silently merges every environment into the first one.
static func parse(text: String, newline_mode: bool = false) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var current: String = ""
	var have: bool = false
	var continued: bool = false
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.replace("\r", "")
		if line.is_empty() or line.begins_with("#"):
			continue
		if newline_mode:
			var forward: bool = line.ends_with("\\")
			if forward:
				line = line.substr(0, line.length() - 1)
			if continued and have:
				current += line
			else:
				if have:
					records.push_back(_parse_record(current))
				current = line
				have = true
			continued = forward
		elif line.begins_with("*") or not have:
			if have:
				records.push_back(_parse_record(current))
			current = line
			have = true
		else:
			current += line
	if have:
		records.push_back(_parse_record(current))
	return records

static func _parse_record(s: String) -> Dictionary:
	var out: Dictionary = {}
	var i: int = 0
	var n: int = s.length()
	while i < n:
		var open_pos: int = s.find("[", i)
		if open_pos < 0:
			break
		var close_pos: int = s.find("]", open_pos)
		if close_pos < 0:
			break
		var tag: String = s.substr(open_pos + 1, close_pos - open_pos - 1)
		var value_start: int = close_pos + 1
		var next_open: int = s.find("[", value_start)
		var next_hash: int = s.find("#", value_start)
		var value_end: int = n
		if next_open >= 0:
			value_end = next_open
		if next_hash >= 0 and next_hash < value_end:
			value_end = next_hash
		var value: String = s.substr(value_start, value_end - value_start).strip_edges()
		if not out.has(tag):
			out[tag] = value
		i = close_pos + 1
	return out

static func load_file(path: String, newline_mode: bool = false) -> Array[Dictionary]:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("SPList: cannot open %s" % path)
		return []
	var text: String = f.get_as_text()
	f.close()
	return parse(text, newline_mode)

# ------------------------------------------------------------ accessors

static func get_str(rec: Dictionary, tag: String, def: String = "") -> String:
	var v: String = rec.get(tag, "")
	return def if v.is_empty() else v

static func get_float(rec: Dictionary, tag: String, def: float = 0.0) -> float:
	var v: String = rec.get(tag, "")
	return def if v.is_empty() else v.to_float()

static func get_int(rec: Dictionary, tag: String, def: int = 0) -> int:
	var v: String = rec.get(tag, "")
	return def if v.is_empty() else v.to_int()

## `Str_BoolN` in the original also accepts the spelled-out forms, and one tag
## in the shipped data uses them: `env/environment.lst` writes
## `[high_res] true`, which parsed as an integer is 0 — so the etr location
## silently loaded its 512² skyboxes instead of the 1024² ones it ships.
static func get_bool(rec: Dictionary, tag: String, def: bool = false) -> bool:
	var v: String = rec.get(tag, "")
	if v.is_empty():
		return def
	if v == "true":
		return true
	if v == "false":
		return false
	return v.to_int() != 0

## Whitespace-separated numbers, e.g. `[col] 255 255 255`.
static func get_numbers(rec: Dictionary, tag: String) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var v: String = rec.get(tag, "")
	if v.is_empty():
		return out
	for part: String in v.split(" ", false):
		var p: String = part.strip_edges()
		if not p.is_empty():
			out.push_back(p.to_float())
	return out

static func get_color3(rec: Dictionary, tag: String, def: Color = Color.BLACK) -> Color:
	var n: PackedFloat64Array = get_numbers(rec, tag)
	if n.size() < 3:
		return def
	return Color(float(n[0]) / 255.0, float(n[1]) / 255.0, float(n[2]) / 255.0)
