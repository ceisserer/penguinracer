## The screen the game starts on, and the one it comes back to.
##
## Until now `race.tscn` was the main scene and the course list was a panel over
## a course that had already been loaded — which meant the game always paid for
## a course before the player had chosen one, and there was nowhere for a
## settings screen to live. This is the plan's arrangement (godot-port-plan.md
## §4.1): the shell above the race, holding it rather than sitting inside it.
##
## Two entries, both of them ETR's own: `PRACTICE` is a single free race on any
## course — the original's word for exactly this, and the reason the label comes
## out of the imported strings rather than being written here — and
## `CONFIGURATION` is [SettingsMenu] over `penguinracer.cfg`. Cups, events and
## profiles are imported and waiting; when they arrive they are more entries in
## the same column.
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
@onready var _settings_button: Button = %SettingsButton
@onready var _quit_button: Button = %QuitButton
@onready var _version: Label = %Version
@onready var _course_menu: CourseMenu = $CourseMenu
@onready var _settings: SettingsMenu = $SettingsMenu
@onready var _loading: CanvasLayer = $Loading
@onready var _loading_label: Label = %LoadingLabel
@onready var _wait_label: Label = %WaitLabel

func _ready() -> void:
	var first_run: bool = not _boot_handled
	_boot_handled = true
	if first_run:
		# `?nointro=1`. Read here because a browser has no command line and this
		# is the one screen that gets to look at the URL; the race scene reads
		# the same thing off `--no-intro` where there is one.
		RaceScene.play_intro = not _url_query().has("nointro")
	if first_run and _direct_race_requested():
		_start_race(_requested_course_path())
		return

	_title.text = ProjectSettings.get_setting("application/config/name", "PenguinRacer")
	_version.text = "v%s" % ProjectSettings.get_setting("application/config/version", "")
	_practice_button.text = tr("PRACTICE")
	_settings_button.text = tr("CONFIGURATION")
	_quit_button.text = tr("QUIT")
	_wait_label.text = tr("PLEASE_WAIT")
	# The browser owns the tab; a quit button there does nothing useful.
	_quit_button.visible = not OS.has_feature("web")
	_loading.visible = false

	_practice_button.pressed.connect(_open_course_menu)
	_settings_button.pressed.connect(_open_settings)
	_quit_button.pressed.connect(func() -> void: Audio.quit_game(0))
	_course_menu.course_chosen.connect(_on_course_chosen)
	_course_menu.closed.connect(_show_root)
	_course_menu.back_requested.connect(_show_root)
	_settings.closed.connect(_show_root)

	Audio.play_menu_music()
	_show_root()

# ------------------------------------------------------------------
#                            the three screens
# ------------------------------------------------------------------

## Back to the column of buttons, from wherever. Focus goes with it, so the
## whole shell is playable from the keyboard.
func _show_root() -> void:
	_frame.visible = true
	_practice_button.grab_focus()

func _open_course_menu() -> void:
	_frame.visible = false
	# Nothing is loaded and nothing is running, so there is no race to continue
	# and the last course raced is only a highlight.
	_course_menu.open(RaceScene.requested_course_path.get_base_dir().get_file(), false)

func _open_settings() -> void:
	_frame.visible = false
	_settings.open()

func _on_course_chosen(listing: CourseListing) -> void:
	# ETR's loading screen: the course in yellow, "please wait" in white under
	# it, both centred on the same flat blue every other screen is cleared to.
	_loading_label.text = "%s '%s'" % [tr("LOADING"), listing.title()]
	_loading.visible = true
	Audio.halt_all()
	# Building a course blocks the main thread for long enough to be seen as a
	# freeze, so the panel has to have been drawn before the load starts — one
	# composited frame, not just one assignment.
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
	# The settings panel handles its own Esc and consumes it; this is the course
	# list, which is driven from here.
	if _course_menu.visible:
		get_viewport().set_input_as_handled()
		_course_menu.close()

# ------------------------------------------------------------------
#                      skipping straight to a race
# ------------------------------------------------------------------

## Whether this run is a scripted one that wants a course rather than a menu.
##
## `--auto-input=` alone is enough: it is a run with a stand-in for a player, so
## the default course is the right one. A bare `--capture=` is not — that one
## captures whatever is on screen, which is how this screen gets screenshotted.
## Such a run also skips the start animation; see [member RaceScene.play_intro].
func _direct_race_requested() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--course=") or arg.begins_with("--auto-input="):
			return true
	var query: Dictionary = _url_query()
	return query.has("course") or query.has("autostart")

## The course such a run named, as a scene path, or `""` for the default.
func _requested_course_path() -> String:
	var dir: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--course="):
			dir = arg.trim_prefix("--course=")
	if dir.is_empty():
		dir = str(_url_query().get("course", ""))
	if dir.is_empty():
		return ""
	return "res://courses/%s/course.tscn" % dir

## The web build's `?a=b&c=d`, since there is no command line in a browser.
## Empty everywhere else — [JavaScriptBridge] exists on every platform but only
## evaluates anything on web.
func _url_query() -> Dictionary:
	if not OS.has_feature("web"):
		return {}
	var search: Variant = JavaScriptBridge.eval("location.search", true)
	if not (search is String):
		return {}
	var out: Dictionary = {}
	for pair: String in str(search).trim_prefix("?").split("&", false):
		var eq: int = pair.find("=")
		if eq < 0:
			out[pair.uri_decode()] = ""
		else:
			out[pair.left(eq).uri_decode()] = pair.substr(eq + 1).uri_decode()
	return out
