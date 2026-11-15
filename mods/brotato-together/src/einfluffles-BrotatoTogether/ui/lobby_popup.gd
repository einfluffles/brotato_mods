extends CanvasLayer
# The lobby page (ui/lobby_page.gd) as a popup over the screen, for where no game menu can hold
# it: a client on a screen without a pause menu (ui/lobby_menu.gd opens it on pause).
# Co-op screens have FocusEmulators that mark every foreign event as handled, so while it is open
# ui/menu_input_guard.gd takes every key/pad and mouse event away from the game and hands it to
# handle_panel_input() / handle_panel_mouse(). The cursor is kept visible (the game hides it in
# co-op). The buttons hold the Godot focus meanwhile; the screen gets its own back on close.

signal open_changed(is_open)

const MenuInputGuard := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/menu_input_guard.gd"
)
const GUARD_NAME := "BrotatoTogetherMenuInputGuard"
# Pads are matched by button on any device (the game's base ui_* actions only bind device 0).
const PAD_NAV := {JOY_DPAD_UP: -1, JOY_DPAD_LEFT: -1, JOY_DPAD_DOWN: 1, JOY_DPAD_RIGHT: 1}
const NAV_ACTIONS := {"ui_up": -1, "ui_left": -1, "ui_down": 1, "ui_right": 1}

var page: Control = null  # set before this node enters the tree

var _guard: Node = null
var _mouse_mode_before := Input.MOUSE_MODE_VISIBLE
var _focus_before: Control = null
var _mouse_down_on: Button = null


func _ready() -> void:
	layer = 128
	pause_mode = PAUSE_MODE_PROCESS
	page.visible = false
	page.connect("back_button_pressed", self, "close")
	add_child(page)


func is_open() -> bool:
	return page.visible


func open() -> void:
	if page.visible:
		return
	_focus_before = page.get_focus_owner()
	_mouse_down_on = null
	_mouse_mode_before = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_guard = MenuInputGuard.new()
	_guard.name = GUARD_NAME
	_guard.handler = self
	get_tree().root.call_deferred("add_child", _guard)
	page.visible = true
	page.init()
	emit_signal("open_changed", true)


func close() -> void:
	if not page.visible:
		return
	page.visible = false  # its focus goes with it
	Input.set_mouse_mode(_mouse_mode_before)
	if _guard != null and is_instance_valid(_guard):
		_guard.finish()  # also swallows the release of the key/button that closed us
	_guard = null
	if is_instance_valid(_focus_before) and _focus_before.is_visible_in_tree():
		_focus_before.grab_focus()
	_focus_before = null
	emit_signal("open_changed", false)


# The game's InputService hides the cursor in co-op.
func _process(_delta: float) -> void:
	if page.visible:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


# The mouse while open (from MenuInputGuard): pointing takes the cursor, as on the game's menu
# buttons; a left click that starts and ends on a button presses it.
func handle_panel_mouse(event: InputEvent) -> void:
	var button: Button = page.button_at(event.position)
	if event is InputEventMouseMotion:
		if button != null and not button.has_focus():
			button.grab_focus()
	elif event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			_mouse_down_on = button
		elif button != null and button == _mouse_down_on:
			page.press(button)


# Keyboard / gamepad while open (from MenuInputGuard).
func handle_panel_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if not event.pressed:
			return
		if event.is_action_pressed("ui_cancel"):
			page.back()
		elif event.is_action_pressed("ui_accept"):
			page.press_focused()
		else:
			for action in NAV_ACTIONS:
				if event.is_action_pressed(action, true):
					page.move_focus(NAV_ACTIONS[action])
					return
	elif event is InputEventJoypadButton:
		if not event.pressed:
			return
		if event.button_index == JOY_BUTTON_0:
			page.press_focused()
		elif event.button_index == JOY_BUTTON_1:
			page.back()
		elif event.button_index == JOY_START:
			close()
		elif PAD_NAV.has(event.button_index):
			page.move_focus(PAD_NAV[event.button_index])
	elif event is InputEventAction and event.pressed:
		# InputService's repeat for held d-pads / sticks: "ui_left" or "ui_left_<device>".
		var action: String = event.action
		for base in NAV_ACTIONS:
			if action == base or action.begins_with(base + "_"):
				page.move_focus(NAV_ACTIONS[base])
				return
