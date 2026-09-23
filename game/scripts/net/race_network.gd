## The session: the socket, the lobby protocol and the snapshot stream. The
## `Net` autoload, and the only file in the game that knows a network exists.
##
## [b]Client/server over WebSocket, because half this game's targets are a
## browser tab.[/b] The first cut of this file was peer-to-peer ENet, which is
## the right transport for a desktop game and cannot work on the web at all —
## ENet is UDP and a page has no UDP socket. Everything now goes through one
## dedicated server ([LobbyServer], run headless out of `scenes/server.tscn`),
## over a transport a browser and a native build can both open. One address,
## one protocol, one build of the server for both kinds of player.
##
## [b]What the server decides, and what it does not.[/b] It owns the room list,
## who may enter a room, who may start a race, and when a race is over. It owns
## nothing inside the race: a snapshot arrives from one member and is forwarded
## to the others unread. Every peer still simulates itself and only itself, and
## draws everybody else as a [PlaybackRacer] a fixed delay behind its own clock
## — no host authority over positions, no rollback, no prediction. The surface
## is identical on every machine and the only shared mutable state on the course
## is the herring, so the worst a divergence can do is put two penguins on
## slightly different lines through the same hill.
##
## [b]Racers do collide, and it is resolved twice.[/b] The contact is symmetric
## and each body applies it to itself against the other's published position
## (see [method RacePhysics._adjust_racer_collision]), so no arbiter is needed
## and nothing is sent that is not already in the snapshot stream. What that
## costs is agreement: each peer resolves against the other as it was
## [constant INTERPOLATION_DELAY] ago, so a hard shoulder-to-shoulder bump is
## felt slightly differently at each end. That is the honest price of having no
## authority; the alternative is a server that owns every position, and this
## transport would not survive one.
##
## [b]What WebSocket costs.[/b] It is TCP, so a lost snapshot is retransmitted
## and the ones behind it wait — the head-of-line blocking UDP exists to avoid.
## At 20 packets a second of 72 bytes it is not a problem worth a second
## transport to solve, and [RacerStateStream] interpolates through a late
## snapshot the same way it interpolates through a missing one. WebRTC would buy
## the unreliable channel back and costs a signalling server and a second code
## path on both ends; it is not worth it until somebody measures a race where it
## matters.
##
## [codeblock]
## godot --headless --path game res://scenes/server.tscn -- --port=27015
## godot --path game                  # Network multiplayer on the main menu
## [/codeblock]
class_name RaceNetwork
extends Node

# ---- transport ----
## Our connection attempt resolved. Not "we are in a race" — see
## [signal room_changed].
signal session_started()
signal session_ended(reason: String)

# ---- lobby ----
## The browser's list of open races arrived.
signal rooms_listed(rooms: Array)
## The room we are in changed: we joined one, somebody came or went, the admin
## changed hands, or the course did. [member room] is the new state, and is
## empty when we are no longer in one.
signal room_changed()
## Something the player asked for was refused, in words. See
## [method LobbyServer.explain].
signal lobby_error(message: String)

# ---- the race ----
## The admin started the race: load [param course_dir] and report ready.
signal race_starting(course_dir: String, snowfall: int, conditions: int)
## Everybody has the hill built. Start the countdown.
signal race_go()
## The last racer is in. Carries the finishing order — see
## [method LobbyServer.standings].
signal race_over(standings: Array)
## The roster changed: someone joined the race, left it, or told us their name.
signal roster_changed()
## A snapshot arrived from [param peer_id].
signal snapshot_received(peer_id: int, packet: PackedFloat32Array)

const DEFAULT_PORT := 27015

## Snapshots per second. The same rate a ghost is recorded at, and for the same
## reason: three simulation ticks apart is about a metre at racing speed, which
## [RacerStateStream] interpolates through invisibly.
const SNAPSHOT_HZ := 20
## How far behind the local clock a remote racer is drawn. Three snapshot
## intervals: enough to ride out one dropped packet and one late one without
## ever reading past the end of a peer's buffer.
const INTERPOLATION_DELAY := 3.0 / float(SNAPSHOT_HZ)

## Seconds between the server's own sweeps for abandoned races. Nothing is
## waiting on it — see [constant LobbyServer.ABANDON_AFTER_MSEC] — so it is slow
## on purpose.
const EXPIRY_SWEEP := 5.0

## Where this machine is in a race, which is not the same question as where the
## room is. The room's state is the server's and covers everybody; this covers
## us, and the two part company the moment we cross the line — the room is still
## RACING and we are [constant Phase.FINISHED], which is the whole of "the race
## ends when the last racer is in" seen from one client.
enum Phase {
	## Not racing. On the menu, in the browser, or standing in a room.
	IDLE,
	## The course is being built. [method report_ready] ends it.
	LOADING,
	## Everyone has it; the race is on.
	RACING,
	## We are over the line and the rest of the field is not. Read by
	## [method report_finish], which will not report a second one, and by
	## [method publish], which keeps publishing — a racer standing at the line
	## is still a racer everybody else can see.
	FINISHED,
}

## Who we tell the server we are. Set by the shell through [method configure],
## not read out of [GameConfig] here.
##
## [b]On purpose.[/b] The settings file names the default port, so [GameConfig]
## has to know this class exists; if this class also reached for `Config` the
## two would be a cycle, and GDScript resolves an autoload's singleton name to
## its script type at parse time, so the cycle is a real one — it takes both
## scripts down with "Nonexistent function 'new'" and no mention of either. The
## transport not reading the settings file is the better arrangement anyway.
var player_name: String = "Racer"
var character: String = CharacterCatalog.DEFAULT_DIR

## Every open race the server last told us about, as [method
## LobbyServer.room_list] builds them.
var rooms: Array[Dictionary] = []
## The room we are in, as [method LobbyServer.room_state] builds it, or empty.
var room: Dictionary = {}
## Everyone in our room but nobody else, keyed by peer id — which is what
## [RacerRoster] reads to name a penguin. Our own entry is in here too.
var roster: Dictionary[int, Dictionary] = {}
## Course every member of this room is racing. The admin names it; everyone else
## takes what they are given.
var course_dir: String = ""
## ... and the weather it is raced in, for the same reason. ETR's `snow_id`
## and `light_id`: everybody in a room races the same course under the same sky,
## which is the admin's to choose and nobody else's.
var snowfall: int = 0
var conditions: int = 0

var phase: Phase = Phase.IDLE

## The rooms, when this process is the one serving. Null in the game.
var _lobby: LobbyServer = null

var _snapshot_interval: float = 1.0 / float(SNAPSHOT_HZ)
var _since_snapshot: float = 0.0
var _since_sweep: float = 0.0
## The local racer's state, to be broadcast on the next snapshot boundary.
##
## Set every tick by [RaceScene] and sent [constant SNAPSHOT_HZ] times a second,
## rather than sent every tick: the receiver interpolates, so a higher rate buys
## nothing but bandwidth, and rate-limiting here rather than at the caller keeps
## the race scene from having to own a second clock.
var _pending: PackedFloat32Array = PackedFloat32Array()

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	set_process(false)

## Tell the server who is playing. Called before connecting; a later call is
## sent on as a rename, which the server applies in place.
func configure(new_name: String, new_character: String) -> void:
	player_name = LobbyServer.sanitize_name(new_name, "Racer",
		LobbyServer.PLAYER_NAME_MAX)
	character = new_character
	if active() and not serving():
		srv_hello.rpc_id(1, player_name, character)

# ==================================================================
#                             the socket
# ==================================================================

## Whether a session is up. Everything else in the game checks this and nothing
## else — with no session there are no remote racers and no snapshots to send,
## and the race scene is exactly what it was before this file existed.
##
## [b]A `MultiplayerAPI` with no session is not a `MultiplayerAPI` with no
## peer.[/b] Godot hands every `SceneTree` an [OfflineMultiplayerPeer] at
## startup — unique id 1, and a connection status of
## [constant MultiplayerPeer.CONNECTION_CONNECTED] — so a null check plus a
## status check says "connected" in a game that has never touched the network.
## Naming the class is safe where naming `WebSocketMultiplayerPeer` is not: the
## offline peer is core and ships in every export template.
func active() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer) \
		and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

## Whether this process is the server. False in the game, always.
func serving() -> bool:
	return _lobby != null

func connecting() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer) \
		and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING

func local_id() -> int:
	return multiplayer.get_unique_id() if active() else 0

func name_of(peer_id: int) -> String:
	var entry: Dictionary = roster.get(peer_id, {})
	return str(entry.get("name", "racer %d" % peer_id))

func character_of(peer_id: int) -> String:
	var entry: Dictionary = roster.get(peer_id, {})
	return str(entry.get("character", CharacterCatalog.DEFAULT_DIR))

## Open the server socket. The headless server calls this and nothing else does
## — see `scripts/net/server_main.gd`.
func serve(port: int = DEFAULT_PORT) -> Error:
	leave("")
	if OS.has_feature("web"):
		push_warning("a browser cannot listen on a socket — run the server natively")
		return ERR_UNAVAILABLE
	var peer: MultiplayerPeer = _new_peer()
	if peer == null:
		return ERR_UNAVAILABLE
	var err: Error = int(peer.call("create_server", port)) as Error
	if err != OK:
		push_warning("could not listen on port %d (error %d)" % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	_lobby = LobbyServer.new()
	set_process(true)
	return OK

## Connect to one. [param address] may be a bare host, `host:port`, or a full
## `ws://` / `wss://` URL — see [method resolve_url].
func connect_to_server(address: String, default_port: int = DEFAULT_PORT) -> Error:
	leave("")
	var url: String = resolve_url(address, default_port)
	if url.is_empty():
		session_ended.emit("no server address")
		return ERR_INVALID_PARAMETER
	var peer: MultiplayerPeer = _new_peer()
	if peer == null:
		return ERR_UNAVAILABLE
	var err: Error = int(peer.call("create_client", url)) as Error
	if err != OK:
		push_warning("could not reach %s (error %d)" % [url, err])
		session_ended.emit("could not reach %s" % url)
		return err
	multiplayer.multiplayer_peer = peer
	set_process(true)
	print("connecting to %s" % url)
	return OK

func leave(reason: String = "left") -> void:
	set_process(false)
	rooms.clear()
	room = {}
	roster.clear()
	course_dir = ""
	phase = Phase.IDLE
	_lobby = null
	_pending = PackedFloat32Array()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	if not reason.is_empty():
		session_ended.emit(reason)
	roster_changed.emit()
	room_changed.emit()

## Build the transport.
##
## Through [ClassDB] rather than as `WebSocketMultiplayerPeer.new()` on purpose:
## a script that names a class the runtime does not have fails to compile, which
## would take the whole game down on a stripped build rather than just the part
## that cannot work there. This is also the one place another transport would be
## chosen instead.
func _new_peer() -> MultiplayerPeer:
	if not ClassDB.can_instantiate("WebSocketMultiplayerPeer"):
		push_warning("no WebSocket support in this build — multiplayer is unavailable")
		session_ended.emit("multiplayer is not available in this build")
		return null
	return ClassDB.instantiate("WebSocketMultiplayerPeer") as MultiplayerPeer

## `penguin.example:27015` → `ws://penguin.example:27015`. An address that
## already carries a scheme is passed through, so `wss://` reaches a server
## behind TLS — which is what a game served over HTTPS has to use, since a page
## on `https:` may not open a `ws:` socket.
static func resolve_url(address: String, default_port: int = DEFAULT_PORT) -> String:
	var text: String = address.strip_edges()
	if text.is_empty():
		return ""
	if text.begins_with("ws://") or text.begins_with("wss://"):
		return text
	# An IPv6 literal carries colons of its own; only a colon after the last
	# `]` (or in an address with no brackets at all) is a port.
	var colon: int = text.rfind(":")
	var bracket: int = text.rfind("]")
	if colon > bracket and colon > 0:
		return "ws://%s" % text
	return "ws://%s:%d" % [text, default_port]

## What the address field starts out saying.
##
## In a browser: the host that served the page, because the same machine serves
## both halves — that is the whole point of the server in `scenes/server.tscn`
## being one process. A page delivered over HTTPS gets `wss://`, since the
## browser will refuse anything else. Everywhere else: the loopback, which is
## what a developer running a server in the next terminal wants.
static func default_address(default_port: int = DEFAULT_PORT) -> String:
	if not OS.has_feature("web"):
		return "127.0.0.1:%d" % default_port
	var host: Variant = JavaScriptBridge.eval("location.hostname", true)
	var secure: Variant = JavaScriptBridge.eval("location.protocol === 'https:'", true)
	if not (host is String) or str(host).is_empty():
		return "127.0.0.1:%d" % default_port
	return "%s://%s:%d" % ["wss" if bool(secure) else "ws", str(host), default_port]

# ==================================================================
#                        connection events
# ==================================================================

func _on_peer_connected(id: int) -> void:
	if _lobby == null:
		return
	# Nothing is known about them until they say hello; they are not in the
	# room list's world yet either. The provisional name is unique by
	# construction, so this one cannot be refused.
	_lobby.add_peer(id, "racer %d" % id, CharacterCatalog.DEFAULT_DIR)
	_push_rooms(id)

func _on_peer_disconnected(id: int) -> void:
	if _lobby == null:
		return
	var affected: int = _lobby.remove_peer(id)
	_after_change(affected)

func _on_connected() -> void:
	srv_hello.rpc_id(1, player_name, character)
	# Marker for the browser harness, and the same job `RACE_READY` does: the
	# one line that says the socket is genuinely up rather than merely asked
	# for. `tools/webtest/run_web_test.js` waits on it.
	print("LOBBY_CONNECTED as peer %d" % local_id())
	session_started.emit()

func _on_connection_failed() -> void:
	leave("could not connect to the server")

func _on_server_disconnected() -> void:
	leave("the server closed the connection")

func _process(delta: float) -> void:
	if _lobby != null:
		_since_sweep += delta
		if _since_sweep >= EXPIRY_SWEEP:
			_since_sweep = 0.0
			for id: int in _lobby.expire(Time.get_ticks_msec()):
				_finish_room(id)
		return
	if not active():
		return
	_since_snapshot += delta
	if _since_snapshot < _snapshot_interval or _pending.is_empty():
		return
	_since_snapshot = 0.0
	srv_snapshot.rpc_id(1, _pending)

# ==================================================================
#                      what the client asks for
# ==================================================================

func in_room() -> bool:
	return not room.is_empty()

func room_id() -> int:
	return int(room.get("id", 0))

func is_admin() -> bool:
	return in_room() and int(room.get("admin", 0)) == local_id()

## Everyone in our room, as [method LobbyServer.room_state] wrote them.
func members() -> Array:
	return room.get("members", []) as Array

func refresh_rooms() -> void:
	if active():
		srv_list_rooms.rpc_id(1)

## Open a race. [param password] is what the player typed; only a digest of it
## leaves this machine — see [method LobbyServer.digest].
func create_room(name: String, password: String, course: String, snow: int,
		sky: int) -> void:
	if not active():
		return
	var clean: String = LobbyServer.sanitize_name(name, "", LobbyServer.ROOM_NAME_MAX)
	srv_create_room.rpc_id(1, clean, LobbyServer.digest(clean, password), course,
		snow, sky)

func join_room(id: int, room_name: String, password: String) -> void:
	if not active():
		return
	srv_join_room.rpc_id(1, id, LobbyServer.digest(room_name, password))

func leave_room() -> void:
	if not active():
		return
	srv_leave_room.rpc_id(1)

## Admin only, and ignored by the server otherwise.
func set_course(course: String, snow: int, sky: int) -> void:
	if not active():
		return
	srv_set_course.rpc_id(1, course, snow, sky)

func start_race() -> void:
	if not active():
		return
	srv_start_race.rpc_id(1)

## The hill is built and this machine is on the start line. [RaceScene] calls
## it; the race does not begin until everybody has.
func report_ready() -> void:
	if not active() or phase != Phase.LOADING:
		return
	srv_ready.rpc_id(1)

## We crossed the line. The race is not over — see the brief and
## [method LobbyServer.report_finish] — it is over when the last of us has.
func report_finish(seconds: float, herring: int) -> void:
	if not active() or phase != Phase.RACING:
		return
	phase = Phase.FINISHED
	srv_finish.rpc_id(1, seconds, herring)

## We are leaving the hill without finishing. Recorded as a forfeit so the rest
## of the field is not left waiting for a window that has gone back to the menu.
func forfeit() -> void:
	if not active() or (phase != Phase.RACING and phase != Phase.LOADING):
		return
	phase = Phase.IDLE
	srv_forfeit.rpc_id(1)

func publish(state: RacerState) -> void:
	if not active() or phase == Phase.IDLE:
		return
	_pending = state.to_floats()

# ==================================================================
#                     client → server (the protocol)
# ==================================================================

@rpc("any_peer", "call_remote", "reliable")
func srv_hello(peer_name: String, peer_character: String) -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	# A name already spoken for on this server is the one hello that comes
	# back refused — see [method LobbyServer.add_peer]. The peer stays
	# connected under the provisional name it was seated with; what it does
	# next is the client's business, and our client leaves.
	if not _accepted(id, _lobby.add_peer(id, peer_name, peer_character)):
		_log("refused peer %d — \"%s\" is already racing here" % [id, peer_name])
		return
	var current: LobbyServer.Room = _lobby.room_of(id)
	if current != null:
		_push_room(current)
	else:
		_push_rooms(id)

@rpc("any_peer", "call_remote", "reliable")
func srv_list_rooms() -> void:
	if _lobby == null:
		return
	_push_rooms(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable")
func srv_create_room(name: String, password_digest: String, course: String,
		snow: int, sky: int) -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var was: LobbyServer.Room = _lobby.room_of(id)
	var result: Dictionary = _lobby.create_room(id, name, password_digest, course,
		snow, sky)
	if not _accepted(id, result):
		return
	if was != null:
		_after_change(was.id)
	var opened: LobbyServer.Room = _lobby.room_of(id)
	_log("%s opened \"%s\" on %s%s" % [_lobby.peer_name(id), opened.name,
		opened.course_dir, " (password)" if opened.locked() else ""])
	_push_room(opened)
	_broadcast_rooms()

@rpc("any_peer", "call_remote", "reliable")
func srv_join_room(id: int, password_digest: String) -> void:
	if _lobby == null:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var was: LobbyServer.Room = _lobby.room_of(sender)
	var result: Dictionary = _lobby.join_room(sender, id, password_digest)
	if not _accepted(sender, result):
		return
	if was != null and was.id != id:
		_after_change(was.id)
	var entered: LobbyServer.Room = _lobby.room_of(sender)
	_log("%s joined \"%s\" (%d/%d)" % [_lobby.peer_name(sender), entered.name,
		entered.members.size(), LobbyServer.MAX_PLAYERS_PER_ROOM])
	_push_room(entered)
	_broadcast_rooms()

@rpc("any_peer", "call_remote", "reliable")
func srv_leave_room() -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var affected: int = _lobby.leave_room(id)
	cli_room.rpc_id(id, {})
	_after_change(affected)

@rpc("any_peer", "call_remote", "reliable")
func srv_set_course(course: String, snow: int, sky: int) -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var result: Dictionary = _lobby.set_course(id, course, snow, sky)
	if not _accepted(id, result):
		return
	_push_room(_lobby.room_of(id))
	_broadcast_rooms()

@rpc("any_peer", "call_remote", "reliable")
func srv_start_race() -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var result: Dictionary = _lobby.start_race(id)
	if not _accepted(id, result):
		return
	var started: LobbyServer.Room = _lobby.room_of(id)
	_log("\"%s\" starts %s with %d racers" % [started.name, started.course_dir,
		started.members.size()])
	for member: int in started.members:
		cli_race_starting.rpc_id(member, started.course_dir, started.snowfall,
			started.conditions)
	_push_room(started)
	_broadcast_rooms()

@rpc("any_peer", "call_remote", "reliable")
func srv_ready() -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var everyone: bool = _lobby.report_ready(id)
	var current: LobbyServer.Room = _lobby.room_of(id)
	if current == null:
		return
	if everyone:
		for member: int in current.members:
			cli_race_go.rpc_id(member)
	_push_room(current)

@rpc("any_peer", "call_remote", "reliable")
func srv_finish(seconds: float, herring: int) -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var current: LobbyServer.Room = _lobby.room_of(id)
	if current == null:
		return
	if _lobby.report_finish(id, seconds, herring, true):
		_finish_room(current.id)
	else:
		_push_room(current)

@rpc("any_peer", "call_remote", "reliable")
func srv_forfeit() -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var current: LobbyServer.Room = _lobby.room_of(id)
	if current == null:
		return
	if _lobby.report_finish(id, 0.0, 0, false):
		_finish_room(current.id)
	else:
		_push_room(current)

## Forward one snapshot to the rest of the sender's room.
##
## Unreliable is asked for and TCP does not grant it — see the class note. It is
## still the right declaration: it says what the payload is worth, and it is
## what a WebRTC channel behind the same call would honour.
@rpc("any_peer", "call_remote", "unreliable")
func srv_snapshot(packet: PackedFloat32Array) -> void:
	if _lobby == null:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var current: LobbyServer.Room = _lobby.room_of(id)
	if current == null:
		return
	# Checked here rather than trusted: a malformed packet forwarded to seven
	# clients is seven `RacerStateStream`s asked to index off the end of an
	# array. [method RacerStateStream.append_packet] would refuse it at the far
	# end too; refusing it once is cheaper than refusing it seven times.
	if not RacerState.is_valid_packet(packet):
		return
	for member: int in current.members:
		if member != id:
			cli_snapshot.rpc_id(member, id, packet)

# ==================================================================
#                     server → client (the protocol)
# ==================================================================

@rpc("authority", "call_remote", "reliable")
func cli_rooms(list: Array) -> void:
	rooms = []
	for entry: Variant in list:
		if entry is Dictionary:
			rooms.push_back(entry)
	rooms_listed.emit(rooms)

@rpc("authority", "call_remote", "reliable")
func cli_room(state: Dictionary) -> void:
	room = state
	_rebuild_roster()
	if state.is_empty():
		course_dir = ""
		phase = Phase.IDLE
	else:
		course_dir = str(state.get("course", ""))
		snowfall = int(state.get("snowfall", 0))
		conditions = int(state.get("conditions", 0))
	room_changed.emit()

@rpc("authority", "call_remote", "reliable")
func cli_error(code: String) -> void:
	# `name_taken` is the one refusal that is not about a room: the server will
	# not have us under the name we gave it, and there is nothing on this
	# session worth keeping while that is true — a player left standing in the
	# browser as "racer 1394852" would open a race under it. Dropping the
	# session puts [LobbyMenu] back on its CONNECT page with the name field
	# filled in and the reason on the status line, which is the one screen that
	# can do anything about it.
	if code == "name_taken":
		leave(LobbyServer.explain(code))
		return
	lobby_error.emit(LobbyServer.explain(code))

@rpc("authority", "call_remote", "reliable")
func cli_race_starting(course: String, snow: int, sky: int) -> void:
	course_dir = course
	snowfall = snow
	conditions = sky
	phase = Phase.LOADING
	race_starting.emit(course, snow, sky)

@rpc("authority", "call_remote", "reliable")
func cli_race_go() -> void:
	phase = Phase.RACING
	race_go.emit()

@rpc("authority", "call_remote", "reliable")
func cli_race_over(standings: Array) -> void:
	phase = Phase.IDLE
	race_over.emit(standings)

@rpc("authority", "call_remote", "unreliable")
func cli_snapshot(peer_id: int, packet: PackedFloat32Array) -> void:
	if peer_id == local_id():
		return
	snapshot_received.emit(peer_id, packet)

# ==================================================================
#                          server plumbing
# ==================================================================

## Tell [param peer] what its request came to, or nothing if it worked.
func _accepted(peer: int, result: Dictionary) -> bool:
	if bool(result.get("ok", false)):
		return true
	cli_error.rpc_id(peer, str(result.get("error", "refused")))
	return false

func _push_rooms(peer: int) -> void:
	cli_rooms.rpc_id(peer, _lobby.room_list())

## The list changed for everyone who is looking at it — which is everyone not
## inside a room. A member has a room state instead and does not want their
## screen replaced by a browser.
func _broadcast_rooms() -> void:
	var list: Array[Dictionary] = _lobby.room_list()
	for id: int in _lobby.peers:
		if _lobby.room_of(id) == null:
			cli_rooms.rpc_id(id, list)

func _push_room(current: LobbyServer.Room) -> void:
	if current == null:
		return
	var state: Dictionary = _lobby.room_state(current)
	for member: int in current.members:
		cli_room.rpc_id(member, state)

## A room somebody joined or left: the people still in it get the new state, the
## people outside it get a new list, and a room that is gone needs neither.
func _after_change(room_id: int) -> void:
	if _lobby == null or room_id == 0:
		return
	var current: LobbyServer.Room = _lobby.rooms.get(room_id, null)
	# A racer dropping out may have been the last one anybody was waiting for,
	# which ends the race on the spot rather than on the next sweep.
	if current != null and current.state == LobbyServer.State.RACING and _all_in(current):
		_finish_room(room_id)
		return
	_push_room(current)
	_broadcast_rooms()

## Whether every remaining member of [param current] is off the hill.
func _all_in(current: LobbyServer.Room) -> bool:
	for member: int in current.members:
		if not current.results.has(member):
			return false
	return true

## Publish the finishing order and put the room back on its feet.
func _finish_room(room_id: int) -> void:
	var current: LobbyServer.Room = _lobby.rooms.get(room_id, null)
	if current == null:
		return
	if current.state == LobbyServer.State.RACING:
		current.state = LobbyServer.State.LOBBY
		current.ready_peers.clear()
		current.first_finish_msec = 0
	var order: Array[Dictionary] = _lobby.standings(current)
	_log("\"%s\" is over — %s" % [current.name, _describe(order)])
	for member: int in current.members:
		cli_race_over.rpc_id(member, order)
	_push_room(current)
	_broadcast_rooms()

## One line on the server's terminal, which is the only window it has. Silent in
## the game, where [member _lobby] is null and none of this runs.
func _log(line: String) -> void:
	print("[lobby] %s" % line)

## The finishing order as one line, for the log above.
func _describe(order: Array[Dictionary]) -> String:
	var parts := PackedStringArray()
	for row: Dictionary in order:
		if bool(row["finished"]):
			parts.push_back("%s %.2fs" % [row["name"], row["seconds"]])
		else:
			parts.push_back("%s dnf" % row["name"])
	return ", ".join(parts)

# ==================================================================
#                          the local roster
# ==================================================================

## Turn the room's member list into the id → name/character map [RacerRoster]
## reads. The roster is the room and nothing else: a peer connected to the same
## server but racing somewhere else is not on this hill.
func _rebuild_roster() -> void:
	roster.clear()
	for entry: Variant in members():
		if not (entry is Dictionary):
			continue
		var member: Dictionary = entry
		roster[int(member.get("peer", 0))] = {
			"name": str(member.get("name", "racer")),
			"character": str(member.get("character", CharacterCatalog.DEFAULT_DIR)),
		}
	roster_changed.emit()

# ==================================================================
#                          command line
# ==================================================================

## Whether this run was told to go straight to the lobby, and where.
##
## `--server=<address>` on the desktop, `?server=` in the browser. Returns
## whether a connection was started, so [MainMenu] knows to open the lobby
## screen rather than the root menu.
func start_from_cmdline(address: String, default_port: int = DEFAULT_PORT) -> bool:
	var args: LaunchArgs = LaunchArgs.current()
	if not args.server.is_empty():
		connect_to_server(args.server, default_port)
		return true
	if args.lobby:
		# `?lobby` with nothing in the settings file is the common case in a
		# browser — the player followed a link and has never set an address —
		# and the answer is the host that served the page.
		var where: String = address if not address.strip_edges().is_empty() \
			else default_address(default_port)
		connect_to_server(where, default_port)
		return true
	return false
