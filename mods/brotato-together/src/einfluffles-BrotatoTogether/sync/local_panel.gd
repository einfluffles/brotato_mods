extends Node
# Client: the local player's keyboard, mouse and pad on a co-op screen whose own panel runs on
# this client (the level-up / crate panels, sync/upgrades_sync.gd; the shop, sync/shop_local.gd).
#
# Co-op screens are driven by one FocusEmulator per player, and an emulator with a cursor marks
# every event that is not a co-op action as handled. So the mouse never reaches the GUI there,
# and InputService (an autoload: last in _input order) never learns which device is in use.
# This node must be added AFTER the emulators (the last child of their parent): _input runs in
# reverse tree order, so it sees every event first.
# - Device: the own slot takes the PlayerType of what the player used last. Puppet slots start
#   as gamepads; a keyboard has no trigger binding, so a keyboard player needs the game's
#   keyboard co-op panel (page arrows reachable by focus, keyboard glyphs). The game fixes the
#   type when a co-op player joins; a client is one player who may put the pad down, so it is
#   followed here, and the panel is refreshed (refresh_player_type) when it changes.
# - Mouse: moving over a focusable control of the own panel puts the own emulator's cursor
#   there; a left click presses it through the emulator, so the press belongs to the own
#   player (a native GUI press has no player: PopupManager would book it on player 0).
# - A mouse event over any player's panel ends here: another player's panel never reacts.
# - The wheel scrolls what is under the pointer in the own panel only (ui/wheel_scroll.gd), and
#   ends here wherever the pointer is.
# Nothing here knows a particular screen. A screen sets panels, keeps blocked up to date,
# calls set_own(panel, emulator, player_index) while its own panel is local, and redoes its
# own focus neighbours on player_type_changed. hold_cursor is for a screen whose cursor
# position means something (the shop's Go only counts while the cursor rests on it).

# cursor_lost: the cursor sat on a control that cannot hold it any more (a page arrow).
signal player_type_changed(player_type, cursor_lost)

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const WheelScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/wheel_scroll.gd")
# UIService._check_input: slower mouse motion is not a change of device (a bumped desk).
const MOUSE_SWITCH_SPEED := 1000.0
const STICK_SWITCH := 0.5  # InputService.joystick_deadzone
const ARROW_NAMES := ["ArrowLeft", "ArrowRight"]
const ARROW_TEXTURES := [
	"texture_normal", "texture_pressed", "texture_hover", "texture_disabled", "texture_focused"
]

var panels := []  # every player's panel (Controls): where the mouse is ours to handle
var blocked := false  # the lobby popup is open and owns keyboard, pad and mouse
var hold_cursor := false  # hover leaves the own cursor where it is (a click still moves it)

var _own: Control = null
var _emulator: Node = null
var _player_index := -1
var _hover_pos := Vector2.ZERO
var _hover_pending := false
var _held_device := -1  # the device whose accept a mouse press stands for, until released


# The own panel takes local input (null: none does, the mouse does nothing on any panel).
func set_own(panel: Control, emulator: Node, player_index: int) -> void:
	_own = panel
	_emulator = emulator
	_player_index = player_index if panel != null else -1
	_hover_pending = false
	if panel != null:
		_set_player_type(VirtualDevices.local_player_type())


func has_own() -> bool:
	return (
		_own != null
		and is_instance_valid(_own)
		and is_instance_valid(_emulator)
		and _emulator.player_index == _player_index  # parked (-1) once the panel is done
	)


func _input(event: InputEvent) -> void:
	if blocked:
		return
	if has_own():
		_track_device(event)
	if not (event is InputEventMouse):
		return
	var wheel := WheelScroll.direction(event)
	if wheel != 0:
		# Wherever the pointer is (a popup can reach past its panel): only the own panel scrolls.
		get_tree().set_input_as_handled()
		if event.pressed and has_own():
			WheelScroll.scroll_at(_own, event.position, wheel)
		return
	var left: bool = event is InputEventMouseButton and event.button_index == BUTTON_LEFT
	if left and not event.pressed:
		_release()  # wherever the pointer is by now
	if not _over_panels(event.position):
		return
	get_tree().set_input_as_handled()
	if not has_own():
		return
	if event is InputEventMouseMotion:
		# Resolved once per frame: a mouse can send many motion events in one.
		_hover_pos = event.position
		_hover_pending = true
	elif left and event.pressed:
		_hover_pending = false
		var control := control_at(_cursor_root(), event.position)
		if control != null:
			press(control)


func _process(_delta: float) -> void:
	if not _hover_pending:
		return
	_hover_pending = false
	if blocked or hold_cursor or not has_own():
		return
	var control := control_at(_cursor_root(), _hover_pos)
	if control != null and _emulator.focused_control != control:
		_emulator.focused_control = control  # the setter emits the focus signals as this player


# Accept on a control of the own panel, as the own emulator does it: toggles, option buttons,
# disabled buttons and the pressed signal with its player index are the game's.
func press(control: Control) -> void:
	if _emulator.focused_control != control:
		_emulator.focused_control = control
	_held_device = CoopService.get_remapped_player_device(_player_index)
	var accept := InputEventAction.new()
	accept.action = VirtualDevices.action("ui_accept", _held_device)
	accept.pressed = true
	_emulator._handle_input(accept)


# The mouse button came up: what holds on to an accept (the popup's hold-to-recycle) waits for
# the device's release event, so send one.
func _release() -> void:
	if _held_device < 0:
		return
	var device := _held_device
	_held_device = -1
	VirtualDevices.press_button(VirtualDevices.action("ui_accept", device), device, false)


# Where the mouse may put the cursor. A popup that took it (ItemPopup.focus(): only then do
# its buttons take focus) keeps it until it closes, as the buttons' focus neighbours do for
# the keys: the mouse stays inside it too.
func _cursor_root() -> Control:
	var node = _emulator.focused_control
	while is_instance_valid(node) and node != _own:
		if node is ItemPopup and node._focused:
			return node
		node = node.get_parent()
	return _own


# The control of the panel that a cursor can land on at pos (viewport coordinates): what the
# emulator could focus, not what the GUI would hit. The game's co-op panels are not laid out
# for a mouse (CoopUpgradesUIPlayerContainer has a Control that stops the mouse over all of
# its content), so mouse filters say nothing here.
static func control_at(panel: Control, pos: Vector2) -> Control:
	if not panel.is_visible_in_tree():
		return null
	return _find_at(panel, pos, null)


# Tree order is draw order: of the focusable controls under pos, the last one is on top. An open
# popup hides the ones below: hovering its description must not move the cursor away.
static func _find_at(node: Node, pos: Vector2, found: Control) -> Control:
	if node is CanvasItem and not node.visible:
		return found
	if node is Control:
		var inside: bool = _rect(node).has_point(pos)
		if not inside and (node.rect_clip_content or node is ScrollContainer):
			return found  # its children are cut off here
		if inside and _is_focusable(node):
			found = node
		elif inside and node is ItemPopup:
			found = null  # an item's popup covers what lies below it
	for child in node.get_children():
		found = _find_at(child, pos, found)
	return found


# FocusEmulator._filter_control: what a cursor may land on.
static func _is_focusable(control: Control) -> bool:
	if control is BaseButton and control.disabled:
		return false
	return control.focus_mode == Control.FOCUS_ALL


# In viewport coordinates, like the positions of the events _input gets.
static func _rect(control: Control) -> Rect2:
	return control.get_global_transform_with_canvas().xform(Rect2(Vector2.ZERO, control.rect_size))


func _over_panels(pos: Vector2) -> bool:
	for panel in panels:
		if is_instance_valid(panel) and panel.is_visible_in_tree() and _rect(panel).has_point(pos):
			return true
	return false


# What InputService does with an event in solo play; here it would never get to see it.
func _track_device(event: InputEvent) -> void:
	if event is InputEventMouse:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	var player_type := event_player_type(event)
	if player_type < 0:
		return
	if not (event is InputEventMouse):
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	InputService.using_gamepad = player_type != CoopService.PlayerType.KEYBOARD_AND_MOUSE
	_set_player_type(player_type)


# The CoopService.PlayerType an event comes from, -1 when it says nothing about the device
# (releases, a resting stick, slow mouse motion, the virtual devices' own action events).
static func event_player_type(event: InputEvent) -> int:
	var keyboard: int = CoopService.PlayerType.KEYBOARD_AND_MOUSE
	if event is InputEventKey or event is InputEventMouseButton:
		return keyboard if event.pressed else -1
	if event is InputEventMouseMotion:
		return keyboard if event.speed.length() >= MOUSE_SWITCH_SPEED else -1
	if event is InputEventJoypadButton:
		return VirtualDevices.pad_type(event.device) if event.pressed else -1
	if event is InputEventJoypadMotion and abs(event.axis_value) >= STICK_SWITCH:
		return VirtualDevices.pad_type(event.device)
	return -1


func _set_player_type(player_type: int) -> void:
	if not VirtualDevices.set_slot_type(_player_index, player_type):
		return
	var had_cursor: bool = _emulator.focused_control != null
	refresh_player_type(_own, _player_index, _emulator)
	var cursor_lost: bool = had_cursor and _emulator.focused_control == null
	emit_signal("player_type_changed", player_type, cursor_lost)


# A panel built for one PlayerType shows another: carousels switch between trigger glyphs and
# focusable arrows, key hints reload their glyph. The game only does this once, in _ready.
# The caller redoes what is its screen's own (focus neighbours, a cursor that lost its place).
static func refresh_player_type(node: Node, player_index: int, emulator: Node) -> void:
	if node is Carousel:
		_refresh_carousel(node, emulator)
	elif node is InputIcon:
		# The game leaves these on player 0; inside a player's panel they are that player's.
		node.player_index = player_index
		node._change_controller()
	elif node is CoopShopHint:
		# The setter reloads the glyph. CoopItemPopup._set_player_index skips its steal hint,
		# which would show player 0's device.
		node.player_index = player_index
	for child in node.get_children():
		refresh_player_type(child, player_index, emulator)


static func _refresh_carousel(carousel: Node, emulator: Node) -> void:
	var arrows := [carousel.arrow_left, carousel.arrow_right]
	if emulator != null and emulator.focused_control in arrows:
		# Its focus style remembers a texture that is replaced below.
		emulator.focused_control = null
	if not carousel.are_trigger_buttons_active():
		_restore_arrows(carousel, arrows)
	carousel.index = carousel.index  # the setter: arrows enabled by page, or trigger glyphs


# Carousel swaps its arrow textures for trigger glyphs and keeps no copy: take the arrows of
# the scene it was instanced from.
static func _restore_arrows(carousel: Node, arrows: Array) -> void:
	var scene = load(carousel.filename) if carousel.filename != "" else null
	if not (scene is PackedScene):
		return
	var fresh: Node = scene.instance()  # never enters the tree: no _ready, no glyphs
	for i in arrows.size():
		var source = fresh.find_node(ARROW_NAMES[i], true, false)
		if source is TextureButton:
			for property in ARROW_TEXTURES:
				arrows[i].set(property, source.get(property))
	fresh.free()
