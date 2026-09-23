## The screen a finished race lands on, over the still-rendered course — where
## [RaceScene] used to jump straight to [CourseMenu] with a one-line banner.
##
## Shown while the local racer plays its `wonrace`/`lostrace`/`finish` clip
## (see `RaceScene._start_finish_clip`), carrying the time, the herring and —
## when one was raced — how the ghost compared. The one thing it can do that
## the banner couldn't: keep the run. Every finished race is recorded, but
## nothing is written to disk until this screen's Save button is pressed —
## see [SavedRunStore].
##
## In a network race there is a clip behind this panel only for the winner, and
## the note under the result is the whole finishing order rather than a ghost
## gap — see `RaceScene._on_network_race_over`. Neither is something this screen
## knows about: it is handed a result line, a note and a recording to keep.
##
## [b]The panel sits at the top of the screen and dims nothing.[/b] Both are
## `CGameOver` — `topframe = 80` over a course it goes on rendering at full
## brightness — and both are load-bearing rather than taste: the chase camera
## puts the penguin in the middle of the frame, so a centred panel covers the
## finish animation completely, and a full-screen tint washes out what is left
## of it. This screen was authored as a centred panel over a 72 % blue
## `ColorRect` and the animation played behind both of them for a phase.
class_name ResultsMenu
extends CanvasLayer

## The player pressed Continue. [RaceScene] stops the finish clip and brings
## up the ordinary course menu; nothing here decides where "continue" goes.
signal continue_pressed()

@onready var _result: Label = %Result
## The line — or, after a network race, the lines — under the result. A ghost
## comparison in a solo race, the whole finishing order in a network one; the
## panel does not care which, and neither does the label.
@onready var _note: Label = %Ghost
@onready var _name_edit: LineEdit = %NameEdit
@onready var _save_button: Button = %SaveButton
@onready var _saved_label: Label = %Saved
@onready var _continue_button: Button = %ContinueButton

var _recording: RaceRecording

func _ready() -> void:
	_save_button.pressed.connect(_on_save_pressed)
	_continue_button.pressed.connect(_on_continue_pressed)
	visible = false

## Show the panel for a just-finished run. [param recording] is null for a
## scripted run (no recorder — see [member RacerRoster.build_local]) and for a
## network race this machine did not finish, which disables Save rather than
## offering to save nothing. [param note] is whatever there is to say under the
## result: the ghost gap, or the finishing order of a network race.
func open(result_text: String, recording: RaceRecording, note: String) -> void:
	_recording = recording
	_result.text = result_text
	_note.text = note
	_note.visible = not note.is_empty()
	_saved_label.visible = false
	_name_edit.text = _default_name(recording)
	_name_edit.editable = recording != null
	_save_button.disabled = recording == null
	visible = true
	if recording != null:
		_name_edit.grab_focus()
		_name_edit.select_all()
	else:
		_continue_button.grab_focus()

## `"bunny_hill  1:23.45"` — a name the player can just press Save on, and can
## still overwrite before they do.
func _default_name(recording: RaceRecording) -> String:
	if recording == null:
		return ""
	var minutes: int = int(recording.total_time) / 60
	var seconds: float = fmod(recording.total_time, 60.0)
	return "%s  %d:%05.2f" % [recording.course_dir.capitalize(), minutes, seconds]

func _on_save_pressed() -> void:
	var run_name: String = _name_edit.text.strip_edges()
	if run_name.is_empty() or _recording == null:
		return
	if not SavedRunStore.save(_recording, run_name):
		return
	_saved_label.visible = true
	_save_button.disabled = true
	_name_edit.editable = false

func _on_continue_pressed() -> void:
	visible = false
	continue_pressed.emit()
