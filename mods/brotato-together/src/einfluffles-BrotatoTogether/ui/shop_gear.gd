extends Reference
# Two fixes of the game's shop around the weapons row. The shop is told by what it can do, never
# by class: naming BaseShop here would load it at mod init (see mod_main.gd, _ready).
# - Anvil (upgrade_random_weapon): BaseShop._ready combines before the gear rows exist, then
#   defers a grab_focus on an element that set_weapons_data frees. While the shop applies its
#   own effects (RunData.shop_effects_checked is false) only the run changes; the rows build
#   from it right after.
# - "WEAPONS (n/m)": the game computes the label only when the weapons row changes, not when
#   an item adds a weapon slot.


# The run data part of BaseShop._combine_weapon for an upgrade (no partner), with its sound.
static func upgrade_at_entry(shop: Node, weapon, player_index: int) -> void:
	var new_weapon = RunData.combine_weapon(weapon, null, player_index)
	new_weapon.dmg_dealt_last_wave = weapon.dmg_dealt_last_wave
	SoundManager.play(Utils.get_rand_element(shop.combine_sounds), 0, 0.1, true)


# player_index -1: every player's.
static func refresh_weapons_label(shop: Node, player_index: int) -> void:
	var players: Array = [player_index] if player_index >= 0 else range(RunData.get_player_count())
	for p in players:
		var gear = shop._get_gear_container(p)
		if gear != null and gear.is_inside_tree():
			gear._on_weapons_changed()
