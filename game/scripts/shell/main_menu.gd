## The screen the game starts on, and the one it comes back to.
##
## Until now `race.tscn` was the main scene and the course list was a panel over
## a course that had already been loaded — which meant the game always paid for
## a course before the player had chosen one, and there was nowhere for a
## settings screen to live. This is the plan's arrangement (godot-port-plan.md
## §4.1): the shell above the race, holding it rather than sitting inside it.
##
## Five entries. Three are ETR's own words: `PRACTICE` is a single free race on
## any course — the original's term for exactly this, and the reason the label
## comes out of the imported strings rather than being written here —
## `SELECT_A_CHARACTER` is [CharacterMenu] over the five rows of
## `char/characters.lst`, and `CONFIGURATION` is [SettingsMenu] over
## `penguinracer.cfg`. Cups, events and profiles are imported and waiting; when
## they arrive they are more entries in the same column.
##
## Two are beyond the original. *Race the computer* — ETR has no
## opponents on the hill at all, so there is no string to migrate and the label
## is written here (see [AISkill] for the same call about the difficulty names).
## It opens the same [CourseMenu] Practice does, carrying a [RaceSetup] that
## turns the panel's opponent and skill spinners on. Both entries are one screen
## for that reason: the difference between them is two numbers, and a player who
## has just been beaten should be able to change one of them without leaving.
##
## ... and *Network multiplayer*, which opens [LobbyMenu] rather than the course
## list, because in a network race the course is not this player's to choose: it
## belongs to the room, and the room belongs to whoever created it. The lobby
## still picks it on a [CourseMenu] — its own instance, in a network mode. Everything
## else about such a race is a race against the computer with the field arriving
## over a socket — see [RaceSetup] and [RaceNetwork].
##
## The field itself is remembered — `[game] opponents` and `opponent_skill` in
## `penguinracer.cfg`, written when a race starts rather than on a settings
## screen, because it is a choice made in the flow of racing rather than a
## preference someone goes looking for.
##
## The character entry is here rather than on its own startup screen because
## ETR's is half of `CRegist`, whose other half is the player profile — see
## [CharacterMenu].
##
## [b]A scripted run never sees this screen.[/b] `--course=` or `--auto-input=`
## on the command line — which is every capture, every `tools/shot.sh` and the
## whole headless verification path — hands straight over to the race, as does
## `?course=` on the web build's URL. That is what keeps `RACE_READY` arriving
## at the same point in the browser harness as it did when the race was the main
## scene.
class_name MainMenu
extends Control

const RACE_SCENE := "res://scenes/race.tscn"

## Whether the shell has already been through its boot decision once.
##
## `--course=` and `?course=` are boot arguments, and a command line does not go
## away when the scene does: without this, coming back from that race would land
## here and be sent straight round again, and the menu would be unreachable for
## the whole run.
static var _boot_handled: bool = false

@onready var _title: Label = %Title
## The whole title-and-buttons page. The panels draw over the same background
## and would otherwise show the title through their own dim.
@onready var _frame: MarginContainer = %Frame
@onready var _practice_button: Button = %PracticeButton
@onready var _opponents_button: Button = %OpponentsButton
@onready var _network_button: Button = %NetworkButton
@onready var _ghost_button: Button = %GhostButton
@onready var _character_button: Button = %CharacterButton
@onready var _settings_button: Button = %SettingsButton
@onready var _quit_button: Button = %QuitButton
@onready var _version: Label = %Version
@onready var _course_menu: CourseMenu = $CourseMenu
@onready var _character_menu: CharacterMenu = $CharacterMenu
@onready var _settings: SettingsMenu = $SettingsMenu
@onready var _ghost_menu: GhostMenu = $GhostMenu
@onready var _lobby: LobbyMenu = $LobbyMenu
## ETR's loading panel. Shared with [RaceScene] rather than built twice — see
## [LoadingScreen]: the work this covers finishes in the other scene.
@onready var _loading: LoadingScreen = $LoadingScreen

func _ready() -> void:
	var first_run: bool = not _boot_handled
	_boot_handled = true
	var args: LaunchArgs = LaunchArgs.current()
	if first_run:
		# `--no-intro` or `?nointro`, and `--character=` or `?character=`.
		# [LaunchArgs] is where the two transports become one list, so this
		# screen is no longer the one place that knows a URL exists.
		RaceScene.play_intro = not args.no_intro
		RaceScene.requested_character = args.character
		# `--server=` / `?server=`, and `--lobby` / `?lobby`. Started here rather
		# than in the race scene because the session outlives any one race: the
		# connection stays up across a race, a restart and a return to the room.
		Net.configure(Config.player_name, Config.character)
		Net.start_from_cmdline(Config.multiplayer_server, Config.multiplayer_port)
	if first_run and args.wants_direct_race():
		_start_race(args.course_scene_path())
		return

	_title.text = ProjectSettings.get_setting("application/config/name", "PenguinRacer")
	_version.text = "v%s" % ProjectSettings.get_setting("application/config/version", "")
	_practice_button.text = tr("PRACTICE")
	# None of the three is a migrated string; the original has no opponents, no
	# ghosts and nobody to race over a network.
	_opponents_button.text = "Race the computer"
	_network_button.text = "Network multiplayer"
	_ghost_button.text = "Race against ghost"
	_settings_button.text = tr("CONFIGURATION")
	_quit_button.text = tr("QUIT")
	_refresh_character_button()
	# The browser owns the tab; a quit button there does nothing useful.
	_quit_button.visible = not OS.has_feature("web")
	_loading.finish()

	_practice_button.pressed.connect(_open_practice_menu)
	_opponents_button.pressed.connect(_open_race_menu)
	_network_button.pressed.connect(_open_lobby)
	_ghost_button.pressed.connect(_open_ghost_menu)
	_character_button.pressed.connect(_open_character_menu)
	_settings_button.pressed.connect(_open_settings)
	_quit_button.pressed.connect(func() -> void: Audio.quit_game(0))
	_course_menu.course_chosen.connect(_on_course_chosen)
	_course_menu.closed.connect(_show_root)
	_course_menu.back_requested.connect(_show_root)
	_character_menu.chosen.connect(_on_character_chosen)
	_character_menu.closed.connect(_show_root)
	_settings.closed.connect(_show_root)
	_ghost_menu.run_chosen.connect(_on_ghost_run_chosen)
	_ghost_menu.closed.connect(_show_root)
	_lobby.race_starting.connect(_on_network_race_starting)
	_lobby.closed.connect(_show_root)

	Audio.play_menu_music()
	_show_root()
	# Landing here straight out of a network race is coming back to the room
	# those people are still standing in, and making the player find the button
	# again to see it is a screen nobody asked for. Being in a room is not
	# enough on its own: somebody who joined one, pressed Back and then raced
	# Practice pressed Back for a reason.
	var from_network_race: bool = RaceScene.requested_setup != null \
		and RaceScene.requested_setup.networked
	if args.wants_lobby() or Net.connecting() or (from_network_race and Net.in_room()):
		_open_lobby()

# ------------------------------------------------------------------
#                            the four screens
# ------------------------------------------------------------------

## Back to the column of buttons, from wherever. Focus goes with it, so the
## whole shell is playable from the keyboard.
func _show_root() -> void:
	_frame.visible = true
	_practice_button.grab_focus()

func _open_practice_menu() -> void:
	_open_course_menu(RaceSetup.practice().in_snow(Config.snowfall)
		.under_sky(Config.conditions))

## The same screen with the field spinners showing, opened on whatever the
## player last raced — [GameConfig] holds it so that the answer survives a
## restart of the game, not just of the scene.
func _open_race_menu() -> void:
	_open_course_menu(RaceSetup.against(Config.opponents,
		Config.opponent_skill).in_snow(Config.snowfall).under_sky(Config.conditions))

func _open_course_menu(setup: RaceSetup) -> void:
	_frame.visible = false
	# Nothing is loaded and nothing is running, so there is no race to continue
	# and the last course raced is only a highlight.
	_course_menu.open(RaceScene.requested_course_path.get_base_dir().get_file(),
		false, setup)

func _open_character_menu() -> void:
	_frame.visible = false
	_character_menu.open(Config.character)

func _open_settings() -> void:
	_frame.visible = false
	_settings.open()

func _open_ghost_menu() -> void:
	_frame.visible = false
	_ghost_menu.open()

func _open_lobby() -> void:
	_frame.visible = false
	# The name and character the lobby announces are the ones on this screen,
	# re-read every time it opens: the character menu is one button up from here
	# and a player who changed penguins should race as the one they chose.
	Net.configure(Config.player_name, Config.character)
	_lobby.open()

## The character screen picks; this writes. [SettingsMenu] saves its own page of
## the same file the same way — the screens move values, [GameConfig] owns the
## file.
func _on_character_chosen(dir: String) -> void:
	if dir != Config.character:
		Config.character = dir
		Config.save()
	# A run started with `--character=`/`?character=` said "this run", and the
	# player has now said something else. Clearing it is what makes the choice
	# on screen the one the next race uses.
	RaceScene.requested_character = ""
	_refresh_character_button()
	_show_root()

## `Select a character:` with the current one after it. ETR's own string, colon
## and all — the colon is there because the original draws this text as a label
## above the framed name, and here the name is what follows it.
func _refresh_character_button() -> void:
	var catalog: CharacterCatalog = CharacterCatalog.load_default()
	var listing: CharacterListing = catalog.find(Config.character)
	var name: String = listing.title() if listing != null else Config.character
	_character_button.text = "%s %s" % [tr("SELECT_A_CHARACTER"), name]

func _on_course_chosen(listing: CourseListing, setup: RaceSetup) -> void:
	# The field travels to the race the way the course does, and is remembered
	# for the next time this screen opens. A practice run leaves the stored
	# field alone: choosing to race alone is not choosing zero opponents.
	RaceScene.requested_setup = setup
	# The weather is kept whichever mode this was: the two weather rows are
	# offered on the Practice screen too, so a practice run really is the player
	# saying so.
	var changed: bool = setup.snowfall != Config.snowfall \
		or setup.conditions != Config.conditions
	Config.snowfall = setup.snowfall
	Config.conditions = setup.conditions
	if setup.is_race() and (setup.opponents != Config.opponents
			or setup.skill != Config.opponent_skill):
		Config.opponents = setup.opponents
		Config.opponent_skill = setup.skill
		changed = true
	if changed:
		Config.save()
	# ETR's loading screen: the course in yellow, "please wait" in white under
	# it, both centred on the same flat blue every other screen is cleared to.
	# The race scene puts up the identical panel on the other side of the swap
	# and takes it down once the hill is actually there, so this is the start of
	# one continuous screen rather than a panel that vanishes with the menu.
	_loading.begin(listing.title())
	Audio.halt_all()
	# Building a course blocks the main thread for long enough to be seen as a
	# freeze, so the panel has to have been drawn before the load starts — one
	# composited frame, not just one assignment.
	await RenderingServer.frame_post_draw
	_start_race(listing.scene_path)

## The room's admin started the race. The course is the room's, the weather is
## the room's, and the field is whoever else is in it — which is nobody this
## scene has to build: [RaceScene] grows a [PlaybackRacer] per peer as the
## snapshots arrive. Everything after this point is the ordinary handover.
##
## A course the room named but this build does not have is the one failure
## worth a word: the player is put back on the lobby with the session intact
## rather than dropped into a race with nowhere to load.
func _on_network_race_starting(course_dir: String, snow: int, sky: int) -> void:
	var listing: CourseListing = CourseCatalog.load_default().find(course_dir)
	if listing == null or not ResourceLoader.exists(listing.preview_path):
		Net.forfeit()
		_open_lobby()
		return
	RaceScene.requested_setup = RaceSetup.networked_race().in_snow(snow) \
		.under_sky(LightCondition.of(sky))
	RaceScene.requested_ghost = null
	_loading.begin(listing.title())
	Audio.halt_all()
	await RenderingServer.frame_post_draw
	_start_race(listing.scene_path)

## A saved run was picked off [GhostMenu]'s list. Forces Practice — a ghost
## race has never had a field, the same way choosing a course from the
## Practice button always has — and starts the race on the course the run was
## recorded on, with that run set as [member RaceScene.requested_ghost].
func _on_ghost_run_chosen(recording: RaceRecording) -> void:
	var listing: CourseListing = CourseCatalog.load_default().find(recording.course_dir)
	if listing == null:
		# The course this was recorded on is no longer in this build. Nothing
		# ventured — back to the root rather than starting a race with nowhere
		# to load.
		_show_root()
		return
	RaceScene.requested_setup = RaceSetup.practice().in_snow(Config.snowfall) \
		.under_sky(Config.conditions)
	RaceScene.requested_ghost = recording
	_loading.begin(listing.title())
	Audio.halt_all()
	await RenderingServer.frame_post_draw
	_start_race(listing.scene_path)

## Hand over to the race. The course travels on [member
## RaceScene.requested_course_path] because a scene swap leaves nothing else
## standing: the node about to be built cannot be reached to set a property on,
## and an autoload for one string would be a third global for the shell to own.
## Empty means "whatever the race scene itself defaults to".
##
## Deferred because the earliest caller is `_ready`: a scripted run decides to
## skip this screen while the tree is still in the middle of adding it, and
## swapping the scene from inside that is "Parent node is busy adding/removing
## children". One frame later the shell is fully built and can be thrown away
## cleanly.
func _start_race(course_scene_path: String) -> void:
	RaceScene.requested_course_path = course_scene_path
	get_tree().change_scene_to_file.call_deferred(RACE_SCENE)

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("menu"):
		return
	# The settings and character panels handle their own Esc and consume it;
	# this is the course list, which is driven from here.
	if _course_menu.visible:
		get_viewport().set_input_as_handled()
		_course_menu.close()
