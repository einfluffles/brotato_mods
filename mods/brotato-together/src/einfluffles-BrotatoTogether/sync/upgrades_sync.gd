extends Node
# Mirrors the end-of-wave level-up / crate panels (main.tscn's coop UpgradesUI).
# Host: while the panels are visible, send UPGRADES_STATE on change: run state + per player
#   ["none"] | ["done"] | ["upgrades", [upgrade ids], level, reroll_price] | ["item", json, id]
# Client: drive its own (puppet) panels with exactly those options — nothing is rolled locally.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const CHECK_INTERVAL := 0.1

var session: Node = null
var battle_host: Node = null
var battle_client: Node = null

var _last_sent_key := ""
var _check_left := 0.0
var _pending := {}  # client: state that arrived while the battle scene was still loading


func setup(netplay_session: Node, host_battle: Node, client_battle: Node) -> void:
	session = netplay_session
	battle_host = host_battle
	battle_client = client_battle
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	battle_client.connect("battle_entered", self, "_on_battle_entered")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


# --- host ---


func _process(delta: float) -> void:
	if not session.is_host() or not battle_host.is_in_battle():
		_last_sent_key = ""
		return
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = CHECK_INTERVAL
	var ui = battle_host._main.get("_coop_upgrades_ui")
	if ui == null or not ui.visible:
		return
	var players := capture(ui)
	var key := var2str(players) + str(RunData.get_player_gold(0))
	if key == _last_sent_key:
		return
	_last_sent_key = key
	session.broadcast_reliable(Protocol.Msg.UPGRADES_STATE, body(players))


func body(players: Array) -> Dictionary:
	return {
		"battle_id": battle_host._battle_id,
		"visible": true,
		"run": RunStateCodec.encode(),
		"players": players,
	}


static func capture(ui: Node) -> Array:
	var players := []
	for p in RunData.get_player_count():
		var container = ui._get_player_container(p)
		if container._checkmark_group.visible:
			players.append(["done"])
		elif container._upgrades_container.visible:
			var ids := []
			for upgrade in container._old_upgrades:
				ids.append(upgrade.my_id)
			players.append(["upgrades", ids, container._level, container._reroll_price])
		elif container._items_container.visible and container._item_data != null:
			var item = container._item_data
			players.append(["item", JSON.print(item.serialize()), item.my_id])
		else:
			players.append(["none"])
	return players


# A (re)joining client needs the current panels too: force a resend.
func _on_peer_ready(_steam_id: int) -> void:
	_last_sent_key = ""


# --- client ---


func _on_battle_entered() -> void:
	if not _pending.empty() and _pending.get("battle_id") == battle_client._battle_id:
		apply(battle_client._main, _pending)
	_pending = {}


func _on_message(steam_id: int, msg_type: int, msg) -> void:
	if msg_type != Protocol.Msg.UPGRADES_STATE or not session.is_client():
		return
	if steam_id != session.transport.host_id or typeof(msg) != TYPE_DICTIONARY:
		return
	if msg.get("battle_id") != battle_client._battle_id:
		return
	if not battle_client.is_in_battle():
		_pending = msg  # BATTLE_START just arrived; the scene is still loading
		return
	apply(battle_client._main, msg)


func apply(main: Node, msg: Dictionary) -> void:
	if typeof(msg.get("players")) != TYPE_ARRAY:
		return
	var state := RunStateCodec.decode(msg.get("run"))
	if not state.empty():
		RunStateCodec.apply(state)
	var ui = main.get("_coop_upgrades_ui")
	if ui == null:
		return
	ui.show()
	for p in min(msg.players.size(), RunData.get_player_count()):
		var entry = msg.players[p]
		if typeof(entry) != TYPE_ARRAY or entry.empty() or typeof(entry[0]) != TYPE_STRING:
			continue
		var container = ui._get_player_container(p)
		container.update_inventory()
		container.update_stats()
		match entry[0]:
			"done":
				container.finish()
			"upgrades":
				if entry.size() == 4:
					_show_upgrades(container, p, entry[1], int(entry[2]), int(entry[3]))
			"item":
				if entry.size() == 3:
					_show_item(container, entry[1], entry[2])


# show_upgrades_for_level() without ItemService.get_upgrades (RNG): the host's options instead.
static func _show_upgrades(container, p: int, ids: Array, level: int, price: int) -> void:
	var upgrades := []
	for id in ids:
		var upgrade = _find(ItemService.upgrades, id)
		if upgrade != null:
			upgrades.append(upgrade)
	container._level = level
	container._old_upgrades = upgrades
	container._reroll_price = price
	container._reroll_button.init(price, p)
	var upgrade_uis: Array = container._get_upgrade_uis()
	for i in upgrade_uis.size():
		upgrade_uis[i].visible = i < upgrades.size()
		if upgrade_uis[i].visible:
			upgrade_uis[i].set_upgrade(upgrades[i], p)
	container._reroll_button.visible = upgrades.size() > 1
	container._update_gold_label()
	container._checkmark_group.hide()
	container._items_container.hide()
	container._upgrades_container.show()


# Crate items can be cursed/modified copies: rebuild from the base element + serialized changes.
static func _show_item(container, json: String, id: String) -> void:
	var parsed := JSON.parse(json)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return
	var base = _find(ItemService.items, id)
	if base == null:
		base = _find(ItemService.weapons, id)
	if base == null:
		return
	var item = base.duplicate()
	item.deserialize_and_merge(parsed.result)
	container._checkmark_group.hide()
	container.show_item(item)


static func _find(elements: Array, my_id: String):
	for element in elements:
		if element.my_id == my_id:
			return element
	return null
