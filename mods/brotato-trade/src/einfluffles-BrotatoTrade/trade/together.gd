extends Reference
# brotato:together, when it is loaded (optional). There the host owns the run and a client's
# shop is a copy that decides nothing: a client's trade leaves as a shop intent
# (ShopSync.register_intent / send_intent), the host checks and applies it like its own
# players' and its next state brings the result to everybody.
#   kind            slot                          id            arg
#   "trade.weapon"  index in the giver's weapons  weapon my_id  receiving player
#   "trade.item"    index in the giver's items    item my_id    receiving player
# The crate panels (level-up / crate, UpgradesSync) take a client's crate trade the same way:
#   "trade.crate"   -                             crate item my_id   receiving player
# Without brotato:together every shop is this game's own. With a version that has no intents
# for other mods a client cannot trade (it could only change its own copy); the host and an
# offline game still can.

const NODE_PATH := "/root/ModLoader/einfluffles-BrotatoTogether"
const KIND_WEAPON := "trade.weapon"
const KIND_ITEM := "trade.item"
const KIND_CRATE := "trade.crate"
const LOG_NAME := "einfluffles-BrotatoTrade:Together"


static func is_loaded() -> bool:
	return _node() != null


# Host side: handler gets on_remote_weapon / on_remote_item(shop, player, slot, id, arg) and
# on_remote_crate(ui, player, id, arg) -> bool.
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


# Without the panel revision: a second trade sent before the host's state with the first
# arrived carries the same revision and was dropped as stale. The host checks it all again.
static func _register(shop_sync: Object, kind: String, handler: Object, method: String) -> void:
	for info in shop_sync.get_method_list():
		if info.name == "register_intent" and info.args.size() > 3:
			shop_sync.register_intent(kind, handler, method, false)
			return
	shop_sync.register_intent(kind, handler, method)


# Whether player `from` can trade from its panel of this shop.
static func can_request(shop: Node, from: int) -> bool:
	if not is_loaded():
		return true
	var shop_sync = _shop_sync()
	if shop_sync == null:
		return not _is_client()
	if not shop_sync.is_puppet_shop(shop):
		return true
	# A client: only its own panel, and only when the host trades too.
	return (
		shop_sync.own_player() == from
		and shop_sync.host_handles(KIND_WEAPON)
		and shop_sync.host_handles(KIND_ITEM)
	)


# The shop is a client's copy of the host's: nothing may change the run here.
static func is_puppet(shop: Node) -> bool:
	var shop_sync = _shop_sync()
	if shop_sync == null:
		return _is_client()
	return shop_sync.is_puppet_shop(shop)


# A client's request to its host. False: not sent.
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


# Whether player `from` can trade the crate item its panel of these level-up panels shows.
static func can_request_crate(ui: Node, from: int) -> bool:
	if not is_loaded():
		return true
	var upgrades_sync = _upgrades_sync()
	if upgrades_sync == null:
		return not _is_client()
	if not upgrades_sync.is_puppet_ui(ui):
		return true
	return upgrades_sync.own_player() == from and upgrades_sync.host_handles(KIND_CRATE)


# The level-up panels are a client's copy of the host's: nothing may change the run here.
static func is_puppet_ui(ui: Node) -> bool:
	if not is_loaded():
		return false
	var upgrades_sync = _upgrades_sync()
	if upgrades_sync == null:
		return _is_client()
	return upgrades_sync.is_puppet_ui(ui)


# A client's crate trade to its host. False: not sent.
static func send_crate(ui: Node, from: int, id: String, to: int) -> bool:
	var upgrades_sync = _upgrades_sync()
	if upgrades_sync == null or not can_request_crate(ui, from):
		return false
	return upgrades_sync.send_intent(ui, from, KIND_CRATE, id, to)


static func _node() -> Node:
	var tree = Engine.get_main_loop()
	return tree.root.get_node_or_null(NODE_PATH) if tree is SceneTree else null


# In a session as a client (asked of a brotato:together without intents for other mods).
static func _is_client() -> bool:
	var together := _node()
	var session = together.get("session") if together != null else null
	if not session is Object or not session.has_method("is_client"):
		return false
	return session.is_client()


# brotato:together's UpgradesSync when it takes other mods' intents, else null.
static func _upgrades_sync():
	var together := _node()
	var upgrades_sync = together.get("upgrades_sync") if together != null else null
	if not upgrades_sync is Object or not is_instance_valid(upgrades_sync):
		return null
	return upgrades_sync if upgrades_sync.has_method("register_intent") else null


# brotato:together's ShopSync when it takes other mods' intents, else null.
static func _shop_sync():
	var together := _node()
	var shop_sync = together.get("shop_sync") if together != null else null
	if not shop_sync is Object or not is_instance_valid(shop_sync):
		return null
	return shop_sync if shop_sync.has_method("register_intent") else null
