## **Network multiplayer** — the server, the list of open races, and the room
## you stand in until the admin starts one.
##
## Four pages behind one panel, because they are four steps of one errand and a
## player walking it should never lose their place:
##
## [codeblock]
## CONNECT   who you are, and which server          → Net.connect_to_server
## BROWSE    every race not yet started             → Net.join_room / create
## CREATE    name it, lock it, choose the course    → Net.create_room
## ROOM      who is here, and the Start button      → Net.start_race
## [/codeblock]
##
## The page is never chosen by a button — it is chosen by what [RaceNetwork]
## says is true. Connected and in a room is ROOM, connected and not is BROWSE,
## not connected is CONNECT, and the one exception is CREATE, which is the only
## page a player asks for. That is what makes the screen survive things that
## happen to it rather than through it: the admin leaves and the room lands on
## somebody else, the server goes away mid-browse, a race ends and eight people
## are put back in the room they were in.
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
signal race_starting(course_dir: String, snowfall: int)
## The player backed out to the main menu. The session is left up — being in a
## room is not something you should lose by looking at the settings screen.
signal closed()

enum Page { CONNECT, BROWSE, CREATE, ROOM }

## How often the browser asks for a fresh list, in seconds. The server pushes
## one at every change already; this is for the change that happened while the
## packet was in flight, and for a client that has been sitting on the screen
## since before the room it is looking at filled up.
const REFRESH_SECONDS := 5.0

## What the four grades of snowfall are called. The same four [CourseMenu]
## offers, named the same way and for the same reason — see
## [constant CourseMenu.SNOW_LABELS].
const SNOW_LABELS: Array[String] = ["None", "A little", "More", "A lot"]

var _page: Page = Page.CONNECT
var _catalog: CourseCatalog
## Course directories offered, in the order the option button lists them.
var _courses: PackedStringArray = PackedStringArray()
## The rooms behind the rows of [member _list], as the server sent them.
var _rooms: Array[Dictionary] = []

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

@onready var _create_page: Control = %CreatePage
@onready var _race_name_edit: LineEdit = %RaceNameEdit
@onready var _new_password_edit: LineEdit = %NewPasswordEdit
@onready var _course_option: OptionButton = %CourseOption
@onready var _snow_option: OptionButton = %SnowOption
@onready var _create_confirm: Button = %CreateConfirmButton
@onready var _cancel_button: Button = %CancelButton

@onready var _room_page: Control = %RoomPage
@onready var _room_title: Label = %RoomTitle
@onready var _room_course: Label = %RoomCourse
@onready var _member_list: ItemList = %MemberList
@onready var _room_hint: Label = %RoomHint
@onready var _room_course_option: OptionButton = %RoomCourseOption
@onready var _room_snow_option: OptionButton = %RoomSnowOption
@onready var _room_course_row: Control = %RoomCourseRow
@onready var _start_button: Button = %StartButton
@onready var _leave_button: Button = %LeaveButton

@onready var _back_buttons: Array[Button] = [%BackButton1, %BackButton2, %BackButton3]
@onready var _refresh_timer: Timer = %RefreshTimer

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
	%RaceNameLabel.text = "Race name:"
	%NewPasswordLabel.text = "Password:"
	%CourseLabel.text = "Course:"
	%SnowLabel.text = "Snowfall:"
	%RoomCourseLabel.text = "Course:"
	%RoomSnowLabel.text = "Snowfall:"
	_create_confirm.text = "Create"
	_cancel_button.text = tr("CANCEL")
	_start_button.text = "Start the race"
	_leave_button.text = "Leave this race"
	for button: Button in _back_buttons:
		button.text = tr("BACK")
		button.pressed.connect(close)
	_fill_courses(_course_option)
	_fill_courses(_room_course_option)
	_fill_snow(_snow_option)
	_fill_snow(_room_snow_option)

	_connect_button.pressed.connect(_do_connect)
	_address_edit.text_submitted.connect(func(_t: String) -> void: _do_connect())
	_list.item_selected.connect(func(_i: int) -> void: _refresh_browse_buttons())
	_list.item_activated.connect(func(_i: int) -> void: _do_join())
	_password_edit.text_submitted.connect(func(_t: String) -> void: _do_join())
	_join_button.pressed.connect(_do_join)
	_create_button.pressed.connect(_open_create)
	_refresh_button.pressed.connect(Net.refresh_rooms)
	_disconnect_button.pressed.connect(_do_disconnect)
	_create_confirm.pressed.connect(_do_create)
	_race_name_edit.text_submitted.connect(func(_t: String) -> void: _do_create())
	_cancel_button.pressed.connect(func() -> void: _show(Page.BROWSE))
	_start_button.pressed.connect(_do_start)
	_leave_button.pressed.connect(_do_leave)
	_room_course_option.item_selected.connect(_on_room_course_changed)
	_room_snow_option.item_selected.connect(_on_room_course_changed)
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
	_race_name_edit.text = "%s's race" % Config.player_name
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
	closed.emit()

## The one thing on this screen that is not decided by [RaceNetwork]: which of
## the four pages is up. Everything else follows from it.
func _show(page: Page) -> void:
	_page = page
	_connect_page.visible = page == Page.CONNECT
	_browse_page.visible = page == Page.BROWSE
	_create_page.visible = page == Page.CREATE
	_room_page.visible = page == Page.ROOM
	match page:
		Page.CONNECT:
			_address_edit.grab_focus()
		Page.BROWSE:
			_fill_rooms()
			if _list.item_count > 0:
				_list.grab_focus()
			else:
				_create_button.grab_focus()
		Page.CREATE:
			_race_name_edit.grab_focus()
			_race_name_edit.select_all()
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
	_status.text = reason
	_show(Page.CONNECT)

func _on_lobby_error(message: String) -> void:
	if visible:
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

func _open_create() -> void:
	_status.text = ""
	_new_password_edit.text = ""
	if _race_name_edit.text.strip_edges().is_empty():
		_race_name_edit.text = "%s's race" % Config.player_name
	_snow_option.select(_snow_option.get_item_index(
		clampi(Config.snowfall, 0, SnowFall.MAX_GRADE)))
	_show(Page.CREATE)

func _do_create() -> void:
	var name: String = LobbyServer.sanitize_name(_race_name_edit.text, "",
		LobbyServer.ROOM_NAME_MAX)
	if name.is_empty():
		_status.text = LobbyServer.explain("bad_room_name")
		_race_name_edit.grab_focus()
		return
	var course: String = _chosen_course(_course_option)
	if course.is_empty():
		_status.text = LobbyServer.explain("no_course")
		return
	_status.text = ""
	Net.create_room(name, _new_password_edit.text, course, _snow_option.get_selected_id())

# ==================================================================
#                             the room
# ==================================================================

func _on_room_changed() -> void:
	if not visible:
		return
	if Net.in_room():
		if _page != Page.ROOM:
			_show(Page.ROOM)
		else:
			_fill_room()
		return
	# Dropped out of a room — by leaving it, or by being the last one in it
	# when the server tidied it away. CREATE is left alone: a player halfway
	# through naming a race has not lost anything worth taking the page for.
	if _page == Page.ROOM:
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
	var grade: int = clampi(int(room.get("snowfall", 0)), 0, SNOW_LABELS.size() - 1)
	_room_course.text = "%s   —   snow: %s" % [course, SNOW_LABELS[grade]]
	# The admin gets the course as a control and everyone else as a line of
	# text, which is the whole of what being the admin means on this page.
	_room_course_row.visible = admin
	_room_course.visible = not admin
	if admin:
		_select_course(_room_course_option, str(room.get("course", "")))
		_room_snow_option.select(_room_snow_option.get_item_index(grade))
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

func _on_room_course_changed(_index: int) -> void:
	if not Net.is_admin():
		return
	Net.set_course(_chosen_course(_room_course_option), _room_snow_option.get_selected_id())

func _do_start() -> void:
	_status.text = ""
	Net.start_race()

func _do_leave() -> void:
	Net.leave_room()
	_show(Page.BROWSE)

# ==================================================================
#                          into the race
# ==================================================================

func _on_race_starting(course_dir: String, snow: int) -> void:
	if not visible:
		return
	_refresh_timer.stop()
	visible = false
	race_starting.emit(course_dir, snow)

## The race this screen sent everyone into has finished for everybody. The
## results screen in the race scene has already shown the order; by the time
## this arrives the player is either still on the hill or back here, and either
## way the room they are standing in is the thing to show them.
func _on_race_over(_standings: Array) -> void:
	if visible and Net.in_room():
		_show(Page.ROOM)

# ==================================================================

func _fill_courses(option: OptionButton) -> void:
	option.clear()
	_courses = PackedStringArray()
	for entry: CourseListing in _catalog.entries:
		# `preview_path`, not `scene_path`: a streamed web build has no
		# `course.tscn` bundled until the course is chosen, and every preview
		# ships up front. Same filter [CourseMenu] uses, for the same reason.
		if not ResourceLoader.exists(entry.preview_path):
			continue
		option.add_item(entry.title(), _courses.size())
		_courses.push_back(entry.dir)

func _fill_snow(option: OptionButton) -> void:
	option.clear()
	for grade: int in SNOW_LABELS.size():
		option.add_item(SNOW_LABELS[grade], grade)

func _chosen_course(option: OptionButton) -> String:
	var id: int = option.get_selected_id()
	return _courses[id] if id >= 0 and id < _courses.size() else ""

func _select_course(option: OptionButton, dir: String) -> void:
	var at: int = _courses.find(dir)
	if at >= 0:
		option.select(option.get_item_index(at))

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("menu"):
		return
	get_viewport().set_input_as_handled()
	# Esc backs out one page rather than off the screen, wherever there is a
	# page behind: out of Create to the browser, out of the browser to the main
	# menu. A room is left with its own button — Esc is not how you leave a race
	# eight people are waiting in.
	if _page == Page.CREATE:
		_show(Page.BROWSE)
		return
	close()
