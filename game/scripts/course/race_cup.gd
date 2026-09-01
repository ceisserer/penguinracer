## A cup: an ordered set of races with an unlock chain.
@tool
class_name RaceCup
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
@export var races: Array[RaceEvent] = []
