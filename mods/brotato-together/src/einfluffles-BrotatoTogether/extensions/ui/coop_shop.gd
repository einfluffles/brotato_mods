extends "res://ui/menus/shop/coop_shop.gd"
# The game's shop with the two fixes of ui/shop_gear.gd.

const ShopGear := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/shop_gear.gd")


func _combine_weapon(weapon_data: WeaponData, player_index: int, is_upgrade: bool) -> void:
	if is_upgrade and not RunData.shop_effects_checked:
		ShopGear.upgrade_at_entry(self, weapon_data, player_index)
		return
	._combine_weapon(weapon_data, player_index, is_upgrade)


func _update_stats(player_index := -1) -> void:
	._update_stats(player_index)
	ShopGear.refresh_weapons_label(self, player_index)
