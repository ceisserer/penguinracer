## **Network multiplayer** — the server, the list of open races, and the room
## you stand in until the admin starts one.
##
## Three pages behind one panel, because they are three steps of one errand
## and a player walking it should never lose their place:
##
## [codeblock]
## CONNECT   who you are, and which server          → Net.connect_to_server
## BROWSE    every race not yet started             → Net.join_room
## ROOM      who is here, and the Start button      → Net.start_race
## [/codeblock]
##
## The page is never chosen by a button — it is chosen by what [RaceNetwork]
## says is true. Connected and in a room is ROOM, connected and not is BROWSE,
## not connected is CONNECT. That is what makes the screen survive things that
## happen to it rather than through it: the admin leaves and the room lands on
## somebody else, the server goes away mid-browse, a race ends and eight people
## are put back in the room they were in.
##
## [b]The course is chosen on the course screen[/b], the same [CourseMenu]
## Practice and *Race the computer* use, with its preview and its details —
## this scene carries an instance of it of its own (`%CoursePicker`, one layer
## up). *Create a race* opens it in [constant CourseMenu.Mode.NET_CREATE], with
## a race name and a password where the field would be; *Change course* opens
## it for the room's admin in [constant CourseMenu.Mode.NET_ROOM]. It is a
## panel over this one rather than a page of it, and it is taken down by the
## same [RaceNetwork] news that moves the pages: the room that was being
## created arriving, the session dropping, the admin's seat passing to
## somebody else.
##
## [b]The password never leaves this machine.[/b] What goes on the wire is
## [method LobbyServer.digest] of the room name and the password together; the
## server stores that and compares that. See the method for what this does and
## does not claim to protect.
##
## Nothing here is a migrated string. ETR has no multiplayer, so there is
## nothing to migrate and a `tr()` key would resolve to nothing in all thirteen
## languages — the same call [GhostMenu] and *Race the computer* already make.
## The two keys that do exist, `BACK` and `CANCEL`, are used.
class_name LobbyMenu
extends CanvasLayer

## The admin started the race: load this course. [MainMenu] hands over exactly
## as it does for a course picked off [CourseMenu].
signal race_starting(course_dir: String, snowfall: int, conditions: int)
## The player backed out to the main menu. The session is left up — being in a
## room is not something you should lose by looking at the settings screen.
signal closed()

enum Page { CONNECT, BROWSE, ROOM }

## How often the browser asks for a fresh list, in seconds. The server pushes
## one at every change already; this is for the change that happened while the
## packet was in flight, and for a client that has been sitting on the screen
## since before the room it is looking at filled up.
const REFRESH_SECONDS := 5.0

var _page: Page = Page.CONNECT
var _catalog: CourseCatalog
## What the next room this player opens is called, kept between opens of the
## picker so a refused name can be fixed rather than typed again.
var _race_name: String = ""
## The rooms behind the rows of [member _list], as the server sent them.
var _rooms: Array[Dictionary] = []

@onready var _frame: Control = $Frame
@onready var _title: Label = %Title
@onready var _status: Label = %Status

@onready var _connect_page: Control = %ConnectPage
@onready var _name_edit: LineEdit = %NameEdit
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _connect_hint: Label = %ConnectHint
@onready var _connect_button: Button = %ConnectButton

@onready var _browse_page: Control = %BrowsePage
@onready var _list_panel: PanelContainer = %ListPanel
@onready var _list: ItemList = %RoomList
@onready var _empty: Label = %Empty
@onready var _password_row: Control = %PasswordRow
@onready var _password_edit: LineEdit = %PasswordEdit
@onready var _join_button: Button = %JoinButton
@onready var _create_button: Button = %CreateButton
@onready var _refresh_button: Button = %RefreshButton
@onready var _disconnect_button: Button = %DisconnectButton

@onready var _room_page: Control = %RoomPage
@onready var _room_title: Label = %RoomTitle
@onready var _room_course: Label = %RoomCourse
@onready var _member_list: ItemList = %MemberList
@onready var _room_hint: Label = %RoomHint
@onready var _change_course_button: Button = %ChangeCourseButton
@onready var _start_button: Button = %StartButton
@onready var _leave_button: Button = %LeaveButton

@onready var _back_buttons: Array[Button] = [%BackButton1, %BackButton2, %BackButton3]
@onready var _refresh_timer: Timer = %RefreshTimer
@onready var _picker: CourseMenu = %CoursePicker

func _ready() -> void:
	_catalog = CourseCatalog.load_default()
	_title.text = "Network multiplayer"
	%NameLabel.text = "You are:"
	%AddressLabel.text = "Server:"
	_connect_button.text = "Connect"
	_connect_hint.text = "A host name, a host:port, or a ws:// URL.\n" \
		+ "Run a server with:  godot --headless --path game res://scenes/server.tscn"
	_join_button.text = "Join"
	_create_button.text = "Create a race"
	_refresh_button.text = "Refresh"
	_disconnect_button.text = "Disconnect"
	%PasswordLabel.text = "Password:"
	_empty.text = "No races waiting. Create one and the others will see it."
	_change_course_button.text = "Change course"
	_start_button.text = "Start the race"
	_leave_button.text = "Leave this race"
	for button: Button in _back_buttons:
		button.text = tr("BACK")
		button.pressed.connect(close)

	_connect_button.pressed.connect(_do_connect)
	_address_edit.text_submitted.connect(func(_t: String) -> void: _do_connect())
	_list.item_selected.connect(func(_i: int) -> void: _refresh_browse_buttons())
	_list.item_activated.connect(func(_i: int) -> void: _do_join())
	_password_edit.text_submitted.connect(func(_t: String) -> void: _do_join())
	_join_button.pressed.connect(_do_join)
	_create_button.pressed.connect(_open_create)
	_change_course_button.pressed.connect(_open_change_course)
	_refresh_button.pressed.connect(Net.refresh_rooms)
	_disconnect_button.pressed.connect(_do_disconnect)
	_start_button.pressed.connect(_do_start)
	_leave_button.pressed.connect(_do_leave)
	_picker.room_course_chosen.connect(_on_picker_chosen)
	_picker.back_requested.connect(_close_picker)
	_refresh_timer.wait_time = REFRESH_SECONDS
	_refresh_timer.timeout.connect(_on_refresh_tick)

	Net.session_started.connect(_on_session_started)
	Net.session_ended.connect(_on_session_ended)
	Net.rooms_listed.connect(_on_rooms_listed)
	Net.room_changed.connect(_on_room_changed)
	Net.lobby_error.connect(_on_lobby_error)
	Net.race_starting.connect(_on_race_starting)
	Net.race_over.connect(_on_race_over)
	visible = false

# ==================================================================
#                            opening
# ==================================================================

func open() -> void:
	visible = true
	_name_edit.text = Config.player_name
	_address_edit.text = Config.multiplayer_server if not Config.multiplayer_server.is_empty() \
		else RaceNetwork.default_address(Config.multiplayer_port)
	_race_name = "%s's race" % Config.player_name
	_status.text = ""
	_refresh_timer.start()
	if Net.in_room():
		_show(Page.ROOM)
	elif Net.active():
		Net.refresh_rooms()
		_show(Page.BROWSE)
	elif Net.connecting():
		_show(Page.CONNECT)
		_status.text = "Connecting…"
	else:
		_show(Page.CONNECT)

func close() -> void:
	if not visible:
		return
	visible = false
	_refresh_timer.stop()
	_close_picker()
	closed.emit()

## Which of the three pages is up. Everything else follows from it.
func _show(page: Page) -> void:
	_page = page
	_connect_page.visible = page == Page.CONNECT
	_browse_page.visible = page == Page.BROWSE
	_room_page.visible = page == Page.ROOM
	# The pages are drawn and focused under the picker too, so that taking it
	# down lands on the right one; only a panel nobody can see keeps the focus.
	if _picker.visible:
		return
	match page:
		Page.CONNECT:
			_address_edit.grab_focus()
		Page.BROWSE:
			_fill_rooms()
			if _list.item_count > 0:
				_list.grab_focus()
			else:
				_create_button.grab_focus()
		Page.ROOM:
			_fill_room()
			if Net.is_admin():
				_start_button.grab_focus()
			else:
				_leave_button.grab_focus()

# ==================================================================
#                            connecting
# ==================================================================

func _do_connect() -> void:
	var player: String = LobbyServer.sanitize_name(_name_edit.text, "Racer",
		LobbyServer.PLAYER_NAME_MAX)
	var address: String = _address_edit.text.strip_edges()
	if address.is_empty():
		address = RaceNetwork.default_address(Config.multiplayer_port)
	_name_edit.text = player
	_address_edit.text = address
	# Remembered before the attempt, not after it: an address that failed
	# because the server was not up yet is still the address the player meant.
	if Config.player_name != player or Config.multiplayer_server != address:
		Config.player_name = player
		Config.multiplayer_server = address
		Config.save()
	Net.configure(player, Config.character)
	_status.text = "Connecting to %s…" % address
	_connect_button.disabled = true
	Net.connect_to_server(address, Config.multiplayer_port)

func _do_disconnect() -> void:
	Net.leave("")
	_status.text = ""
	_show(Page.CONNECT)

func _on_session_started() -> void:
	_connect_button.disabled = false
	if not visible:
		return
	_status.text = ""
	Net.refresh_rooms()
	_show(Page.BROWSE)

func _on_session_ended(reason: String) -> void:
	_connect_button.disabled = false
	_rooms.clear()
	if not visible:
		return
	_close_picker()
	_status.text = reason
	_show(Page.CONNECT)

func _on_lobby_error(message: String) -> void:
	if not visible:
		return
	# A refused create is the picker's to explain — the player is still looking
	# at it, with the name the server did not like in front of them.
	if _picker.visible and _picker.mode == CourseMenu.Mode.NET_CREATE:
		_picker.show_error(message)
	else:
		_status.text = message

# ==================================================================
#                            the browser
# ==================================================================

func _on_rooms_listed(_rooms_in: Array) -> void:
	if _page == Page.BROWSE:
		_fill_rooms()

## Keep asking while the browser is up, and only then. A player standing in a
## room already has the only state they care about pushed to them.
func _on_refresh_tick() -> void:
	if visible and _page == Page.BROWSE and Net.active():
		Net.refresh_rooms()

func _fill_rooms() -> void:
	var selected: int = _selected_room_id()
	_rooms = Net.rooms
	_list.clear()
	for entry: Dictionary in _rooms:
		_list.add_item(_room_row(entry))
	_empty.visible = _rooms.is_empty()
	_list_panel.visible = not _rooms.is_empty()
	# Put the cursor back on the race the player was looking at, not on
	# whatever is now first: the list is repainted every five seconds and a
	# selection that jumps under a finger is how somebody joins the wrong race.
	for i: int in _rooms.size():
		if int(_rooms[i].get("id", 0)) == selected:
			_list.select(i)
			break
	if _list.get_selected_items().is_empty() and _list.item_count > 0:
		_list.select(0)
	_refresh_browse_buttons()

func _room_row(entry: Dictionary) -> String:
	var listing: CourseListing = _catalog.find(str(entry.get("course", "")))
	var course: String = listing.title() if listing != null else str(entry.get("course", ""))
	# Words rather than a padlock glyph: the menu theme is the engine's default
	# font, which has no emoji, and a tofu box in a list of races is worse than
	# four characters of English.
	return "%s%s  —  %s  —  %d/%d racers  —  host: %s" % [
		"(locked)  " if bool(entry.get("locked", false)) else "",
		str(entry.get("name", "?")), course,
		int(entry.get("players", 0)), int(entry.get("max_players", 0)),
		str(entry.get("admin", "?"))]

func _selected_room() -> Dictionary:
	var selected: PackedInt32Array = _list.get_selected_items()
	if selected.is_empty() or selected[0] >= _rooms.size():
		return {}
	return _rooms[selected[0]]

func _selected_room_id() -> int:
	return int(_selected_room().get("id", 0))

func _refresh_browse_buttons() -> void:
	var entry: Dictionary = _selected_room()
	var locked: bool = bool(entry.get("locked", false))
	_join_button.disabled = entry.is_empty() \
		or int(entry.get("players", 0)) >= int(entry.get("max_players", 99))
	_password_row.visible = locked
	if not locked:
		_password_edit.text = ""

func _do_join() -> void:
	var entry: Dictionary = _selected_room()
	if entry.is_empty():
		return
	_status.text = ""
	Net.join_room(int(entry["id"]), str(entry.get("name", "")), _password_edit.text)

# ==================================================================
#                          creating a race
# ==================================================================

## The course screen, as the place a room is opened from. It starts on the
## course this player last raced, the way *Race the computer* does, and on the
## weather they last chose.
func _open_create() -> void:
	_status.text = ""
	if _race_name.strip_edges().is_empty():
		_race_name = "%s's race" % Config.player_name
	_open_picker(CourseMenu.Mode.NET_CREATE,
		RaceScene.requested_course_path.get_base_dir().get_file(), Config.snowfall,
		Config.conditions)

## The admin wants the room to race something else. The picker opens on what
## it races now.
func _open_change_course() -> void:
	var room: Dictionary = Net.room
	if room.is_empty() or not Net.is_admin():
		return
	_status.text = ""
	_open_picker(CourseMenu.Mode.NET_ROOM, str(room.get("course", "")),
		int(room.get("snowfall", 0)), int(room.get("conditions", 0)))

func _open_picker(mode: CourseMenu.Mode, course_dir: String, snow: int,
		sky: int) -> void:
	# Hidden rather than covered: the picker's backdrop lets the mouse through,
	# and a click on its empty margin must not land on a button under it.
	_frame.visible = false
	_picker.open_network(mode, course_dir, snow, sky, _race_name)

## Down again, back on whichever page [RaceNetwork] now says is the one.
func _close_picker() -> void:
	if not _picker.visible and _frame.visible:
		return
	_picker.dismiss()
	_frame.visible = true
	if visible:
		_show(_page)

func _on_picker_chosen(listing: CourseListing, snow: int, sky: int,
		race_name: String, password: String) -> void:
	if _picker.mode == CourseMenu.Mode.NET_ROOM:
		_close_picker()
		if Net.is_admin():
			Net.set_course(listing.dir, snow, sky)
		return
	var clean: String = LobbyServer.sanitize_name(race_name, "", LobbyServer.ROOM_NAME_MAX)
	_race_name = clean
	if clean.is_empty():
		_picker.show_error(LobbyServer.explain("bad_room_name"))
		return
	# The picker stays up, saying so, until the room arrives
	# ([method _on_room_changed]) or the reason it will not ([method _on_lobby_error]).
	Net.create_room(clean, password, listing.dir, snow, sky)

# ==================================================================
#                             the room
# ==================================================================

func _on_room_changed() -> void:
	if not visible:
		return
	if Net.in_room():
		# The room being created has arrived — or the room somebody was
		# choosing a course for is no longer theirs to choose it for.
		if _picker.visible and (_picker.mode == CourseMenu.Mode.NET_CREATE
				or not Net.is_admin()):
			_page = Page.ROOM
			_close_picker()
		elif _page != Page.ROOM:
			_show(Page.ROOM)
		else:
			_fill_room()
		return
	# Dropped out of a room — by leaving it, or by being the last one in it
	# when the server tidied it away. A create still in flight is left alone:
	# a player halfway through naming a race has not lost anything worth
	# taking the screen for.
	if _picker.visible and _picker.mode == CourseMenu.Mode.NET_ROOM:
		_page = Page.BROWSE
		_close_picker()
	elif _page == Page.ROOM:
		_show(Page.BROWSE)

func _fill_room() -> void:
	var room: Dictionary = Net.room
	if room.is_empty():
		return
	var admin: bool = Net.is_admin()
	_room_title.text = "%s%s" % [str(room.get("name", "")),
		"   (password)" if bool(room.get("locked", false)) else ""]
	var listing: CourseListing = _catalog.find(str(room.get("course", "")))
	var course: String = listing.title() if listing != null else str(room.get("course", ""))
	var grade: int = clampi(int(room.get("snowfall", 0)), 0, CourseMenu.SNOW_LABELS.size() - 1)
	var sky: LightCondition.Kind = LightCondition.of(int(room.get("conditions", 0)))
	_room_course.text = "%s   —   %s   —   snow: %s" % [course,
		LightCondition.label_of(sky), CourseMenu.SNOW_LABELS[grade]]
	# The admin gets a way to change the course and everyone else only reads
	# it, which is the whole of what being the admin means on this page.
	_change_course_button.visible = admin
	_member_list.clear()
	for entry: Variant in Net.members():
		if entry is Dictionary:
			_member_list.add_item(_member_row(entry))
	_start_button.visible = admin
	_start_button.disabled = not admin
	_room_hint.text = "Press Start when everybody is here." if admin \
		else "Waiting for %s to start the race." % Net.name_of(int(room.get("admin", 0)))

func _member_row(entry: Dictionary) -> String:
	var suffix: String = ""
	if bool(entry.get("admin", false)):
		suffix = "   (admin)"
	if int(entry.get("peer", 0)) == Net.local_id():
		suffix += "   (you)"
	return "%s  —  %s%s" % [str(entry.get("name", "?")),
		str(entry.get("character", "")), suffix]

func _do_start() -> void:
	_status.text = ""
	Net.start_race()

func _do_leave() -> void:
	Net.leave_room()
	_show(Page.BROWSE)

# ==================================================================
#                          into the race
# ==================================================================

func _on_race_starting(course_dir: String, snow: int, sky: int) -> void:
	if not visible:
		return
	_refresh_timer.stop()
	_close_picker()
	visible = false
	race_starting.emit(course_dir, snow, sky)

## The race this screen sent everyone into has finished for everybody. The
## results screen in the race scene has already shown the order; by the time
## this arrives the player is either still on the hill or back here, and either
## way the room they are standing in is the thing to show them.
func _on_race_over(_standings: Array) -> void:
	if visible and Net.in_room():
		_show(Page.ROOM)

# ==================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("menu"):
		return
	get_viewport().set_input_as_handled()
	# Esc backs out one screen rather than off the lobby, wherever there is one
	# behind: out of the course picker to the page under it, out of the browser
	# to the main menu. A room is left with its own button — Esc is not how you
	# leave a race eight people are waiting in.
	if _picker.visible:
		_close_picker()
		return
	close()
