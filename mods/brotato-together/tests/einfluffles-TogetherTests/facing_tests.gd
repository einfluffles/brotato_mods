extends Reference
# Projectile angles (sync/facing.gd) and the meca / mutant look (sync/looks.gd): the angles section
# of the wire format, the host's sparse sending, the client's resolve, then a host battle replayed
# on a client. Part of the looks suite (looks_tests.gd).

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Facing := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/facing.gd")
const Looks := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/looks.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const SLASH := "res://projectiles/slash/slash_projectile.tscn"
const PLANT := "res://entities/units/enemies/jungle/basic/carnivorus_plant/carnivorus_plant.tscn"
const BEHAVIORS := "res://effect_behaviors/enemies/%s_enemy_effect_behavior.tscn"
const SLASH_SPEED := 300.0  # px/s, the mad slasher's: 10 px per snapshot
const ANGLE_STEP := PI / 32767.0  # the wire's
const RECORD_MSEC := 500  # a slash lives 0.63 s

var _t: Node
var _plain := {}  # "meca" / "mutant" -> the enemy's sprite before the game evolved it


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	_test_wire()
	_test_host_sparse()
	_test_resolve()
	yield(_test_battle(together), "completed")


func _test_wire() -> void:
	var view: Dictionary = SnapshotTests.new(_t).scenario(2, 12, 6, 4, 2, 4, 3, 2, true)
	var plain := Snapshot.encode(view)
	var last: int = view.ids.size() - 1
	view["angles"] = {0: 0.5, 5: -2.0, last: 3.1}
	var bytes := Snapshot.encode(view)
	var parsed := Snapshot.parse(bytes)
	var angles: Dictionary = parsed.get("angles", {})
	var same := angles.size() == 3
	for index in view.angles:
		var got = angles.get(view.ids[index])
		same = same and got != null and abs(got - view.angles[index]) <= ANGLE_STEP
	_t._check(same, "angles survive the round trip, by net id %s" % [angles])
	_t._check(bytes.size() - plain.size() == 9, "3 B per angle (%d)" % (bytes.size() - plain.size()))
	var beyond := view.duplicate(true)
	beyond.angles = {view.ids.size(): 1.0}
	_t._check(Snapshot.parse(Snapshot.encode(beyond)).empty(), "angle index out of range rejected")
	bytes.resize(bytes.size() - 1)
	_t._check(Snapshot.parse(bytes).empty(), "a cut off angle rejected")


# Sent for REPEAT snapshots after a change, then only in its refresh.
func _test_host_sparse() -> void:
	var facing = Facing.new()
	var shot := Node2D.new()
	shot.rotation = 0.7
	var sent := []
	for count in 40:
		if count == 20:
			shot.rotation = -1.2
		facing.capture(shot, 7, 3, count)
		var section: Dictionary = facing.end_snapshot()
		if not section.empty():
			sent.append(count)
			_t._check(section.keys() == [3], "the angle is listed under the entity's index")
	shot.free()
	# (count + 7) % 15 == 0: 8, 23, 38
	var want := [0, 1, 2, 8, 20, 21, 22, 23, 38]
	_t._check(sent == want, "a shot's angle: 3 times, then refreshes %s" % [sent])


func _test_resolve() -> void:
	var cache := {}
	var first := _view(100, [4, 5], {4: 0.2})
	Facing.resolve(first, cache)
	_t._check(_same(first.angles_by_id, {4: 0.2}), "an angle is known from its snapshot on")
	var quiet := _view(110, [4, 5], {})
	Facing.resolve(quiet, cache)
	_t._check(_same(quiet.angles_by_id, {4: 0.2}), "and stays while the shot is listed")
	var second := _view(133, [4, 5], {4: 0.5})
	Facing.resolve(second, cache)
	var late := _view(120, [4, 5], {4: 0.1, 5: 2.0})
	Facing.resolve(late, cache)
	Facing.resolve(second, cache)
	_t._check(_same(second.angles_by_id, {4: 0.5, 5: 2.0}), "an older snapshot does not turn it back")
	var old := _view(110, [5], {})
	Facing.resolve(old, cache)
	Facing.resolve(second, cache)
	_t._check(second.angles_by_id.has(4), "nor does one drop a shot it does not list yet")
	var gone := _view(166, [5], {})
	Facing.resolve(gone, cache)
	var reused := _view(200, [4, 5], {})
	Facing.resolve(reused, cache)
	_t._check(_same(reused.angles_by_id, {5: 2.0}), "a shot that left is forgotten: ids come back")


static func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key) or a[key] != b[key]:
			return false
	return true


func _view(t: int, ids: Array, angles: Dictionary) -> Dictionary:
	var index := {}
	for i in ids.size():
		index[ids[i]] = i
	return {"t": t, "ids": PoolIntArray(ids), "index": index, "angles": angles}


func _test_battle(together: Node):
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
	var nodes := _spawn(main)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var ids := {}
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < RECORD_MSEC:
		yield(_t.get_tree().create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
		if ids.empty():
			for name in nodes:
				ids[name] = nodes[name].get_meta(host.NET_ID_META)
	var host_values := _host_values(nodes)
	var carried := []
	for i in recorded.size():
		if Snapshot.parse(recorded[i][1]).angles.has(ids.slash):
			carried.append(i)
	_t._check(
		carried.slice(0, 2) == [0, 1, 2] and carried.size() <= 4 and recorded.size() >= 10,
		"a new shot's angle goes out with its first snapshots, then rarely %s" % [carried]
	)
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var seen := {}  # name -> [least, most rotation, frames shown]
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(_t.get_tree(), "idle_frame")
			_sample(client, ids, seen)
		client._on_snapshot(snap)
	for _i in 12:
		yield(_t.get_tree(), "idle_frame")
		_sample(client, ids, seen)
	client.set_process(false)
	for name in ["slash", "askew"]:
		var range_seen: Array = seen.get(name, [9.0, -9.0, 0])
		var want: float = host_values[name]
		_t._check(
			(
				range_seen[2] > 5
				and abs(range_seen[0] - want) <= ANGLE_STEP
				and abs(range_seen[1] - want) <= ANGLE_STEP
			),
			"%s: the puppet holds the host's angle %.4f in every frame %s" % [name, want, range_seen]
		)
	_check_evolved(client, ids, host_values)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


# Two slashes at the mad slasher's speed (one flying where it points, one the game did not turn
# into its flight), a meca and a mutant enemy. Far from the players, weapons off.
func _spawn(main: Node) -> Dictionary:
	for player in main.get("_players"):
		player._weapons_container.propagate_call("set_physics_process", [false])
		player._weapons_container.propagate_call("set_process", [false])
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var corner := zone.position + Vector2(200, 200)
	var nodes := {}
	var scene: PackedScene = load(SLASH)
	if not main._pool.has(scene.get_instance_id()):
		main._pool[scene.get_instance_id()] = []
	var shots := {"slash": [0.684, 0.684], "askew": [-2.1, 0.3]}  # rotation, flight
	for name in shots:
		var shot: Node = scene.instance()
		shot.set_meta("pool_id", scene.get_instance_id())
		main.add_enemy_projectile(shot)
		shot.global_position = corner + Vector2(300 * nodes.size(), 300)
		shot.rotation = shots[name][0]
		shot.velocity = Vector2.RIGHT.rotated(shots[name][1]) * SLASH_SPEED
		nodes[name] = shot
	var spawner = main.get("_entity_spawner")
	for name in ["meca", "mutant"]:
		var enemy: Node = _t._spawn_on_host(
			spawner, PLANT, EntityType.ENEMY, corner + Vector2(150 * nodes.size(), 0)
		)
		enemy.propagate_call("set_physics_process", [false])  # parked
		_plain[name] = enemy.sprite.texture
		var behavior: Node = load(BEHAVIORS % name).instance()
		enemy.effect_behaviors.add_child(behavior.init(enemy))
		nodes[name] = enemy
	return nodes


func _host_values(nodes: Dictionary) -> Dictionary:
	var values := {}
	for name in ["slash", "askew"]:
		values[name] = wrapf(nodes[name].rotation, -PI, PI)
	for name in ["meca", "mutant"]:
		values[name] = nodes[name].sprite.texture
		values[name + "_plain"] = _plain[name]
		values[name + "_colors"] = nodes[name]._outline_colors.duplicate()
	return values


func _sample(client: Node, ids: Dictionary, seen: Dictionary) -> void:
	for name in ["slash", "askew"]:
		var node = client._entities.get(ids.get(name, -1))
		if node == null or not is_instance_valid(node) or not node.visible:
			continue
		var rotation: float = wrapf(node.rotation, -PI, PI)
		var entry: Array = seen.get(name, [rotation, rotation, 0])
		seen[name] = [min(entry[0], rotation), max(entry[1], rotation), entry[2] + 1]


func _check_evolved(client: Node, ids: Dictionary, host_values: Dictionary) -> void:
	var colors := {"meca": Utils.MECA_COLOR, "mutant": Utils.MUTANT_COLOR}
	for name in colors:
		var puppet = client._entities.get(ids[name])
		_t._check(
			host_values[name + "_colors"] == [colors[name]]
			and host_values[name] != host_values[name + "_plain"],
			"the game gave the %s enemy its outline and sprite on the host" % name
		)
		if puppet == null or not is_instance_valid(puppet):
			_t._check(false, "client mirrors the %s enemy" % name)
			continue
		var material = puppet.sprite.material
		if material == puppet.flash_mat:
			material = puppet._non_flash_material
		_t._check(
			(
				puppet._outline_colors == [colors[name]]
				and material is ShaderMaterial
				and material.shader == puppet.outline_material.shader
			),
			"the %s puppet has the host's outline" % name
		)
		_t._check(puppet.sprite.texture == host_values[name], "and its evolved sprite")
		_t._check(puppet.effect_behaviors.get_child_count() == 0, "without the behavior itself")
		client._looks.set_look(puppet, 0)
		_t._check(
			puppet._outline_colors.empty() and puppet.sprite.texture == host_values[name + "_plain"],
			"a %s puppet reused for a plain enemy is plain again" % name
		)
