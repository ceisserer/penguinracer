## One race entry from `events.lst`. The herring and time thresholds are tuned
## difficulty data and are migrated verbatim — they are expensive to recreate
## and the whole medal curve depends on them.
@tool
class_name RaceEvent
extends Resource

@export var id: StringName = &""
@export var course_group: String = "default"
@export var course_dir: String = ""
@export var course: CourseData
## sunny / cloudy / evening / night.
@export var light: StringName = &"sunny"
@export_range(0, 3) var snow: int = 0
@export_range(0, 3) var wind: int = 0
## Herring needed for bronze / silver / gold.
@export var herring: Vector3i = Vector3i.ZERO
## Seconds allowed for bronze / silver / gold.
@export var time: Vector3 = Vector3.ZERO
@export var music_theme: StringName = &"normal"

## 3 = gold, 2 = silver, 1 = bronze, 0 = no medal.
func medal_for(collected: int, seconds: float) -> int:
	if collected >= herring.z and seconds <= time.z: return 3
	if collected >= herring.y and seconds <= time.y: return 2
	if collected >= herring.x and seconds <= time.x: return 1
	return 0
