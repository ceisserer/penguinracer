## "Select a character:" — the half of ETR's registration screen that this
## shell has something to put in it.
##
## `CRegist` (regist.cpp) is the first screen the original shows, and it asks two
## questions side by side: which saved player you are, and which of the five
## characters in `char/characters.lst` you race as. Each is a [code]TUpDown[/code]
## spinner over a framed name with a 128x128 preview under it. There are no
## player profiles here yet (Phase 5), so the player half has nothing to show and
## the character half is this screen.
##
## Three things are carried over exactly:
##
## - [b]The order is the file's.[/b] `characters.lst` names Tux, Trixi, Boris,
##   Samuel, Beastie and the spinner opens on index 0, so Tux is the default
##   without anything having to say so.
## - [b]The spinner clamps, it does not wrap.[/b] `TUpDown::Click` stops at
##   `minimum`/`maximum` and greys the arrow out — [code]SetActive(false)[/code],
##   which is `colLGrey` there and a disabled [Button] here.
## - [b]The name is not translated.[/b] ETR draws `Char.CharList[i].name`
##   straight out of the file. They are names.
##
## DEVIATION: the arrows are horizontal and flank the name, where ETR stacks an
## up and a down arrow to its right. Up and down over a horizontal row of
## widgets is what an SFML menu with no focus traversal does; here the column of
## buttons below already owns up/down, and left/right over a name between two
## arrows is what the shape on screen says it should be.
##
## Also a deviation, and the bigger one: the answer is [b]kept[/b].
## `g_game.character` is a pointer set once per launch from a spinner that opens
## on index 0 every time. See [member GameConfig.character].
class_name CharacterMenu
extends CanvasLayer

## Chosen and confirmed. Carries the directory name — [MainMenu] writes it to
## the config file, because this screen does not own the settings file any more
## than [SettingsMenu] owns the course list.
signal chosen(dir: String)
## Dismissed without confirming. Nothing has been written.
signal closed()

var _catalog: CharacterCatalog
var _entries: Array[CharacterListing] = []
var _index: int = 0

@onready var _title: Label = %Title
@onready var _prev_button: Button = %PrevButton
@onready var _next_button: Button = %NextButton
@onready var _name: Label = %CharacterName
@onready var _preview: TextureRect = %Preview
@onready var _position: Label = %Position
@onready var _enter_button: Button = %EnterButton
@onready var _back_button: Button = %BackButton

func _ready() -> void:
	_title.text = tr("SELECT_A_CHARACTER")
	_enter_button.text = tr("ENTER")
	_back_button.text = tr("BACK")
	_prev_button.pressed.connect(_step.bind(-1))
	_next_button.pressed.connect(_step.bind(1))
	_enter_button.pressed.connect(_confirm)
	_back_button.pressed.connect(close)
	visible = false

## Show the screen with [param current_dir] selected. Anything the catalog does
## not know — a hand-edited config file, a character dropped from a narrowed
## export — opens on index 0, which is where [method CharacterCatalog.index_of]
## sends it and where ETR's spinner starts anyway.
func open(current_dir: String) -> void:
	if _catalog == null:
		_catalog = CharacterCatalog.load_default()
		_entries = _catalog.entries
	if _entries.is_empty():
		push_warning("no characters in the catalog; run tools/import_all.sh")
		closed.emit()
		return
	_index = _catalog.index_of(current_dir)
	_refresh()
	visible = true
	_enter_button.grab_focus()

func close() -> void:
	visible = false
	closed.emit()

func _confirm() -> void:
	visible = false
	chosen.emit(_entries[_index].dir)

# ------------------------------------------------------------------
#                             the spinner
# ------------------------------------------------------------------

func _step(delta: int) -> void:
	var next: int = clampi(_index + delta, 0, _entries.size() - 1)
	if next == _index:
		return
	_index = next
	_refresh()

func _refresh() -> void:
	var listing: CharacterListing = _entries[_index]
	_name.text = listing.title()
	_preview.texture = listing.preview()
	# ETR draws no counter. It is here because five characters behind two arrows
	# give no sense of how many there are, and the original's greyed-out arrow —
	# reproduced below — is the only other thing that says so.
	_position.text = "%d / %d" % [_index + 1, _entries.size()]
	_prev_button.disabled = _index == 0
	_next_button.disabled = _index == _entries.size() - 1
	# A disabled button cannot hold focus, and walking off the end of the
	# spinner with the keyboard would otherwise drop focus entirely.
	if _prev_button.disabled and _prev_button.has_focus():
		_next_button.grab_focus()
	elif _next_button.disabled and _next_button.has_focus():
		_prev_button.grab_focus()

## Left and right drive the spinner from anywhere on the screen, which is what
## the two arrows on it promise.
##
## Handled in `_input` rather than `_unhandled_input` because focus traversal
## gets there first: `ui_left`/`ui_right` on a focused [Button] is Godot's
## horizontal focus navigation, and it consumes the event before anything
## unhandled sees it. Esc stays in `_unhandled_input`, where [MainMenu]'s own
## handler will not fight it — this screen is the visible one, so it wins.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_left"):
		_step(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		_step(1)
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("menu"):
		return
	get_viewport().set_input_as_handled()
	close()
