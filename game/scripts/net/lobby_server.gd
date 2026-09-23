## The rooms, and who is in them. The whole of what a PenguinRacer server
## decides.
##
## [b]Deliberately not a [Node] and deliberately ignorant of the network.[/b]
## Every method here takes a peer id and returns a result; nothing in this file
## sends anything, reads a clock or touches [MultiplayerAPI]. [RaceNetwork] owns
## the RPC surface on both ends and calls into this on the one that is serving.
##
## That split is what makes the server testable. `tests/test_lobby.gd` drives a
## whole session — four peers, a password, an admin handover, a race that ends
## only when the last racer is in — with no sockets and no frames, which is not
## something a server written as a pile of `@rpc` functions can be asked to do.
##
## [b]The model is a relay, not an authority.[/b] The server owns the room list,
## who may enter one, who may start a race and when that race is over. It owns
## nothing about the race itself: positions are not simulated here, not
## validated here and not corrected here — a snapshot arrives and is forwarded
## to the other members of the sender's room unread. See [RaceNetwork] for why
## that is the right trade for this game, and what it costs.
class_name LobbyServer
extends RefCounted

## Racers in one race. Eight is what the snapshot stream costs at 20 Hz without
## anybody noticing, and what the HUD's standings can name without becoming a
## wall of penguins.
const MAX_PLAYERS_PER_ROOM := 8
## Open races one server will hold. A number to fail cleanly at rather than a
## limit anything technical imposes.
const MAX_ROOMS := 64
## Characters of a race name kept. Long enough for "Clemens' Friday race" and
## short enough that a row in the browser is still a row.
const ROOM_NAME_MAX := 32
## ... and of a player name, for the same reason.
const PLAYER_NAME_MAX := 20

## How long after the first racer crosses the line the rest have before the
## room stops waiting for them, in milliseconds.
##
## DEVIATION from the brief, which says the race is over when the last player
## crosses the line — and it is, every time somebody is actually racing. This
## is the other case: a player who stops playing without disconnecting and
## without leaving. A disconnect already ends their race (they leave the
## members list) and so does backing out to the lobby (a forfeit), so five
## minutes is not a rule anybody racing will ever meet; it is the thing that
## stops one abandoned window holding seven people in a finished race forever.
const ABANDON_AFTER_MSEC := 300_000

enum State {
	## Gathering. Shows in the browser, can be joined, the admin may start.
	LOBBY,
	## Everyone has been told which course; waiting for them all to have it
	## built. Hidden from the browser — a race you cannot get into the start of
	## is not a race to advertise.
	LOADING,
	## Running. Ends when the last member is finished, forfeit or gone.
	RACING,
}

## One open or running race.
class Room extends RefCounted:
	var id: int = 0
	var name: String = ""
	## SHA-256 of the room name and the password together, or empty for a race
	## anyone may enter. See [method digest] — the server never sees what the
	## player typed.
	var password_digest: String = ""
	## Peer id of whoever may start the race and change the course. The creator,
	## until they leave — see [method _promote].
	var admin: int = 0
	## Everyone in the room, in the order they arrived. The admin is in here
	## too, and index 0 is not special.
	var members: PackedInt32Array = PackedInt32Array()
	var course_dir: String = ""
	var snowfall: int = 0
	var state: LobbyServer.State = LobbyServer.State.LOBBY
	## Who has finished building the course, while [member state] is
	## [constant State.LOADING].
	var ready_peers: Dictionary[int, bool] = {}
	## Who has crossed the line (or given up), and what they did it in. Keyed by
	## peer id; the value is `{"name", "character", "seconds", "herring",
	## "finished"}`.
	var results: Dictionary[int, Dictionary] = {}
	## When the first racer crossed, in [method Time.get_ticks_msec]. Zero until
	## one does; see [constant ABANDON_AFTER_MSEC].
	var first_finish_msec: int = 0

	func has(peer: int) -> bool:
		return members.has(peer)

	func is_open() -> bool:
		return state == LobbyServer.State.LOBBY

	func locked() -> bool:
		return not password_digest.is_empty()

	func full() -> bool:
		return members.size() >= LobbyServer.MAX_PLAYERS_PER_ROOM

## Everything known about a connected peer: what they call themselves, what they
## race as, and which room they are in (0 for none).
class Peer extends RefCounted:
	var id: int = 0
	var name: String = ""
	var character: String = ""
	var room: int = 0

var rooms: Dictionary[int, Room] = {}
var peers: Dictionary[int, Peer] = {}

var _next_room_id: int = 1

# ==================================================================
#                          coming and going
# ==================================================================

## A peer connected, or told us its name again. Idempotent: a second
## announcement from a peer already in a room renames it in place rather than
## throwing it out of the race it is in.
func add_peer(id: int, player_name: String, character: String) -> void:
	var entry: Peer = peers.get(id, null)
	if entry == null:
		entry = Peer.new()
		entry.id = id
		peers[id] = entry
	entry.name = sanitize_name(player_name, "racer %d" % id, PLAYER_NAME_MAX)
	entry.character = character

## A peer dropped. Returns the room it was in, or 0.
##
## A racer who disconnects mid-race is out of the race rather than waited for,
## which is the whole reason [constant ABANDON_AFTER_MSEC] is a backstop and not
## the mechanism: an unplugged cable ends that racer's race in the same tick the
## transport notices it.
func remove_peer(id: int) -> int:
	var entry: Peer = peers.get(id, null)
	if entry == null:
		return 0
	# Detached before the entry is dropped, not after: leaving a race in
	# progress is recorded as a forfeit, and the forfeit carries the racer's
	# name. Erasing first put a peer id where a name belonged on every results
	# screen in the room.
	var affected: int = _detach(entry, rooms.get(entry.room, null))
	peers.erase(id)
	return affected

func peer_name(id: int) -> String:
	var entry: Peer = peers.get(id, null)
	return entry.name if entry != null else "racer %d" % id

func peer_character(id: int) -> String:
	var entry: Peer = peers.get(id, null)
	return entry.character if entry != null else ""

func room_of(peer: int) -> Room:
	var entry: Peer = peers.get(peer, null)
	if entry == null or entry.room == 0:
		return null
	return rooms.get(entry.room, null)

# ==================================================================
#                             the rooms
# ==================================================================

## Open a race. The caller becomes its admin.
##
## [param password_digest] is what [method digest] made of the name the player
## typed and the password they chose — never the password itself. Empty means
## anyone may join.
func create_room(peer: int, room_name: String, password_digest: String,
		course_dir: String, snowfall: int) -> Dictionary:
	if not peers.has(peer):
		return _error("unknown_peer")
	if rooms.size() >= MAX_ROOMS:
		return _error("too_many_rooms")
	var clean: String = sanitize_name(room_name, "", ROOM_NAME_MAX)
	if clean.is_empty():
		return _error("bad_room_name")
	if course_dir.is_empty():
		return _error("no_course")
	for room: Room in rooms.values():
		if room.name.to_lower() == clean.to_lower():
			return _error("room_name_taken")
	leave_room(peer)
	var created := Room.new()
	created.id = _next_room_id
	_next_room_id += 1
	created.name = clean
	created.password_digest = password_digest
	created.admin = peer
	created.members.push_back(peer)
	created.course_dir = course_dir
	created.snowfall = clampi(snowfall, 0, 3)
	rooms[created.id] = created
	peers[peer].room = created.id
	return {"ok": true, "room": created.id}

## Enter a race somebody else opened.
func join_room(peer: int, room_id: int, password_digest: String) -> Dictionary:
	if not peers.has(peer):
		return _error("unknown_peer")
	var room: Room = rooms.get(room_id, null)
	if room == null:
		return _error("no_such_room")
	if room.has(peer):
		return {"ok": true, "room": room.id}
	if not room.is_open():
		return _error("already_started")
	if room.full():
		return _error("room_full")
	# Constant-time comparison is not the point here and would be theatre: the
	# digest is the credential, it is what the wire carries, and anyone holding
	# it is exactly the person the password was meant to let in.
	if room.password_digest != password_digest:
		return _error("wrong_password")
	leave_room(peer)
	room.members.push_back(peer)
	peers[peer].room = room.id
	return {"ok": true, "room": room.id}

## Back out of a race. Returns the room id affected, or 0.
##
## Mid-race this is a forfeit and is recorded as one — the racer stops being
## waited for, and the results line says they gave up rather than reporting a
## time they did not set.
func leave_room(peer: int) -> int:
	var entry: Peer = peers.get(peer, null)
	if entry == null or entry.room == 0:
		return 0
	return _detach(entry, rooms.get(entry.room, null))

## Move a peer out of whatever room it is in, tidying up behind it: the admin is
## handed on, an emptied room is deleted, and a race everybody has now finished
## is over.
func _detach(entry: Peer, room: Room) -> int:
	entry.room = 0
	if room == null:
		return 0
	var at: int = room.members.find(entry.id)
	if at >= 0:
		room.members.remove_at(at)
	room.ready_peers.erase(entry.id)
	if room.state == State.RACING and not room.results.has(entry.id):
		_record(room, entry.id, 0.0, 0, false)
	if room.members.is_empty():
		rooms.erase(room.id)
		return room.id
	if room.admin == entry.id:
		_promote(room)
	return room.id

## Hand the room to whoever has been in it longest. A race whose admin closes
## the window is still a race the other seven are in.
func _promote(room: Room) -> void:
	room.admin = room.members[0]

## Change what the room is about to race. Admin only, and only before it starts.
func set_course(peer: int, course_dir: String, snowfall: int) -> Dictionary:
	var room: Room = room_of(peer)
	if room == null:
		return _error("not_in_a_room")
	if room.admin != peer:
		return _error("not_admin")
	if not room.is_open():
		return _error("already_started")
	if course_dir.is_empty():
		return _error("no_course")
	room.course_dir = course_dir
	room.snowfall = clampi(snowfall, 0, 3)
	return {"ok": true, "room": room.id}

# ==================================================================
#                             the race
# ==================================================================

## The admin pressed Start. The room stops being joinable and everyone in it is
## told what to load; nobody races until [method report_ready] says they all
## have it.
func start_race(peer: int) -> Dictionary:
	var room: Room = room_of(peer)
	if room == null:
		return _error("not_in_a_room")
	if room.admin != peer:
		return _error("not_admin")
	if not room.is_open():
		return _error("already_started")
	if room.course_dir.is_empty():
		return _error("no_course")
	room.state = State.LOADING
	room.ready_peers.clear()
	room.results.clear()
	room.first_finish_msec = 0
	return {"ok": true, "room": room.id}

## A racer has the course built and is sitting on the start line. Returns true
## on the call that completes the set — which is the moment the race may begin.
##
## Waiting for everybody is why there is no start animation in a network race
## and why there is a countdown instead: a 9 MB course pack over a slow link is
## twenty seconds on one machine and half a second on another, and a race that
## starts when the host's hill is ready is a race two people have already lost.
func report_ready(peer: int) -> bool:
	var room: Room = room_of(peer)
	if room == null or room.state != State.LOADING:
		return false
	room.ready_peers[peer] = true
	for member: int in room.members:
		if not room.ready_peers.has(member):
			return false
	room.state = State.RACING
	return true

## A racer crossed the line, or gave up ([param finished] false). Returns true
## on the call that leaves nobody still racing.
##
## [b]This is the brief's one hard rule.[/b] A network race is over when the
## last racer is in — not when the first one is, and not when the local player
## is. Everyone who is still on the hill keeps racing, on their own clock, with
## the rest of the field watching.
func report_finish(peer: int, seconds: float, herring: int, finished: bool = true) -> bool:
	var room: Room = room_of(peer)
	if room == null or room.state != State.RACING:
		return false
	if room.results.has(peer):
		return false
	_record(room, peer, seconds, herring, finished)
	for member: int in room.members:
		if not room.results.has(member):
			return false
	_end_race(room)
	return true

## Rooms whose stragglers have run out of time, ended in place. See
## [constant ABANDON_AFTER_MSEC]; [param now_msec] is
## [method Time.get_ticks_msec], passed in so this class still owns no clock.
func expire(now_msec: int) -> Array[int]:
	var ended: Array[int] = []
	for room: Room in rooms.values():
		if room.state != State.RACING or room.first_finish_msec == 0:
			continue
		if now_msec - room.first_finish_msec < ABANDON_AFTER_MSEC:
			continue
		for member: int in room.members:
			if not room.results.has(member):
				_record(room, member, 0.0, 0, false)
		_end_race(room)
		ended.push_back(room.id)
	return ended

func _record(room: Room, peer: int, seconds: float, herring: int, finished: bool) -> void:
	room.results[peer] = {
		"peer": peer,
		"name": peer_name(peer),
		"character": peer_character(peer),
		"seconds": seconds,
		"herring": herring,
		"finished": finished,
	}
	if finished and room.first_finish_msec == 0:
		room.first_finish_msec = Time.get_ticks_msec()

## Put the room back where it started. The group keeps standing — the same
## people, the same admin, the same course highlighted — so "again" is one
## button rather than eight people finding each other a second time.
func _end_race(room: Room) -> void:
	room.state = State.LOBBY
	room.ready_peers.clear()
	room.first_finish_msec = 0

# ==================================================================
#                         what goes on the wire
# ==================================================================

## Every race that can still be entered, for the browser. Rooms that are loading
## or running are left out — see [constant State.LOADING].
func room_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for room: Room in rooms.values():
		if not room.is_open():
			continue
		out.push_back({
			"id": room.id,
			"name": room.name,
			"admin": peer_name(room.admin),
			"players": room.members.size(),
			"max_players": MAX_PLAYERS_PER_ROOM,
			"course": room.course_dir,
			"snowfall": room.snowfall,
			"locked": room.locked(),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"]))
	return out

## One room in full, for the people inside it.
func room_state(room: Room) -> Dictionary:
	var members: Array[Dictionary] = []
	for member: int in room.members:
		members.push_back({
			"peer": member,
			"name": peer_name(member),
			"character": peer_character(member),
			"admin": member == room.admin,
			"ready": room.ready_peers.has(member),
			"done": room.results.has(member),
		})
	return {
		"id": room.id,
		"name": room.name,
		"admin": room.admin,
		"course": room.course_dir,
		"snowfall": room.snowfall,
		"locked": room.locked(),
		"state": int(room.state),
		"members": members,
	}

## The finishing order: everyone who crossed the line, fastest first, then
## everyone who did not.
func standings(room: Room) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Dictionary in room.results.values():
		out.push_back(row)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a["finished"]) != bool(b["finished"]):
			return bool(a["finished"])
		if not bool(a["finished"]):
			return str(a["name"]) < str(b["name"])
		return float(a["seconds"]) < float(b["seconds"]))
	return out

# ==================================================================

## What a client sends instead of a password.
##
## The room name is in the hash so that the same password on two races produces
## two different credentials, which is the whole of what a salt is for here. The
## digest is not a secret the server keeps — it is stored as it arrives and
## compared as it arrives — because the thing it protects is a seat in a
## penguin race, and the honest reading of that is: this keeps strangers out,
## it is not a credential, and a player who types their bank password into it
## has still not sent it anywhere.
static func digest(room_name: String, password: String) -> String:
	if password.is_empty():
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(("penguinracer:%s:%s" % [room_name.to_lower(), password]).to_utf8_buffer())
	return ctx.finish().hex_encode()

## A name with the control characters and the padding taken out, cut to
## [param limit]. Both ends call it — the client so the field says what will
## happen, the server because the client is not the only thing that can send.
static func sanitize_name(text: String, fallback: String, limit: int) -> String:
	var out: String = ""
	for c: String in text.strip_edges():
		out += c if c.unicode_at(0) >= 0x20 else " "
	out = out.strip_edges()
	if out.length() > limit:
		out = out.left(limit).strip_edges()
	return out if not out.is_empty() else fallback

static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}

## One line of English per error code the calls above can come back with. Here
## rather than on the menu because the server is what produces them and this is
## the file that enumerates them; [LobbyMenu] only shows what it is handed.
static func explain(code: String) -> String:
	match code:
		"no_such_room": return "That race is no longer there."
		"wrong_password": return "Wrong password."
		"room_full": return "That race is full."
		"already_started": return "That race has already started."
		"not_admin": return "Only the player who created the race can do that."
		"not_in_a_room": return "You are not in a race."
		"room_name_taken": return "There is already a race with that name."
		"too_many_rooms": return "The server is full."
		"bad_room_name": return "Give the race a name."
		"no_course": return "Choose a course."
		"unknown_peer": return "The server does not know who you are — reconnect."
	return code
