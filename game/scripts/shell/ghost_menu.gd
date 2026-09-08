## "Race against ghost" — every run the player has ever saved, across every
## course, picked from one list. Where [CourseMenu] is a single course's
## detail behind a list of many, this has nothing to show per row beyond what
## the row itself already says, so there is no master/detail split here.
##
## Racing a run hands the whole [RaceRecording] to [MainMenu], which sets
## [member RaceScene.requested_ghost] and starts the race exactly as choosing
## a course does — see [method MainMenu._on_ghost_run_chosen].
class_name GhostMenu
extends CanvasLayer

## A saved run was picked to race against.
signal run_chosen(recording: RaceRecording)
## The player backed out. [MainMenu] takes its focus back either way.
signal closed()

var _entries: Array[SavedRunStore.Entry] = []
var _catalog: CourseCatalog

@onready var _title: Label = %Title
@onready var _empty: Label = %Empty
@onready var _list_panel: PanelContainer = %ListPanel
@onready var _list: ItemList = %RunList
@onready var _race_button: Button = %RaceButton
@onready var _delete_button: Button = %DeleteButton
@onready var _back_button: Button = %BackButton
@onready var _delete_confirm: ConfirmationDialog = %DeleteConfirm

func _ready() -> void:
	_catalog = CourseCatalog.load_default()
	# Not migrated strings — ETR has no saved runs to have a word for, the same
	# call *Race the computer* and `ghost` already make.
	_title.text = "Race against ghost"
	_race_button.text = "Race!"
	_delete_button.text = "Delete"
	_back_button.text = tr("BACK")
	_empty.text = "No saved runs yet — finish a race and save one to fill this list."
	_delete_confirm.ok_button_text = "Delete"
	_delete_confirm.cancel_button_text = tr("CANCEL")

	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(func(_i: int) -> void: _race_selected())
	_race_button.pressed.connect(_race_selected)
	_delete_button.pressed.connect(_delete_selected)
	_delete_confirm.confirmed.connect(_confirm_delete)
	_back_button.pressed.connect(_go_back)
	visible = false

func open() -> void:
	_fill_list()
	visible = true
	if _list.item_count > 0:
		_list.select(0)
	_update_buttons()
	if _list.item_count > 0:
		_list.grab_focus()
	else:
		_back_button.grab_focus()

func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()

func _fill_list() -> void:
	_list.clear()
	_entries = SavedRunStore.list_all()
	for entry: SavedRunStore.Entry in _entries:
		_list.add_item(_row_text(entry))
	var has_runs: bool = not _entries.is_empty()
	_empty.visible = not has_runs
	_list_panel.visible = has_runs

func _row_text(entry: SavedRunStore.Entry) -> String:
	var recording: RaceRecording = entry.recording
	var listing: CourseListing = _catalog.find(recording.course_dir)
	var course_title: String = listing.title() if listing != null else recording.course_dir
	var minutes: int = int(recording.total_time) / 60
	var seconds: float = fmod(recording.total_time, 60.0)
	return "%s  —  %s  —  %d:%05.2f  —  %d herring" % [course_title,
		recording.run_name, minutes, seconds, recording.herring]

func _update_buttons() -> void:
	var selected: bool = not _list.get_selected_items().is_empty()
	_race_button.disabled = not selected
	_delete_button.disabled = not selected

func _on_item_selected(_index: int) -> void:
	_update_buttons()

func _selected_entry() -> SavedRunStore.Entry:
	var selected: PackedInt32Array = _list.get_selected_items()
	if selected.is_empty():
		return null
	return _entries[selected[0]]

func _race_selected() -> void:
	var entry: SavedRunStore.Entry = _selected_entry()
	if entry == null:
		return
	visible = false
	run_chosen.emit(entry.recording)

func _delete_selected() -> void:
	if _selected_entry() == null:
		return
	_delete_confirm.dialog_text = "Delete this saved run? This cannot be undone."
	_delete_confirm.popup_centered()

func _confirm_delete() -> void:
	var entry: SavedRunStore.Entry = _selected_entry()
	if entry == null:
		return
	SavedRunStore.delete(entry.path)
	_fill_list()
	_update_buttons()

func _go_back() -> void:
	close()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("menu"):
		return
	get_viewport().set_input_as_handled()
	close()
