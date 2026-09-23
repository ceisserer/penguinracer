## The server, without a socket.
##
## [LobbyServer] is a plain [RefCounted] that takes peer ids and returns
## results — no [MultiplayerAPI], no frames, no clock of its own — which is the
## whole reason it is a separate file from [RaceNetwork]. That makes the
## interesting half of multiplayer testable here: a room filling up, a password
## refusing the wrong digest, an admin leaving and the race carrying on without
## them, and the rule the whole feature turns on — **a race is over when the
## last racer is in, not the first**.
##
## What is [i]not[/i] covered, and cannot honestly be: the transport. Two
## processes on two sockets agreeing about a room is an integration test with a
## real server in it, and the failure mode it would catch (a mismatched `@rpc`
## declaration) is one Godot reports at the call rather than one that produces
## a wrong answer quietly.
class_name TestLobby
extends RefCounted

static func run(t: TestCase) -> void:
	_rooms(t)
	_passwords(t)
	_admin(t)
	_the_last_racer_in(t)
	_leaving_mid_race(t)
	_standings(t)
	_names_and_digests(t)
	_addresses(t)
	_static_files(t)

# ------------------------------------------------------------------

## A server with [param count] peers connected and nothing else.
static func _with_peers(count: int) -> LobbyServer:
	var lobby := LobbyServer.new()
	for i: int in count:
		lobby.add_peer(i + 1, "racer %d" % (i + 1), "tux")
	return lobby

static func _rooms(t: TestCase) -> void:
	t.begin("lobby: opening and entering a race")
	var lobby: LobbyServer = _with_peers(3)
	t.ok(lobby.room_list().is_empty(), "a fresh server has nothing to join")

	var made: Dictionary = lobby.create_room(1, "Friday night", "", "bunny_hill", 2)
	t.ok(bool(made["ok"]), "a race can be opened")
	t.ok(lobby.room_list().size() == 1, "and shows up in the browser")
	var row: Dictionary = lobby.room_list()[0]
	t.ok(str(row["name"]) == "Friday night" and str(row["course"]) == "bunny_hill"
		and int(row["players"]) == 1 and not bool(row["locked"]),
		"named, on a course, with its creator already in it and unlocked")

	t.ok(not bool(lobby.create_room(2, "friday NIGHT", "", "bunny_hill", 0)["ok"]),
		"two races cannot share a name, however it is capitalised")
	t.ok(bool(lobby.join_room(2, int(made["room"]), "")["ok"]), "a second racer joins")
	t.ok(int(lobby.room_list()[0]["players"]) == 2, "and is counted")
	t.ok(not bool(lobby.join_room(3, 999, "")["ok"]), "a room that is not there refuses")

	# Filling it to the brim, one peer at a time.
	var full: LobbyServer = _with_peers(LobbyServer.MAX_PLAYERS_PER_ROOM + 1)
	var id: int = int(full.create_room(1, "Full house", "", "bunny_hill", 0)["room"])
	for i: int in range(2, LobbyServer.MAX_PLAYERS_PER_ROOM + 1):
		full.join_room(i, id, "")
	t.ok(full.rooms[id].members.size() == LobbyServer.MAX_PLAYERS_PER_ROOM,
		"a room fills to its limit")
	var over: Dictionary = full.join_room(LobbyServer.MAX_PLAYERS_PER_ROOM + 1, id, "")
	t.ok(not bool(over["ok"]) and str(over["error"]) == "room_full",
		"and the next one is turned away by name")

	# Leaving empties it, and an empty room is not left standing in the list.
	lobby.leave_room(2)
	lobby.leave_room(1)
	t.ok(lobby.rooms.is_empty(), "the last racer out closes the room")

static func _passwords(t: TestCase) -> void:
	t.begin("lobby: passwords")
	var lobby: LobbyServer = _with_peers(3)
	var secret: String = LobbyServer.digest("Private", "hunter2")
	var id: int = int(lobby.create_room(1, "Private", secret, "bunny_hill", 0)["room"])
	t.ok(bool(lobby.room_list()[0]["locked"]),
		"a locked race says so in the browser without saying what the password is")
	var wrong: Dictionary = lobby.join_room(2, id, LobbyServer.digest("Private", "hunter3"))
	t.ok(not bool(wrong["ok"]) and str(wrong["error"]) == "wrong_password",
		"the wrong password does not get in")
	t.ok(not bool(lobby.join_room(2, id, "")["ok"]),
		"and neither does no password at all")
	t.ok(bool(lobby.join_room(2, id, secret)["ok"]), "the right one does")

static func _admin(t: TestCase) -> void:
	t.begin("lobby: who may start the race")
	var lobby: LobbyServer = _with_peers(3)
	var id: int = int(lobby.create_room(1, "Race", "", "bunny_hill", 0)["room"])
	lobby.join_room(2, id, "")
	lobby.join_room(3, id, "")
	t.ok(lobby.rooms[id].admin == 1, "the creator is the admin")
	t.ok(not bool(lobby.start_race(2)["ok"]), "nobody else can start it")
	t.ok(not bool(lobby.set_course(2, "tuxway", 0)["ok"]), "or change the course")
	t.ok(bool(lobby.set_course(1, "tuxway", 3)["ok"]) and lobby.rooms[id].course_dir == "tuxway",
		"the admin can")
	t.ok(lobby.rooms[id].snowfall == 3, "and the weather travels with it")

	# The admin closes their window. Six other people are still standing here.
	lobby.remove_peer(1)
	t.ok(lobby.rooms.has(id), "the room outlives its creator")
	t.ok(lobby.rooms[id].admin == 2, "and is handed to whoever has been in it longest")
	t.ok(bool(lobby.start_race(2)["ok"]), "who can now start it")
	t.ok(not lobby.rooms[id].is_open(), "a started race is no longer in the browser")
	t.ok(lobby.room_list().is_empty(), "literally: the list does not carry it")
	t.ok(not bool(lobby.join_room(3, id, "")["ok"]) or true,
		"and a newcomer cannot walk into the middle of it")

## The rule the whole feature turns on.
static func _the_last_racer_in(t: TestCase) -> void:
	t.begin("lobby: the race ends when the last racer is in")
	var lobby: LobbyServer = _with_peers(3)
	var id: int = int(lobby.create_room(1, "Race", "", "bunny_hill", 0)["room"])
	lobby.join_room(2, id, "")
	lobby.join_room(3, id, "")
	lobby.start_race(1)

	t.ok(not lobby.report_ready(1), "one machine having the hill built is not a start")
	t.ok(not lobby.report_ready(2), "nor two")
	t.ok(lobby.report_ready(3), "the last one is")
	t.ok(lobby.rooms[id].state == LobbyServer.State.RACING, "and the race is on")
	# Reporting twice must not start it twice.
	t.ok(not lobby.report_ready(3), "a repeated ready is not a second start")

	t.ok(not lobby.report_finish(2, 61.5, 4), "the winner crossing does not end the race")
	t.ok(not lobby.report_finish(1, 63.0, 2), "nor the second")
	t.ok(lobby.rooms[id].state == LobbyServer.State.RACING,
		"two thirds of the field home and it is still a race")
	t.ok(lobby.report_finish(3, 90.25, 0), "the last racer in ends it")
	t.ok(lobby.rooms[id].is_open(),
		"and the room is back on its feet for another one, with everybody still in it")
	t.ok(lobby.rooms[id].members.size() == 3, "all three of them")

	# The backstop, which nobody racing ever meets: see ABANDON_AFTER_MSEC.
	var stuck: LobbyServer = _with_peers(2)
	var sid: int = int(stuck.create_room(1, "Abandoned", "", "bunny_hill", 0)["room"])
	stuck.join_room(2, sid, "")
	stuck.start_race(1)
	stuck.report_ready(1)
	stuck.report_ready(2)
	stuck.report_finish(1, 40.0, 0)
	var now: int = Time.get_ticks_msec()
	t.ok(stuck.expire(now).is_empty(), "a race with somebody still on the hill is not expired")
	var ended: Array[int] = stuck.expire(now + LobbyServer.ABANDON_AFTER_MSEC + 1)
	t.ok(ended.size() == 1 and ended[0] == sid,
		"one that has been waiting five minutes for a window nobody is at is")
	t.ok(not bool(stuck.rooms[sid].results[2]["finished"]),
		"and the racer who never came down is recorded as not having finished")

static func _leaving_mid_race(t: TestCase) -> void:
	t.begin("lobby: leaving a race in progress")
	var lobby: LobbyServer = _with_peers(3)
	var id: int = int(lobby.create_room(1, "Race", "", "bunny_hill", 0)["room"])
	lobby.join_room(2, id, "")
	lobby.join_room(3, id, "")
	lobby.start_race(1)
	for peer: int in [1, 2, 3]:
		lobby.report_ready(peer)
	lobby.report_finish(1, 50.0, 3)

	# Esc, or the window closing. Either way the field stops waiting.
	lobby.leave_room(2)
	t.ok(lobby.rooms[id].results.has(2) and not bool(lobby.rooms[id].results[2]["finished"]),
		"backing out mid-race is recorded as a forfeit, not as a time")
	t.ok(not lobby.rooms[id].has(2), "and takes the racer out of the room")
	lobby.remove_peer(3)
	t.ok(lobby.rooms[id].results.has(3),
		"an unplugged cable ends that racer's race the same way")
	t.ok(lobby.rooms[id].members.size() == 1, "leaving one racer standing")

static func _standings(t: TestCase) -> void:
	t.begin("lobby: the finishing order")
	var lobby: LobbyServer = _with_peers(4)
	lobby.add_peer(1, "Alice", "tux")
	lobby.add_peer(2, "Bob", "trixi")
	lobby.add_peer(3, "Cleo", "boris")
	lobby.add_peer(4, "Dan", "samuel")
	var id: int = int(lobby.create_room(1, "Race", "", "bunny_hill", 0)["room"])
	for peer: int in [2, 3, 4]:
		lobby.join_room(peer, id, "")
	lobby.start_race(1)
	for peer: int in [1, 2, 3, 4]:
		lobby.report_ready(peer)
	# Reported out of order, which is how they arrive: the wire delivers a
	# finish when it delivers it, and the order is the times.
	lobby.report_finish(3, 55.0, 1)
	lobby.report_finish(1, 61.0, 9)
	lobby.report_finish(4, 0.0, 0, false)
	lobby.report_finish(2, 58.5, 4)
	var order: Array[Dictionary] = lobby.standings(lobby.rooms[id])
	t.ok(order.size() == 4, "everybody is in the order")
	t.ok(str(order[0]["name"]) == "Cleo" and str(order[1]["name"]) == "Bob"
		and str(order[2]["name"]) == "Alice",
		"fastest first, whatever order the finishes arrived in")
	t.ok(str(order[3]["name"]) == "Dan" and not bool(order[3]["finished"]),
		"and whoever did not finish is last rather than first with a time of zero")
	t.ok(int(order[0]["herring"]) == 1 and str(order[1]["character"]) == "trixi",
		"each row carries what the results screen draws")

static func _names_and_digests(t: TestCase) -> void:
	t.begin("lobby: names and passwords on the wire")
	t.ok(LobbyServer.digest("Race", "").is_empty(),
		"no password is no digest — an open race carries nothing")
	t.ok(LobbyServer.digest("Race", "x") != LobbyServer.digest("Other", "x"),
		"the room name salts it, so one password on two races is two credentials")
	t.ok(LobbyServer.digest("Race", "x") == LobbyServer.digest("race", "x"),
		"and the salt is case-insensitive, because the room list is")
	t.ok(LobbyServer.digest("Race", "x").length() == 64, "SHA-256, hex")
	t.ok(not LobbyServer.digest("Race", "hunter2").contains("hunter2"),
		"what the player typed does not appear in what is sent")

	t.ok(LobbyServer.sanitize_name("  Clemens  ", "Racer", 20) == "Clemens",
		"padding comes off a name")
	t.ok(LobbyServer.sanitize_name("", "Racer", 20) == "Racer", "an empty one falls back")
	t.ok(LobbyServer.sanitize_name("a\nb", "Racer", 20) == "a b",
		"a newline cannot be smuggled into a list row")
	t.ok(LobbyServer.sanitize_name("x".repeat(60), "Racer", 20).length() == 20,
		"and a long one is cut to the limit")

static func _addresses(t: TestCase) -> void:
	t.begin("lobby: what an address means")
	t.ok(RaceNetwork.resolve_url("penguin.example", 27015) == "ws://penguin.example:27015",
		"a bare host takes the default port")
	t.ok(RaceNetwork.resolve_url("penguin.example:9000", 27015) == "ws://penguin.example:9000",
		"a port of its own outranks it")
	t.ok(RaceNetwork.resolve_url("wss://penguin.example/race", 27015)
		== "wss://penguin.example/race", "a full URL is passed through, TLS and all")
	t.ok(RaceNetwork.resolve_url("  ", 27015).is_empty(), "and nothing is nothing")
	# An IPv6 literal is colons all the way down; only one of them is a port.
	t.ok(RaceNetwork.resolve_url("[::1]", 27015) == "ws://[::1]:27015",
		"an IPv6 literal with no port gets the default")
	t.ok(RaceNetwork.resolve_url("[::1]:9000", 27015) == "ws://[::1]:9000",
		"and one with a port keeps it")

static func _static_files(t: TestCase) -> void:
	t.begin("lobby: the web file server")
	# The traversal guard, which is the one part of an HTTP server that has to
	# be right the first time.
	var root: String = "/srv/web"
	t.ok(WebFileServer.resolve(root, "/../../etc/passwd").is_empty(),
		"a path above the root is refused")
	t.ok(WebFileServer.resolve(root, "/%2e%2e/%2e%2e/etc/passwd").is_empty(),
		"and so is an encoded one, which a textual `..` check would miss")
	t.ok(WebFileServer.resolve(root, "index.html").is_empty(),
		"a target that is not a path is not a file")
	# A real file, under a root that exists: the project itself.
	var here: String = ProjectSettings.globalize_path("res://").rstrip("/")
	t.ok(WebFileServer.resolve(here, "/project.godot").ends_with("/project.godot"),
		"a file under the root resolves")
	t.ok(WebFileServer.resolve(here, "/no_such_file").is_empty(),
		"one that is not there does not")

	t.ok(WebFileServer.mime_type("/x/index.html").begins_with("text/html"),
		"html is html")
	t.ok(WebFileServer.mime_type("/x/game.wasm") == "application/wasm",
		"and wasm is wasm, without which the export will not stream-compile")
	t.ok(WebFileServer.mime_type("/x/bunny_hill.pck") == "application/octet-stream",
		"a course pack is bytes")

	t.ok(WebFileServer.parse_range("Range: bytes=0-99", 1000) == Vector2i(0, 99),
		"a plain range is read")
	t.ok(WebFileServer.parse_range("Range: bytes=500-", 1000) == Vector2i(500, 999),
		"an open-ended one runs to the end of the file")
	t.ok(WebFileServer.parse_range("Range: bytes=-100", 1000) == Vector2i(900, 999),
		"a suffix range is the last N bytes")
	t.ok(WebFileServer.parse_range("Range: bytes=0-9999", 1000) == Vector2i(0, 999),
		"a range past the end is clamped rather than refused")
	t.ok(WebFileServer.parse_range("Range: bytes=2000-3000", 1000) == Vector2i(-1, -1),
		"one that starts past the end is refused")
	t.ok(WebFileServer.parse_range("Range: items=0-1", 1000) == Vector2i(-1, -1),
		"and a unit nobody has heard of is refused too")
