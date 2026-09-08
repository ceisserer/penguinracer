## One row of ETR's `data/music/racing_themes.lst`: the three pieces a race can
## be in, selected by [enum Situation].
##
## A course names a theme, not a track ([member CourseData.music_theme],
## [member RaceEvent.music_theme]), which is what lets the same win and loss
## stings sit under three different racing tracks.
@tool
class_name MusicTheme
extends Resource

## `ESituation` in `audio.h`. Declared here rather than on [AudioDirector] so
## the resource layer does not have to reference the autoload — a cycle
## GDScript resolves badly.
enum Situation {
	RACE,
	WON,
	LOST,
}

@export var id: StringName = &""
## Paths rather than embedded [AudioStream]s — see [member MusicTrack.stream_path].
@export var race_path: String = ""
@export var won_path: String = ""
@export var lost_path: String = ""

func for_situation(situation: Situation) -> String:
	match situation:
		Situation.WON:
			return won_path
		Situation.LOST:
			return lost_path
	return race_path
