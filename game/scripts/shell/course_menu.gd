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
## The weather row is the same idea and is ETR's own arrangement: `CRaceSelect`
## puts three icon buttons — light, snow, wind — under the course list, each
## cycling four states. All three are here — the snow ([SnowFall]), the sky
## ([LightCondition]) and the wind ([WindField], a crosswind of three strengths
## rather than ETR's grades) — as named spinners rather than icons, since
## nothing in the original's data says what those icons said. All are shown in
## Practice too, because the weather is not the field.
##
## [b]It is also the network lobby's course picker.[/b] [LobbyMenu] carries an
## instance of this scene of its own and opens it with [method open_network]:
## in [constant Mode.NET_CREATE] to open a room — the field row gives way to a
## race name and a password — and in [constant Mode.NET_ROOM] for the room's
## admin to change what it races. Neither mode starts anything. The choice goes
## out on [signal room_course_chosen] and the lobby turns it into a request to
## the server; this screen never talks to [RaceNetwork]. Creating a room can be
## refused (the name is taken, the session dropped), so in that mode the panel
## stays up until the lobby either takes it down or hands it the reason with
## [method show_error].
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
## A course was picked in one of the network modes. `race_name` and `password`
## are what the player typed, and empty in [constant Mode.NET_ROOM], which has
## no such row. The panel is still up: see [method open_network].
signal room_course_chosen(listing: CourseListing, snowfall: int, conditions: int,
	wind: int, race_name: String, password: String)

## What the panel is for, which is what decides the rows under the preview and
## what the Race button says. The first two are the main menu's and the race's;
## the last two are only ever opened by [LobbyMenu].
enum Mode { PRACTICE, RACE, NET_CREATE, NET_ROOM }

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

## What the four grades of [member RaceSetup.snowfall] are called. Not migrated
## strings and not `tr()` keys: ETR says this with a four-state icon and has no
## words for it in any of the thirteen translations, so a key would resolve to
## nothing everywhere. Same standing as *Opponents* and *Skill* above.
const SNOW_LABELS: Array[String] = ["None", "A little", "More", "A lot"]

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
@onready var _back_button: Button = %BackButton
@onready var _hint: Label = %Hint
@onready var _field_row: Control = %FieldRow
@onready var _opponents_label: Label = %OpponentsLabel
@onready var _opponents: OptionButton = %OpponentsOption
@onready var _skill_label: Label = %SkillLabel
@onready var _skill: OptionButton = %SkillOption
@onready var _snow_label: Label = %SnowLabel
@onready var _snow: OptionButton = %SnowOption
@onready var _conditions_label: Label = %ConditionsLabel
@onready var _conditions: OptionButton = %ConditionsOption
@onready var _wind_label: Label = %WindLabel
@onready var _wind: OptionButton = %WindOption
@onready var _room_row: Control = %RoomRow
@onready var _race_name: LineEdit = %RaceNameEdit
@onready var _password: LineEdit = %PasswordEdit

## Which of the four screens this is right now. Read by [LobbyMenu] to tell a
## create in flight from an admin changing the course.
var mode: Mode = Mode.PRACTICE
## A room was asked for and the server has not answered. The Race button is
## off until it does, so a second Enter cannot ask twice.
var _waiting: bool = false

## The field the panel is currently offering. Held rather than read back off the
## widgets on close, so that a Practice open cannot lose the race settings the
## player made on the previous one.
var _setup := RaceSetup.new()

func _ready() -> void:
	_catalog = CourseCatalog.load_default()
	_back_button.text = tr("BACK")
	# Neither of these is a migrated string: ETR has no computer opponents, so
	# there is nothing to migrate and a `tr()` key would resolve to nothing in
	# all thirteen languages. Same call as `ghost` and *Race your best time*.
	_opponents_label.text = "Opponents:"
	_skill_label.text = "Skill:"
	_snow_label.text = "Snowfall:"
	_conditions_label.text = "Conditions:"
	_wind_label.text = "Wind:"
	_fill_field_options()

	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(_on_item_activated)
	_race_button.pressed.connect(_race_selected)
	_back_button.pressed.connect(_go_back)
	_race_name.text_submitted.connect(func(_t: String) -> void: _race_selected())
	_password.text_submitted.connect(func(_t: String) -> void: _race_selected())

	_fill_list()
	visible = false

func _fill_list() -> void:
	_list.clear()
	_entries.clear()
	for entry: CourseListing in _catalog.entries:
		# `preview_path`, not `scene_path`: a streamed web build (see
		# `PackStream`) legitimately has no `course.tscn` bundled until the
		# player picks the course, but every preview thumbnail ships up front.
		if not ResourceLoader.exists(entry.preview_path):
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
	_snow.clear()
	for grade: int in SNOW_LABELS.size():
		_snow.add_item(SNOW_LABELS[grade], grade)
	_conditions.clear()
	# The id is the [enum LightCondition.Kind] itself and not the row number,
	# because the enum is ETR's `lightcond` and has a gap in it where `evening`
	# is — see [LightCondition].
	for kind: LightCondition.Kind in LightCondition.KINDS:
		_conditions.add_item(LightCondition.label_of(kind), kind)
	_wind.clear()
	for level: WindField.Strength in WindField.STRENGTHS:
		_wind.add_item(WindField.strength_label(level), level)

## Show the menu. `current_dir` is highlighted, `over_race` says whether there
## is a course loaded and rendered behind this panel — which is only true from
## [RaceScene], since this screen has no way back to a race once it is open —
## `setup` is the field to offer — an empty one hides the two spinners and
## makes this the Practice screen — and `result_text` carries the summary of
## the race that just ended.
func open(current_dir: String, over_race: bool, setup: RaceSetup,
		result_text: String = "") -> void:
	_setup = setup.copy() if setup != null else RaceSetup.new()
	_apply_mode(Mode.RACE if _setup.is_race() else Mode.PRACTICE)
	_set_result(result_text)
	_dim.color = OVER_RACE_COLOR if over_race else SCREEN_COLOR
	if _setup.is_race():
		_opponents.select(_opponents.get_item_index(_setup.opponents))
		_skill.select(_skill.get_item_index(_setup.skill))
	_present(current_dir)
	_list.grab_focus()

## Show the menu as the network lobby's course picker — `net_mode` is
## [constant Mode.NET_CREATE] or [constant Mode.NET_ROOM]. There is never a
## race behind it: the lobby is a screen of its own.
func open_network(net_mode: Mode, current_dir: String, snowfall: int,
		conditions: int, wind: int, race_name: String = "") -> void:
	_setup = RaceSetup.networked_race().in_snow(snowfall) \
		.under_sky(LightCondition.of(conditions)).in_wind(WindField.strength_of(wind))
	_apply_mode(net_mode)
	_set_result("")
	_dim.color = SCREEN_COLOR
	_race_name.text = race_name
	_password.text = ""
	_present(current_dir)
	if net_mode == Mode.NET_CREATE:
		_race_name.grab_focus()
		_race_name.select_all()
	else:
		_list.grab_focus()

## The server would not have it. Say why and let the player try again.
func show_error(message: String) -> void:
	_waiting = false
	_race_button.disabled = false
	_set_result(message)

## Take the panel down without a word to anyone — the lobby's way of saying
## that what it was open for has been settled elsewhere.
func dismiss() -> void:
	_waiting = false
	_race_button.disabled = false
	visible = false

## The rows, the title and the button's word for each [enum Mode].
func _apply_mode(new_mode: Mode) -> void:
	mode = new_mode
	_waiting = false
	_race_button.disabled = false
	_field_row.visible = mode == Mode.RACE
	_room_row.visible = mode == Mode.NET_CREATE
	# None of the network words is a migrated string, for the reason [LobbyMenu]
	# gives: ETR has no multiplayer to have migrated them from.
	var action: String = tr("RACE")
	match mode:
		Mode.NET_CREATE:
			_title.text = "Create a race"
			action = "Create"
		Mode.NET_ROOM:
			_title.text = "Choose the course"
			action = "Choose"
		_:
			_title.text = tr("SELECT_A_RACE")
	_race_button.text = action
	_hint.text = "↑↓  •  Enter: %s  •  Esc: %s" % [action, tr("BACK")]

func _set_result(text: String) -> void:
	_result.text = text
	_result.visible = not text.is_empty()

## Everything [method open] and [method open_network] share: the weather, and
## the list with `current_dir` highlighted.
func _present(current_dir: String) -> void:
	_snow.select(_snow.get_item_index(clampi(_setup.snowfall, 0, SnowFall.MAX_GRADE)))
	# Through `of()` like the snow goes through `clampi`: an id the list does not
	# have selects nothing at all, and a spinner with no selection reads back as
	# -1 the moment somebody presses Race.
	_conditions.select(_conditions.get_item_index(LightCondition.of(_setup.conditions)))
	_wind.select(_wind.get_item_index(WindField.strength_of(_setup.wind)))
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
	if mode == Mode.NET_CREATE or mode == Mode.NET_ROOM:
		if _waiting:
			return
		if mode == Mode.NET_CREATE:
			_waiting = true
			_race_button.disabled = true
			_set_result("Creating the race…")
		room_course_chosen.emit(entry, _snow.get_selected_id(),
			_conditions.get_selected_id(), _wind.get_selected_id(), _race_name.text,
			_password.text)
		return
	visible = false
	course_chosen.emit(entry, _chosen_setup())

## The field and the weather as the spinners now stand. Practice stays practice
## however the field spinners were last left: they are hidden and their values
## are last race's. The weather rows are never hidden, so all three of their
## spinners always speak.
func _chosen_setup() -> RaceSetup:
	var sky: LightCondition.Kind = LightCondition.of(_conditions.get_selected_id())
	var wind: WindField.Strength = WindField.strength_of(_wind.get_selected_id())
	if not _setup.is_race():
		return RaceSetup.practice().in_snow(_snow.get_selected_id()).under_sky(sky) \
			.in_wind(wind)
	return RaceSetup.against(_opponents.get_selected_id(),
		AISkill.level_at(_skill.get_selected_id())) \
		.in_snow(_snow.get_selected_id()).under_sky(sky).in_wind(wind)

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
