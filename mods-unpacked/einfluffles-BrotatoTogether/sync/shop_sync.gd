extends Node
# Co-op shop mirror.
# Host: while coop_shop.tscn runs, send SHOP_STATE (reliable) whenever the shop or run state
# changes: full run state incl. the shop's own save data (offered items, rerolls, steals) via
# RunStateCodec, plus per-slot layout and Go flags.
# Client: load the real shop through the game's resume path (RunData.resumed_from_state_in_shop),
# so it shows exactly the host's items without rolling; later states are applied in place.

signal shop_entered

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:ShopSync"
const SHOP_SCENE := "res://ui/menus/shop/coop_shop.tscn"
const CHECK_INTERVAL := 0.1

var session: Node = null

# host
var _host_shop: Node = null
var _shop_id := 0
var _last_sent_key := ""
var _check_left := 0.0

# client
var _client_shop: Node = null
var _client_shop_id := 0
var _pending := {}  # latest decoded state, applied once the shop scene is ready


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	get_tree().connect("node_added", self, "_on_node_added")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func is_in_shop() -> bool:
	return _client_shop != null and is_instance_valid(_client_shop)


# --- host ---


func _process(delta: float) -> void:
	if not session.is_host():
		return
	var scene := get_tree().current_scene
	if scene != null and scene.filename == SHOP_SCENE:
		if scene != _host_shop:
			_host_shop = scene
			_shop_id += 1
			_last_sent_key = ""
		_check_left -= delta
		if _check_left <= 0.0:
			_check_left = CHECK_INTERVAL
			_send_if_changed()
	else:
		_host_shop = null


func _shop_body() -> Dictionary:
	var shop := _host_shop
	var shop_args := [
		shop._shop_items,
		shop._reroll_count,
		shop._paid_reroll_count,
		shop._initial_free_rerolls,
		shop._free_rerolls,
		shop._item_steals,
	]
	var slots := []
	for p in RunData.get_player_count():
		var active := []
		var container = shop._get_shop_items_container(p)
		for i in container._shop_items.size():
			active.append(container.get_shop_item_node(i).active)
		slots.append(active)
	return {
		"shop_id": _shop_id,
		"run": RunStateCodec.encode(shop_args),
		"slots": slots,
		"go": shop._player_pressed_go_button.duplicate(),
	}


func _send_if_changed() -> void:
	var body := _shop_body()
	var key := str(body.run.data.hash()) + var2str(body.slots) + var2str(body.go)
	if key == _last_sent_key:
		return
	_last_sent_key = key
	session.broadcast_reliable(Protocol.Msg.SHOP_STATE, body)


func _on_peer_ready(steam_id: int) -> void:
	if session.is_host() and _host_shop != null and is_instance_valid(_host_shop):
		session.send_reliable(steam_id, Protocol.Msg.SHOP_STATE, _shop_body())


# --- client ---


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.SHOP_STATE or not session.is_client():
		return
	if steam_id != session.transport.host_id or typeof(body) != TYPE_DICTIONARY:
		return
	if typeof(body.get("shop_id")) != TYPE_INT or typeof(body.get("slots")) != TYPE_ARRAY:
		return
	if typeof(body.get("go")) != TYPE_ARRAY:
		return
	var state := RunStateCodec.decode(body.get("run"))
	if state.empty() or not state.get("has_run_state", false):
		ModLoaderLog.error("Invalid shop state", LOG_NAME)
		return
	_pending = {"state": state, "slots": body.slots, "go": body.go}
	if body.shop_id != _client_shop_id or not is_in_shop():
		_client_shop_id = body.shop_id
		_enter_shop(state)
	else:
		_apply_pending()


func _enter_shop(state: Dictionary) -> void:
	Puppet.set_active(true)
	_client_shop = null
	RunData.resume_from_state(state)
	# The game's "continue run in shop" path: BaseShop._ready takes items/rerolls from here.
	ProgressData.saved_run_state = state
	RunData.resumed_from_state_in_shop = true
	RunData.shop_effects_checked = true  # anvil/destroy effects already ran on the host
	CoopService.connected_players.clear()
	for i in RunData.get_player_count():
		CoopService.connected_players.push_back(
			[VirtualDevices.FIRST + i, CoopService.PlayerType.GAMEPAD_XBOX]
		)
	get_tree().paused = false
	if get_tree().change_scene(SHOP_SCENE) != OK:
		ModLoaderLog.error("Could not load the shop scene", LOG_NAME)


func _on_node_added(node: Node) -> void:
	if Puppet.is_active() and node.filename == SHOP_SCENE:
		node.connect("ready", self, "_on_shop_ready", [node], CONNECT_ONESHOT)


func _on_shop_ready(shop: Node) -> void:
	_client_shop = shop
	# Leaving the shop would roll curses on locked items locally; the host decides those.
	if shop.is_connected("tree_exited", shop, "_on_tree_exited"):
		shop.disconnect("tree_exited", shop, "_on_tree_exited")
	_apply_pending()
	emit_signal("shop_entered")


func _apply_pending() -> void:
	if _pending.empty() or not is_in_shop():
		return
	var shop := _client_shop
	var state: Dictionary = _pending.state
	RunData.resume_from_state(state)
	for p in RunData.get_player_count():
		_refresh_player(shop, state, p)
	shop._update_visual_locks()
	shop.update_go_next_button_text()
	_pending = {}


# The per-player part of BaseShop._ready, re-run with the host's values (no RNG anywhere).
func _refresh_player(shop: Node, state: Dictionary, p: int) -> void:
	var gear = shop._get_gear_container(p)
	gear.set_weapons_data(RunData.get_player_weapons(p))
	gear.set_items_data(RunData.get_player_items(p))
	shop._update_stats(p)
	shop._get_gold_label(p).update_value(RunData.get_player_gold(p))
	shop._refresh_currency_dependent_buttons(p)
	shop._refresh_meca_parts_ui(RunData.get_player_meca_parts(p), p)

	for key in ["reroll_count", "paid_reroll_count", "initial_free_rerolls", "free_rerolls"]:
		if state.get(key) is Array and p < state[key].size():
			shop.get("_" + key)[p] = int(state[key][p])
	shop._item_steals[p] = int(state.item_steals[p]) if p < state.item_steals.size() else 0
	var price: Array = ItemService.get_reroll_price(
		RunData.current_wave, shop._paid_reroll_count[p], p
	)
	shop._reroll_price[p] = price[0]
	shop._reroll_discount[p] = price[1]

	var items: Array = state.shop_items[p] if p < state.shop_items.size() else []
	shop._shop_items[p] = items
	var container = shop._get_shop_items_container(p)
	container.item_steals = shop._item_steals[p]
	container.unlock_all_shop_items_visually()
	var active: Array = _pending.slots[p] if p < _pending.slots.size() else []
	var next := 0
	for i in container._shop_items.size():
		var node = container.get_shop_item_node(i)
		var is_active: bool = active[i] if i < active.size() else next < items.size()
		if is_active and next < items.size():
			node.item_steals = shop._item_steals[p]
			node.set_shop_item(items[next][0], items[next][1])
			if not node.active:
				node.activate()
			next += 1
		elif node.active:
			node.deactivate()
	container.update_buttons_color()
	shop._refresh_bonus_free_reroll(p)

	var go: bool = _pending.go[p] if p < _pending.go.size() else false
	shop._player_pressed_go_button[p] = go
	shop._get_checkmark(p).visible = go


func _on_lobby_left() -> void:
	_client_shop = null
	_client_shop_id = 0
	_pending = {}
