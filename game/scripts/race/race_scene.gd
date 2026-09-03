## The race: wires the node-free simulation to everything that draws.
##
## Layering per godot-port-plan.md §4.1 — [RacePhysics] knows nothing about any
## of this. It is handed a [SurfaceProvider] and two [ObjectGrid]s and stepped;
## the presentation reads its state afterwards.
##
## [b]There is more than one penguin on the hill.[/b] The scene owns a list of
## [Racer]s rather than a player: one [SimulatedRacer] for the person at the
## keyboard, up to nine more driven by an [AIInputSource], optionally a
## [PlaybackRacer] replaying their best run as a ghost, and one more per
## connected peer. The scene does not branch on which is which — it advances
## them all on the same tick and draws them all from the same [RacerState]. See
## [Racer] for the split, [AISkill] for the opponents and [RaceNetwork] for the
## session.
##
## [b]Two modes, one scene.[/b] [RaceSetup] is the whole of the difference:
## zero opponents is Practice, which is what the game did before and what every
## reference capture still gets, and one to nine is a race. Nothing else
## branches on it — an opponent is built the same way the player is and the
## presentation cannot tell them apart.
##
## [b]The simulation runs on a fixed tick[/b] ([constant SIM_HZ]) and the
## presentation interpolates between the last two. That is the other half of
## making more than one racer possible: a run has to mean the same thing at
## 30 fps and at 144, or a recorded ghost is not a fair opponent and two peers
## cannot agree about who reached the line first. It also makes the physics
## reproducible off the frame rate, which is what [ReplayInputSource] and the
## determinism test both depend on.
class_name RaceScene
extends Node3D

signal herring_changed(count: int)
signal race_completed(seconds: float, herring: int)

## Simulation ticks per second.
##
## 60 because that is what every reference capture was measured at
## (`tools/shot.sh` passes `--fixed-fps 60`), so moving to a fixed tick moved no
## frame: at exactly 1/60 s per frame the accumulator takes exactly one tick and
## comes out at zero. Above 60 fps the extra frames are interpolated, below it
## the tick catches up.
const SIM_HZ := 60
const SIM_DT := 1.0 / float(SIM_HZ)
## Ticks one frame may catch up by before the rest of the backlog is dropped.
##
## Without a cap a frame that took a second asks for 60 ticks, which takes
## longer than a frame, which asks for more — the spiral every fixed-timestep
## loop has to be stopped from entering. Dropping the backlog makes the race run
## slow for a moment, which is the right failure: the alternative is a game that
## never recovers from one hitch.
const MAX_TICKS_PER_FRAME := 8

## Seconds between crossing the finish line and the menu coming up, so the
## finish deceleration is watchable instead of being cut off by a panel.
const FINISH_MENU_DELAY := 3.0

## The clip [CharacterRig] plays before the race starts. `char/<name>/start.lst`
## in the original: Tux is standing off to one side of the start point, waddles
## across to it, turns to face down the hill and drops onto his belly.
const INTRO_CLIP := &"start"
## What `CIntro::Enter` passes `CKeyframe::Init` as its height correction, and
## the reason the standing pose sits into the snow rather than on top of it.
const INTRO_HEIGHT_CORRECTION := -0.05
## `SetCameraDistance(4.0)` in `CIntro::Enter`. Same number as the racing
## default, named here because the intro is where the original says it.
const INTRO_CAMERA_DISTANCE := 4.0

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

## Where "back" goes. Spelled out rather than reached for through [MainMenu]:
## that script already reaches in here for [member requested_course_path], and
## one direction of coupling between the two is enough.
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

@export_file("*.tscn") var course_scene_path: String = "res://courses/bunny_hill/course.tscn"
## What the shell asked for, and what it was last handed back.
##
## Static because a scene swap leaves nothing to set a property on: [MainMenu]
## writes it just before [method SceneTree.change_scene_to_file], `_ready` reads
## it, and [method load_course] keeps it current so the menu can highlight the
## course that was actually raced. Empty means [member course_scene_path] — the
## scene's own default, which is what opening `race.tscn` in the editor gets.
static var requested_course_path: String = ""
## A character named for this run only, overriding [member GameConfig.character]
## without writing to the settings file.
##
## Static for the same reason as [member requested_course_path], and set from
## the same two places: `--character=trixi` on the command line, or
## `?character=trixi` in the browser, where [MainMenu] reads the URL one scene
## before this one exists. Empty means "whoever the config file names".
static var requested_character: String = ""
## The field the shell asked for, or null for whatever the command line says —
## which is Practice unless it says otherwise.
##
## Static for the same reason as [member requested_course_path]: the shell picks
## the mode on a screen that no longer exists by the time this scene is built.
## Set by [CourseMenu] through [MainMenu]; cleared by nobody, so a session keeps
## racing the field it chose until it chooses another.
static var requested_setup: RaceSetup = null
## Whether the shell was asked for a race without the start animation.
##
## Static for the same reason as [member requested_course_path]: a browser has no
## command line, so `?nointro=1` is read where the rest of the URL is read — in
## [MainMenu], one scene before this one exists.
static var play_intro: bool = true
@export var environment_preset: EnvironmentPreset
## Snow deformation costs a 1024² render target per frame; off on the lowest tier.
@export var snow_deformation: bool = true
## Overrides the player's chosen character with one specific scene.
##
## Empty — the shipped value — means "whoever [member GameConfig.character]
## names", resolved through [CharacterCatalog] at `_ready`. This is the hook for
## pointing the race at a rig that is not in the catalog at all: authored skinned
## glTF art with the same joint names drops in here without an import run.
@export_file("*.tscn") var character_scene_path: String = ""

var course_root: CourseRoot
var terrain: TerrainRenderer
var snow_cpu: SnowField
var snow_gpu: SnowFieldGPU
var camera: ChaseCamera

## Everyone on the hill, in the order they were added. The local player is
## always the first entry.
var racers: Array[Racer] = []
## The person at the keyboard.
var local: SimulatedRacer
## The computer opponents, in start-line order. Empty in Practice.
var opponents: Array[SimulatedRacer] = []
## How many opponents this race has and how well they drive. Never null once
## `_ready` has run.
var setup: RaceSetup
## The player's best recorded run on this course, or null.
var ghost: PlaybackRacer
## Who the camera, the snow window and the HUD are about. The local player
## today; a spectator mode is this variable pointing somewhere else.
var view_target: Racer

var running: bool = false
## True while the start animation is playing. The simulation is not stepped —
## the character is posed straight out of the migrated keyframe — but the course
## is drawn and any key skips to the race, exactly as `CIntro` does it.
var intro_running: bool = false
## True while the course menu is up. The simulation is not stepped and no
## player input is read, but the course stays loaded and on screen behind it.
var paused: bool = false

var menu: CourseMenu
## Directory name of the loaded course, so the menu can highlight it.
var current_course_dir: String = ""
## Incremented by [method restart]; lets a deferred callback tell whether the
## race it was started for is still the one running.
var _run_id: int = 0

## How far the simulation is ahead of the frame being drawn, in seconds. Always
## in [0, [constant SIM_DT]) once [method _process] has topped it up.
##
## [b]Ahead, not behind[/b], and that is the whole subtlety of the loop. The
## obvious accumulator counts unspent frame time and draws between the last two
## ticks by `unspent / SIM_DT`, which puts the picture a full tick behind the
## clock — at exactly 60 fps there is never any unspent time, so it draws the
## [i]previous[/i] tick, every frame, forever. Every reference capture in the
## repository moved by 16.7 ms the first time this was written that way, and
## measurably: the procedural snow relief is view-dependent, so a fifteen-
## centimetre camera shift repainted a sixth of the frame.
##
## Running the simulation up to the frame instead — tick until it has passed the
## rendered instant, then interpolate back by how far it overshot — draws
## exactly at the frame's own time. At 60 fps the overshoot is zero and the draw
## is the live tick, bit for bit what the variable-timestep loop did.
var _sim_lead: float = 0.0

var _racers_root: Node3D
## Where everyone who is a body on the hill is, rebuilt in place each tick and
## shared by reference with every simulation and every opponent. See
## [method _refresh_rivals].
var _rivals := RacerField.new()
var _remote: Dictionary[int, PlaybackRacer] = {}
var _sun: DirectionalLight3D

## Root motion of the clip currently playing, sampled against [member _intro_time].
var _intro_path: KeyframePath
var _intro_time: float = 0.0
## The camera framing the race wants back once the intro is over.
var _camera_mode_before_intro: ChaseCamera.Mode = ChaseCamera.Mode.BEHIND
var _camera_distance_before_intro: float = 4.0
## Whether this run wants the start animation at all. A scripted run does not:
## `--auto-input=` is a stand-in for a player, and four and a half seconds of Tux
## waddling in front of a frame counter would move every reference capture. A
## networked race does not either — see [method _begin_intro].
var _intro_enabled: bool = true

## The terrain slide effect currently looping, or empty. ETR keeps the same
## pair of "last"/"new" ids in `racing.cpp`.
var _slide_cue: StringName = &""
## Reused by the once-a-frame terrain query behind the slide sound, so the
## audio does not allocate on the hot path.
var _slide_sample := SurfaceSample.new()

## Development-only scripted input, for headless verification shots.
## `--auto-input=carve` slaloms, `--auto-input=brake` drags the belly.
var _auto_input: String = ""
## `--opponents=N --difficulty=hard`: a field without going through the shell.
## Used only when the shell has not asked for one.
var _cli_setup := RaceSetup.new()
## `--remote-keyboard`: bridge a keyboard arriving as zero-length pulses.
var _compensate_keys: bool = false

# ------------------------------------------------------------------
#      what used to be scene state and is now the local racer's
# ------------------------------------------------------------------

## The local player's simulation. Kept as a property because the HUD, the menu
## and the tests all grew up reading `race.physics`, and because "the physics"
## is still a meaningful thing to ask a race for — it is just one racer's now.
var physics: RacePhysics:
	get:
		return local.physics if local != null else null

var race_time: float:
	get:
		return local.race_time if local != null else 0.0

var herring: int:
	get:
		return local.herring if local != null else 0

# ==================================================================
#                              setup
# ==================================================================

func _ready() -> void:
	camera = $ChaseCamera
	snow_gpu = $SnowFieldGPU
	_racers_root = $Racers
	_sun = $Sun
	if not requested_course_path.is_empty():
		course_scene_path = requested_course_path
	# A `--course=` on the command line outranks it: a capture run names the
	# course it wants, and the shell only ever passes on what it was given.
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--auto-input="):
			_auto_input = arg.trim_prefix("--auto-input=")
		elif arg.begins_with("--camera="):
			if arg.ends_with("above"):
				camera.mode = ChaseCamera.Mode.ABOVE
			elif arg.ends_with("trail"):
				camera.mode = ChaseCamera.Mode.TRAIL
		elif arg == "--remote-keyboard":
			_compensate_keys = true
		elif arg == "--no-intro":
			play_intro = false
		elif arg.begins_with("--course="):
			course_scene_path = "res://courses/%s/course.tscn" % arg.trim_prefix("--course=")
		elif arg.begins_with("--character="):
			requested_character = arg.trim_prefix("--character=")
		elif arg.begins_with("--opponents="):
			_cli_setup.opponents = clampi(
				arg.trim_prefix("--opponents=").to_int(), 0, RaceSetup.MAX_OPPONENTS)
		elif arg.begins_with("--difficulty="):
			_cli_setup.skill = AISkill.parse(arg.trim_prefix("--difficulty="))
	# The shell outranks the command line here, unlike `--course=`: the two flags
	# are a way to start a race without a menu, not a way to keep overriding a
	# choice the player has just made on one.
	setup = requested_setup.copy() if requested_setup != null else _cli_setup
	# After the arguments, not before: `--character=` names a rig and this is
	# where it has been read. The start animation is per character too — Trixi's
	# `start.lst` is not Tux's — so the rig has to exist before the intro is set
	# up on the course load below.
	_create_local_racer()
	_create_opponents()
	_intro_enabled = play_intro and _auto_input.is_empty()
	menu = $CourseMenu
	menu.course_chosen.connect(_on_course_chosen)
	menu.closed.connect(_on_menu_closed)
	menu.back_requested.connect(leave_to_main_menu)
	Net.snapshot_received.connect(_on_snapshot_received)
	Net.roster_changed.connect(_sync_remote_racers)
	load_course(course_scene_path)

## Build the player and put them on the hill.
##
## Which character is the player's choice — [member GameConfig.character], or a
## `--character=`/`?character=` naming one for this run only. Anything the
## catalog cannot resolve comes back as Tux rather than as an error; see
## [method CharacterCatalog.scene_path_for].
func _create_local_racer() -> void:
	local = SimulatedRacer.new()
	local.name = "LocalRacer"
	local.kind = Racer.Kind.LOCAL
	local.display_name = Config.player_name
	if _auto_input.is_empty():
		var keyboard := LocalInputSource.new()
		keyboard.compensate = _compensate_keys
		local.input_source = keyboard
		local.recorder = RaceRecorder.new()
	else:
		# A scripted run is a stand-in for a player, not a player. It neither
		# keeps a ghost nor races one — see [method _scripted_run].
		local.input_source = ScriptedInputSource.new(_auto_input)
	_add_racer(local, _local_character_dir(), character_scene_path)
	view_target = local
	local.item_collected.connect(_on_item_collected)
	local.tree_hit.connect(_on_tree_hit)
	local.racer_hit.connect(_on_racer_hit)
	local.finished_race.connect(_on_racer_finished)

func _local_character_dir() -> String:
	return requested_character if not requested_character.is_empty() else Config.character

## Build the field.
##
## An opponent is not a special kind of racer — it is exactly what
## [method _create_local_racer] builds, with an [AIInputSource] where the
## keyboard goes and no recorder, because a ghost is the player's own best run
## and a computer's is not a time anybody set. Everything downstream — the
## simulation, the spray, the snow stamps, the herring grid, the rig, the
## interpolated draw, the standings — is the same code path.
##
## Each opponent gets its own character where there are enough to go round, its
## own seat in the start line and its own personality drawn from that seat, so a
## field of nine is nine racers rather than one drawn nine times.
func _create_opponents() -> void:
	if setup == null or not setup.is_race():
		return
	var catalog: CharacterCatalog = CharacterCatalog.load_default()
	# The player is already wearing one of the five, so the first opponent to
	# reach it is the second of that character on the hill and is named as such.
	var worn: Dictionary[String, int] = {_local_character_dir(): 1}
	for i: int in setup.opponents:
		var racer := SimulatedRacer.new()
		racer.name = "Opponent%d" % (i + 1)
		racer.kind = Racer.Kind.AI
		racer.spray_pool = OPPONENT_SPRAY_POOL
		racer.start_offset = RaceSetup.lane_offset(i)
		racer.input_source = AIInputSource.new(AISkill.for_level(setup.skill), i, 0)
		var listing: CharacterListing = _opponent_character(catalog, i)
		var dir: String = listing.dir if listing != null else CharacterCatalog.DEFAULT_DIR
		racer.display_name = _opponent_name(listing, dir, worn)
		_add_racer(racer, dir)
		# Only the collection matters here — [method _on_item_collected] hides
		# the fish for everyone and plays the cue for the player alone. A tree an
		# opponent hits is deliberately not connected: the mixer has one voice
		# per cue and no positional audio, so it would sound like the player's.
		racer.item_collected.connect(_on_item_collected)
		racer.finished_race.connect(_on_racer_finished)
		opponents.push_back(racer)
	print("field: %s" % setup.describe())

## Replace the field with one built from the current [member setup]. Called when
## the in-race menu comes back with a different number of opponents.
func _rebuild_opponents() -> void:
	for racer: SimulatedRacer in opponents:
		racers.erase(racer)
		# Out of the tree before the free, not just queued for it: `queue_free`
		# leaves the node a child until the end of the frame, and the
		# replacements go in under the same names.
		_racers_root.remove_child(racer)
		racer.queue_free()
	opponents.clear()
	_create_opponents()
	if course_root != null:
		for racer: SimulatedRacer in opponents:
			_build_simulation(racer, course_root.course_data)

## Which character an opponent races as. The catalog in order, starting after
## the player's own, so the racer beside you is never wearing your suit until
## there are more opponents than characters.
func _opponent_character(catalog: CharacterCatalog, index: int) -> CharacterListing:
	if catalog == null or catalog.entries.is_empty():
		return null
	var start: int = catalog.index_of(_local_character_dir())
	return catalog.entries[(start + 1 + index) % catalog.entries.size()]

## What the standings call an opponent. The character's own name, which is what
## a player would call the penguin they can see — numbered from the second one
## wearing it, because two racers called Trixi on one line is not a standing.
##
## [param worn] counts how many of each character are already on the hill and is
## updated here. It starts with the player's own, so a field large enough to
## come round the catalog produces "Tux 2" beside a player racing as Tux, rather
## than a second plain Tux nobody can tell from the one they are steering.
func _opponent_name(listing: CharacterListing, dir: String,
		worn: Dictionary[String, int]) -> String:
	var base: String = listing.title() if listing != null else "Racer"
	var nth: int = worn.get(dir, 0) + 1
	worn[dir] = nth
	return base if nth == 1 else "%s %d" % [base, nth]

## Put a racer in the tree, give it a rig and register it. [param scene_path]
## overrides the catalog lookup; empty means "look [param character_dir] up".
func _add_racer(racer: Racer, character_dir: String, scene_path: String = "") -> void:
	racer.character_dir = character_dir
	_racers_root.add_child(racer)
	var path: String = scene_path
	if path.is_empty():
		path = CharacterCatalog.load_default().scene_path_for(character_dir)
	if not racer.install_character(path):
		racer.install_fallback_mesh()
	racers.push_back(racer)

# ==================================================================
#                          loading a course
# ==================================================================

func load_course(path: String) -> void:
	_stop_slide_sound()
	Audio.halt_all()
	if course_root != null:
		course_root.queue_free()
		course_root = null
	if terrain != null:
		terrain.queue_free()
		terrain = null

	current_course_dir = path.get_base_dir().get_file()
	requested_course_path = path
	var packed: PackedScene = load(path)
	course_root = packed.instantiate()
	add_child(course_root)
	course_root.build_runtime()

	var course: CourseData = course_root.course_data

	snow_cpu = SnowField.new()
	course_root.surface.snow_field = snow_cpu

	# One simulation per simulated racer, all against the same surface and the
	# same two object grids. Sharing the grids is what makes the herring a race
	# rather than a pair of solitaires; sharing the surface is free, since a
	# [SurfaceProvider] is read-only apart from the snow field.
	for racer: Racer in racers:
		if racer is SimulatedRacer:
			_build_simulation(racer as SimulatedRacer, course)

	terrain = TerrainRenderer.new()
	terrain.name = "Terrain"
	add_child(terrain)
	terrain.setup(course, course_root.surface)

	camera.surface = course_root.surface
	camera.reset()

	var preset: EnvironmentPreset = environment_preset
	if preset == null and course.environment_preset is EnvironmentPreset:
		preset = course.environment_preset
	if preset != null:
		_apply_environment(preset)

	_setup_ghost()
	restart()

func _build_simulation(racer: SimulatedRacer, course: CourseData) -> void:
	var sim := RacePhysics.new()
	sim.surface = course_root.surface
	sim.trees = course_root.trees
	sim.items = course_root.items
	sim.bounds_polygon = course.effective_play_bounds()
	sim.play_length = course.play_size.y
	sim.finish_brake = course.finish_brake
	racer.attach_physics(sim)
	racer.snow_cpu = snow_cpu
	# One 64 m GPU window exists and it follows the view target, so only that
	# racer can usefully stamp it. Everyone else deforms the CPU mirror, which
	# is what the physics reads and is course-wide.
	racer.snow_gpu = snow_gpu if snow_deformation and racer == view_target else null

## Whether a stand-in is driving rather than a person.
##
## `--auto-input=` is every reference capture and the whole headless
## verification path, and it is deliberately kept out of the ghost system in
## both directions. Not saving is the important half: a capture that set a best
## time would leave a file behind, and every later capture of that course would
## come out with a second penguin on the slope — a difference between two
## machines that nothing in the frame explains. Not showing one follows from the
## same argument, and means a developer who has actually raced the course still
## gets the reference frame everyone else does.
func _scripted_run() -> bool:
	return not _auto_input.is_empty()

## Load the best recorded run for this course, if the player wants one.
##
## Not in a race against opponents. A ghost is a second penguin on your own line
## and the HUD has one status line to say something on — with a field on the
## hill that line is the standings, and the translucent copy of yourself is one
## more thing to mistake for someone you are racing. The recording still happens
## and a best time is still kept; only the drawing is dropped.
func _setup_ghost() -> void:
	if ghost != null:
		racers.erase(ghost)
		ghost.queue_free()
		ghost = null
	if not Config.ghosts or _scripted_run() or setup.is_race():
		return
	var recording: RaceRecording = GhostStore.load_for(current_course_dir)
	if recording == null:
		return
	var racer := PlaybackRacer.new()
	racer.name = "Ghost"
	racer.kind = Racer.Kind.GHOST
	racer.display_name = GHOST_LABEL
	if not racer.play_recording(recording):
		racer.queue_free()
		return
	_add_racer(racer, recording.character_dir)
	racer.make_translucent(GHOST_TINT)
	ghost = racer

## Put the race back at the start line. [param with_intro] is what separates the
## two ways in: choosing a course runs the start animation, where `r` mid-race is
## the original's Reset state and goes straight back to racing.
func restart(with_intro: bool = true) -> void:
	_run_id += 1
	var course: CourseData = course_root.course_data
	var start := Vector2(course.start_position.x, -course.start_position.y)
	running = true
	intro_running = false
	_sim_lead = 0.0
	snow_cpu = SnowField.new()
	course_root.surface.snow_field = snow_cpu
	if snow_gpu != null:
		snow_gpu.reset()
	# The herring are back. `hide_item` collapsed their instance transforms and
	# `collectable` was cleared on the shared grid; a restart that skipped this
	# left the course stripped of everything the last run picked up, which a
	# ghost of that run makes obvious — it collects fish that are not there.
	course_root.reset_items()
	for racer: Racer in racers:
		if racer is SimulatedRacer:
			var sim: SimulatedRacer = racer
			sim.snow_cpu = snow_cpu
			# The player has no offset and is not put through the clamp at all:
			# their start point is the course's own, whoever else is on the line.
			# A course whose start sits inside [constant RaceSetup.LANE_MARGIN]
			# of its own boundary would otherwise be moved by the field existing,
			# and every reference capture with it.
			var x: float = start.x
			if sim.start_offset != 0.0:
				x = RaceSetup.lane_x(x + sim.start_offset, course.effective_play_bounds())
			sim.restart(x, start.y, current_course_dir)
		elif racer is PlaybackRacer:
			(racer as PlaybackRacer).restart()
		racer.present(1.0)
	camera.reset()
	herring_changed.emit(0)
	terrain.update_streaming(local.state.position)
	# Drop the authoring markers only once the batches and grids exist.
	course_root.release_markers()
	_stop_slide_sound()
	Audio.play_theme(course.music_theme, MusicTheme.Situation.RACE)
	# Marker for the browser harness: the course is loaded and the first frame
	# of simulation has run.
	print("RACE_READY %s %d chunks" % [course.display_name, terrain.chunk_count()])
	if with_intro and _intro_enabled and not Net.active():
		_begin_intro()

# ==================================================================
#                          the frame loop
# ==================================================================

func _process(delta: float) -> void:
	if paused:
		return
	if Input.is_action_just_pressed("reset_race"):
		# The original's Reset state re-enters Racing, not Intro: `r` is for
		# getting back on the hill, not for watching the walk again.
		restart(false)
		return

	_sim_lead -= delta
	var ticks: int = 0
	while _sim_lead < 0.0 and ticks < MAX_TICKS_PER_FRAME:
		_simulation_tick(SIM_DT)
		_sim_lead += SIM_DT
		ticks += 1
	if _sim_lead < 0.0:
		# The cap bit: the frame asked for more simulation than it is allowed to
		# run. Give up on the backlog rather than carry it, or the next frame
		# asks for more again.
		_sim_lead = 0.0

	var alpha: float = clampf(1.0 - _sim_lead / SIM_DT, 0.0, 1.0)
	for racer: Racer in racers:
		racer.present(alpha)
	_present(delta)

## One fixed step of everything that is part of the race rather than part of
## the picture.
func _simulation_tick(dt: float) -> void:
	if intro_running:
		_step_intro(dt)
		return
	if not running:
		return
	_refresh_rivals()
	for racer: Racer in racers:
		racer.advance(dt)
	if Net.active() and local != null:
		Net.publish(local.state)
	_update_slide_sound()
	# The CPU mirror follows the local player, not the view target: it is what
	# the physics reads under this machine's racer, and it is never drawn. The
	# GPU window, which is only ever drawn, follows the view target instead.
	snow_cpu.recenter(local.state.position.x, local.state.position.z)
	snow_cpu.decay(dt)

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
## why this cannot simply publish [member racers].
func _refresh_rivals() -> void:
	var slot: int = 0
	for racer: Racer in racers:
		if racer.collides():
			slot += 1
	_rivals.resize(slot)
	slot = 0
	for racer: Racer in racers:
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

## Everything that follows the simulation and is allowed to run at the screen's
## rate rather than the simulation's: the camera lag, the streaming window, the
## particle rates and the deformation render target.
func _present(delta: float) -> void:
	for racer: Racer in racers:
		if racer is SimulatedRacer:
			(racer as SimulatedRacer).spray.flush(delta)
	if view_target == null:
		return
	var view: RacerState = view_target.view_state()
	if intro_running:
		camera.track(local.global_position, Vector3.ZERO, Vector3.UP, delta)
	else:
		camera.track(view.position, view.velocity, view_target.surface_normal(), delta)
	terrain.update_streaming(view.position)
	if snow_deformation and snow_gpu != null:
		snow_gpu.update(view.position.x, view.position.z, delta)
		terrain.set_trail_map(snow_gpu.trail_texture(), snow_gpu.window_origin(),
			snow_gpu.window_extent(), snow_gpu.max_depth)

# ==================================================================
#                          the start animation
# ==================================================================

## `CIntro` in the original: the course is up and lit, the racing theme is
## already playing, and the character walks itself to the start line before the
## simulation is handed the controls.
##
## Nothing here touches the simulation. The keyframe writes the body transform
## directly — the original does the same thing, overwriting `ctrl->cpos` from
## `CKeyframe::Update` every frame — and the simulation is stepped from the same
## start point it was initialised at once the animation is done, so there is
## nothing to hand over.
##
## Skipped in a networked race. Four and a half seconds of walking is fine when
## it is your own clock; between peers it is four and a half seconds of nobody
## agreeing when the race began, and a countdown everyone starts on is a
## different feature from the original's start animation.
func _begin_intro() -> void:
	if local.rig == null or not local.rig.play_clip(INTRO_CLIP):
		return
	_intro_path = local.rig.path_for(INTRO_CLIP)
	if _intro_path == null:
		local.rig.stop_clip()
		return
	running = false
	local.running = false
	intro_running = true
	_intro_time = 0.0
	# `set_view_mode(ctrl, ABOVE)` — the one camera that does not need a
	# direction of travel to point itself, which during the intro there is none of.
	_camera_mode_before_intro = camera.mode
	_camera_distance_before_intro = camera.distance
	camera.mode = ChaseCamera.Mode.ABOVE
	camera.distance = INTRO_CAMERA_DISTANCE
	_apply_intro_pose(0.0)
	local.snap()
	local.present(1.0)
	camera.reset()
	camera.track(local.global_position, Vector3.ZERO, Vector3.UP, 0.0)

func _step_intro(dt: float) -> void:
	_intro_time += dt
	if _intro_time >= _intro_path.duration():
		_end_intro()
		return
	_apply_intro_pose(_intro_time)
	local.rig.seek_clip(_intro_time)

## Place the body where the keyframe says, on the hill rather than in it.
##
## `CKeyframe::Update` reads the authored Y as a clearance above the terrain and
## adds `Course.FindYCoord` to it, which is why a canned animation plays on any
## course. The rotation is the same yaw/pitch/roll the original hands node 0,
## turned into the frame this scene positions the character in — see
## [method CharacterRig.parent_basis_for].
##
## Writes the racer's state rather than its transform: the drawing still goes
## through [method Racer.present], so the walk is interpolated between ticks
## like everything else.
func _apply_intro_pose(t: float) -> void:
	var course: CourseData = course_root.course_data
	var origin := Vector2(course.start_position.x, -course.start_position.y)
	var offset: Vector3 = _intro_path.offset_at(t)
	var x: float = origin.x + offset.x
	var z: float = origin.y + offset.z
	var basis: Basis = local.rig.parent_basis_for(_intro_path.basis_at(t))
	var y: float = course_root.surface.height_at(x, z) + offset.y \
		+ PhysConst.TUX_Y_CORR + INTRO_HEIGHT_CORRECTION
	local.apply_pose(Vector3(x, y, z), basis)

## Hand over to the simulation. Reached either by the animation running out or by
## a key — the original aborts on any keypress too, and that is most of what the
## intro is for: it is a four-and-a-half second pause you are meant to be able to
## cut short.
func _end_intro() -> void:
	if not intro_running:
		return
	intro_running = false
	_intro_path = null
	if local.rig != null:
		local.rig.stop_clip()
	camera.mode = _camera_mode_before_intro
	camera.distance = _camera_distance_before_intro
	camera.reset()
	running = true
	local.running = true
	# The intro left the racer standing at the start point; the simulation is
	# about to carry on from where `init_at` put it. Collapsing the window stops
	# the first frame interpolating between the two.
	local.state.capture(local.physics, 0.0, 0)
	local.snap()

# ==================================================================
#                            multiplayer
# ==================================================================

## A snapshot arrived. The peer's racer is created on first contact rather than
## from the roster, so a packet that beats its sender's introduction still lands
## somewhere — the name catches up when [signal RaceNetwork.roster_changed]
## fires.
func _on_snapshot_received(peer_id: int, packet: PackedFloat32Array) -> void:
	var racer: PlaybackRacer = _remote.get(peer_id, null)
	if racer == null:
		racer = _spawn_remote(peer_id)
	racer.push_snapshot(packet)
	racer.trim_history()

func _spawn_remote(peer_id: int) -> PlaybackRacer:
	var racer := PlaybackRacer.new()
	racer.name = "Peer%d" % peer_id
	racer.kind = Racer.Kind.REMOTE
	racer.peer_id = peer_id
	racer.display_name = Net.name_of(peer_id)
	racer.interpolation_delay = RaceNetwork.INTERPOLATION_DELAY
	racer.running = true
	_add_racer(racer, Net.character_of(peer_id))
	_remote[peer_id] = racer
	print("racer %d (%s) is on the hill" % [peer_id, racer.display_name])
	return racer

## Names arrived, or someone left. A racer whose peer has gone is removed
## outright rather than left standing on the slope — a motionless penguin at the
## point the connection dropped is worse than an empty hill.
func _sync_remote_racers() -> void:
	for peer_id: int in _remote.keys():
		if Net.roster.has(peer_id):
			_remote[peer_id].display_name = Net.name_of(peer_id)
			continue
		var racer: PlaybackRacer = _remote[peer_id]
		print("racer %d (%s) left" % [peer_id, racer.display_name])
		racers.erase(racer)
		racer.queue_free()
		_remote.erase(peer_id)

## Everyone on the hill, best progress first. What a standings HUD draws and
## what decides a finishing order.
func standings() -> Array[Racer]:
	var ordered: Array[Racer] = racers.duplicate()
	ordered.sort_custom(func(a: Racer, b: Racer) -> bool:
		if a.finished != b.finished:
			return a.finished
		if a.finished and b.finished:
			return a.finish_time < b.finish_time
		return a.state.progress > b.state.progress)
	return ordered

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

## Where [param racer] is in the field, counting from 1. Zero if they are not on
## this hill at all.
func place_of(racer: Racer) -> int:
	return standings().find(racer) + 1

## `1st`..`10th` from the imported string table, which is exactly as far as it
## goes — and exactly as far as a field of ten needs it to.
func place_label(place: int) -> String:
	const ORDINALS: PackedStringArray = ["1ST", "2ND", "3RD", "4TH", "5TH",
		"6TH", "7TH", "8TH", "9TH", "10TH"]
	if place < 1 or place > ORDINALS.size():
		return str(place)
	return tr(ORDINALS[place - 1])

# ==================================================================
#                           course menu
# ==================================================================

func open_menu(result_text: String = "") -> void:
	if menu == null or menu.visible:
		return
	paused = true
	_stop_slide_sound()
	# The original's menus all play `param.menu_music`, and its game-over screen
	# plays the theme's win sting — which is the screen this becomes when it
	# comes up carrying a result. Opening the menu mid-race is the other case.
	if result_text.is_empty():
		Audio.play_menu_music()
	else:
		Audio.halt_all()
		Audio.play_theme(course_root.course_data.music_theme, MusicTheme.Situation.WON)
	menu.open(current_course_dir, running, setup, result_text)

func _on_menu_closed() -> void:
	paused = false
	# A pause is not simulated time. Without this the first frame after the menu
	# closes owes the simulation the whole time it was up, and the race either
	# catches up in one lurch or — past the tick cap — drops it and looks right
	# by accident.
	_sim_lead = 0.0
	Audio.play_theme(course_root.course_data.music_theme, MusicTheme.Situation.RACE)

## The menu came back with a course and — since it is the same panel that offers
## the field — possibly a different one of those too. A changed field is rebuilt
## before the restart, so that racing the same course again with two more
## opponents does not need the scene reloading.
func _on_course_chosen(listing: CourseListing, chosen: RaceSetup) -> void:
	paused = false
	_sim_lead = 0.0
	var field_changed: bool = not chosen.matches(setup)
	setup = chosen.copy()
	# What the shell offers next time, and what a scene swap carries.
	requested_setup = setup.copy()
	if field_changed:
		_rebuild_opponents()
	if listing.dir == current_course_dir:
		if field_changed:
			# Practice and a race disagree about whether a ghost is drawn.
			_setup_ghost()
		restart()
		return
	course_scene_path = listing.scene_path
	load_course(course_scene_path)

## Drop the race and go back to the shell — the original's "abort race", which
## now has somewhere to go. The scene is replaced rather than kept around: a
## loaded course is most of the memory in the game and the menu behind it does
## not need a slope to draw over.
func leave_to_main_menu() -> void:
	_stop_slide_sound()
	Audio.halt_all()
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)

## Esc opens the menu mid-race and closes it again — except during the start
## animation, where every key including that one skips to the race. That is
## `CIntro::Keyb`, which takes any press at all and aborts.
func _unhandled_input(event: InputEvent) -> void:
	if intro_running and not paused and _is_skip_press(event):
		get_viewport().set_input_as_handled()
		_end_intro()
		return
	if not event.is_action_pressed("menu"):
		return
	get_viewport().set_input_as_handled()
	if menu != null and menu.visible:
		menu.close()
	else:
		open_menu()

## A real press of anything a player could press. Echoes are held keys repeating
## and mouse motion is not a press, but a keyboard forwarded as zero-length
## pulses still arrives here as an ordinary [InputEventKey] — this is edge
## detection on the event itself, not on
## [method Input.is_action_just_pressed], and so does not need [KeyHoldFilter].
static func _is_skip_press(event: InputEvent) -> bool:
	if event is InputEventKey:
		return event.is_pressed() and not event.is_echo()
	return event is InputEventMouseButton and event.is_pressed() \
		or event is InputEventJoypadButton and event.is_pressed()

## What the menu shows above the list when it comes up after a finish.
##
## The place goes first in a race, because it is the answer to the question the
## player asked by entering one. It is read at the moment the panel is built —
## three seconds after the line, by which point the opponents who were going to
## beat you have — and it is a place among everyone still racing, so an opponent
## a hundred metres up the hill is behind you and counted as such.
func _result_line() -> String:
	var line: String = "%s   —   %s %.2f %s   %s %d" % [
		tr("RACE_OVER"), tr("TIME"), race_time, tr("SECONDS"), tr("HERRING"), herring]
	if not setup.is_race():
		return line
	return "%s %s   —   %s" % [tr("POSITION"), place_label(place_of(local)), line]

func _apply_environment(preset: EnvironmentPreset) -> void:
	var we: WorldEnvironment = $WorldEnvironment
	var env: Environment = preset.to_environment()
	# The preset knows what `light.lst` said; the settings file knows how far
	# the player wants to see. Fog distance is the one place the two meet.
	Config.apply_fog(env, preset)
	we.environment = env
	_sun.light_color = preset.sun_color
	_sun.light_energy = preset.sun_energy
	_sun.look_at_from_position(Vector3.ZERO, -preset.sun_direction, Vector3.UP)
	_sun.directional_shadow_max_distance = _shadow_range_for(env)
	for racer: Racer in racers:
		if racer is SimulatedRacer:
			(racer as SimulatedRacer).spray.particle_color = preset.particle_color
	if terrain != null:
		# What the ice reflects. The horizon end is the fog colour: at the
		# grazing angle a chase camera reflects at, ETR's sky is its own white
		# haze, and the skybox's nadir average is a downward direction ice
		# never shows you.
		terrain.set_sky_tint(preset.sky_zenith_color, preset.fog_color)

## How far directional shadows have to reach for this environment.
##
## Godot stops drawing them past `directional_shadow_max_distance` and fades
## them out over the last tenth. Set shorter than the visible slope, that cutoff
## is an arc centred on the camera: a shadowed bowl in front of the player and
## bare white hillside beyond it, moving with the view. The old fixed 120 m sat
## well inside a 190 m fog range and a 400 m far plane, so the arc was in shot
## most of the time.
##
## Tying the range to where fog has already washed the terrain out puts the
## cutoff somewhere it cannot be read. Four PSSM splits with blending keep the
## near-field resolution the longer range would otherwise cost.
##
## Read off the built [Environment] rather than off the preset, so a range the
## settings file has stretched carries the shadows out with it.
func _shadow_range_for(env: Environment) -> float:
	if not env.fog_enabled:
		return camera.far
	return clampf(env.fog_depth_end, 120.0, camera.far)

# ==================================================================
#                       events off the simulation
# ==================================================================

func _on_item_collected(racer: SimulatedRacer, index: int) -> void:
	course_root.hide_item(index)
	if racer != local:
		return
	herring_changed.emit(racer.herring)
	# Three cues, fired together, deliberately: the original has one voice per
	# sound, so a single pickup effect could never have layered with itself.
	Audio.play(&"pickup1")
	Audio.play(&"pickup2")
	Audio.play(&"pickup3")

func _on_tree_hit(racer: SimulatedRacer, _tree_pos: Vector3) -> void:
	# Somebody else hitting a tree three hundred metres up the hill is not a
	# sound this player should hear. A distance-attenuated version of it is a
	# real improvement and needs positional audio, which the one-voice-per-cue
	# mixer does not have.
	if racer == local:
		Audio.play(&"tree_hit")

## The player ran into somebody. Only the player's own contacts are connected,
## for the reason above — and only the player's, not the opponents', because a
## contact is resolved by both bodies and connecting both ends would fire the
## cue twice for one bump.
##
## DEVIATION: `tree_hit` is the sound of hitting a tree, and it is the only
## impact the original ships — there is nobody on its hill to run into, so there
## is no cue for it. Reusing the thud is closer to right than silence: a
## collision the player can feel in the steering and cannot hear reads as the
## physics glitching.
func _on_racer_hit(_racer: SimulatedRacer, _rival: int) -> void:
	Audio.play(&"tree_hit")

func _on_racer_finished(racer: Racer) -> void:
	if racer != local:
		return
	race_completed.emit(local.race_time, local.herring)
	_store_ghost()
	_show_menu_after_finish(_run_id)

## Keep the run if it beat the stored one. Nothing is asked of the player and
## nothing is said about it — a personal best that announces itself needs a
## screen to announce itself on, and this is the phase that has no results
## screen yet.
func _store_ghost() -> void:
	if local.recorder == null:
		return
	var recording: RaceRecording = local.recorder.finish(
		local.race_time, local.herring, true)
	GhostStore.save_if_best(recording)

## Bring the menu up once the finish deceleration has played out, unless the
## player restarted or picked another course in the meantime.
func _show_menu_after_finish(run_id: int) -> void:
	await get_tree().create_timer(FINISH_MENU_DELAY).timeout
	if run_id == _run_id and not paused:
		open_menu(_result_line())

# ------------------------------------------------------------------
#                          terrain slide loop
# ------------------------------------------------------------------

## `PlayTerrainSound` in `racing.cpp`: the terrain under the player names a
## looping cue, which is halted when the terrain changes or the player leaves
## the ground. There is no speed or lean term — the original wrote one
## (`SlideVolume`) and left it commented out with "this function is not used
## yet", so the slide is on or off and nothing else.
##
## The local player's terrain, not the view target's and not anyone else's: the
## mixer has one voice per cue and no positional audio, so a second racer's
## slide would be indistinguishable from the player's own.
##
## DEVIATION: the terrain is the dominant splat layer at the contact point,
## where the original took `Course.GetTerrainIdx(x, z, 0.5)` — the type holding
## at least half the blend, else nothing. Ours always resolves to a layer, so
## the sound changes a little earlier across a boundary; the flip side is that
## no blend of terrains is ever silent when both halves make a noise.
func _update_slide_sound() -> void:
	var cue: StringName = &""
	var sim: RacePhysics = local.physics
	if sim != null and not sim.airborne:
		course_root.surface.sample_into(sim.pos.x, sim.pos.z, _slide_sample)
		var layers: Array[TerrainLayer] = course_root.course_data.terrain_layers
		var id: int = _slide_sample.terrain_id
		if id >= 0 and id < layers.size() and layers[id] != null:
			cue = layers[id].slide_sound
	if cue != _slide_cue:
		if not _slide_cue.is_empty():
			Audio.halt(_slide_cue)
		_slide_cue = cue
	if not cue.is_empty():
		Audio.play(cue, true)

func _stop_slide_sound() -> void:
	if not _slide_cue.is_empty():
		Audio.halt(_slide_cue)
		_slide_cue = &""
