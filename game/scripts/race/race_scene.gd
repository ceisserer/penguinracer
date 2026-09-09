## The race: wires the node-free simulation to everything that draws.
##
## Layering per godot-port-plan.md §4.1 — [RacePhysics] knows nothing about any
## of this. It is handed a [SurfaceProvider] and two [ObjectGrid]s and stepped;
## the presentation reads its state afterwards.
##
## [b]There is more than one penguin on the hill.[/b] [RacerRoster] owns the
## list — one [SimulatedRacer] for the person at the keyboard, up to nine more
## driven by an [AIInputSource], optionally a [PlaybackRacer] replaying a
## saved run as a ghost, and one more per connected peer. The scene does not
## branch on which is which: it advances them all on the same tick and draws
## them all from the same [RacerState]. See [Racer] for the split, [AISkill] for
## the opponents and [RaceNetwork] for the session.
##
## [b]What this file is, and what it is not.[/b] It is the tick loop and the
## course: loading one, lighting it, stepping the simulation against it, and
## handing over to the shell. Three things it used to also be have their own
## files now — [RacerRoster] (who is on the hill and who is winning),
## [IntroSequence] (the start animation and the camera it borrows) and
## [LaunchArgs] (what this run was asked for). Each was extracted whole, with no
## behaviour change: the reference capture is byte-identical across all three.
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

## What `CGameOver::Enter` passes `CKeyframe::Init` as its height correction —
## the counterpart of [constant IntroSequence.HEIGHT_CORRECTION], and a deeper
## number because the standing pose of a finish clip has its feet a little
## further below the reference point than the start animation's does.
const FINISH_HEIGHT_CORRECTION := -0.18

## What a ghost is called on the HUD. Lives on [RacerRoster] with the rest of
## the field; named here because [RaceHUD] has always asked the scene for it.
const GHOST_LABEL := RacerRoster.GHOST_LABEL

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
## A saved run to race against, or null for none.
##
## Static for the same reason as [member requested_course_path], but consumed
## rather than kept: [GhostMenu] sets it and [MainMenu] hands over the same
## way it does for a chosen course, `_ready` reads it into
## [member _active_ghost_recording] and clears it immediately — one race, not
## a mode that persists like [member requested_setup] does, because it names
## one specific file rather than a kind of race.
static var requested_ghost: RaceRecording = null
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

## Everyone on the hill: the player, the field, the ghost and any peers. See
## [RacerRoster], which owns building them and ordering them.
var roster: RacerRoster
## How many opponents this race has and how well they drive. Never null once
## `_ready` has run.
var setup: RaceSetup

var running: bool = false
## True while the start animation is playing. The simulation is not stepped —
## the character is posed straight out of the migrated keyframe — but the course
## is drawn and any key skips to the race, exactly as `CIntro` does it.
var intro_running: bool = false
## True while the course menu is up, or while `P` has frozen the race on its
## own. Either way the simulation is not stepped and no player input is read,
## but the course stays loaded and on screen behind it.
var paused: bool = false
## True while the freeze is `P`'s rather than the course menu's — the two are
## mutually exclusive so a stray key cannot leave the game paused with nothing
## on screen saying so.
var _key_paused: bool = false
var _paused_label: Label
## Covers the network round trip a web build's [PackStream] does when a
## course was not in the base bundle. Absent on native, where [method
## PackStream.ensure] never actually suspends.
var _loading_label: Label

var menu: CourseMenu
var results_menu: ResultsMenu
## Directory name of the loaded course, so the menu can highlight it.
var current_course_dir: String = ""
## Incremented by [method restart]; lets a deferred callback tell whether the
## race it was started for is still the one running.
var _run_id: int = 0

## The saved run this race is against, or null for none. Read once out of
## [member requested_ghost] in [method _ready]; see [method _setup_ghost].
var _active_ghost_recording: RaceRecording = null

# ------------------------------------------------------------------
#                       the finish-line clip
# ------------------------------------------------------------------

## Whether [member CharacterRig.animation_player] is being scrubbed through
## `finish`/`wonrace`/`lostrace` right now. See [method _start_finish_clip].
var _finish_clip_playing: bool = false
var _finish_clip_time: float = 0.0
var _finish_clip_duration: float = 0.0
## Root motion of the clip, sampled against [member _finish_clip_time]. This is
## where the whole of standing up lives — see [method _start_finish_clip].
var _finish_clip_path: KeyframePath = null
## Where on the hill the clip plays, in world XZ: the racer's own position when
## it started, which is `CKeyframe::Init(ctrl->cpos, …)` in `CGameOver::Enter`.
var _finish_clip_origin: Vector2 = Vector2.ZERO

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

var _sun: DirectionalLight3D

## The start animation, when one is playing. See [IntroSequence] — it owns the
## clip, the root motion and the camera it borrows.
var _intro := IntroSequence.new()
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
		return roster.local.physics if roster.local != null else null

var race_time: float:
	get:
		return roster.local.race_time if roster.local != null else 0.0

var herring: int:
	get:
		return roster.local.herring if roster.local != null else 0

# ==================================================================
#                              setup
# ==================================================================

func _ready() -> void:
	camera = $ChaseCamera
	snow_gpu = $SnowFieldGPU
	roster = $Racers
	roster.racer_added.connect(_on_racer_added)
	_sun = $Sun
	if not requested_course_path.is_empty():
		course_scene_path = requested_course_path
	# A `--course=` on the way in outranks it: a capture run names the course it
	# wants, and the shell only ever passes on what it was given.
	var args: LaunchArgs = LaunchArgs.current()
	_auto_input = args.auto_input
	_compensate_keys = args.remote_keyboard
	if args.no_intro:
		play_intro = false
	if args.camera == "above":
		camera.mode = ChaseCamera.Mode.ABOVE
	elif args.camera == "trail":
		camera.mode = ChaseCamera.Mode.TRAIL
	if not args.course.is_empty():
		course_scene_path = args.course_scene_path()
	if not args.character.is_empty():
		requested_character = args.character
	if args.opponents != LaunchArgs.NO_OPPONENTS:
		_cli_setup.opponents = clampi(args.opponents, 0, RaceSetup.MAX_OPPONENTS)
	if not args.difficulty.is_empty():
		_cli_setup.skill = AISkill.parse(args.difficulty)
	# The shell outranks the command line here, unlike `--course=`: the two flags
	# are a way to start a race without a menu, not a way to keep overriding a
	# choice the player has just made on one.
	setup = requested_setup.copy() if requested_setup != null else _cli_setup
	_active_ghost_recording = requested_ghost
	requested_ghost = null
	# After the arguments, not before: `--character=` names a rig and this is
	# where it has been read. The start animation is per character too — Trixi's
	# `start.lst` is not Tux's — so the rig has to exist before the intro is set
	# up on the course load below.
	roster.build_local(_local_character_dir(), character_scene_path,
		Config.player_name, _auto_input, _compensate_keys)
	roster.build_field(setup, _local_character_dir())
	_intro_enabled = play_intro and _auto_input.is_empty()
	menu = $CourseMenu
	menu.course_chosen.connect(_on_course_chosen)
	menu.back_requested.connect(leave_to_main_menu)
	results_menu = $ResultsMenu
	results_menu.continue_pressed.connect(_on_results_continue)
	Net.snapshot_received.connect(_on_snapshot_received)
	Net.roster_changed.connect(roster.sync_remote)
	_paused_label = _make_paused_label()
	_loading_label = _make_loading_label()
	await load_course(course_scene_path)

## `P`'s freeze has no panel of its own, so it needs its own text — nothing
## else on screen would otherwise say the race stopped moving rather than
## hung. A full-rect [Label] on its own [CanvasLayer] rather than a child of
## [RaceHUD]: that layer hides itself whenever [member paused] is true, which
## is exactly the frame this has to remain visible.
func _make_paused_label() -> Label:
	var layer := CanvasLayer.new()
	add_child(layer)
	var label := Label.new()
	label.text = "PAUSED"
	label.add_theme_font_size_override("font_size", 48)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.visible = false
	layer.add_child(label)
	return label

## Same shape as [method _make_paused_label]: the one sign on screen that a
## web build is fetching a course's `.pck` rather than having stalled. `main_menu.gd`'s
## own "please wait" panel belongs to the menu scene, which
## [method SceneTree.change_scene_to_file] has already torn down by the time
## [method load_course] starts waiting on the network, so this scene needs its
## own.
func _make_loading_label() -> Label:
	var layer := CanvasLayer.new()
	add_child(layer)
	var label := Label.new()
	label.text = "Loading course…"
	label.add_theme_font_size_override("font_size", 32)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.visible = false
	layer.add_child(label)
	return label

## Wire up a racer the roster has just built.
##
## One place, and the only place, where a racer that appears on the hill gets
## connected to the rest of the game — [RacerRoster] announces every one of
## them through [signal RacerRoster.racer_added], whatever kind it is. It used
## to be three blocks of `connect` calls beside three separate constructors.
##
## What is connected is not the same for everybody, and that is about audio
## rather than about racers. The mixer has one voice per cue and no positional
## audio (see [AudioDirector]), so a sound another racer causes is
## indistinguishable from one the player caused: an opponent hitting a tree
## three hundred metres up the hill would thud in your ears. Only collection is
## connected for everyone, because [method _on_item_collected] hides the fish
## for the whole field and plays the cue for the player alone.
func _on_racer_added(racer: Racer) -> void:
	# Null until the course is loaded, and set for everyone by `_use_snow_field`
	# when it is. This is the other order: a ghost, a peer joining mid-session or
	# a rebuilt field arrives on a hill that already has a trench in it.
	racer.snow_cpu = snow_cpu
	var sim := racer as SimulatedRacer
	if sim == null:
		return
	sim.item_collected.connect(_on_item_collected)
	sim.finished_race.connect(_on_racer_finished)
	if not sim.is_local():
		return
	sim.tree_hit.connect(_on_tree_hit)
	# Only the player's end of a contact. A contact is resolved by both bodies,
	# so connecting both ends would fire the cue twice for one bump.
	sim.racer_hit.connect(_on_racer_hit)

func _local_character_dir() -> String:
	return requested_character if not requested_character.is_empty() else Config.character

## Replace the field with one built from the current [member setup]. Called when
## the in-race menu comes back with a different number of opponents.
func _rebuild_opponents() -> void:
	roster.clear_field()
	roster.build_field(setup, _local_character_dir())
	if course_root != null:
		for racer: SimulatedRacer in roster.opponents:
			_build_simulation(racer, course_root.course_data)

# ==================================================================
#                          loading a course
# ==================================================================

func load_course(path: String) -> void:
	var dir: String = path.get_base_dir().get_file()
	_loading_label.visible = true
	var err: Error = await PackStream.ensure(path, "courses/%s.pck" % dir)
	if err != OK:
		_loading_label.text = "Could not load %s (%s)" % [dir, error_string(err)]
		return
	_loading_label.visible = false

	_stop_slide_sound()
	Audio.halt_all()
	if course_root != null:
		course_root.queue_free()
		course_root = null
	if terrain != null:
		terrain.queue_free()
		terrain = null

	current_course_dir = dir
	requested_course_path = path
	var packed: PackedScene = load(path)
	course_root = packed.instantiate()
	add_child(course_root)
	course_root.build_runtime()

	var course: CourseData = course_root.course_data

	_use_snow_field(SnowField.new())

	# One simulation per simulated racer, all against the same surface and the
	# same two object grids. Sharing the grids is what makes the herring a race
	# rather than a pair of solitaires; sharing the surface is free, since a
	# [SurfaceProvider] is read-only apart from the snow field.
	for racer: Racer in roster.all:
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
	# One 64 m GPU window exists and it follows the view target, so only that
	# racer can usefully stamp it. Everyone else deforms the CPU mirror, which
	# is what the physics reads and is course-wide.
	racer.snow_gpu = snow_gpu if snow_deformation and racer == roster.view_target else null

## Point the course, and everyone on it, at [param field].
##
## The mirror is replaced rather than cleared on a restart, so there is a second
## caller and this is worth naming. Every racer holds it, not just the simulated
## ones: a ghost and a remote peer are drawn against the same trench even though
## neither is stamping it — see [method Racer._drawn_snow_lift].
func _use_snow_field(field: SnowField) -> void:
	snow_cpu = field
	course_root.surface.snow_field = field
	for racer: Racer in roster.all:
		racer.snow_cpu = field

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

## Load the saved run this race is against, if there is one that applies here.
##
## Three reasons not to: a scripted run (see [method _scripted_run]), a race
## against opponents, and a saved run recorded on a different course — picking
## another course from the in-race menu after a ghost race leaves
## [member _active_ghost_recording] set, and this is what drops it rather than
## racing the wrong hill's ghost on the new one. The rest of the reasoning, and
## the loading, is [method RacerRoster.load_ghost_recording].
func _setup_ghost() -> void:
	if _active_ghost_recording != null \
			and _active_ghost_recording.course_dir == current_course_dir \
			and not _scripted_run() and not setup.is_race():
		roster.load_ghost_recording(_active_ghost_recording)
	else:
		roster.clear_ghost()

## Put the race back at the start line. [param with_intro] is what separates the
## two ways in: choosing a course runs the start animation, where `r` mid-race is
## the original's Reset state and goes straight back to racing.
func restart(with_intro: bool = true) -> void:
	_run_id += 1
	var course: CourseData = course_root.course_data
	var start := Vector2(course.start_position.x, -course.start_position.y)
	# Not just `intro_running = false`: an animation still up owns the camera
	# mode and the rig's clip, and dropping the flag leaves both where the intro
	# put them — a race framed from ABOVE for good, and the next `begin` saving
	# that framing as the one to restore.
	_end_intro()
	_stop_finish_clip()
	running = true
	_sim_lead = 0.0
	_use_snow_field(SnowField.new())
	if snow_gpu != null:
		snow_gpu.reset()
	# The herring are back. `hide_item` collapsed their instance transforms and
	# `collectable` was cleared on the shared grid; a restart that skipped this
	# left the course stripped of everything the last run picked up, which a
	# ghost of that run makes obvious — it collects fish that are not there.
	course_root.reset_items()
	for racer: Racer in roster.all:
		if racer is SimulatedRacer:
			var sim: SimulatedRacer = racer
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
	# The whole backlog, not a budgeted slice: the shell's loading panel is
	# already on screen and the first drawn frame of the race should be a
	# complete hillside. Every later call comes from [method _present] and is
	# budgeted.
	terrain.update_streaming(roster.local.state.position, true)
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
	# Cosmetic, and the one thing that has to keep moving while the results
	# screen is up — everything else below this stops the moment [member
	# paused] is true.
	if _finish_clip_playing:
		_advance_finish_clip(delta)
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
	for racer: Racer in roster.all:
		racer.present(alpha)
	_present(delta)

## One fixed step of everything that is part of the race rather than part of
## the picture.
func _simulation_tick(dt: float) -> void:
	if intro_running:
		if not _intro.step(dt):
			_end_intro()
		return
	if not running:
		return
	roster.refresh_rivals()
	for racer: Racer in roster.all:
		racer.advance(dt)
	if Net.active() and roster.local != null:
		Net.publish(roster.local.state)
	_update_slide_sound()
	# The CPU mirror follows the local player, not the view target: it is what
	# the physics reads under this machine's racer, and it is never drawn. The
	# GPU window, which is only ever drawn, follows the view target instead.
	snow_cpu.recenter(roster.local.state.position.x, roster.local.state.position.z)
	snow_cpu.decay(dt)
	# Last, because it reads the field: every stamp this tick has landed, the
	# window has moved and the decay has been applied, so what each racer reads
	# is the trench the next tick's physics will stand on. Sampling here rather
	# than from `present` is what keeps the drawn body off the 60 Hz sawtooth —
	# see [method Racer.sample_snow_lift].
	for racer: Racer in roster.all:
		racer.sample_snow_lift()

## Everything that follows the simulation and is allowed to run at the screen's
## rate rather than the simulation's: the camera lag, the streaming window, the
## particle rates and the deformation render target.
func _present(delta: float) -> void:
	for racer: Racer in roster.all:
		if racer is SimulatedRacer:
			(racer as SimulatedRacer).spray.flush(delta)
	if roster.view_target == null:
		return
	var view: RacerState = roster.view_target.view_state()
	if intro_running:
		camera.track(roster.local.global_position, Vector3.ZERO, Vector3.UP, delta)
	else:
		camera.track(view.position, view.velocity, roster.view_target.surface_normal(), delta)
	terrain.update_streaming(view.position)
	if snow_deformation and snow_gpu != null:
		snow_gpu.update(view.position.x, view.position.z, delta)
		terrain.set_trail_map(snow_gpu.trail_texture(), snow_gpu.window_origin(),
			snow_gpu.window_extent(), snow_gpu.max_depth)

# ==================================================================
#                          the start animation
# ==================================================================

## Hand over to [IntroSequence], which is the whole of the start animation.
##
## Skipped in a networked race. Four and a half seconds of walking is fine when
## it is your own clock; between peers it is four and a half seconds of nobody
## agreeing when the race began, and a countdown everyone starts on is a
## different feature from the original's start animation.
func _begin_intro() -> void:
	var course: CourseData = course_root.course_data
	var start := Vector2(course.start_position.x, -course.start_position.y)
	if not _intro.begin(roster.local, camera, course_root.surface, start):
		return
	running = false
	roster.local.running = false
	intro_running = true

## Give the controls back to the simulation. Reached either by the animation
## running out or by a key — the original aborts on any keypress too.
func _end_intro() -> void:
	if not intro_running:
		return
	_intro.finish()
	intro_running = false
	running = true
	roster.local.running = true
	# The intro left the racer standing at the start point; the simulation is
	# about to carry on from where `init_at` put it. Collapsing the window stops
	# the first frame interpolating between the two.
	roster.local.state.capture(roster.local.physics, 0.0, 0)
	roster.local.snap()

# ==================================================================
#                            multiplayer
# ==================================================================

## A snapshot arrived. [method RacerRoster.remote_for] builds the racer on
## first contact rather than from the roster, so a packet that beats its
## sender's introduction still lands somewhere — the name catches up when
## [signal RaceNetwork.roster_changed] fires.
func _on_snapshot_received(peer_id: int, packet: PackedFloat32Array) -> void:
	var racer: PlaybackRacer = roster.remote_for(peer_id)
	racer.push_snapshot(packet)
	racer.trim_history()

## Everyone on the hill, best progress first. Forwarded rather than reached for
## through [member roster]: the HUD and the result line have always asked the
## race who is winning, and that is a fair question to ask it.
func standings() -> Array[Racer]:
	return roster.standings()

## Seconds the player is behind their ghost at the point they have reached.
## Negative is ahead; [constant INF] means there is no ghost, or it never got
## this far.
func ghost_delta() -> float:
	return roster.ghost_delta()

## Where [param racer] is in the field, counting from 1. Zero if they are not on
## this hill at all.
func place_of(racer: Racer) -> int:
	return roster.place_of(racer)

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

## Opening from mid-race (Esc) or from the results screen's Continue — both
## land on the ordinary course list playing menu music. A finish carrying a
## result goes to [method _open_results] instead, which is the only other
## place [member paused] is set for this reason.
func open_menu() -> void:
	if menu == null or menu.visible:
		return
	paused = true
	_stop_slide_sound()
	Audio.play_menu_music()
	menu.open(current_course_dir, running, setup)

## `P`, toggled. Unlike the course menu this has nowhere to go but back to the
## same race — no course list, no Back button — so it is a plain freeze with
## [member _paused_label] as the only sign anything happened. Ignored while
## the course menu owns the freeze already, or during the start animation,
## where every key is spoken for.
func _toggle_key_pause() -> void:
	if (menu != null and menu.visible) or intro_running:
		return
	_key_paused = not _key_paused
	paused = _key_paused
	if paused:
		_stop_slide_sound()
	else:
		# A pause is not simulated time. Without this the first frame after the
		# freeze lifts owes the simulation the whole time it was down, and the
		# race either catches up in one lurch or — past the tick cap — drops it
		# and looks right by accident.
		_sim_lead = 0.0
	_paused_label.visible = _key_paused

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

## Esc drops back to the course list mid-race — the original's "abort race",
## not a toggle: there is no Continue button to resume from, so a second press
## does nothing new rather than closing the panel again. That is deliberate:
## `P` (below) is the way to freeze the race and come straight back to it;
## Esc is the way to leave it for another course. Neither fires during the
## start animation, where every key including these skips to the race instead —
## that is `CIntro::Keyb`, which takes any press at all and aborts.
func _unhandled_input(event: InputEvent) -> void:
	if intro_running and not paused and _is_skip_press(event):
		get_viewport().set_input_as_handled()
		_end_intro()
		return
	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		_toggle_key_pause()
		return
	if not event.is_action_pressed("menu"):
		return
	get_viewport().set_input_as_handled()
	if not _key_paused:
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
	return "%s %s   —   %s" % [tr("POSITION"), place_label(place_of(roster.local)), line]

func _apply_environment(preset: EnvironmentPreset) -> void:
	var we: WorldEnvironment = $WorldEnvironment
	var env: Environment = preset.to_environment()
	# The preset knows what `light.lst` said; the settings file knows how far
	# the player wants to see. Fog distance is the one place the two meet.
	Config.apply_fog(env, preset)
	we.environment = env
	preset.apply_sun(_sun)
	_sun.directional_shadow_max_distance = _shadow_range_for(env)
	for racer: Racer in roster.all:
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
	if racer != roster.local:
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
	if racer == roster.local:
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
	if racer != roster.local:
		return
	race_completed.emit(roster.local.race_time, roster.local.herring)
	_show_results_after_finish(_run_id, _finish_recording())

## Close out the recording. Nothing is saved here — recording is unconditional
## but keeping it is now something the player asks for on the results screen;
## see [SavedRunStore].
func _finish_recording() -> RaceRecording:
	if roster.local.recorder == null:
		return null
	return roster.local.recorder.finish(roster.local.race_time, roster.local.herring, true)

## Bring the results screen up once the finish deceleration has played out,
## unless the player restarted or picked another course in the meantime.
func _show_results_after_finish(run_id: int, recording: RaceRecording) -> void:
	await get_tree().create_timer(FINISH_MENU_DELAY).timeout
	if run_id == _run_id and not paused:
		var clip: StringName = _outcome_clip()
		_start_finish_clip(clip)
		_open_results(recording, clip)

## Whether this race had anything to win or lose, and — if so — whether the
## player did. See [RaceOutcome] for the mapping itself.
func _outcome_clip() -> StringName:
	var beat_ghost: bool = _active_ghost_recording != null \
		and roster.local.race_time < _active_ghost_recording.total_time
	return RaceOutcome.clip(setup.is_race(), roster.place_of(roster.local) == 1,
		_active_ghost_recording != null, beat_ghost)

## Start [param clip] on the local racer's rig, falling back to `finish` and
## then to nothing for a character missing both — the same tolerance the rig
## already has for a joint `shape.lst` does not name. See
## [method _advance_finish_clip] for how it keeps playing.
##
## [b]The clip is root motion first and joints second.[/b] Standing up out of
## the racing pose is not in any joint track: `finish.lst` opens on
## `[yaw] 180 [pitch] 109` — face down the hill, tipped past horizontal, i.e.
## lying on the belly — and walks that to `[yaw] 5 [pitch] 1` while lifting
## `[pos]` by 0.35 m, so the penguin rises onto its feet and turns to face back
## up the hill. All of that is on node 0 in the original, which is [KeyframePath]
## here; the joint tracks only fold the flippers and the legs in underneath it.
## Playing the [Animation] without the path is what left the racer lying in the
## snow through the whole results screen.
func _start_finish_clip(clip: StringName) -> void:
	var rig: CharacterRig = roster.local.rig
	if rig == null:
		return
	var chosen: StringName = clip
	if not rig.has_clip(chosen):
		chosen = &"finish"
	if not rig.play_clip(chosen):
		return
	_finish_clip_playing = true
	_finish_clip_time = 0.0
	_finish_clip_duration = rig.clip_length(chosen)
	_finish_clip_path = rig.path_for(chosen)
	# `CKeyframe::Init(ctrl->cpos, -0.18)`: the clip plays around wherever the
	# racer came to rest, not around the finish line.
	var at: Vector3 = roster.local.state.position
	_finish_clip_origin = Vector2(at.x, at.z)
	_apply_finish_pose(0.0)

## Scrub the finish clip forward by [param delta], body and joints together.
##
## It runs out rather than looping and the last pose is held, which is what
## `CKeyframe::Update` does — it goes inactive on reaching the last key and
## `CGameOver` simply keeps drawing the shape. Looping would replay the stand-up
## from lying down every few seconds now that the root motion is applied.
func _advance_finish_clip(delta: float) -> void:
	_finish_clip_time += delta
	_apply_finish_pose(minf(_finish_clip_time, _finish_clip_duration))

## Place the body where the clip says and pose the joints to match.
##
## The height is the same reading [IntroSequence] makes: the authored Y is a
## clearance over the terrain, so `CKeyframe::Update` adds `FindYCoord` to it —
## which is what lets one canned animation play on all 44 courses. A clip with
## no root motion still poses its joints, on the body transform the race left
## behind.
func _apply_finish_pose(t: float) -> void:
	var racer: Racer = roster.local
	if _finish_clip_path != null:
		var offset: Vector3 = _finish_clip_path.offset_at(t)
		var x: float = _finish_clip_origin.x + offset.x
		var z: float = _finish_clip_origin.y + offset.z
		var y: float = course_root.surface.height_at(x, z) + offset.y \
			+ PhysConst.TUX_Y_CORR + FINISH_HEIGHT_CORRECTION
		racer.apply_pose(Vector3(x, y, z),
			racer.rig.parent_basis_for(_finish_clip_path.basis_at(t)))
	racer.rig.seek_clip(t)

func _stop_finish_clip() -> void:
	if not _finish_clip_playing:
		return
	_finish_clip_playing = false
	_finish_clip_path = null
	if roster.local != null and roster.local.rig != null:
		roster.local.rig.stop_clip()

## What the results screen says about the ghost, or empty for a race that had
## none. A literal rather than a `tr()` key — "ghost" is not in the imported
## string table either.
func _ghost_note() -> String:
	if _active_ghost_recording == null:
		return ""
	var delta: float = roster.local.race_time - _active_ghost_recording.total_time
	if delta < 0.0:
		return "Beat the ghost by %.2f s" % -delta
	return "%.2f s behind the ghost" % delta

## Bring the results screen up in place of the course menu, carrying the
## finished run so its Save button has something to write. [param clip] is
## what [method _show_results_after_finish] just started on the rig — reused
## here so the sting matches the pose: `lostrace` plays the theme's loss
## sting, anything else its win sting (`finish` included — a plain practice
## run has nothing to lose, matching the original's own non-cup behaviour).
func _open_results(recording: RaceRecording, clip: StringName) -> void:
	paused = true
	_stop_slide_sound()
	Audio.halt_all()
	var situation: MusicTheme.Situation = MusicTheme.Situation.LOST \
		if clip == &"lostrace" else MusicTheme.Situation.WON
	Audio.play_theme(course_root.course_data.music_theme, situation)
	results_menu.open(_result_line(), recording, _ghost_note())

## The results screen's Continue button. The clip stops and the ordinary
## course menu takes over exactly as it did before there was a results screen.
func _on_results_continue() -> void:
	_stop_finish_clip()
	open_menu()

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
	var sim: RacePhysics = roster.local.physics
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
