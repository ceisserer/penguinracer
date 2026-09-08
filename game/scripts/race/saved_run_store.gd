## Runs the player chose to keep, on disk.
##
## `user://runs/<course>_<ticks>.res`, one file per save. Unlike the ghost
## store this replaced, nothing here is automatic and nothing is ever
## overwritten: a run only lands here when the results screen's Save button
## is pressed, under whatever name the player gave it, and it stays until
## [method delete] removes it. Binary rather than the commented text
## [GameConfig] writes, for the same reason the old store was — this is a
## few hundred kilobytes of float32 poses, not something to hand-edit.
class_name SavedRunStore
extends RefCounted

const DIR := "user://runs"

## One saved run as the list screen needs it: the recording itself and the
## path it lives at, since [RaceRecording] does not know its own filename and
## a delete button needs one.
class Entry extends RefCounted:
	var path: String
	var recording: RaceRecording

## Every saved run, most recently recorded first. A file that fails to load or
## does not cast to [RaceRecording] is skipped rather than surfaced — a
## corrupt save is not something to interrupt this screen over.
static func list_all() -> Array[Entry]:
	var out: Array[Entry] = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	for file_name: String in dir.get_files():
		if not file_name.ends_with(".res"):
			continue
		var path: String = "%s/%s" % [DIR, file_name]
		# No type hint: [ResourceLoader] checks one against [ClassDB], which
		# knows nothing about a script class, and the load fails outright
		# rather than falling back. The cast below is the check.
		var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var rec: RaceRecording = res as RaceRecording
		if rec == null or rec.format_version != RaceRecording.FORMAT_VERSION:
			continue
		var entry := Entry.new()
		entry.path = path
		entry.recording = rec
		out.push_back(entry)
	out.sort_custom(func(a: Entry, b: Entry) -> bool:
		return a.recording.recorded_unix > b.recording.recorded_unix)
	return out

## Save [param recording] under [param name]. Always writes a new file — there
## is no "best" here to replace, only runs the player asked to keep.
static func save(recording: RaceRecording, run_name: String) -> bool:
	if recording == null or not recording.completed or recording.course_dir.is_empty():
		return false
	if recording.pose_count() < 2:
		return false
	if not DirAccess.dir_exists_absolute(DIR):
		var err: Error = DirAccess.make_dir_recursive_absolute(DIR)
		if err != OK:
			push_warning("could not create %s (error %d)" % [DIR, err])
			return false
	recording.run_name = run_name
	var path: String = "%s/%s_%d.res" % [DIR, recording.course_dir, Time.get_ticks_usec()]
	var err: Error = ResourceSaver.save(recording, path)
	if err != OK:
		push_warning("could not write saved run to %s (error %d)" % [path, err])
		return false
	return true

## Forget one saved run.
static func delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
