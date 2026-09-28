## Drag-to-scroll for an [ItemList], which Godot does not give it.
##
## An [ItemList] scrolls by wheel, keys and its thin scroll bar, and nothing
## else: a finger on a row selects that row on touch-down, and dragging only
## drags the selection along. On a phone the 44-course list could not be scrolled
## at all. This makes the list behave like any phone list instead:
##
## - a drag scrolls it, and a flick keeps it going and slows to a stop;
## - a tap — a touch that did not move past [constant DRAG_THRESHOLD] — selects
##   the row under it on release, emitting [signal ItemList.item_selected] as a
##   click would, and a double tap on the selected row emits
##   [signal ItemList.item_activated], as a double click would.
##
## It works by taking the list's input before the list does: the
## `gui_input` signal runs ahead of the control's own handler, and accepting
## the event there ends it. Only the mouse events Godot makes up from a touch
## ([constant InputEvent.DEVICE_ID_EMULATION]) are swallowed — those are what
## select on touch-down — so a real mouse and the keyboard work as before.
##
## [code]TouchListScroll.attach(list)[/code] and forget it: it lives as the
## list's child and goes when the list does.
class_name TouchListScroll
extends Node

## How far a finger may move, in canvas units, and still be a tap. A thumb
## wobbles; under `canvas_items` stretch a unit is at least a physical pixel.
const DRAG_THRESHOLD := 16.0
## How quickly a flick dies away, per second (exponential decay rate).
const FLING_DECAY := 4.0
## Under this speed, in canvas units per second, a flick stops.
const FLING_STOP_SPEED := 20.0

var _list: ItemList
## A finger is down on the list.
var _pressed: bool = false
## ...and has moved far enough to be a drag rather than a tap.
var _dragging: bool = false
var _press_at: Vector2 = Vector2.ZERO
## The press that started this touch was a double tap.
var _double_tap: bool = false
## Scroll speed, canvas units per second, positive toward the end of the list.
var _fling_speed: float = 0.0

static func attach(list: ItemList) -> TouchListScroll:
	var scroller := TouchListScroll.new()
	scroller._list = list
	scroller.name = "TouchListScroll"
	list.add_child(scroller)
	list.gui_input.connect(scroller._on_list_input)
	return scroller

func _ready() -> void:
	set_process(false)

func _on_list_input(event: InputEvent) -> void:
	if event.device == InputEvent.DEVICE_ID_EMULATION \
			and (event is InputEventMouseButton or event is InputEventMouseMotion):
		_list.accept_event()
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.index != 0:
			return
		if touch.pressed:
			_pressed = true
			_dragging = false
			_press_at = touch.position
			_double_tap = touch.double_tap
			_stop_fling()
		elif _pressed:
			_pressed = false
			if _dragging:
				_start_fling()
			else:
				_tap(touch.position)
		_list.accept_event()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index != 0 or not _pressed:
			return
		if not _dragging and absf(drag.position.y - _press_at.y) > DRAG_THRESHOLD:
			_dragging = true
		if _dragging:
			scroll_by(-drag.relative.y)
			_fling_speed = -drag.velocity.y
		_list.accept_event()

## Move the list by [param amount] canvas units; the scroll bar clamps. Returns
## whether it moved at all.
func scroll_by(amount: float) -> bool:
	var bar: VScrollBar = _list.get_v_scroll_bar()
	var before: float = bar.value
	bar.value = before + amount
	return not is_equal_approx(bar.value, before)

func _tap(at: Vector2) -> void:
	var index: int = _list.get_item_at_position(at, true)
	if index < 0 or not _list.is_item_selectable(index) or _list.is_item_disabled(index):
		return
	_list.grab_focus()
	if _double_tap and _list.is_selected(index):
		_list.item_activated.emit(index)
		return
	_list.select(index)
	_list.item_selected.emit(index)

func _start_fling() -> void:
	set_process(absf(_fling_speed) > FLING_STOP_SPEED)

func _stop_fling() -> void:
	_fling_speed = 0.0
	set_process(false)

func _process(delta: float) -> void:
	_fling_speed *= exp(-FLING_DECAY * delta)
	if not scroll_by(_fling_speed * delta) or absf(_fling_speed) < FLING_STOP_SPEED:
		_stop_fling()
