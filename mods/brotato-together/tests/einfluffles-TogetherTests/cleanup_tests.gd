extends Reference
# Endless runs: nothing a wave allocated may outlive it. Compares the engine's object counts at the
# same point of every round; the first rounds still load scenes and fill caches. The waves end as
# in a session: the next scene replaces the battle, nobody calls the cleanup.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const ShopStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_stream_tests.gd"
)
const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const TREE := "res://entities/units/neutral/tree.tscn"
const ENEMY := "res://entities/units/enemies/crash_zone/basic/baby_alien/baby_alien.tscn"
const BULLET := "res://projectiles/bullet/bullet_projectile.tscn"
const SOUND := "res://entities/units/player/step_sounds/Step 1.mp3"
const LOAD := {"enemies": 400, "bullets": 200, "gold": 50}  # a late endless wave
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
const KEPT_ON_PURPOSE := ["_seqs", "_seq_keys"]

var _t: Node
var _together: Node
var _markers_seen := 0
var _flash_ended := false
var _ignored_logs := []


func run_host(test_mod: Node, together: Node):
	yield(_begin(test_mod, together), "completed")
	var host: Node = together.battle_host
	var host_counts := []
	var recording := {}
	for _round in ROUNDS:
		recording = yield(_host_wave(host), "completed")
		yield(_blank_scene(), "completed")
		host_counts.append(_sample())
	_report("host", host_counts)
	_t._check(recording.spawn_id_kept, "host: a spawned entity keeps the net id its spawn gave it")
	var markers := 0
	for key in recording.start.types.values():
		markers += 1 if "#birth_" in key else 0
	_t._check(markers > 0, "host: spawn markers are part of the wave (%d kinds)" % markers)
	var times: Array = recording.times
	_t._check(
		times[1] - times[0] > 15 and times[1] - times[0] < 60 and times[2] - times[0] > 2000,
		"host: snapshot time follows the simulation %s" % [times]
	)
	_test_clock(host)
	_t._check(
		not host._battle_live and not host.is_in_battle(),
		"host: the wave ends when its scene is replaced"
	)
	_t._check(_kept([host]).empty(), "host: nothing of the wave is kept %s" % [_kept([host])])
	_t._check(_dangling().empty(), "host: no reference to a freed node %s" % [_dangling()])
	yield(_end(), "completed")


func run_client(test_mod: Node, together: Node):
	yield(_begin(test_mod, together), "completed")
	var client: Node = together.battle_client
	var shop_sync: Node = together.shop_sync
	var recording: Dictionary = yield(_host_wave(together.battle_host), "completed")
	yield(_blank_scene(), "completed")
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
	_t._check(_markers_seen > 0, "client: spawn markers shown and flickering (%d)" % _markers_seen)
	_t._check(_flash_ended, "client: a hit flash ends")
	var kept := _kept([client, together.upgrades_sync])
	_t._check(kept.empty(), "client: nothing of the wave is kept %s" % [kept])
	_t._check(_dangling().empty(), "client: no reference to a freed node %s" % [_dangling()])
	yield(_end(), "completed")


func run_misc(test_mod: Node, together: Node):
	yield(_begin(test_mod, together), "completed")
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var shop_sync: Node = together.shop_sync
	var recording: Dictionary = yield(_host_wave(host), "completed")
	yield(_blank_scene(), "completed")
	var shop: Dictionary = yield(_host_shop_body(shop_sync), "completed")
	yield(_test_starts(client, recording), "completed")
	yield(_test_shop_states(shop_sync, shop), "completed")
	yield(_measure(host, client), "completed")
	yield(_end(), "completed")


func _begin(test_mod: Node, together: Node):
	_t = test_mod
	_together = together
	together.battle_host.set_process(false)
	together.shop_sync.set_process(false)
	_t.get_tree().paused = false
	CoopService.connected_players.clear()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.current_wave = 8
	# Log lines are the one thing that is kept on purpose (3 per wave): out of the counts.
	_ignored_logs = ModLoaderStore.ml_options.ignored_mod_names_in_log
	ModLoaderStore.ml_options.ignored_mod_names_in_log = _ignored_logs + [MOD_LOGS]
	_load_every_sound_player()
	yield(_t.get_tree(), "idle_frame")


# The game's sound players (12 per sound manager) each keep a playback object from their first
# stream: warm them all so a wave leaves none behind.
func _load_every_sound_player() -> void:
	var sound: AudioStream = load(SOUND)
	for manager in [SoundManager, SoundManager2D]:
		for player in manager.get_children():
			if player.stream == null:
				player.stream = sound


func _end():
	ModLoaderStore.ml_options.ignored_mod_names_in_log = _ignored_logs
	Puppet.set_active(false)
	yield(_blank_scene(), "completed")
	_together.battle_host.set_process(true)
	_together.shop_sync.set_process(true)


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
	var spawned: Node = _t._spawn_on_host(
		main._entity_spawner, TREE, EntityType.NEUTRAL, Vector2(600, 600)
	)
	var spawn_id: int = spawned.get_meta(host.NET_ID_META)
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
	var first: Dictionary = Snapshot.parse(recorded[0][1])
	var times := [first.t, Snapshot.parse(recorded[1][1]).t, Snapshot.parse(recorded[-1][1]).t]
	return {
		"start": start,
		"recorded": recorded,
		"spawn_id_kept": spawn_id in Array(first.ids),
		"times": times,
	}


func _host_shop_body(shop_sync: Node):
	var tree := _t.get_tree()
	tree.change_scene(RunData.get_shop_scene_path())
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	shop_sync._host_shop = tree.current_scene
	var body: Dictionary = shop_sync.state_body(StateStream.RUN_SHOP)
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
		for birth in client._main._births_container.get_children():
			_markers_seen += 1 if birth.visible and birth.is_physics_processing() else 0
	var player: Node = client._main._players[0]
	player.flash()
	var flashing: bool = player.sprite.material == player.flash_mat
	yield(tree.create_timer(0.3), "timeout")
	_flash_ended = flashing and player.sprite.material != player.flash_mat


func _client_shop(shop_sync: Node, body: Dictionary):
	shop_sync._client_shop_id = 0
	ShopStreamTests.deliver(shop_sync.state_stream, StateStream.RUN_SHOP, body)
	yield(shop_sync, "shop_entered")
	yield(_t.get_tree().create_timer(SETTLE_SEC), "timeout")


# A scene with nothing in it, so that the counts of two rounds compare. Changed to like the game
# changes scenes: the old one is gone before the new one is the current scene.
func _blank_scene():
	var tree := _t.get_tree()
	var blank := Node.new()
	blank.name = "WaveCleanupBlank"
	var packed := PackedScene.new()
	packed.pack(blank)
	blank.free()
	tree.change_scene_to(packed)
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
	client._on_battle_start(second)
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	_t._check(
		tree.current_scene == main and client._main == main, "a resync mid-wave keeps the battle"
	)
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


# Three physics steps in one frame are three steps of the wave; a pause or a long hitch puts the
# snapshot clock back onto the wall clock.
func _test_clock(host: Node) -> void:
	var now := 100000
	var t0: float = host.advance_clock(float(now), now)
	var t1: float = host.advance_clock(t0, now)
	var t2: float = host.advance_clock(t1, now)
	_t._check(
		abs(t1 - t0 - 1000.0 / 60.0) < 0.01 and abs(t2 - t1 - 1000.0 / 60.0) < 0.01,
		"snapshot clock: one step is 1/60 s whenever it runs"
	)
	_t._check(host.advance_clock(t2, now + 5000) == now + 5000.0, "snapshot clock: back after a pause")


# What a late endless wave costs per snapshot on the host and per frame on a client.
func _measure(host: Node, client: Node):
	var tree := _t.get_tree()
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main: Node = tree.current_scene
	host._start_battle(main)
	for i in LOAD.enemies:
		var at := Vector2(200 + (i % 40) * 40, 200 + (i / 40) * 100)
		_t._spawn_on_host(main._entity_spawner, ENEMY, EntityType.ENEMY, at)
	var bullet: PackedScene = load(BULLET)
	for i in LOAD.bullets:
		var node: Node2D = bullet.instance()
		main._player_projectiles.add_child(node)
		node.global_position = Vector2(100 + i * 8, 900)
		PuppetEntity.puppetize(node)  # never shot: no stats, no pool id, must hit nothing
	main.spawn_gold(LOAD.gold, Vector2(1000, 700), 300)
	yield(tree, "idle_frame")
	var recorded := []
	var build_usec := 0
	for _i in 30:
		yield(tree, "physics_frame")
		var before := OS.get_ticks_usec()
		var message: Array = host._build_snapshot()
		build_usec += OS.get_ticks_usec() - before
		recorded.append(bytes2var(var2bytes(message), false))
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	var bytes: int = var2bytes(recorded[-1]).size()
	var nodes: int = Snapshot.parse(recorded[-1][1]).ids.size()
	print(
		"  info: host builds a snapshot of %d nodes in %.2f ms (%d B)"
		% [nodes, build_usec / 30000.0, bytes]
	)
	client._on_battle_start(start)
	yield(client, "battle_entered")
	client.set_process(false)
	var cache := {}
	var parse_usec := OS.get_ticks_usec()
	var views := []
	for msg in recorded:
		views.append(Snapshot.resolve(Snapshot.parse(msg[1]), cache))
	parse_usec = OS.get_ticks_usec() - parse_usec
	var spawn_usec := OS.get_ticks_usec()
	client._apply_entities(views[0], views[1], 0.5)
	spawn_usec = OS.get_ticks_usec() - spawn_usec
	var frame_usec := OS.get_ticks_usec()
	for i in range(1, 29):
		client._apply_entities(views[i], views[i + 1], 0.5)
	frame_usec = OS.get_ticks_usec() - frame_usec
	print(
		(
			"  info: client applies them in %.2f ms per frame (first frame, spawning: %.1f ms;"
			+ " parsing a snapshot: %.2f ms)"
		)
		% [frame_usec / 28000.0, spawn_usec / 1000.0, parse_usec / 30000.0]
	)
	_t._check(client._entities.size() == nodes, "client mirrors the whole late wave")
	# Everything leaves and comes back: what a spawn costs once the pools are filled.
	var empty: Dictionary = views[-1].duplicate()
	empty["ids"] = PoolIntArray()
	empty["types"] = PoolIntArray()
	empty["positions"] = PoolVector2Array()
	empty["flags"] = PoolByteArray()
	empty["poses"] = {}
	empty.erase("index")
	client._apply_entities(views[-1], empty, 1.0)
	yield(tree.create_timer(2.5), "timeout")
	var again: Dictionary = views[-1].duplicate()
	again.erase("index")
	var respawn_usec := OS.get_ticks_usec()
	client._apply_entities(again, again, 1.0)
	respawn_usec = OS.get_ticks_usec() - respawn_usec
	print(
		"  info: client respawns %d pooled puppets in %.1f ms (%.0f usec each)"
		% [client._entities.size(), respawn_usec / 1000.0, respawn_usec / float(nodes)]
	)
	client.set_process(true)
	client._leave_battle()



# The same for the shop: two states in one frame enter it once, and the second one (the
# other player ready) is applied once the shop is.
func _test_shop_states(shop_sync: Node, body: Dictionary):
	var tree := _t.get_tree()
	var ready: Dictionary = body.duplicate()
	ready.go = [false, true]
	shop_sync._client_shop_id = 0
	ShopStreamTests.deliver(shop_sync.state_stream, StateStream.RUN_SHOP, body)
	ShopStreamTests.deliver(shop_sync.state_stream, StateStream.RUN_SHOP, ready)
	yield(shop_sync, "shop_entered")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	_t._check(
		shop_sync.is_in_shop() and tree.current_scene == shop_sync._client_shop,
		"two shop states in one frame: one guarded shop"
	)
	_t._check(
		shop_sync._client_shop._player_pressed_go_button.slice(0, 1) == [false, true]
		and not shop_sync.state_stream.is_pending(StateStream.RUN_SHOP),
		"the state that came while the shop loaded is applied once it is ready"
	)
