extends Reference
# Suite pose_mirror: parts the game turns in physics code (frozen on puppets): a bullet ring on a
# Pivot, a catling gun's aim, a stampede dino's heading. Turrets don't rotate in this game: a real
# turret and ordinary enemies must add no pose data. Also the facing/hidden flags. Checks go
# through mod_main's _check.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const RuntimePartsTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/runtime_parts_tests.gd"
)

var t: Node  # the test mod: _check, helpers, scene tree
var _runtime_parts = null


func _init(test_mod: Node) -> void:
	t = test_mod
	_runtime_parts = RuntimePartsTests.new(test_mod)


func run(together: Node):
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
	var spawner = main.get("_entity_spawner")
	var enemies := "res://entities/units/enemies/"
	var nodes := {}
	nodes["tree"] = t._spawn_on_host(
		spawner, enemies + "corrupted_tree/corrupted_tree.tscn", EntityType.ENEMY, Vector2(300, 300)
	)
	nodes["dino"] = t._spawn_on_host(
		spawner, enemies + "jungle/basic/iguanodon/iguanodon.tscn", EntityType.ENEMY, Vector2(900, 600)
	)
	nodes.dino.propagate_call("set_physics_process", [false])  # parked, hidden by its behavior
	nodes.dino.rotation = 0.7  # what GoTowardsBorderOppositeMovementBehavior does when charging
	nodes["catling"] = t._spawn_on_host(
		spawner,
		"res://entities/units/pet/catling_gun/catling_gun.tscn",
		EntityType.PET,
		Vector2(500, 300),
		load("res://items/all/03_paws_n_claws/catling_gun/catling_gun_effect_0.tres")
	)
	nodes.catling.set_physics_process(false)  # aimed below with the game's own _orient_gun
	nodes["turret"] = t._spawn_on_host(
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
		yield(t.get_tree().create_timer(1.0 / 30.0), "timeout")
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
	t._check(not last.empty() and not early.empty(), "snapshots with poses well-formed")
	if last.empty() or early.empty():
		return
	var index := {}
	for name in nodes:
		index[name] = Snapshot.index_of(last, nodes[name].get_meta(host.NET_ID_META))
	t._check(not (-1 in index.values()), "test entities in the snapshot %s" % [index])
	if -1 in index.values():
		return
	print(
		(
			"  info: %d entities, %d with poses (%d B), flags %d B"
			% [last.ids.size(), last.poses.size(), 4 * t._pose_floats(last), last.flags.size()]
		)
	)
	t._check(
		last.poses.size() == 3 and not last.poses.has(index.turret),
		"only tree, dino, catling send poses; turret + %d others don't" % (last.ids.size() - 3)
	)
	var tree_pose: PoolRealArray = last.poses.get(index.tree, PoolRealArray())
	t._check(
		tree_pose.size() == 2 and t._angle_diff(tree_pose[0], host_values.pivot) < 0.001,
		"tree pose = pivot rotation + bullet distance %s" % [tree_pose]
	)
	var early_tree: PoolRealArray = early.poses.get(
		Snapshot.index_of(early, last.ids[index.tree]), PoolRealArray()
	)
	t._check(
		early_tree.size() == 2 and t._angle_diff(early_tree[0], tree_pose[0]) > 0.5,
		"host bullet ring spins"
	)
	t._check(
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
			yield(t.get_tree(), "idle_frame")
		client._on_snapshot(snap)
	yield(t.get_tree().create_timer(0.3), "timeout")
	client.set_process(false)
	var puppets := {}
	for name in nodes:
		puppets[name] = client._entities.get(last.ids[index[name]])
	t._check(not (null in puppets.values()), "client mirrors the test entities")
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
	t._check(t._angle_diff(host_values.pivot, 0.0) > 0.5, "host ring turned away from its start angle")
	t._check(
		t._angle_diff(puppet_pivot.rotation, host_values.pivot) < 0.01,
		"bullet ring rotation mirrored (%.2f vs %.2f)" % [puppet_pivot.rotation, host_values.pivot]
	)
	t._check(
		abs(puppet_pivot.get_child(0).position.x - host_values.bullet) < 0.01,
		"bullet distance mirrored (%.1f)" % host_values.bullet
	)
	t._check(t._angle_diff(puppets.dino.rotation, 0.7) < 0.01, "dino heading mirrored")
	t._check(not puppets.dino.visible, "dino hidden like on the host")
	var gun_l: Node2D = puppets.catling._gun_pivot_l
	var gun_r: Node2D = puppets.catling._gun_pivot_r
	t._check(
		(
			t._angle_diff(gun_l.rotation, host_values.gun_l) < 0.01
			and t._angle_diff(gun_r.rotation, host_values.gun_r) < 0.01
		),
		"catling gun aim mirrored (%.2f, %.2f)" % [gun_l.rotation, gun_r.rotation]
	)
	t._check(
		gun_l.scale.y == host_values.gun_l_flip and gun_l.get_index() == host_values.gun_l_index,
		"catling gun flip and draw order mirrored"
	)
	var facing_mismatches := 0
	for i in last.ids.size():
		var node = client._entities.get(last.ids[i])
		if node is Unit:
			var left := bool(Snapshot.get_flags(last.flags, i) & Snapshot.FLAG_FACING_LEFT)
			facing_mismatches += 1 if (node.sprite.scale.x < 0) != left else 0
	t._check(facing_mismatches == 0, "unit facing mirrored (%d mismatches)" % facing_mismatches)
	# Interpolation takes the short way around: PI - 0.1 -> -PI + 0.1 passes PI, not 0.
	var x: float = host_values.bullet
	client._pose.apply(
		puppets.tree, PoolRealArray([PI - 0.1, x]), PoolRealArray([-PI + 0.1, x]), 0.5
	)
	t._check(t._angle_diff(puppet_pivot.rotation, PI) < 0.01, "pose interpolates the shortest angle")

