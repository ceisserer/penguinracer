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
## [b]The list is in three parts[/b], each under a header row that cannot be
## selected: the five courses Tux Racer shipped, the ones Extreme Tux Racer
## added, and the ones the player added by address ([ExternalCourses]) — see
## [enum CourseListing.Category]. Add and Remove under the list manage the
## third part. The network modes leave it out: the other racers in a room
## would have no way to find a course only this machine has heard of.
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

## What the four grades of [member RaceSetup.snowfall] are called: translation
## keys from `i18n/ui.csv`. ETR's own `SNOW_A_LITTLE` reads "Snow: A little", a
## label and a value in one, which is not what a drop-down beside a label wants.
const SNOW_LABELS: Array[String] = ["SNOWFALL_NONE", "SNOWFALL_A_LITTLE",
	"SNOWFALL_MORE", "SNOWFALL_A_LOT"]

## What each [enum CourseListing.Category] is called on its header row:
## translation keys from `i18n/ui.csv`.
const CATEGORY_LABELS: Array[String] = ["COURSES_TUXRACER", "COURSES_ETR",
	"COURSES_EXTERNAL"]
## The header rows' colour — [code]AccentLabel[/code]'s, ETR's `colDYell`.
const HEADER_COLOR := Color(1.0, 0.8, 0.0)

var _catalog: CourseCatalog
## One per list row: the course, or `null` for a category header. Only the
## catalog rows that are actually present in this build — the `WebOneCourse`
## export ships one course against the full index, and listing the other 43
## would offer the player 43 dead ends.
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
@onready var _opponents: OptionButton = %OpponentsOption
@onready var _skill: OptionButton = %SkillOption
@onready var _snow: OptionButton = %SnowOption
@onready var _conditions: OptionButton = %ConditionsOption
@onready var _wind: OptionButton = %WindOption
@onready var _room_row: Control = %RoomRow
@onready var _race_name: LineEdit = %RaceNameEdit
@onready var _password: LineEdit = %PasswordEdit
@onready var _external_buttons: Control = %ExternalButtons
@onready var _add_button: Button = %AddCourseButton
@onready var _remove_button: Button = %RemoveCourseButton
@onready var _add_row: Control = %AddRow
@onready var _url_edit: LineEdit = %UrlEdit
@onready var _confirm_add: Button = %ConfirmAddButton
@onready var _cancel_add: Button = %CancelAddButton

## Which of the four screens this is right now. Read by [LobbyMenu] to tell a
## create in flight from an admin changing the course.
var mode: Mode = Mode.PRACTICE
## A room was asked for and the server has not answered. The Race button is
## off until it does, so a second Enter cannot ask twice.
var _waiting: bool = false
## A course is being fetched to be added. Everything that would change the list
## under it is off until it lands.
var _adding: bool = false

## The field the panel is currently offering. Held rather than read back off the
## widgets on close, so that a Practice open cannot lose the race settings the
## player made on the previous one.
var _setup := RaceSetup.new()

func _ready() -> void:
	_catalog = CourseCatalog.load_with_external()
	_back_button.text = tr("BACK")
	# The row labels are translation keys in the scene, and the drop-downs'
	# rows are keys too: the engine translates both as it draws them.
	_fill_field_options()

	# A phone cannot scroll an ItemList at all without this.
	TouchListScroll.attach(_list)
	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(_on_item_activated)
	_race_button.pressed.connect(_race_selected)
	_back_button.pressed.connect(_go_back)
	_race_name.text_submitted.connect(func(_t: String) -> void: _race_selected())
	_password.text_submitted.connect(func(_t: String) -> void: _race_selected())
	_add_button.pressed.connect(_open_add_row)
	_remove_button.pressed.connect(_remove_selected)
	_confirm_add.pressed.connect(_add_course)
	_cancel_add.pressed.connect(_close_add_row)
	_url_edit.text_submitted.connect(func(_t: String) -> void: _add_course())

	_fill_list()
	visible = false

## Rebuild the rows from [member _catalog]: a header, then its courses, for
## each category — the external one even while it is empty, since the header
## is what says the list can hold such a thing.
func _fill_list() -> void:
	_list.clear()
	_entries.clear()
	var networked: bool = mode == Mode.NET_CREATE or mode == Mode.NET_ROOM
	var shown: Array[CourseListing] = []
	for entry: CourseListing in _catalog.entries:
		if entry.is_external():
			if not networked:
				shown.push_back(entry)
			continue
		# `preview_path`, not `scene_path`: a streamed web build (see
		# `PackStream`) legitimately has no `course.tscn` bundled until the
		# player picks the course, but every preview thumbnail ships up front.
		# An external course has neither until it is fetched, which is why it
		# is not asked.
		if ResourceLoader.exists(entry.preview_path):
			shown.push_back(entry)
	for category: int in CATEGORY_LABELS.size():
		if networked and category == CourseListing.Category.EXTERNAL:
			continue
		var index: int = _list.add_item(tr(CATEGORY_LABELS[category]))
		_list.set_item_selectable(index, false)
		_list.set_item_custom_fg_color(index, HEADER_COLOR)
		_entries.push_back(null)
		for entry: CourseListing in shown:
			if entry.category() == category:
				_entries.push_back(entry)
				_list.add_item("   " + entry.title())

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
	_external_buttons.visible = mode == Mode.PRACTICE or mode == Mode.RACE
	_add_row.visible = false
	# None of the network words is a migrated string, for the reason [LobbyMenu]
	# gives: ETR has no multiplayer to have migrated them from.
	var action: String = tr("RACE")
	match mode:
		Mode.NET_CREATE:
			_title.text = tr("CREATE_A_RACE")
			action = tr("ACTION_CREATE")
		Mode.NET_ROOM:
			_title.text = tr("CHOOSE_THE_COURSE")
			action = tr("ACTION_CHOOSE")
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
	# Every time: the network modes list fewer rows than the others.
	_fill_list()
	_select(current_dir)

## Highlight `dir_name`, or the first course if the list has no such row.
func _select(dir_name: String) -> void:
	var index: int = _index_of(dir_name)
	if index < 0:
		index = _index_of("")
	if index >= 0:
		_list.select(index)
		_show_details(_entries[index])
		# Scrolling to the selection needs the list laid out, which has not
		# happened yet on the frame the menu becomes visible.
		_list.ensure_current_is_visible.call_deferred()
	_remove_button.disabled = index < 0 or not _entries[index].is_external()

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

## The row of `dir_name`, or of the first course when `dir_name` is empty;
## -1 if there is none.
func _index_of(dir_name: String) -> int:
	for i: int in _entries.size():
		if _entries[i] != null and (dir_name.is_empty() or _entries[i].dir == dir_name):
			return i
	return -1

func _on_item_selected(index: int) -> void:
	if _entries[index] == null:
		return
	_show_details(_entries[index])
	_remove_button.disabled = not _entries[index].is_external()

func _on_item_activated(index: int) -> void:
	if _entries[index] != null:
		_choose(_entries[index])

func _race_selected() -> void:
	var selected: PackedInt32Array = _list.get_selected_items()
	if selected.is_empty() or _entries[selected[0]] == null:
		return
	_choose(_entries[selected[0]])

func _choose(entry: CourseListing) -> void:
	if _adding:
		return
	if mode == Mode.NET_CREATE or mode == Mode.NET_ROOM:
		if _waiting:
			return
		if mode == Mode.NET_CREATE:
			_waiting = true
			_race_button.disabled = true
			_set_result(tr("CREATING_THE_RACE"))
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
	if entry.is_external():
		# Where it comes from is the one thing a player can judge an added
		# course by before racing it.
		parts.push_back(entry.source_url.get_slice("://", 1).get_slice("/", 0))
	else:
		parts.push_back(tr(CATEGORY_LABELS[entry.category()]))
	_meta.text = "   •   ".join(parts)
	_description.text = entry.description

## Swap the Add/Remove buttons for the address row.
func _open_add_row() -> void:
	_external_buttons.visible = false
	_add_row.visible = true
	_set_result("")
	_url_edit.grab_focus()
	_url_edit.select_all()

func _close_add_row() -> void:
	if _adding:
		return
	_add_row.visible = false
	_external_buttons.visible = true
	_list.grab_focus()

## Fetch the course at the typed address and, if it is one, list it and pick
## it. Said on the result line either way; a refusal leaves the row open with
## the address in it to be corrected.
func _add_course() -> void:
	if _adding:
		return
	var refusal: String = ExternalCourses.check_url(_url_edit.text)
	if not refusal.is_empty():
		_set_result(tr(refusal))
		return
	_adding = true
	_confirm_add.disabled = true
	_cancel_add.disabled = true
	_race_button.disabled = true
	_set_result(tr("EXTERNAL_DOWNLOADING"))
	var added: Variant = await ExternalCourses.add(_url_edit.text, _on_add_progress)
	_adding = false
	_confirm_add.disabled = false
	_cancel_add.disabled = false
	_race_button.disabled = false
	if added is String:
		_set_result(tr(added))
		return
	var listing: CourseListing = added
	_set_result(tr("EXTERNAL_ADDED") % listing.title())
	_url_edit.text = ""
	_close_add_row()
	_catalog = CourseCatalog.load_with_external()
	_fill_list()
	_select(listing.dir)

func _on_add_progress(downloaded: int, total: int) -> void:
	var mb: float = float(downloaded) / 1048576.0
	if total > 0:
		_set_result("%s  %.1f / %.1f MB" % [tr("EXTERNAL_DOWNLOADING"), mb,
			float(total) / 1048576.0])
	else:
		_set_result("%s  %.1f MB" % [tr("EXTERNAL_DOWNLOADING"), mb])

## Forget the highlighted course if the player added it; the rest of the list
## is the build's and cannot be removed.
func _remove_selected() -> void:
	var selected: PackedInt32Array = _list.get_selected_items()
	if _adding or selected.is_empty():
		return
	var entry: CourseListing = _entries[selected[0]]
	if entry == null or not entry.is_external():
		return
	ExternalCourses.remove(entry.dir)
	_set_result(tr("EXTERNAL_REMOVED") % entry.title())
	_catalog = CourseCatalog.load_with_external()
	_fill_list()
	_select("")

## Esc while typing an address folds the row away rather than leaving the
## screen. Runs before the host's handler: this node is below it in the tree.
func _unhandled_input(event: InputEvent) -> void:
	if visible and _add_row.visible and event.is_action_pressed("menu"):
		get_viewport().set_input_as_handled()
		_close_add_row()
