extends Reference
# Suite shop_change: the host serializes the shop's run state only when it can have changed
# (sync/run_cache.gd). On a stream of its own (fake session, stepped by hand) and the real
# co-op shop: every kind of change the game makes in the shop moves the fingerprint and goes out
# once, serialized once and only its changed run parts compressed; view-only changes (Go, page,
# colours, meca roll) go out without serializing; an unchanged shop serializes nothing between
# safety-net checks; a change only the safety net can see (a stat written directly) still goes
# out and counts as missed, its warning naming the stat; a description shown (Effect.get_text
# adding custom args to an effect two players own) changes no part, and the client's copy shows
# the same text without doubled args; an applied intent goes out in the next frame, serialized
# once;
# peer_ready resends every part without compressing again. Prints the cost of a check before
# and after in a small and in late runs. The client's side of a changed state: its per-player
# keys follow the part ids (which panels it rebuilds), and what a whole run state costs it.
# (What a change sends and costs in parts: run_parts_tests.gd.)

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const RunCache := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_cache.gd")
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const EffectArgs := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/effect_args.gd"
)
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const PEER := 4343
const REMOTE := 1  # the player whose intents the host applies
const PISTOL := "weapon_pistol_1"
const LATE_ITEMS := 250
const LATE_WEAPONS := 6
const IDLE_CHECKS := 20

var _t: Node = null
var _sync: Node = null
var _cache = null  # ShopSync.run_cache
var _shop: Node = null
var _stream: Node = null  # the host stream of this suite
var _run := ""  # the run part ids last sent (var2str)
var _client = RunParts.Store.new()  # what a client has of the run, from what was sent
var _client_ok := true  # no body named a part the client lacked
var _client_ids := {}  # the run part ids last sent


func run(t: Node, together: Node):
	_t = t
	_sync = together.shop_sync
	_cache = _sync.run_cache
	_sync.set_process(false)  # driven by hand (no Steam session)
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	var saved_colors: Array = CoopService.bt_slot_colors.duplicate()
	yield(_small_run(), "completed")
	_end_stream(together)
	yield(_late_run(2), "completed")
	yield(_late_run(4), "completed")
	_sync._host_shop = null
	_cache.clear()
	CoopService.connected_players = saved_players
	CoopService.bt_slot_colors = saved_colors
	_sync.set_process(true)


# --- small run: what is detected, and how often the run is serialized ---


func _small_run():
	_build_run(2, 0)
	var pistol = _t._find_by_id(ItemService.weapons, PISTOL)
	RunData.players_data[0].weapons.clear()
	for _i in 3:
		RunData.add_weapon(pistol, 0)  # to combine, recycle and upgrade
	for p in 2:
		RunData.add_gold(5000, p)
	yield(_enter_shop(), "completed")
	_measure("small run, 2 players", 30)
	_test_client_keys()
	_cache.clear()  # as when the host enters the shop
	var session := StateStreamTests.FakeSession.new()
	session.transport = StateStreamTests.FakeTransport.new()
	session.peers[PEER] = {"ready": true}
	_stream = StateStream.new()
	_stream.setup(session)
	_stream.register_provider(StateStream.RUN_SHOP, _sync, _sync.CHECK_INTERVAL)
	_sync.state_stream = _stream  # host_apply_intent flushes this one
	_sync.run_sender.forget(PEER)  # the client has nothing yet
	var serialized: int = _cache.serialized
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		sent.size() == 1 and _cache.serialized == serialized + 1,
		"shop change: the first check serializes the run once and sends it"
	)
	_run = _run_of(sent)
	_test_idle()
	yield(_test_slot_changes(), "completed")
	yield(_test_weapon_changes(), "completed")
	_test_view_changes()
	yield(_test_dismantle(), "completed")
	yield(_test_meca(), "completed")
	_test_safety_net()
	_test_shown_text()
	yield(_test_intent(), "completed")
	_test_peer_ready()


func _test_idle() -> void:
	var serialized: int = _cache.serialized
	var sends := 0
	_cache._checked_msec = OS.get_ticks_msec()
	for _i in IDLE_CHECKS:
		_stream.step(1.0)  # a whole interval each: every one checks
		sends += _take().size()
	_t._check(
		sends == 0 and _cache.serialized == serialized,
		"shop change: %d checks of an unchanged shop serialize nothing" % IDLE_CHECKS
	)
	_age_safety_net()
	_stream.step(1.0)
	_t._check(
		_take().empty() and _cache.serialized == serialized + 1 and _cache.missed == 0,
		"shop change: the safety net serializes once, finds nothing, sends nothing"
	)


func _test_slot_changes():
	_expect_run("gold (RunData.add_gold)", funcref(self, "_add_gold"))
	var node = _offered(0)
	if node.item_data.is_lockable:
		node.change_lock_status(true)
		_expect_run("lock (ShopItem.change_lock_status)")
		node.change_lock_status(false)
		_expect_run("unlock")
	FocusEmulatorSignal.emit(node._button, "pressed", 0)
	yield(_frames(1), "completed")
	_expect_run("buy (the item's buy button)")
	yield(_buy_delay(), "completed")
	FocusEmulatorSignal.emit(_shop._get_reroll_button(0), "pressed", 0)
	yield(_frames(1), "completed")
	_expect_run("reroll (the reroll button)")
	_shop._item_steals[0] = 1
	_shop._get_shop_items_container(0).item_steals = 1
	_expect_run("a steal to spend (BaseShop._item_steals)")
	node = _offered(0)
	node.steal_item()
	yield(_frames(1), "completed")
	_expect_run("steal (ShopItem.steal_item)")
	yield(_buy_delay(), "completed")
	RunData.players_data[0].remaining_ban_token = 1
	_expect_run("a ban token")
	node = _offered(0)
	node._ban_button.activate()
	node.emit_signal("ban_item_pressed", node)
	_expect_run("ban (ban_item_pressed)")


func _test_weapon_changes():
	var popup = _shop._get_item_popup(0)
	popup.emit_signal("item_combine_button_pressed", RunData.get_player_weapons(0)[0])
	_sync.call_deferred("_settle_host_cursor", _shop, 0)  # as after an intent
	yield(_frames(1), "completed")
	_expect_run("combine (item popup)")
	popup.emit_signal("item_discard_button_pressed", RunData.get_player_weapons(0)[0])
	_sync.call_deferred("_settle_host_cursor", _shop, 0)
	yield(_frames(1), "completed")
	_expect_run("recycle (item popup)")
	var endless = _shop._get_coop_player_container(0).get("_endless_button")
	if endless == null:
		print("  info: no endless button in this shop, endless toggle not tested")
		return
	var was_visible: bool = endless.visible
	endless.visible = true
	endless.pressed = true
	_expect_run("endless on (the endless button)")
	endless.pressed = false
	_expect_run("endless off")
	endless.visible = was_visible


func _test_view_changes() -> void:
	FocusEmulatorSignal.emit(_shop._get_go_button(0), "pressed", 0)
	_expect_view("Go (the Go button)")
	_shop._clear_go_button_pressed(0)
	_expect_view("Go cleared")
	var panel = _shop._get_coop_player_container(0)
	panel.carousel.index = 1
	_expect_view("page")
	panel.carousel.index = 0
	_expect_view("page back")
	var colors: Array = CoopService.bt_slot_colors
	if colors.size() >= 2:
		var first = colors[0]
		colors[0] = colors[1]
		colors[1] = first
		_expect_view("colours")


# Meca weapons only exist with the DLC: a pistol marked as one stands in (local_shop_tests.gd).
func _test_dismantle():
	var node = _offered(0)
	var weapon = _t._find_by_id(ItemService.weapons, PISTOL).duplicate()
	weapon.is_meca = true
	weapon.meca_power = 1
	for entry in _shop._shop_items[0]:
		if entry[0] == node.item_data:
			entry[0] = weapon
	node.set_shop_item(weapon, node.wave_value)
	var effects: Dictionary = RunData.get_player_effects(0)
	effects[Keys.stat_evolution_hash] = 1
	_expect_run("a meca weapon offered")
	if not _shop._can_dismantle_with_shortcut(node, 0):
		print("  info: dismantle not offered here, not tested")
		return
	node._on_DismantleButton_pressed()
	yield(_frames(1), "completed")
	_expect_run("dismantle (the dismantle button)")
	yield(_buy_delay(), "completed")


func _test_meca():
	var dlc = MecaChoice.dlc_data()
	if dlc == null:
		print("  info: no %s data, meca roll and upgrade not tested" % MecaChoice.MECA_DLC)
		return
	var was_active: bool = MecaChoice.MECA_DLC in ProgressData.active_update_data
	if not was_active:
		ProgressData.active_update_data.push_back(MecaChoice.MECA_DLC)
	var weapon = RunData.get_player_weapons(0)[0]
	RunData.players_data[0].meca_parts += dlc.get_meca_upgrade_cost(weapon) + 1
	_expect_run("meca parts")
	var popup = _shop._get_item_popup(0)
	if MecaChoice.roll(popup, weapon, 0) == null:
		print("  info: %s cannot be mechanized, meca roll not tested" % weapon.my_id)
	else:
		_expect_view("meca roll (the popup's remembered options)")
		var upgraded = MecaChoice.take(popup, weapon, 0, 0)
		popup.emit_signal("item_meca_upgrade_selected", weapon, upgraded)
		yield(_frames(1), "completed")
		_expect_run("meca upgrade (item_meca_upgrade_selected)")
	if not was_active:
		ProgressData.active_update_data.erase(MecaChoice.MECA_DLC)


# A stat written directly (another mod's way; the game's own stat changes in the shop come with
# a change the fingerprint sees): only the safety net finds it, sends it and reports it.
func _test_safety_net() -> void:
	var serialized: int = _cache.serialized
	_cache._checked_msec = OS.get_ticks_msec()
	RunData.add_stat(Keys.stat_max_hp_hash, 1, 0)
	_stream.step(1.0)
	_t._check(
		_take().empty() and _cache.serialized == serialized,
		"shop change: a stat alone does not move the fingerprint"
	)
	_age_safety_net()
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		(
			sent.size() == 1
			and _run_of(sent) != _run
			and _cache.serialized == serialized + 1
			and _cache.missed == 1
		),
		"shop change: the safety net sends it once and reports a miss"
	)
	var warning: String = (
		"%s run state changed without a change of its fingerprint: p0.effects.stat_max_hp; sent"
		% _cache.label
	)
	_t._check(
		_cache.last_miss == warning,
		"shop change: the miss warning names the stat written directly (%s)" % _cache.last_miss
	)
	_run = _run_of(sent)
	RunData.remove_stat(Keys.stat_max_hp_hash, 1, 0)
	_age_safety_net()
	_stream.step(1.0)
	_run = _run_of(_take())
	_cache.missed = 0


# A description shown between two checks: Effect.get_text adds the effect's custom args the
# first time, and the effect is shared by both owners of the item. No run part changes, nothing
# goes out, no miss (sync/effect_args.gd). The client's copy came with the args: its own
# description adds none (no doubled args) and reads the same.
func _test_shown_text() -> void:
	var found := _unshown_args_item()
	_t._check(not found.empty(), "shop change: an item whose effect adds custom args when shown")
	if found.empty():
		return
	var item = found[0]
	var effect = item.effects[found[1]]
	for p in 2:
		RunData.add_item(item, p)
	_expect_run("an item with custom args bought by two players")
	var serialized: int = _cache.serialized
	var missed: int = _cache.missed
	_cache._checked_msec = OS.get_ticks_msec()
	_cache.last_miss = ""
	var text: String = effect.get_text(0)
	_age_safety_net()
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		sent.empty() and _cache.serialized == serialized + 1 and _cache.missed == missed,
		"shop change: a description shown changes no run part (%s)" % _cache.last_miss
	)
	_run = _run_of(sent) if not sent.empty() else _run
	var state: Dictionary = _client.state_for(_client_ids)
	var copy = null
	if not state.empty():
		var items: Array = state.players_data[1].items
		copy = items[items.size() - 1].effects[found[1]]
	_t._check(
		(
			copy != null
			and copy.get_text(0) == text
			and copy.custom_args.size() == effect.custom_args.size()
		),
		"shop change: the client's copy of the effect shows the same text without doubled args"
	)
	for p in 2:
		RunData.remove_item(item, p)
	_stream.step(1.0)
	_run = _run_of(_take())
	_cache.missed = missed


# A copy of an item with an effect whose description adds custom args, none of them shown yet
# (not shared with the game's item): [item, index of that effect], [] if there is none.
func _unshown_args_item() -> Array:
	for base in ItemService.items:
		var index := -1
		for i in base.effects.size():
			var probe = base.effects[i].duplicate()
			probe.custom_args = []
			probe._add_custom_args()
			if not probe.custom_args.empty():
				index = i
				break
		if index < 0:
			continue
		var item = base.duplicate()
		item.effects = []
		for effect in base.effects:
			var copy = effect.duplicate()
			copy.custom_args = effect.custom_args.duplicate()
			copy._custom_args_added = false
			if effect._custom_args_added:
				copy._remove_custom_args()
			item.effects.append(copy)
		return [item, index]
	return []


# An applied intent: no check in its own frame, one in the next, which serializes once (forced,
# whatever the fingerprint says) and sends the complete state.
func _test_intent():
	var slot := _offered_slot(REMOTE)
	var node = _shop._get_shop_items_container(REMOTE).get_shop_item_node(slot)
	_sync._update_seqs(_shop)
	var intent := {
		"shop_id": _sync._shop_id,
		"seq": _sync._seqs[REMOTE],
		"kind": "buy",
		"slot": slot,
		"id": node.item_data.my_id,
		"arg": -1,
	}
	var serialized: int = _cache.serialized
	var packs: int = _cache.packs
	var parts: int = _cache.parts.size()
	_t._check(_sync.host_apply_intent(_shop, REMOTE, intent), "shop change: buy intent applied")
	_stream.step(1.0)
	var early := _take()
	yield(_frames(1), "completed")
	_stream.step(0.0)  # no interval left: only the flush checks
	var sent := _take()
	_t._check(
		(
			early.empty()
			and sent.size() == 1
			and not node.active
			and not sent[0][2].slots[REMOTE][slot]
			and _run_of(sent) != _run
			and _cache.serialized == serialized + 1
			and _cache.packs > packs
			and _cache.packs < packs + parts
		),
		"shop change: an applied intent goes out in the next frame, serialized once, some parts packed"
	)
	_run = _run_of(sent)
	yield(_buy_delay(), "completed")
	var go := {"shop_id": _sync._shop_id, "seq": 0, "kind": "go", "slot": -1, "id": "", "arg": 1}
	serialized = _cache.serialized
	_t._check(_sync.host_apply_intent(_shop, REMOTE, go), "shop change: Go intent applied")
	yield(_frames(1), "completed")
	_stream.step(0.0)
	sent = _take()
	_t._check(
		(
			sent.size() == 1
			and sent[0][2].go[REMOTE]
			and _run_of(sent) == _run
			and _cache.serialized == serialized + 1
			and _cache.missed == 0
		),
		"shop change: Go by intent goes out, the forced check finds the run unchanged"
	)
	_shop._clear_go_button_pressed(REMOTE)
	_stream.step(1.0)
	_take()


# ShopSync's own peer_ready handler forces a check and forgets what the peer has, and the
# stream's resync (queued for its next step, after every peer_ready handler) is that check: the
# new peer gets the true run state, every part of it, serialized once and not compressed again
# when nothing changed.
func _test_peer_ready() -> void:
	var serialized: int = _cache.serialized
	var packs: int = _cache.packs
	_cache._checked_msec = OS.get_ticks_msec()
	_stream.session.emit_signal("peer_ready", PEER)
	_sync._on_peer_ready(PEER)
	_t._check(_take().empty(), "shop change: nothing goes out inside the peer_ready emission")
	_stream.step(0.0)
	var sent := _take()
	_t._check(
		sent.size() == 1 and _run_of(sent) == _run and _cache.packs == packs,
		"shop change: peer_ready resends the same run, not compressed again"
	)
	_t._check(
		sent.size() == 1 and sent[0][2].run.parts.size() == _cache.parts.size(),
		"shop change: peer_ready resends every run part"
	)
	_t._check(
		_cache.serialized == serialized + 1,
		"shop change: the resync after peer_ready serializes once"
	)
	_stream.step(1.0)
	_t._check(
		_take().empty() and _cache.serialized == serialized + 1 and _cache.packs == packs,
		"shop change: the check after it serializes nothing and sends nothing"
	)


# --- late runs: the cost ---


func _late_run(players: int):
	_build_run(players, LATE_ITEMS)
	yield(_enter_shop(), "completed")
	_measure("late endless run, %d players, %d items each" % [players, LATE_ITEMS], 5)
	_measure_miss("late endless run, %d players" % players)
	_measure_settle("late endless run, %d players" % players)


# Prints the cost of a check: before (the run serialized to JSON on every check, as the key was),
# now with nothing changed, the safety net's check and a change (serialize, print, pack).
func _measure(label: String, slow_calls: int) -> void:
	var section := StateStream.RUN_SHOP
	_sync.state_key(section)
	var old_keys := []
	var started := OS.get_ticks_usec()
	for _i in slow_calls:
		var json := RunStateCodec.encode_json(_sync.shop_args(_shop))
		old_keys.append(json + var2str(_sync._shop_parts().values()))
		old_keys.clear()
	var before := (OS.get_ticks_usec() - started) / float(slow_calls)
	var calls := 200
	var serialized: int = _cache.serialized
	_cache._checked_msec = OS.get_ticks_msec()
	started = OS.get_ticks_usec()
	for _i in calls:
		_sync.state_key(section)
	var now := (OS.get_ticks_usec() - started) / float(calls)
	_t._check(_cache.serialized == serialized, "%s: unchanged checks serialize nothing" % label)
	started = OS.get_ticks_usec()
	for _i in slow_calls:
		_cache.force()
		_sync.state_key(section)
	var net := (OS.get_ticks_usec() - started) / float(slow_calls)
	RunData.add_gold(1, 0)
	started = OS.get_ticks_usec()
	_sync.state_key(section)
	_sync.state_body(section)
	var change := OS.get_ticks_usec() - started
	print(
		(
			"  info: shop check, %s: before %.0f usec per check, now %.0f usec unchanged;"
			+ " safety net %.0f usec once a second; a change %.0f usec (%d B of JSON)"
		)
		% [label, before, now, net, change, _cache.text_size()]
	)
	_measure_client(label, slow_calls <= 5)


# What making every effect's custom args the same costs each serialization (EffectArgs.settle:
# a walk over every effect the run state serializes, each shared one once).
func _measure_settle(label: String) -> void:
	var state: Dictionary = ProgressData.callv("get_run_state", _sync.shop_args(_shop))
	var started := OS.get_ticks_usec()
	var added := EffectArgs.settle(state, true)
	var usec := OS.get_ticks_usec() - started
	print(
		"  info: effect args, %s: %d usec per serialization (%d effects given args)"
		% [label, usec, added]
	)


# What naming a miss costs on top of the check that finds it (RunCache.miss_paths: the changed
# parts' old and new text parsed and compared): a stat ("p" part) and a weapon's field ("g"
# part, the big one), both written directly; the warning names both down to the field.
func _measure_miss(label: String) -> void:
	var section := StateStream.RUN_SHOP
	_cache.force()
	_sync.state_key(section)
	var before: Dictionary = _cache.parts
	var missed: int = _cache.missed
	var weapon = RunData.players_data[0].weapons[0]
	RunData.add_stat(Keys.stat_max_hp_hash, 1, 0)
	weapon.dmg_dealt_last_wave += 1
	_cache.force()
	var started := OS.get_ticks_usec()
	_sync.state_key(section)
	var check := OS.get_ticks_usec() - started
	started = OS.get_ticks_usec()
	var paths := RunCache.miss_paths(before, _cache.parts)
	var naming := OS.get_ticks_usec() - started
	var expected := ["g0.weapons[0].dmg_dealt_last_wave", "p0.effects.stat_max_hp"]
	_t._check(
		_cache.missed == missed + 1 and paths == expected,
		"%s: a miss names the stat and the weapon's field (%s)" % [label, ", ".join(paths)]
	)
	print(
		(
			"  info: shop miss, %s: naming it %d usec, on top of its check %d usec"
			% [label, naming, check]
		)
	)
	RunData.remove_stat(Keys.stat_max_hp_hash, 1, 0)
	weapon.dmg_dealt_last_wave -= 1
	_cache.force()
	_sync.state_key(section)
	_cache.missed = missed


# What a whole run state costs a client before its panels are rebuilt (each state before parts,
# now the first one and a resync): the JSON parsed, the players' keys (before parts: as JSON
# text), the game's deserializer. In one frame, for every client.
func _measure_client(label: String, late: bool) -> void:
	var payload := RunStateCodec.encode(_sync.shop_args(_shop))
	var started := OS.get_ticks_usec()
	var raw := RunStateCodec.parse(payload)
	var parse := OS.get_ticks_usec() - started
	started = OS.get_ticks_usec()
	var texts := []
	for p in raw.players_data.size():
		var data: Dictionary = raw.players_data[p]
		var offered := [_sync._at(raw.shop_items, p), _sync._at(raw.item_steals, p)]
		texts.append(to_json(data) + to_json([data.weapons, data.items]) + to_json(offered))
	var before := OS.get_ticks_usec() - started
	var ids: Dictionary = _cache.all().ids
	var common: Dictionary = RunParts.split(raw).c
	started = OS.get_ticks_usec()
	var keys: Array = _sync.player_keys(ids, common)
	var now := OS.get_ticks_usec() - started
	started = OS.get_ticks_usec()
	RunStateCodec.deserialize(raw)
	var deserialize := OS.get_ticks_usec() - started
	print(
		(
			"  info: shop state on a client, %s: %d B compressed; parse %d usec, player keys"
			+ " %d usec (as JSON text before: %d), deserialize %d usec"
		)
		% [label, payload.data.size(), parse, now, before, deserialize]
	)
	if late:
		_t._check(
			keys.size() == texts.size() and now * 3 < before,
			"%s: the client's player keys cost a fraction of the JSON text" % label
		)


# The client rebuilds a panel only when its part of the run state changed
# (ShopSync.player_keys): the keys follow the ids of the player's run parts and the content of
# its offered items, nested values included.
func _test_client_keys() -> void:
	var data := RunStateCodec.serialize(_sync.shop_args(_shop))
	var parts := RunParts.split(data)
	var ids: Dictionary = RunParts.pack_all(data).ids
	var raw: Dictionary = JSON.parse(JSON.print(parts.c)).result
	var keys: Array = _sync.player_keys(ids, raw)
	var again: Array = _sync.player_keys(RunParts.pack_all(data).ids, raw.duplicate(true))
	_t._check(
		keys.size() == 2 and var2str(keys) == var2str(again),
		"player keys: the same state packed twice gives the same keys"
	)
	parts.p0["bt_test"] = 1.0
	ids.p0 = RunParts.entry(parts.p0, hash(parts.p0)).id
	var player: Array = _sync.player_keys(ids, raw)
	_t._check(
		(
			player[0].data != keys[0].data
			and player[0].gear == keys[0].gear
			and player[0].items == keys[0].items
			and var2str(player[1]) == var2str(keys[1])
		),
		"player keys: a value of one player changes that player's data key only"
	)
	var weapons: Array = parts.g1.weapons
	weapons[0] = [weapons[0], 1.0]
	ids.g1 = RunParts.entry(parts.g1, hash(parts.g1)).id
	var gear: Array = _sync.player_keys(ids, raw)
	_t._check(
		(
			gear[1].gear != player[1].gear
			and gear[1].data != player[1].data
			and gear[1].items == player[1].items
			and var2str(gear[0]) == var2str(player[0])
		),
		"player keys: a change inside a weapon changes its owner's gear and data keys"
	)
	var offered: Array = raw.shop_items[0]
	offered[0] = [offered[0], 1.0]
	var items: Array = _sync.player_keys(ids, raw)
	_t._check(
		(
			items[0].items != gear[0].items
			and items[0].data == gear[0].data
			and var2str(items[1]) == var2str(gear[1])
		),
		"player keys: a change inside an offered item changes that player's items key only"
	)


# --- helpers ---


func _build_run(players: int, items: int) -> void:
	CoopService.connected_players.clear()
	for i in players:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(players)
	var pool: Array = ItemService.items
	var weapons: Array = ItemService.weapons
	for p in players:
		RunData.add_character(ItemService.characters[p], p)
		var count := LATE_WEAPONS if items > 0 else 1
		for w in count:
			RunData.add_weapon(weapons[(p + w * 7) % weapons.size()], p)
		for i in items:
			RunData.add_item(pool[(i * 13 + p) % pool.size()], p)
		RunData.add_gold(200, p)
	RunData.current_wave = 40 if items > 0 else 2
	RunData.is_endless_run = items > 0


func _enter_shop():
	var tree: SceneTree = _t.get_tree()
	tree.change_scene(RunData.get_shop_scene_path())
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	_shop = tree.current_scene
	_sync._host_shop = _shop
	_sync._shop_id += 1


func _end_stream(together: Node) -> void:
	_sync.state_stream = together.state_stream
	var session: Node = _stream.session
	_stream.free()
	session.free()
	_stream = null


# One check after a change of the run state: sent once, serialized once, found by the
# fingerprint (the safety net is not due), only some parts packed again.
func _expect_run(label: String, change: FuncRef = null) -> void:
	if change != null:
		change.call_func()
	var serialized: int = _cache.serialized
	var packs: int = _cache.packs
	var parts: int = _cache.parts.size()
	_cache._checked_msec = OS.get_ticks_msec()
	_stream.step(1.0)
	var sent := _take()
	var run := _run_of(sent)
	_t._check(
		(
			sent.size() == 1
			and run != _run
			and _cache.serialized == serialized + 1
			and _cache.packs > packs
			and _cache.packs < packs + parts
			and _cache.missed == 0
		),
		"shop change: %s detected, serialized once, some parts packed" % label
	)
	if sent.size() == 1:
		_run = run
	_check_client("shop change: " + label)


# One check after a change of the view only: sent once, the run not serialized.
func _expect_view(label: String) -> void:
	var serialized: int = _cache.serialized
	_cache._checked_msec = OS.get_ticks_msec()
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		sent.size() == 1 and _run_of(sent) == _run and _cache.serialized == serialized,
		"shop change: %s goes out without serializing the run" % label
	)
	_check_client("shop change: " + label)


func _add_gold() -> void:
	RunData.add_gold(3, 0)


func _age_safety_net() -> void:
	_cache._checked_msec = OS.get_ticks_msec() - RunCache.SAFETY_NET_MSEC


# An active slot of player p that a press buys: an item when there is one, else a weapon the
# player can take; never a meca item (a press only asks for its effect choice). Random rolls
# offered one of those first and the purchase then bought nothing. -1 when there is none.
func _offered_slot(p: int) -> int:
	var container = _shop._get_shop_items_container(p)
	var fallback := -1
	for slot in container._shop_items.size():
		var node = container.get_shop_item_node(slot)
		if not node.active or node.item_data == null or node.item_data.is_meca:
			continue
		if node.item_data.get_category() == Category.ITEM:
			return slot
		if fallback < 0 and container._can_weapon_be_bought(node):
			fallback = slot
	return fallback


func _offered(p: int) -> Node:
	return _shop._get_shop_items_container(p).get_shop_item_node(_offered_slot(p))


# The run part ids of the last message sent (var2str), "" if none.
func _run_of(sent: Array) -> String:
	if sent.empty() or typeof(sent[-1][2]) != TYPE_DICTIONARY:
		return ""
	return var2str(sent[-1][2].run.ids)


# What the host sent since the last call, as [steam_id, revision, body]. The client's store
# takes each body's run parts, as a client does.
func _take() -> Array:
	var messages := []
	for sent in _stream.session.sent:
		messages.append([sent[0], sent[2][1], sent[2][2]])
		if typeof(sent[2][2]) == TYPE_DICTIONARY:
			_client_ok = _client.ingest(sent[2][2].run) and _client_ok
			_client_ids = sent[2][2].run.ids
	_stream.session.sent.clear()
	return messages


# The client's run parts, joined and printed, are the host's run state as JSON (no part
# missing, every value as the whole text had it).
func _check_client(label: String) -> void:
	var text := JSON.print(RunParts.join(_client.raws(_client_ids)))
	_t._check(
		_client_ok and text == RunStateCodec.encode_json(_sync.shop_args(_shop)),
		"%s: the client's run parts make the host's run state" % label
	)


# ShopItemsContainer ignores presses for 0.05 s after a buy, steal or dismantle.
func _buy_delay():
	yield(_t.get_tree().create_timer(0.1), "timeout")


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")
