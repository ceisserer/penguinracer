## Peer-to-peer race sessions over ENet. The `Net` autoload.
##
## [b]The model: everyone simulates themselves, nobody simulates anybody
## else.[/b] Each peer runs its own [SimulatedRacer] from its own keyboard and
## broadcasts a [RacerState] snapshot [constant SNAPSHOT_HZ] times a second;
## every other peer shows it as a [PlaybackRacer], read a fixed delay behind the
## local clock. There is no host authority over positions, no rollback and no
## prediction.
##
## That is a real choice and it is the right one [i]for this game[/i]: the
## surface is identical on every machine and the only shared mutable state on
## the course is the herring, so the worst a divergence can do is put two
## penguins on slightly different lines through the same hill.
##
## [b]Racers do collide, and it is resolved twice.[/b] The contact is symmetric
## and each body applies it to itself against the other's published position
## (see [method RacePhysics._adjust_racer_collision]), so no arbiter is needed
## and nothing is sent that is not already in the snapshot stream. What that
## costs is agreement: each peer resolves against the other as it was
## [constant INTERPOLATION_DELAY] ago, so a hard shoulder-to-shoulder bump is
## felt slightly differently at each end, and a fast glancing one can be felt at
## one end and not the other. That is the honest price of having no authority;
## the alternative is a server that owns every position, and this transport
## would not survive one.
##
## [b]Web.[/b] ENet is UDP and a browser has no UDP socket, so this transport
## does not work in the web build — which ships to half of this project's
## targets. It is still the right scaffold to build first: the seam that matters
## is the snapshot stream, and WebRTC through Godot's `WebRTCMultiplayerPeer`
## delivers the same [MultiplayerAPI] with the same RPCs behind
## [method _new_peer]. What WebRTC additionally needs is a signalling server to
## introduce two browsers to each other, which is a piece of hosted
## infrastructure and not a piece of this repository. Until it exists, a
## multiplayer race is desktop-to-desktop and the browser build says so rather
## than failing obscurely.
##
## Driven from the command line for now — there is no lobby screen:
## [codeblock]
## godot --path game -- --host --course=bunny_hill
## godot --path game -- --join=127.0.0.1 --course=bunny_hill
## [/codeblock]
class_name RaceNetwork
extends Node

## The roster changed: someone joined, left, or told us their name.
signal roster_changed()
## A snapshot arrived from [param peer_id].
signal snapshot_received(peer_id: int, packet: PackedFloat32Array)
## Our connection attempt resolved.
signal session_started(hosting: bool)
signal session_ended(reason: String)

const DEFAULT_PORT := 27015
## ENet's channel budget and the number of penguins the HUD can list. Not a
## limit anything technical imposes; a number to fail cleanly at.
const MAX_PEERS := 8
## Snapshots per second. The same rate a ghost is recorded at, and for the same
## reason: three simulation ticks apart is about a metre at racing speed, which
## [RacerStateStream] interpolates through invisibly.
const SNAPSHOT_HZ := 20
## How far behind the local clock a remote racer is drawn. Three snapshot
## intervals: enough to ride out one dropped packet and one late one without
## ever reading past the end of a peer's buffer.
const INTERPOLATION_DELAY := 3.0 / float(SNAPSHOT_HZ)

## Who we tell everyone else we are. Set by the shell through
## [method configure], not read out of [GameConfig] here.
##
## [b]On purpose.[/b] The settings file names the default port, so [GameConfig]
## has to know this class exists; if this class also reached for `Config` the
## two would be a cycle, and GDScript resolves an autoload's singleton name to
## its script type at parse time, so the cycle is a real one — it takes both
## scripts down with "Nonexistent function 'new'" and no mention of either. The
## transport not reading the settings file is the better arrangement anyway.
var player_name: String = "Racer"
var character: String = CharacterCatalog.DEFAULT_DIR

## What each connected peer told us about itself, keyed by peer id. Our own
## entry is in here too, under [method MultiplayerAPI.get_unique_id].
var roster: Dictionary[int, Dictionary] = {}
## Course every peer in this session is racing. The host names it; a client
## takes what it is given.
var course_dir: String = ""

var _snapshot_interval: float = 1.0 / float(SNAPSHOT_HZ)
var _since_snapshot: float = 0.0
var _hosting: bool = false

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	set_process(false)

## Tell the transport who is playing. Called before hosting or joining; a later
## call takes effect on the next session, not the current one.
func configure(new_name: String, new_character: String) -> void:
	player_name = new_name if not new_name.is_empty() else "Racer"
	character = new_character

## Whether a session is up. Everything else in the game checks this and nothing
## else — with no session there are no remote racers and no snapshots to send,
## and the race scene is exactly what it was before this file existed.
func active() -> bool:
	return multiplayer.multiplayer_peer != null \
		and multiplayer.multiplayer_peer.get_connection_status() \
			== MultiplayerPeer.CONNECTION_CONNECTED

func is_host() -> bool:
	return _hosting

func local_id() -> int:
	return multiplayer.get_unique_id() if active() else 0

## Peer ids of everyone but us, in a stable order so the HUD does not reshuffle.
func remote_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id: int in roster:
		if id != local_id():
			ids.push_back(id)
	ids.sort()
	return ids

func name_of(peer_id: int) -> String:
	var entry: Dictionary = roster.get(peer_id, {})
	return str(entry.get("name", "racer %d" % peer_id))

func character_of(peer_id: int) -> String:
	var entry: Dictionary = roster.get(peer_id, {})
	return str(entry.get("character", CharacterCatalog.DEFAULT_DIR))

# ------------------------------------------------------------------
#                        starting and stopping
# ------------------------------------------------------------------

## Open a session others can join. [param course] is what they will race.
func host(port: int = DEFAULT_PORT, course: String = "") -> Error:
	leave("")
	var peer: MultiplayerPeer = _new_peer()
	if peer == null:
		return ERR_UNAVAILABLE
	var err: Error = int(peer.call("create_server", port, MAX_PEERS)) as Error
	if err != OK:
		push_warning("could not host on port %d (error %d)" % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	_hosting = true
	course_dir = course
	_register_self()
	set_process(true)
	print("hosting on port %d" % port)
	session_started.emit(true)
	return OK

## Join a session. [param address] may carry a port as `host:port`.
func join(address: String, port: int = DEFAULT_PORT) -> Error:
	leave("")
	var host_part: String = address
	var colon: int = address.rfind(":")
	if colon > 0:
		host_part = address.left(colon)
		port = address.substr(colon + 1).to_int()
	var peer: MultiplayerPeer = _new_peer()
	if peer == null:
		return ERR_UNAVAILABLE
	var err: Error = int(peer.call("create_client", host_part, port)) as Error
	if err != OK:
		push_warning("could not reach %s:%d (error %d)" % [host_part, port, err])
		return err
	multiplayer.multiplayer_peer = peer
	_hosting = false
	set_process(true)
	print("connecting to %s:%d" % [host_part, port])
	return OK

func leave(reason: String = "left") -> void:
	set_process(false)
	roster.clear()
	_hosting = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	if not reason.is_empty():
		session_ended.emit(reason)

## Build the transport.
##
## Through [ClassDB] rather than as `ENetMultiplayerPeer.new()` on purpose: the
## web export templates do not carry the ENet module, and a script that names a
## class the runtime does not have fails to compile — which would take the whole
## game down in the browser rather than just the part that cannot work there.
## This is also the one place a WebRTC peer would be chosen instead.
func _new_peer() -> MultiplayerPeer:
	if not ClassDB.can_instantiate("ENetMultiplayerPeer"):
		push_warning("no ENet on this platform — multiplayer needs a native build")
		session_ended.emit("multiplayer is not available in the browser")
		return null
	return ClassDB.instantiate("ENetMultiplayerPeer") as MultiplayerPeer

# ------------------------------------------------------------------
#                             the roster
# ------------------------------------------------------------------

func _register_self() -> void:
	roster[local_id()] = {"name": player_name, "character": character}
	roster_changed.emit()

func _on_peer_connected(id: int) -> void:
	# Tell the newcomer who we are, and — if we are the host — what we are
	# racing. Reliable: a roster entry that goes missing leaves a nameless
	# penguin on someone's screen for the rest of the race.
	_announce.rpc_id(id, player_name, character)
	if _hosting and not course_dir.is_empty():
		_set_course.rpc_id(id, course_dir)

func _on_peer_disconnected(id: int) -> void:
	roster.erase(id)
	roster_changed.emit()

func _on_connected() -> void:
	_register_self()
	_announce.rpc(player_name, character)
	session_started.emit(false)

func _on_connection_failed() -> void:
	leave("could not connect")

func _on_server_disconnected() -> void:
	leave("host closed the session")

@rpc("any_peer", "reliable")
func _announce(peer_name: String, character: String) -> void:
	var id: int = multiplayer.get_remote_sender_id()
	roster[id] = {"name": peer_name, "character": character}
	roster_changed.emit()

@rpc("authority", "reliable")
func _set_course(dir: String) -> void:
	course_dir = dir

# ------------------------------------------------------------------
#                            snapshots
# ------------------------------------------------------------------

## The local racer's state, to be broadcast on the next snapshot boundary.
##
## Set every frame by [RaceScene] and sent [constant SNAPSHOT_HZ] times a
## second, rather than sent every frame: the receiver interpolates, so a higher
## rate buys nothing but bandwidth, and rate-limiting here rather than at the
## caller keeps the race scene from having to own a second clock.
var _pending: PackedFloat32Array = PackedFloat32Array()

func publish(state: RacerState) -> void:
	if not active():
		return
	_pending = state.to_floats()

func _process(delta: float) -> void:
	if not active():
		return
	_since_snapshot += delta
	if _since_snapshot < _snapshot_interval or _pending.is_empty():
		return
	_since_snapshot = 0.0
	_snapshot.rpc(_pending)

## Unreliable and unordered. A snapshot that arrives late is worth less than the
## one behind it — [method RacerStateStream.append_packet] drops it — and a
## snapshot that never arrives is interpolated over. Retransmitting either would
## cost latency to deliver something already superseded.
@rpc("any_peer", "unreliable")
func _snapshot(packet: PackedFloat32Array) -> void:
	var id: int = multiplayer.get_remote_sender_id()
	if id == local_id():
		return
	snapshot_received.emit(id, packet)

# ------------------------------------------------------------------
#                          command line
# ------------------------------------------------------------------

## `--host[=port]` / `--join=<address>[:port]`, read by [MainMenu] at boot.
## Returns whether a session was asked for, so the shell knows to skip straight
## to a race. [param default_port] is what the settings file says.
func start_from_cmdline(default_port: int = DEFAULT_PORT) -> bool:
	var wants_host: bool = false
	var join_address: String = ""
	var port: int = default_port
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--host":
			wants_host = true
		elif arg.begins_with("--host="):
			wants_host = true
			port = arg.trim_prefix("--host=").to_int()
		elif arg.begins_with("--join="):
			join_address = arg.trim_prefix("--join=")
	if wants_host:
		host(port)
		return true
	if not join_address.is_empty():
		join(join_address, port)
		return true
	return false
