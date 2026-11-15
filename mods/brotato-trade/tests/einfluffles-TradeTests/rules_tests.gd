extends Reference
# trade/rules.gd and trade/transfer.gd on a co-op run, without a screen: who can give what to
# whom, and that a hand-over moves exactly one object with its effects.

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")
const Transfer := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/transfer.gd")

var _t: Node = null


func run(t: Node):
	_t = t
	yield(t.get_tree(), "idle_frame")
	_items()
	_limits()
	_shared_objects()
	_bound_items()
	_weapons()
	_combine()
	_weapon_rules()


func _items() -> void:
	_t.coop_run(3)
	var item = _t.item_with_limit(-1)
	_t.check(item != null, "the game has a plain stat item to trade")
	var key: int = item.effects[0].key_hash
	var base := [RunData.get_player_effect(key, 0), RunData.get_player_effect(key, 1)]
	RunData.add_item(item, 0)
	var gain: int = RunData.get_player_effect(key, 0) - base[0]
	var ledger: String = _t.ledger()
	_t.check(Rules.receivers(item, 0) == [1, 2], "an item without a limit: every other player")
	_t.check(Rules.receivers(item, 1).empty(), "nobody gives what they do not own")
	_t.check(Transfer.give(item, 0, 0).empty(), "nothing is given to oneself")
	_t.check(Transfer.give(item, 0, 7).empty(), "nor to a player who is not there")
	_t.check(Transfer.give(null, 0, 1).empty(), "nor nothing at all")

	var result: Dictionary = Transfer.give(item, 0, 1)
	_t.check(
		not result.empty() and result.received == item and not result.weapon,
		"an item is given (%s)" % [result]
	)
	_t.check(
		not item in RunData.get_player_items_ref(0) and item in RunData.get_player_items_ref(1),
		"it left the giver and is the receiver's"
	)
	_t.check(_t.ledger() == ledger, "nothing appeared or vanished")
	_t.check(
		RunData.get_player_effect(key, 0) == base[0] and gain != 0,
		"the giver's stat is back where it was before the item"
	)
	_t.check(
		RunData.get_player_effect(key, 1) - base[1] == gain, "the receiver has its effect instead"
	)
	_t.check(Transfer.give(item, 0, 1).empty(), "the same hand-over again gives nothing")
	_t.check(_t.ledger() == ledger, "and changes nothing")
	_t.check(not Transfer.give(item, 1, 2).empty(), "the receiver can pass it on")
	_t.check(not Transfer.give(item, 2, 0).empty(), "and it can come back")
	_t.check(
		RunData.get_player_effect(key, 0) - base[0] == gain and _t.ledger() == ledger,
		"round trip: the first owner has the item and its effect once"
	)
	_t.check(RunData.get_player_effect(key, 1) == base[1], "and the others nothing of it")


# "Unique" is a limit of 1: a player who has the item cannot be given another.
func _limits() -> void:
	_t.coop_run(3)
	var unique = _t.item_with_limit(1)
	_t.check(unique != null, "the game has a unique item")
	RunData.add_item(unique, 0)
	RunData.add_item(unique.duplicate(), 1)
	_t.check(Rules.receivers(unique, 0) == [2], "a unique item only goes to players without it")
	var ledger: String = _t.ledger()
	_t.check(Transfer.give(unique, 0, 1).empty(), "a second unique item is refused")
	_t.check(_t.ledger() == ledger, "and both players keep theirs")
	_t.check(not Transfer.give(unique, 0, 2).empty(), "the player without it takes it")
	_t.check(Rules.receivers(RunData.get_player_items_ref(1).back(), 1) == [0], "and so on")

	var limited = null
	for max_nb in [2, 3, 4, 5]:
		limited = _t.item_with_limit(max_nb) if limited == null else limited
	_t.check(limited != null, "the game has an item with a limit above 1")
	if limited == null:
		return
	_t.coop_run(2)
	for _i in limited.max_nb - 1:
		RunData.add_item(limited, 1)
	RunData.add_item(limited, 0)
	RunData.add_item(limited, 0)
	_t.check(not Transfer.give(limited, 0, 1).empty(), "a limited item is given up to its limit")
	var refused: bool = Transfer.give(limited, 0, 1).empty()
	var count: int = RunData.get_nb_item(limited.my_id_hash, 1)
	_t.check(
		refused and count == limited.max_nb, "and not beyond (%d of %d)" % [count, limited.max_nb]
	)


# The shop hands out ItemService's own item objects: the same object several times in a list,
# and in both players' lists.
func _shared_objects() -> void:
	_t.coop_run(2)
	var item = _t.item_with_limit(-1)
	var key: int = item.effects[0].key_hash
	var base := [RunData.get_player_effect(key, 0), RunData.get_player_effect(key, 1)]
	for _i in 3:
		RunData.add_item(item, 0)
	RunData.add_item(item, 1)
	var gain: int = (RunData.get_player_effect(key, 0) - base[0]) / 3
	var ledger: String = _t.ledger()
	_t.check(not Transfer.give(item, 0, 1).empty(), "one of three copies of an object is given")
	var counts := [
		RunData.get_player_items_ref(0).count(item), RunData.get_player_items_ref(1).count(item)
	]
	_t.check(counts == [2, 2], "exactly one changed hands (%s)" % [counts])
	_t.check(_t.ledger() == ledger, "no copy appeared or vanished")
	_t.check(
		(
			RunData.get_player_effect(key, 0) - base[0] == 2 * gain
			and RunData.get_player_effect(key, 1) - base[1] == 2 * gain
		),
		"and the effects follow the counts"
	)
	var looks: int = RunData.players_data[0].appearances.size()
	_t.check(not Transfer.give(item, 0, 1).empty(), "a second copy is given")
	_t.check(
		RunData.players_data[0].appearances.size() == looks,
		"the giver keeps the looks of its last copy"
	)


# What belongs to its player's state stays there.
func _bound_items() -> void:
	_t.coop_run(2)
	var character = RunData.get_player_character(0)
	_t.check(
		character in RunData.get_player_items_ref(0) and Rules.receivers(character, 0).empty(),
		"a character is not given away"
	)
	var bound = null
	var spent = null
	for item in ItemService.items:
		if not item.can_be_looted and bound == null:
			bound = item
		for effect in item.effects:
			if effect.get_id() in Rules.ONE_SHOT_EFFECTS and spent == null:
				spent = item
	if bound != null:
		RunData.players_data[0].items.push_back(bound)
		_t.check(Rules.receivers(bound, 0).empty(), "%s is bound to its player" % bound.my_id)
	if spent != null:
		RunData.players_data[0].items.push_back(spent)
		_t.check(Rules.receivers(spent, 0).empty(), "%s was spent when picked up" % spent.my_id)
	if bound == null:
		print("  info: no item the game never offers here, bound items not tested")
	if spent == null:
		print("  info: no one-shot item without the DLCs, spent items not tested")
	var hourglass = _t.find(ItemService.items, "item_hourglass")
	if hourglass != null and hourglass.replaced_by != null:
		RunData.add_item(hourglass, 0)
		var ledger: String = _t.ledger()
		_t.check(not Transfer.give(hourglass, 0, 1).empty(), "an item with a successor is given")
		_t.check(_t.ledger() == ledger, "and the giver gets no leftover for it")


func _weapons() -> void:
	_t.coop_run(2)
	var pistol = _t.weapon()
	var weapon = RunData.add_weapon(pistol, 0)
	weapon.tracked_value = 41
	weapon.dmg_dealt_last_wave = 7
	var ledger: String = _t.ledger()
	_t.check(Rules.receivers(weapon, 0) == [1], "a weapon goes to a player with a free slot")
	_t.check(Rules.receivers(pistol, 0).empty(), "only the giver's own weapon object counts")
	var result: Dictionary = Transfer.give(weapon, 0, 1)
	var received = result.get("received")
	_t.check(
		not result.empty() and result.weapon and not result.combined,
		"a weapon is given into a free slot"
	)
	_t.check(
		RunData.get_player_weapons_ref(0).empty() and RunData.get_player_weapons_ref(1) == [received],
		"the giver has none, the receiver one"
	)
	_t.check(
		received.my_id == _t.PISTOL and received.tracked_value == 41,
		"it keeps what it has tracked"
	)
	_t.check(received.dmg_dealt_last_wave == 7, "and the damage it dealt last wave")
	_t.check(_t.ledger() == ledger, "no weapon appeared or vanished")
	_t.check(Transfer.give(weapon, 0, 1).empty(), "the weapon that was given cannot be given again")
	_t.check(RunData.get_player_weapons_ref(1).size() == 1, "and the receiver still has one")


# No free slot: the weapon is combined with one of the receiver's, a cursed one first.
func _combine() -> void:
	_t.coop_run(2)
	var pistol = _t.weapon()
	var slots: int = RunData.get_player_effect(Keys.weapon_slot_hash, 1)
	var cursed = pistol.duplicate()
	cursed.is_cursed = true
	for i in slots:
		RunData.add_weapon(cursed if i == slots - 2 else pistol, 1)
	var other = _t.weapon("weapon_smg_1")
	var given = RunData.add_weapon(pistol, 0)
	var unknown = RunData.add_weapon(other, 0)
	_t.check(not RunData.has_weapon_slot_available(given, 1), "the receiver has no free slot")
	_t.check(Rules.weapon_plan(given, 1) == Rules.COMBINE, "but the same weapon to combine with")
	_t.check(Rules.combine_partner(given, 1).is_cursed, "the cursed one is the partner")
	_t.check(Rules.weapon_plan(unknown, 1) == Rules.NONE, "a weapon without a partner: no place")
	_t.check(Rules.receivers(unknown, 0).empty(), "so nobody is offered for it")

	var result: Dictionary = Transfer.give(given, 0, 1)
	var ids: Array = _t.ids(RunData.get_player_weapons_ref(1))
	_t.check(not result.empty() and result.combined, "the weapon is given and combined")
	_t.check(
		ids.size() == slots and ids.count(_t.PISTOL) == slots - 1 and not (_t.PISTOL + "*") in ids,
		"the cursed weapon was used up, the plain ones stay (%s)" % [ids]
	)
	var combined = result.received
	_t.check(
		combined in RunData.get_player_weapons_ref(1) and combined.tier == pistol.tier + 1,
		"and the receiver has the next tier (%s)" % combined.my_id
	)
	_t.check(RunData.get_player_weapons_ref(0) == [unknown], "the giver keeps its other weapon")


func _weapon_rules() -> void:
	_t.coop_run(2)
	var given = RunData.add_weapon(_t.weapon(), 0)
	var effects: Dictionary = RunData.get_player_effects(1)
	for key in [Keys.no_ranged_weapons_hash, Keys.lock_current_weapons_hash]:
		effects[key] = 1
		var label: String = Keys.hash_to_string[key]
		var blocked: bool = key == Keys.no_ranged_weapons_hash
		_t.check(
			Rules.receivers(given, 0).empty() == blocked,
			"receiver with %s: %s" % [label, "no weapon" if blocked else "a free slot still takes one"]
		)
		effects[key] = 0
	effects[Keys.max_weapon_tier_hash] = -1
	_t.check(Rules.receivers(given, 0).empty(), "a weapon above the receiver's tier limit: no")
	effects[Keys.max_weapon_tier_hash] = 99
	effects[Keys.weapon_slot_hash] = 0
	_t.check(Rules.receivers(given, 0).empty(), "no slot and nothing to combine: refused")
	effects[Keys.weapon_slot_hash] = 6
	RunData.get_player_effects(0)[Keys.lock_current_weapons_hash] = 1
	_t.check(Rules.receivers(given, 0).empty(), "a giver with locked weapons keeps them")
	RunData.get_player_effects(0)[Keys.lock_current_weapons_hash] = 0
	_t.check(Rules.receivers(given, 0) == [1], "without those effects the weapon can go")
