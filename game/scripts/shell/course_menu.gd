## Course selection screen — the first slice of the game shell (Phase 5).
##
## Draws over the running race rather than replacing it: the course behind the
## panel stays loaded and rendered, so opening the menu costs nothing and
## closing it resumes exactly where the player was. Picking a course hands a
## [CourseListing] back to [RaceScene], which swaps the course in place.
##
## Cups and events are imported and waiting in `res://resources/events/`; this
## screen only does free selection of a single course.
class_name CourseMenu
extends CanvasLayer

## A course was picked. The race scene loads it and hides the menu.
signal course_chosen(listing: CourseListing)
## The player dismissed the menu without choosing.
signal closed()

var _catalog: CourseCatalog
## The catalog rows that are actually present in this build. The `WebOneCourse`
## export ships one course against the full index; listing the other 43 would
## offer the player 43 dead ends.
var _entries: Array[CourseListing] = []

@onready var _list: ItemList = %CourseList
@onready var _title: Label = %Title
@onready var _result: Label = %Result
@onready var _preview: TextureRect = %Preview
@onready var _name: Label = %CourseName
@onready var _meta: Label = %Meta
@onready var _description: Label = %Description
@onready var _race_button: Button = %RaceButton
@onready var _continue_button: Button = %ContinueButton
@onready var _quit_button: Button = %QuitButton
@onready var _hint: Label = %Hint

func _ready() -> void:
	_catalog = CourseCatalog.load_default()
	_title.text = tr("SELECT_A_RACE")
	_race_button.text = tr("RACE")
	_continue_button.text = tr("CONTINUE")
	_quit_button.text = tr("QUIT")
	_hint.text = "↑↓  •  Enter: %s  •  Esc: %s" % [tr("RACE"), tr("BACK")]
	# The browser owns the tab; a quit button there does nothing useful.
	_quit_button.visible = not OS.has_feature("web")

	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(_on_item_activated)
	_race_button.pressed.connect(_race_selected)
	_continue_button.pressed.connect(close)
	_quit_button.pressed.connect(func() -> void: get_tree().quit(0))

	_fill_list()
	visible = false

func _fill_list() -> void:
	_list.clear()
	_entries.clear()
	for entry: CourseListing in _catalog.entries:
		if not ResourceLoader.exists(entry.scene_path):
			continue
		_entries.push_back(entry)
		_list.add_item(entry.title())

## Show the menu. `current_dir` is highlighted, `resumable` controls whether
## there is a race worth going back to, and `result_text` carries the summary
## of the race that just ended.
func open(current_dir: String, resumable: bool, result_text: String = "") -> void:
	_result.text = result_text
	_result.visible = not result_text.is_empty()
	_continue_button.visible = resumable
	visible = true
	var index: int = _index_of(current_dir)
	if index < 0 and not _entries.is_empty():
		index = 0
	if index >= 0:
		_list.select(index)
		_show_details(_entries[index])
		# Scrolling to the selection needs the list laid out, which has not
		# happened yet on the frame the menu becomes visible.
		_list.ensure_current_is_visible.call_deferred()
	_list.grab_focus()

func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()

func _index_of(dir_name: String) -> int:
	for i: int in _entries.size():
		if _entries[i].dir == dir_name:
			return i
	return -1

func _on_item_selected(index: int) -> void:
	_show_details(_entries[index])

func _on_item_activated(index: int) -> void:
	_choose(_entries[index])

func _race_selected() -> void:
	var selected: PackedInt32Array = _list.get_selected_items()
	if selected.is_empty():
		return
	_choose(_entries[selected[0]])

func _choose(entry: CourseListing) -> void:
	visible = false
	course_chosen.emit(entry)

func _show_details(entry: CourseListing) -> void:
	_name.text = entry.title()
	_preview.texture = entry.preview()
	var parts: PackedStringArray = PackedStringArray()
	if not entry.author.is_empty() and entry.author != "unknown":
		parts.push_back("%s %s" % [tr("CONTRIBUTED_BY"), entry.author])
	if entry.world_size.y > 0.0:
		parts.push_back("%s %d m" % [tr("PATH_LENGTH"), int(entry.world_size.y)])
	if entry.base_angle > 0.0:
		parts.push_back("%.0f°" % entry.base_angle)
	parts.push_back(_group_label(entry.group))
	_meta.text = "   •   ".join(parts)
	_description.text = entry.description

## ETR's course groups, as something a player can read: `default` is the set the
## original shipped with, `extras` the community courses collected since.
func _group_label(group: String) -> String:
	match group:
		"default":
			return "Tux Racer"
		"extras":
			return "Extras"
	return group
