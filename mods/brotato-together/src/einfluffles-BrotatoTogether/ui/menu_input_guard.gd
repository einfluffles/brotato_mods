extends Node
# While the lobby popup (ui/lobby_popup.gd) is open: the last child of the root viewport, so its
# _input runs before every other node's (_input is dispatched in reverse tree order, then GUI,
# then unhandled). Keyboard/gamepad events go to the popup only and are marked handled, so the
# game's scene, FocusEmulators, CoopService (hold-to-join) and GUI focus never see them. Mouse
# events go to the popup the same way: on most co-op screens the FocusEmulators mark them handled
# before the GUI gets them.
# Input state is updated before events are dispatched, so the actions an event pressed are
# released again: code that polls Input (player movement, InputSync on clients) stays neutral.
# After the popup closes, the releases of keys/buttons pressed while it was open are swallowed
# too (closing with Esc / B must not reach the game: it pauses / goes back on *release*).

const DRAIN_TIMEOUT_SEC := 2.0

var handler: Object = null  # handle_panel_input(event), handle_panel_mouse(event)

var _held := {}  # key / pad button id -> true, pressed while the popup was open
var _closing := false


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


# New scenes are appended to the root after us; stay last.
func _process(_delta: float) -> void:
	var parent := get_parent()
	if parent != null and get_index() != parent.get_child_count() - 1:
		parent.move_child(self, parent.get_child_count() - 1)


func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		if handler != null:
			get_tree().set_input_as_handled()
			handler.handle_panel_mouse(event)
		return
	var id := _id_of(event)
	if _closing:
		if _held.has(id):
			get_tree().set_input_as_handled()
			if not event.is_pressed():
				_held.erase(id)
				if _held.empty():
					queue_free()
		return
	get_tree().set_input_as_handled()
	release_actions(event)
	if id != "":
		if event.is_pressed():
			_held[id] = true
		else:
			_held.erase(id)
	if handler != null:
		handler.handle_panel_input(event)


# The popup closed: stop routing, wait for the held keys/buttons to come up, then go away.
func finish() -> void:
	_closing = true
	handler = null
	if _held.empty() or not is_inside_tree():
		queue_free()
	else:
		get_tree().create_timer(DRAIN_TIMEOUT_SEC, true).connect("timeout", self, "queue_free")


static func release_actions(event: InputEvent) -> void:
	for action in InputMap.get_actions():
		if Input.is_action_pressed(action) and InputMap.event_is_action(event, action):
			Input.action_release(action)


static func _id_of(event: InputEvent) -> String:
	if event is InputEventKey:
		return "k%d" % event.scancode
	if event is InputEventJoypadButton:
		return "j%d:%d" % [event.device, event.button_index]
	return ""
