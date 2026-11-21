extends Node
# Client: the local player's keyboard, mouse and pad on a co-op screen whose own panel runs here.
# An emulator with a cursor marks every event that is not a co-op action as handled, so this
# node must be the emulators' last sibling: _input runs in reverse tree order.

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
var _near_on = null  # the control the last hover was on, or whose open popup (or the gap to it)
var _closed_on = null  # the cursor's control whose popup the mouse closed by leaving it


func set_own(panel: Control, emulator: Node, player_index: int) -> void:
	_own = panel
	_emulator = emulator
	_player_index = player_index if panel != null else -1
	_hover_pending = false
	_near_on = null
	_closed_on = null
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
	if event is InputEventMouseMotion and has_own():
		# Resolved once per frame: a mouse can send many motion events in one. Also off the
		# panels, where leaving an item's popup closes it.
		_hover_pos = event.position
		_hover_pending = true
	if not _over_panels(event.position):
		return
	get_tree().set_input_as_handled()
	if not has_own():
		return
	if left and event.pressed:
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
	var root := _cursor_root()
	var control := control_at(root, _hover_pos)
	var focused: Control = _emulator.focused_control
	if control == null:
		var popup = _open_popup(_own, focused) if root == _own else null
		var near: bool = popup != null and _near_popup(popup, focused, _hover_pos)
		if popup != null and not near and _near_on == focused:
			# Only the popup goes (the game's mouse_exited unfocuses the item too): the cursor
			# and the shop's focused item, which its lock, steal and ban keys act on, stay.
			popup.hide()
			_closed_on = focused
		_near_on = focused if near else null
		return
	_near_on = control
	if focused != control:
		_closed_on = null
		_emulator.focused_control = control  # the setter emits the focus signals as this player
	elif control == _closed_on:
		_closed_on = null
		if _open_popup(_own, control) == null:
			FocusEmulatorSignal.emit(control, "focus_entered", _player_index)  # shown again


# Through the own emulator, so the press belongs to the own player: a native GUI press has no
# player, and PopupManager would book it on player 0.
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


# The shown item popup that belongs to control (its attachment), one that did not take the cursor.
static func _open_popup(node: Node, control: Control) -> ItemPopup:
	if control == null or (node is CanvasItem and not node.visible):
		return null
	if node is ItemPopup:
		if node._attachment == control and not node._focused:
			return node as ItemPopup
		return null
	for child in node.get_children():
		var found := _open_popup(child, control)
		if found != null:
			return found
	return null


# On the popup, on its item or within BasePopup.DIST of the item: the popup touches its item
# (extensions/ui/coop_item_popup.gd), but the game's sideways shift still leaves that gap.
static func _near_popup(popup: Control, item: Control, pos: Vector2) -> bool:
	return _rect(popup).has_point(pos) or _rect(item, BasePopup.DIST).has_point(pos)


# What the emulator could focus at pos (viewport coordinates), not what the GUI would hit:
# CoopUpgradesUIPlayerContainer has a Control that stops the mouse over all of its content.
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
static func _rect(control: Control, margin := 0.0) -> Rect2:
	var local := Rect2(Vector2.ZERO, control.rect_size).grow(margin)
	return control.get_global_transform_with_canvas().xform(local)


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


# The game fixes the type when a co-op player joins. A client is one player who may put the pad
# down, so the type follows the device used last.
func _set_player_type(player_type: int) -> void:
	if not VirtualDevices.set_slot_type(_player_index, player_type):
		return
	var had_cursor: bool = _emulator.focused_control != null
	refresh_player_type(_own, _player_index, _emulator)
	var cursor_lost: bool = had_cursor and _emulator.focused_control == null
	emit_signal("player_type_changed", player_type, cursor_lost)


# A panel built for one PlayerType shows another: carousels switch between trigger glyphs and
# focusable arrows, key hints reload their glyph. The game only does this once, in _ready.
static func refresh_player_type(node: Node, player_index: int, emulator: Node) -> void:
	if node is Carousel:
		_refresh_carousel(node, emulator)
	else:
		_adopt_hint(node, player_index)
	for child in node.get_children():
		refresh_player_type(child, player_index, emulator)


# The key hints inside a player's panel are that player's (see _adopt_hint).
static func adopt_hints(node: Node, player_index: int) -> void:
	_adopt_hint(node, player_index)
	for child in node.get_children():
		adopt_hints(child, player_index)


static func _adopt_hint(node: Node, player_index: int) -> void:
	if node is InputIcon:
		# The game leaves these on player 0 (the shop items' lock and ban keys).
		node.player_index = player_index
		node._change_controller()
	elif node is CoopShopHint:
		# The setter reloads the glyph. CoopItemPopup._set_player_index skips its steal hint,
		# which would show player 0's device.
		node.player_index = player_index


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
