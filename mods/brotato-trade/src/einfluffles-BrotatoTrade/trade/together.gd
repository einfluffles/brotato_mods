extends Reference
# brotato:together is optional. With it the host owns the run: a client's trade leaves as an
# intent and the host applies it. The shop's intents (ShopSync):
#   kind            slot                          id            arg
#   "trade.buy"     index in the giver's offers   item my_id    receiving player
#   "trade.weapon"  index in the giver's weapons  weapon my_id  receiving player
#   "trade.item"    index in the giver's items    item my_id    receiving player
# The crate panels' intent (UpgradesSync) has no slot:
#   "trade.crate"   -                             crate item my_id   receiving player
# With a brotato:together that has no intents for other mods a client cannot trade; the host and
# an offline game still can.

const NODE_PATH := "/root/ModLoader/einfluffles-BrotatoTogether"
const KIND_BUY := "trade.buy"
const KIND_WEAPON := "trade.weapon"
const KIND_ITEM := "trade.item"
const KIND_CRATE := "trade.crate"
const LOG_NAME := "einfluffles-BrotatoTrade:Together"


static func is_loaded() -> bool:
	return _node() != null


# Host side: the handler gets on_remote_weapon / on_remote_item / on_remote_buy(shop, player,
# slot, id, arg) and on_remote_crate(ui, player, id, arg), each returning a bool.
static func register(handler: Object) -> void:
	if not is_loaded():
		return
	var upgrades_sync = _upgrades_sync()
	if upgrades_sync == null:
		ModLoaderLog.warning(
			"brotato:together is too old for crate trades online: only the host's own players can",
			LOG_NAME
		)
	else:
		upgrades_sync.register_intent(KIND_CRATE, handler, "on_remote_crate")
	var shop_sync = _shop_sync()
	if shop_sync == null:
		ModLoaderLog.warning(
			"brotato:together is too old for trading online: only the host's own players can",
			LOG_NAME
		)
		return
	_register(shop_sync, KIND_WEAPON, handler, "on_remote_weapon")
	_register(shop_sync, KIND_ITEM, handler, "on_remote_item")
	# A buy keeps the revision, like the game's own buy press.
	shop_sync.register_intent(KIND_BUY, handler, "on_remote_buy")


# Without the panel revision: a second trade sent before the host's state with the first
# arrives carries the same revision and would be dropped as stale. The host checks it all again.
static func _register(shop_sync: Object, kind: String, handler: Object, method: String) -> void:
	for info in shop_sync.get_method_list():
		if info.name == "register_intent" and info.args.size() > 3:
			shop_sync.register_intent(kind, handler, method, false)
			return
	shop_sync.register_intent(kind, handler, method)


static func can_request(shop: Node, from: int) -> bool:
	if not is_loaded():
		return true
	var shop_sync = _shop_sync()
	if shop_sync == null:
		return not _is_client()
	if not shop_sync.is_puppet_shop(shop):
		return true
	return (
		shop_sync.own_player() == from
		and shop_sync.host_handles(KIND_WEAPON)
		and shop_sync.host_handles(KIND_ITEM)
	)


static func can_request_buy(shop: Node, from: int) -> bool:
	if not is_loaded():
		return true
	var shop_sync = _shop_sync()
	if shop_sync == null:
		return not _is_client()
	if not shop_sync.is_puppet_shop(shop):
		return true
	return shop_sync.own_player() == from and shop_sync.host_handles(KIND_BUY)


static func send_buy(shop: Node, from: int, shop_item: Node, to: int) -> bool:
	var shop_sync = _shop_sync()
	if shop_sync == null or not can_request_buy(shop, from) or shop_item.item_data == null:
		return false
	var slot: int = shop._get_shop_items_container(from)._shop_items.find(shop_item)
	return shop_sync.send_intent(shop, from, KIND_BUY, slot, shop_item.item_data.my_id, to)


# The shop is a client's copy of the host's: nothing may change the run here.
static func is_puppet(shop: Node) -> bool:
	var shop_sync = _shop_sync()
	if shop_sync == null:
		return _is_client()
	return shop_sync.is_puppet_shop(shop)


static func send(shop: Node, from: int, item, to: int) -> bool:
	var shop_sync = _shop_sync()
	if shop_sync == null or not can_request(shop, from):
		return false
	var weapon: bool = item is WeaponData
	var owned: Array = (
		RunData.get_player_weapons_ref(from)
		if weapon
		else RunData.get_player_items_ref(from)
	)
	var kind := KIND_WEAPON if weapon else KIND_ITEM
	return shop_sync.send_intent(shop, from, kind, owned.find(item), item.my_id, to)


static func can_request_crate(ui: Node, from: int) -> bool:
	if not is_loaded():
		return true
	var upgrades_sync = _upgrades_sync()
	if upgrades_sync == null:
		return not _is_client()
	if not upgrades_sync.is_puppet_ui(ui):
		return true
	return upgrades_sync.own_player() == from and upgrades_sync.host_handles(KIND_CRATE)


static func is_puppet_ui(ui: Node) -> bool:
	if not is_loaded():
		return false
	var upgrades_sync = _upgrades_sync()
	if upgrades_sync == null:
		return _is_client()
	return upgrades_sync.is_puppet_ui(ui)


static func send_crate(ui: Node, from: int, id: String, to: int) -> bool:
	var upgrades_sync = _upgrades_sync()
	if upgrades_sync == null or not can_request_crate(ui, from):
		return false
	return upgrades_sync.send_intent(ui, from, KIND_CRATE, id, to)


static func _node() -> Node:
	var tree = Engine.get_main_loop()
	return tree.root.get_node_or_null(NODE_PATH) if tree is SceneTree else null


static func _is_client() -> bool:
	var together := _node()
	var session = together.get("session") if together != null else null
	if not session is Object or not session.has_method("is_client"):
		return false
	return session.is_client()


# null for a brotato:together that takes no intents from other mods (_shop_sync likewise).
static func _upgrades_sync():
	var together := _node()
	var upgrades_sync = together.get("upgrades_sync") if together != null else null
	if not upgrades_sync is Object or not is_instance_valid(upgrades_sync):
		return null
	return upgrades_sync if upgrades_sync.has_method("register_intent") else null


static func _shop_sync():
	var together := _node()
	var shop_sync = together.get("shop_sync") if together != null else null
	if not shop_sync is Object or not is_instance_valid(shop_sync):
		return null
	return shop_sync if shop_sync.has_method("register_intent") else null
