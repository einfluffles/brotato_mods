extends "res://effects/items/swap_max_min_stat_effect.gd"
# Axolotl: the game's get_args calls to_upper() on null when stats_swapped has fewer than two
# known entries, which crashes a release build; co-op reaches that state by itself. The text
# then names the player's current lowest and highest stats. The effect is shared by every
# Axolotl, so it is not repaired here.

const LOG_NAME := "einfluffles-BrotatoTogether:Axolotl"
const AXOLOTL_ID := "item_axolotl"
const META_KEY := "bt_axolotl_warnings"  # Engine meta: {count, logged_msec, unlogged}
const FULL_WARNINGS := 5  # the first ones are all logged, later ones once per interval
const WARN_INTERVAL_MSEC := 60000


func get_args(player_index: int) -> Array:
	if not has_been_applied or bt_renderable(stats_swapped):
		return .get_args(player_index)
	bt_warn("get_args", player_index)
	var keys: Array = _find_min_max_stat_keys(player_index)
	return [_stat_text(keys[1]), _stat_text(keys[0])]


func apply(player_index: int) -> void:
	.apply(player_index)
	if not bt_renderable(stats_swapped):
		bt_warn("apply", player_index)


func deserialize_and_merge(serialized: Dictionary) -> void:
	.deserialize_and_merge(serialized)
	if has_been_applied and not bt_renderable(stats_swapped):
		bt_warn("deserialize_and_merge", -1)


# Whether the game's get_args can name both entries of stats (stats_swapped once applied).
static func bt_renderable(stats: Array) -> bool:
	if stats.size() < 2:
		return false
	for i in 2:
		if typeof(stats[i]) != TYPE_INT or not Keys.hash_to_string.has(stats[i]):
			return false
	return true


static func bt_warning_count() -> int:
	return Engine.get_meta(META_KEY).count if Engine.has_meta(META_KEY) else 0


func bt_warn(where: String, player_index: int) -> void:
	if not Engine.has_meta(META_KEY):
		Engine.set_meta(META_KEY, {"count": 0, "logged_msec": 0, "unlogged": 0})
	var warnings: Dictionary = Engine.get_meta(META_KEY)
	warnings.count += 1
	var now := OS.get_ticks_msec()
	if warnings.count > FULL_WARNINGS and now - warnings.logged_msec < WARN_INTERVAL_MSEC:
		warnings.unlogged += 1
		return
	var text := (
		"Axolotl effect %d in %s, player %d, wave %d: has_been_applied %s, stats_swapped %s, %s; %s; %s"
		% [
			get_instance_id(),
			where,
			player_index,
			RunData.current_wave,
			has_been_applied,
			_describe(stats_swapped),
			_missing(stats_swapped),
			_origin(),
			_owners(),
		]
	)
	if where == "get_args":
		text += "; its text names player %d's own lowest and highest stats" % player_index
	if warnings.unlogged > 0:
		text += " (%d more since the last warning)" % warnings.unlogged
	ModLoaderLog.warning(text, LOG_NAME)
	warnings.logged_msec = now
	warnings.unlogged = 0


func _stat_text(key) -> String:
	return tr(str(Keys.hash_to_string.get(key, "")).to_upper())


# [int 4033990219 (stat_engineering), Nil null]: type, value and the key's name when known.
static func _describe(stats: Array) -> String:
	var parts := []
	for entry in stats:
		var part := "%s %s" % [_type_name(typeof(entry)), entry]
		if typeof(entry) == TYPE_INT and Keys.hash_to_string.has(entry):
			part += " (%s)" % Keys.hash_to_string[entry]
		parts.append(part)
	return "[%s] (size %d)" % [PoolStringArray(parts).join(", "), stats.size()]


static func _missing(stats: Array) -> String:
	var missing := []
	for entry in stats:
		if typeof(entry) == TYPE_INT and not Keys.hash_to_string.has(entry):
			missing.append(entry)
	if missing.empty():
		return "no int hash missing from Keys.hash_to_string"
	return "missing from Keys.hash_to_string %s" % [missing]


static func _type_name(type: int) -> String:
	match type:
		TYPE_NIL:
			return "Nil"
		TYPE_INT:
			return "int"
		TYPE_REAL:
			return "float"
		TYPE_STRING:
			return "String"
	return "type %d" % type


# The ItemService original's effect is the one shop offers and bought Axolotls share.
func _origin() -> String:
	for item in ItemService.items:
		if item.my_id == AXOLOTL_ID:
			if self in item.effects:
				return "the ItemService original's effect (shared)"
			return "a separate instance (not the ItemService original's effect)"
	return "a separate instance (no Axolotl in ItemService.items)"


func _owners() -> String:
	var owners := []
	for p in RunData.get_player_count():
		for item in RunData.get_player_items(p):
			if self in item.effects:
				owners.append(p)
				break
	return "held by the items of players %s" % [owners] if not owners.empty() else "owned by nobody"
