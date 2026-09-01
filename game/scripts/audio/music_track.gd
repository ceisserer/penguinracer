## One named piece from ETR's `data/music/music.lst`.
##
## The names are the stable identity — `racing_themes.lst`, `course.dim` and
## `events.lst` all refer to music by name — so they survive the migration
## unchanged even though the filenames carry the composers' initials.
@tool
class_name MusicTrack
extends Resource

@export var id: StringName = &""
@export var stream: AudioStream
