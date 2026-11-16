extends Reference
# Suite battle_loopback: the host records a real battle, the client replays the recording in
# puppet mode. Plays on mod_main's two-player run (coop_run); checks go through its _check.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const LocalPanelTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/local_panel_tests.gd"
)
const PerfTests := preload("res://mods-unpacked/einfluffles-TogetherTests/battle_perf_tests.gd")
const UpgradesStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/upgrades_stream_tests.gd"
)
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const CursorKeyTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/cursor_key_tests.gd"
)

var t: Node  # the test mod: _check, helpers, scene tree
var _local_panel = LocalPanelTests.new()  # kept alive across its yields
var _cursor_key = null  # kept alive across its yields
var _perf = null
var _upgrades_stream = UpgradesStreamTests.new()


func _init(test_mod: Node) -> void:
	t = test_mod
	_perf = PerfTests.new(test_mod)


func run(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)  # driven by hand: no Steam session, so it would end the battle

	# --- host: start a 2-player co-op battle (on mod_main.coop_run) ---
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.current_wave = 3
	_local_panel.give_crate_weapons(t, 1)  # player 1's crate panel gets the weapons popup
	t.get_tree().change_scene("res://main.tscn")
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var main := t.get_tree().current_scene
	t._check(main != null and main.filename == "res://main.tscn", "host battle scene loaded")
	host._start_battle(main)  # installs the sound recorder and player damage hooks
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < 6000:
		yield(t.get_tree().create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	# End-of-wave panels on the host: player 0 levels up, player 1 opens a crate (both rolled).
	var upgrades_ui = main.get("_coop_upgrades_ui")
	var level_up = UpgradesUI.UpgradeToProcess.new()
	level_up.level = 2
	level_up.player_index = 0
	var crate_open = UpgradesUI.ConsumableToProcess.new()
	crate_open.consumable_data = t._find_by_id(ItemService.consumables, "consumable_item_box")
	crate_open.player_index = 1
	upgrades_ui.show_options([[], [crate_open], [], []], [[level_up], [], [], []])
	_upgrades_stream.host_part(t, together, upgrades_ui)
	var upgrades_sync: Node = together.upgrades_sync
	var host_panels: Array = upgrades_sync.capture(upgrades_ui)
	# What the host's stream would send a peer now (no session here: the stream is not host).
	var state_stream: Node = together.state_stream
	var upgrades_state: Array = bytes2var(
		var2bytes(state_stream.message_for(StateStream.UPGRADES, t.FAKE_PEER)), false
	)
	t._check(typeof(upgrades_state[2]) == TYPE_DICTIONARY, "host's upgrades section is active")
	var upgrades_msg: Dictionary = upgrades_state[2]
	yield(
		_local_panel.host_part(t, together, upgrades_ui, host_panels, upgrades_msg), "completed"
	)
	_cursor_key = CursorKeyTests.new(t, together)
	yield(_cursor_key.run_upgrades(upgrades_ui, 3), "completed")
	upgrades_ui.hide()
	var host_types: Dictionary = host._types.duplicate()  # the wave's tables go with it
	host._end_battle()
	var damage_events := 0
	var sound_events := 0
	for msg in recorded:
		for event in Snapshot.parse(msg[1]).events:
			damage_events += 1 if event[0] == Snapshot.EVENT_DAMAGE else 0
			sound_events += 1 if event[0] == Snapshot.EVENT_SOUND else 0
	print("  info: recorded %d damage and %d sound events" % [damage_events, sound_events])
	t._check(damage_events > 0 and sound_events > 0, "host records damage and sound events")
	var last: Dictionary = SnapshotTests.views(recorded)[-1]
	t._check(not last.empty(), "host snapshot well-formed")
	t._check(last.players.size() == 2, "snapshot has both players")
	t._check(last.ids.size() > 0, "host battle has entities after 6 s (%d)" % last.ids.size())
	start.types = {}
	for path in host_types:
		start.types[host_types[path]] = path
	var max_bytes := 0
	for msg in recorded:
		max_bytes = max(max_bytes, var2bytes(msg).size())
	print(
		(
			"  info: %d snapshots, largest %d B, %d entities at end"
			% [recorded.size(), max_bytes, last.ids.size()]
		)
	)

	# --- client: replay ---
	# Rejoin during the level-up phase. A rejoin gets BATTLE_START before the stream's resync
	# (menu_ux_tests: join order); the state arriving first is kept as a robustness check, and the
	# scene still loads after BATTLE_START. The state waits in the stream until battle_entered.
	state_stream.receive(upgrades_state)
	t._check(state_stream.is_pending(StateStream.UPGRADES), "panel state before its battle: pending")
	client._on_battle_start(start)
	t._check(Puppet.is_active(), "puppet mode on")
	state_stream.step(0.0)
	t._check(state_stream.is_pending(StateStream.UPGRADES), "panel state pending while loading")
	yield(client, "battle_entered")
	t._check(
		not state_stream.is_pending(StateStream.UPGRADES), "panel state applied once the scene is ready"
	)
	var puppet_main: Node = client._main
	t._check(puppet_main != null and puppet_main != main, "client loaded its own battle scene")
	var spawner = puppet_main.get("_entity_spawner")
	var max_floating_texts := 0  # damage numbers only live ~1 s: sample during the replay
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)  # host t -> replay timeline
		while OS.get_ticks_msec() < snap.t:
			yield(t.get_tree(), "idle_frame")
			max_floating_texts = max(
				max_floating_texts, puppet_main.get_node("%FloatingTexts").get_child_count()
			)
		client._on_snapshot(snap)
	yield(t.get_tree().create_timer(0.3), "timeout")
	t._check(spawner.enemies.empty(), "client spawner spawned nothing itself")
	if damage_events > 0:  # hits are random in a 6 s battle
		t._check(max_floating_texts > 0, "damage numbers replayed on the client")
	# Local sounds are muted while mirroring; the host's replayed sounds play.
	var stream: AudioStream = load("res://entities/units/player/step_sounds/Step 1.mp3")
	var queued: int = SoundManager2D.sounds_to_play.size()
	SoundManager2D.play(stream, Vector2.ZERO)
	t._check(SoundManager2D.sounds_to_play.size() == queued, "local sound muted while mirroring")
	SoundRelay.replay(stream, Vector2.ZERO, 0.0, 0.0)
	t._check(SoundManager2D.sounds_to_play.size() == queued + 1, "replayed host sound plays")
	t._check(
		client._entities.size() == last.ids.size(),
		"client mirrors all entities (%d/%d)" % [client._entities.size(), last.ids.size()]
	)
	var first_id: int = last.ids[0]
	if client._entities.has(first_id):
		var node: Node2D = client._entities[first_id]
		t._check(
			node.global_position.distance_to(last.positions[0]) < 1.0,
			"entity at host position after buffer drains"
		)
		t._check(not node.is_physics_processing(), "entity puppetized")
	var player: Node2D = puppet_main.get("_players")[0]
	t._check(player.global_position.distance_to(last.players[0][0]) < 1.0, "player follows host")
	var host_weapons: PoolRealArray = last.players[0][Snapshot.PlayerField.WEAPONS]
	t._check(host_weapons.size() == 4 * player.current_weapons.size(), "weapon state per weapon")
	if host_weapons.size() >= 4 and player.current_weapons.size() > 0:
		var diff := abs(wrapf(player.current_weapons[0].rotation - host_weapons[0], -PI, PI))
		t._check(diff < 0.01, "weapon aim mirrored")
	t._check(puppet_main.get_tree().current_scene == puppet_main, "wave did not end locally")
	# Level-up / crate panels mirrored with the host's rolled options.
	t._check(
		host_panels[0][0] == "upgrades" and host_panels[1][0] == "item",
		"host panels %s" % [[host_panels[0][0], host_panels[1][0]]]
	)
	var client_panels: Array = upgrades_sync.capture(puppet_main.get("_coop_upgrades_ui"))
	t._check(client_panels[0] == host_panels[0], "client shows host's level-up options")
	t._check(
		client_panels[1][0] == "item" and client_panels[1][2] == host_panels[1][2],
		"client shows host's crate item (%s)" % host_panels[1][2]
	)
	yield(_local_panel.client_part(t, together, puppet_main, upgrades_msg), "completed")
	_upgrades_stream.client_part(t, together, puppet_main)
	puppet_main.get("_coop_upgrades_ui").hide()
	client._set_paused(true)
	t._check(puppet_main.get_node("BrotatoTogetherPauseBanner").visible, "pause banner shown")
	client._set_paused(false)
	t._check(not puppet_main.get_node("BrotatoTogetherPauseBanner").visible, "pause banner hidden")
	ProgressData.settings.pause_on_focus_lost = true
	InputService.emit_signal("game_lost_focus")  # alt-tab / pad disconnect
	t._check(not t.get_tree().paused, "client battle ignores focus loss")

	# Player 1 dies on the host: the puppet plays dead without running game logic.
	var dead_snap := Snapshot.parse(recorded[-1][1])
	dead_snap.t = client._buffer[-1].t + 1000  # newer than anything buffered
	dead_snap.players[1][Snapshot.PlayerField.HEALTH] = 0
	client._on_snapshot(dead_snap)
	yield(t.get_tree().create_timer(1.3), "timeout")
	var player2: Node = puppet_main.get("_players")[1]
	t._check(player2.dead and not player2._weapons_container.visible, "dead player shown dead")
	t._check(puppet_main.get_tree().current_scene == puppet_main, "death did not end the wave")
	var kinds := {}
	for path in host_types:
		kinds[path.get_file()] = true
	print("  info: mirrored types %s" % [kinds.keys()])
	t._check(
		kinds.has("player_projectile.tscn") or _has_projectile_type(kinds), "projectiles mirrored"
	)

	# Own-player prediction: newest host position + un-acked inputs (ack is 0 for local players).
	var input_sync: Node = together.input_sync
	client._you = 0
	_perf.test_prediction(client, input_sync, player, last.players[0])
	input_sync.history = [[1, Vector2(0.3, 0)], [2, Vector2(1, 0)]]
	client._newest_rx_msec = OS.get_ticks_msec()  # fresh: prediction on
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var step: float = player.get_move_speed() / float(Engine.iterations_per_second)
	var expected_x: float = min(
		last.players[0][0].x + 2 * step, ZoneService.get_current_zone_rect().end.x
	)
	t._check(
		abs(player.global_position.x - expected_x) < 0.5,
		"prediction replays un-acked inputs (%.1f vs %.1f)" % [player.global_position.x, expected_x]
	)
	yield(_perf.test_own_animation(client, input_sync, player), "completed")
	input_sync.history = []

	# Death: a vanished unit plays its death animation, then returns to main's pool.
	client.set_process(false)
	var victim = null
	var victim_id := -1
	for id in client._entities:
		if client._entities[id] is Enemy:
			victim = client._entities[id]
			victim_id = id
			break
	t._check(victim != null, "found an enemy puppet")
	if victim != null:
		# The snapshot that drops the enemy carries its killing blow; the event replays after.
		var survivors := {"ids": PoolIntArray(), "types": PoolIntArray(), "positions": [], "t": 0}
		for id in client._entities:
			if id != victim_id:
				survivors.ids.append(id)
				survivors.types.append(client._entity_types[id])
				survivors.positions.append(client._entities[id].global_position)
		survivors.positions = PoolVector2Array(survivors.positions)
		var survivor_flags := []
		for node_id in survivors.ids:  # keep each survivor's facing / visibility as it is
			var node: Node = client._entities[node_id]
			var sprite = node.get("sprite")
			var flags := 0
			if sprite != null and sprite.scale.x < 0:
				flags |= Snapshot.FLAG_FACING_LEFT
			if not node.visible:
				flags |= Snapshot.FLAG_HIDDEN
			survivor_flags.append(flags)
		survivors["flags"] = Snapshot.pack_flags(survivor_flags)
		survivors["poses"] = {}
		client._apply_entities(survivors, survivors, 1.0)
		t._check(victim.dead and victim.is_inside_tree(), "death animation playing")
		var texts: Node = puppet_main.get_node("%FloatingTexts")
		var texts_before := texts.get_child_count()
		client._show_damage([Snapshot.EVENT_DAMAGE, victim_id, 12, Vector2.ZERO, 0, 0])
		t._check(texts.get_child_count() > texts_before, "killing blow shows its damage number")
		yield(t.get_tree().create_timer(2.0), "timeout")
		t._check(puppet_main.is_in_pool(victim), "dead puppet returned to pool")
		var pooled: Array = puppet_main._pool[victim.pool_id].duplicate()
		var reused: Node = client._spawn(host_types[victim.filename])
		t._check(
			reused in pooled and not reused.dead and reused.is_inside_tree(),
			"puppet reused from pool"
		)
	# Consumables share one scene; their look comes from data (crate vs. fruit).
	var crate = ItemService.consumables[-1]
	client._define_type(999, "res://items/consumables/consumable.tscn#%s" % crate.my_id)
	var consumable: Node = client._spawn(999)
	t._check(
		consumable != null and consumable.consumable_data == crate,
		"consumable gets its data (%s)" % crate.my_id
	)
	# Cursed structures carry curse particles; a pooled puppet reused as a normal one loses them.
	var turret_scene := "res://entities/structures/turret/turret.tscn"
	client._define_type(997, turret_scene + "#cursed")
	client._define_type(998, turret_scene)
	var cursed_turret: Node = client._spawn(997)
	t._check(is_instance_valid(cursed_turret.curse_particle_instance), "cursed turret has particles")
	client._despawn(cursed_turret)
	yield(t.get_tree().create_timer(2.0), "timeout")
	var normal_turret: Node = client._spawn(998)
	t._check(
		not is_instance_valid(normal_turret.curse_particle_instance),
		"reused turret lost curse particles (reused: %s)" % (normal_turret == cursed_turret)
	)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


func _has_projectile_type(kinds: Dictionary) -> bool:
	for kind in kinds:
		if "projectile" in kind or "bullet" in kind:
			return true
	return false
