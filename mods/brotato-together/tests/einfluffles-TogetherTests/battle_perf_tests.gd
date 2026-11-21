extends Reference
# Battle mirror robustness and performance: own-player prediction during pauses and stalls, reused
# net ids of pooled nodes, the brachiosaurus foot on clients, recorded sounds, puppet pooling and
# the puppets made while the battle scene loads.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const PF := Snapshot.PlayerField
const BOSSES := "res://entities/units/enemies/jungle/bosses/brachiosaurus/"
const BRACHIOSAURUS := BOSSES + "brachiosaurus.tscn"
const FOOT := BOSSES + "brachiosaurus_foot/brachiosaurus_foot.tscn"
const BULLET := "res://projectiles/bullet/bullet_projectile.tscn"
const STEP_SOUND := "res://entities/units/player/step_sounds/Step 1.mp3"
const EXPLOSION := "res://projectiles/explosion.tscn"

var _t: Node


func _init(tests: Node) -> void:
	_t = tests


func test_no_global_hooks(together: Node) -> void:
	var hooked := []
	for connection in _t.get_tree().get_signal_connection_list("node_added"):
		if connection.target.get_parent() == together:
			hooked.append(connection.target.name)
	_t._check(hooked.empty(), "no node_added hooks outside a session %s" % [hooked])


# Prediction replays at most 0.75 s of un-acked input, and none while paused or when snapshots
# stopped.
func test_prediction(client: Node, input_sync: Node, player: Node2D, entry: Array) -> void:
	var host_entry := entry.duplicate()
	host_entry[PF.INPUT_ACK] = 0
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var direction := Vector2.RIGHT
	if entry[PF.POSITION].x > zone.get_center().x:
		direction = Vector2.LEFT
	var history := []
	for seq in range(1, input_sync.HISTORY_SIZE + 1):  # 3 s of input the host never applied
		history.append([seq, direction])
	var saved: Array = input_sync.history
	input_sync.history = history
	client._newest_rx_msec = OS.get_ticks_msec()
	client._view.place([], {"players": []}, client._you)  # no other player in the way
	var step: float = player.get_move_speed() / float(Engine.iterations_per_second)
	var lead: float = client._own_target(player, host_entry).distance_to(entry[PF.POSITION])
	_t._check(
		abs(lead - client.MAX_REPLAY_INPUTS * step) < 0.5,
		"prediction capped at 0.75 s of input (%.0f px, uncapped %.0f)" % [lead, history.size() * step]
	)
	client._paused = true
	var paused_target: Vector2 = client._own_target(player, host_entry)
	client._paused = false
	client._newest_rx_msec = OS.get_ticks_msec() - client.PREDICTION_STALE_MSEC - 100
	var stale_target: Vector2 = client._own_target(player, host_entry)
	_t._check(
		paused_target == entry[PF.POSITION] and stale_target == entry[PF.POSITION],
		"no prediction while paused or when snapshots stopped"
	)
	input_sync.history = saved


# The own player is idle on the frame after its keys are let go, though a prediction correction is
# still blending out of its displayed position (that kept it running for about a second).
func test_own_animation(client: Node, input_sync: Node, player: Node2D):
	var saved: Array = input_sync.history
	var anim: AnimationPlayer = player._animation_player
	client._newest_rx_msec = OS.get_ticks_msec()
	input_sync.history = [[1, Vector2.LEFT]]
	client._own_error = Vector2(20, 0)
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	_t._check(
		anim.current_animation == player.animation_move and player._sprites[0].scale.x < 0,
		"own player runs and faces the held keys (%s)" % anim.current_animation
	)
	input_sync.history.append([2, Vector2.ZERO])
	client._own_error = Vector2(20, 0)
	yield(_t.get_tree(), "idle_frame")
	_t._check(
		anim.current_animation == player.animation_idle and client._own_error.length() > 1,
		(
			"own player idle on the frame the keys are let go, correction still %.1f px (%s)"
			% [client._own_error.length(), anim.current_animation]
		)
	)
	input_sync.history.append([3, Vector2.RIGHT])
	yield(_t.get_tree(), "idle_frame")
	var ran: bool = anim.current_animation == player.animation_move
	client._paused = true
	yield(_t.get_tree(), "idle_frame")
	_t._check(
		ran and anim.current_animation == player.animation_idle,
		"own player stands while the host's world is paused, keys held (ran before: %s)" % ran
	)
	client._paused = false
	input_sync.history = saved


func test_battle(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	_t.get_tree().change_scene("res://main.tscn")
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var main: Node = _t.get_tree().current_scene
	host._start_battle(main)
	_check_preregistered(host, main)
	var wave_data = main._wave_manager.current_wave_data
	var unit_path: String = wave_data.groups_data[0].wave_units_data[0].unit_scene.resource_path
	_check_pool_reuse_ids(host, main)
	_check_recorded_sounds(host)
	var spawner = main.get("_entity_spawner")
	var boss: Node = _t._spawn_on_host(spawner, BRACHIOSAURUS, EntityType.BOSS, Vector2(1000, 700))
	var foot: Node = _t._spawn_on_host(spawner, FOOT, EntityType.ENEMY, Vector2(700, 700))
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < 700:
		yield(_t.get_tree().create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	var ids := {"boss": boss.get_meta(host.NET_ID_META), "foot": foot.get_meta(host.NET_ID_META)}
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	var foot_type: int = host._types[FOOT]
	var gold_type: int = host._types[main.gold_scene.resource_path]
	var bullet_type: int = host._types[BULLET]
	host._end_battle()
	var views := SnapshotTests.views(recorded)
	var last: Dictionary = views[-1]
	_t._check(
		Snapshot.index_of(last, ids.boss) < Snapshot.index_of(last, ids.foot),
		"host lists bosses before their parts"
	)

	client._warm = client.WarmPools.new()  # what earlier suites' battles needed does not count
	client._on_battle_start(start)
	yield(client, "battle_entered")
	client.set_process(false)
	_check_warm_pools(client, unit_path)
	var foot_only := _single(ids.foot, foot_type, last.positions[Snapshot.index_of(last, ids.foot)])
	client._apply_entities(foot_only, foot_only, 1.0)
	_t._check(not client._entities.has(ids.foot), "foot waits for its boss puppet")
	_check_client_ids(client, gold_type, bullet_type)
	client.set_process(true)
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(_t.get_tree(), "idle_frame")
		client._on_snapshot(snap)
	yield(_t.get_tree().create_timer(0.3), "timeout")
	client.set_process(false)
	var boss_puppet = client._entities.get(ids.boss)
	var foot_puppet = client._entities.get(ids.foot)
	_t._check(
		boss_puppet != null and foot_puppet is BrachiosaurusFoot and foot_puppet.dino_mom == boss_puppet,
		"client spawned the brachiosaurus, then its foot (found its boss, no script errors)"
	)
	if boss_puppet != null:
		var host_position: Vector2 = last.positions[Snapshot.index_of(last, ids.boss)]
		yield(_t.get_tree().create_timer(0.3), "timeout")
		_t._check(
			boss_puppet.global_position.distance_to(host_position) < 1.0,
			"the foot's _ready did not send the boss puppet away"
		)
	var warm = client._warm
	var used: int = warm._taken.get(unit_path, 0) + warm._fresh.get(unit_path, 0)
	var needed := int(max(used, warm._prepared.get(unit_path, 0) / 2))
	_check_puppet_pool(client, bullet_type)  # ends with the battle's state reset
	_t._check(
		warm.needed.get(unit_path) == needed and needed >= 1 and warm._prepared.empty(),
		"what the battle used (%d %s) is what the next one makes" % [needed, unit_path.get_file()]
	)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


# Enemies and explosions are made in the frame that loads the battle, not mid-wave.
func _check_warm_pools(client: Node, unit_path: String) -> void:
	var main: Node = client._main
	var unit: PackedScene = load(unit_path)
	var pool: Array = main._pool.get(unit.get_instance_id(), [])
	var ready := 0
	for node in pool:
		if (
			is_instance_valid(node) and node is Enemy and not node.is_inside_tree()
			and node.collision_layer == 0 and node.pool_id == unit.get_instance_id()
		):
			ready += 1
	_t._check(
		ready == client._warm.ENEMIES and pool.size() == ready
		and client._warm.needed.get(unit_path) == client._warm.ENEMIES,
		"the wave's enemies are in main's pool, puppetized (%d %s)" % [ready, unit_path.get_file()]
	)
	var explosions: Array = main._pool.get(load(EXPLOSION).get_instance_id(), [])
	_t._check(
		explosions.size() == client._warm.EXPLOSIONS and explosions[0] is PlayerExplosion
		and not explosions[0].is_inside_tree(),
		"and explosions (%d)" % explosions.size()
	)
	_t._check(
		client._warm.needed.get(BULLET) == 0 and client._warm.needed.get(BRACHIOSAURUS) == 0
		and not client._warm.needed.has(FOOT),
		"not projectiles, bosses or a boss part without its boss"
	)
	var idx := -1
	for k in client._types:
		if client._types[k] == unit:
			idx = k
	var expected = pool[-1] if not pool.empty() else null
	var taken: Node = client._spawn(idx)
	_t._check(
		taken != null and taken == expected and taken.is_inside_tree() and taken.visible
		and not taken.dead and client._warm._taken.get(unit_path) == 1
		and not taken.has_meta(client._warm.PREPARED_META),
		"a spawn takes a prepared puppet, no new one, and counts it as used"
	)
	client._despawn(taken)
	_t._check(client._pose._layouts.has(unit_path), "its pose layout was derived while loading")
	var manager: Node = main._effects_manager
	var hits: Array = main._pool.get(manager.hit_particles.get_instance_id(), [])
	_t._check(
		hits.size() == client._warm.EFFECTS.hit_particles and not hits[0].is_inside_tree()
		and hits[0].is_connected("finished", manager, "on_graphical_effect_finished"),
		"hit effects are made the way EffectsManager.play makes them (%d)" % hits.size()
	)
	# A scene under two type indices (a cursed and a normal structure) is made once.
	var warm = client.WarmPools.new()
	for path in client._warm.needed:
		warm.needed[path] = 0
	warm.needed[unit_path] = 1000
	var before := pool.size()
	warm.fill(client, main, {0: unit, 1: unit})
	_t._check(
		pool.size() - before == warm.MAX_PER_TYPE and warm._prepared[unit_path] == warm.MAX_PER_TYPE,
		(
			"a scene with two type indices is made once, at most %d (%d)"
			% [warm.MAX_PER_TYPE, pool.size() - before]
		)
	)
	var counts := {"big.tscn": 30, "small.tscn": 4, "mid.tscn": 12}
	var order: Array = counts.keys()
	order.sort_custom(warm.ByCount.new(counts), "first")
	_t._check(order == ["small.tscn", "mid.tscn", "big.tscn"], "small kinds first: %s" % [order])
	warm._prepared = {"a": 6, "b": 6, "c": 1}
	warm._taken = {"a": 1, "b": 6}
	warm._fresh = {"b": 5, "d": 3}
	warm.remember()
	_t._check(
		warm.needed.a == 3 and warm.needed.b == 11 and warm.needed.c == 0 and warm.needed.d == 3
		and warm.last_fresh.hash() == {"b": 5, "d": 3}.hash() and warm._prepared.empty(),
		"next battle: what was used, unused ones halved: %s" % [warm.needed]
	)


func _check_preregistered(host: Node, main: Node) -> void:
	var wave_data = main._wave_manager.current_wave_data
	var unit: String = wave_data.groups_data[0].wave_units_data[0].unit_scene.resource_path
	_t._check(
		host._types.has(main.gold_scene.resource_path) and host._types.has(unit),
		"gold and the wave's units announced with BATTLE_START (%d types)" % host._types.size()
	)


# The game's pools are LIFO: a node pooled and reused between two snapshots is a new entity.
func _check_pool_reuse_ids(host: Node, main: Node) -> void:
	var container: Node = main.get("_player_projectiles")
	var pool_id := 424242
	main.get_node_from_pool(pool_id, container)  # creates the pool
	var bullet: Node = load(BULLET).instance()
	container.add_child(bullet)
	host._build_snapshot()
	var first_id: int = bullet.get_meta(host.NET_ID_META)
	main.add_node_to_pool(bullet, pool_id)
	var reused: Node = main.get_node_from_pool(pool_id, container)
	host._build_snapshot()
	_t._check(
		reused == bullet and bullet.get_meta(host.NET_ID_META) != first_id,
		"projectile pooled and reused between snapshots gets a new net id"
	)
	main.add_node_to_pool(bullet, pool_id)
	bullet.free()
	main._pool.erase(pool_id)


# Recorded = what the game queued: playSingle within its cooldown and a full queue drop sounds.
func _check_recorded_sounds(host: Node) -> void:
	var stream: AudioStream = load(STEP_SOUND)
	_t._hold_sounds(true)
	SoundManager._last_played.erase(stream)
	host._events.clear()
	SoundManager.playSingle(stream, 0, 0, false, 0.5)
	SoundManager.playSingle(stream, 0, 0, false, 0.5)
	var singles := _sound_events(host, stream)
	_t._check(
		singles.size() == 1 and singles[0][6] == 0.5 and SoundManager.sounds_to_play.size() == 1,
		"playSingle within its cooldown neither plays nor is recorded"
	)
	SoundManager.clear_queue()
	host._events.clear()
	for i in SoundManager.MAX_SOUNDS + 3:
		SoundManager.play(stream)
	SoundManager.play(stream, 0.0, 0.0, true)
	var recorded := _sound_events(host, stream)
	_t._check(
		recorded.size() == SoundManager.MAX_SOUNDS + 1 and recorded[-1][5],
		"full queue: dropped sounds not recorded, always_play recorded (%d)" % recorded.size()
	)
	host._events.clear()
	_t._hold_sounds(false)
	# Client replays: playSingle again, with the host's cooldown minus a little timing slack.
	_t._hold_sounds(true)
	SoundManager._last_played.erase(stream)
	var relay = load("res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd")
	relay.replay(stream, null, 0.0, 0.0, false, 0.5)
	relay.replay(stream, null, 0.0, 0.0, false, 0.5)
	_t._check(
		SoundManager.sounds_to_play.size() == 1 and SoundManager._last_played.has(stream),
		"client replays playSingle as playSingle"
	)
	_t._hold_sounds(false)


func _sound_events(host: Node, stream: AudioStream) -> Array:
	var found := []
	for event in host._events:
		if event[0] == Snapshot.EVENT_SOUND and event[1] == host._types.get(stream.resource_path):
			found.append(event)
	return found


func _single(id: int, type: int, position: Vector2, t := 0) -> Dictionary:
	return {
		"t": t,
		"ids": PoolIntArray([id]),
		"types": PoolIntArray([type]),
		"positions": PoolVector2Array([position]),
		"flags": Snapshot.pack_flags([0]),
		"poses": {},
	}


# A jump no entity can make between two snapshots is a reused id: snap, don't lerp across the map.
# An id that comes back with another type is a new entity.
func _check_client_ids(client: Node, gold_type: int, bullet_type: int) -> void:
	var id := 60001
	var a := _single(id, gold_type, Vector2(200, 300), 1000)
	var b := _single(id, gold_type, Vector2(1800, 300), 1033)
	client._apply_entities(a, a, 1.0)
	var node = client._entities.get(id)
	client._apply_entities(a, b, 0.5)
	_t._check(
		node != null and node.global_position == Vector2(1800, 300),
		"implausible jump snaps instead of lerping (%s)" % [node.global_position if node else null]
	)
	var near := _single(id, gold_type, Vector2(1830, 300), 1066)
	client._apply_entities(b, near, 0.5)
	_t._check(
		node != null and node.global_position == Vector2(1815, 300),
		"plausible motion still interpolated"
	)
	var as_bullet := _single(id, bullet_type, Vector2(1830, 300), 1100)
	client._apply_entities(near, as_bullet, 1.0)
	var replaced = client._entities.get(id)
	_t._check(
		replaced != null and replaced != node and replaced is Projectile,
		"id reused for another type: new puppet"
	)


func _check_puppet_pool(client: Node, bullet_type: int) -> void:
	var bullet: Node = client._spawn(bullet_type)
	client._despawn(bullet)
	var pooled: bool = is_instance_valid(bullet) and not bullet.is_inside_tree()
	var again: Node = client._spawn(bullet_type)
	_t._check(
		pooled and again == bullet and bullet.is_inside_tree(),
		"client reuses a pooled projectile puppet"
	)
	client._despawn(again)
	client._reset_battle_state()
	_t._check(not is_instance_valid(bullet), "pooled puppets freed with the battle")
