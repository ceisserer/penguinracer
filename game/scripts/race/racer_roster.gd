## Everyone on the hill: who they are, how they got here, and where everybody
## else is.
##
## This is the `Racers` node under `race.tscn`, and it is the half of
## [RaceScene] that is about the field rather than about the course. It builds
## the player, the computer opponents, the ghost and one racer per connected
## peer; it publishes the [RacerField] every simulation reads its contacts out
## of; and it answers who is winning.
##
## [b]It knows nothing about the course.[/b] A racer is put in the tree, given a
## rig and registered here; a [RacePhysics] is attached to it by [RaceScene],
## which is the thing that has a [SurfaceProvider] and two [ObjectGrid]s to
## attach. The split is deliberate and it is why this class can be reasoned
## about on its own: everything here is membership, identity and ordering.
##
## [b]One place a racer appears.[/b] Every racer, of every kind, goes through
## [method add] and is announced with [signal racer_added] — which is what the
## scene listens to in order to wire its own audio and result handling. It used
## to be three separate blocks of `connect` calls next to three separate
## constructors, and adding a fourth kind of racer meant remembering all of it.
class_name RacerRoster
extends Node3D

## A racer has been built, given a rig and registered. Carries it so the scene
## can connect whatever it wants to hear about; nothing here connects anything.
signal racer_added(racer: Racer)

## Particles an opponent's spray may have in flight per side. A quarter of the
## player's; see [member SimulatedRacer.spray_pool].
const OPPONENT_SPRAY_POOL := 180

## What a ghost is tinted. Cold and pale so it separates from a real racer at a
## glance and from the snow at speed; see [method Racer.make_translucent].
const GHOST_TINT := Color(0.55, 0.78, 1.0, 0.40)
## What a ghost is called on the HUD.
##
## A literal rather than a `tr()` key. The original has no ghosts and so has no
## word for one, and the string table here is exactly ETR's 111 imported strings
## — a key that resolves to nothing would print `GHOST` in every language. When
## the shell grows strings of its own this is the first one.
const GHOST_LABEL := "ghost"

## Everyone on the hill, in the order they were added. The local player is
## always the first entry.
var all: Array[Racer] = []
## The person at the keyboard.
var local: SimulatedRacer
## The computer opponents, in start-line order. Empty in Practice.
var opponents: Array[SimulatedRacer] = []
## The player's best recorded run on this course, or null.
var ghost: PlaybackRacer
## Who the camera, the snow window and the HUD are about. The local player
## today; a spectator mode is this variable pointing somewhere else.
var view_target: Racer

## Where everyone who is a body on the hill is, rebuilt in place each tick and
## shared by reference with every simulation and every opponent. See
## [method refresh_rivals].
var _rivals := RacerField.new()
var _remote: Dictionary[int, PlaybackRacer] = {}

# ==================================================================
#                            building
# ==================================================================

## Build the player and put them on the hill.
##
## [param character_dir] is the player's choice — [member GameConfig.character],
## or a `--character=`/`?character=` naming one for this run only. Anything the
## catalog cannot resolve comes back as Tux rather than as an error; see
## [method CharacterCatalog.scene_path_for]. [param scene_path] overrides the
## catalog lookup entirely, which is [member RaceScene.character_scene_path].
##
## [param auto_input] non-empty makes this a stand-in for a player rather than a
## player: it neither keeps a ghost nor races one.
func build_local(character_dir: String, scene_path: String, display_name: String,
		auto_input: String, compensate_keys: bool) -> SimulatedRacer:
	local = SimulatedRacer.new()
	local.name = "LocalRacer"
	local.kind = Racer.Kind.LOCAL
	local.display_name = display_name
	if auto_input.is_empty():
		var keyboard := LocalInputSource.new()
		keyboard.compensate = compensate_keys
		local.input_source = keyboard
		local.recorder = RaceRecorder.new()
	else:
		local.input_source = ScriptedInputSource.new(auto_input)
	add(local, character_dir, scene_path)
	view_target = local
	return local

## Build the field.
##
## An opponent is not a special kind of racer — it is exactly what
## [method build_local] builds, with an [AIInputSource] where the keyboard goes
## and no recorder, because a ghost is the player's own best run and a
## computer's is not a time anybody set. Everything downstream — the simulation,
## the spray, the snow stamps, the herring grid, the rig, the interpolated draw,
## the standings — is the same code path.
##
## Each opponent gets its own character where there are enough to go round, its
## own seat in the start line and its own personality drawn from that seat, so a
## field of nine is nine racers rather than one drawn nine times.
func build_field(setup: RaceSetup, player_character: String) -> void:
	if setup == null or not setup.is_race():
		return
	var catalog: CharacterCatalog = CharacterCatalog.load_default()
	# The player is already wearing one of the five, so the first opponent to
	# reach it is the second of that character on the hill and is named as such.
	var worn: Dictionary[String, int] = {player_character: 1}
	for i: int in setup.opponents:
		var racer := SimulatedRacer.new()
		racer.name = "Opponent%d" % (i + 1)
		racer.kind = Racer.Kind.AI
		racer.spray_pool = OPPONENT_SPRAY_POOL
		racer.start_offset = RaceSetup.lane_offset(i)
		racer.input_source = AIInputSource.new(AISkill.for_level(setup.skill), i, 0)
		var listing: CharacterListing = _opponent_character(catalog, player_character, i)
		var dir: String = listing.dir if listing != null else CharacterCatalog.DEFAULT_DIR
		racer.display_name = _opponent_name(listing, dir, worn)
		add(racer, dir)
		opponents.push_back(racer)
	print("field: %s" % setup.describe())

## Throw the field away, so [method build_field] can lay a new one.
func clear_field() -> void:
	for racer: SimulatedRacer in opponents:
		all.erase(racer)
		# Out of the tree before the free, not just queued for it: `queue_free`
		# leaves the node a child until the end of the frame, and the
		# replacements go in under the same names.
		remove_child(racer)
		racer.queue_free()
	opponents.clear()

## Which character an opponent races as. The catalog in order, starting after
## the player's own, so the racer beside you is never wearing your suit until
## there are more opponents than characters.
static func _opponent_character(catalog: CharacterCatalog, player_character: String,
		index: int) -> CharacterListing:
	if catalog == null or catalog.entries.is_empty():
		return null
	var start: int = catalog.index_of(player_character)
	return catalog.entries[(start + 1 + index) % catalog.entries.size()]

## What the standings call an opponent. The character's own name, which is what
## a player would call the penguin they can see — numbered from the second one
## wearing it, because two racers called Trixi on one line is not a standing.
##
## [param worn] counts how many of each character are already on the hill and is
## updated here. It starts with the player's own, so a field large enough to
## come round the catalog produces "Tux 2" beside a player racing as Tux, rather
## than a second plain Tux nobody can tell from the one they are steering.
static func _opponent_name(listing: CharacterListing, dir: String,
		worn: Dictionary[String, int]) -> String:
	var base: String = listing.title() if listing != null else "Racer"
	var nth: int = worn.get(dir, 0) + 1
	worn[dir] = nth
	return base if nth == 1 else "%s %d" % [base, nth]

## Put a racer in the tree, give it a rig and register it. [param scene_path]
## overrides the catalog lookup; empty means "look [param character_dir] up".
func add(racer: Racer, character_dir: String, scene_path: String = "") -> void:
	racer.character_dir = character_dir
	add_child(racer)
	var path: String = scene_path
	if path.is_empty():
		path = CharacterCatalog.load_default().scene_path_for(character_dir)
	if not racer.install_character(path):
		racer.install_fallback_mesh()
	all.push_back(racer)
	racer_added.emit(racer)

## Every racer whose motion is computed here, which is who needs a simulation.
func simulated() -> Array[SimulatedRacer]:
	var out: Array[SimulatedRacer] = []
	for racer: Racer in all:
		if racer is SimulatedRacer:
			out.push_back(racer)
	return out

# ==================================================================
#                              ghost
# ==================================================================

## Load the best recorded run for this course, if one is wanted.
##
## [param wanted] is false for a scripted run and for a race against opponents.
## A ghost is a second penguin on your own line and the HUD has one status line
## to say something on — with a field on the hill that line is the standings,
## and the translucent copy of yourself is one more thing to mistake for someone
## you are racing. The recording still happens and a best time is still kept;
## only the drawing is dropped.
func load_ghost(course_dir: String, wanted: bool) -> PlaybackRacer:
	if ghost != null:
		all.erase(ghost)
		remove_child(ghost)
		ghost.queue_free()
		ghost = null
	if not wanted:
		return null
	var recording: RaceRecording = GhostStore.load_for(course_dir)
	if recording == null:
		return null
	var racer := PlaybackRacer.new()
	racer.name = "Ghost"
	racer.kind = Racer.Kind.GHOST
	racer.display_name = GHOST_LABEL
	if not racer.play_recording(recording):
		racer.queue_free()
		return null
	add(racer, recording.character_dir)
	racer.make_translucent(GHOST_TINT)
	ghost = racer
	return ghost

## Seconds the player is behind their ghost at the point they have reached.
## Negative is ahead; [constant INF] means there is no ghost, or it never got
## this far.
func ghost_delta() -> float:
	if ghost == null or local == null:
		return INF
	var when: float = ghost.time_at_progress(local.state.progress)
	if when < 0.0:
		return INF
	return local.race_time - when

# ==================================================================
#                            the field
# ==================================================================

## Tell everyone where everybody else is.
##
## The one thing a racer cannot read out of its own [RacePhysics]: the trees and
## the herring are course furniture that was loaded with the course, and another
## penguin is a body being integrated somewhere else on the same tick. Two
## consumers, one array:
##
## - [member RacePhysics.rivals], which bounces off it — a contact between two
##   racers, resolved independently and symmetrically by each of them;
## - [member AIInputSource.rivals], which steers around it, so an opponent
##   plans a line that does not need the contact resolved in the first place.
##
## Read before anyone advances, so every racer resolves the tick against the
## same instant — the previous one — rather than against however far down the
## list it happens to sit. The field is written in place and shared by
## reference; each index is written with it so that a peer disconnecting, which
## renumbers the list, cannot leave a racer bouncing off where it used to be
## itself.
##
## [b]The ghost is not in it[/b] — see [method Racer.collides], which is also
## why this cannot simply publish [member all].
func refresh_rivals() -> void:
	var slot: int = 0
	for racer: Racer in all:
		if racer.collides():
			slot += 1
	_rivals.resize(slot)
	slot = 0
	for racer: Racer in all:
		if not racer.collides():
			continue
		_rivals.set_state(slot, racer.state.position, racer.state.velocity)
		var sim := racer as SimulatedRacer
		if sim != null and sim.physics != null:
			sim.physics.rivals = _rivals
			sim.physics.rival_index = slot
			if sim.input_source is AIInputSource:
				var ai: AIInputSource = sim.input_source
				ai.rivals = _rivals.positions
				ai.rival_index = slot
		slot += 1

## Everyone on the hill, best progress first. What a standings HUD draws and
## what decides a finishing order.
func standings() -> Array[Racer]:
	var ordered: Array[Racer] = all.duplicate()
	ordered.sort_custom(func(a: Racer, b: Racer) -> bool:
		if a.finished != b.finished:
			return a.finished
		if a.finished and b.finished:
			return a.finish_time < b.finish_time
		return a.state.progress > b.state.progress)
	return ordered

## Where [param racer] is in the field, counting from 1. Zero if they are not on
## this hill at all.
func place_of(racer: Racer) -> int:
	return standings().find(racer) + 1

# ==================================================================
#                            multiplayer
# ==================================================================

## The racer for [param peer_id], built on first contact rather than from the
## roster, so a packet that beats its sender's introduction still lands
## somewhere — the name catches up when [signal RaceNetwork.roster_changed]
## fires.
func remote_for(peer_id: int) -> PlaybackRacer:
	var racer: PlaybackRacer = _remote.get(peer_id, null)
	if racer != null:
		return racer
	racer = PlaybackRacer.new()
	racer.name = "Peer%d" % peer_id
	racer.kind = Racer.Kind.REMOTE
	racer.peer_id = peer_id
	racer.display_name = Net.name_of(peer_id)
	racer.interpolation_delay = RaceNetwork.INTERPOLATION_DELAY
	racer.running = true
	add(racer, Net.character_of(peer_id))
	_remote[peer_id] = racer
	print("racer %d (%s) is on the hill" % [peer_id, racer.display_name])
	return racer

## Names arrived, or someone left. A racer whose peer has gone is removed
## outright rather than left standing on the slope — a motionless penguin at the
## point the connection dropped is worse than an empty hill.
func sync_remote() -> void:
	for peer_id: int in _remote.keys():
		if Net.roster.has(peer_id):
			_remote[peer_id].display_name = Net.name_of(peer_id)
			continue
		var racer: PlaybackRacer = _remote[peer_id]
		print("racer %d (%s) left" % [peer_id, racer.display_name])
		all.erase(racer)
		racer.queue_free()
		_remote.erase(peer_id)
