extends Reference
# Two fixes of the game's own shop around the weapons row, for the co-op and the solo shop alike
# (extensions/ui/coop_shop.gd, extensions/ui/shop.gd). The shop is told by what it can do, never
# by class: naming BaseShop in a script that loads with the mod loads base_shop.gd too early and
# the game's shop scripts no longer parse (ui/damage_views.gd).
# - Anvil (effect upgrade_random_weapon): BaseShop._ready upgrades a weapon with _combine_weapon
#   before it fills the gear rows (set_weapons_data). The game's combine then finds no element to
#   remove ("combine: no inventory element for ..., the weapons row is out of sync"), adds one for
#   the new weapon to the still empty row and defers a grab_focus on it; set_weapons_data frees
#   that element before the deferred call runs ("grab_focus: Condition "!is_inside_tree()" is
#   true"). The rows are right in the end (built from RunData), but the game works on a control
#   that is being freed. While the shop applies its own effects (RunData.shop_effects_checked is
#   false only then: _ready sets it right after that block) only the run changes, as the game's
#   combine changes it; the rows are built from RunData right after. A client's copy of the shop
#   enters with the flag set (sync/shop_sync.gd): the host's Anvil arrives in its run state.
# - "WEAPONS (n/m)": the game computes the label only when the weapons row changes
#   (PlayerGearContainer._on_weapons_changed), so an item that adds a weapon slot (Cybernetic Arm)
#   kept the old m until the next shop. It is computed again with every stats update of the shop
#   (BaseShop._update_stats: a purchase, a combine, a trade, a client's state from the host).


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
