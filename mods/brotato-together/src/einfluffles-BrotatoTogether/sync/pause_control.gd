extends Node
# Who may pause, and who operates the pause menu.
# Host: any player can pause (the game opens PauseMenu for the player who pressed pause). When
#   that is a remote player, the menu goes to the host's first local player (the game's own
#   "change pause ownership" steps from PauseMenu.on_game_lost_focus): the remote player can't
#   see the menu, and must not quit or restart the run blind. The remote player who paused can
#   resume with pause again (while the menu shows its main page). Clients learn who paused
#   (BATTLE_PAUSE via BattleHost, SHOP_PAUSE from here).
# Client: puppet scenes never pause locally (focus loss, pad disconnect, pause button).

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const SHOP_SCENE := "res://ui/menus/shop/coop_shop.tscn"
const REMOTE_PRESS_WINDOW_MSEC := 1000  # a remote pause press this recent caused the pause

var session: Node = null
var input_sync: Node = null

# host
var _menu: Node = null  # PauseMenu that is open
var _pauser_device := -1  # virtual device that paused (-1: the host or nobody)
var _paused_frame := -1  # the shop pauses on the release event that is still propagating
var _last_shop_pause := []

# client
var _shop_banner: CanvasLayer = null
var _shop: Node = null


func setup(netplay_session: Node, remote_input: Node) -> void:
	session = netplay_session
	input_sync = remote_input
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	get_tree().connect("node_added", self, "_on_node_added")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


# Client: called when a puppet battle / shop scene is ready.
static func disable_local_pause(scene: Node) -> void:
	var menu = scene.get("_pause_menu")
	if menu != null:
		menu.enabled = false
	if InputService.is_connected("game_lost_focus", scene, "_on_game_lost_focus"):
		InputService.disconnect("game_lost_focus", scene, "_on_game_lost_focus")


static func banner_text(by: String, by_id: int, local_id: int) -> String:
	if by_id != 0 and by_id == local_id:
		return "Paused by you · press pause to resume"
	return "Paused by %s" % (by if by != "" else "the host")


static func make_banner(parent: Node) -> CanvasLayer:
	var banner := CanvasLayer.new()
	banner.layer = 100
	var label := Label.new()
	label.name = "Label"
	label.align = Label.ALIGN_CENTER
	label.valign = Label.VALIGN_CENTER
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	banner.add_child(label)
	parent.add_child(banner)
	return banner


# --- host ---


# [name, steam id] of whoever paused; ["", 0] for the host.
func paused_by() -> Array:
	if _pauser_device < 0:
		return ["", 0]
	for steam_id in input_sync.devices:
		if input_sync.devices[steam_id] == _pauser_device:
			var peer = session.peers.get(steam_id)
			return [peer.name if peer != null else "a player", steam_id]
	return ["a player", 0]


func _on_node_added(node: Node) -> void:
	if node is PauseMenu:
		node.connect("paused", self, "_on_menu_paused", [node])
		node.connect("unpaused", self, "_on_menu_unpaused")


func _on_menu_paused(menu: Node) -> void:
	if session.is_host():
		handle_pause(menu)


func _on_menu_unpaused() -> void:
	_menu = null
	_pauser_device = -1


# PauseMenu.pause() emits "paused" before it sets the menu up for the pausing player, so the
# hand-over runs deferred.
func handle_pause(menu: Node) -> void:
	_menu = menu
	_pauser_device = -1
	_paused_frame = Engine.get_idle_frames()
	var device: int = CoopService.get_remapped_player_device(menu._player_index)
	if not VirtualDevices.is_virtual(device):
		return
	# Player 0 can be remote: focus loss on the host always opens the menu for player 0.
	var pressed_at: int = input_sync.last_pause_msec(device)
	if pressed_at >= 0 and OS.get_ticks_msec() - pressed_at < REMOTE_PRESS_WINDOW_MSEC:
		_pauser_device = device
	var owner: int = local_player_index()
	if owner >= 0:
		call_deferred("_give_menu_to", menu, owner)


static func local_player_index() -> int:
	for i in CoopService.connected_players.size():
		if not VirtualDevices.is_virtual(CoopService.connected_players[i][0]):
			return i
	return -1


func _give_menu_to(menu: Node, owner: int) -> void:
	if not is_instance_valid(menu) or not get_tree().paused:
		return
	menu._player_index = owner
	menu._focus_emulator.player_index = owner
	menu._menus.reset()
	menu._main_menu.init(owner)


# The remote player who paused resumes with its pause button (released, like the game).
func _input(event: InputEvent) -> void:
	if _pauser_device < 0 or not (event is InputEventAction) or event.pressed:
		return
	if event.action != VirtualDevices.action("ui_pause", _pauser_device):
		return
	if not is_instance_valid(_menu) or not get_tree().paused:
		return
	if Engine.get_idle_frames() == _paused_frame:
		return
	get_tree().set_input_as_handled()
	if _menu._main_menu.visible and not _menu.codex_is_opened:
		_menu.unpause()


func _process(_delta: float) -> void:
	if not session.is_host():
		_last_shop_pause = []
		return
	var scene := get_tree().current_scene
	if scene == null or scene.filename != SHOP_SCENE:
		_last_shop_pause = []
		return
	var state := _shop_pause_state()
	if state != _last_shop_pause:
		_last_shop_pause = state
		session.broadcast_reliable(Protocol.Msg.SHOP_PAUSE, state)


func _shop_pause_state() -> Array:
	var by := paused_by()
	return [get_tree().paused, by[0], by[1]]


func _on_peer_ready(steam_id: int) -> void:
	if session.is_host() and not _last_shop_pause.empty():
		session.send_reliable(steam_id, Protocol.Msg.SHOP_PAUSE, _last_shop_pause)


# --- client ---


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.SHOP_PAUSE or not session.is_client():
		return
	if steam_id != session.transport.host_id or typeof(body) != TYPE_ARRAY or body.size() != 3:
		return
	if typeof(body[1]) != TYPE_STRING or typeof(body[2]) != TYPE_INT:
		return
	var scene := get_tree().current_scene
	if scene == null or scene.filename != SHOP_SCENE:
		return
	show_shop_pause(scene, bool(body[0]), banner_text(body[1], body[2], session.transport.local_id))


func show_shop_pause(shop: Node, paused: bool, text: String) -> void:
	if shop != _shop or not is_instance_valid(_shop_banner):
		_shop = shop
		_shop_banner = make_banner(shop)
	_shop_banner.get_node("Label").text = text
	_shop_banner.visible = paused
