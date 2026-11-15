extends Reference
# Endless runs: nothing a wave allocated may outlive it. Plays several short waves as the host,
# then replays one as a client several times (battle -> shop -> battle ...), and compares the
# engine's object counts at the same point of every round. The first rounds still load scenes
# and fill caches; after them the counts must stand still. The waves end the way they do in a
# session: the next scene replaces the battle, nobody calls the cleanup.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const ROUNDS := 6
const WARM_UP := 2
const WAVE_MSEC := 2400
const KILL_AT_MSEC := 1500  # the wave's enemies die here: loot, death animations, pools
const SETTLE_SEC := 0.7  # death animations and the game's short timers
const MONITORS := [
	["orphan nodes", Performance.OBJECT_ORPHAN_NODE_COUNT],
	["nodes", Performance.OBJECT_NODE_COUNT],
	["objects", Performance.OBJECT_COUNT],
	["resources", Performance.OBJECT_RESOURCE_COUNT],
]
const MOD_LOGS := "einfluffles-BrotatoTogether*"  # the Mod Loader keeps every log entry
# Bounded and meant to last: caches per scene / sound, one value per player or peer.
const KEPT_ON_PURPOSE := ["_seqs", "_seq_keys", "_meca_stats"]

var _t: Node
var _together: Node


func run(test_mod: Node, together: Node):
	_t = test_mod
	_together = together
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var shop_sync: Node = together.shop_sync
	host.set_process(false)
	shop_sync.set_process(false)
	_t.get_tree().paused = false
	CoopService.connected_players.clear()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.current_wave = 8
	# Log lines are the one thing that is kept on purpose (3 per wave): out of the counts.
	var ignored: Array = ModLoaderStore.ml_options.ignored_mod_names_in_log
	ModLoaderStore.ml_options.ignored_mod_names_in_log = ignored + [MOD_LOGS]

	var host_counts := []
	var recording := {}
	for _round in ROUNDS:
		recording = yield(_host_wave(host), "completed")
		yield(_blank_scene(), "completed")
		host_counts.append(_sample())
	_report("host", host_counts)
	_t._check(
		not host._battle_live and not host.is_in_battle(),
		"host: the wave ends when its scene is replaced"
	)
	_t._check(_kept([host]).empty(), "host: nothing of the wave is kept %s" % [_kept([host])])
	_t._check(_dangling().empty(), "host: no reference to a freed node %s" % [_dangling()])

	var shop: Dictionary = yield(_host_shop_body(shop_sync), "completed")
	var client_counts := []
	for _round in ROUNDS:
		yield(_client_wave(client, recording), "completed")
		yield(_client_shop(shop_sync, shop), "completed")
		client_counts.append(_sample())
	_report("client", client_counts)
	_t._check(
		not client.is_in_battle() and client._main_id == 0 and client._battle_id == 0,
		"client: the wave ends when the shop replaces its scene"
	)
	_t._check(not RunData.wave_in_progress, "client: no wave in progress in the shop")
	var kept := _kept([client, together.upgrades_sync])
	_t._check(kept.empty(), "client: nothing of the wave is kept %s" % [kept])
	_t._check(_dangling().empty(), "client: no reference to a freed node %s" % [_dangling()])
	yield(_test_starts(client, recording), "completed")

	ModLoaderStore.ml_options.ignored_mod_names_in_log = ignored
	Puppet.set_active(false)
	yield(_blank_scene(), "completed")
	host.set_process(true)
	shop_sync.set_process(true)


# One wave on the host with the mod's hooks, recorded like BattleHost sends it.
func _host_wave(host: Node):
	var tree := _t.get_tree()
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main: Node = tree.current_scene
	host._start_battle(main)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var killed := false
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < WAVE_MSEC:
		yield(tree.create_timer(1.0 / 30.0), "timeout")
		if not killed and OS.get_ticks_msec() - t0 > KILL_AT_MSEC:
			killed = true
			for enemy in main._entity_spawner.enemies.duplicate():
				if is_instance_valid(enemy) and not enemy.dead:
					enemy.die()
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	return {"start": start, "recorded": recorded}


func _host_shop_body(shop_sync: Node):
	var tree := _t.get_tree()
	tree.change_scene(RunData.get_shop_scene_path())
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	shop_sync._host_shop = tree.current_scene
	var body: Dictionary = bytes2var(var2bytes(shop_sync._shop_body()), false)
	shop_sync._host_shop = null
	return body


func _client_wave(client: Node, recording: Dictionary):
	var tree := _t.get_tree()
	client._on_battle_start(recording.start)
	yield(client, "battle_entered")
	var recorded: Array = recording.recorded
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(tree, "idle_frame")
		client._on_snapshot(snap)
	yield(tree.create_timer(0.3), "timeout")


func _client_shop(shop_sync: Node, body: Dictionary):
	var state := RunStateCodec.decode(body.run)
	shop_sync._client_shop_id = 0
	shop_sync._pending = {"state": state, "slots": body.slots, "go": body.go}
	shop_sync._client_shop_id = body.shop_id
	shop_sync._enter_shop(state)
	yield(shop_sync, "shop_entered")
	yield(_t.get_tree().create_timer(SETTLE_SEC), "timeout")


# A scene with nothing in it, so that the counts of two rounds compare.
func _blank_scene():
	var tree := _t.get_tree()
	var previous := tree.current_scene
	var blank := Node.new()
	blank.name = "WaveCleanupBlank"
	tree.root.add_child(blank)
	tree.current_scene = blank
	if previous != null:
		previous.queue_free()
	yield(tree.create_timer(SETTLE_SEC), "timeout")


func _sample() -> Dictionary:
	var sample := {}
	for monitor in MONITORS:
		sample[monitor[0]] = int(Performance.get_monitor(monitor[1]))
	return sample


func _report(side: String, counts: Array) -> void:
	for monitor in MONITORS:
		var name: String = monitor[0]
		var series := []
		for sample in counts:
			series.append(sample[name])
		_t._check(
			series[-1] <= series[WARM_UP], "%s: %s stand still across waves %s" % [side, name, series]
		)


# Containers of the mod's long-lived nodes that still hold something.
func _kept(nodes: Array) -> Array:
	var kept := []
	for node in nodes:
		for property in node.get_property_list():
			if not property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				continue
			var value = node.get(property.name)
			var size := 0
			if typeof(value) == TYPE_DICTIONARY or typeof(value) == TYPE_ARRAY:
				size = value.size()
			if size > 0 and not property.name in KEPT_ON_PURPOSE:
				kept.append("%s.%s=%d" % [node.name, property.name, size])
	return kept


# Variables of the mod's nodes (and their helper objects) that point at a freed object: in the
# game's release build such an address is reused, and is_instance_valid() then says yes.
func _dangling() -> Array:
	var found := []
	for node in _together.get_children():
		_scan(node, node.name, found, 0)
	return found


func _scan(object: Object, path: String, found: Array, depth: int) -> void:
	for property in object.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			_scan_value(object.get(property.name), "%s.%s" % [path, property.name], found, depth)


func _scan_value(value, path: String, found: Array, depth: int) -> void:
	match typeof(value):
		TYPE_OBJECT:
			if not is_instance_valid(value):
				found.append(path)
			elif depth < 2 and value is Reference and not value is Resource:
				_scan(value, path, found, depth + 1)
		TYPE_ARRAY:
			for i in min(value.size(), 64):
				_scan_value(value[i], "%s[%d]" % [path, i], found, depth)
		TYPE_DICTIONARY:
			for key in value.keys().slice(0, 63):
				_scan_value(value[key], "%s[%s]" % [path, key], found, depth)


# Reliable messages can arrive together after a hitch: whatever the order, the client ends up in
# one frozen scene that is the battle it was told last.
func _test_starts(client: Node, recording: Dictionary):
	var tree := _t.get_tree()
	var first: Dictionary = recording.start
	var second: Dictionary = first.duplicate()
	second["battle_id"] = first.battle_id + 1
	client._on_battle_start(first)
	client._on_battle_start(second)
	yield(client, "battle_entered")
	_t._check(client._battle_id == first.battle_id, "the first of two starts loads first")
	yield(client, "battle_entered")
	var main: Node = tree.current_scene
	_t._check(
		client._battle_id == second.battle_id and client._main == main,
		"two battle starts in one frame: the second battle is the one mirrored"
	)
	_t._check(
		not main.is_processing() and not main._wave_manager.is_physics_processing(),
		"and its scene is frozen"
	)
	# A resync of the battle the client is in keeps the scene.
	client._on_battle_start(second)
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	_t._check(
		tree.current_scene == main and client._main == main, "a resync mid-wave keeps the battle"
	)
	# The battle ends while the next one's scene is still loading.
	var third: Dictionary = first.duplicate()
	third["battle_id"] = first.battle_id + 2
	client._on_battle_start(third)
	client._on_message(0, 0, null)  # not from the host: ignored
	client._leave_battle()
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var orphaned: Node = tree.current_scene
	_t._check(
		orphaned != main and not client.is_in_battle() and not orphaned.is_processing(),
		"a battle that ended while loading is not played locally"
	)
	# A bullet-hell wave: main._ready adds its own generator, the host's bullets are mirrored.
	var bullet_hell: Node = ZoneService.bullets_hell[0].instance()
	orphaned._enemy_projectiles.add_child(bullet_hell)
	client._freeze(orphaned)
	_t._check(not is_instance_valid(bullet_hell), "no local bullet-hell generator on a client")
