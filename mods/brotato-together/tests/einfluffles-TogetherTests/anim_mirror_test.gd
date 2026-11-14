extends Reference
# Part of the headless tests (mod_main.gd): run(test, together) yields like the other battle tests.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")

var t: Node = null  # the test mod (checks, helpers)


# Animations the game starts from physics code: a real turret shooting at parked enemies, a catling
# gun going mad next to a player, a spitter's wind-up. The puppets play the host's animations
# without their method tracks: no shoot() and no projectiles of their own on the client.
func run(test: Node, together: Node):
	t = test
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	t.get_tree().change_scene("res://main.tscn")
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var main := t.get_tree().current_scene
	host._start_battle(main)
	var nodes := _spawn_anim_entities(main)
	var ids := {}
	for name in nodes:
		ids[name] = -1
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < 3000:
		yield(t.get_tree().create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
		for name in nodes:
			if ids[name] == -1 and nodes[name].has_meta(host.NET_ID_META):
				ids[name] = nodes[name].get_meta(host.NET_ID_META)
	var host_shots: int = nodes.turret._nb_shots_taken
	var host_catling: String = nodes.catling._animation_player.current_animation
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()
	var anim_events := {}  # net id -> {name: true}
	var anim_bytes := 0
	var anim_count := 0
	for msg in recorded:
		for event in Snapshot.parse(msg[1]).events:
			if event[0] == Snapshot.EVENT_ANIM:
				anim_count += 1
				anim_bytes += 8 + event[2].length()  # on the wire (sync/snapshot.gd)
				if not anim_events.has(event[1]):
					anim_events[event[1]] = {}
				anim_events[event[1]][event[2]] = true
	print(
		(
			"  info: %d anim events from %d entities (%d B in %d snapshots); turret shots %d"
			% [anim_count, anim_events.size(), anim_bytes, recorded.size(), host_shots]
		)
	)
	t._check(host_shots > 0, "host turret shot (%d)" % host_shots)
	t._check(anim_events.get(ids.turret, {}).has("shoot"), "host sends the turret's shoot animation")
	t._check(host_catling == "idle_attack", "host catling gun in mad mode (%s)" % host_catling)
	t._check(
		anim_events.get(ids.catling, {}).has("enter_in_mad_mode"),
		"host sends the catling's mad mode %s" % [anim_events.get(ids.catling, {}).keys()]
	)
	var idle_events := 0
	for i in 3:
		idle_events += anim_events.get(ids["target%s" % i], {}).size()
	t._check(idle_events == 0, "entities staying in their autoplay animation send nothing")

	# --- client replay: sample the puppets every frame ---
	client._on_battle_start(start)
	yield(client, "battle_entered")
	var seen := {"turret_shoot": false, "turret_y": 0.0, "spitter_shoot": false, "stray": 0}
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(t.get_tree(), "idle_frame")
			_sample_anim_puppets(client, ids, seen)
		client._on_snapshot(snap)
	var drain_until := OS.get_ticks_msec() + 300
	while OS.get_ticks_msec() < drain_until:
		yield(t.get_tree(), "idle_frame")
		_sample_anim_puppets(client, ids, seen)
	client.set_process(false)
	var turret = client._entities.get(ids.turret)
	var catling = client._entities.get(ids.catling)
	t._check(turret != null and catling != null, "client mirrors the turret and the catling gun")
	t._check(seen.turret_shoot, "client turret plays the host's shoot animation")
	t._check(
		seen.turret_y < -28.0,
		"client turret's Animation node pumps like a shot (y %.1f, idle >= -24)" % seen.turret_y
	)
	t._check(seen.stray == 0, "client spawned no projectiles of its own (%d)" % seen.stray)
	t._check(anim_events.get(ids.spitter, {}).has("shoot"), "host sends the spitter's wind-up")
	t._check(seen.spitter_shoot, "client spitter plays the host's attack wind-up")
	if turret != null and catling != null:
		_check_anim_puppets(client, turret, catling, ids)
	t._check(
		_count_method_tracks(load("res://entities/structures/turret/turret_shoot_animation.tres")) == 1,
		"the game's own turret animation keeps its method track"
	)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


# Turret in a corner with three parked bruisers in range (they stay "idle"), a catling gun on
# player 0 (mad mode), a spitter in range of the players with its attack ready.
func _spawn_anim_entities(main: Node) -> Dictionary:
	var spawner = main.get("_entity_spawner")
	var corner: Vector2 = ZoneService.get_current_zone_rect().position + Vector2(150, 150)
	var player_position: Vector2 = main.get("_players")[0].global_position
	var enemies := "res://entities/units/enemies/crash_zone/basic/"
	var nodes := {}
	nodes["turret"] = t._spawn_on_host(
		spawner,
		"res://entities/structures/turret/turret.tscn",
		EntityType.STRUCTURE,
		corner,
		load("res://items/all/00_base_game/turret/turret_effect_1.tres")
	)
	for i in 3:
		var target: Node = t._spawn_on_host(
			spawner,
			enemies + "bruiser/bruiser.tscn",
			EntityType.ENEMY,
			corner + Vector2(90, 0).rotated(i * PI / 4)
		)
		target.propagate_call("set_physics_process", [false])
		nodes["target%s" % i] = target
	nodes["catling"] = t._spawn_on_host(
		spawner,
		"res://entities/units/pet/catling_gun/catling_gun.tscn",
		EntityType.PET,
		player_position,
		load("res://items/all/03_paws_n_claws/catling_gun/catling_gun_effect_0.tres")
	)
	nodes["spitter"] = t._spawn_on_host(
		spawner, enemies + "spitter/spitter.tscn", EntityType.ENEMY, player_position + Vector2(450, 0)
	)
	var attack = nodes.spitter.get("_current_attack_behavior")
	if attack != null:
		attack._current_cd = 0.0  # shoots on its first physics frame instead of after ~2 s
	return nodes


func _sample_anim_puppets(client: Node, ids: Dictionary, seen: Dictionary) -> void:
	var turret = client._entities.get(ids.turret)
	if turret != null and is_instance_valid(turret):
		if turret._animation_player.current_animation == "shoot":
			seen.turret_shoot = true
		seen.turret_y = min(seen.turret_y, turret.get_node("Animation").position.y)
	var spitter = client._entities.get(ids.spitter)
	if spitter != null and is_instance_valid(spitter):
		if spitter._animation_player.current_animation == "shoot":
			seen.spitter_shoot = true
	# Every projectile on the client must be a mirrored one.
	var mirrored := {}
	for node in client._entities.values():
		mirrored[node] = true
	for container_name in ["_player_projectiles", "_enemy_projectiles"]:
		for child in client._main.get(container_name).get_children():
			if child is Projectile and not child.is_queued_for_deletion() and not mirrored.has(child):
				seen.stray += 1


func _check_anim_puppets(client: Node, turret: Node, catling: Node, ids: Dictionary) -> void:
	var player: AnimationPlayer = turret._animation_player
	t._check(turret._nb_shots_taken == 0, "client turret never ran shoot()")
	t._check(
		_count_method_tracks(player.get_animation("shoot")) == 0,
		"puppet's shoot animation has no method tracks"
	)
	t._check(
		not player.is_connected(
			"animation_finished", turret, "_on_AnimationPlayer_animation_finished"
		),
		"puppet turret's animation_finished handler disconnected"
	)
	var mirror = client._anim_mirror
	var event := [Snapshot.EVENT_ANIM, ids.turret, "shoot", 0.15, 1.0]
	t._check(mirror.replay(client._entities, event), "shoot event replays")
	player.advance(0.1)  # passes the original's shoot() key at 0.2 s
	t._check(
		turret._nb_shots_taken == 0 and player.current_animation == "shoot",
		"replayed shot past its shoot() key calls nothing"
	)
	t._check(
		catling._animation_player.current_animation == "idle_attack",
		"client catling gun in mad mode (%s)" % catling._animation_player.current_animation
	)
	catling.update_animation(Vector2.ZERO)  # the game's walk logic on puppets keeps it
	t._check(catling._animation_player.current_animation == "idle_attack", "walk logic keeps mad mode")
	# Malformed or unknown events are ignored; speeds are clamped.
	var bad := {
		"death is never mirrored": [Snapshot.EVENT_ANIM, ids.turret, "death", 0.0, 1.0],
		"unknown animation": [Snapshot.EVENT_ANIM, ids.turret, "nope", 0.0, 1.0],
		"unknown entity": [Snapshot.EVENT_ANIM, -77, "shoot", 0.0, 1.0],
		"id not an int": [Snapshot.EVENT_ANIM, "x", "shoot", 0.0, 1.0],
		"name not a string": [Snapshot.EVENT_ANIM, ids.turret, 3, 0.0, 1.0],
		"NaN position": [Snapshot.EVENT_ANIM, ids.turret, "shoot", NAN, 1.0],
		"infinite speed": [Snapshot.EVENT_ANIM, ids.turret, "shoot", 0.0, INF],
		"truncated": [Snapshot.EVENT_ANIM, ids.turret, "shoot", 0.0],
	}
	for label in bad:
		t._check(not mirror.replay(client._entities, bad[label]), "anim event rejected: %s" % label)
	t._check(not turret.dead, "rejected death event left the turret alive")
	mirror.replay(client._entities, [Snapshot.EVENT_ANIM, ids.turret, "idle", 99.0, 1e9])
	t._check(
		player.playback_speed <= mirror.MAX_SPEED and player.current_animation == "idle",
		"speed clamped (%s)" % player.playback_speed
	)


func _count_method_tracks(animation: Animation) -> int:
	var count := 0
	for i in animation.get_track_count():
		count += 1 if animation.track_get_type(i) == Animation.TYPE_METHOD else 0
	return count
