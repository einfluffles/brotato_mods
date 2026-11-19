extends Reference
# Effect.get_text adds custom args to the shared effect the first time a text is shown, which
# changes what serialize() writes. settle() adds them up front (host) or marks them as added
# (client, after deserializing), so a run state serializes the same whatever has been shown.

# Effect properties holding effects that serialize() includes (StructureEffect,
# EffectWithSubEffects, BonkDogEffect, BotOMineEffect, CarbonBowStatEffect, ...).
const NESTED_LISTS := ["effects", "sub_effects"]
const NESTED := ["explosion_effect", "landmine_effect_stat", "structure_effect"]


# state: a run state as ProgressData.get_run_state / deserialize_run_state give it.
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
