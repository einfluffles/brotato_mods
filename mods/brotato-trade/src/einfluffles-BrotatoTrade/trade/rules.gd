extends Reference
# Who may give what to whom. Only reads the run; trade/transfer.gd changes it.
#
# Giver: owns that very object and may part with it.
# - weapons: not while the character's weapons are locked (the game hides combine / recycle too)
# - items: no character, nothing the game never offers (can_be_looted: builder turret, tumor,
#   hatched eggs, used-up leftovers: they belong to their player's state) and nothing with an
#   effect that a hand-over does not undo (ONE_SHOT_EFFECTS, SPENT_KEYS: giving it away takes
#   back less than the receiver gets, so passing it back and forth would farm it)
# Receiver:
# - items: the limit of the item (max_nb, "unique" = 1), counted like the shop counts it when
#   it rolls: what the player owns and what its shop offers it right now, locked or not
# - weapons: what ShopItemsContainer._can_weapon_be_bought asks before a buy: tier limits, no
#   melee / ranged weapons, then a free slot (ADD), else a weapon to combine it with (COMBINE)
# A crate item (can_take_crate) is new to the run: there is no giver to check, only whether the
# receiver could take it.

enum { NONE, ADD, COMBINE }

# Effect.get_id() of effects whose unapply() does not undo their apply():
# - swap_max_min_stat (Axolotl), gain_meca_parts: unapply() is empty
# - multiply_value (the Leaps): multiplies the current value, a later hand-over multiplies the
#   grown one, and undoing it in apply order drifts (2V + 2, then (2V + 2) / 2 - 2 = V - 1)
# - stat_cap (Handcuffs, Shackles): apply() caps at the stat's current value, so a hand-over
#   and back caps it anew and frees what grew under the cap
# - extra_enemy (Bait): the wave empties the list, the giver's unapply() then finds nothing
const ONE_SHOT_EFFECTS := [
	"swap_max_min_stat", "gain_meca_parts", "multiply_value", "stat_cap", "extra_enemy"
]
# Effect.key / custom_key of plain effects the game uses up or resets once they have worked:
# the giver's unapply() then takes back what is no longer there, and the receiver gets it anew.
# - stats_next_wave (Peacock, Celery Tea, Scarf), hp_start_next_wave (Weird Ghost, Hourglass),
#   extra_loot_aliens_next_wave (Lure): used up or reset when the next wave starts
# - free_rerolls (Dangerous Bunny): the shop counts its rise when something is bought, the
#   giver keeps the rerolls it was given
const SPENT_KEYS := [
	"stats_next_wave", "hp_start_next_wave", "extra_loot_aliens_next_wave", "free_rerolls"
]


static func is_weapon(item) -> bool:
	return item is WeaponData


static func is_player(player: int) -> bool:
	return player >= 0 and player < RunData.get_player_count()


# The giver's weapons for a weapon, else its items.
static func owned_list(item, from: int) -> Array:
	if is_weapon(item):
		return RunData.get_player_weapons_ref(from)
	return RunData.get_player_items_ref(from)


# The player's own object that stands for `item`: item itself when the player owns it, else
# the first of its weapons / items with the same my_id and curse (null: none). For a
# brotato:together client, whose gear rows may show objects of an older state of the run.
static func own_object(item, from: int):
	if item == null or not is_player(from):
		return null
	var owned := owned_list(item, from)
	if owned.has(item):
		return item
	for entry in owned:
		if entry.my_id == item.my_id and entry.is_cursed == item.is_cursed:
			return entry
	return null


# The object a request names: the one at `slot` when its my_id is `id`, else the first with
# that my_id (the request was made on an older state of the run). null: none.
static func find_named(owned: Array, slot: int, id: String):
	if slot >= 0 and slot < owned.size() and owned[slot].my_id == id:
		return owned[slot]
	for entry in owned:
		if entry.my_id == id:
			return entry
	return null


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
	return not has_spent_effect(item)


# The item has an effect that a hand-over would not undo (ONE_SHOT_EFFECTS, SPENT_KEYS).
static func has_spent_effect(item) -> bool:
	for effect in item.effects:
		if effect.get_id() in ONE_SHOT_EFFECTS:
			return true
		if effect.key in SPENT_KEYS or effect.custom_key in SPENT_KEYS:
			return true
	return false


# shop: the shop the trade happens in (null: none). Its offers to `to` count towards an item's
# limit, as when the game rolls them: a buy of an offered item checks nothing but the gold.
static func can_receive(item, to: int, shop: Node = null) -> bool:
	if item == null or not is_player(to):
		return false
	if is_weapon(item):
		return weapon_plan(item, to) != NONE
	return RunData.get_remaining_max_nb_item(item, to) > offered_count(item, to, shop)


# How many of the shop's offers to player `to` count towards the item's limit: the item and
# what it turns into (RunData.get_remaining_max_nb_item counts those too). Locked ones are
# offers like the others. 0 without a limit or a shop.
static func offered_count(item, to: int, shop: Node) -> int:
	if item.max_nb == -1 or shop == null or not is_instance_valid(shop):
		return 0
	if not shop.has_method("_get_shop_items_container"):
		return 0
	var limited: Array = [item.my_id_hash]
	limited += ItemService.get_limited_item_descendants(item.my_id_hash)
	var count := 0
	for node in shop._get_shop_items_container(to)._shop_items:
		if node.active and node.item_data is ItemData and node.item_data.my_id_hash in limited:
			count += 1
	return count


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


# Player `to` can take a crate item in place of the player who found it: a weapon by the
# weapon rules above and what the crate panel's Take checks (RunData.can_take_weapon), an item
# within its limit, counting the player's locked shop items as UpgradesUI._recheck_extra_items
# does (the next shop offers them again).
static func can_take_crate(item, to: int) -> bool:
	if item == null or not is_player(to):
		return false
	if is_weapon(item):
		return weapon_plan(item, to) != NONE and RunData.can_take_weapon(item, to)
	if not item is ItemData:
		return false
	return RunData.get_remaining_max_nb_item(item, to) > locked_count(item, to)


# How many of player `to`'s locked shop items count towards the item's limit.
static func locked_count(item, to: int) -> int:
	if item.max_nb == -1:
		return 0
	var limited: Array = [item.my_id_hash]
	limited += ItemService.get_limited_item_descendants(item.my_id_hash)
	var count := 0
	for locked in RunData.get_player_locked_shop_items(to):
		if locked[0] is ItemData and locked[0].my_id_hash in limited:
			count += 1
	return count


static func can_trade(item, from: int, to: int, shop: Node = null) -> bool:
	return from != to and can_give(item, from) and can_receive(item, to, shop)


# The players `from` can give the item to, in player order.
static func receivers(item, from: int, shop: Node = null) -> Array:
	var players := []
	if not can_give(item, from):
		return players
	for to in RunData.get_player_count():
		if to != from and can_receive(item, to, shop):
			players.append(to)
	return players
