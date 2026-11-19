extends Reference
# Host: a section's run state, serialized only when a cheap fingerprint of it changed, a check
# was forced, or SAFETY_NET_MSEC passed (JSON.print of a late run costs tens of ms). Only a part
# (RunParts.split) whose hash and text both changed is compressed and gets a new id.

const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:RunCache"
# What the fingerprint cannot see (a stat or effect written directly) is at most this late.
const SAFETY_NET_MSEC := 1000
const MISS_DEPTH := 4  # path levels the miss warning names: down to a weapon's field
const MISS_PATHS := 6  # paths the miss warning lists

var label := ""  # the screen, for the miss warning and RunParts.Sender's counters
var title := ""  # the screen as its provider names it (the log line when it closes)
# key -> RunParts.entry ({hash, id, size, data, text}) of the run state as of the last change, in
# RunParts.split's order
var parts := {}
var rev := 0  # bumped whenever an id of parts changes
var serialized := 0
var packs := 0  # parts compressed
var missed := 0  # changes only a forced check or the safety net found
var last_miss := ""  # the warning of the last miss

var _screen_id := 0  # instance id of the screen parts belong to (0: none)
var _fingerprint := []
var _checked_msec := 0
var _force_frame := -1  # a check from this idle frame on, whatever the fingerprint says


func _init(screen_label := "run") -> void:
	label = screen_label


# A full check at the first refresh from frames_ahead idle frames on (1: after deferred game
# code, like the shop's Buy and Steal).
func force(frames_ahead := 0) -> void:
	_force_frame = int(max(_force_frame, Engine.get_idle_frames() + frames_ahead))


func clear() -> void:
	if _screen_id == 0 and parts.empty():
		return
	parts = {}
	_screen_id = 0
	_fingerprint = []
	_force_frame = -1


# Returns whether parts changed. screen: the node the run state is shown on (another one starts
# over); save_args: ProgressData.get_run_state's arguments; extra: the caller's part of the
# fingerprint (ints and floats only).
func refresh(screen: Object, save_args := [], extra := []) -> bool:
	var fingerprint := fingerprint(save_args, extra)
	var same_screen: bool = screen.get_instance_id() == _screen_id and not parts.empty()
	var frame := Engine.get_idle_frames()
	var forced: bool = _force_frame >= 0 and frame >= _force_frame
	var now := OS.get_ticks_msec()
	var unchanged: bool = same_screen and fingerprint == _fingerprint
	if unchanged and not forced and now - _checked_msec < SAFETY_NET_MSEC:
		return false
	if not same_screen:
		clear()
		_screen_id = screen.get_instance_id()
	if forced:
		_force_frame = -1
	_fingerprint = fingerprint
	_checked_msec = now
	var data := RunStateCodec.serialize(save_args)
	serialized += 1
	var fresh := {}
	var changed := false
	var split := RunParts.split(data)
	for key in split:
		var part_hash := hash(split[key])
		var old = parts.get(key)
		if old != null and old.hash == part_hash:
			fresh[key] = old
			continue
		var text := JSON.print(split[key])
		if old != null and text == old.text:
			old.hash = part_hash  # a value's type or last bits moved, not its text: same id
			fresh[key] = old
			continue
		fresh[key] = RunParts.entry(split[key], part_hash, text)
		packs += 1
		changed = changed or old == null or old.id != fresh[key].id
	changed = changed or fresh.size() != parts.size()
	var before := parts
	parts = fresh
	if not changed:
		return false
	if unchanged:
		missed += 1
		last_miss = (
			"%s run state changed without a change of its fingerprint: %s; sent"
			% [label, miss_text(miss_paths(before, fresh))]
		)
		ModLoaderLog.warning(last_miss, LOG_NAME)
	rev += 1
	return true


# The paths that moved between two sets of parts ({key: RunParts.entry}), for the miss warning.
static func miss_paths(before: Dictionary, after: Dictionary) -> Array:
	var old := {}
	var new := {}
	for key in after:
		var was = before.get(key)
		if was == null or was.id != after[key].id:
			new[key] = JSON.parse(after[key].text).result
			if was != null:
				old[key] = JSON.parse(was.text).result
	for key in before:
		if not after.has(key):
			old[key] = JSON.parse(before[key].text).result
	return RunParts.changed_paths(old, new, MISS_DEPTH)


# "a, b, c, d, e, f, +3 more" (MISS_PATHS paths at most); "no value" when the texts differ but
# not what they parse to.
static func miss_text(paths: Array) -> String:
	if paths.empty():
		return "no value"
	var text := ", ".join(PoolStringArray(paths.slice(0, int(min(paths.size(), MISS_PATHS)) - 1)))
	if paths.size() > MISS_PATHS:
		text += ", +%d more" % (paths.size() - MISS_PATHS)
	return text


# The length of the run state's JSON text, all parts.
func text_size() -> int:
	var size := 0
	for key in parts:
		size += parts[key].id[1]
	return size


# Every part in the wire format (RunParts header): what a client with nothing needs.
func all() -> Dictionary:
	var run := {"ids": {}, "parts": {}}
	for key in parts:
		run.ids[key] = parts[key].id
		run.parts[key] = {"size": parts[key].size, "data": parts[key].data}
	return run


# The shared part: cheap values (ints and floats only) that every mutation of the run moves. Sizes
# and the last element stand for the item lists, so the cost does not grow with them.
# - gold (RunData.add_gold / remove_gold: buy, rerolls, recycling, ban, a crate item discarded)
# - items: add_item_triggering_stat_gain_effects pushes at the end, try_mutate_item_on_equip
#   (DLC) replaces one (recently_mutated)
# - weapons by instance (add_weapon, combine_weapon, recycle_weapon, meca_upgrade_weapon)
# - upgrades_taken (RunData.add_upgrade), banned_items, remaining_ban_token, locked items
# - wave, endless, bonus gold, retries, health, level, xp, pending mutations
# A stat or effect written alone (the effects' sizes stay) is left to the safety net.
# save_args: lists of [item, wave value] (the shop's offered items) go in by item instance.
static func fingerprint(save_args := [], extra := []) -> Array:
	var background = RunData.current_background
	var values := [
		RunData.players_data.size(),
		RunData.current_wave,
		RunData.is_endless_run,
		RunData.bonus_gold,
		RunData.total_bonus_gold,
		RunData.retries,
		RunData.nb_of_waves,
		RunData.current_difficulty,
		background.get_instance_id() if background is Object else 0,
		RunData.max_endless_wave_record_beaten,
		RunData.challenges_completed_this_run.size(),
		RunData.shop_effects_checked,
		RunData.locked_shop_items.size(),
	]
	for args in save_args:
		values.append(args.size())
		for p in args.size():
			if args[p] is Array:  # offered items: [item, wave value]
				values.append(args[p].size())
				for entry in args[p]:
					values.append(_id(entry[0]))
					values.append(entry[1])
			else:
				values.append(args[p])
	values.append_array(extra)
	var all_locked: Array = RunData.locked_shop_items
	for p in RunData.players_data.size():
		_player_values(values, RunData.players_data[p])
		var locked: Array = all_locked[p] if p < all_locked.size() else []
		values.append(locked.size())
		for entry in locked:
			values.append(_id(entry[0]))
			values.append(entry[1])
	return values


static func _player_values(values: Array, data) -> void:
	values.append_array(
		[
			data.get_instance_id(),
			_id(data.current_character),
			data.gold,
			data.meca_parts,
			data.current_health,
			data.max_health_end_of_wave,
			data.current_level,
			data.current_xp,
			data.pending_mutations,
			data.remaining_ban_token,
			data.uses_ban,
			data.chal_recycling_current,
			data.consumables_picked_up_this_run,
			data.curse_locked_shop_items_pity,
			data.items.size(),
			_id(data.items.back()) if not data.items.empty() else 0,
			data.banned_items.size(),
			data.upgrades_taken.size(),
			data.appearances.size(),
			data.recently_mutated.size(),
			data.extra_selected_weapons.size(),
			data.active_set_effects.size(),
			data.unique_effects.size(),
			data.additional_weapon_effects.size(),
			data.tier_iv_weapon_effects.size(),
			data.tier_i_weapon_effects.size(),
			data.effects.size(),
			data.weapons.size(),
		]
	)
	for weapon in data.weapons:
		values.append(_id(weapon))


static func _id(object) -> int:
	return object.get_instance_id() if object is Object else 0
