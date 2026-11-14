extends Node
# Headless integration tests, run by tools/check.sh inside the decompiled game (no Steam).
# Prints "MOD-TESTS: PASS" or "MOD-TESTS: FAIL" and quits.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PressCounter := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/press_counter.gd"
)
const PauseInputTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/pause_input_tests.gd"
)
const MenuUxTests := preload("res://mods-unpacked/einfluffles-TogetherTests/menu_ux_tests.gd")
const AnimMirrorTest := preload("res://mods-unpacked/einfluffles-TogetherTests/anim_mirror_test.gd")
const RuntimePartsTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/runtime_parts_tests.gd"
)
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const PerfTests := preload("res://mods-unpacked/einfluffles-TogetherTests/battle_perf_tests.gd")
const SessionLifecycleTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/session_lifecycle_tests.gd"
)
const DlcBorrowTests := preload("res://mods-unpacked/einfluffles-TogetherTests/dlc_borrow_tests.gd")
const LocalPanelTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/local_panel_tests.gd"
)
const LocalShopTests := preload("res://mods-unpacked/einfluffles-TogetherTests/local_shop_tests.gd")
const FAKE_PEER := 4242
const WATCHDOG_SEC := 170.0
const DEVICE := VirtualDevices.FIRST
const BIT_ACCEPT := 1

var _failures := []
var _seq := 0
var _presses = PressCounter.new()
var _pause_input = null  # kept alive across its yields
var _anim_test = AnimMirrorTest.new()  # kept alive across its yields
var _runtime_parts = null  # kept alive across its coroutines
var _perf = null  # kept alive across its coroutines
var _local_panel = LocalPanelTests.new()  # kept alive across its yields
var _local_shop = LocalShopTests.new()  # kept alive across its yields


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	_runtime_parts = RuntimePartsTests.new(self)
	_perf = PerfTests.new(self)
	call_deferred("_run")


# Desktop platforms flush parsed input events every frame; the headless platform never does.
func _process(_delta: float) -> void:
	Input.flush_buffered_events()


func _run() -> void:
	yield(get_tree().create_timer(1.0), "timeout")
	print("MOD-TESTS: START")
	get_tree().create_timer(WATCHDOG_SEC).connect("timeout", self, "_on_watchdog")
	var together := get_node("/root/ModLoader/einfluffles-BrotatoTogether")
	var input_sync: Node = together.input_sync
	_perf.test_no_global_hooks(together)
	SnapshotTests.new(self).run()

	# Virtual actions exist and survive the game's InputMap rebuild.
	_check(InputMap.has_action("ui_accept_%s" % DEVICE), "virtual actions registered")
	InputService.enable_gamepad_movement()
	_check(InputMap.has_action("analog_move_left_%s" % DEVICE), "actions survive rebuild")

	# F9 menu: one hotkey, bottom-centre pill, no keyboard/gamepad focus stealing.
	var menu: CanvasLayer = together.get_node("TogetherMenu")
	_check(not menu.is_open(), "menu starts closed")
	yield(_tap_key(KEY_F8), "completed")
	_check(not menu.is_open(), "F8 (game bug reporter) is not ours")
	yield(_tap_key(KEY_F9), "completed")
	_check(menu.is_open(), "F9 opens the menu")
	_check(not menu._pill.visible, "pill hidden while menu open")
	_check(menu._host_button.focus_mode == Control.FOCUS_NONE, "menu buttons take no focus")
	_check(menu.details_text() != "", "menu shows details")
	yield(_tap_key(KEY_F9), "completed")
	_check(not menu.is_open(), "F9 closes the menu")
	_check(menu._pill.visible and menu.pill_text().ends_with("F9"), "pill shows hint")
	var view_size: Vector2 = menu._pill.get_viewport_rect().size
	var pill_rect: Rect2 = menu._pill.get_global_rect()
	_check(
		abs(pill_rect.get_center().x - view_size.x / 2.0) < 2.0 and pill_rect.end.y <= view_size.y,
		"pill sits bottom-centre (%s in %s)" % [pill_rect, view_size]
	)
	_check(pill_rect.position.y > view_size.y * 0.85, "pill near the bottom edge")

	# Remote player joins via hold-to-join and is typed as a gamepad.
	RunData.set_coop_run(true)
	CoopService.clear_coop_players()
	CoopService.listening_for_inputs = true
	CoopService.set_process_input(true)
	input_sync.devices[FAKE_PEER] = DEVICE
	_send(input_sync, Vector2.ZERO, Vector2.ZERO, 0)  # first packet: nothing held
	# Hold accept for longer than CoopService.HOLD_DURATION (time-based: headless frames are uncapped).
	var hold_until := OS.get_ticks_msec() + int(CoopService.HOLD_DURATION * 1000) + 300
	while OS.get_ticks_msec() < hold_until:
		_send(input_sync, Vector2(0.5, 0.0), Vector2(0.0, -1.0), BIT_ACCEPT)
		yield(get_tree(), "idle_frame")
	_check(CoopService.is_device_assigned(DEVICE), "virtual device joined co-op")
	if CoopService.is_device_assigned(DEVICE):
		_check(
			CoopService.get_player_input_type(0) == CoopService.PlayerType.GAMEPAD_XBOX,
			"virtual player typed as gamepad"
		)
		_check(Utils.get_player_rjoy_vector(0).is_equal_approx(Vector2(0, -1)), "aim reaches game")

	var move := Input.get_vector(
		"analog_move_left_%s" % DEVICE,
		"analog_move_right_%s" % DEVICE,
		"analog_move_up_%s" % DEVICE,
		"analog_move_down_%s" % DEVICE
	)
	_check(move.is_equal_approx(Vector2(0.5, 0.0)), "movement strength exact (got %s)" % move)

	# Reordered (stale) packets are ignored.
	_seq -= 10
	_send(input_sync, Vector2(-1.0, 0.0), Vector2.ZERO, 0)
	yield(get_tree(), "idle_frame")
	_check(Input.is_action_pressed("ui_accept_%s" % DEVICE), "stale packet ignored")
	_seq += 20

	# Button release edge.
	_send(input_sync, Vector2(0.5, 0.0), Vector2.ZERO, 0)
	yield(get_tree(), "idle_frame")
	_check(not Input.is_action_pressed("ui_accept_%s" % DEVICE), "button released")

	# Input timeout releases everything.
	yield(get_tree().create_timer(0.4), "timeout")
	input_sync._release_timed_out()
	_check(
		Input.get_action_strength("analog_move_right_%s" % DEVICE) == 0.0, "timeout releases move"
	)

	_test_host_timeout(together)
	SessionLifecycleTests.new().run(self, together)
	DlcBorrowTests.new().run(self, together)
	_test_run_state_round_trip()
	yield(_test_battle_loopback(together), "completed")
	yield(_test_pose_mirror(together), "completed")
	yield(_anim_test.run(self, together), "completed")
	yield(_runtime_parts.test_runtime_parts(together), "completed")
	yield(_perf.test_battle(together), "completed")
	# Variants the game actually uses (ZoneService.bullets_hell); BulletHell_0..3 are unused
	# leftovers (2 and 3 are even broken in the game: bullet groups in a single-bullet variable).
	for variant in ["BulletHell_Left", "BulletHell_Top_2", "BulletHell_Bottom_3"]:
		yield(_test_bullet_hell(together, variant), "completed")
	var menu_ux = MenuUxTests.new()
	yield(menu_ux.run_battle_tests(self, together), "completed")
	yield(_test_shop_loopback(together), "completed")
	yield(_local_shop.run(self, together), "completed")
	_pause_input = PauseInputTests.new(self, together)
	yield(_pause_input.run(), "completed")  # needs the run state
	yield(_test_menu_mirror(together), "completed")
	yield(menu_ux.run_menu_tests(self, together), "completed")
	yield(preload("coop_selection_tests.gd").new().run(self, together), "completed")
	_finish()


func _test_host_timeout(together: Node) -> void:
	var session: Node = together.session
	var transport: Node = session.transport
	var saved_host: int = transport.host_id
	transport.host_id = 77
	session.peers[77] = {"name": "h", "ready": true, "rtt_ms": 1, "last_seen_msec": 0}
	var now := OS.get_ticks_msec()
	_check(session._host_timed_out(now + session.HOST_TIMEOUT_MSEC + 1), "silent host detected")
	session.peers[77].last_seen_msec = now
	_check(not session._host_timed_out(now + 1000), "live host kept")
	session.peers.erase(77)
	transport.host_id = saved_host


# Host run state survives encode -> var2bytes -> bytes2var(no objects) -> apply.
func _test_run_state_round_trip() -> void:
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(2)
	for i in 2:
		RunData.add_character(ItemService.characters[i], i)
	RunData.add_weapon(_find_by_id(ItemService.weapons, "weapon_pistol_1"), 0)
	# +1 weapon slot (the item from the BrotatoOnline bug report); DLC items may be absent here.
	var arm = _find_by_id(ItemService.items, "item_cybernetic_arm")
	if arm == null:
		arm = load("res://items/all/04_primal_dread/cybernetic_arm/cybernetic_arm.tres")
	RunData.add_item(arm, 1)
	RunData.add_gold(37, 1)
	var expected := {
		"chars": [RunData.get_player_character(0).my_id, RunData.get_player_character(1).my_id],
		"weapons0": RunData.get_player_weapons(0).size(),
		"gold1": RunData.get_player_gold(1),
		"slots1": RunData.get_player_effect(Keys.weapon_slot_hash, 1),
	}

	var bytes := var2bytes(RunStateCodec.encode())
	var state := RunStateCodec.decode(bytes2var(bytes, false))
	_check(not state.empty(), "run state decodes (%d bytes on the wire)" % bytes.size())
	if state.empty():
		return

	RunData.reset()
	RunStateCodec.apply(state)
	var actual := {
		"chars": [RunData.get_player_character(0).my_id, RunData.get_player_character(1).my_id],
		"weapons0": RunData.get_player_weapons(0).size(),
		"gold1": RunData.get_player_gold(1),
		"slots1": RunData.get_player_effect(Keys.weapon_slot_hash, 1),
	}
	_check(str(actual) == str(expected), "run state round trip %s == %s" % [actual, expected])


# Host records a real battle; the client replays the recording in puppet mode.
func _test_battle_loopback(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)  # driven by hand: no Steam session, so it would end the battle

	# --- host: start a 2-player co-op battle (run from the round-trip test) ---
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.current_wave = 3
	_local_panel.give_crate_weapons(self, 1)  # player 1's crate panel gets the weapons popup
	get_tree().change_scene("res://main.tscn")
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var main := get_tree().current_scene
	_check(main != null and main.filename == "res://main.tscn", "host battle scene loaded")
	host._start_battle(main)  # installs the sound recorder and player damage hooks
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < 6000:
		yield(get_tree().create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	# End-of-wave panels on the host: player 0 levels up, player 1 opens a crate (both rolled).
	var upgrades_ui = main.get("_coop_upgrades_ui")
	var level_up = UpgradesUI.UpgradeToProcess.new()
	level_up.level = 2
	level_up.player_index = 0
	var crate_open = UpgradesUI.ConsumableToProcess.new()
	crate_open.consumable_data = _find_by_id(ItemService.consumables, "consumable_item_box")
	crate_open.player_index = 1
	upgrades_ui.show_options([[], [crate_open], [], []], [[level_up], [], [], []])
	var upgrades_sync: Node = together.upgrades_sync
	var host_panels: Array = upgrades_sync.capture(upgrades_ui)
	var upgrades_msg: Dictionary = bytes2var(var2bytes(upgrades_sync.body(host_panels)), false)
	yield(
		_local_panel.host_part(self, together, upgrades_ui, host_panels, upgrades_msg), "completed"
	)
	upgrades_ui.hide()
	host._end_battle()
	var damage_events := 0
	var sound_events := 0
	for msg in recorded:
		for event in Snapshot.parse(msg[1]).events:
			damage_events += 1 if event[0] == Snapshot.EVENT_DAMAGE else 0
			sound_events += 1 if event[0] == Snapshot.EVENT_SOUND else 0
	print("  info: recorded %d damage and %d sound events" % [damage_events, sound_events])
	_check(damage_events > 0 and sound_events > 0, "host records damage and sound events")
	var last: Dictionary = SnapshotTests.views(recorded)[-1]
	_check(not last.empty(), "host snapshot well-formed")
	_check(last.players.size() == 2, "snapshot has both players")
	_check(last.ids.size() > 0, "host battle has entities after 6 s (%d)" % last.ids.size())
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
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
	client._on_battle_start(start)
	_check(Puppet.is_active(), "puppet mode on")
	# Rejoin during the level-up phase: panel state arrives while the scene is still loading.
	together.upgrades_sync._pending = upgrades_msg
	yield(client, "battle_entered")
	var puppet_main: Node = client._main
	_check(puppet_main != null and puppet_main != main, "client loaded its own battle scene")
	var spawner = puppet_main.get("_entity_spawner")
	var max_floating_texts := 0  # damage numbers only live ~1 s: sample during the replay
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)  # host t -> replay timeline
		while OS.get_ticks_msec() < snap.t:
			yield(get_tree(), "idle_frame")
			max_floating_texts = max(
				max_floating_texts, puppet_main.get_node("%FloatingTexts").get_child_count()
			)
		client._on_snapshot(snap)
	yield(get_tree().create_timer(0.3), "timeout")
	_check(spawner.enemies.empty(), "client spawner spawned nothing itself")
	if damage_events > 0:  # hits are random in a 6 s battle
		_check(max_floating_texts > 0, "damage numbers replayed on the client")
	# Local sounds are muted while mirroring; the host's replayed sounds play.
	var stream: AudioStream = load("res://entities/units/player/step_sounds/Step 1.mp3")
	var queued: int = SoundManager2D.sounds_to_play.size()
	SoundManager2D.play(stream, Vector2.ZERO)
	_check(SoundManager2D.sounds_to_play.size() == queued, "local sound muted while mirroring")
	SoundRelay.replay(stream, Vector2.ZERO, 0.0, 0.0)
	_check(SoundManager2D.sounds_to_play.size() == queued + 1, "replayed host sound plays")
	_check(
		client._entities.size() == last.ids.size(),
		"client mirrors all entities (%d/%d)" % [client._entities.size(), last.ids.size()]
	)
	var first_id: int = last.ids[0]
	if client._entities.has(first_id):
		var node: Node2D = client._entities[first_id]
		_check(
			node.global_position.distance_to(last.positions[0]) < 1.0,
			"entity at host position after buffer drains"
		)
		_check(not node.is_physics_processing(), "entity puppetized")
	var player: Node2D = puppet_main.get("_players")[0]
	_check(player.global_position.distance_to(last.players[0][0]) < 1.0, "player follows host")
	var host_weapons: PoolRealArray = last.players[0][Snapshot.PlayerField.WEAPONS]
	_check(host_weapons.size() == 4 * player.current_weapons.size(), "weapon state per weapon")
	if host_weapons.size() >= 4 and player.current_weapons.size() > 0:
		var diff := abs(wrapf(player.current_weapons[0].rotation - host_weapons[0], -PI, PI))
		_check(diff < 0.01, "weapon aim mirrored")
	_check(puppet_main.get_tree().current_scene == puppet_main, "wave did not end locally")
	# Level-up / crate panels mirrored with the host's rolled options.
	_check(
		host_panels[0][0] == "upgrades" and host_panels[1][0] == "item",
		"host panels %s" % [[host_panels[0][0], host_panels[1][0]]]
	)
	var client_panels: Array = upgrades_sync.capture(puppet_main.get("_coop_upgrades_ui"))
	_check(client_panels[0] == host_panels[0], "client shows host's level-up options")
	_check(
		client_panels[1][0] == "item" and client_panels[1][2] == host_panels[1][2],
		"client shows host's crate item (%s)" % host_panels[1][2]
	)
	yield(_local_panel.client_part(self, together, puppet_main, upgrades_msg), "completed")
	puppet_main.get("_coop_upgrades_ui").hide()
	client._set_paused(true)
	_check(client._banner != null and client._banner.visible, "pause banner shown")
	client._set_paused(false)
	_check(not client._banner.visible, "pause banner hidden")
	ProgressData.settings.pause_on_focus_lost = true
	InputService.emit_signal("game_lost_focus")  # alt-tab / pad disconnect
	_check(not get_tree().paused, "client battle ignores focus loss")

	# Player 1 dies on the host: the puppet plays dead without running game logic.
	var dead_snap := Snapshot.parse(recorded[-1][1])
	dead_snap.t = client._buffer[-1].t + 1000  # newer than anything buffered
	dead_snap.players[1][Snapshot.PlayerField.HEALTH] = 0
	client._on_snapshot(dead_snap)
	yield(get_tree().create_timer(1.3), "timeout")
	var player2: Node = puppet_main.get("_players")[1]
	_check(player2.dead and not player2._weapons_container.visible, "dead player shown dead")
	_check(puppet_main.get_tree().current_scene == puppet_main, "death did not end the wave")
	var kinds := {}
	for path in host._types:
		kinds[path.get_file()] = true
	print("  info: mirrored types %s" % [kinds.keys()])
	_check(
		kinds.has("player_projectile.tscn") or _has_projectile_type(kinds), "projectiles mirrored"
	)

	# Own-player prediction: newest host position + un-acked inputs (ack is 0 for local players).
	var input_sync: Node = together.input_sync
	client._you = 0
	_perf.test_prediction(client, input_sync, player, last.players[0])
	input_sync.history = [[1, Vector2(0.3, 0)], [2, Vector2(1, 0)]]
	client._newest_rx_msec = OS.get_ticks_msec()  # fresh: prediction on
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var step: float = player.get_move_speed() / float(Engine.iterations_per_second)
	var expected_x: float = min(
		last.players[0][0].x + 2 * step, ZoneService.get_current_zone_rect().end.x
	)
	_check(
		abs(player.global_position.x - expected_x) < 0.5,
		"prediction replays un-acked inputs (%.1f vs %.1f)" % [player.global_position.x, expected_x]
	)
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
	_check(victim != null, "found an enemy puppet")
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
		_check(victim.dead and victim.is_inside_tree(), "death animation playing")
		var texts: Node = puppet_main.get_node("%FloatingTexts")
		var texts_before := texts.get_child_count()
		client._show_damage([Snapshot.EVENT_DAMAGE, victim_id, 12, Vector2.ZERO, 0, 0])
		_check(texts.get_child_count() > texts_before, "killing blow shows its damage number")
		yield(get_tree().create_timer(2.0), "timeout")
		_check(puppet_main.is_in_pool(victim), "dead puppet returned to pool")
		var pooled: Array = puppet_main._pool[victim.pool_id].duplicate()
		var reused: Node = client._spawn(host._types[victim.filename])
		_check(
			reused in pooled and not reused.dead and reused.is_inside_tree(),
			"puppet reused from pool"
		)
	# Consumables share one scene; their look comes from data (crate vs. fruit).
	var crate = ItemService.consumables[-1]
	client._define_type(999, "res://items/consumables/consumable.tscn#%s" % crate.my_id)
	var consumable: Node = client._spawn(999)
	_check(
		consumable != null and consumable.consumable_data == crate,
		"consumable gets its data (%s)" % crate.my_id
	)
	# Cursed structures carry curse particles; a pooled puppet reused as a normal one loses them.
	var turret_scene := "res://entities/structures/turret/turret.tscn"
	client._define_type(997, turret_scene + "#cursed")
	client._define_type(998, turret_scene)
	var cursed_turret: Node = client._spawn(997)
	_check(is_instance_valid(cursed_turret.curse_particle_instance), "cursed turret has particles")
	client._despawn(cursed_turret)
	yield(get_tree().create_timer(2.0), "timeout")
	var normal_turret: Node = client._spawn(998)
	_check(
		not is_instance_valid(normal_turret.curse_particle_instance),
		"reused turret lost curse particles (reused: %s)" % (normal_turret == cursed_turret)
	)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


# Parts the game turns in physics code (frozen on puppets): a bullet ring on a Pivot, a catling
# gun's aim, a stampede dino's heading. Turrets don't rotate in this game: a real turret and
# ordinary enemies must add no pose data. Also the facing/hidden flags.
func _test_pose_mirror(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	get_tree().change_scene("res://main.tscn")
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var main := get_tree().current_scene
	host._start_battle(main)
	var spawner = main.get("_entity_spawner")
	var enemies := "res://entities/units/enemies/"
	var nodes := {}
	nodes["tree"] = _spawn_on_host(
		spawner, enemies + "corrupted_tree/corrupted_tree.tscn", EntityType.ENEMY, Vector2(300, 300)
	)
	nodes["dino"] = _spawn_on_host(
		spawner, enemies + "jungle/basic/iguanodon/iguanodon.tscn", EntityType.ENEMY, Vector2(900, 600)
	)
	nodes.dino.propagate_call("set_physics_process", [false])  # parked, hidden by its behavior
	nodes.dino.rotation = 0.7  # what GoTowardsBorderOppositeMovementBehavior does when charging
	nodes["catling"] = _spawn_on_host(
		spawner,
		"res://entities/units/pet/catling_gun/catling_gun.tscn",
		EntityType.PET,
		Vector2(500, 300),
		load("res://items/all/03_paws_n_claws/catling_gun/catling_gun_effect_0.tres")
	)
	nodes.catling.set_physics_process(false)  # aimed below with the game's own _orient_gun
	nodes["turret"] = _spawn_on_host(
		spawner,
		"res://entities/structures/turret/turret.tscn",
		EntityType.STRUCTURE,
		Vector2(400, 500),
		load("res://items/all/00_base_game/turret/turret_effect_1.tres")
	)
	var catling: Node = nodes.catling
	var pivot: Node2D = nodes.tree.get_node("Pivot")
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var host_values := {}
	var t0 := OS.get_ticks_msec()
	# 1.5 s: the ring (PI rad/s) ends ~1.5 PI from its start, so a frozen puppet can't match.
	while OS.get_ticks_msec() - t0 < 1500:
		yield(get_tree().create_timer(1.0 / 30.0), "timeout")
		catling._left_current_target = [nodes.tree, 0.0]
		catling._right_current_target = [nodes.tree, 0.0]
		catling._orient_gun(true)
		catling._orient_gun(false)
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
		host_values = {
			"pivot": pivot.rotation,
			"bullet": pivot.get_child(0).position.x,
			"gun_l": catling._gun_pivot_l.rotation,
			"gun_r": catling._gun_pivot_r.rotation,
			"gun_l_flip": catling._gun_pivot_l.scale.y,
			"gun_l_index": catling._gun_pivot_l.get_index(),
		}
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()
	var early: Dictionary = Snapshot.parse(recorded[recorded.size() / 4][1])
	var last: Dictionary = Snapshot.parse(recorded[-1][1])
	_check(not last.empty() and not early.empty(), "snapshots with poses well-formed")
	if last.empty() or early.empty():
		return
	var index := {}
	for name in nodes:
		index[name] = Snapshot.index_of(last, nodes[name].get_meta(host.NET_ID_META))
	_check(not (-1 in index.values()), "test entities in the snapshot %s" % [index])
	if -1 in index.values():
		return
	print(
		(
			"  info: %d entities, %d with poses (%d B), flags %d B"
			% [last.ids.size(), last.poses.size(), 4 * _pose_floats(last), last.flags.size()]
		)
	)
	_check(
		last.poses.size() == 3 and not last.poses.has(index.turret),
		"only tree, dino, catling send poses; turret + %d others don't" % (last.ids.size() - 3)
	)
	var tree_pose: PoolRealArray = last.poses.get(index.tree, PoolRealArray())
	_check(
		tree_pose.size() == 2 and _angle_diff(tree_pose[0], host_values.pivot) < 0.001,
		"tree pose = pivot rotation + bullet distance %s" % [tree_pose]
	)
	var early_tree: PoolRealArray = early.poses.get(
		Snapshot.index_of(early, last.ids[index.tree]), PoolRealArray()
	)
	_check(
		early_tree.size() == 2 and _angle_diff(early_tree[0], tree_pose[0]) > 0.5,
		"host bullet ring spins"
	)
	_check(
		bool(Snapshot.get_flags(last.flags, index.dino) & Snapshot.FLAG_HIDDEN),
		"hidden dino flagged hidden"
	)

	# --- client replay ---
	client._on_battle_start(start)
	yield(client, "battle_entered")
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(get_tree(), "idle_frame")
		client._on_snapshot(snap)
	yield(get_tree().create_timer(0.3), "timeout")
	client.set_process(false)
	var puppets := {}
	for name in nodes:
		puppets[name] = client._entities.get(last.ids[index[name]])
	_check(not (null in puppets.values()), "client mirrors the test entities")
	if not (null in puppets.values()):
		_check_puppet_poses(client, puppets, host_values, last)
		var host_pose: PoolRealArray = last.poses.get(index.tree, PoolRealArray([0.0, 0.0]))
		yield(_runtime_parts.test_pivot_restore(client, puppets.tree, host_pose), "completed")
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


func _check_puppet_poses(client: Node, puppets: Dictionary, host_values: Dictionary, last) -> void:
	var puppet_pivot: Node2D = puppets.tree.get_node("Pivot")
	_check(_angle_diff(host_values.pivot, 0.0) > 0.5, "host ring turned away from its start angle")
	_check(
		_angle_diff(puppet_pivot.rotation, host_values.pivot) < 0.01,
		"bullet ring rotation mirrored (%.2f vs %.2f)" % [puppet_pivot.rotation, host_values.pivot]
	)
	_check(
		abs(puppet_pivot.get_child(0).position.x - host_values.bullet) < 0.01,
		"bullet distance mirrored (%.1f)" % host_values.bullet
	)
	_check(_angle_diff(puppets.dino.rotation, 0.7) < 0.01, "dino heading mirrored")
	_check(not puppets.dino.visible, "dino hidden like on the host")
	var gun_l: Node2D = puppets.catling._gun_pivot_l
	var gun_r: Node2D = puppets.catling._gun_pivot_r
	_check(
		(
			_angle_diff(gun_l.rotation, host_values.gun_l) < 0.01
			and _angle_diff(gun_r.rotation, host_values.gun_r) < 0.01
		),
		"catling gun aim mirrored (%.2f, %.2f)" % [gun_l.rotation, gun_r.rotation]
	)
	_check(
		gun_l.scale.y == host_values.gun_l_flip and gun_l.get_index() == host_values.gun_l_index,
		"catling gun flip and draw order mirrored"
	)
	var facing_mismatches := 0
	for i in last.ids.size():
		var node = client._entities.get(last.ids[i])
		if node is Unit:
			var left := bool(Snapshot.get_flags(last.flags, i) & Snapshot.FLAG_FACING_LEFT)
			facing_mismatches += 1 if (node.sprite.scale.x < 0) != left else 0
	_check(facing_mismatches == 0, "unit facing mirrored (%d mismatches)" % facing_mismatches)
	# Interpolation takes the short way around: PI - 0.1 -> -PI + 0.1 passes PI, not 0.
	var x: float = host_values.bullet
	client._pose.apply(
		puppets.tree, PoolRealArray([PI - 0.1, x]), PoolRealArray([-PI + 0.1, x]), 0.5
	)
	_check(_angle_diff(puppet_pivot.rotation, PI) < 0.01, "pose interpolates the shortest angle")


func _spawn_on_host(spawner, path: String, type: int, position: Vector2, data = null) -> Node:
	var args = EntitySpawner.SpawnEntityArgs.new(position, type)
	args.player_index = 0
	return spawner.spawn_entity(load(path), args, data)


func _pose_floats(snapshot: Dictionary) -> int:
	var floats := 0
	for i in snapshot.poses:
		floats += 2 + snapshot.poses[i].size()
	return floats


func _angle_diff(a: float, b: float) -> float:
	return abs(wrapf(a - b, -PI, PI))


# Bullet-hell wave: every visible enemy bullet on the host must be in the snapshot and mirrored.
func _test_bullet_hell(together: Node, variant: String):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)
	RunData.constant_projectile = 2
	RunData.players_data[0].effects[Keys.bullet_hell_event_hash] = 1
	var saved_variants: Array = ZoneService.bullets_hell
	ZoneService.bullets_hell = [load("res://projectiles/bullet_hells/%s.tscn" % variant)]
	get_tree().change_scene("res://main.tscn")
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var main := get_tree().current_scene
	host._start_battle(main)
	yield(get_tree().create_timer(5.0), "timeout")
	var visible := 0
	for node in _descendants(main.get("_enemy_projectiles")):
		if node is Projectile and node.is_visible_in_tree():
			visible += 1
	var msg: Array = bytes2var(var2bytes(host._build_snapshot()), false)
	var snap := Snapshot.parse(msg[1])
	var mirrored := 0
	for i in snap.ids.size():
		var path: String = host._types.keys()[host._types.values().find(snap.types[i])]
		mirrored += 1 if "bullet" in path or "projectile" in path else 0
	ZoneService.bullets_hell = saved_variants
	print("  info: %s: %d visible enemy bullets, %d in snapshot" % [variant, visible, mirrored])
	_check(visible > 0, "%s spawned bullets" % variant)
	_check(mirrored >= visible, "%s: all visible bullets in the snapshot" % variant)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	host._end_battle()

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var snap2 := Snapshot.parse(msg[1])
	snap2.t = OS.get_ticks_msec() - 1000
	client._on_snapshot(snap2)
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var client_visible := 0
	for node in _descendants(client._main.get("_enemy_projectiles")):
		if node is Projectile and node.is_visible_in_tree():
			client_visible += 1
	_check(
		client_visible == visible,
		"%s: client shows the same bullets (%d/%d)" % [variant, client_visible, visible]
	)
	client._leave_battle()
	Puppet.set_active(false)
	RunData.constant_projectile = 0
	RunData.players_data[0].effects[Keys.bullet_hell_event_hash] = 0
	host.set_process(true)


func _descendants(node: Node) -> Array:
	var found := []
	for child in node.get_children():
		found.append(child)
		found += _descendants(child)
	return found


# Host opens the real co-op shop (rolls items), buys slot 1; the client mirrors both states.
func _test_shop_loopback(together: Node):
	var shop_sync: Node = together.shop_sync
	shop_sync.set_process(false)  # driven by hand (no Steam session)
	CoopService.connected_players.clear()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.current_wave = 2
	RunData.add_gold(500, 0)
	get_tree().change_scene(RunData.get_shop_scene_path())
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var host_shop := get_tree().current_scene
	_check(host_shop.filename == shop_sync.SHOP_SCENE, "host co-op shop loaded")
	shop_sync._host_shop = host_shop
	shop_sync._shop_id = 7
	_perf.test_shop_compare(shop_sync)
	var before: Dictionary = bytes2var(var2bytes(shop_sync._shop_body()), false)
	var host_before := _shop_slots(host_shop, 0)

	var container = host_shop._get_shop_items_container(0)
	var bought = container.get_shop_item_node(1)
	var bought_id: String = bought.item_data.my_id
	var gold_before: int = RunData.get_player_gold(0)
	var host_sounds: Dictionary = yield(_ui_sounds_host_buy(together, bought), "completed")
	var after: Dictionary = bytes2var(var2bytes(shop_sync._shop_body()), false)

	# Host cursor for player 0 on shop slot 2 (focus mirroring).
	var focus_sync: Node = together.focus_sync
	var host_emulator = Utils.get_focus_emulator(0, host_shop)
	var focus_target = container.get_shop_item_node(2)._button
	host_emulator.focused_control = focus_target
	focus_sync._scene = host_shop
	focus_sync._emulators = ScenePaths.find_focus_emulators(host_shop)
	var focus_body := {"scene": host_shop.filename, "cursors": focus_sync._cursors()}
	var focus_path := ScenePaths.path_of(focus_target, host_shop)
	var host_after := _shop_slots(host_shop, 0)
	var host_gold_after: int = RunData.get_player_gold(0)
	_check(host_gold_after < gold_before, "host bought %s" % bought_id)
	print("  info: shop state %d B on the wire" % var2bytes(after).size())

	# --- client ---
	shop_sync._client_shop_id = 0
	var state := RunStateCodec.decode(before.run)
	shop_sync._pending = {"state": state, "slots": before.slots, "go": before.go}
	shop_sync._client_shop_id = before.shop_id
	shop_sync._enter_shop(state)
	yield(shop_sync, "shop_entered")
	var client_shop: Node = shop_sync._client_shop
	_check(client_shop != host_shop, "client loaded its own shop")
	_check(not client_shop._pause_menu.enabled, "client shop can't pause locally")
	_check(
		_shop_slots(client_shop, 0) == host_before,
		"client shows host's items %s" % [_shop_slots(client_shop, 0)]
	)

	var dropped_before := _hold_sounds(true)
	shop_sync._pending = {
		"state": RunStateCodec.decode(after.run), "slots": after.slots, "go": after.go
	}
	shop_sync._apply_pending()
	_check(
		_shop_slots(client_shop, 0) == host_after,
		"client mirrors purchase %s == %s" % [_shop_slots(client_shop, 0), host_after]
	)
	_check(RunData.get_player_gold(0) == host_gold_after, "client gold matches host")
	yield(get_tree(), "idle_frame")
	focus_sync._apply(focus_body)
	var client_focus = Utils.get_focus_emulator(0, client_shop).focused_control
	_check(
		client_focus != null and ScenePaths.path_of(client_focus, client_shop) == focus_path,
		"client cursor mirrors host cursor"
	)
	_test_ui_sounds_client(together, host_sounds, dropped_before)
	var owned := false
	for element in RunData.get_player_weapons(0) + RunData.get_player_items(0):
		owned = owned or element.my_id == bought_id
	_check(owned, "client inventory has %s" % bought_id)
	Puppet.set_active(false)
	shop_sync.set_process(true)


# Host presses the shop item's real Buy button: its press sound plays through SoundManager, and
# everything the host plays outside battle is recorded for clients (UiSounds).
func _ui_sounds_host_buy(together: Node, shop_item: Node):
	var ui_sounds: Node = together.ui_sounds
	ui_sounds.set_process(false)  # driven by hand (no Steam session)
	SoundRelay.set_ui_sink(ui_sounds)
	_hold_sounds(true)
	shop_item._button.emit_signal("pressed")  # the buy itself is a deferred connection
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var played := _queued_sound_paths()
	var body: Dictionary = bytes2var(var2bytes(ui_sounds.take_batch()), false)
	SoundRelay.set_ui_sink(null)
	_hold_sounds(false)
	ui_sounds.set_process(true)
	var sent := _batch_paths(body)
	print("  info: host played %s, sent %s (%d B)" % [played, sent, var2bytes(body).size()])
	_check("res://ui/sounds/button_press.wav" in sent, "host sends the purchase sound")
	_check(sent == played, "host sends every sound it played in the shop")
	return body


# Client: mirroring the purchase and the cursor in the puppet shop plays nothing locally; the
# host's batch plays exactly once.
func _test_ui_sounds_client(together: Node, host_sounds: Dictionary, dropped_before: int) -> void:
	var local := _queued_sound_paths()
	var dropped: int = SoundRelay.dropped_count() - dropped_before
	print("  info: client mirroring muted %d local sounds" % dropped)
	_check(local.empty() and dropped > 0, "mirrored shop plays no local sounds %s" % [local])
	var played: int = together.ui_sounds.play_batch(host_sounds)
	var heard := _queued_sound_paths()
	_check(
		played > 0 and heard == _batch_paths(host_sounds),
		"client plays exactly the host's sounds %s" % [heard]
	)
	_hold_sounds(false)
	_test_ui_sound_validation(together.ui_sounds)


# Sound paths come from the network: only existing res:// sound files are played.
func _test_ui_sound_validation(ui_sounds: Node) -> void:
	_check(SoundRelay.is_sound_path("res://ui/sounds/buy.wav"), "UI sound path accepted")
	var rejected := true
	for path in ["user://a.wav", "res://../a.wav", "res://main.tscn", "res://a.wav::1", 42, null]:
		rejected = rejected and not SoundRelay.is_sound_path(path)
	_check(rejected, "non-sound paths rejected")
	_hold_sounds(true)
	var bad := {
		"sounds":
		[
			["res://ui/menus/shop/coop_shop.tscn", 0.0, 0.0, null],
			["res://../ui/sounds/buy.wav", 0.0, 0.0, null],
			["user://buy.wav", 0.0, 0.0, null],
			["res://ui/sounds/does_not_exist.wav", 0.0, 0.0, null],
			["res://ui/sounds/buy.wav", "loud", 0.0, null],
			["res://ui/sounds/buy.wav", 0.0, 0.0, "here"],
			["res://ui/sounds/buy.wav"],
			"res://ui/sounds/buy.wav",
		]
	}
	var played: int = ui_sounds.play_batch(bad)
	played += ui_sounds.play_batch("res://ui/sounds/buy.wav")
	played += ui_sounds.play_batch({"sounds": 3})
	_check(played == 0 and _queued_sound_paths().empty(), "malformed UI sounds rejected")
	_hold_sounds(false)


# Stops the sound managers so their queues show what was played; returns the muted count so far.
func _hold_sounds(hold: bool) -> int:
	for manager in [SoundManager, SoundManager2D]:
		manager.clear_queue()
		manager.set_process(not hold)
	return SoundRelay.dropped_count()


func _queued_sound_paths() -> Array:
	var paths := []
	for manager in [SoundManager, SoundManager2D]:
		for entry in manager.sounds_to_play:
			paths.append(entry[0].resource_path if entry[0] != null else "")
	paths.sort()
	return paths


func _batch_paths(body: Dictionary) -> Array:
	var paths := []
	if typeof(body.get("sounds")) == TYPE_ARRAY:
		for entry in body.sounds:
			paths.append(entry[0])
	paths.sort()
	return paths


# Character selection: the client card shows what the host cursor is on (by id, not grid index).
func _test_menu_mirror(together: Node):
	var menu_sync: Node = together.menu_sync
	menu_sync.set_process(false)
	get_tree().change_scene(MenuData.character_selection_scene)
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var scene := get_tree().current_scene
	# Two players join like remote players do (virtual devices), then the grid appears.
	RunData.set_coop_run(true)
	CoopService.clear_coop_players()
	CoopService._add_player(VirtualDevices.FIRST, CoopService.PlayerType.GAMEPAD_XBOX)
	CoopService._add_player(VirtualDevices.FIRST + 1, CoopService.PlayerType.GAMEPAD_XBOX)
	yield(get_tree(), "idle_frame")
	var grid = scene.get_node("%Inventory1")
	var element: InventoryElement = null
	for child in grid.get_children():
		if child is InventoryElement and not child.is_random and child.item != null:
			element = child
			break
	_check(element != null, "character grid built")
	if element == null:
		return
	menu_sync._scene = scene
	menu_sync._emulators = ScenePaths.find_focus_emulators(scene)
	Utils.get_focus_emulator(0, scene).focused_control = element
	var state: Dictionary = menu_sync._state()
	state["you"] = 1
	state = bytes2var(var2bytes(state), false)
	_check(state.kind == "character_selection", "menu kind %s" % state.kind)
	_check(state.players[0][0] == element.item.my_id, "host cursor item %s" % element.item.my_id)

	var view = ClientView.new()
	get_tree().root.add_child(view)
	view.show_menu(state)
	_check(view._panels.size() == state.count, "one card per player (%d)" % state.count)
	var card_item = view._panels[0].panel.item_data
	_check(
		card_item != null and card_item.my_id == element.item.my_id,
		"card shows the host's character"
	)
	_check("(you)" in view._panels[1].label.text, "own card marked")
	var backdrop: Node = view.get_child(0)
	var art: Node = backdrop.get_child(0) if backdrop.get_child_count() > 1 else null
	_check(art != null and not art is ColorRect, "waiting screen shows the title key art")
	view.queue_free()
	menu_sync.set_process(true)


func _shop_slots(shop: Node, p: int) -> Array:
	var slots := []
	var container = shop._get_shop_items_container(p)
	for i in container._shop_items.size():
		var node = container.get_shop_item_node(i)
		slots.append(node.item_data.my_id if node.active and node.item_data else "-")
	return slots


func _has_projectile_type(kinds: Dictionary) -> bool:
	for kind in kinds:
		if "projectile" in kind or "bullet" in kind:
			return true
	return false


func _find_by_id(elements: Array, my_id: String):
	for element in elements:
		if element.my_id == my_id:
			return element
	return null


func _send(input_sync: Node, move: Vector2, aim: Vector2, buttons: int) -> void:
	_seq += 1
	input_sync._apply_input(FAKE_PEER, [_seq, move, aim, buttons, _presses.sample(buttons), 0])


func _tap_key(scancode: int) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.scancode = scancode
		event.pressed = pressed
		Input.parse_input_event(event)
		yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")


func _check(condition: bool, label: String) -> void:
	print("  %s %s" % ["ok  " if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _on_watchdog() -> void:
	_check(false, "watchdog: tests did not finish within %d s" % WATCHDOG_SEC)
	_finish()


func _finish() -> void:
	print("MOD-TESTS: %s" % ("PASS" if _failures.empty() else "FAIL %s" % [_failures]))
	get_tree().quit(0 if _failures.empty() else 1)
