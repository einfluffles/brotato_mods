extends Node
# Headless integration tests, run by tools/check.sh inside the decompiled game (no Steam).
# The tests are named suites (SUITES). MOD_TEST_SUITES picks some (comma-separated, empty: all),
# and shards.txt groups them into the processes check.sh runs side by side. Every suite sets up
# what it needs itself (coop_run and the like), so it passes alone and in any shard.
# Prints "MOD-TESTS: PASS" or "MOD-TESTS: FAIL" and quits.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const MenuPuppetTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/menu_puppet_tests.gd"
)
const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
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
const LocalShopTests := preload("res://mods-unpacked/einfluffles-TogetherTests/local_shop_tests.gd")
const LiveMenuTests := preload("res://mods-unpacked/einfluffles-TogetherTests/live_menu_tests.gd")
const LobbyMenuTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/lobby_menu_tests.gd"
)
const CleanupTests := preload("res://mods-unpacked/einfluffles-TogetherTests/cleanup_tests.gd")
const BattleLoopbackTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/battle_loopback_tests.gd"
)
const PoseMirrorTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/pose_mirror_tests.gd"
)
const BulletHellTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/bullet_hell_tests.gd"
)
const ShopLoopbackTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_loopback_tests.gd"
)
const ShopChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_change_tests.gd"
)
const RunPartsTests := preload("res://mods-unpacked/einfluffles-TogetherTests/run_parts_tests.gd")
const BattleStartTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/battle_start_tests.gd"
)
const UpgradesChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/upgrades_change_tests.gd"
)
const SelectionScreenTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/selection_screen_tests.gd"
)
const CoopSelectionTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/coop_selection_tests.gd"
)
const FeedbackTests := preload("res://mods-unpacked/einfluffles-TogetherTests/feedback_tests.gd")
const LooksTests := preload("res://mods-unpacked/einfluffles-TogetherTests/looks_tests.gd")
const ProgressShareTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/progress_share_tests.gd"
)
const DamageMeterTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/damage_meter_tests.gd"
)
const BattleSceneTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/battle_scene_tests.gd"
)
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const CursorKeyTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/cursor_key_tests.gd"
)
const LocalDeviceTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/local_device_tests.gd"
)
const InputAckTests := preload("res://mods-unpacked/einfluffles-TogetherTests/input_ack_tests.gd")
const NetworkStallTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/network_stall_tests.gd"
)
const TrafficTests := preload("res://mods-unpacked/einfluffles-TogetherTests/traffic_tests.gd")
const ClientReportTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/client_report_tests.gd"
)
const AxolotlTests := preload("res://mods-unpacked/einfluffles-TogetherTests/axolotl_tests.gd")
const OwnPickupsTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/own_pickups_tests.gd"
)
const DeadPlayerTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/dead_player_tests.gd"
)
const SHARDS_PATH := "res://mods-unpacked/einfluffles-TogetherTests/shards.txt"
# Suite name -> _suite_<name>(together). Selected suites always run in this order.
const SUITES := [
	"core",
	"battle_loopback",
	"input_ack",
	"pose_mirror",
	"anim_mirror",
	"runtime_parts",
	"battle_perf",
	"bullet_hell_left",
	"bullet_hell_top",
	"bullet_hell_bottom",
	"menu_ux",
	"shop_loopback",
	"local_shop",
	"local_device",
	"pause_input",
	"live_menu",
	"cleanup_host",
	"cleanup_client",
	"cleanup_misc",
	"feedback",
	"looks",
	"damage",
	"battle_scene",
	"dead_player",
	"selection",
	"state_stream",
	"shop_change",
	"run_parts",
	"battle_start",
	"cursor_key",
	"upgrades_change",
	"lobby_menu",
	"network_stalls",
	"traffic",
	"progress",
	"client_report",
	"axolotl",
	"own_pickups",
]
const FAKE_PEER := 4242
const WATCHDOG_SEC := 120.0
const DEVICE := VirtualDevices.FIRST
const BIT_ACCEPT := 1

var _failures := []
var _finished := false
var _seq := 0
var _presses = PressCounter.new()
var _suite = null  # the running suite's test object, kept alive across its yields


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	call_deferred("_run")


# Desktop platforms flush parsed input events every frame; the headless platform never does.
func _process(_delta: float) -> void:
	Input.flush_buffered_events()


func _run() -> void:
	yield(get_tree().create_timer(1.0), "timeout")
	print("MOD-TESTS: START")
	get_tree().create_timer(WATCHDOG_SEC).connect("timeout", self, "_on_watchdog")
	_check_shards()
	var together := get_node("/root/ModLoader/einfluffles-BrotatoTogether")
	for suite in _selected_suites():
		var started := OS.get_ticks_msec()
		var state = call("_suite_%s" % suite, together)
		if state is GDScriptFunctionState:
			yield(state, "completed")
		_suite = null
		print("  info: suite %s took %.1f s" % [suite, (OS.get_ticks_msec() - started) / 1000.0])
	_finish()


# MOD_TEST_SUITES in SUITES order; all of them when it is empty, none if it names an unknown one.
func _selected_suites() -> Array:
	var wanted := []
	for entry in OS.get_environment("MOD_TEST_SUITES").split(",", false):
		var suite: String = entry.strip_edges()
		if suite != "" and not suite in wanted:
			wanted.append(suite)
	if wanted.empty():
		return SUITES.duplicate()
	var selected := []
	for suite in wanted:
		if not suite in SUITES:
			_check(false, "unknown suite %s" % suite)
	if not _failures.empty():
		return selected
	for suite in SUITES:
		if suite in wanted:
			selected.append(suite)
	return selected


# shards.txt (one process per line, comma-separated suites) must name every suite exactly once.
func _check_shards() -> void:
	var file := File.new()
	if file.open(SHARDS_PATH, File.READ) != OK:
		_check(false, "shards.txt readable")
		return
	var shards := {}  # suite -> number of lines naming it
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		for entry in line.split(",", false):
			var suite: String = entry.strip_edges()
			if suite != "":
				shards[suite] = shards.get(suite, 0) + 1
	file.close()
	var failures := _failures.size()
	for suite in shards:
		if not suite in SUITES:
			_check(false, "shards.txt names unknown suite %s" % suite)
	for suite in SUITES:
		if shards.get(suite, 0) != 1:
			_check(false, "shards.txt has suite %s in %d shards" % [suite, shards.get(suite, 0)])
	if _failures.size() == failures:
		print("  info: shards.txt has each of the %d suites in one shard" % SUITES.size())


# The two-player co-op run the battle and shop suites play in (built and checked by the core
# suite's run state round trip): characters 0 and 1, a pistol for player 0, a +1 weapon slot
# item and 37 gold for player 1, both players on pads. wave: the wave the full sequence had
# reached there (0: the one RunData.reset() picks).
func coop_run(wave := 0) -> void:
	get_tree().paused = false
	Puppet.set_active(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
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
	if wave > 0:
		RunData.current_wave = wave


# --- suites ---


func _suite_battle_loopback(together: Node):
	coop_run(3)
	_suite = BattleLoopbackTests.new(self)
	yield(_suite.run(together), "completed")


func _suite_input_ack(together: Node):
	coop_run(3)
	_suite = InputAckTests.new()
	yield(_suite.run(self, together), "completed")


func _suite_pose_mirror(together: Node):
	coop_run(3)
	_suite = PoseMirrorTests.new(self)
	yield(_suite.run(together), "completed")


func _suite_anim_mirror(together: Node):
	coop_run(3)
	_suite = AnimMirrorTest.new()
	yield(_suite.run(self, together), "completed")


func _suite_runtime_parts(together: Node):
	coop_run(3)
	_suite = RuntimePartsTests.new(self)
	yield(_suite.test_runtime_parts(together), "completed")


func _suite_battle_perf(together: Node):
	coop_run(3)
	_suite = PerfTests.new(self)
	yield(_suite.test_battle(together), "completed")


# Variants the game actually uses (ZoneService.bullets_hell); BulletHell_0..3 are unused
# leftovers (2 and 3 are even broken in the game: bullet groups in a single-bullet variable).
func _suite_bullet_hell_left(together: Node):
	yield(_bullet_hell(together, "BulletHell_Left"), "completed")


func _suite_bullet_hell_top(together: Node):
	yield(_bullet_hell(together, "BulletHell_Top_2"), "completed")


func _suite_bullet_hell_bottom(together: Node):
	yield(_bullet_hell(together, "BulletHell_Bottom_3"), "completed")


func _bullet_hell(together: Node, variant: String):
	coop_run(3)
	_suite = BulletHellTests.new(self)
	yield(_suite.run(together, variant), "completed")


func _suite_menu_ux(together: Node):
	coop_run(3)
	_suite = MenuUxTests.new()
	yield(_suite.run_battle_tests(self, together), "completed")


func _suite_shop_loopback(together: Node):
	coop_run(2)
	_suite = ShopLoopbackTests.new(self)
	yield(_suite.run(together), "completed")


func _suite_local_shop(together: Node):
	coop_run(2)
	_suite = LocalShopTests.new()
	yield(_suite.run(self, together), "completed")


func _suite_local_device(together: Node):
	coop_run(2)
	_suite = LocalDeviceTests.new()
	yield(_suite.run(self, together), "completed")


func _suite_pause_input(together: Node):
	coop_run(2)
	# Like a real shop or battle: the game is not listening for joining players (with it on, the
	# pause menu's FocusEmulator lets every device's events through).
	var listening: bool = CoopService.listening_for_inputs
	CoopService.listening_for_inputs = false
	_suite = PauseInputTests.new(self, together)
	yield(_suite.run(), "completed")
	CoopService.listening_for_inputs = listening


func _suite_live_menu(together: Node):
	coop_run(2)
	_suite = LiveMenuTests.new()
	yield(_suite.run(self, together), "completed")


func _suite_cleanup_host(together: Node):
	coop_run(8)
	_suite = CleanupTests.new()
	yield(_suite.run_host(self, together), "completed")


func _suite_cleanup_client(together: Node):
	coop_run(8)
	_suite = CleanupTests.new()
	yield(_suite.run_client(self, together), "completed")


func _suite_cleanup_misc(together: Node):
	coop_run(8)
	_suite = CleanupTests.new()
	yield(_suite.run_misc(self, together), "completed")


func _suite_feedback(together: Node):
	coop_run(8)
	_suite = FeedbackTests.new()
	yield(_suite.run(self, together), "completed")


func _suite_looks(together: Node):
	coop_run(8)
	_suite = LooksTests.new()
	yield(_suite.run(self, together), "completed")


func _suite_damage(together: Node):
	coop_run(3)
	_suite = DamageMeterTests.new(self)
	yield(_suite.run(together), "completed")


func _suite_battle_scene(together: Node):
	coop_run(3)
	_suite = BattleSceneTests.new()
	yield(_suite.run(self, together), "completed")


func _suite_dead_player(together: Node):
	_suite = DeadPlayerTests.new()
	yield(_suite.run(self, together), "completed")


# sync/state_stream.gd with its own streams on a fake session; touches no game state.
func _suite_state_stream(together: Node):
	_suite = StateStreamTests.new()
	yield(_suite.run(self, together), "completed")


# Change detection of the host's shop state, with the cost of a check in small and late runs.
func _suite_shop_change(together: Node):
	coop_run(2)
	_suite = ShopChangeTests.new()
	yield(_suite.run(self, together), "completed")


# The run state of the shop and the level-up panels in parts, only those a client lacks, with
# what a change costs on the wire, on the host and on a client before and now.
func _suite_run_parts(together: Node):
	_suite = RunPartsTests.new()
	yield(_suite.run(self, together), "completed")


# BATTLE_START carries only the run parts a client lacks: bytes per client and the client's
# time before change_scene, before and now.
func _suite_battle_start(together: Node):
	_suite = BattleStartTests.new()
	yield(_suite.run(self, together), "completed")


# The cursors' key against their description on the co-op shop (cursor_key_tests.gd; the
# level-up panels and the retry prompt are checked in battle_loopback and menu_ux).
func _suite_cursor_key(together: Node):
	coop_run(2)
	_suite = CursorKeyTests.new(self, together)
	yield(_suite.run_shop(), "completed")


# Change detection of the run state of the host's level-up / crate panels, with the cost of a
# send and of a level-up sequence in small and late runs.
func _suite_upgrades_change(together: Node):
	_suite = UpgradesChangeTests.new()
	yield(_suite.run(self, together), "completed")


# The lobby in the game's menus (lobby_menu_tests.gd): title screen, character selection, the
# client's popup, the pause menu. Sets up its own scenes and run.
func _suite_lobby_menu(together: Node):
	_suite = LobbyMenuTests.new()
	yield(_suite.run(self, together), "completed")


# Render delay, gap log lines and session paths; the client side of a stall in a puppet battle
# runs in battle_loopback.
func _suite_network_stalls(together: Node) -> void:
	NetworkStallTests.new(self).run(together)


# What went out reliably to a peer, for the slow answer, gap and burst lines (net/traffic.gd).
func _suite_traffic(_together: Node) -> void:
	TrafficTests.new(self).run()


# Character selection: the menu mirror leaves the scene with two co-op players that the grid and
# colour tests use. Then each machine's own scroll, join slots and weapon panels.
func _suite_progress(together: Node) -> void:
	_suite = ProgressShareTests.new(self)
	_suite.run(together)


# A client's frame, stall and correction reports and the host's lines for them; ends with a
# short battle the host records and a client replays.
func _suite_client_report(together: Node):
	coop_run(3)
	_suite = ClientReportTests.new(self)
	yield(_suite.run(together), "completed")


# The Axolotl's text (DLC 1) in the broken state the game leaves its shared effect in during
# co-op: no method call on null (a crash in a release build of the game).
func _suite_axolotl(together: Node):
	_suite = AxolotlTests.new(self)
	yield(_suite.run(together), "completed")


func _suite_own_pickups(together: Node):
	coop_run(3)
	_suite = OwnPickupsTests.new(self)
	yield(_suite.run(together), "completed")


func _suite_selection(together: Node):
	yield(_test_menu_mirror(together), "completed")
	_suite = MenuUxTests.new()
	yield(_suite.run_menu_tests(self, together), "completed")
	_suite = CoopSelectionTests.new()
	yield(_suite.run(self, together), "completed")
	_suite = MenuPuppetTests.new()
	yield(_suite.run(self, together), "completed")
	_suite = SelectionScreenTests.new()
	yield(_suite.run(self, together), "completed")


# Input sync, session lifecycle, DLC borrowing, the run state round trip. First in any process:
# it checks that no session hook is installed yet.
func _suite_core(together: Node):
	var input_sync: Node = together.input_sync
	PerfTests.new(self).test_no_global_hooks(together)
	SnapshotTests.new(self).run()

	# Virtual actions exist and survive the game's InputMap rebuild.
	_check(InputMap.has_action("ui_accept_%s" % DEVICE), "virtual actions registered")
	InputService.enable_gamepad_movement()
	_check(InputMap.has_action("analog_move_left_%s" % DEVICE), "actions survive rebuild")

	# No overlay of the mod's own: nothing is open, and without Steam the texts say why.
	var lobby: Node = together.get_node("LobbyMenu")
	_check(lobby.open_page() == null, "lobby page starts closed")
	_check("Steam is unavailable" in lobby.details_text(), "lobby details without Steam")
	_check(lobby.status_text() == "Online: needs Steam", "lobby status line without Steam")

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
	yield(get_tree().create_timer((input_sync.INPUT_TIMEOUT_MSEC + 100) / 1000.0), "timeout")
	input_sync._release_timed_out()
	_check(
		Input.get_action_strength("analog_move_right_%s" % DEVICE) == 0.0, "timeout releases move"
	)

	_test_host_timeout(together)
	SessionLifecycleTests.new().run(self, together)
	DlcBorrowTests.new().run(self, together)
	_test_run_state_round_trip()


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
	coop_run()
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


# Stops the sound managers so their queues show what was played; returns the muted count so far.
func _hold_sounds(hold: bool) -> int:
	for manager in [SoundManager, SoundManager2D]:
		manager.clear_queue()
		manager.set_process(not hold)
	return SoundRelay.dropped_count()


# Character selection with two co-op players: the menu state names the screen and who selected,
# the grids every element. The waiting screen (no copy of the host's screen) shows the key art.
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
	Utils.get_focus_emulator(0, scene).focused_control = element
	var state: Dictionary = menu_sync._state()
	state["you"] = 1
	state = bytes2var(var2bytes(state), false)
	_check(state.kind == "character_selection", "menu kind %s" % state.kind)
	_check(state.count == 2 and state.selected == [false, false], "menu: players %s" % [state])
	var ids := []
	for entry in menu_sync.grids_state().inventories[0]:
		ids.append(entry[0])
	_check(element.item.my_id in ids, "menu grids name the host's elements")

	var view = ClientView.new()
	get_tree().root.add_child(view)
	view.show_menu({"kind": "title_screen"})
	_check(view._title.text != "", "waiting screen says where the host is")
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


func _find_by_id(elements: Array, my_id: String):
	for element in elements:
		if element.my_id == my_id:
			return element
	return null


func _send(input_sync: Node, move: Vector2, aim: Vector2, buttons: int) -> void:
	_seq += 1
	var counts: int = _presses.sample(buttons)
	input_sync._apply_input(FAKE_PEER, [_seq, move, aim, buttons, counts, 0, PoolVector2Array(), 0])


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
