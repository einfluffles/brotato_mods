extends Reference
# Suite input_hints: every machine shows a player's key hints for the device that player really
# uses (sync/input_types.gd). Three players: the host's on a pad (slot 0), a keyboard client
# (REMOTE) and a pad client (OTHER). On the host the keyboard client's INPUT types its shop panel
# while its slot stays a gamepad for aim; on the pad client the section does. Switches redraw
# panels that are open.

const LocalAim := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/local_aim.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const REMOTE := 1
const OTHER := 2
const OTHER_PEER_OFFSET := 1  # OTHER's steam id: FAKE_PEER + this
const UPGRADES_PANEL := "res://ui/menus/ingame/coop_upgrades_ui_player_container.tscn"
const KEYBOARD := 0  # CoopService.PlayerType
const XBOX := 1
const PLAYSTATION := 2

var _t: Node
var _input: Node = null
var _types: Node = null
var _message := []  # the section as the host sends it to OTHER's client


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	_input = together.input_sync
	_types = together.input_types
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	var saved_devices: Dictionary = _input.devices.duplicate()
	var saved_gamepad: bool = InputService.using_gamepad
	RunData.set_player_count(3)
	RunData.add_character(ItemService.characters[2], 2)
	yield(_host_part(), "completed")
	yield(_client_part(together.state_stream), "completed")
	CoopService.bt_clear_input_types()
	together.state_stream._revs.erase(StateStream.INPUT_TYPES)
	InputService.using_gamepad = saved_gamepad
	_input.devices = saved_devices
	CoopService.connected_players = saved_players


func _host_part():
	var tree: SceneTree = _t.get_tree()
	var other_peer: int = _t.FAKE_PEER + OTHER_PEER_OFFSET
	CoopService.connected_players.clear()
	CoopService.connected_players.push_back([0, XBOX])
	CoopService.connected_players.push_back([_t.DEVICE, XBOX])
	CoopService.connected_players.push_back([_t.DEVICE + 1, XBOX])
	_input.devices[_t.FAKE_PEER] = _t.DEVICE
	_input.devices[other_peer] = _t.DEVICE + 1
	_input._remote.erase(_t.FAKE_PEER)
	_report(KEYBOARD)
	_t._check(
		CoopService.get_player_input_type(REMOTE) == KEYBOARD,
		"host: a keyboard client's hints are keyboard hints"
	)
	var body: Array = _client_input(KEYBOARD)
	body[2] = Vector2(0, -1)
	_input._apply_input(_t.FAKE_PEER, body)
	_t._check(
		(
			Utils.is_player_using_gamepad(REMOTE)
			and Utils.get_player_rjoy_vector(REMOTE).is_equal_approx(Vector2(0, -1))
		),
		"host: the keyboard client's slot still aims with the stick its client sends"
	)
	_t._check(
		CoopService.get_player_input_type(OTHER) == XBOX,
		"host: a client that sent no type keeps the gamepad hints"
	)

	tree.change_scene(RunData.get_shop_scene_path())
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var shop: Node = tree.current_scene
	_check_panel("host shop", shop, REMOTE, KEYBOARD)
	_check_panel("host shop", shop, OTHER, XBOX)
	_check_panel("host shop", shop, 0, XBOX)
	var upgrades: Node = load(UPGRADES_PANEL).instance()
	upgrades.player_index = REMOTE
	shop.add_child(upgrades)
	_t._check(
		_icons_of(upgrades, REMOTE, KEYBOARD),
		"host: a level-up panel's key icons are its own player's"
	)

	_report(XBOX)
	_check_panel("host shop, the client took a pad", shop, REMOTE, XBOX)
	_t._check(
		_icons_of(upgrades, REMOTE, XBOX), "host: an open level-up panel follows the switch too"
	)
	_report(KEYBOARD)
	_check_panel("host shop, back on the keyboard", shop, REMOTE, KEYBOARD)

	var section := StateStream.INPUT_TYPES
	var state: Dictionary = _types.state_body(section)
	_t._check(
		_types.state_key(section) != "" and state.types == [XBOX, KEYBOARD, XBOX],
		"host: section input_types carries every slot's type %s" % [state]
	)
	_t._check(
		_types.state_patch(section, other_peer).you == OTHER,
		"host: each client is told its own slot"
	)
	_message = bytes2var(var2bytes(_types.state_stream.message_for(section, other_peer)), false)
	upgrades.queue_free()
	_input.devices.erase(other_peer)
	_input.devices.erase(_t.FAKE_PEER)
	_input._remote.erase(_t.FAKE_PEER)
	CoopService.bt_clear_input_types()


func _client_part(state_stream: Node):
	var tree: SceneTree = _t.get_tree()
	VirtualDevices.fill_puppet_slots(3)
	state_stream.receive(_message)
	_t._check(
		(
			CoopService.bt_own_slot == OTHER
			and CoopService.get_player_input_type(REMOTE) == KEYBOARD
			and CoopService.get_player_input_type(0) == XBOX
			and Utils.is_player_using_gamepad(REMOTE)
		),
		"other client: the host's types reach the puppet slots"
	)
	tree.change_scene(RunData.get_shop_scene_path())
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var shop: Node = tree.current_scene
	_check_panel("other client's shop", shop, REMOTE, KEYBOARD)
	_check_panel("other client's shop", shop, 0, XBOX)

	var rev: int = _message[1]
	var types := [XBOX, PLAYSTATION, XBOX]
	state_stream.receive([StateStream.INPUT_TYPES, rev + 1, {"types": types, "you": OTHER}])
	_check_panel("other client's shop, the client took a pad", shop, REMOTE, PLAYSTATION)
	types = [XBOX, KEYBOARD, XBOX]
	state_stream.receive([StateStream.INPUT_TYPES, rev + 2, {"types": types, "you": OTHER}])
	_check_panel("other client's shop, back on the keyboard", shop, REMOTE, KEYBOARD)

	InputService.using_gamepad = false
	var own_keyboard: bool = CoopService.get_player_input_type(OTHER) == KEYBOARD
	InputService.using_gamepad = true
	_t._check(
		own_keyboard and CoopService.get_player_input_type(OTHER) == XBOX,
		"other client: its own slot shows the device used here"
	)
	state_stream.receive([StateStream.INPUT_TYPES, rev + 3, {"types": [XBOX, 9, 0], "you": 0}])
	_t._check(
		CoopService.get_player_input_type(REMOTE) == KEYBOARD,
		"other client: a body with a type out of range is ignored"
	)
	state_stream.receive([StateStream.INPUT_TYPES, rev + 4, null])
	_t._check(
		CoopService.get_player_input_type(REMOTE) == XBOX and CoopService.bt_own_slot == -1,
		"other client: the host's types go with the section"
	)


# What the client's InputSync sends with the type in use, applied on the host for REMOTE.
func _report(player_type: int) -> void:
	_input._apply_input(_t.FAKE_PEER, _client_input(player_type))


func _client_input(player_type: int) -> Array:
	InputService.using_gamepad = player_type != KEYBOARD
	var body: Array = _input.sample_local()
	_t._check(
		LocalAim.flags_type(body[5]) == player_type, "client: INPUT carries type %d" % player_type
	)
	return bytes2var(var2bytes(body), false)


func _check_panel(label: String, shop: Node, player_index: int, player_type: int) -> void:
	var panel: Node = shop._get_coop_player_container(player_index)
	var hint: Texture = panel._toggle_popup_hint._key_icon.texture
	var info: Texture = CoopService.get_input_type_key_texture("ui_info", player_type, 0)
	var triggers: bool = panel.carousel.are_trigger_buttons_active()
	_t._check(
		(
			hint == info
			and triggers == (player_type != KEYBOARD)
			and panel.carousel.arrow_right.disabled == triggers
			and _icons_of(panel, player_index, player_type)
		),
		(
			"%s: player %d's panel shows type %d (info key %s, triggers %s)"
			% [label, player_index, player_type, hint == info, triggers]
		)
	)


# Every key icon and hint inside panel (the shop items' lock and ban keys, the popups' hints) is
# player_index's and shows player_type; false when there is none.
func _icons_of(panel: Node, player_index: int, player_type: int) -> bool:
	var hints := []
	_collect_hints(panel, hints)
	for hint in hints:
		var icon: bool = "input_string" in hint  # an InputIcon, else a CoopShopHint
		var action: String = hint.input_string if icon else hint.ui_action
		var texture: Texture = hint.texture if icon else hint._key_icon.texture
		var expected = CoopService.get_input_type_key_texture(action, player_type, 0)
		if hint.player_index != player_index or texture != expected:
			print("  info: %s shows %s for %s" % [hint.get_path(), texture, action])
			return false
	return not hints.empty()


# By property, not class: naming InputIcon or CoopShopHint here would compile the game's hint
# scripts at test mod init, and two of them then fail to parse.
static func _collect_hints(node: Node, hints: Array) -> void:
	if node.get("input_string") or node.get("ui_action"):
		hints.append(node)
	for child in node.get_children():
		_collect_hints(child, hints)
