## The player's best run per course, on disk.
##
## `user://ghosts/<course>.res` beside `penguinracer.cfg`, one file per course,
## overwritten whenever a faster completed run comes in. Binary rather than the
## commented text [GameConfig] writes, because unlike the settings file there is
## nothing here to hand-edit: it is a hundred kilobytes of float32 poses.
##
## Only completed runs are stored. An abandoned run has no time to compare and a
## ghost that stops halfway up the hill is worse than no ghost.
class_name GhostStore
extends RefCounted

const DIR := "user://ghosts"

static func path_for(course_dir: String) -> String:
	return "%s/%s.res" % [DIR, course_dir]

## The stored ghost for [param course_dir], or `null`.
##
## [constant ResourceLoader.CACHE_MODE_IGNORE] because this file is rewritten
## while the game is running: the cached copy from the start of the race is the
## run the player has just beaten, and the next race would load it back.
##
## A file that fails to load, or that was written by another format version, is
## dropped silently. A corrupt ghost is not something to interrupt a race over.
static func load_for(course_dir: String) -> RaceRecording:
	var path: String = path_for(course_dir)
	if not FileAccess.file_exists(path):
		return null
	# No type hint: [ResourceLoader] checks one against [ClassDB], which knows
	# nothing about a script class, and the load fails outright rather than
	# falling back. The cast below is the check.
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var rec: RaceRecording = res as RaceRecording
	if rec == null or not rec.is_playable_on(course_dir):
		return null
	return rec

## Store [param recording] if it beats what is there. Returns whether it landed.
static func save_if_best(recording: RaceRecording) -> bool:
	if recording == null or not recording.completed or recording.course_dir.is_empty():
		return false
	if recording.pose_count() < 2:
		return false
	var previous: RaceRecording = load_for(recording.course_dir)
	if previous != null and previous.total_time <= recording.total_time:
		return false
	return save(recording)

## Write [param recording] out, best or not. Split from [method save_if_best] so
## a test can put a known ghost in place without racing for it.
static func save(recording: RaceRecording) -> bool:
	if not DirAccess.dir_exists_absolute(DIR):
		var err: Error = DirAccess.make_dir_recursive_absolute(DIR)
		if err != OK:
			push_warning("could not create %s (error %d)" % [DIR, err])
			return false
	var err: Error = ResourceSaver.save(recording, path_for(recording.course_dir))
	if err != OK:
		push_warning("could not write ghost for %s (error %d)"
			% [recording.course_dir, err])
		return false
	return true

## Forget the ghost for one course. Nothing calls this yet — it is what a
## "clear best time" control would call, and it is here so that the tests can
## leave the user directory as they found it.
static func erase(course_dir: String) -> void:
	var path: String = path_for(course_dir)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
