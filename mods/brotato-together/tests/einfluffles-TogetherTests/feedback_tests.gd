extends Reference
# Feedback the client shows without game logic (sync/feedback_mirror.gd, protocol 11): the wire
# format of its events and their size, then a host battle that explodes (once a pooled
# explosion reused between two snapshots), pays out bonus gold, heals, levels up, changes a
# player's stats, picks up crates, uses up tardigrade charges and ends its wave, replayed on a
# client: also the stat icons over the player (protocol 18), the HUD's picked-up crates
# (sync/pickup_list.gd) and the charges' counter and life bar tint (protocol 28).
# Driven from mod_main.gd (late suites); checks go through its _check.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const FeedbackMirror := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/feedback_mirror.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const WeaponAnimTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/weapon_anim_tests.gd"
)
const ROCKET_EFFECT := "res://weapons/ranged/rocket_launcher/rocket_launcher_effect.tres"
const SNAPSHOTS := 30  # 1 s of battle
const HEAL := 3
const BONUS := 12
const PROTECTION := 2

var t: Node  # the test mod: _check, scene tree
var _weapon_anims = null  # WeaponAnimTests, kept alive across its yields


func run(test_mod: Node, mod: Node):
	t = test_mod
	_test_wire()
	var saved: Dictionary = ProgressData.settings.duplicate(true)
	ProgressData.settings.screenshake = true
	ProgressData.settings.visual_effects = true
	yield(_test_battle(mod), "completed")
	_weapon_anims = WeaponAnimTests.new(t)
	yield(_weapon_anims.run(mod), "completed")
	ProgressData.settings = saved
	RunData.bonus_gold = 0


# --- wire ---


func _feedback_events() -> Array:
	return [
		[Snapshot.EVENT_EXPLOSION, 3, Vector2(100.5, -20.0), 1.44, 48],
		[Snapshot.EVENT_BONUS_GOLD, 1234, true],
		[Snapshot.EVENT_WAVE_END, Snapshot.WAVE_FAILED | Snapshot.WAVE_LABEL],
		[Snapshot.EVENT_GOLD_BOOST, Vector2(5.0, 6.5), 2],
		[Snapshot.EVENT_STAT, 1, Keys.stat_evolution_hash, -2],
	]


func _test_wire() -> void:
	var tests = SnapshotTests.new(t)
	var view: Dictionary = tests.scenario(2, 12, 6, 4, 2, 2, 2, 1, true)
	view.events = _feedback_events()
	var bytes := Snapshot.encode(view)
	var parsed := Snapshot.parse(bytes)
	var events: Array = parsed.get("events", [])
	_check_round_trip(events)
	var truncated := true
	for size in bytes.size():
		var prefix: PoolByteArray = bytes.subarray(0, size - 1) if size > 0 else PoolByteArray()
		truncated = truncated and Snapshot.parse(prefix).empty()
	t._check(truncated, "every truncation of a snapshot with feedback events rejected")
	view.events = []
	var empty := Snapshot.encode(view)
	var bad := {
		"wave end flag out of range": [Snapshot.EVENT_WAVE_END, 16],
		"bonus gold flag out of range": [Snapshot.EVENT_BONUS_GOLD, 2, 5],
		"explosion of scale 0": [Snapshot.EVENT_EXPLOSION, 0, 0, 0, 0, 0, 0, 0, 9],
		"stat of a player that cannot be": [Snapshot.EVENT_STAT, 9, 1, 0, 0, 0, 2],
	}
	for label in bad:
		t._check(Snapshot.parse(_with_event(empty, bad[label])).empty(), "rejected: %s" % label)
	var good := Snapshot.parse(_with_event(empty, [Snapshot.EVENT_WAVE_END, Snapshot.WAVE_WON]))
	t._check(not good.empty(), "hand-made wave end event accepted")
	_test_selection()
	_test_sizes(tests)


func _check_round_trip(events: Array) -> void:
	var ok := events.size() == 5
	if ok:
		var boom: Array = events[0]
		ok = (
			boom[1] == 3
			and boom[2].distance_to(Vector2(100.5, -20.0)) < 0.5
			and abs(boom[3] - 1.44) < 0.006
			and boom[4] == 48
		)
		ok = ok and events[1] == [Snapshot.EVENT_BONUS_GOLD, 1234, true]
		ok = ok and events[2][1] == Snapshot.WAVE_FAILED | Snapshot.WAVE_LABEL
		ok = ok and events[3][1].distance_to(Vector2(5.0, 6.5)) < 0.5 and events[3][2] == 2
		ok = ok and events[4] == [Snapshot.EVENT_STAT, 1, Keys.stat_evolution_hash, -2]
	t._check(ok, "explosion, bonus gold, wave end, gold boost and stat events survive %s" % [events])


# A snapshot without events, looks or angles with one hand-written event put in: its last three
# bytes are the event count and the counts of the looks and angles sections after the events.
static func _with_event(empty: PoolByteArray, event_bytes: Array) -> PoolByteArray:
	var bytes := empty.subarray(0, empty.size() - 4)
	bytes.append(1)
	bytes.append_array(PoolByteArray(event_bytes))
	bytes.append_array(PoolByteArray([0, 0]))
	return bytes


func _test_selection() -> void:
	var events := []
	for i in 60:
		events.append([Snapshot.EVENT_DAMAGE, 100 + i, i, Vector2.ZERO, 0, 0])
	events.append([Snapshot.EVENT_EXPLOSION, 0, Vector2.ZERO, 1.0, 20])
	events.append([Snapshot.EVENT_BONUS_GOLD, 5, true])
	events.append([Snapshot.EVENT_WAVE_END, 0])
	var kinds := {}
	for event in Snapshot.select_events(events, 48):
		kinds[event[0]] = true
	t._check(
		(
			kinds.has(Snapshot.EVENT_EXPLOSION)
			and kinds.has(Snapshot.EVENT_BONUS_GOLD)
			and kinds.has(Snapshot.EVENT_WAVE_END)
		),
		"event cap keeps explosions and the state events over enemy damage numbers"
	)
	t._check(
		(
			Snapshot.is_state_event(Snapshot.EVENT_WAVE_END)
			and Snapshot.is_state_event(Snapshot.EVENT_ANIM)
			and not Snapshot.is_state_event(Snapshot.EVENT_EXPLOSION)
		),
		"bonus gold and the wave's end survive a stall like animations, explosions do not"
	)


# The late-wave scenario of snapshot_tests.gd, plus what this slice adds at most per snapshot.
func _test_sizes(tests) -> void:
	var view: Dictionary = tests.scenario(4, 150, 90, 50, 10, 30, 6, 8, true)
	view.events = Snapshot.select_events(view.events, 48)
	var before := Protocol.encode(Protocol.Msg.SNAPSHOT, Snapshot.encode(view)).size()
	var sizes := {}
	for event in _feedback_events():
		var one := view.duplicate()
		one.events = view.events + [event]
		sizes[event[0]] = Snapshot.encode(one).size() - Snapshot.encode(view).size()
	for _i in 3:  # four explosions in one snapshot is a lot (one rocket launcher each)
		view.events.append([Snapshot.EVENT_EXPLOSION, 3, Vector2(1500, 900), 1.32, 48])
	view.events += _feedback_events()
	var after := Protocol.encode(Protocol.Msg.SNAPSHOT, Snapshot.encode(view)).size()
	print(
		(
			"  info: event sizes: explosion %d B, bonus gold %d B, wave end %d B, gold boost %d B"
			% [
				sizes[Snapshot.EVENT_EXPLOSION],
				sizes[Snapshot.EVENT_BONUS_GOLD],
				sizes[Snapshot.EVENT_WAVE_END],
				sizes[Snapshot.EVENT_GOLD_BOOST],
			]
		)
	)
	print("  info: late wave %d B, with 4 explosions + all state events %d B" % [before, after])
	t._check(
		sizes[Snapshot.EVENT_EXPLOSION] <= 9 and sizes[Snapshot.EVENT_BONUS_GOLD] <= 5,
		"an explosion costs at most 9 B, bonus gold at most 5 B"
	)
	t._check(
		sizes[Snapshot.EVENT_WAVE_END] == 2 and sizes[Snapshot.EVENT_GOLD_BOOST] == 6,
		"wave end 2 B, gold boost 6 B"
	)
	t._check(sizes[Snapshot.EVENT_STAT] == 7, "a stat text 7 B (%d)" % sizes[Snapshot.EVENT_STAT])


# --- battle ---


func _test_battle(mod: Node):
	var host: Node = mod.battle_host
	var client: Node = mod.battle_client
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	var effects: Dictionary = RunData.get_player_effects(0)
	var saved_protection = effects[Keys.hit_protection_hash]
	effects[Keys.hit_protection_hash] = PROTECTION  # two tardigrades
	t.get_tree().change_scene("res://main.tscn")
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var main := t.get_tree().current_scene
	host._start_battle(main)
	t._check(host._types.has(FeedbackMirror.EXPLOSION_SCENE), "explosion scene announced at start")
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var host_side := {"pickup_list": mod.pickup_list}
	var recorded: Array = yield(_record_host(host, main, host_side), "completed")
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()
	_check_host_events(recorded, host_side)
	client._on_battle_start(start)
	yield(client, "battle_entered")
	var puppet_main: Node = client._main
	var seen: Dictionary = yield(_replay(client, puppet_main, recorded), "completed")
	_check_client(client, puppet_main, seen, host_side)
	_check_protection(puppet_main, seen, host_side)
	effects[Keys.hit_protection_hash] = saved_protection
	_check_pickups(mod.pickup_list, client, puppet_main, host_side)
	yield(t.get_tree().create_timer(1.2), "timeout")  # "explode" lasts 1 s
	var pooled: Node = seen.get("explosion")
	t._check(
		puppet_main._explosions.get_child_count() == 0
		and pooled != null
		and puppet_main.is_in_pool(pooled),
		"client explosions go back to main's pool when their animation ends"
	)
	var shaker: Node = puppet_main._screenshaker
	shaker._camera_shake_duration = 0.0
	shaker._camera_shake_intensity = 0.0
	client._show_damage([Snapshot.EVENT_DAMAGE, -1, 5, Vector2.ZERO, 0, 0])
	t._check(shaker._camera_shake_duration > 0.0, "a hit on a player shakes the client's screen")
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


# 1 s of host battle: three explosions (the third reuses the first's pooled node before the next
# snapshot), a bonus-boosted gold picked up, a heal, a level-up, then the wave's end and its
# label hidden again (main._on_EndWaveTimer_timeout). Players don't shoot.
func _record_host(host: Node, main: Node, host_side: Dictionary):
	var players: Array = main.get("_players")
	for player in players:
		player._weapons_container.propagate_call("set_physics_process", [false])
		player._weapons_container.propagate_call("set_process", [false])
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var corner := zone.position + Vector2(120, 120)
	var effect: Resource = load(ROCKET_EFFECT)
	RunData.bonus_gold = BONUS
	main._ui_bonus_gold.update_value(BONUS)
	main._ui_bonus_gold.show()
	var recorded := []
	var explosions := []
	for k in SNAPSHOTS:
		yield(t.get_tree().create_timer(1.0 / 30.0), "timeout")
		match k:
			1:
				main.spawn_gold(1.0, zone.end - Vector2(150, 150), 0)  # boosted: bonus gold
			2, 4:
				explosions.append(_explode(effect, corner + Vector2(40 * k, 0)))
			3:
				players[0].current_stats.health -= HEAL
			5, 16:
				var hit := TakeDamageArgs.new(-1)
				hit.dodgeable = false  # no dodge roll, no iframes
				players[0].take_damage(7, hit)  # blocked: a charge used up
			6:
				explosions[0]._animation_player.advance(1.0)  # ends: end_explosion pools it ...
				yield(t.get_tree(), "idle_frame")  # (in case animation_finished comes deferred)
				explosions.append(_explode(effect, corner + Vector2(0, 80)))  # ... and reused
			8:
				var golds: Array = main._active_golds
				host_side["boosted"] = golds.back().boosted if not golds.empty() else 0
				if not golds.empty():
					golds.back().pickup(0)
			10:
				players[0].on_healing_effect(HEAL)
			12:
				RunData.emit_signal("stat_added", Keys.stat_evolution_hash, 4, 0.0, 1)
			13:
				RunData.emit_signal("stat_removed", Keys.stat_armor_hash, 2.0, 0.0, 0)
			14:
				_pick_up_crates(main, host_side)
			18:
				RunData.add_xp(RunData.get_next_level_xp_needed(0), 0)
			22:
				main._cleaning_up = true  # what clean_up_room starts with, without saving
				main._wave_cleared_label.start(false, false, false)
			27:
				main._wave_cleared_label.hide()
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	host_side["scale"] = explosions[1].scale.x
	host_side["reused"] = explosions[2] == explosions[0]
	host_side["bonus"] = RunData.bonus_gold
	host_side["protection"] = players[0]._hit_protection
	return recorded


# What main.on_consumable_picked_up puts into the HUD: player 1 a crate and a legendary crate,
# player 0 a crate; then one of player 1's is taken out again.
func _pick_up_crates(main: Node, host_side: Dictionary) -> void:
	var pickup_list: Node = host_side.pickup_list
	var crate = t._find_by_id(ItemService.consumables, "consumable_item_box")
	var legendary = t._find_by_id(ItemService.consumables, "consumable_legendary_item_box")
	var containers: Array = main._things_to_process_player_containers
	host_side["none"] = bytes2var(var2bytes(pickup_list.state_body(StateStream.PICKUPS)), false)
	var none_key: String = pickup_list.state_key(StateStream.PICKUPS)
	var first: Resource = crate.duplicate()
	containers[1].consumables.add_element(first)
	containers[1].consumables.add_element(legendary.duplicate())
	containers[0].consumables.add_element(crate.duplicate())
	host_side["picked"] = bytes2var(var2bytes(pickup_list.state_body(StateStream.PICKUPS)), false)
	host_side["key_changed"] = pickup_list.state_key(StateStream.PICKUPS) != none_key
	containers[1].consumables.remove_element(first)
	host_side["one_less"] = bytes2var(var2bytes(pickup_list.state_body(StateStream.PICKUPS)), false)


# The HUD's picked-up crates on the client, from the host's lists (section pickups).
func _check_pickups(pickup_list: Node, client: Node, puppet_main: Node, host_side: Dictionary):
	var section := StateStream.PICKUPS
	var lists := []
	for container in puppet_main._things_to_process_player_containers:
		lists.append(container.consumables)
	t._check(
		host_side.key_changed
		and host_side.picked.players.slice(0, 1) == [
			["consumable_item_box"], ["consumable_item_box", "consumable_legendary_item_box"]
		],
		"host: the picked-up crates of each player are state %s" % [host_side.picked.players]
	)
	t._check(
		pickup_list.state_stream.message_for(section, 1)[2] == null,
		"host: no such state outside a battle"
	)
	t._check(
		pickup_list.apply_state(section, host_side.none, 1) and lists[1].is_empty(),
		"client: nothing picked up, nothing listed"
	)
	t._check(
		pickup_list.apply_state(section, host_side.picked, 2)
		and _ids(lists[0]) == ["consumable_item_box"]
		and _ids(lists[1]) == ["consumable_item_box", "consumable_legendary_item_box"]
		and lists[1].get_child_count() == 2,
		"client: the HUD lists the crates the host's players picked up %s" % [_ids(lists[1])]
	)
	var icon: Texture = lists[1]._elements[1].icon
	t._check(
		icon != null and icon == RunData.current_background.get_zone_consumable_sprite(
			lists[1]._elements[1]
		),
		"client: with the zone's crate sprite"
	)
	t._check(
		pickup_list.apply_state(section, host_side.picked, 2) and lists[1]._elements.size() == 2,
		"client: the same state again changes nothing"
	)
	t._check(
		pickup_list.apply_state(section, host_side.one_less, 3)
		and _ids(lists[1]) == ["consumable_legendary_item_box"]
		and _ids(lists[0]) == ["consumable_item_box"],
		"client: an entry the host took out goes %s" % [_ids(lists[1])]
	)
	var later: Dictionary = host_side.picked.duplicate(true)
	later.battle_id = client._battle_id + 1
	var earlier: Dictionary = host_side.picked.duplicate(true)
	earlier.battle_id = client._battle_id - 1
	t._check(
		not pickup_list.apply_state(section, later, 4)
		and pickup_list.apply_state(section, earlier, 4)
		and _ids(lists[1]) == ["consumable_legendary_item_box"],
		"client: a later battle's lists wait for it, an earlier battle's are dropped"
	)
	var junk := {"battle_id": client._battle_id, "players": [7, ["no_such_consumable", 3]]}
	t._check(
		pickup_list.apply_state(section, junk, 5) and lists[0].is_empty() and lists[1].is_empty(),
		"client: unknown entries are left out"
	)


static func _ids(list: Node) -> Array:
	var ids := []
	for data in list._elements:
		ids.append(data.my_id)
	return ids


static func _explode(effect: Resource, position: Vector2) -> Node:
	var args := WeaponServiceExplodeArgs.new()
	args.pos = position
	args.damage = 1
	args.from_player_index = 0
	return WeaponService.explode(effect, args)


func _check_host_events(recorded: Array, host_side: Dictionary) -> void:
	var counts := {}
	var scale := 0.0
	var boost := 0
	var labels := []
	for msg in recorded:
		for event in Snapshot.parse(msg[1]).events:
			counts[event[0]] = counts.get(event[0], 0) + 1
			if event[0] == Snapshot.EVENT_EXPLOSION:
				scale = event[3]
			elif event[0] == Snapshot.EVENT_GOLD_BOOST:
				boost = event[2]
			elif event[0] == Snapshot.EVENT_WAVE_END:
				labels.append(bool(event[1] & Snapshot.WAVE_LABEL))
	print("  info: feedback events by kind %s" % [counts])
	t._check(host_side.reused, "the third explosion reused the first's pooled node")
	t._check(
		counts.get(Snapshot.EVENT_EXPLOSION, 0) == 3 and abs(scale - host_side.scale) < 0.01,
		"host sends each explosion once, with its scale (%.2f), also a reused node" % scale
	)
	t._check(
		host_side.boosted == 2 and boost == 2, "boosted gold pickup sent (x%d)" % host_side.boosted
	)
	t._check(
		counts.get(Snapshot.EVENT_STAT, 0) == 3,
		"a stat added, one removed and the level-up's max HP are sent once each"
	)
	var bonus_count: int = counts.get(Snapshot.EVENT_BONUS_GOLD, 0)
	t._check(
		bonus_count > FeedbackMirror.STATE_REPEAT and bonus_count < SNAPSHOTS / 2,
		"bonus gold sent on change and refreshed, not every snapshot (%d)" % bonus_count
	)
	t._check(
		labels.size() >= 2 and labels[0] and not labels[-1],
		"wave end sent from cleanup on, the label's hiding too %s" % [labels]
	)


# Replays the recording and notes what the client showed meanwhile.
func _replay(client: Node, puppet_main: Node, recorded: Array):
	var seen := {
		"explosions": 0, "texts": {}, "icons": {}, "label": 0, "sparkles": 0, "protection": {}
	}
	var sparkle: String = puppet_main._effects_manager.gold_pickup_particles.resource_path
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(t.get_tree(), "idle_frame")
			_sample(puppet_main, seen, sparkle)
		client._on_snapshot(snap)
	var until := OS.get_ticks_msec() + 300
	while OS.get_ticks_msec() < until:
		yield(t.get_tree(), "idle_frame")
		_sample(puppet_main, seen, sparkle)
	return seen


func _sample(puppet_main: Node, seen: Dictionary, sparkle: String) -> void:
	var explosions: Array = puppet_main._explosions.get_children()
	seen.explosions = max(seen.explosions, explosions.size())
	if not explosions.empty() and not seen.has("explosion"):
		var explosion: Node = explosions[0]
		seen["explosion"] = explosion
		seen["scale"] = explosion.scale.x
		seen["inert"] = explosion.sound_played and not explosion.is_physics_processing()
		seen["playing"] = explosion._animation_player.current_animation == "explode"
	for text in puppet_main.get_node("%FloatingTexts").get_children():
		if text.visible:
			seen.texts[text.text] = true
			if text.has_icon:
				seen.icons[text.text] = text.player_index
	seen.label = max(seen.label, puppet_main._wave_cleared_label.visible_characters)
	for effect in puppet_main._effects.get_children():
		seen.sparkles += 1 if effect.filename == sparkle else 0
	var counter: Node = puppet_main._players_ui[0].hit_protection
	if counter.visible:
		seen.protection[counter.hit_protection_label.text] = true


func _check_client(client: Node, puppet_main: Node, seen: Dictionary, host_side: Dictionary):
	print("  info: client texts %s" % [seen.texts.keys()])
	t._check(seen.explosions >= 2, "client shows the host's explosions (%d at once)" % seen.explosions)
	t._check(
		seen.has("explosion") and abs(seen.scale - host_side.scale) < 0.02,
		"client explosion has the host's scale"
	)
	t._check(
		seen.get("inert", false) and seen.get("playing", false),
		"client explosion plays its animation without physics or its own sound"
	)
	var hitbox = seen.explosion._hitbox if seen.has("explosion") else null
	t._check(
		hitbox != null and not hitbox.monitoring and not hitbox.monitorable,
		"client explosion's hitbox finds nothing and is found by nothing (damage is the host's)"
	)
	t._check(seen.texts.has("+%d" % HEAL), "heal text derived from the host's health")
	t._check(seen.texts.has("LEVEL_UP"), "level-up text derived from the host's level")
	t._check(seen.texts.has("x2"), "boosted gold pickup shows x2")
	t._check(
		seen.icons.get("+4") == 1 and seen.icons.get("-2") == 0 and seen.icons.get("+1") == 0,
		"a changed stat shows its icon and number over that player %s" % [seen.icons]
	)
	t._check(seen.sparkles > 0, "picked-up gold sparkles where it vanished")
	t._check(puppet_main._ui_dim_screen.color.a > 0.0, "wave end dims the client's screen")
	t._check(
		seen.label > 0 and not puppet_main._wave_cleared_label.visible,
		"wave completed label typed out and hidden again like the host's"
	)
	var bag: Node = puppet_main._ui_bonus_gold
	t._check(
		bag.visible and bag._gold_label.text == str(host_side.bonus),
		"bonus gold bag shows the host's value (%s)" % bag._gold_label.text
	)
	t._check(client._feedback._wave_ended, "client knows the wave ended")


# Tardigrade: the host's blocked hits use up the charges; the client's HUD counter counts down
# and hides at 0, and the life bars are red again (main._physics_process tints them).
func _check_protection(puppet_main: Node, seen: Dictionary, host_side: Dictionary) -> void:
	var ui = puppet_main._players_ui[0]
	t._check(host_side.protection == 0, "the host's two blocked hits use up both charges")
	t._check(
		seen.protection.keys() == ["2", "1"] and not ui.hit_protection.visible,
		"client's charge counter counts down and hides at 0 %s" % [seen.protection.keys()]
	)
	t._check(
		(
			puppet_main._players[0]._hit_protection == 0
			and ui.life_bar._non_flash_color == ui.life_bar.progress_color
			and ui.player_life_bar._non_flash_color == ui.player_life_bar.progress_color
		),
		"client's life bars turn red when the charges are gone"
	)
