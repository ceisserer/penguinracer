## ETR's loading screen: the course name in yellow, "please wait" in white
## under it, both centred on the same flat blue every other shell screen is
## cleared to — plus a progress bar, when there is something to measure.
##
## [b]One screen, two scenes.[/b] The panel goes up in [MainMenu] and the work
## it covers happens in [RaceScene], one [method
## SceneTree.change_scene_to_file] later. Both scenes therefore carry an
## instance of this, and the swap between them has to be invisible — which is
## the whole reason this is a scene rather than two sets of markup that drifted
## apart. Before it existed the menu's panel was torn down with the menu and
## the race drew a bare centred [Label] over a live 3D viewport, so a streamed
## build (see [PackStream]) showed the player a penguin standing on nothing for
## as long as the download took.
##
## [b]The backdrop is opaque and that is the point.[/b] `race.tscn` is already
## drawing — the rig is built, the camera is up, and there is no terrain under
## either of them yet.
##
## [b]The bar is hidden until [method set_progress] asks for it.[/b] The menu
## never asks: its panel lives for exactly one frame (see the
## `frame_post_draw` wait in [MainMenu]), and a bar that flashes 0% is worse
## than no bar. A native race never asks either, because nothing there is slow
## enough to be worth measuring.
class_name LoadingScreen
extends CanvasLayer

@onready var _title: Label = %LoadingLabel
@onready var _note: Label = %WaitLabel
@onready var _bar: ProgressBar = %LoadingBar

func _ready() -> void:
	_note.text = tr("PLEASE_WAIT")
	_bar.visible = false

## Put the screen up for [param title], with no progress shown yet.
func begin(title: String) -> void:
	_title.text = "%s '%s'" % [tr("LOADING"), title]
	_note.text = tr("PLEASE_WAIT")
	_bar.visible = false
	_bar.value = 0.0
	visible = true

## Move the bar to [param fraction] of the whole load, 0..1, and replace the
## second line with [param note] — or restore "please wait" when it is empty.
##
## The bar draws no percentage of its own (`show_percentage`), because the two
## numbers would not agree: the bar is a fraction of the whole load and the
## note, while a pack is coming down, is a count of that pack's bytes. Showing
## both invites the reader to check one against the other and find them
## contradicting. The bar carries the shape; the note carries the detail.
##
## A negative [param fraction] means there is no fraction to show: a server
## that sent no `Content-Length` leaves [method HTTPRequest.get_body_size] at
## -1, and the honest answer to "how far along" is then the note alone. The bar
## is taken away rather than left frozen at a number that is not true.
func set_progress(fraction: float, note: String = "") -> void:
	_bar.visible = fraction >= 0.0
	if fraction >= 0.0:
		_bar.value = clampf(fraction, 0.0, 1.0) * 100.0
	_note.text = note if not note.is_empty() else tr("PLEASE_WAIT")

## The load failed. The screen stays up holding [param message] — there is
## nothing behind it to fall back to, and a course that would not load is not
## a race anyone can be dropped into.
func fail(message: String) -> void:
	_note.text = message
	_bar.visible = false

## Take the screen down. The caller decides when: everything the panel is
## covering has to be finished, not merely started.
func finish() -> void:
	visible = false
