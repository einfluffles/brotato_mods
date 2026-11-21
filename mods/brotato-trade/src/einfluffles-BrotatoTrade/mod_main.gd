extends Node
# brotato:trade: give items and weapons to other players in the co-op shop, and crate items on
# the end-of-wave crate panels. The trade key (trade/hotkey.gd) is rebindable in the mod config.

const MOD_ID := "einfluffles-BrotatoTrade"
const MOD_DIR := "res://mods-unpacked/einfluffles-BrotatoTrade/"
const LOG_NAME := MOD_ID + ":Main"
const EXTENSIONS := [
	"extensions/ui/coop_item_popup.gd",
	"extensions/ui/coop_shop.gd",
	"extensions/ui/coop_upgrades_ui_player_container.gd",
	"extensions/ui/upgrades_ui.gd",
	"extensions/singletons/input_service.gd",
]


func _init() -> void:
	for extension in EXTENSIONS:
		ModLoaderMod.install_script_extension(MOD_DIR + extension)
	ModLoaderLog.info("Init", LOG_NAME)


func _ready() -> void:
	# Also here: InputService may have copied its actions before the extension was in place.
	load(MOD_DIR + "trade/hotkey.gd").register_all()
	ModLoader.connect("current_config_changed", self, "_on_config_changed")
	# Once every mod is ready: brotato:together builds its shop sync in its own _ready.
	call_deferred("_link_together")


# Loaded here, not preloaded: the script names game classes, which must not be compiled
# before every mod's script extensions are installed.
func _link_together() -> void:
	load(MOD_DIR + "trade/together.gd").register(self)


# A config chosen while the game runs (a mod that edits Mod Loader configs).
func _on_config_changed(config) -> void:
	if config != null and config.mod_id == MOD_ID:
		load(MOD_DIR + "trade/hotkey.gd").register_all()


# The handlers trade/together.gd registers: brotato:together calls them on the host for a remote
# player's intent.
func on_remote_weapon(shop: Node, player: int, slot: int, id: String, to: int) -> bool:
	return _remote(shop, true, player, slot, id, to)


func on_remote_item(shop: Node, player: int, slot: int, id: String, to: int) -> bool:
	return _remote(shop, false, player, slot, id, to)


func on_remote_crate(ui: Node, player: int, id: String, to: int) -> bool:
	if not is_instance_valid(ui) or not ui.has_method("trade_crate_apply_request"):
		return false
	return ui.trade_crate_apply_request(player, id, to)


func _remote(shop: Node, weapon: bool, from: int, slot: int, id: String, to: int) -> bool:
	if not is_instance_valid(shop) or not shop.has_method("trade_apply_request"):
		return false
	return shop.trade_apply_request(weapon, from, slot, id, to)


func on_remote_buy(shop: Node, player: int, slot: int, id: String, to: int) -> bool:
	if not is_instance_valid(shop) or not shop.has_method("trade_buy_apply_request"):
		return false
	return shop.trade_buy_apply_request(player, slot, id, to)
