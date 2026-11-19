extends Reference
# Scrolling online (ui/wheel_scroll.gd, sync/scroll_sync.gd): wheel and right stick scroll the own
# panel only; positions are mirrored. The descriptions are made taller than their box, so the
# checks need no particular item.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const ScrollSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/scroll_sync.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
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


# own: the panel of this machine's player p_own; other: the panel of player p_other (a remote
# player on the host, another player on a client).
func check_sync(
	label: String, scroller: Node, scene: Node, own: Control, other: Control, players: Array
):
	yield(_frames(1), "completed")
	var p_own: int = players[0]
	var p_other: int = players[1]
	var selection := ScrollSync.is_selection(scene)
	var own_scroll := largest_scroll(own)
	var other_scroll := largest_scroll(other)
	if own_scroll == null or other_scroll == null:
		_t._check(false, "%s: both panels have a ScrollContainer showing" % label)
		return
	make_tall(own_scroll)
	make_tall(other_scroll)
	yield(_frames(2), "completed")
	reset(own)
	reset(other)
	own_scroll.scroll_vertical = 70
	var own_target := ScrollSync._describe(own_scroll, scene, p_own, own)
	var other_target := ScrollSync._describe(other_scroll, scene, p_other, other)
	_t._check(
		ScrollSync.resolve(scene, p_own, own_target) == own_scroll
		and ScrollSync.resolve(scene, p_other, other_target) == other_scroll,
		"%s: a panel's scroll named by meaning (%s, %s)" % [label, own_target, other_target]
	)
	# The selection screens name it relative to the player's panel: never another panel either.
	var inside: bool = selection or ScrollSync.resolve(scene, p_other, own_target) == null
	_t._check(inside, "%s: another player's scroll is not in a player's own panel" % label)
	var sent: Array = []
	if Puppet.is_active():
		var body: Dictionary = bytes2var(var2bytes(scroller.own_body()), false)
		sent = body.get("scrolls", [])
		_t._check(
			body.get("scene") == scene.filename and [own_target, 70] in sent,
			"%s: PANEL_SCROLL carries the own panel's position (%s)" % [label, sent]
		)
		var state := {
			"scene": scene.filename,
			"players": [[p_own, [[own_target, 210]]], [p_other, [[other_target, 140]]]],
		}
		_t._check(
			scroller.apply_state(StateStream.SCROLLS, bytes2var(var2bytes(state), false), 1),
			"%s: the host's scroll state applied" % label
		)
	else:
		_t._check(scroller.state_key(StateStream.SCROLLS) != "", "%s: the scroll state is on" % label)
		var body: Dictionary = scroller.state_body(StateStream.SCROLLS)
		for entry in body.get("players", []):
			if entry[0] == p_own:
				sent = entry[1]
		_t._check(
			body.get("scene") == scene.filename and [own_target, 70] in sent,
			"%s: the scroll state carries the own panel's position (%s)" % [label, sent]
		)
		var wrong := {"scene": "res://elsewhere.tscn", "scrolls": [[other_target, 300]]}
		var ignored: bool = not scroller.host_apply(p_other, wrong)
		_t._check(ignored, "%s: another scene's scrolls ignored" % label)
		var message := {"scene": scene.filename, "scrolls": [[other_target, 140]]}
		if not selection:
			message.scrolls.append([own_target, 210])
		_t._check(
			scroller.host_apply(p_other, bytes2var(var2bytes(message), false)),
			"%s: a client's PANEL_SCROLL applied" % label
		)
	yield(_t.get_tree().create_timer(0.5), "timeout")
	_t._check(
		other_scroll.scroll_vertical == 140 and own_scroll.scroll_vertical == 70,
		"%s: the other panel follows (140), the own one stays (%s, %s)"
		% [label, other_scroll.scroll_vertical, own_scroll.scroll_vertical]
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


# Host: two remote players P1 and P2 (virtual devices 12, 13) and this machine's keyboard player
# P3, every cursor on a character (else a panel shows the random element, without a description).
func host_selection(scene: Node, scroller: Node):
	var panels: Array = scene._get_panels()
	var grid: Node = scene._get_inventories()[0]
	for p in 3:
		Utils.get_focus_emulator(p, scene).focused_control = grid.get_child(1 + p)
	yield(_frames(2), "completed")
	yield(check_wheel("character selection, host", panels[2], panels[0]), "completed")
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
	restore()
	for scroll in scrolls:
		scroll.scroll_vertical = 0
	# P3 (the keyboard player) is this machine's, P2 a client's.
	var label := "character selection, host"
	yield(check_sync(label, scroller, scene, panels[2], panels[1], [2, 1]), "completed")


# Client: its copy of the host's screen; this machine's player is P2 (you = 1).
func client_selection(scene: Node, input_sync: Node, scroller: Node):
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
	restore()
	for scroll in scrolls:
		scroll.scroll_vertical = 0
	var label := "character selection, client"
	yield(check_sync(label, scroller, scene, panels[1], panels[0], [1, 0]), "completed")
