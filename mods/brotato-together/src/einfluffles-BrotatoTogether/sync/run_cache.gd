extends Reference
# Host: the run state a state stream section carries, serialized only when it can have changed,
# in parts (sync/run_parts.gd). One per provider: ShopSync (section shop) and UpgradesSync
# (section upgrades, the level-up / crate panels). Serializing it (ProgressData.get_run_state,
# serialize_run_state, JSON.print) grows with the run's items: 2.6 ms for a small 2-player run,
# 29 / 58 ms for a late endless run with 2 / 4 players (250 items each), three quarters of it
# JSON.print (shop_change_tests.gd and upgrades_change_tests.gd measure it). The stream checks
# every 0.1 s, so the check itself must not serialize: a whole key costs 0.05 - 0.3 ms there
# (shop / panels).
#
# refresh(screen, save_args, extra) brings parts / rev up to date and serializes only when
# - the fingerprint changed: cheap values that every mutation of the run the game does on that
#   screen moves, whose cost does not grow with the item lists. The shared part (RunData and
#   every player: fingerprint() names them) is here; the caller adds its screen's part: the
#   save args (the shop's offered items and rerolls) and extra (UpgradesSync: the option each
#   panel processes);
# - a check was forced: after an applied intent and after peer_ready (force());
# - the safety net is due (SAFETY_NET_MSEC since the last serialization): it catches what the
#   fingerprint cannot see (a stat or effect written directly, by another mod say). A change
#   found while the fingerprint stayed the same is a miss of the fingerprint: logged as a
#   warning (missed) and sent like any other.
# The serialized dictionary is split (RunParts.split: "c", per player "g<p>" and "p<p>") and each
# part's hash() compared with the last one of its key (1.2 / 8 / 15 ms for the whole run in the
# runs above, a quarter of the text's cost): only a part whose hash changed is printed to JSON,
# and only one whose text changed too is compressed and gets a new id (RunParts.entry), so a
# purchase packs the common part and the buyer's two, a level-up choice one. (The hash alone
# also moves when a value's type or its last bits change, which the text does not show: seen on
# both players' weapons right after a shop came up. Equal hashes of different content, 1 in
# 2^32, would wait for the next change of that part.) rev counts the changes of the part ids
# (the stream's key carries it, so the key changes exactly when the body's run does). Only text,
# bytes and ints are kept, never a game object; clear() once the screen is gone drops them.

const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:RunCache"
# 1 s: what the fingerprint cannot see is at most that late, and the late 4-player run's check
# (15 ms, about one frame) costs 1.5 % of the host's time on the screen.
const SAFETY_NET_MSEC := 1000

var label := ""  # the screen, for the miss warning and RunParts.Sender's counters
var title := ""  # the screen as its provider names it (the log line when it closes)
# key -> RunParts.entry ({hash, id, size, data, text}) of the run state as of the last change, in
# RunParts.split's order
var parts := {}
var rev := 0  # bumped whenever an id of parts changes
var serialized := 0  # run states serialized (tests)
var packs := 0  # parts compressed (tests)
var missed := 0  # changes only a forced check or the safety net found (tests)

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


# Called on every check (or frame) while the screen is not up: nothing to do once cleared.
func clear() -> void:
	if _screen_id == 0 and parts.empty():
		return
	parts = {}
	_screen_id = 0
	_fingerprint = []
	_force_frame = -1


# Returns whether parts changed. screen: the node the run state is shown on (another one starts
# over); save_args: ProgressData.get_run_state's arguments (the shop's, [] elsewhere); extra:
# the caller's part of the fingerprint (ints and floats only).
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
	parts = fresh
	if not changed:
		return false
	if unchanged:
		missed += 1
		ModLoaderLog.warning(
			"%s run state changed without a change of its fingerprint; sent" % label, LOG_NAME
		)
	rev += 1
	return true


# The length of the run state's JSON text, all parts (tests, log lines).
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


# The shared part: everything a mutation of the run moves, as cheap values (ints and floats
# only: no object is kept). Sizes and the last element stand for the item lists, so the cost
# does not grow with them; weapons and locked items are short and listed by instance.
# - gold (RunData.add_gold / remove_gold: buy, rerolls, recycling, ban, a crate item discarded)
# - items: add_item_triggering_stat_gain_effects pushes at the end (buy, a crate item taken),
#   try_mutate_item_on_equip (DLC) replaces one (recently_mutated)
# - weapons: add_weapon duplicates; combine_weapon, recycle_weapon, meca_upgrade_weapon replace
#   or remove (shop item popup, crate weapon popup), meca parts with them
# - upgrades_taken (RunData.add_upgrade: a level-up option chosen; its stats come with it)
# - banned_items, remaining_ban_token (ban in the shop or of a crate item)
# - locked items (RunData.lock_player_shop_item), wave, endless, bonus gold, retries
# - health, level, xp, pending mutations (consumables, gold and fruit still flying in)
# A stat or effect written alone (the effects' sizes stay) is the safety net's.
# save_args: their sizes and values, lists of [item, wave value] (the shop's offered items) by
# item instance. extra: appended as it is.
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
