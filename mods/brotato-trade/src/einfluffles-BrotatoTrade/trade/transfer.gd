extends Reference
# The hand-over itself, on the game that owns the run (never on a brotato:together client).
# One call, nothing deferred: everything is checked first (trade/rules.gd), then the object
# leaves the giver's list and enters the receiver's before give() returns, so no frame, save
# or network state ever sees it in both lists or in none. Each of the two steps is counted
# before the next: if the object did not leave the giver nothing else happens, and if it did
# not reach the receiver the giver gets it back.
# Counted, not looked up: the shop hands out ItemService's own item objects, so the same
# object can sit in a list several times and in several players' lists.
#
# The game's own functions do the work, so stats, sets, caches and other mods follow:
# - item: RunData.remove_item (without its replaced_by: the giver gets no "broken" leftover)
#   and RunData.add_item, the same object. Plain add: no stat-gain triggers, no mutation on
#   equip, no duplication (those belong to buying; giving back and forth would farm them).
# - weapon: RunData.remove_weapon_by_index and RunData.add_weapon (which copies, as for every
#   weapon it adds), then RunData.combine_weapon when the receiver had no slot.

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")
const LOG_NAME := "einfluffles-BrotatoTrade:Transfer"


# {} when nothing was given, else: weapon (bool), received (the receiver's object), combined
# (bool: merged into one of the receiver's weapons).
static func give(item, from: int, to: int) -> Dictionary:
	if not Rules.can_trade(item, from, to):
		return {}
	if Rules.is_weapon(item):
		return _give_weapon(item, from, to)
	return _give_item(item, from, to)


static func _give_item(item, from: int, to: int) -> Dictionary:
	var giver: Array = RunData.get_player_items_ref(from)
	var receiver: Array = RunData.get_player_items_ref(to)
	var had := [giver.count(item), receiver.count(item)]
	# RunData.remove_item_displayed drops the item's looks even when another copy stays.
	var looks: Array = RunData.players_data[from].appearances.duplicate()
	RunData.remove_item(item, from, false, false)
	if giver.count(item) != had[0] - 1:
		ModLoaderLog.error("%s did not leave player %d" % [item.my_id, from], LOG_NAME)
		return {}
	if RunData.get_nb_item(item.my_id_hash, from) > 0:
		RunData.players_data[from].appearances = looks
	RunData.add_item(item, to)
	if receiver.count(item) != had[1] + 1:
		ModLoaderLog.error("%s did not reach player %d: given back" % [item.my_id, to], LOG_NAME)
		RunData.add_item(item, from)
		return {}
	return {"weapon": false, "received": item, "combined": false}


static func _give_weapon(weapon, from: int, to: int) -> Dictionary:
	var giver: Array = RunData.get_player_weapons_ref(from)
	var receiver: Array = RunData.get_player_weapons_ref(to)
	var sizes := [giver.size(), receiver.size()]
	var plan: int = Rules.weapon_plan(weapon, to)
	var partner = Rules.combine_partner(weapon, to) if plan == Rules.COMBINE else null

	var tracked: int = RunData.remove_weapon_by_index(giver.find(weapon), from)
	if giver.has(weapon) or giver.size() != sizes[0] - 1:
		ModLoaderLog.error("%s did not leave player %d" % [weapon.my_id, from], LOG_NAME)
		return {}
	var received = RunData.add_weapon(weapon, to)
	if received == null or not receiver.has(received) or receiver.size() != sizes[1] + 1:
		ModLoaderLog.error("%s did not reach player %d: given back" % [weapon.my_id, to], LOG_NAME)
		RunData.add_weapon(weapon, from)
		return {}
	received.tracked_value = tracked
	received.dmg_dealt_last_wave = weapon.dmg_dealt_last_wave

	if partner != null:
		# As when a bought weapon finds no slot (BaseShop.buy_weapon): two become the next tier.
		received = RunData.combine_weapon(received, partner, to)
		if receiver.size() != sizes[1]:
			ModLoaderLog.error("weapon count is off after combining %s" % weapon.my_id, LOG_NAME)
	return {"weapon": true, "received": received, "combined": partner != null}
