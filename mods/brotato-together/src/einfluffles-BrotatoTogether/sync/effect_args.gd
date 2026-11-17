extends Reference
# The custom args of the game's effects, the same in every run state the mod serializes.
#
# Effect.get_text adds an effect's custom args (_add_custom_args: a NEUTRAL sign for a burn
# duration, an interval, ...) the first time its description is shown, and serialize() writes
# them. Effects are shared resources (every copy of an item, the shop's offered items), so a
# tooltip, a flame turret offered in the shop or a gear page shown on the host changed the
# serialized gear of every player owning that effect while nothing in the run changed: a miss of
# RunCache's fingerprint (7 in a 43-wave session, waves 18 to 40), and run parts that changed or
# not depending on what had been shown (run_parts_tests.gd flaked on it).
#
# settle(state, true) (host, RunStateCodec.serialize): every effect the state serializes gets
# its custom args now, as showing its text would; a later get_text changes nothing. Each effect
# is walked once (shared ones too): 2.4 / 3.0 ms in the late 2 / 4-player test runs, only when
# the run is serialized (never in RunCache's fingerprint check).
# settle(state, false) (client, after deserializing a run state the host serialized that way):
# the args came with the effect, so it is only marked as having them; its first get_text would
# otherwise add them a second time. (A second copy does not change the text: every added arg is
# USUAL value and format with a NEUTRAL sign, applied twice the same. The game's own resume has
# that duplicate; DLC 2 drops duplicates before comparing effects.)
#
# state: a run state as ProgressData.get_run_state / deserialize_run_state give it (players_data
# PlayerRunData objects, locked_shop_items and shop_items as [item, wave value] per player).

# Effect properties holding effects that serialize() includes (StructureEffect,
# EffectWithSubEffects, BonkDogEffect, BotOMineEffect, CarbonBowStatEffect, ...).
const NESTED_LISTS := ["effects", "sub_effects"]
const NESTED := ["explosion_effect", "landmine_effect_stat", "structure_effect"]


# Returns the number of effects whose args were added (host) or marked (client).
static func settle(state: Dictionary, add: bool) -> int:
	var walk := {"seen": {}, "add": add, "count": 0}
	var players = state.get("players_data")
	if typeof(players) == TYPE_ARRAY:
		for data in players:
			if data is Object:
				_player(data, walk)
	for list_key in ["locked_shop_items", "shop_items"]:
		var lists = state.get(list_key)
		if typeof(lists) != TYPE_ARRAY:
			continue
		for list in lists:
			if typeof(list) != TYPE_ARRAY:
				continue
			for entry in list:
				if typeof(entry) == TYPE_ARRAY and not entry.empty():
					_item(entry[0], walk)
	return walk.count


static func _player(data: Object, walk: Dictionary) -> void:
	for item in data.items:
		_item(item, walk)
	for weapon in data.weapons:
		_item(weapon, walk)
	for entry in data.active_set_effects:
		if typeof(entry) == TYPE_ARRAY and entry.size() > 1:
			_effect(entry[1], walk)
	for key in RunData.effect_keys_full_serialization:
		var value = data.effects.get(key)
		if typeof(value) == TYPE_ARRAY:
			for effect in value:
				_effect(effect, walk)
		else:
			_effect(value, walk)


static func _item(item, walk: Dictionary) -> void:
	if not item is Object or not _first(item, walk):
		return
	for list_key in ["effects", "mutation_removed_effects"]:
		var effects = item.get(list_key)
		if typeof(effects) == TYPE_ARRAY:
			for effect in effects:
				_effect(effect, walk)
	_item(item.get("replaced_by"), walk)
	var sets = item.get("sets")
	if typeof(sets) == TYPE_ARRAY:
		for set in sets:
			if not set is Object or typeof(set.get("set_bonuses")) != TYPE_ARRAY:
				continue
			for bonus in set.set_bonuses:
				if typeof(bonus) == TYPE_ARRAY:
					for effect in bonus:
						_effect(effect, walk)


static func _effect(effect, walk: Dictionary) -> void:
	if not effect is Object or not ("_custom_args_added" in effect) or not _first(effect, walk):
		return
	if not effect._custom_args_added:
		if walk.add:
			effect._add_custom_args()
		effect._custom_args_added = true
		walk.count += 1
	for list_key in NESTED_LISTS:
		var effects = effect.get(list_key)
		if typeof(effects) == TYPE_ARRAY:
			for nested in effects:
				_effect(nested, walk)
	for key in NESTED:
		_effect(effect.get(key), walk)


static func _first(object: Object, walk: Dictionary) -> bool:
	var id := object.get_instance_id()
	if walk.seen.has(id):
		return false
	walk.seen[id] = true
	return true
