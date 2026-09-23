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
## [b]Three modes, one scene.[/b] [RaceSetup] is the whole of the difference:
## zero opponents is Practice, which is what the game did before and what every
## reference capture still gets, one to nine is a race against the computer, and
## [member RaceSetup.networked] is a race against other people. Nothing in the
## presentation branches on it — an opponent is built the same way the player is,
## a peer is a [PlaybackRacer] like a ghost, and none of them can be told apart
## from a [RacerState].
##
## [b]What a network race does change is the clock at either end of it.[/b]
## There is no start animation: everybody reports the hill built
## ([method RaceNetwork.report_ready]), the server waits for the last of them,
## and a three-second countdown starts the field together. And the race does not
## end when this player crosses the line — it ends when the [i]last[/i] player
## does. Between those two moments this machine is a spectator: its penguin has
## stopped at the bottom, the camera is on whoever is still coming down, and the
## results screen waits for [signal RaceNetwork.race_over].
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

## Seconds of `3 · 2 · 1` between the last racer being ready and a network race
## starting.
##
## This is what the start animation is instead of. `CIntro` is four and a half
## seconds of one penguin walking to the line on its own clock, which is fine
## when it is your clock and is four and a half seconds of nobody agreeing when
## the race began when it is eight of them. The countdown is short, it is the
## same three numbers on every screen, and the packet that starts it leaves the
## server once — so the field is aligned to within one round trip, which is the
## best any peer-simulated game gets.
const COUNTDOWN_SECONDS := 3.0
## How long `GO!` stays up after the countdown reaches zero. Cosmetic: the race
## is already running.
const GO_FLASH := 0.8

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
## The mirror the ice reflects the racers in, or a pass that is switched off.
## Presentation only — nothing in the simulation may read it.
var reflection: IceReflection
## Scratch for [method _admit_racers_to_reflection], which runs once per racer
## per drawn frame and has no business allocating in either loop.
var _reflect_sample := SurfaceSample.new()
## The weather. Presentation only, like the mirror: [SnowFall] draws what
## [member RaceSetup.snowfall] asked for and the simulation never hears about it.
var snowfall: SnowFall
## The environment this course is lit by, kept because two things outside
## [method _apply_environment] need it — the snowfall's `[partcol]` tint, and
## anything else that has to be reapplied when the weather changes without the
## course doing so.
var _preset: EnvironmentPreset
## The course's own sky, before [member RaceSetup.conditions] chose a time of
## day for it. Kept beside the applied one because the two are different
## questions and the player can change either: picking another course replaces
## this, and picking another sky re-resolves [member _preset] off it without the
## course moving. See [method LightCondition.preset_for].
var _course_preset: EnvironmentPreset
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
## Covers the whole of building a course: the network round trip a web build's
## [PackStream] does when the course was not in the base bundle, and the four
## blocking steps after it. The same panel [MainMenu] put up before the scene
## swap — see [LoadingScreen] — so the handover between the two is invisible.
##
## Never drawn on a native build, where [method PackStream.ensure] does not
## actually suspend and the whole of [method load_course] runs inside one
## frame.
@onready var _loading: LoadingScreen = $LoadingScreen

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
#                          a network race
# ------------------------------------------------------------------

## True between this machine's hill being built and the whole field having one.
## The course is drawn and the camera lives; nothing is stepped.
var _net_waiting: bool = false
## Seconds left of the countdown, counting on past zero for
## [constant GO_FLASH] so the `GO!` has somewhere to live.
## [constant -INF] when there is no countdown.
var _net_countdown: float = -INF
## True from this player crossing the line until the last one does. The race
## goes on without them; see [method _update_spectate].
var _net_spectating: bool = false
## The finished run, held back until the race is over for everybody — the
## results screen is what offers to save it, and in a network race that screen
## does not come up when this player finishes.
var _net_recording: RaceRecording = null

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
	# Built here rather than in `race.tscn` for the same reason [TerrainRenderer]
	# is: it is a render target and a camera, not a thing anyone would want to
	# position in the editor.
	reflection = IceReflection.new()
	reflection.name = "IceReflection"
	reflection.enabled = Config.ice_reflections
	add_child(reflection)
	# Built here for the same reason the mirror is: it is a field of quads that
	# follows the player, not a thing anyone would place in the editor.
	snowfall = SnowFall.new()
	snowfall.name = "SnowFall"
	add_child(snowfall)
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
	# Weather for a race started without the shell: the settings file, unless
	# `--snow=` names a grade for this run. A run that went through the menu has
	# already been asked, and its answer is in `requested_setup`.
	_cli_setup.snowfall = Config.snowfall
	if args.snow != LaunchArgs.NO_SNOW:
		_cli_setup.snowfall = clampi(args.snow, 0, SnowFall.MAX_GRADE)
	_cli_setup.conditions = Config.conditions
	if not args.light.is_empty():
		_cli_setup.conditions = LightCondition.parse(args.light)
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
	for link: Array in _network_links():
		(link[0] as Signal).connect(link[1])
	_paused_label = _make_paused_label()
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

## Fractions of the whole load the four marks below sit at.
##
## The download owns most of the bar because on the only build that draws one
## it owns most of the wait: a course pack is megabytes over the player's link,
## where everything after it is tens of milliseconds of local work. The four
## steps after it cannot report from the inside — `load()`, `build_runtime()`,
## `TerrainRenderer.setup` and the first streaming pass each block until they
## are done — so each one simply ends at its mark. A bar that jumps in four
## steps at the end is honest about that; a smoothly faked one would not be.
const LOAD_DOWNLOADED := 0.75
const LOAD_INSTANTIATED := 0.82
const LOAD_RUNTIME_BUILT := 0.90
const LOAD_TERRAIN_READY := 0.95

func load_course(path: String) -> void:
	var dir: String = path.get_base_dir().get_file()
	var listing: CourseListing = CourseCatalog.load_default().find(dir)
	_loading.begin(listing.title() if listing != null else dir)
	# Asked before the fetch, because it governs the whole of what follows: see
	# [method _load_step].
	var streaming: bool = PackStream.is_streamed(path)
	var err: Error = await PackStream.ensure(path, "courses/%s.pck" % dir,
		_on_pack_progress if streaming else Callable())
	if err != OK:
		_loading.fail("Could not load %s (%s)" % [dir, error_string(err)])
		return

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
	await _load_step(LOAD_DOWNLOADED, streaming)
	var packed: PackedScene = load(path)
	course_root = packed.instantiate()
	add_child(course_root)
	await _load_step(LOAD_INSTANTIATED, streaming)
	course_root.build_runtime()
	await _load_step(LOAD_RUNTIME_BUILT, streaming)

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
	await _load_step(LOAD_TERRAIN_READY, streaming)

	camera.surface = course_root.surface
	camera.reset()

	# The course names a place and the shell names a time of day — see
	# [LightCondition]. `environment_preset` on the scene outranks both, which is
	# how a spike or an authored course pins one sky.
	var preset: EnvironmentPreset = environment_preset
	if preset == null and course.environment_preset is EnvironmentPreset:
		preset = course.environment_preset
	_course_preset = preset
	if preset != null:
		_apply_environment(_lit_preset(preset))
	_apply_snowfall()

	_setup_ghost()
	# `restart()` builds the whole terrain backlog in one go and prints
	# RACE_READY. The panel comes down after it, not before: everything it is
	# covering has to be finished, or the player is handed a penguin standing
	# on an empty hillside — which is exactly what the bare "Loading course…"
	# label this replaced used to do on a streamed build.
	restart()
	_loading.finish()

## Mark one blocking step of the load done, and — only on a build that is
## actually streaming — give the panel a frame to draw it in.
##
## [b]Every frame spent here moves every reference capture.[/b] `DebugCapture`
## counts frames from the moment the process starts, not from the moment the
## race does, so waiting unconditionally would renumber all of them. There is
## nothing to wait for on a native build in any case: [method
## PackStream.ensure] never suspends there, so the panel is never composited,
## and `load_course` has always run start to finish inside a single frame. It
## still does.
func _load_step(fraction: float, streaming: bool) -> void:
	_loading.set_progress(fraction)
	if not streaming:
		return
	await RenderingServer.frame_post_draw

## Bytes off the wire, mapped onto the first [constant LOAD_DOWNLOADED] of the
## bar. Handed to [method PackStream.ensure] only when there is a download to
## watch.
func _on_pack_progress(downloaded: int, total: int) -> void:
	var mb: float = float(downloaded) / 1048576.0
	if total <= 0:
		# The size is not known yet, or never will be — see [method
		# PackStream._begin_size_probe]. There is no fraction to be had, so say
		# how much has arrived and let [method LoadingScreen.set_progress] drop
		# the bar rather than park it at a number that is not true.
		_loading.set_progress(-1.0, "%.1f MB" % mb)
		return
	_loading.set_progress(LOAD_DOWNLOADED * float(downloaded) / float(total),
		"%.1f / %.1f MB" % [mb, float(total) / 1048576.0])

func _build_simulation(racer: SimulatedRacer, course: CourseData) -> void:
	var sim := RacePhysics.new()
	sim.surface = course_root.surface
	sim.trees = course_root.trees
	sim.items = course_root.items
	sim.bounds_polygon = course.effective_play_bounds()
	sim.play_length = course.play_size.y
	sim.finish_brake = course.finish_brake
	# ETR's `[wind]` grade belongs to a *cup race* in `events.lst`, and there
	# are no cups here yet, so `--wind=` is the only thing that asks for
	# weather — and the only way to see the HUD's wind rose. Every racer gets
	# its own [WindField] on the same seed rather than sharing one: they are all
	# stepped with the same [constant SIM_DT] on the same tick, so identical
	# seeds evolve identically, where one shared field would be advanced once
	# per racer and blow a field of ten about ten times too fast.
	sim.wind.init_wind(LaunchArgs.current().wind)
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
	# A network race is a field on one start line and the player is one of it,
	# so — unlike every other mode — the local racer takes a lane rather than
	# the course's own start point. The seat comes out of the room's member
	# order, which is the same list in the same order on every machine, so no
	# two people take the same one and nobody has to be told which is theirs.
	if _is_network_race():
		roster.local.start_offset = RaceSetup.lane_offset(_network_seat())
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
	if reflection != null:
		# Otherwise the smoothed plane normal eases across from wherever the
		# last run left it, which on a restart is the bottom of the course.
		reflection.reset()
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
	snowfall.restart()
	Audio.play_theme(course.music_theme, MusicTheme.Situation.RACE)
	# Marker for the browser harness: the course is loaded and the first frame
	# of simulation has run.
	print("RACE_READY %s %d chunks" % [course.display_name, terrain.chunk_count()])
	if _is_network_race():
		_hold_for_network()
		return
	if with_intro and _intro_enabled:
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
	# Cosmetic past zero, and the reason it is up here with the finish clip:
	# `GO!` has to keep counting out while the race it started is running.
	if _net_countdown > -GO_FLASH:
		_advance_countdown(delta)
	if paused:
		return
	if Input.is_action_just_pressed("reset_race") and not _is_network_race():
		# The original's Reset state re-enters Racing, not Intro: `r` is for
		# getting back on the hill, not for watching the walk again.
		#
		# Never in a network race: restarting is this machine putting its clock
		# back to zero while seven others keep theirs, which is not a restart —
		# it is a racer who teleports to the top of the hill on every screen but
		# their own.
		restart(false)
		return
	if _net_waiting:
		# The hill is built and the field is not all here yet. Everything that
		# draws still runs — the course, the camera, the weather — so the wait
		# is a view of the start line rather than a frozen frame.
		#
		# Snapshots keep going out through it, which is what puts the other
		# penguins on the line during the countdown instead of popping them
		# into existence on the first tick of the race.
		if roster.local != null:
			Net.publish(roster.local.state)
		for racer: Racer in roster.all:
			racer.present(1.0)
		_present(delta)
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
	if _net_spectating:
		_update_spectate()
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
	# ETR updates the weather from `ctrl->cpos` — the racer being watched, which
	# is the player unless something else is being spectated — and its `Paused`
	# state draws the snow without updating it. `_process` returns before this
	# whole function while paused, which is the same thing.
	snowfall.update(view.position, _racer_wind(), delta)
	if snow_deformation and snow_gpu != null:
		snow_gpu.update(view.position.x, view.position.z, delta)
		terrain.set_trail_map(snow_gpu.trail_texture(), snow_gpu.window_origin(),
			snow_gpu.window_extent(), snow_gpu.max_depth)
	_update_reflection(view, delta)

## Aim the ice's mirror at the racer being watched and hand the result to the
## terrain. See [IceReflection] for why the plane is the one under that racer.
func _update_reflection(view: RacerState, delta: float) -> void:
	if reflection == null or terrain == null:
		return
	if not reflection.enabled:
		terrain.set_character_reflection(null, Vector3.ZERO, Vector3.UP, 0.0)
		return
	# The *drawn* surface, not the simulated one. [SnowField] takes the trench
	# off the height the physics stands on and the terrain mesh does not go down
	# with it — the same mismatch [method Racer._drawn_snow_lift] exists for, and
	# undone the same way. A mirror plane on the simulated height would sit up to
	# `max_trench` below the ice the player can see, and the reflection would
	# hang off the bottom of the penguin.
	var height: float = course_root.surface.height_at(view.position.x, view.position.z)
	if snow_cpu != null:
		height += snow_cpu.depth_at(view.position.x, view.position.z)
	reflection.update(camera,
		Vector3(view.position.x, height, view.position.z),
		roster.view_target.surface_normal(), delta)
	_admit_racers_to_reflection()
	terrain.set_character_reflection(reflection.texture(),
		reflection.plane_point(), reflection.plane_normal(),
		reflection.fade_distance, reflection.attachment(camera))

## Decide, for each racer on the hill, whether the mirror plane speaks for the
## ice it is standing on — and take the ones it does not out of the pass.
##
## The plane is the one under the racer being watched and nobody else, so a
## field spread across a bend is a field of racers being mirrored through
## somebody else's ground. [method IceReflection.admits] is the test and
## [member Racer.reflected] is the switch; this function is only the part that
## needs a [SurfaceProvider], which is why it lives here and not there.
##
## The surface is asked directly rather than through [method Racer.surface_normal]
## because that answers [constant Vector3.UP] for anyone not simulated locally —
## a ghost, a remote peer — and a mirror does not care who is driving. Same
## drawn-not-simulated height as above, for the same reason.
func _admit_racers_to_reflection() -> void:
	for racer: Racer in roster.all:
		# The racer the plane was taken under is in the mirror unconditionally.
		# Not quite a tautology and that is why it is written down: the plane's
		# normal is *smoothed* ([constant IceReflection.NORMAL_TAU]) and the
		# terrain's is not, so carving across a pipe at 78 km/h opens 14° between
		# the two — measured — and a tolerance test would drop the one reflection
		# in the frame that must never blink. The lag is deliberate and the
		# shader already fades around this plane; see [method IceReflection.update].
		if racer == roster.view_target:
			racer.reflected = true
			continue
		var at: RacerState = racer.view_state()
		course_root.surface.sample_into(at.position.x, at.position.z, _reflect_sample)
		var ground: float = _reflect_sample.height
		if snow_cpu != null:
			ground += snow_cpu.depth_at(at.position.x, at.position.z)
		racer.reflected = reflection.admits(
			Vector3(at.position.x, ground, at.position.z),
			_reflect_sample.normal, racer.reflected)

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

## Whether this race is one other people are in. Both halves are needed: the
## shell asked for a network race ([member RaceSetup.networked]) and there is
## still a session to have one over — a race whose server went away is a race
## that has to stop behaving like one.
func _is_network_race() -> bool:
	return setup != null and setup.networked and Net.active()

## Which start-line seat this machine takes.
##
## Out of the room's own member order, which the server fixes when the race
## starts and sends to everybody: the same list in the same order on every
## machine, so no two peers claim a lane and nobody has to be told which is
## theirs. Seat zero is [constant RaceSetup.lane_offset] zero, i.e. the course's
## authored start point — somebody always begins exactly where a practice run
## begins.
func _network_seat() -> int:
	var seat: int = 0
	for entry: Variant in Net.members():
		if not (entry is Dictionary):
			continue
		if int((entry as Dictionary).get("peer", 0)) == Net.local_id():
			return seat
		seat += 1
	return 0

## The hill is built. Stand still and tell the server so; it starts the field
## when the last machine says the same.
func _hold_for_network() -> void:
	running = false
	_net_spectating = false
	_net_countdown = -INF
	_net_waiting = true
	roster.view_target = roster.local
	if Net.phase == RaceNetwork.Phase.LOADING:
		Net.report_ready()
		return
	# The server already thinks this race is running — a course rebuilt under
	# one in progress, or a scene reloaded. Nothing to wait for.
	_on_race_go()

## Everybody has a hill. Three, two, one.
func _on_race_go() -> void:
	if not _is_network_race():
		return
	_net_waiting = true
	running = false
	_net_countdown = COUNTDOWN_SECONDS

## Count the start down, and let the race go at zero. Runs past zero by
## [constant GO_FLASH] so the HUD has something to say for a moment after.
func _advance_countdown(delta: float) -> void:
	var before: float = _net_countdown
	_net_countdown -= delta
	if before <= 0.0 or _net_countdown > 0.0:
		return
	_net_waiting = false
	running = true
	# The wait was not simulated time. Without this the first frame of the race
	# owes the simulation the whole countdown.
	_sim_lead = 0.0

## Hand the camera to whoever is still racing.
##
## [member RacerRoster.view_target] was built for exactly this — "a spectator
## mode is this variable pointing somewhere else" — and everything that follows
## the view rather than the player already reads it: the chase camera, the
## terrain streaming window, the GPU deformation window and the ice mirror. The
## CPU snow mirror deliberately does not: that one is what the local simulation
## stands on, and this player is still standing on it at the bottom of the hill.
func _update_spectate() -> void:
	var leader: Racer = null
	for racer: Racer in roster.all:
		if racer == roster.local or racer.finished or not racer.collides():
			continue
		if leader == null or racer.state.progress > leader.state.progress:
			leader = racer
	var target: Racer = leader if leader != null else roster.local
	if target == roster.view_target:
		return
	roster.view_target = target
	# Otherwise the chase camera eases across the whole hill from wherever it
	# was watching, through the terrain, over about a second.
	camera.reset()

## This player is over the line and the race is not finished — the brief's one
## hard rule, and the whole reason this function is not [method
## _show_results_after_finish]. The run is kept back until the field is in; the
## camera goes to whoever is still coming down.
##
## The finish-line clip is not played here, and that is not an oversight: it is
## scrubbed by [method _apply_finish_pose] against a racer the interpolated
## presentation is still drawing every frame, so the two fight. Offline the
## results screen freezes the scene first, which is what makes the clip visible
## at all. Here the scene has to keep running, so the penguin simply decelerates
## and stops — and the clip plays when the race really is over, below.
func _on_local_network_finish(recording: RaceRecording) -> void:
	_net_recording = recording
	_net_spectating = true
	Net.report_finish(roster.local.race_time, roster.local.herring)

## The last racer is in. Now the race is over for everybody at once, which is
## the point: the order on this screen is the server's, not eight machines'
## separate opinions of who was where.
##
## DEVIATION: [b]only the winner plays the finish-line clip.[/b] The original
## has one penguin and plays it to them whatever they did, and in a solo race
## this build still does. In a field of eight it lands differently: seven people
## are shown a four-second `lostrace` while the one result they are waiting for
## — the order, on the panel above it — is already on screen behind it, and the
## clip is the last thing that happens rather than the answer. The loser's
## penguin is left where it came to rest, which is where it was a moment ago
## anyway. The *outcome* is still computed for everyone, because the music sting
## is chosen by it (see [method _open_results]) and a loss should still sound
## like one.
func _on_network_race_over(standings: Array) -> void:
	if setup == null or not setup.networked or paused:
		return
	_net_spectating = false
	_net_waiting = false
	_net_countdown = -INF
	running = false
	_recall_camera()
	var clip: StringName = &""
	if roster.local.finished:
		var won: bool = _won_network_race(standings)
		clip = RaceOutcome.clip(true, won, false, false)
		if won:
			_start_finish_clip(clip)
	_open_results(_net_recording, clip, _finishing_order(standings))
	_net_recording = null

## Put the view back on the local racer, in one step rather than over a second.
##
## The results screen sets [member paused], and a paused frame returns before
## [method _present] — so the chase camera is never asked to track anything
## again and would simply stay where spectating left it, parked on somebody
## else's penguin while this one played its finish clip off screen. Resetting
## and tracking once here is the whole fix: [method ChaseCamera.reset] drops the
## smoothing so the single call lands the camera rather than starting it moving.
func _recall_camera() -> void:
	roster.view_target = roster.local
	if camera == null or roster.local == null:
		return
	camera.reset()
	var home: RacerState = roster.local.view_state()
	camera.track(home.position, home.velocity, roster.local.surface_normal(), SIM_DT)

## Whether the fastest row is ours. The server sorted them; this only reads the
## top one, because a place is what the result line says and a win is what the
## clip is chosen by.
func _won_network_race(standings: Array) -> bool:
	if standings.is_empty() or not (standings[0] is Dictionary):
		return false
	return int((standings[0] as Dictionary).get("peer", 0)) == Net.local_id()

## The finishing order, one racer per line, for the results panel.
func _finishing_order(standings: Array) -> String:
	var lines := PackedStringArray()
	var place: int = 0
	for entry: Variant in standings:
		if not (entry is Dictionary):
			continue
		var row: Dictionary = entry
		place += 1
		var who: String = str(row.get("name", "?"))
		if int(row.get("peer", 0)) == Net.local_id():
			who = "%s  (you)" % who
		if not bool(row.get("finished", false)):
			lines.push_back("—   %s   did not finish" % who)
			continue
		lines.push_back("%s   %s   %.2f s   %d herring" % [
			place_label(place), who, float(row.get("seconds", 0.0)),
			int(row.get("herring", 0))])
	return "\n".join(lines)

## The session went away under a race that needed it. There is nothing to race
## against any more and no server to report a finish to, so the honest thing is
## to leave rather than to keep simulating one penguin on an eight-lane start
## line. A race already on the results screen is left alone — it is over.
func _on_session_ended(_reason: String) -> void:
	if setup == null or not setup.networked or paused:
		return
	leave_to_main_menu()

# ------------------------------------------------------------------
#      what the HUD draws about a network race, and the way out of one
# ------------------------------------------------------------------

## The big number in the middle of the screen, or empty. Public because
## [RaceHUD] asks the race for everything it draws.
func countdown_text() -> String:
	if _net_countdown == -INF:
		return ""
	if _net_countdown > 0.0:
		return str(ceili(_net_countdown))
	return "GO!" if _net_countdown > -GO_FLASH else ""

## The line under it: what this machine is waiting for, if anything.
func network_status() -> String:
	if not _is_network_race():
		return ""
	if _net_waiting and _net_countdown == -INF:
		return "Waiting for the other racers to load the course…"
	if not _net_spectating:
		return ""
	var left: int = _racers_still_racing()
	if left <= 0:
		return "Waiting for the results…"
	return "Finished — the race ends when the last racer is in (%d to go)" % left

## How many people in the room are still on the hill, out of the room state the
## server keeps pushing. Counted there rather than off [member roster] because
## a racer who gave up stops sending snapshots and would otherwise be waited
## for forever by a count of penguins that have not crossed the line.
func _racers_still_racing() -> int:
	var left: int = 0
	for entry: Variant in Net.members():
		if entry is Dictionary and not bool((entry as Dictionary).get("done", false)):
			left += 1
	return left

## Drop out of a network race. The rest of the field stops waiting for this
## machine — see [method RaceNetwork.forfeit] — which is what keeps Esc from
## being a way to hold seven other people in a race forever.
func leave_network_race() -> void:
	Net.forfeit()
	leave_to_main_menu()

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
	# Not part of `matches()` — see [method RaceSetup.matches]. The weather is
	# rebuilt in place, whoever is on the hill. The sky first: the snow is tinted
	# by whichever one is up.
	_apply_conditions()
	_apply_snowfall()
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
	_stop_listening_to_network()
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)

## [b]A scene on its way out is still alive, and still connected.[/b]
## `change_scene_to_file` takes this node out of the tree at once but frees it
## only when the swap is flushed, a frame or more later — the main menu is
## loaded in between. The autoload's signals are not severed until the free, so
## anything [Net] says in that window lands here, on a race that has no tree to
## put it in. Forfeiting as the last racer on the hill is exactly that: the
## server's `race_over` comes straight back, and the results screen tried to
## take focus off-tree ("Condition !is_inside_tree() is true" in `grab_focus`).
## The race is over for this scene the moment it asks to leave, so it stops
## listening then.
func _stop_listening_to_network() -> void:
	for link: Array in _network_links():
		if (link[0] as Signal).is_connected(link[1]):
			(link[0] as Signal).disconnect(link[1])

## Every [Net] signal this scene listens to, and what hears it — one list, so
## the connect in `_ready` and the disconnect above cannot drift apart.
func _network_links() -> Array[Array]:
	return [
		[Net.snapshot_received, _on_snapshot_received],
		[Net.roster_changed, roster.sync_remote],
		[Net.race_go, _on_race_go],
		[Net.race_over, _on_network_race_over],
		[Net.session_ended, _on_session_ended],
	]

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
		# `P` freezes this machine's simulation and nobody else's, which in a
		# network race is not a pause — it is one racer standing still while
		# seven keep going, and their snapshots piling up behind a stopped
		# clock. There is nothing to pause a shared race with.
		if not _is_network_race():
			_toggle_key_pause()
		return
	if not event.is_action_pressed("menu"):
		return
	get_viewport().set_input_as_handled()
	if _is_network_race():
		# No course list: the course belongs to the room and there is nothing
		# here to pick. Esc is "I am out".
		leave_network_race()
		return
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
	# In a network race the place is on the finishing order below rather than
	# here: this machine's standings are eight interpolated positions and the
	# server's are eight reported times, and only one of those is the answer.
	if setup.networked:
		return line
	return "%s %s   —   %s" % [tr("POSITION"), place_label(place_of(roster.local)), line]

func _apply_environment(preset: EnvironmentPreset) -> void:
	_preset = preset
	var we: WorldEnvironment = $WorldEnvironment
	var env: Environment = preset.to_environment()
	# The preset knows what `light.lst` said; the settings file knows how far
	# the player wants to see. Fog distance is the one place the two meet.
	Config.apply_fog(env, preset)
	we.environment = env
	# The mirror renders through a camera of its own, and a camera that is not
	# given an environment does not inherit this one — see
	# [method IceReflection.set_environment].
	if reflection != null:
		reflection.set_environment(env)
	preset.apply_sun(_sun)
	_sun.shadow_enabled = _shadows_wanted(preset)
	_sun.directional_shadow_max_distance = _shadow_range_for(env)
	if course_root != null:
		course_root.set_casting_shadows(_sun.shadow_enabled)
		course_root.set_ambient(preset.ambient_illumination())
	for racer: Racer in roster.all:
		if racer is SimulatedRacer:
			(racer as SimulatedRacer).spray.particle_color = preset.particle_color
	if terrain != null:
		# The ambient the terrain clamps the sun against — see
		# [method TerrainRenderer.set_ambient]. The same two fields the
		# [Environment] above got its ambient from, so the two cannot drift.
		terrain.set_ambient(preset.ambient_illumination())
		# What the ice reflects. The horizon end is the skybox's own haze band
		# ([member EnvironmentPreset.sky_horizon_color]), not `fog_color` — the
		# fog colour is a fade target and reads `1 1 1` on 40 of the 44 shipped
		# courses, which put a full-radiance sky in the mirror and was half of
		# "ice at a flat angle is almost white". The nadir average is no use for
		# it either: that is a downward direction, and the bottom of an ETR
		# skybox face is mountains.
		# ... and `fog_color` still has a job here: it is what a low ray off
		# *distant* ice lands on, because distant terrain is what the fog fades.
		terrain.set_sky_tint(preset.sky_zenith_color, preset.sky_horizon_color,
			preset.fog_color)

## The course's sky at the time of day [member setup] asks for.
func _lit_preset(base: EnvironmentPreset) -> EnvironmentPreset:
	if setup == null:
		return base
	return LightCondition.preset_for(base, setup.conditions)

## Re-light the loaded course, when the sky has changed and the course has not.
##
## The other half of [method _apply_snowfall], and here for the same reason:
## the course screen offers both halves of the weather over a running race, and
## a change to either has to land without the hill being rebuilt. Everything
## that follows from a preset — the sun, the shadow gate, the ambient the
## terrain clamps against, what the ice reflects — is re-applied by
## [method _apply_environment]; nothing here touches the simulation, because
## nothing in the simulation has ever heard of the sky.
func _apply_conditions() -> void:
	if _course_preset == null:
		return
	var wanted: EnvironmentPreset = _lit_preset(_course_preset)
	if wanted == _preset:
		return
	_apply_environment(wanted)

## Put the weather the shell asked for on the course, at the tint this
## environment gives it.
##
## Both halves are here because both can change without the other: picking
## heavier snow from the in-race menu keeps the course, and picking another
## course keeps the weather. [method SnowFall.set_grade] does nothing when the
## grade has not moved, so this is safe to call on either path.
func _apply_snowfall() -> void:
	if snowfall == null:
		return
	if _preset != null:
		# `[partcol]` — the same field the spray is tinted by, and the reason
		# night snow is blue and evening snow is warm without anything here
		# knowing which sky it is under.
		snowfall.tint = _preset.particle_color
	snowfall.set_grade(setup.snowfall if setup != null else 0)

## The wind the weather is blown by: the local player's, since every racer is
## given its own [WindField] on the same seed and they evolve identically. Null
## on a course with no wind, which is all of them until `--wind=` says otherwise.
func _racer_wind() -> WindField:
	var sim: RacePhysics = physics
	return sim.wind if sim != null else null

## Whether the sun casts a shadow map at all, which three separate things have
## to agree on.
##
## [b]The renderer.[/b] Under Compatibility a shadow-casting light moves into a
## second, additive pass blended in sRGB rather than linear, and the sun then
## arrives five to ten times too bright with its N·L gradient crushed flat —
## `RenderBackend` has the whole story. That is not a quality setting, it is a
## broken frame, so the web build gets no shadow map whatever the file says.
##
## [b]The sky.[/b] `CCharShape::DrawShadow` returns immediately under `light_id`
## 1 or 3 — cloudy and night — so the original already knows a hard shadow under
## an overcast sky is wrong. [member EnvironmentPreset.casts_shadows] is that
## line.
##
## [b]The player.[/b] `param.perf_level > 2` gates the same thing in the
## original; [member GameConfig.shadows] is the switch.
func _shadows_wanted(preset: EnvironmentPreset) -> bool:
	return RenderBackend.supports_light_shadows() \
		and Config.shadows and preset.casts_shadows

## How far directional shadows have to reach for this environment.
##
## [b]On the two bias values in `race.tscn`, which have nowhere else to be
## written down.[/b] Godot's directional defaults are `shadow_bias` 0.1 and
## `shadow_normal_bias` 2.0, and a normal bias is measured in *world metres*
## along the surface normal: two of them, on a penguin 0.6 m across, erase his
## shadow completely. That is what "the racer casts nothing" was — the shadow
## map had him in it the whole time (rendering `vec3(ATTENUATION)` out of the
## terrain shader shows it), and the receiver was sampling far enough off the
## contact point to miss. 0.4 m and 0.03 put it back with no acne on the snow,
## which is the surface that would show it first: the terrain is a near-white
## Lambertian sheet at a grazing angle, i.e. the worst case for both.
##
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
	var recording: RaceRecording = _finish_recording()
	if _is_network_race():
		_on_local_network_finish(recording)
		return
	_show_results_after_finish(_run_id, recording)

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
		_open_results(recording, clip, _ghost_note())

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
## sting, anything else its win sting (`wonrace`, and `finish` when a rig
## falls back to it — a plain practice run has nothing to lose, matching the
## original's own non-cup behaviour).
func _open_results(recording: RaceRecording, clip: StringName, note: String) -> void:
	paused = true
	_stop_slide_sound()
	Audio.halt_all()
	var situation: MusicTheme.Situation = MusicTheme.Situation.LOST \
		if clip == &"lostrace" else MusicTheme.Situation.WON
	Audio.play_theme(course_root.course_data.music_theme, situation)
	results_menu.open(_result_line(), recording, note)

## The results screen's Continue button. The clip stops and the ordinary
## course menu takes over exactly as it did before there was a results screen.
func _on_results_continue() -> void:
	_stop_finish_clip()
	if setup != null and setup.networked:
		# Back to the shell, which puts the lobby up on the room these eight
		# people are still standing in — see [method MainMenu._open_lobby].
		# The in-race course list has nothing to offer a race whose course
		# belongs to somebody else.
		leave_to_main_menu()
		return
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
