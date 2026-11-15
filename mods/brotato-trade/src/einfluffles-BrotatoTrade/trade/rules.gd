extends Reference
# Who may give what to whom. Only reads the run; trade/transfer.gd changes it.
#
# Giver: owns that very object and may part with it.
# - weapons: not while the character's weapons are locked (the game hides combine / recycle too)
# - items: no character, nothing the game never offers (can_be_looted: builder turret, tumor,
#   hatched eggs, used-up leftovers: they belong to their player's state) and nothing whose
#   effect was spent when it was picked up (ONE_SHOT_EFFECTS: giving it away takes nothing back,
#   so every hand-over would run it again)
# Receiver:
# - items: the limit of the item (max_nb, "unique" = 1), counted like the shop counts it
# - weapons: what ShopItemsContainer._can_weapon_be_bought asks before a buy: tier limits, no
#   melee / ranged weapons, then a free slot (ADD), else a weapon to combine it with (COMBINE)

enum { NONE, ADD, COMBINE }

# Effect.get_id() of effects with an empty unapply().
const ONE_SHOT_EFFECTS := ["swap_max_min_stat", "gain_meca_parts"]


static func is_weapon(item) -> bool:
	return item is WeaponData


static func is_player(player: int) -> bool:
	return player >= 0 and player < RunData.get_player_count()


static func can_give(item, from: int) -> bool:
	if item == null or not is_player(from):
		return false
	if is_weapon(item):
		if RunData.get_player_effect_bool(Keys.lock_current_weapons_hash, from):
			return false
		return RunData.get_player_weapons_ref(from).has(item)
	if not item is ItemData or not RunData.get_player_items_ref(from).has(item):
		return false
	if item == RunData.get_player_character(from) or item.my_id.begins_with("character_"):
		return false
	if not item.can_be_looted:
		return false
	for effect in item.effects:
		if effect.get_id() in ONE_SHOT_EFFECTS:
			return false
	return true


static func can_receive(item, to: int) -> bool:
	if item == null or not is_player(to):
		return false
	if is_weapon(item):
		return weapon_plan(item, to) != NONE
	return RunData.get_remaining_max_nb_item(item, to) > 0


# How player `to` would take the weapon: NONE, ADD (a free slot) or COMBINE (no slot, but a
# weapon it upgrades with).
static func weapon_plan(weapon, to: int) -> int:
	var max_tier: int = RunData.get_player_effect(Keys.max_weapon_tier_hash, to)
	var min_tier: int = RunData.get_player_effect(Keys.min_weapon_tier_hash, to)
	if weapon.tier > max_tier or weapon.tier < min_tier:
		return NONE
	if weapon.type == WeaponType.MELEE:
		if RunData.get_player_effect_bool(Keys.no_melee_weapons_hash, to):
			return NONE
	elif weapon.type == WeaponType.RANGED:
		if RunData.get_player_effect_bool(Keys.no_ranged_weapons_hash, to):
			return NONE
	if RunData.has_weapon_slot_available(weapon, to):
		return ADD
	if RunData.get_player_effect_bool(Keys.lock_current_weapons_hash, to):
		return NONE
	if weapon.upgrades_into == null or weapon.upgrades_into.tier > max_tier:
		return NONE
	return COMBINE if combine_partner(weapon, to) != null else NONE


# The receiver's weapon the given one is combined with: a cursed one first, then the order
# the game itself would pick in (RunData.get_combine_candidates).
static func combine_partner(weapon, to: int):
	var candidates: Array = RunData.get_combine_candidates(weapon, to)
	for candidate in candidates:
		if candidate.is_cursed:
			return candidate
	return candidates.front() if not candidates.empty() else null


static func can_trade(item, from: int, to: int) -> bool:
	return from != to and can_give(item, from) and can_receive(item, to)


# The players `from` can give the item to, in player order.
static func receivers(item, from: int) -> Array:
	var players := []
	if not can_give(item, from):
		return players
	for to in RunData.get_player_count():
		if to != from and can_receive(item, to):
			players.append(to)
	return players
