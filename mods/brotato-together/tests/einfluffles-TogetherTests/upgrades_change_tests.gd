extends Reference
# Suite upgrades_change: the host serializes the run state of the level-up / crate panels (section
# upgrades) only when it can have changed (UpgradesSync.run_cache, sync/run_cache.gd), and a client
# applying the states rebuilds only the player that changed.

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
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const GearView := preload("res://mods-unpacked/einfluffles-TogetherTests/gear_view.gd")
const NonFiniteTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/non_finite_tests.gd"
)
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const PEER := 4545
const PISTOL := "weapon_pistol_1"
const CRATE := "consumable_item_box"
const LATE_ITEMS := 250
const LATE_WEAPONS := 6
const IDLE_CHECKS := 20
const BUTTON_DELAY_SEC := 0.15  # UpgradesUIPlayerContainer's ButtonDelayTimer: 0.1 s
const CLIENT_KINDS := ["crate item", "reroll", "upgrade choice"]
const NEW_PANELS := "new panels"
const STATS_MARK := "-"  # a stat value no update leaves (the level shown in each panel's stats)
const POKE := "test.poke"  # another mod's kind (_test_mod_intent)

var _t: Node = null
var _together: Node = null
var _sync: Node = null
var _cache = null
var _main: Node = null
var _ui: Node = null
var _stream: Node = null
var _run := ""  # the run part ids last sent (var2str)
var _client = RunParts.Store.new()  # what a client has of the run, from what was sent
var _client_ok := true  # no body named a part the client lacked
var _client_ids := {}  # the run part ids last sent
var _bodies := []  # [kind, player, body]: the states of _sequence that changed the run
var _pokes := []  # what the POKE handler got: [player, id, arg]


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
	_cache.clear()
	_sync.run_sender.forget(PEER)
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
	_test_mod_intent()
	yield(_test_crate(), "completed")
	yield(_test_level_ups(), "completed")
	_test_safety_net()
	_test_peer_ready()
	_test_lobby_left()
	yield(_test_client_popup(), "completed")
	NonFiniteTests.new(_t).client_panels(self)


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
	_test_popup(other)
	_sync._seq_keys[0] = ""  # the next check bumps player 0's revision, nothing else changes
	var seq: int = _sync._seqs[0]
	_expect_view("panel revision")
	_t._check(_sync._seqs[0] == seq + 1, "upgrades change: the revision did move")
	_expect_run("gold (RunData.add_gold)", funcref(self, "_add_gold"))
	_expect_run("a tracked value (RunData.add_tracked_value)", funcref(self, "_add_tracked"))
	_expect_run("a mine laid by Bot-O-Mine (a pair's second value)", funcref(self, "_add_mine"))


# The battle goes on under the panels: an item's counter moves the fingerprint, no miss.
func _add_tracked() -> void:
	RunData.add_tracked_value(0, Keys.generate_hash("item_piggy_bank"), 1)


func _add_mine() -> void:
	RunData.add_tracked_value(1, Keys.item_bot_o_mine_hash, 1, 1)  # as bot_o_mine.gd does


# Player 1's client has its crate weapon popup open (UPGRADE_FOCUS popup): the host's copy shows
# it, and the panels' state carries it for the other clients.
func _test_popup(other) -> void:
	var element = other.crate_weapons_container._elements.get_child(0)
	var popup = other.item_popup
	var view := [FocusTargets.describe(element, _ui, 1), element.item.my_id, 0, [null, null]]
	var cancel := FocusTargets.describe(popup._cancel_button, _ui, 1)
	_sync.host_apply_focus(_ui, 1, 0, cancel, view)
	_t._check(
		(
			popup._focused
			and _ui._popup_manager._elements_pressed[1] == element
			and other.focus_emulator.focused_control == popup._cancel_button
		),
		"upgrades change: a remote player's crate weapon popup opens on the host's copy"
	)
	_t._check(
		var2str(_sync._popups(_ui)[1]) == var2str(view) and _sync._popups(_ui)[0].empty(),
		"upgrades change: the panels' state names it"
	)
	_expect_view("open popup (UPGRADE_FOCUS)")
	_sync.host_apply_focus(_ui, 1, 0, FocusTargets.describe(element, _ui, 1), [])
	_t._check(not popup._focused, "upgrades change: and closes with the client's")
	_expect_view("closed popup (UPGRADE_FOCUS)")


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


func _test_mod_intent() -> void:
	_t._check(
		not _sync.register_intent("take", self, "_on_poke"),
		"upgrades change: a mod cannot take a game kind"
	)
	var press := _intent(1, POKE, "x", {"arg": 2})
	_t._check(
		not _sync.host_apply_intent(_ui, 1, press), "upgrades change: a kind nobody has is dropped"
	)
	_t._check(_sync.register_intent(POKE, self, "_on_poke"), "upgrades change: a mod registers one")
	_t._check(
		_sync.body(_sync.capture(_ui)).kinds == [POKE],
		"upgrades change: the state names the host's kinds"
	)
	_t._check(
		not _sync.host_apply_intent(_ui, 1, _intent(1, POKE, "x")),
		"upgrades change: a press without its arg is dropped"
	)
	press = _intent(1, POKE, "x", {"arg": 2})
	_t._check(_sync.host_apply_intent(_ui, 1, press), "upgrades change: its press is applied")
	_t._check(_pokes == [[1, "x", 2]], "upgrades change: by its handler %s" % [_pokes])
	_t._check(
		not _sync.host_apply_intent(_ui, 1, press), "upgrades change: the same press twice: once"
	)
	_sync._mod_kinds.erase(POKE)
	_stream.step(1.0)
	_take()


func _on_poke(_ui_node: Node, player: int, id: String, arg: int) -> bool:
	_pokes.append([player, id, arg])
	return true


# The ban token and button are given here: the headless profile has not unlocked bans.
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


# A second press inside the button delay is ignored by the game: the forced check then finds what
# a stat written meanwhile changed (a miss of the fingerprint).
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


# The stream's resync (its next step) is the check UpgradesSync's own peer_ready handler forced.
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
	_t._check(
		sent.size() == 1 and sent[0][2].run.parts.size() == _cache.parts.size(),
		"upgrades change: peer_ready resends every run part"
	)
	_stream.step(1.0)
	_t._check(
		_take().empty() and _cache.serialized == serialized + 1 and _cache.packs == packs,
		"upgrades change: the check after it serializes nothing and sends nothing"
	)
	var body: Dictionary = _sync.state_body(StateStream.UPGRADES)
	_t._check(
		(
			var2str(body.run.ids) == _run
			and _cache.serialized == serialized + 1
			and _cache.packs == packs
		),
		"upgrades change: a body built alone reuses the run"
	)
	RunData.add_gold(1, 0)
	body = _sync.state_body(StateStream.UPGRADES)  # no state_key before it
	_t._check(
		var2str(body.run.ids) != _run and _cache.packs == packs + 1,
		"upgrades change: a body built alone after a change carries the new run (one part)"
	)
	_stream.step(1.0)
	_run = _run_of(_take())


func _test_lobby_left() -> void:
	_sync._on_lobby_left()
	_t._check(
		_cache.parts.empty() and _cache._screen_id == 0, "upgrades change: lobby_left drops it"
	)
	_stream.step(1.0)
	var sent := _take()
	_t._check(
		sent.size() == 1 and _run_of(sent) == _run,
		"upgrades change: after lobby_left the next check serializes the same run again"
	)


# A client's copy of the panels (a new battle scene, used as _client_replay uses it) gets player
# 1's open crate weapon popup from the state: on new panels the rebuilt crate weapons close it
# first, then it opens on the element at its place; later states open and close it alone.
func _test_client_popup():
	yield(_blank_scene(), "completed")
	_build_run(2, 0)
	RunData.get_player_effects(1)[Keys.effect_crate_give_weapon_hash] = 1
	RunData.add_weapon(_t._find_by_id(ItemService.weapons, PISTOL), 1)
	yield(_enter_battle(), "completed")
	_show([[_crate(0)], [_crate(1)]], [[], []])
	yield(_t.get_tree(), "idle_frame")
	var other = _ui._get_player_container(1)
	var row: Node = other.crate_weapons_container._elements
	var element = null
	for child in row.get_children():
		if element == null and not child.is_queued_for_deletion():
			element = child
	if element == null:
		_t._check(false, "upgrades change: (player 1 has crate weapons)")
		return
	var id: String = element.item.my_id
	var popup = other.item_popup
	var view := [FocusTargets.describe(element, _ui, 1), id, 0, [null, null]]
	_sync.host_apply_focus(_ui, 1, 0, FocusTargets.describe(popup._cancel_button, _ui, 1), view)
	_t._check(popup._focused, "upgrades change: (player 1's crate weapon popup open on the host)")
	var opened = bytes2var(var2bytes(_sync.state_body(StateStream.UPGRADES)))
	_sync.host_apply_focus(_ui, 1, 0, view[0], [])
	var closed = bytes2var(var2bytes(_sync.state_body(StateStream.UPGRADES)))
	var client: Node = _together.battle_client
	var saved_you: int = client._you
	var saved_store = _sync.run_store
	client._you = -1
	_sync.run_store = RunParts.Store.new()
	_sync._guarded_ui = null
	_sync._reported_popups = {}  # the host's, which would close the copy every frame here
	for body in [opened, closed, opened, closed]:
		yield(_client_apply(body, 2), "completed")
		var open: bool = body == opened
		var pressed = _ui._popup_manager._elements_pressed[1]
		var shown: bool = (
			popup._focused
			and is_instance_valid(pressed)
			and pressed.get_parent() == row
			and pressed.item.my_id == id
			and popup._item_data.my_id == id
		)
		_t._check(
			shown == open and (open or not popup._focused),
			"upgrades change, client: the copy %s with the host's state" % ["opens" if open else "closes"]
		)
	_sync._on_battle_left()
	_sync.run_store = saved_store
	client._you = saved_you


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
	yield(_client_replay(label, players), "completed")


# A typical level-up sequence: every player looks at its gear page and back, takes its crate item,
# rerolls and chooses twice. Player 0 presses on the host, the others send intents.
func _sequence(label: String, players: int, encode: float):
	var serialized: int = _cache.serialized
	var packs: int = _cache.packs
	var sends := 0
	var usec := 0
	var take := [0, 0, 0]  # a client's crate item on the host: usec applying it, checking, takes
	_bodies = []
	_record(NEW_PANELS, -1)
	for step in 6:
		for p in players:
			var container = _ui._get_player_container(p)
			var decided := OS.get_ticks_usec()
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
			if step == 2 and p > 0:
				take[0] += started - decided
				take[1] += OS.get_ticks_usec() - started
				take[2] += 1
			sends += _take().size()
			if step >= 2:
				_record(CLIENT_KINDS[min(step - 2, 2)], p)
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
			+ " now %d serializations, %d parts compressed, %.0f ms in the stream's checks"
		)
		% [
			label,
			sends,
			sends,
			sends * encode / 1000.0,
			_cache.serialized - serialized,
			_cache.packs - packs,
			usec / 1000.0,
		]
	)
	print(
		(
			"  info: upgrades host, %s: a client's crate item to its answer sent %d usec"
			+ " (the intent %d, the stream's check %d); the client waits that plus a round trip"
		)
		% [label, (take[0] + take[1]) / take[2], take[0] / take[2], take[1] / take[2]]
	)


# Prints the cost of a send next to a baseline (RunStateCodec.encode in every body). Returns the
# encode's usec.
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
		% [label, before, key, capture, reuse, net, change, _cache.text_size()]
	)
	return before


# On the host's panels made a spectator's puppet (the panels' decisions are cut, which is why this
# comes after the sequence). The time is of apply only: freed elements go at the end of the frame.
func _client_replay(label: String, players: int):
	var client: Node = _together.battle_client
	var saved_you: int = client._you
	var saved_store = _sync.run_store
	client._you = -1
	_sync.run_store = RunParts.Store.new()
	_sync._guarded_ui = null
	var all := range(players)
	var times := {}  # kind -> [usec, states]
	var crate := []  # the first crate item's [player, body]
	for recorded in _bodies:
		var kind: String = recorded[0]
		var p: int = recorded[1]
		var done: Dictionary = yield(_client_apply(recorded[2], players), "completed")
		if not times.has(kind):
			times[kind] = [0, 0, [0, 0, 0, 0, 0]]
		times[kind][0] += done.usec
		times[kind][1] += 1
		for i in times[kind][2].size():
			times[kind][2][i] += done.marks[i]
		# Every change of a player brings new weapon objects (its gear page points at them).
		var gear: Array = all if kind == NEW_PANELS else [p]
		var stats: Array = gear
		var what := "%s, client: %s (player %d)" % [label, kind, p]
		_t._check(
			done.gear == gear and done.stats == stats and done.shows_run,
			(
				"%s updates gear %s, stats %s, every gear page shows the run (did %s, %s, %s)"
				% [what, gear, stats, done.gear, done.stats, done.shows_run]
			)
		)
		if kind == NEW_PANELS:
			continue
		# Issue #110: a crate item's state rebuilt that player's whole gear page and deserialized
		# all of its ~250 items again. Now only what changed: the new item.
		var most := 1 if kind == CLIENT_KINDS[0] else 0
		_t._check(
			done.instanced <= most and done.made <= most,
			(
				"%s instances %d gear elements, deserializes %d items (at most %d)"
				% [what, done.instanced, done.made, most]
			)
		)
		if kind == CLIENT_KINDS[0] and crate.empty():
			crate = [p, recorded[2]]
	_sync._guarded_ui = null
	var again: Dictionary = yield(_client_apply(_bodies[-1][2], players), "completed")
	_t._check(
		again.gear.empty() and again.stats == all and again.shows_run and again.instanced == 0,
		(
			"%s, client: new panels on the same run update every player's stats and keep the gear"
			+ " (did %s, %s, %s, %d instanced)"
		)
		% [label, again.gear, again.stats, again.shows_run, again.instanced]
	)
	var line := ""
	for kind in [NEW_PANELS] + CLIENT_KINDS:
		if times.has(kind):
			line += ", %s %d" % [kind, times[kind][0] / times[kind][1]]
	print("  info: upgrades client, %s: usec per applied state%s" % [label, line])
	if not crate.empty():
		var count: int = times[CLIENT_KINDS[0]][1]
		var now: int = times[CLIENT_KINDS[0]][0] / count
		var split := []
		for value in times[CLIENT_KINDS[0]][2]:
			split.append(value / count)
		var before: int = yield(_old_crate_apply(crate[0], crate[1], players), "completed")
		print(
			(
				"  info: upgrades client, %s: a crate item's state %d usec (run parse %d,"
				+ " deserialize %d, apply %d, panels %d); before issue #110 %d"
			)
			% [label, now, split[0], split[1], split[2], split[4], before]
		)
		_t._check(
			now * 2 < before,
			(
				"%s, client: a crate item's state applies in under half the time it took before"
				+ " issue #110 (%d usec, then %d)"
			)
			% [label, now, before]
		)
	_sync._on_battle_left()  # the client's state of these panels goes
	_sync.run_store = saved_store
	client._you = saved_you


# What applying a crate item's state cost before issue #110, in usec: that player deserialized
# with all of its items, its gear page rebuilt (the game's update_inventory).
func _old_crate_apply(p: int, body: Dictionary, players: int):
	var store = RunParts.Store.new()
	var run: Dictionary = body.run.duplicate(true)
	store.ingest(run)
	var started := OS.get_ticks_usec()
	store.state_for(run.ids)
	var whole := OS.get_ticks_usec() - started  # every player: a client had the others already
	started = OS.get_ticks_usec()
	_ui._get_player_container(p).update_inventory()
	var rebuild := OS.get_ticks_usec() - started
	yield(_t.get_tree(), "idle_frame")
	return whole / players + rebuild


# Applies body as a client, one frame later (the freed elements are gone): {gear, stats: the
# players whose gear page shows other item objects / whose stats were updated, shows_run: every
# gear page shows its player's run objects, instanced: gear elements new, made: items
# deserialized, usec}.
func _client_apply(body: Dictionary, players: int):
	var views := []
	for p in players:
		var container = _ui._get_player_container(p)
		views.append(GearView.ids(container))
		container.primary_stats_container.general_stats[0]._value.text = STATS_MARK
	var made: int = _sync.run_store.items_made
	var report: Node = _together.client_report
	var was_active: bool = report.active
	report.active = true  # its marks: run parse, deserialize, apply, level-up panels
	report._marks = report._no_marks()
	var started := OS.get_ticks_usec()
	_sync.accept_state(StateStream.UPGRADES, body, 0)
	_sync.apply(_main, body)
	var usec := OS.get_ticks_usec() - started
	var marks: Array = report._marks.duplicate()
	report._marks = report._no_marks()
	report.active = was_active
	var done := {
		"usec": usec,
		"marks": marks,
		"made": _sync.run_store.items_made - made,
		"gear": [],
		"stats": [],
		"shows_run": true,
		"instanced": 0,
	}
	for p in players:
		var container = _ui._get_player_container(p)
		var view := GearView.ids(container)
		if view[1] != views[p][1]:
			done.gear.append(p)
		for node in view[0]:
			if not node in views[p][0]:
				done.instanced += 1
		if container.primary_stats_container.general_stats[0]._value.text != STATS_MARK:
			done.stats.append(p)
		done.shows_run = done.shows_run and GearView.shows_run(container, p)
	yield(_t.get_tree(), "idle_frame")
	return done


# The panels' state now, as a client gets it (every part, a copy), for the replay; only when
# its run differs from the one recorded last (a free reroll changes no part).
func _record(kind: String, p: int) -> void:
	var body = _sync.state_body(StateStream.UPGRADES)
	if typeof(body) != TYPE_DICTIONARY:
		return
	body = bytes2var(var2bytes(body))
	if not _bodies.empty() and RunParts.same_ids(body.run.ids, _bodies[-1][2].run.ids):
		return
	_bodies.append([kind, p, body])


# The next scene replaces the battle (nobody calls a cleanup): the cache is dropped and keeps
# nothing of the wave.
func _test_battle_end():
	_t._check(not _cache.parts.empty(), "upgrades change: a run is cached while the panels show")
	yield(_blank_scene(), "completed")
	_t._check(
		not _together.battle_host.is_in_battle()
		and _cache.parts.empty()
		and _cache._screen_id == 0
		and _cache._fingerprint.empty(),
		"upgrades change: the cache is gone with the battle"
	)
	_t._check(_sync.state_key(StateStream.UPGRADES) == "", "upgrades change: section inactive")
	_main = null
	_ui = null


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


# One check after a change of the run state: sent once, serialized once, found by the
# fingerprint or the forced check (the safety net is not due), only some parts packed again.
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
		"upgrades change: %s detected, serialized once, some parts packed" % label
	)
	if sent.size() == 1:
		_run = run
	_check_client("upgrades change: " + label)


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
	_check_client("upgrades change: " + label)


func _add_gold() -> void:
	RunData.add_gold(3, 0)


func _age_safety_net() -> void:
	_cache._checked_msec = OS.get_ticks_msec() - RunCache.SAFETY_NET_MSEC


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
		_client_ok and text == RunStateCodec.encode_json(),
		"%s: the client's run parts make the host's run state" % label
	)


func _button_delay():
	yield(_t.get_tree().create_timer(BUTTON_DELAY_SEC), "timeout")
