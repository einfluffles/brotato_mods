extends Node
# Headless integration tests, run by tools/check.sh inside the decompiled game (no Steam).
# Prints "TOGETHER-TESTS: PASS" or "TOGETHER-TESTS: FAIL" and quits.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const FAKE_PEER := 4242
const WATCHDOG_SEC := 100.0
const DEVICE := VirtualDevices.FIRST
const BIT_ACCEPT := 1

var _failures := []
var _seq := 0


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	call_deferred("_run")


# Desktop platforms flush parsed input events every frame; the headless platform never does.
func _process(_delta: float) -> void:
	Input.flush_buffered_events()


func _run() -> void:
	yield(get_tree().create_timer(1.0), "timeout")
	print("TOGETHER-TESTS: START")
	get_tree().create_timer(WATCHDOG_SEC).connect("timeout", self, "_on_watchdog")
	var together := get_node("/root/ModLoader/einfluffles-BrotatoTogether")
	var input_sync: Node = together.input_sync

	# Virtual actions exist and survive the game's InputMap rebuild.
	_check(InputMap.has_action("ui_accept_%s" % DEVICE), "virtual actions registered")
	InputService.enable_gamepad_movement()
	_check(InputMap.has_action("analog_move_left_%s" % DEVICE), "actions survive rebuild")

	# Remote player joins via hold-to-join and is typed as a gamepad.
	RunData.set_coop_run(true)
	CoopService.clear_coop_players()
	CoopService.listening_for_inputs = true
	CoopService.set_process_input(true)
	input_sync.devices[FAKE_PEER] = DEVICE
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

	_test_run_state_round_trip()
	yield(_test_battle_loopback(together), "completed")
	yield(_test_shop_loopback(together), "completed")
	yield(_test_menu_mirror(together), "completed")
	_finish()


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
	get_tree().change_scene("res://main.tscn")
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	var main := get_tree().current_scene
	_check(main != null and main.filename == "res://main.tscn", "host battle scene loaded")
	host._main = main
	host._battle_id = 1
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
	upgrades_ui.hide()
	host._main = null
	var last: Dictionary = Snapshot.parse(recorded[-1][1])
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
	yield(client, "battle_entered")
	var puppet_main: Node = client._main
	_check(puppet_main != null and puppet_main != main, "client loaded its own battle scene")
	var spawner = puppet_main.get("_entity_spawner")
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap: Array = msg[1].duplicate()
		snap[1] = replay_start + (snap[1] - recorded[0][1][1])  # host t -> replay timeline
		while OS.get_ticks_msec() < snap[1]:
			yield(get_tree(), "idle_frame")
		client._on_snapshot(Snapshot.parse(snap))
	yield(get_tree().create_timer(0.3), "timeout")
	_check(spawner.enemies.empty(), "client spawner spawned nothing itself")
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
	upgrades_sync.apply(puppet_main, upgrades_msg)
	var client_panels: Array = upgrades_sync.capture(puppet_main.get("_coop_upgrades_ui"))
	_check(client_panels[0] == host_panels[0], "client shows host's level-up options")
	_check(
		client_panels[1][0] == "item" and client_panels[1][2] == host_panels[1][2],
		"client shows host's crate item (%s)" % host_panels[1][2]
	)
	puppet_main.get("_coop_upgrades_ui").hide()
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
	input_sync.history = [[1, Vector2(0.3, 0)], [2, Vector2(1, 0)]]
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
	for id in client._entities:
		if client._entities[id] is Enemy:
			victim = client._entities[id]
			break
	_check(victim != null, "found an enemy puppet")
	if victim != null:
		client._despawn(victim)
		_check(victim.dead and victim.is_inside_tree(), "death animation playing")
		yield(get_tree().create_timer(2.0), "timeout")
		_check(puppet_main.is_in_pool(victim), "dead puppet returned to pool")
		var reused: Node = client._spawn(host._types[victim.filename])
		_check(reused == victim and not reused.dead, "puppet reused from pool")
	# Consumables share one scene; their look comes from data (crate vs. fruit).
	var crate = ItemService.consumables[-1]
	client._define_type(999, "res://items/consumables/consumable.tscn#%s" % crate.my_id)
	var consumable: Node = client._spawn(999)
	_check(
		consumable != null and consumable.consumable_data == crate,
		"consumable gets its data (%s)" % crate.my_id
	)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


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
	var before: Dictionary = bytes2var(var2bytes(shop_sync._shop_body()), false)
	var host_before := _shop_slots(host_shop, 0)

	var container = host_shop._get_shop_items_container(0)
	var bought = container.get_shop_item_node(1)
	var bought_id: String = bought.item_data.my_id
	var gold_before: int = RunData.get_player_gold(0)
	container.on_shop_item_buy_button_pressed(bought)
	yield(get_tree(), "idle_frame")
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
	_check(
		_shop_slots(client_shop, 0) == host_before,
		"client shows host's items %s" % [_shop_slots(client_shop, 0)]
	)

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
	var owned := false
	for element in RunData.get_player_weapons(0) + RunData.get_player_items(0):
		owned = owned or element.my_id == bought_id
	_check(owned, "client inventory has %s" % bought_id)
	Puppet.set_active(false)
	shop_sync.set_process(true)


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
	input_sync._apply_input(FAKE_PEER, [_seq, move, aim, buttons])


func _check(condition: bool, label: String) -> void:
	print("  %s %s" % ["ok  " if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _on_watchdog() -> void:
	_check(false, "watchdog: tests did not finish within %d s" % WATCHDOG_SEC)
	_finish()


func _finish() -> void:
	print("TOGETHER-TESTS: %s" % ("PASS" if _failures.empty() else "FAIL %s" % [_failures]))
	get_tree().quit(0 if _failures.empty() else 1)
