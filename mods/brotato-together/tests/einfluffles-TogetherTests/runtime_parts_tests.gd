extends Reference
# Pose mirroring of parts the game adds, frees or shows at runtime (see sync/pose.gd). Driven from
# mod_main.gd; checks go through its _check.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Pose := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/pose.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")

var _t: Node  # the test mod: _check, helpers, scene tree


func _init(tests: Node) -> void:
	_t = tests


# Pooled puppets: the client's die() frees the tree's Pivot (Pivot._on_Enemy_died), like the
# game. Layouts come from the pristine scene, and a reused puppet gets its Pivot back as soon as
# the host's entity sends one; without host values the ring is hidden.
func test_pivot_restore(client: Node, tree: Node, host_pose: PoolRealArray):
	client._despawn(tree)
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	_t._check(tree.get_node_or_null("Pivot") == null, "client die() freed the tree puppet's pivot")
	var fresh_pose = Pose.new()  # nothing cached: the first instance it sees is the damaged one
	_t._check(fresh_pose.layout(tree).parts.size() == 2, "pose layout from the pristine scene")
	yield(_t.get_tree().create_timer(2.0), "timeout")
	var type_idx := -1
	for idx in client._types:
		var scene = client._types[idx]
		if scene is PackedScene and scene.resource_path == tree.filename:
			type_idx = idx
	var reused: Node = client._spawn(type_idx)
	_t._check(reused == tree, "tree puppet reused from the pool")
	if reused != tree:
		return
	_t._check(tree.get_node_or_null("Pivot") == null, "reused puppet came back without its pivot")
	client._pose.apply(tree, host_pose, host_pose, 1.0)
	var pivot = tree.get_node_or_null("Pivot")
	_t._check(
		(
			pivot != null
			and pivot.visible
			and _t._angle_diff(pivot.rotation, host_pose[0]) < 0.01
			and abs(pivot.get_child(0).position.x - host_pose[1]) < 0.01
			and not pivot.is_physics_processing()
		),
		"reused puppet gets its pivot back, frozen and posed"
	)
	if pivot != null:
		client._pose.apply(tree, PoolRealArray(), PoolRealArray(), 1.0)
		_t._check(not pivot.visible, "ring hidden while the host's entity has none")
		client._pose.apply(tree, host_pose, host_pose, 1.0)
		_t._check(pivot.visible, "ring shown again with host values")
		_t._check(tree.is_connected("died", pivot, "_on_Enemy_died"), "restored pivot dies with it")


# Parts the game adds or shows at runtime: boss pivots from a phase change (eel), a jump attack's
# landing warning, shadow and flip_h (dimetrodon), a charge warning line (velociraptor++), an enemy
# laser's aim and beam. The ring's bullets live inside the boss: not mirrored as projectiles.
func test_runtime_parts(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	_t.get_tree().change_scene("res://main.tscn")
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var main := _t.get_tree().current_scene
	host._start_battle(main)
	var nodes := _spawn_runtime_parts(main)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var host_values := {}
	var ring_tracked := 0
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < 1500:
		yield(_t.get_tree().create_timer(1.0 / 30.0), "timeout")
		if recorded.size() == 5:  # Boss._on_CheckStateTimer_timeout past both state timers
			nodes.eel.elapsed_time = 100
			nodes.eel._on_CheckStateTimer_timeout()
		for node in host._tracked_nodes():
			ring_tracked += 1 if nodes.eel.is_a_parent_of(node) else 0
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
		host_values = _runtime_host_values(nodes)
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()
	var early: Dictionary = Snapshot.parse(recorded[2][1])
	var last: Dictionary = Snapshot.parse(recorded[-1][1])
	var index := {}
	for name in nodes:
		index[name] = Snapshot.index_of(last, nodes[name].get_meta(host.NET_ID_META))
	_t._check(not (-1 in index.values()), "runtime test entities in the snapshot %s" % [index])
	if -1 in index.values() or early.empty():
		return
	_check_runtime_snapshots(early, last, index, host_values)
	_t._check(ring_tracked == 0, "ring bullets inside the boss aren't tracked as projectiles")

	# --- client replay ---
	client._on_battle_start(start)
	yield(client, "battle_entered")
	yield(_replay(client, recorded), "completed")
	client.set_process(false)
	var puppets := {}
	for name in nodes:
		puppets[name] = client._entities.get(last.ids[index[name]])
	_t._check(not (null in puppets.values()), "client mirrors the runtime test entities")
	if not (null in puppets.values()):
		_check_runtime_puppets(client, puppets, host_values)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)
	_check_runtime_layouts(client._pose)


# Eel boss, a dimetrodon that jumps at its target right away (from the right: flip_h), a
# velociraptor++ showing its charge warning, an enemy laser. Players don't shoot.
func _spawn_runtime_parts(main: Node) -> Dictionary:
	var players: Array = main.get("_players")
	for player in players:
		player._weapons_container.propagate_call("set_physics_process", [false])
		player._weapons_container.propagate_call("set_process", [false])
	var center: Vector2 = players[0].global_position
	var right: float = max(players[0].global_position.x, players[1].global_position.x)
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var spawner = main.get("_entity_spawner")
	var enemies := "res://entities/units/enemies/"
	var nodes := {}
	nodes["eel"] = _t._spawn_on_host(
		spawner, enemies + "abyss/bosses/eel/eel.tscn", EntityType.BOSS, center + Vector2(0, -600)
	)
	nodes["dimetrodon"] = _t._spawn_on_host(
		spawner,
		enemies + "jungle/basic/dimetrodon/dimetrodon.tscn",
		EntityType.ENEMY,
		Vector2(min(right + 700, zone.end.x - 50), center.y)
	)
	nodes["raptor"] = _t._spawn_on_host(
		spawner,
		enemies + "jungle/basic/velociraptor/velociraptor++.tscn",
		EntityType.ENEMY,
		center + Vector2(-700, 300)
	)
	var charge = nodes.raptor._current_attack_behavior
	charge.warning_duration = 10.0  # the warning stays up for the whole recording
	charge.start_warning()  # what its physics_process does when the target is in range
	var laser_scene: PackedScene = load("res://projectiles/laser_enemy/enemy_laser.tscn")
	nodes["laser"] = laser_scene.instance()
	main._pool[laser_scene.get_instance_id()] = []
	nodes.laser.set_meta("pool_id", laser_scene.get_instance_id())
	main.add_enemy_projectile(nodes.laser)  # like ShootingAttackBehavior.spawn_projectile
	nodes.laser.global_position = zone.position + Vector2(100, 100)
	nodes.laser.rotation = -2.3  # away from everyone
	nodes.laser.delayAfterShot = 10.0  # the beam stays on once it fires (after 0.75 s)
	return nodes


func _runtime_host_values(nodes: Dictionary) -> Dictionary:
	var values := {}
	var ring = nodes.eel.get_node_or_null("Pivots/BulletsFar/Pivot")
	values["has_ring"] = ring != null
	if ring != null:
		values["ring"] = ring.rotation
		values["bullet"] = ring.get_child(0).position.x
	var dimetrodon: Node = nodes.dimetrodon
	var jump = dimetrodon._current_attack_behavior
	values["flip_h"] = dimetrodon.sprite.flip_h
	values["warning_visible"] = jump._land_shadow_warning.visible
	values["warning"] = jump._land_shadow_warning.global_position
	values["shadow_y"] = jump._shadow.position.y
	var line: Line2D = nodes.raptor._current_attack_behavior._warning_line
	values["line"] = line.points[0].angle() if line.points.size() > 0 else 0.0
	var laser: Node = nodes.laser
	var bits := 0
	for k in Pose.LASER_SPRITES.size():
		bits |= (1 << k) if laser.get_node(Pose.LASER_SPRITES[k]).visible else 0
	values["laser_bits"] = bits
	values["laser_rotation"] = laser.rotation
	return values


func _check_runtime_snapshots(early, last, index: Dictionary, host_values: Dictionary) -> void:
	var sizes := []
	for name in ["eel", "dimetrodon", "raptor", "laser"]:
		sizes.append(last.poses.get(index[name], []).size())
	print(
		(
			"  info: runtime parts: %d entities, %d with poses (%d B), sizes %s"
			% [last.ids.size(), last.poses.size(), 4 * _t._pose_floats(last), sizes]
		)
	)
	var early_eel := Snapshot.index_of(early, last.ids[index.eel])
	_t._check(early_eel >= 0 and not early.poses.has(early_eel), "no eel pose before its phase change")
	_t._check(
		host_values.has_ring and sizes[0] == 32,
		"eel pose after the phase change: 16 pivots + 16 bullets"
	)
	var flags: int = Snapshot.get_flags(last.flags, index.dimetrodon)
	_t._check(
		host_values.flip_h and bool(flags & Snapshot.FLAG_FLIP_H), "jumping dimetrodon flagged flip_h"
	)
	_t._check(
		host_values.warning_visible and sizes[1] == 4,
		"mid-jump dimetrodon sends its landing warning + shadow"
	)
	_t._check(sizes[2] == 1, "charge warning line sent while shown")
	var laser_early: PoolRealArray = early.poses.get(
		Snapshot.index_of(early, last.ids[index.laser]), PoolRealArray()
	)
	_t._check(
		laser_early.size() == 2 and laser_early[1] == 0.0 and host_values.laser_bits == 15,
		"laser beam hidden while charging, shown when firing"
	)


func _replay(client: Node, recorded: Array):
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap: Array = msg[1].duplicate()
		snap[1] = replay_start + (snap[1] - recorded[0][1][1])
		while OS.get_ticks_msec() < snap[1]:
			yield(_t.get_tree(), "idle_frame")
		client._on_snapshot(Snapshot.parse(snap))
	yield(_t.get_tree().create_timer(0.3), "timeout")


func _check_runtime_puppets(client: Node, puppets: Dictionary, host_values: Dictionary) -> void:
	var eel: Node = puppets.eel
	var ring = eel.get_node_or_null("Pivots/BulletsFar/Pivot")
	var pivots = eel.get_node_or_null("Pivots")
	_t._check(ring != null and eel.pivots == pivots, "client eel got the boss pivots")
	if ring != null and host_values.has_ring:
		_t._check(
			(
				_t._angle_diff(ring.rotation, host_values.ring) < 0.01
				and abs(ring.get_child(0).position.x - host_values.bullet) < 0.01
			),
			"boss ring spins and flies out like on the host (%.2f)" % host_values.ring
		)
		_t._check(not ring.get_child(0).is_physics_processing(), "boss ring bullets frozen")
	var dimetrodon: Node = puppets.dimetrodon
	var jump = dimetrodon._current_attack_behavior
	_t._check(dimetrodon.sprite.flip_h == host_values.flip_h, "jump flip_h mirrored")
	var warning: Node2D = jump._land_shadow_warning
	_t._check(
		warning.visible and warning.global_position.distance_to(host_values.warning) < 1.0,
		"landing warning shown at the host's landing spot"
	)
	_t._check(abs(jump._shadow.position.y - host_values.shadow_y) < 0.01, "jump shadow stays grounded")
	var line: Line2D = puppets.raptor._current_attack_behavior._warning_line
	_t._check(
		(
			line.get_parent() == puppets.raptor
			and line.visible
			and line.points.size() == 2
			and _t._angle_diff(line.points[0].angle(), host_values.line) < 0.01
		),
		"charge warning line shown in the host's direction"
	)
	var laser: Node = puppets.laser
	_t._check(
		laser.get_node("Sprite").visible and laser.get_node("aura_2").visible,
		"laser beam shown like on the host"
	)
	_t._check(_t._angle_diff(laser.rotation, host_values.laser_rotation) < 0.01, "laser aim mirrored")
	# Inactive group (host sends the base values only): the telegraphs go away.
	client._pose.apply(dimetrodon, PoolRealArray(), PoolRealArray(), 1.0)
	client._pose.apply(puppets.raptor, PoolRealArray(), PoolRealArray(), 1.0)
	_t._check(not warning.visible and not line.visible, "telegraphs hidden when the host's are")
	# Malformed values: wrong counts are ignored, odd numbers can't break anything.
	var rotation: float = ring.rotation if ring != null else 0.0
	client._pose.apply(eel, PoolRealArray(), PoolRealArray(range(31)), 1.0)
	_t._check(ring == null or ring.rotation == rotation, "pose with a wrong value count ignored")
	client._pose.apply(laser, PoolRealArray(), PoolRealArray([0.0, 1e12]), 1.0)
	client._pose.apply(laser, PoolRealArray(), PoolRealArray([0.0, -3.5]), 1.0)
	_t._check(laser.get_node("Sprite").visible, "out-of-range bit values only set listed bits")


func _check_runtime_layouts(pose) -> void:
	var enemies := "res://entities/units/enemies/jungle/"
	for boss in ["bosses/tyrannosaurus/tyranosaurus", "bosses/brachiosaurus/brachiosaurus"]:
		var lay: Dictionary = pose.layout_of(enemies + boss + ".tscn")
		_t._check(
			lay.group == Pose.Group.PIVOTS and lay.group_parts.size() == 32,
			"%s: runtime pivots in its layout" % boss.get_file()
		)
	var stampede: Dictionary = pose.layout_of(enemies + "basic/oviraptor/oviraptor.tscn")
	_t._check(stampede.stampede, "stampede dino shakes the grass where it spawns")
	var plain: Dictionary = pose.layout_of(enemies + "basic/velociraptor/velociraptor.tscn")
	_t._check(plain.parts.empty() and plain.group == Pose.Group.NONE, "plain raptor sends nothing")
	var foot: Dictionary = pose.layout_of(
		enemies + "bosses/brachiosaurus/brachiosaurus_foot/brachiosaurus_foot.tscn"
	)
	_t._check(foot.parts.size() == 1 and foot.parts[0][1] == Pose.Kind.BITS, "foot: one bits value")


