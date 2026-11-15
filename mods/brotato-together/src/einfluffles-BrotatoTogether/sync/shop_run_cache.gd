extends Reference
# Host: the shop's run state for ShopSync (section shop of the state stream), serialized only
# when it can have changed. Serializing it (ProgressData.get_run_state with the shop's save args,
# serialize_run_state, JSON.print) grows with the run's items: 2.6 ms for a small 2-player run,
# 29 / 58 ms for a late endless run with 2 / 4 players (250 items each), three quarters of it
# JSON.print (shop_change_tests.gd measures it). The stream checks every 0.1 s, so the check
# itself must not serialize: ShopSync's whole key now costs 45 / 51 / 92 us there.
#
# refresh(shop) brings json / rev up to date and serializes only when
# - the fingerprint changed: cheap values that every mutation the game does in the shop moves
#   (fingerprint() names them and the game function behind each), whose cost does not grow with
#   the item lists;
# - a check was forced: in the frame after an applied intent and after peer_ready (force());
# - the safety net is due (SAFETY_NET_MSEC since the last serialization): it catches what the
#   fingerprint cannot see (a stat or effect written directly, by another mod say). Its check
#   skips JSON.print: the serialized dictionary's hash() is compared first (1.2 / 8 / 15 ms in
#   the runs above), and only a different hash prints and compares the text. (Equal hashes of
#   different content, 1 in 2^32, would wait for the next change of the fingerprint.) A change
#   found while the fingerprint stayed the same is a miss of the fingerprint: logged as a
#   warning (missed) and sent like any other.
# rev counts the changes of json (the stream's key carries it, so the key changes exactly when
# the body's run does); pack() compresses json once per rev, for the key's check and every
# resend of the same state.

const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:ShopSync"
# 1 s: what the fingerprint cannot see is at most that late, and the late 4-player run's check
# (15 ms, about one frame) costs 1.5 % of the host's time in the shop (it cost 58 % before).
const SAFETY_NET_MSEC := 1000

var json := ""  # the run state's JSON text as of the last change
var rev := 0  # bumped whenever json changes
var serialized := 0  # run states serialized (tests)
var packs := 0  # run states compressed (tests)
var missed := 0  # changes only a forced check or the safety net found (tests)

var _shop_id := 0  # instance id of the shop json belongs to (0: none)
var _hash := 0  # hash() of the serialized run state json was printed from
var _fingerprint := []
var _checked_msec := 0
var _force_frame := -1  # a check from this idle frame on, whatever the fingerprint says
var _packed := {}


# A full check at the first refresh from frames_ahead idle frames on (1: after deferred game
# code, like the shop's Buy and Steal).
func force(frames_ahead := 0) -> void:
	_force_frame = int(max(_force_frame, Engine.get_idle_frames() + frames_ahead))


# Called on every check while the host is not in the shop: nothing to do once cleared.
func clear() -> void:
	if _shop_id == 0 and json == "":
		return
	json = ""
	_shop_id = 0
	_hash = 0
	_fingerprint = []
	_packed = {}
	_force_frame = -1


# Returns whether json changed.
func refresh(shop: Node) -> bool:
	var fingerprint := fingerprint(shop)
	var same_shop: bool = shop.get_instance_id() == _shop_id and json != ""
	var frame := Engine.get_idle_frames()
	var forced: bool = _force_frame >= 0 and frame >= _force_frame
	var now := OS.get_ticks_msec()
	var unchanged: bool = same_shop and fingerprint == _fingerprint
	if unchanged and not forced and now - _checked_msec < SAFETY_NET_MSEC:
		return false
	if not same_shop:
		clear()
		_shop_id = shop.get_instance_id()
	if forced:
		_force_frame = -1
	_fingerprint = fingerprint
	_checked_msec = now
	var data := RunStateCodec.serialize(shop_args(shop))
	serialized += 1
	var data_hash := data.hash()
	if same_shop and data_hash == _hash:
		return false
	_hash = data_hash
	var text := JSON.print(data)
	if text == json:
		return false
	if unchanged:
		missed += 1
		ModLoaderLog.warning(
			"shop run state changed without a change of its fingerprint; sent", LOG_NAME
		)
	json = text
	rev += 1
	_packed = {}
	return true


# json compressed (RunStateCodec.pack), once per rev. A copy: callers may keep or change it.
func pack() -> Dictionary:
	if _packed.empty():
		_packed = RunStateCodec.pack(json)
		packs += 1
	return _packed.duplicate()


# BaseShop.save_run_state's arguments: the shop's own part of the run state.
static func shop_args(shop: Node) -> Array:
	return [
		shop._shop_items,
		shop._reroll_count,
		shop._paid_reroll_count,
		shop._initial_free_rerolls,
		shop._free_rerolls,
		shop._item_steals,
	]


# Everything a mutation in the shop moves, as cheap values (ints and floats only: no object is
# kept). Sizes and the last element stand for the item lists, so the cost does not grow with
# them; weapons, offered and locked items are short and listed by instance.
# - buy / steal / dismantle (BaseShop.on_shop_item_bought / _stolen / _dismantled): the offered
#   items, gold (RunData.remove_currency), items (add_item_triggering_stat_gain_effects pushes
#   at the end) or weapons (add_weapon duplicates), steals, meca parts
# - reroll (_on_RerollButton_pressed): reroll counters, offered items, gold; its goldfish item
#   (fill_shop_items) and bone dice stats come with them
# - lock / unlock (ShopItem.change_lock_status -> RunData.lock_player_shop_item): locked items
# - ban (ShopItem.ban_item): ban tokens, banned items
# - combine / recycle / meca upgrade (RunData.combine_weapon, recycle_weapon,
#   meca_upgrade_weapon): weapon instances, gold, meca parts
# - endless toggle (CoopShopPlayerContainer._on_EndlessButton_toggled): RunData.is_endless_run
# - DLC mutations on equip (RunData.try_mutate_item_on_equip): items, recently_mutated
# Go, pages, colours, panel revisions and meca rolls are not run state: ShopSync's key has them.
static func fingerprint(shop: Node) -> Array:
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
	for args in shop_args(shop):
		values.append(args.size())
		for p in args.size():
			if args[p] is Array:  # offered items: [item, wave value]
				values.append(args[p].size())
				for entry in args[p]:
					values.append(_id(entry[0]))
					values.append(entry[1])
			else:
				values.append(args[p])
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
