extends Reference
# The level-up options the host's panels show, from their ids (static helpers of
# sync/upgrades_sync.gd). They are what ItemService.get_upgrades returns: elements of
# ItemService.upgrades, copied with scaled effects when the player has
# level_upgrades_modifications (Captain, Barnacle), or, while a character has weapon slots to
# gain (Baby), only ItemService.weapon_slot_upgrade_data, which is not in ItemService.upgrades.

const LOG_NAME := "einfluffles-BrotatoTogether:UpgradesSync"


# The option `id` as player p's panel on the host shows it, or null (logged) for an id unknown here.
static func resolve(id: String, p: int):
	for upgrade in ItemService.upgrades:
		if upgrade.my_id == id:
			return _scaled(upgrade, p)
	var slot_upgrade = ItemService.weapon_slot_upgrade_data
	if slot_upgrade != null and slot_upgrade.my_id == id:
		return slot_upgrade  # get_upgrades returns it as it is
	ModLoaderLog.warning(
		"Level-up option %s of player %d is unknown here: left out of the panel" % [id, p], LOG_NAME
	)
	return null


# ItemService.get_upgrade_data's copy for the player's level_upgrades_modifications (its RunData is
# the host's run state, applied before the panels).
static func _scaled(upgrade, p: int):
	var modifications = RunData.get_player_effect(Keys.level_upgrades_modifications_hash, p)
	if modifications == 0:
		return upgrade
	var copy = upgrade.duplicate()
	var effects := []
	for effect in upgrade.effects:
		var new_effect = effect.duplicate()
		new_effect.value = int(effect.value * (1.0 + modifications / 100.0))
		effects.push_back(new_effect)
	copy.effects = effects
	return copy
