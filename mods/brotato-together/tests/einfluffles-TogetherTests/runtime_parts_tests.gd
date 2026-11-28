extends Reference
# Pose mirroring of parts the game adds, frees or shows at runtime (see sync/pose.gd).

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Pose := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/pose.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const BUILDER_EFFECT := "res://dlcs/dlc_1/items/builder_turret/effects/builder_turret_effect_0.tres"

var _t: Node


func _init(tests: Node) -> void:
	_t = tests


# The client's die() frees the tree's Pivot (Pivot._on_Enemy_died), like the game. A reused
# puppet gets its Pivot back as soon as the host's entity sends one.
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
# landing warning, shadow and facing (dimetrodon), a charge warning line (velociraptor++), an enemy
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
		if recorded.size() == 10:
			_grow_builder(nodes.builder)
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
	_check_builder_snapshots(early, last, index, host_values)
	_t._check(ring_tracked == 0, "ring bullets inside the boss aren't tracked as projectiles")

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
		_check_builder_puppet(client, puppets.builder, host_values)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)
	_check_runtime_layouts(client._pose)


# Eel boss, a dimetrodon that jumps at its target right away (from the right: faces left), a
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
	nodes.eel.current_stats.health = int(nodes.eel.max_stats.health * 0.97)  # hit, same phase
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
	# Player 0's builder turret at structure range 150: level 2, half way to its full size.
	var effects: Dictionary = RunData.get_player_effects(0)
	var structure_range = effects[Keys.structure_range_hash]
	effects[Keys.structure_range_hash] = 150
	nodes["builder"] = _t._spawn_on_host(
		spawner,
		"res://entities/structures/turret/builder/builder_turret.tscn",
		EntityType.STRUCTURE,
		zone.end - Vector2(150, 150),
		load(BUILDER_EFFECT)
	)
	effects[Keys.structure_range_hash] = structure_range
	return nodes


# What BuilderTurret.on_bonus_gold_converted shows when the wave's end lifts the owner's
# structure range to 300 (the rest of it changes the run: items, stats).
static func _grow_builder(builder: Node) -> void:
	builder.set_size(300)
	builder._current_level = 3
	builder.sprite.texture = builder.turret_sprites[3]


func _runtime_host_values(nodes: Dictionary) -> Dictionary:
	var values := {}
	var ring = nodes.eel.get_node_or_null("Pivots/BulletsFar/Pivot")
	values["has_ring"] = ring != null
	values["eel_health"] = nodes.eel.current_stats.health / float(nodes.eel.max_stats.health)
	if ring != null:
		values["ring"] = ring.rotation
		values["bullet"] = ring.get_child(0).position.x
	var dimetrodon: Node = nodes.dimetrodon
	var jump = dimetrodon._current_attack_behavior
	values["faces_left"] = dimetrodon.sprite.scale.x < 0
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
	var builder: Node = nodes.builder
	values["builder"] = [
		builder.sprite.scale.y,
		builder.sprite.position.y,
		builder.turret_sprites.find(builder.sprite.texture),
	]
	return values


# Spawned at level 2 (scale 0.75, 25 px up); grown to level 3 (scale 1, 50 px up) since.
func _check_builder_snapshots(early, last, index: Dictionary, host_values: Dictionary) -> void:
	var early_pose: PoolRealArray = early.poses.get(
		Snapshot.index_of(early, last.ids[index.builder]), PoolRealArray()
	)
	var y: float = host_values.builder[1] + 25.0  # sprite height at level 2
	_t._check(
		_near(early_pose, [0.75, y, 2]),
		"builder turret sends its size, height and level 2 texture %s" % [early_pose]
	)
	var pose: PoolRealArray = last.poses.get(index.builder, PoolRealArray())
	_t._check(
		_near(pose, host_values.builder) and host_values.builder[0] == 1.0,
		"grown builder turret sends level 3 %s" % [pose]
	)


static func _near(values: PoolRealArray, expected: Array) -> bool:
	if values.size() != expected.size():
		return false
	for i in values.size():
		if abs(values[i] - expected[i]) > 0.001:
			return false
	return true


# The puppet has the scene's scale 1 and level 1 texture until the host's values come.
func _check_builder_puppet(client: Node, builder: Node, host_values: Dictionary) -> void:
	var host: Array = host_values.builder
	var sprite: Sprite = builder.sprite
	_t._check(
		(
			abs(sprite.scale.y - host[0]) < 0.001
			and abs(sprite.position.y - host[1]) < 0.001
			and sprite.texture == builder.turret_sprites[host[2]]
		),
		(
			"client builder turret has the host's size, height and texture (%s, %.1f, %s)"
			% [sprite.scale, sprite.position.y, builder.turret_sprites.find(sprite.texture)]
		)
	)
	sprite.scale.x = -sprite.scale.x  # facing left
	client._pose.apply(builder, PoolRealArray(), PoolRealArray([0.6, -30.0, 1.0]), 1.0)
	_t._check(
		(
			sprite.scale == Vector2(-0.6, 0.6)
			and sprite.position.y == -30.0
			and sprite.texture == builder.turret_sprites[1]
		),
		"builder size keeps its facing, texture follows the level (%s)" % [sprite.scale]
	)
	client._pose.apply(builder, PoolRealArray(), PoolRealArray([0.6, -30.0, 9.0]), 1.0)
	_t._check(sprite.texture == builder.turret_sprites[1], "unknown texture index ignored")


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
	var early_pose: PoolRealArray = early.poses.get(early_eel, PoolRealArray())
	_t._check(
		early_pose.size() == 1 and abs(early_pose[0] - host_values.eel_health) < 0.01,
		"before its phase change the eel only sends its health %s" % [early_pose]
	)
	_t._check(
		host_values.has_ring and sizes[0] == 33,
		"eel pose after the phase change: health + 16 pivots + 16 bullets"
	)
	var flags: int = Snapshot.get_flags(last.flags, index.dimetrodon)
	_t._check(
		host_values.faces_left and bool(flags & Snapshot.FLAG_FACING_LEFT),
		"jumping dimetrodon flagged facing left"
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
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(_t.get_tree(), "idle_frame")
		client._on_snapshot(snap)
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
	var bar = eel.life_bar
	var shown: bool = ProgressData.settings.hp_bar_on_bosses
	_t._check(
		not shown or abs(bar.value - 100.0 * host_values.eel_health) < 0.2,
		"boss life bar follows the host's health (%.1f)" % bar.value
	)
	_t._check(not bar.get_node("Timer").paused, "and its hit tint ends")
	var dimetrodon: Node = puppets.dimetrodon
	var jump = dimetrodon._current_attack_behavior
	_t._check(
		(dimetrodon.sprite.scale.x < 0) == host_values.faces_left, "jump facing mirrored"
	)
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
	var structures := "res://entities/structures/"
	for scene in ["turret/turret", "landmine/landmine", "turret/garden/garden"]:
		var lay: Dictionary = pose.layout_of(structures + scene + ".tscn")
		_t._check(lay.parts.empty(), "%s sends no pose" % scene.get_file())


