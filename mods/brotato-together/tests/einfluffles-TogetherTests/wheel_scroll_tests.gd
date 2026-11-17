extends Reference
# Scrolling online (ui/wheel_scroll.gd, sync/local_panel.gd, sync/input_sync.gd, menu sync):
#  - the mouse wheel scrolls what is under the pointer in the mouse player's own panel and nothing
#    of another player: on the host (its keyboard player) in the shop, the level-up panels and
#    character selection; on a client in its own shop and level-up panel and on its copy of the
#    host's character selection;
#  - character selection: a player's right stick scrolls their own panel's description on the
#    host (and the host's state carries where each one is), on a client's copy the own player's
#    stick scrolls its own panel there, and the other panels follow the host's positions.
# The descriptions are made taller than their box here, so the checks need no particular item.
# Called from the shop, level-up and selection tests while their screen is up; checks go
# through the test mod's _check.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const KEYBOARD := 7  # CoopService.KEYBOARD_REMAPPED_DEVICE_ID
const TALLER := 600.0

var _t: Node = null
var _tall := []  # [control, its rect_min_size before]


func _init(test_mod: Node) -> void:
	_t = test_mod


# Host: player p is this machine's keyboard and mouse player now. Returns the players to restore.
static func as_keyboard_player(p: int) -> Array:
	var saved: Array = CoopService.connected_players.duplicate(true)
	CoopService.connected_players[p] = [KEYBOARD, CoopService.PlayerType.KEYBOARD_AND_MOUSE]
	return saved


# label names the screen. own: the mouse player's panel, other: another player's.
func check_wheel(label: String, own: Control, other: Control):
	yield(_frames(1), "completed")  # a coroutine also when it returns early
	var own_scroll := largest_scroll(own)
	var other_scroll := largest_scroll(other)
	if own_scroll == null:
		_t._check(
			false,
			"%s: the own panel has a ScrollContainer showing (%s)" % [label, _shown_scrolls(own)]
		)
		return
	make_tall(own_scroll)
	if other_scroll != null:
		make_tall(other_scroll)
	yield(_frames(2), "completed")
	reset(own)
	reset(other)
	yield(wheel(own_scroll), "completed")
	var own_total := total(own)
	_t._check(own_total > 0 and total(other) == 0, "%s: the wheel scrolls the own panel" % label)
	if other_scroll == null:
		print("  info: %s: the other panel shows nothing to scroll here" % label)
	else:
		yield(wheel(other_scroll), "completed")
		_t._check(
			total(other) == 0 and total(own) == own_total,
			"%s: the wheel over another player's panel scrolls nothing" % label
		)
	restore()
	reset(own)
	reset(other)
	yield(_frames(1), "completed")


# name: size of each ScrollContainer in root, for a failure message.
static func _shown_scrolls(root: Node) -> Array:
	var shown := []
	if root is ScrollContainer:
		shown.append("%s %s %s" % [root.name, root.is_visible_in_tree(), root.rect_size])
	for child in root.get_children():
		shown += _shown_scrolls(child)
	return shown


# Its content taller than the box, until restore().
func make_tall(scroll: ScrollContainer) -> void:
	for child in scroll.get_children():
		if child is Control:
			_tall.append([child, child.rect_min_size])
			child.rect_min_size.y = scroll.rect_size.y + TALLER
			return


func restore() -> void:
	for entry in _tall:
		if is_instance_valid(entry[0]):
			entry[0].rect_min_size = entry[1]
	_tall = []


# The biggest ScrollContainer showing in root that has no other one showing inside.
static func largest_scroll(root: Node) -> ScrollContainer:
	var found := []
	_leaves(root, found)
	var best: ScrollContainer = null
	for scroll in found:
		if best == null or scroll.rect_size.x * scroll.rect_size.y > best.rect_size.x * best.rect_size.y:
			best = scroll
	return best


static func _leaves(node: Node, found: Array) -> bool:
	if node is CanvasItem and not node.visible:
		return false
	var inner := false
	for child in node.get_children():
		inner = _leaves(child, found) or inner
	var leaf: bool = (
		node is ScrollContainer and node.scroll_vertical_enabled and node.rect_size.y > 20.0
	)
	if leaf and not inner:
		found.append(node)
	return inner or leaf


# Sum of how far every ScrollContainer in root is scrolled.
static func total(root: Node) -> int:
	var sum: int = root.scroll_vertical if root is ScrollContainer else 0
	for child in root.get_children():
		sum += total(child)
	return sum


static func reset(root: Node) -> void:
	if root is ScrollContainer:
		root.scroll_vertical = 0
	for child in root.get_children():
		reset(child)


# One wheel step down with the pointer in the middle of control, in window coordinates.
func wheel(control: Control):
	var canvas_pos: Vector2 = control.get_global_transform_with_canvas().xform(
		control.rect_size / 2.0
	)
	var pos: Vector2 = control.get_viewport().get_final_transform().xform(canvas_pos)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = BUTTON_WHEEL_DOWN
		event.pressed = pressed
		event.factor = 1.0
		event.position = pos
		event.global_position = pos
		Input.parse_input_event(event)
		yield(_t.get_tree(), "idle_frame")
	yield(_frames(2), "completed")


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")


# --- character selection ---


# Host: two remote players (virtual devices 12, 13) and the keyboard player 2 of this machine,
# every cursor on a character (else a panel shows the random element, without a description).
func host_selection(scene: Node, capture: FuncRef):
	var panels: Array = scene._get_panels()
	var grid: Node = scene._get_inventories()[0]
	for p in 3:
		Utils.get_focus_emulator(p, scene).focused_control = grid.get_child(1 + p)
	yield(_frames(2), "completed")
	yield(check_wheel("character selection, host", panels[2], panels[0]), "completed")
	# The right stick of remote player 2 (P2's virtual device) scrolls its own panel only.
	var scrolls := [panels[0].get_description_scroll(), panels[1].get_description_scroll()]
	for scroll in scrolls:
		make_tall(scroll)
	yield(_frames(2), "completed")
	for scroll in scrolls:
		scroll.scroll_vertical = 0
	var device: int = CoopService.get_remapped_player_device(1)
	var down := VirtualDevices.action("rjoy_down", device)
	VirtualDevices.set_axis_pair(VirtualDevices.action("rjoy_up", device), down, 1.0)
	yield(_frames(10), "completed")
	VirtualDevices.set_axis_pair(VirtualDevices.action("rjoy_up", device), down, 0.0)
	_t._check(
		scrolls[1].scroll_vertical > 0 and scrolls[0].scroll_vertical == 0,
		"stick, host: P2's right stick scrolls P2's description only"
	)
	var state: Dictionary = capture.call_func(scene, 1)
	var sent = state.get("scrolls")
	_t._check(
		sent is Array and sent.size() == 3 and sent[1] == scrolls[1].scroll_vertical and sent[0] == 0,
		"stick, host: the menu state carries each panel's scroll position (%s)" % [sent]
	)
	restore()
	for scroll in scrolls:
		scroll.scroll_vertical = 0
	yield(_frames(1), "completed")


# Client: its copy of the host's screen, this machine's player is P2 (you = 1).
func client_selection(scene: Node, menus: Node, input_sync: Node, state: Dictionary):
	var panels: Array = scene._get_panels()
	var grid: Node = scene._get_inventories()[0]
	for p in 2:
		Utils.get_focus_emulator(p, scene).focused_control = grid.get_child(1 + p)
	yield(_frames(2), "completed")
	yield(check_wheel("character selection, client", panels[1], panels[0]), "completed")
	var scrolls := [panels[0].get_description_scroll(), panels[1].get_description_scroll()]
	for scroll in scrolls:
		make_tall(scroll)
	yield(_frames(2), "completed")
	for scroll in scrolls:
		scroll.scroll_vertical = 0
	# The own right stick: sampled for the host each tick, and it drives the own slot here.
	Input.action_press("rjoy_down")
	for _i in 10:
		input_sync.sample_local()
		yield(_t.get_tree(), "idle_frame")
	Input.action_release("rjoy_down")
	input_sync.sample_local()
	yield(_frames(2), "completed")
	var own_scrolled: int = scrolls[1].scroll_vertical
	_t._check(
		own_scrolled > 0 and scrolls[0].scroll_vertical == 0,
		"stick, client: the own right stick scrolls the own panel on the copy"
	)
	_t._check(
		Utils.get_player_rjoy_vector(1) == Vector2.ZERO,
		"stick, client: and lets go with the stick"
	)
	# The host scrolled P1's description to 120: the copy follows; the own one stays local.
	var scrolled: Dictionary = state.duplicate(true)
	scrolled["scrolls"] = [120, 0]
	_t._check(menus.show(scrolled), "stick, client: the host's state with scroll positions")
	yield(_t.get_tree().create_timer(0.5), "timeout")  # at the stick's speed
	_t._check(
		scrolls[0].scroll_vertical == 120 and scrolls[1].scroll_vertical == own_scrolled,
		"stick, client: another panel follows the host's position, the own one stays (%s, %s)"
		% [scrolls[0].scroll_vertical, scrolls[1].scroll_vertical]
	)
	restore()
	for scroll in scrolls:
		scroll.scroll_vertical = 0
	yield(_frames(1), "completed")
