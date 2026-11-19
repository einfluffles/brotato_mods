extends Reference
# The hand-over, in one call with nothing deferred: no frame, save or network state sees the
# object in both lists or in none.

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")
const LOG_NAME := "einfluffles-BrotatoTrade:Transfer"


# {} when nothing was given, else {weapon, received (the receiver's object), combined}.
static func give(item, from: int, to: int, shop: Node = null) -> Dictionary:
	if not Rules.can_trade(item, from, to, shop):
		return {}
	if Rules.is_weapon(item):
		return _give_weapon(item, from, to)
	return _give_item(item, from, to)


static func _give_item(item, from: int, to: int) -> Dictionary:
	var giver: Array = RunData.get_player_items_ref(from)
	var receiver: Array = RunData.get_player_items_ref(to)
	# Counted, not looked up: the shop hands out ItemService's own item objects, so one object can
	# sit in a list several times and in several players' lists.
	var had := [giver.count(item), receiver.count(item)]
	# RunData.remove_item_displayed drops the item's looks even when another copy stays.
	var looks: Array = RunData.players_data[from].appearances.duplicate()
	# Without its replaced_by: the giver gets no "broken" leftover.
	RunData.remove_item(item, from, false, false)
	if giver.count(item) != had[0] - 1:
		ModLoaderLog.error("%s did not leave player %d" % [item.my_id, from], LOG_NAME)
		return {}
	if RunData.get_nb_item(item.my_id_hash, from) > 0:
		RunData.players_data[from].appearances = looks
	# Plain add_item: no stat-gain triggers, no mutation on equip, no duplication. Those belong to
	# buying, and giving back and forth would farm them.
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
	# RunData.add_weapon copies every weapon it adds: `received` is the receiver's own object.
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
