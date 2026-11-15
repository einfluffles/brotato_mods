extends Reference
# Suite upgrades_change: the host serializes the run state of the level-up / crate panels
# (section upgrades) only when it can have changed (UpgradesSync.run_cache, sync/run_cache.gd).
# On a stream of its own (fake session, stepped by hand) and the host's real battle scene with
# its panels up (the wave cleaned up as the game does before them): every kind of change the
# panels make to the run is detected and goes out once, serialized and compressed once; pages,
# revisions and meca rolls go out without serializing; an unchanged run serializes nothing
# between safety-net checks; a change only the safety net can see goes out and counts as missed;
# an applied intent forces the next check; peer_ready resends without compressing again; the
# cache is gone with the battle. Prints the cost of a send before and after, and of a typical
# level-up sequence, in a small and in late runs.

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
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const PEER := 4545
const PISTOL := "weapon_pistol_1"
const CRATE := "consumable_item_box"
const LATE_ITEMS := 250
const LATE_WEAPONS := 6
const IDLE_CHECKS := 20
const BUTTON_DELAY_SEC := 0.15  # UpgradesUIPlayerContainer's ButtonDelayTimer: 0.1 s

var _t: Node = null
var _together: Node = null
var _sync: Node = null
var _cache = null  # UpgradesSync.run_cache
var _main: Node = null
var _ui: Node = null
var _stream: Node = null  # the host stream of this suite
var _run := PoolByteArray()  # the run bytes last sent


func run(t: Node, together: Node):
	_t = t
	_together = together
	_sync = together.upgrades_sync
	_cache = _sync.run_cache
	together.battle_host.set_process(false)  # driven by hand: no Steam session
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	var saved_holding: bool = ProgressData.settings.holding_button
	ProgressData.settings.holding_button = false  # a ban at once (see _test_crate)
	_start_stream()
	yield(_small_run(), "completed")
	yield(_late_run(2), "completed")
	yield(_late_run(4), "completed")
	yield(_test_battle_end(), "completed")
	_end_stream()
	ProgressData.settings.holding_button = saved_holding
	CoopService.connected_players = saved_players
	together.battle_host.set_process(true)


# --- small run: what is detected, and how often the run is serialized ---


# Player 0: two crates (recycled, banned), then two level-ups. Player 1 (crates give weapons,
# three pistols): a crate weapon, then a level-up.
func _small_run():
	_build_run(2, 0)
	RunData.get_player_effects(1)[Keys.effect_crate_give_weapon_hash] = 1
	RunData.players_data[1].weapons.clear()
	for _i in 3:
		RunData.add_weapon(_t._find_by_id(ItemService.weapons, PISTOL), 1)
	yield(_enter_battle(), "completed")
	_show([[_crate(0), _crate(0)], [_crate(1)]], [[_level(0, 2), _level(0, 3)], [_level(1, 2)]])
	_measure("small run, 2 players", 20)
	_cache.clear()  # as when the panels come up
	var serialized: int = _cache.serialized
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		sent.size() == 1 and _cache.serialized == serialized + 1 and _cache.packs > 0,
		"upgrades change: the first check serializes the run once and sends it"
	)
	_run = _run_of(sent)
	_test_idle()
	_test_views()
	_test_weapons()
	yield(_test_crate(), "completed")
	yield(_test_level_ups(), "completed")
	_test_safety_net()
	_test_peer_ready()
	_test_lobby_left()


func _test_idle() -> void:
	var serialized: int = _cache.serialized
	var sends := 0
	_cache._checked_msec = OS.get_ticks_msec()
	for _i in IDLE_CHECKS:
		_stream.step(1.0)  # a whole interval each: every one checks
		sends += _take().size()
	_t._check(
		sends == 0 and _cache.serialized == serialized,
		"upgrades change: %d checks of unchanged panels serialize nothing" % IDLE_CHECKS
	)
	_age_safety_net()
	_stream.step(1.0)
	_t._check(
		_take().empty() and _cache.serialized == serialized + 1 and _cache.missed == 0,
		"upgrades change: the safety net serializes once, finds nothing, sends nothing"
	)


func _test_views() -> void:
	var other = _ui._get_player_container(1)
	other.carousel.index = 1
	_expect_view("page")
	_sync.host_apply_focus(_ui, 1, 0, [])
	_expect_view("page back (UPGRADE_FOCUS)")
	_sync._seq_keys[0] = ""  # the next check bumps player 0's revision, nothing else changes
	var seq: int = _sync._seqs[0]
	_expect_view("panel revision")
	_t._check(_sync._seqs[0] == seq + 1, "upgrades change: the revision did move")
	_expect_run("gold (RunData.add_gold)", funcref(self, "_add_gold"))


# Player 1's crate weapon popup, by intent: combine, recycle, meca upgrade (DLC data only).
func _test_weapons() -> void:
	_expect_intent("combine (weapon_combine intent)", 1, "weapon_combine", PISTOL, {"weapon": 0})
	_expect_intent("recycle (weapon_discard intent)", 1, "weapon_discard", PISTOL, {"weapon": 0})
	var dlc = MecaChoice.dlc_data()
	if dlc == null:
		print("  info: no %s data, meca roll and upgrade not tested" % MecaChoice.MECA_DLC)
		return
	var was_active: bool = MecaChoice.MECA_DLC in ProgressData.active_update_data
	if not was_active:
		ProgressData.active_update_data.push_back(MecaChoice.MECA_DLC)
	var weapon = RunData.get_player_weapons(1)[0]
	RunData.players_data[1].meca_parts = dlc.get_meca_upgrade_cost(weapon) + 1
	_expect_run("meca parts")
	var roll := _intent(1, "weapon_meca_roll", weapon.my_id, {"weapon": 0})
	if not _sync.host_apply_intent(_ui, 1, roll):
		print("  info: %s cannot be mechanized, meca roll not tested" % weapon.my_id)
	else:
		_expect_view("meca roll (weapon_meca_roll intent)")
		var pick := _intent(1, "weapon_meca", weapon.my_id, {"weapon": 0})
		pick.meca = 0
		_t._check(_sync.host_apply_intent(_ui, 1, pick), "upgrades change: meca pick applied")
		_expect_run("meca upgrade (weapon_meca intent)")
	if not was_active:
		ProgressData.active_update_data.erase(MecaChoice.MECA_DLC)


# Player 0's crates: recycled by intent, then banned (ban token and button given here: the
# headless profile has not unlocked bans); player 1 takes its crate weapon.
func _test_crate():
	var item = _ui._get_player_container(0)._item_data
	_expect_intent("discard (discard intent)", 0, "discard", item.my_id)
	yield(_button_delay(), "completed")
	RunData.players_data[0].remaining_ban_token = 1
	_expect_run("a ban token")
	var container = _ui._get_player_container(0)
	container._ban_button.visible = true
	_expect_intent("ban (ban intent)", 0, "ban", container._item_data.my_id)
	var weapons: int = RunData.get_player_weapons(1).size()
	_expect_intent("take (take intent)", 1, "take", _ui._get_player_container(1)._item_data.my_id)
	_t._check(
		RunData.get_player_weapons(1).size() == weapons + 1,
		"upgrades change: the crate weapon was taken"
	)


# Level-ups: a reroll by intent, a second press inside the button delay (the game ignores it:
# the forced check finds what a stat written meanwhile changed, a miss of the fingerprint), the
# host's own press (no intent, nothing forced), an absent player's automatic choice and the
# last choice by intent.
func _test_level_ups():
	yield(_button_delay(), "completed")
	_expect_intent("reroll (reroll intent)", 0, "reroll", "")
	var reroll := _intent(0, "reroll", "")
	RunData.add_stat(Keys.stat_luck_hash, 1, 0)  # no fingerprint value moves
	var serialized: int = _cache.serialized
	_cache._checked_msec = OS.get_ticks_msec()
	_t._check(
		_sync.host_apply_intent(_ui, 0, reroll) and _cache._force_frame >= 0,
		"upgrades change: an applied intent forces the next check"
	)
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		(
			sent.size() == 1
			and _run_of(sent) != _run
			and _cache.serialized == serialized + 1
			and _cache.missed == 1
		),
		"upgrades change: the forced check sends what only it could see (a miss)"
	)
	_run = _run_of(sent)
	RunData.remove_stat(Keys.stat_luck_hash, 1, 0)
	_age_safety_net()
	_stream.step(1.0)  # the safety net sends the stat back (a miss too)
	_run = _run_of(_take())
	_cache.missed = 0
	yield(_button_delay(), "completed")
	var container = _ui._get_player_container(0)
	container._on_choose_button_pressed(container._old_upgrades[0])
	_t._check(_cache._force_frame < 0, "upgrades change: the host's own press forces nothing")
	_expect_run("choose (the host's own press)")
	_together.absent_players.resolve_panel(_ui._get_player_container(1))
	_expect_run("choose (an absent player's automatic choice)")
	yield(_button_delay(), "completed")
	var last = _ui._get_player_container(0)._old_upgrades[0]
	_expect_intent("choose (choose intent)", 0, "choose", last.my_id)
	_t._check(
		_sync.capture(_ui) == [["done"], ["done"]],
		"upgrades change: every panel done (%s)" % [_sync.capture(_ui)]
	)


# A stat written directly (another mod's way; the game's own changes on the panels come with a
# change the fingerprint sees): only the safety net finds it, sends it and reports it.
func _test_safety_net() -> void:
	var serialized: int = _cache.serialized
	_cache._checked_msec = OS.get_ticks_msec()
	RunData.add_stat(Keys.stat_luck_hash, 1, 1)
	_stream.step(1.0)
	_t._check(
		_take().empty() and _cache.serialized == serialized,
		"upgrades change: a stat alone does not move the fingerprint"
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
		"upgrades change: the safety net sends it once and reports a miss"
	)
	_run = _run_of(sent)
	RunData.remove_stat(Keys.stat_luck_hash, 1, 1)
	_age_safety_net()
	_stream.step(1.0)
	_run = _run_of(_take())
	_cache.missed = 0


# UpgradesSync's own peer_ready handler forces a check, and the stream's resync (its next step)
# is that check: the new peer gets the true run, serialized once, not compressed again.
func _test_peer_ready() -> void:
	var serialized: int = _cache.serialized
	var packs: int = _cache.packs
	_cache._checked_msec = OS.get_ticks_msec()
	_stream.session.emit_signal("peer_ready", PEER)
	_sync._on_peer_ready(PEER)
	_t._check(_take().empty(), "upgrades change: nothing goes out inside the peer_ready emission")
	_stream.step(0.0)
	var sent := _take()
	_t._check(
		(
			sent.size() == 1
			and _run_of(sent) == _run
			and _cache.packs == packs
			and _cache.serialized == serialized + 1
		),
		"upgrades change: peer_ready resends the same run, checked once, not compressed again"
	)
	_stream.step(1.0)
	_t._check(
		_take().empty() and _cache.serialized == serialized + 1 and _cache.packs == packs,
		"upgrades change: the check after it serializes nothing and sends nothing"
	)
	var body: Dictionary = _sync.state_body(StateStream.UPGRADES)
	_t._check(
		body.run.data == _run and _cache.serialized == serialized + 1 and _cache.packs == packs,
		"upgrades change: a body built alone reuses the run"
	)
	RunData.add_gold(1, 0)
	body = _sync.state_body(StateStream.UPGRADES)  # no state_key before it
	_t._check(
		body.run.data != _run and _cache.packs == packs + 1,
		"upgrades change: a body built alone after a change carries the new run"
	)
	_stream.step(1.0)
	_run = _run_of(_take())


func _test_lobby_left() -> void:
	_sync._on_lobby_left()
	_t._check(_cache.json == "" and _cache._screen_id == 0, "upgrades change: lobby_left drops it")
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		sent.size() == 1 and _run_of(sent) == _run,
		"upgrades change: after lobby_left the next check serializes the same run again"
	)


# --- late runs: the cost ---


func _late_run(players: int):
	yield(_blank_scene(), "completed")  # the old battle must not see the new run's players
	_build_run(players, LATE_ITEMS)
	yield(_enter_battle(), "completed")
	var consumables := []
	var upgrades := []
	for p in players:
		consumables.append([_crate(p)])
		upgrades.append([_level(p, 30), _level(p, 31)])
	_show(consumables, upgrades)
	var label := "late endless run, %d players, %d items each" % [players, LATE_ITEMS]
	var encode: float = _measure(label, 5)
	_stream.step(1.0)
	_run = _run_of(_take())
	yield(_sequence(label, players, encode), "completed")


# A typical level-up sequence, on the stream: every player looks at its gear page and back,
# takes its crate item, rerolls and chooses twice; player 0 presses on the host, the others send
# intents; a peer joins in the middle. Counts the sends (each encoded the run before) and the
# time the stream's checks take now.
func _sequence(label: String, players: int, encode: float):
	var serialized: int = _cache.serialized
	var packs: int = _cache.packs
	var sends := 0
	var usec := 0
	for step in 6:
		for p in players:
			var container = _ui._get_player_container(p)
			match step:
				0, 1:
					container.carousel.index = 1 - step
				2:
					_decide(p, "take", container._item_data.my_id)
				3:
					_decide(p, "reroll", "")
				_:
					_decide(p, "choose", container._old_upgrades[0].my_id)
			var started := OS.get_ticks_usec()
			_stream.step(1.0)
			usec += OS.get_ticks_usec() - started
			sends += _take().size()
		if step == 3:
			_stream.session.emit_signal("peer_ready", PEER)
			_sync._on_peer_ready(PEER)
			var resync_started := OS.get_ticks_usec()
			_stream.step(0.0)
			usec += OS.get_ticks_usec() - resync_started
			sends += _take().size()
		if step >= 2:
			yield(_button_delay(), "completed")
	var done := true
	for entry in _sync.capture(_ui):
		done = done and entry == ["done"]
	_t._check(done, "%s: the level-up sequence ends with every panel done" % label)
	print(
		(
			"  info: upgrades sequence, %s: %d sends, before %d encodes (%.0f ms);"
			+ " now %d encodes, %d checks without one, %.0f ms in the stream's checks"
		)
		% [
			label,
			sends,
			sends,
			sends * encode / 1000.0,
			_cache.packs - packs,
			_cache.serialized - serialized - (_cache.packs - packs),
			usec / 1000.0,
		]
	)


# Prints the cost of a send before (RunStateCodec.encode in every body), and now: the key's
# check with nothing changed (and of it, capture() of the panels), the safety net's check once
# a second, a send that reuses the run (a page, a resend) and a change (serialize, print, pack).
# Returns the encode's usec.
func _measure(label: String, slow_calls: int) -> float:
	var section := StateStream.UPGRADES
	_sync.state_key(section)
	var started := OS.get_ticks_usec()
	for _i in slow_calls:
		RunStateCodec.encode()
	var before := (OS.get_ticks_usec() - started) / float(slow_calls)
	var calls := 200
	var serialized: int = _cache.serialized
	_cache._checked_msec = OS.get_ticks_msec()
	started = OS.get_ticks_usec()
	for _i in calls:
		_sync.state_key(section)
	var key := (OS.get_ticks_usec() - started) / float(calls)
	started = OS.get_ticks_usec()
	for _i in calls:
		_sync.capture(_ui)
	var capture := (OS.get_ticks_usec() - started) / float(calls)
	started = OS.get_ticks_usec()
	for _i in calls:
		_sync.state_body(section)
	var reuse := (OS.get_ticks_usec() - started) / float(calls)
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
	var plain := true
	for value in _cache._fingerprint:
		plain = plain and not typeof(value) in [TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY]
	_t._check(plain, "%s: the fingerprint keeps no object" % label)
	print(
		(
			"  info: upgrades send, %s: before %.0f usec (the run encoded in every body);"
			+ " now key %.0f usec unchanged (capture %.0f), a send reusing the run %.0f usec,"
			+ " safety net %.0f usec once a second, a change %.0f usec (%d B of JSON)"
		)
		% [label, before, key, capture, reuse, net, change, _cache.json.length()]
	)
	return before


# --- the battle ends ---


# The next scene replaces the battle (nobody calls a cleanup): the cache is dropped and keeps
# nothing of the wave.
func _test_battle_end():
	_t._check(_cache.json != "", "upgrades change: a run is cached while the panels show")
	yield(_blank_scene(), "completed")
	_t._check(
		not _together.battle_host.is_in_battle()
		and _cache.json == ""
		and _cache._screen_id == 0
		and _cache._packed.empty()
		and _cache._fingerprint.empty(),
		"upgrades change: the cache is gone with the battle"
	)
	_t._check(_sync.state_key(StateStream.UPGRADES) == "", "upgrades change: section inactive")
	_main = null
	_ui = null


# --- helpers ---


# A scene with nothing in it, changed to like the game changes scenes (the battle is gone first).
func _blank_scene():
	var tree: SceneTree = _t.get_tree()
	var blank := Node.new()
	blank.name = "UpgradesChangeBlank"
	var packed := PackedScene.new()
	packed.pack(blank)
	blank.free()
	tree.change_scene_to(packed)
	for _i in 3:
		yield(tree, "idle_frame")


func _start_stream() -> void:
	var session := StateStreamTests.FakeSession.new()
	session.transport = StateStreamTests.FakeTransport.new()
	session.peers[PEER] = {"ready": true}
	_stream = StateStream.new()
	_stream.setup(session)
	_stream.register_provider(StateStream.UPGRADES, _sync, _sync.CHECK_INTERVAL)


func _end_stream() -> void:
	var session: Node = _stream.session
	_stream.free()
	session.free()
	_stream = null


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
		RunData.add_gold(5000, p)
	RunData.current_wave = 40 if items > 0 else 3
	RunData.is_endless_run = items > 0


# The host's battle scene, cleaned up the way main.clean_up_room leaves it for the panels: no
# wave timer, no enemies, players idle (no regeneration, no pickups).
func _enter_battle():
	var tree: SceneTree = _t.get_tree()
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	_main = tree.current_scene
	_together.battle_host._start_battle(_main)
	_main._wave_timer.stop()
	_main._entity_spawner.clean_up_room()
	_main._wave_manager.clean_up_room()
	for player in _main._players:
		if is_instance_valid(player):
			player.on_room_cleanup()
	yield(tree.create_timer(0.3), "timeout")
	_ui = _main.get("_coop_upgrades_ui")


# UpgradesUI.show_options with per player lists (padded to the UI's four players).
func _show(consumables: Array, upgrades: Array) -> void:
	while consumables.size() < 4:
		consumables.append([])
	while upgrades.size() < 4:
		upgrades.append([])
	_ui.show_options(consumables, upgrades)


func _crate(p: int):
	var crate = UpgradesUI.ConsumableToProcess.new()
	crate.consumable_data = _t._find_by_id(ItemService.consumables, CRATE)
	crate.player_index = p
	return crate


func _level(p: int, level: int):
	var upgrade = UpgradesUI.UpgradeToProcess.new()
	upgrade.level = level
	upgrade.player_index = p
	return upgrade


# An UPGRADE_INTENT from player p for what its panel shows now.
func _intent(p: int, kind: String, id: String, fields := {}) -> Dictionary:
	_sync._update_seqs(_ui, _sync.capture(_ui))
	var intent := {
		"battle_id": _together.battle_host._battle_id,
		"seq": _sync._seqs[p],
		"kind": kind,
		"id": id,
		"meca": -1,
	}
	for field in fields:
		intent[field] = fields[field]
	return intent


# Player 0 presses on the host's own panel; the others send intents.
func _decide(p: int, kind: String, id: String) -> void:
	if p > 0:
		_sync.host_apply_intent(_ui, p, _intent(p, kind, id))
		return
	var container = _ui._get_player_container(0)
	match kind:
		"take":
			container._on_TakeButton_pressed()
		"reroll":
			container._on_RerollButton_pressed()
		"choose":
			container._on_choose_button_pressed(container._old_upgrades[0])


# An applied intent and the check after it (UpgradesSync._on_message flushes): sent once,
# serialized and packed once although the check was forced and the fingerprint moved.
func _expect_intent(label: String, p: int, kind: String, id: String, fields := {}) -> void:
	var applied: bool = _sync.host_apply_intent(_ui, p, _intent(p, kind, id, fields))
	_t._check(applied and _cache._force_frame >= 0, "upgrades change: %s applied, forced" % label)
	_expect_run(label)


# One check after a change of the run state: sent once, serialized and packed once, found by
# the fingerprint or the forced check (the safety net is not due).
func _expect_run(label: String, change: FuncRef = null) -> void:
	if change != null:
		change.call_func()
	var serialized: int = _cache.serialized
	var packs: int = _cache.packs
	_cache._checked_msec = OS.get_ticks_msec()
	_stream.step(1.0)
	var sent := _take()
	var run := _run_of(sent)
	_t._check(
		(
			sent.size() == 1
			and run != _run
			and _cache.serialized == serialized + 1
			and _cache.packs == packs + 1
			and _cache.missed == 0
		),
		"upgrades change: %s detected, serialized and packed once" % label
	)
	if sent.size() == 1:
		_run = run


# One check after a change of the view only: sent once, the run not serialized.
func _expect_view(label: String) -> void:
	var serialized: int = _cache.serialized
	var packs: int = _cache.packs
	_cache._checked_msec = OS.get_ticks_msec()
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		(
			sent.size() == 1
			and _run_of(sent) == _run
			and _cache.serialized == serialized
			and _cache.packs == packs
		),
		"upgrades change: %s goes out without serializing the run" % label
	)


func _add_gold() -> void:
	RunData.add_gold(3, 0)


func _age_safety_net() -> void:
	_cache._checked_msec = OS.get_ticks_msec() - RunCache.SAFETY_NET_MSEC


# The run bytes of the last message sent, empty if none.
func _run_of(sent: Array) -> PoolByteArray:
	if sent.empty() or typeof(sent[-1][2]) != TYPE_DICTIONARY:
		return PoolByteArray()
	return sent[-1][2].run.data


# What the host sent since the last call, as [steam_id, revision, body].
func _take() -> Array:
	var messages := []
	for sent in _stream.session.sent:
		messages.append([sent[0], sent[2][1], sent[2][2]])
	_stream.session.sent.clear()
	return messages


func _button_delay():
	yield(_t.get_tree().create_timer(BUTTON_DELAY_SEC), "timeout")
