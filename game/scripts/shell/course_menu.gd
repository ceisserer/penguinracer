## Course selection screen — the first slice of the game shell (Phase 5).
##
## Shown from two places, and it is `resumable` on [method open] that tells them
## apart:
##
## - from [MainMenu], with nothing loaded behind it. There is no race to
##   continue, so that button is hidden and Back is the only exit.
## - over the running race, on Esc or after the finish line. The course behind
##   the panel stays loaded and rendered, so opening the menu costs nothing and
##   dismissing it resumes exactly where the player was. Picking a course hands
##   a [CourseListing] to [RaceScene], which swaps it in place rather than
##   reloading the scene.
##
## It also carries the [RaceSetup], and that is why the same panel serves both
## of the main menu's race entries: Practice opens it with an empty field and
## the two spinners hidden, racing the computer opens it with the field the
## player last chose. Keeping them here rather than on a screen of their own is
## what lets someone who has just been beaten drop the difficulty and press
## Race! again without walking back out to the main menu.
##
## Cups and events are imported and waiting in `res://resources/events/`; this
## screen only does free selection of a single course.
class_name CourseMenu
extends CanvasLayer

## A course was picked, with the field to race it against. The host loads the
## course, applies the field and hides the menu.
signal course_chosen(listing: CourseListing, setup: RaceSetup)
## The player dismissed the menu without choosing — resume whatever is behind it.
signal closed()
## The player asked to leave: to the main menu from a race, out of the course
## list from the main menu.
signal back_requested()

## What is behind the panel, and therefore what the backdrop has to be.
##
## ETR clears every menu screen to `colBackgr` and draws nothing else behind it
## (`Winsys.clear()` at the top of `CRaceSelect::Loop`), so reached from the main
## menu this is an opaque screen in that blue rather than a scrim. Over a running
## race there is a course behind the panel worth keeping — dismissing the menu
## resumes exactly where the player was — so the same rectangle becomes a
## translucent wash in `colDBackgr`, dark enough to read white text against snow.
const SCREEN_COLOR := Color(0.4, 0.6, 0.8, 1.0)
const OVER_RACE_COLOR := Color(0.2, 0.3, 0.6, 0.72)

var _catalog: CourseCatalog
## The catalog rows that are actually present in this build. The `WebOneCourse`
## export ships one course against the full index; listing the other 43 would
## offer the player 43 dead ends.
var _entries: Array[CourseListing] = []

@onready var _dim: ColorRect = %Dim
@onready var _list: ItemList = %CourseList
@onready var _title: Label = %Title
@onready var _result: Label = %Result
@onready var _preview: TextureRect = %Preview
@onready var _name: Label = %CourseName
@onready var _meta: Label = %Meta
@onready var _description: Label = %Description
@onready var _race_button: Button = %RaceButton
@onready var _continue_button: Button = %ContinueButton
@onready var _back_button: Button = %BackButton
@onready var _hint: Label = %Hint
@onready var _field_row: Control = %FieldRow
@onready var _opponents_label: Label = %OpponentsLabel
@onready var _opponents: OptionButton = %OpponentsOption
@onready var _skill_label: Label = %SkillLabel
@onready var _skill: OptionButton = %SkillOption

## The field the panel is currently offering. Held rather than read back off the
## widgets on close, so that a Practice open cannot lose the race settings the
## player made on the previous one.
var _setup := RaceSetup.new()

func _ready() -> void:
	_catalog = CourseCatalog.load_default()
	_title.text = tr("SELECT_A_RACE")
	_race_button.text = tr("RACE")
	_continue_button.text = tr("CONTINUE")
	_back_button.text = tr("BACK")
	_hint.text = "↑↓  •  Enter: %s  •  Esc: %s" % [tr("RACE"), tr("BACK")]
	# Neither of these is a migrated string: ETR has no computer opponents, so
	# there is nothing to migrate and a `tr()` key would resolve to nothing in
	# all thirteen languages. Same call as `ghost` and *Race your best time*.
	_opponents_label.text = "Opponents:"
	_skill_label.text = "Skill:"
	_fill_field_options()

	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(_on_item_activated)
	_race_button.pressed.connect(_race_selected)
	_continue_button.pressed.connect(close)
	_back_button.pressed.connect(_go_back)

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

## The one to nine an [OptionButton] offers, plus the skill names.
##
## One is the smallest field worth calling a race and nine is
## [constant RaceSetup.MAX_OPPONENTS] — the ordinals in the imported string
## table stop at tenth, and ten simulated racers is where the tick cost stops
## being free. Zero is not on the list because zero is Practice, which is the
## other button on the main menu.
func _fill_field_options() -> void:
	_opponents.clear()
	for count: int in range(1, RaceSetup.MAX_OPPONENTS + 1):
		_opponents.add_item(str(count), count)
	_skill.clear()
	for index: int in AISkill.LABELS.size():
		_skill.add_item(AISkill.label_of(AISkill.level_at(index)), index)

## Show the menu. `current_dir` is highlighted, `resumable` controls whether
## there is a race worth going back to, `setup` is the field to offer — an empty
## one hides the two spinners and makes this the Practice screen — and
## `result_text` carries the summary of the race that just ended.
func open(current_dir: String, resumable: bool, setup: RaceSetup,
		result_text: String = "") -> void:
	_setup = setup.copy() if setup != null else RaceSetup.new()
	_result.text = result_text
	_result.visible = not result_text.is_empty()
	_continue_button.visible = resumable
	_dim.color = OVER_RACE_COLOR if resumable else SCREEN_COLOR
	_field_row.visible = _setup.is_race()
	if _setup.is_race():
		_opponents.select(_opponents.get_item_index(_setup.opponents))
		_skill.select(_skill.get_item_index(_setup.skill))
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

## Esc, or the Back button. From a race that means dropping out of the course
## and back to the main menu; from the main menu it means folding the list away
## again. Both are `back_requested` — what to do about it is the host's call.
func _go_back() -> void:
	visible = false
	back_requested.emit()

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
	course_chosen.emit(entry, _chosen_setup())

## The field as the spinners now stand. Practice stays practice however the
## spinners were last left: they are hidden and their values are last race's.
func _chosen_setup() -> RaceSetup:
	if not _setup.is_race():
		return RaceSetup.practice()
	return RaceSetup.against(_opponents.get_selected_id(),
		AISkill.level_at(_skill.get_selected_id()))

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
