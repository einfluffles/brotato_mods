extends Reference
# Battle state that changes the scene itself (sync/battle_scene.gd, protocol 13): the wire fields
# (weapon slots, sparse speed: round trip, strict parsing, sizes, resolve), then one real host
# battle with the hole layout forced on (the jungle waves' flag, on a base-game wave: the
# headless game owns no jungle zone) in which a weapon breaks, a player is slowed, a single hole
# appears (BrachiosaurusFoot._stomp's call) and a player walks into a layout hole and into that one,
# replayed on a client that loads with the wave and on one that joins after the break. The client's
# own-player prediction walks into both holes from the same spot with the same inputs and must end
# where the host's physics stopped the player.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const BattleScene := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_scene.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const PF := Snapshot.PlayerField
const SLOW := -100  # bonus_speed of the slowed host player
const SNAPSHOTS_EACH := 10  # recorded before and after the break
const HOLE_SCENE := "res://entities/gpe/hole/hole.tscn"
const WALKER := 1  # the host player walked into the holes
const WALK_STEPS := 40  # physics ticks: far past a hole's edge from WALK_START
const WALK_START := 180.0  # px beside a hole's center (its capsule reaches 105, a player 24 more)
const WALK_ANGLE := 0.3  # rad off the hole's center: the player slides along it
# px from other holes and players: a walk only reaches the hole it is meant for (it starts
# WALK_START from it and heads for it, another hole reaches 105 + 24 px towards it)
const ROOM := 350.0

var _t: Node


class FakePlayer:
	extends Reference
	var move_speed := 450.0

	func get_move_speed() -> float:
		return move_speed


# Holds one direction, like a stick held on the player's device.
class Walk:
	extends MovementBehavior
	var direction := Vector2.ZERO

	func get_movement() -> Vector2:
		return direction


func run(test_mod: Node, together: Node):
	_t = test_mod
	_test_wire()
	_test_speed_sparse()
	yield(_test_battle(together), "completed")


func _test_wire() -> void:
	var view: Dictionary = SnapshotTests.new(_t).scenario(2, 10, 4, 3, 1, 2, 1, 1, false)
	var held: PoolRealArray = view.players[0][PF.WEAPONS]  # a copy: pool arrays are values
	held.resize(4 * Snapshot.WEAPON_STRIDE)
	view.players[0][PF.WEAPONS] = held
	view.players[0].append_array([PoolIntArray([0, 2, 3, 5]), 412])
	view.players[1].append_array([null, null])
	var parsed := Snapshot.parse(Snapshot.encode(view))
	_t._check(not parsed.empty(), "snapshot with weapon slots and speed parses")
	if parsed.empty():
		return
	_t._check(
		(
			Array(parsed.players[0][PF.WEAPON_SLOTS]) == [0, 2, 3, 5]
			and parsed.players[0][PF.SPEED] == 412
			and parsed.players[1][PF.WEAPON_SLOTS] == null
			and parsed.players[1][PF.SPEED] == null
		),
		"weapon slots and speed survive, absent when not sent"
	)
	var bytes := Snapshot.encode(view)
	var truncated_rejected := true
	for size in bytes.size():
		var prefix: PoolByteArray = bytes.subarray(0, size - 1) if size > 0 else PoolByteArray()
		truncated_rejected = truncated_rejected and Snapshot.parse(prefix).empty()
	_t._check(truncated_rejected, "every truncation rejected (with the protocol 13 fields)")
	var mismatch := view.duplicate(true)
	mismatch.players[0][PF.WEAPON_SLOTS] = PoolIntArray([0, 2])
	_t._check(
		Snapshot.parse(Snapshot.encode(mismatch)).empty(), "weapon slots that miscount rejected"
	)
	var all_broken := view.duplicate(true)
	all_broken.players[0][PF.WEAPONS] = PoolRealArray()
	all_broken.players[0][PF.WEAPON_SLOTS] = PoolIntArray()
	var none_left := Snapshot.parse(Snapshot.encode(all_broken))
	_t._check(
		not none_left.empty() and none_left.players[0][PF.WEAPON_SLOTS].size() == 0,
		"every weapon broken: an empty slot list, not an absent one"
	)
	_test_sizes()
	_test_resolve_speed()


# Bytes added per snapshot: nothing while no weapon broke and no speed is due (the flag bits
# live in the player byte that was already there).
func _test_sizes() -> void:
	var scenarios := {
		"small": [2, 20, 15, 10, 0, 4, 3, 1], "late": [4, 150, 90, 50, 10, 30, 6, 8]
	}
	for label in scenarios:
		var view: Dictionary = scenario_view(scenarios[label])
		var base := Protocol.encode(Protocol.Msg.SNAPSHOT, Snapshot.encode(view)).size()
		for entry in view.players:
			entry.append_array([null, 430])
		var speeds := Protocol.encode(Protocol.Msg.SNAPSHOT, Snapshot.encode(view)).size()
		var held: PoolRealArray = view.players[0][PF.WEAPONS]
		held.resize(5 * Snapshot.WEAPON_STRIDE)
		view.players[0][PF.WEAPONS] = held
		view.players[0][PF.WEAPON_SLOTS] = PoolIntArray([0, 1, 3, 4, 5])
		var broken := Protocol.encode(Protocol.Msg.SNAPSHOT, Snapshot.encode(view)).size()
		print(
			(
				"  info: snapshot %s: %d B, +%d B with every speed, +%d B for a broken weapon's slots"
				% [label, base, speeds - base, broken - speeds + 2]  # + its i16 angle, gone
			)
		)
		_t._check(
			speeds - base == 2 * view.players.size(), "%s: a speed costs 2 B per player" % label
		)


func scenario_view(args: Array) -> Dictionary:
	var view: Dictionary = SnapshotTests.new(_t).callv("scenario", args + [true])
	view.events = Snapshot.select_events(view.events, 48)
	return view


func _test_resolve_speed() -> void:
	var cache := {}
	var views := []
	for t_speed in [[100, 400], [200, null], [150, 300], [250, null]]:
		var entry := [Vector2.ZERO, 1, 1, 0, 1, 1, 1.0, PoolRealArray(), null, t_speed[1]]
		var view := {
			"battle_id": 1,
			"t": t_speed[0],
			"wave_time_left": 1.0,
			"players": [entry],
			"ids": PoolIntArray(),
			"types": PoolIntArray(),
			"positions": PoolVector2Array(),
			"flags": PoolByteArray(),
			"poses": {},
			"events": [],
		}
		views.append(Snapshot.resolve(view, cache))
	var speeds := []
	for view in views:
		speeds.append(view.players[0][PF.SPEED])
	# 300 was sent after 400 (t 150 > 100) but arrived late: it is the newest one sent.
	_t._check(speeds == [400, 400, 300, 300], "speed filled from the newest one sent %s" % [speeds])


func _test_speed_sparse() -> void:
	var state = BattleScene.new()
	var player := FakePlayer.new()
	var sent := []
	for count in 30:
		if count == 20:
			player.move_speed = 225.4  # a petrol puddle halves it
		sent.append(state.speed(0, player, count) != null)
	var steady := 0
	for count in range(BattleScene.SPEED_REPEAT, 20):
		steady += 1 if sent[count] else 0
	_t._check(
		sent.slice(0, BattleScene.SPEED_REPEAT - 1).count(false) == 0 and steady <= 2,
		"speed sent after a change, then only every %d snapshots" % BattleScene.SPEED_REFRESH
	)
	_t._check(
		sent.slice(20, 20 + BattleScene.SPEED_REPEAT - 1).count(false) == 0
		and state.speed(0, player, 21) == 225,
		"a changed speed goes out at once, in whole px/s"
	)


# --- a real battle ---


func _test_battle(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var tree: SceneTree = _t.get_tree()
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	var wave_data = ZoneService.get_zone_data(RunData.current_zone).waves_data[
		RunData.current_wave - 1
	]
	var saved_holes: bool = wave_data.spawn_holes
	wave_data.spawn_holes = true
	var added := _add_distinct_weapons(0, 2)
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main: Node = tree.current_scene
	host._start_battle(main)
	var host_player: Node = main.get("_players")[0]
	host_player.bonus_speed = SLOW
	var layout_hole := _clear_hole(main)
	var stomp_at := _clear_spot(main)
	main.get("_gpe_spawner").spawn_single_hole_at_position(stomp_at)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	yield(_record(host, recorded), "completed")
	var walks := []
	for hole in [layout_hole, stomp_at]:
		walks.append(yield(_host_walk(main, hole), "completed"))
	var weapon_count: int = host_player.current_weapons.size()
	var broken_slot: int = weapon_count - 2  # the first one added: a neighbour on each side
	host_player.on_weapon_wanted_to_break(host_player.current_weapons[broken_slot], 0)
	var kept_ids := []
	for weapon in host_player.current_weapons:
		kept_ids.append(weapon.weapon_id)
	yield(_record(host, recorded), "completed")
	var late_start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var types := {}
	for path in host._types:
		types[host._types[path]] = path
	start.types = types
	late_start.types = types
	host._end_battle()
	var expected_slots := range(weapon_count)
	expected_slots.remove(broken_slot)
	_check_host(start, late_start, recorded, expected_slots, host_player, kept_ids.size())
	_t._check(types.values().has(HOLE_SCENE), "the single hole is a snapshot entity")
	var last: Dictionary = SnapshotTests.views(recorded)[-1]
	yield(
		_client_from_start(client, start, recorded, last, kept_ids, stomp_at, walks), "completed"
	)
	yield(_client_late(client, late_start, recorded, kept_ids, expected_slots), "completed")
	wave_data.spawn_holes = saved_holes
	for weapon in added.slice(1, added.size() - 1):  # the first one broke on the host
		RunData.remove_weapon(weapon, 0)
	host.set_process(true)


# The hole of the host's layout with the most room around it.
func _clear_hole(main: Node) -> Vector2:
	var best := Vector2.ZERO
	var best_room := 0.0
	var layout = BattleScene._find_layout(main, BattleScene._layout_scenes(main))
	var holes: Array = layout.get_children() if layout != null else []
	for hole in holes:
		var room := _room(main, hole.global_position)
		if room > best_room:
			best = hole.global_position
			best_room = room
	_t._check(best_room >= ROOM, "a layout hole with room around it (%.0f px)" % best_room)
	return best


# The spot with the most room for the single hole.
func _clear_spot(main: Node) -> Vector2:
	var best := Vector2.ZERO
	var best_room := 0.0
	var zone: Rect2 = ZoneService.get_current_zone_rect().grow(-WALK_START - 50)
	for y in range(int(zone.position.y), int(zone.end.y), 25):
		for x in range(int(zone.position.x), int(zone.end.x), 25):
			var room := _room(main, Vector2(x, y))
			if room > best_room:
				best = Vector2(x, y)
				best_room = room
	_t._check(best_room >= ROOM, "a spot with room for the single hole (%.0f px)" % best_room)
	return best


# Distance to the nearest other hole or player (0 too close to the map's edge for a walk).
func _room(main: Node, position: Vector2) -> float:
	if not ZoneService.get_current_zone_rect().grow(-WALK_START - 50).has_point(position):
		return 0.0
	var room := INF
	for circle in ZoneService.forbidden_circles:
		if circle.center != position:
			room = min(room, circle.center.distance_to(position))
	for player in main.get("_players"):
		room = min(room, player.global_position.distance_to(position))
	return room


# The host's own physics walks WALKER into the hole from WALK_START beside it, a tick per input:
# [start, direction, position after every tick].
func _host_walk(main: Node, hole: Vector2):
	var player: Node = main.get("_players")[WALKER]
	var middle: Vector2 = ZoneService.get_current_zone_rect().get_center()
	var side := Vector2.LEFT if hole.x > middle.x else Vector2.RIGHT  # from the map's middle
	var walk := Walk.new()
	walk.direction = -side.rotated(WALK_ANGLE)
	var saved = player._current_movement_behavior
	var start := hole + side * WALK_START
	yield(_t.get_tree(), "idle_frame")  # not between a physics_frame and its tick
	player.global_position = start
	player._current_movement_behavior = walk
	var path := []
	while path.size() <= WALK_STEPS:
		yield(_t.get_tree(), "physics_frame")  # before this tick's move
		path.append(player.global_position)
	player._current_movement_behavior = saved
	var step: float = player.get_move_speed() / Engine.iterations_per_second
	var straight: Vector2 = start + walk.direction * step * WALK_STEPS
	_t._check(
		path[0] == start and path[-1].distance_to(straight) > 30.0,
		"the hole stops the host's player (%.0f px short)" % path[-1].distance_to(straight)
	)
	var direction := walk.direction
	walk.free()
	return [start, direction, path]


func _record(host: Node, recorded: Array):
	for _i in SNAPSHOTS_EACH:
		yield(_t.get_tree().create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))


# Base-game weapons the player does not have yet, added to its run (the scene builds from it).
func _add_distinct_weapons(p: int, count: int) -> Array:
	var owned := {}
	for weapon in RunData.get_player_weapons(p):
		owned[weapon.weapon_id] = true
	var added := []
	for weapon in ItemService.weapons:
		if added.size() < count and weapon.tier == 0 and not owned.has(weapon.weapon_id):
			owned[weapon.weapon_id] = true
			added.append(RunData.add_weapon(weapon, p))
	return added


func _check_host(
	start: Dictionary,
	late_start: Dictionary,
	recorded: Array,
	expected_slots: Array,
	host_player: Node,
	kept: int
) -> void:
	var views := SnapshotTests.views(recorded)
	_t._check(
		start.holes.begins_with("res://entities/gpe/hole/holes_"),
		"BATTLE_START names the host's hole layout (%s)" % start.holes
	)
	var before: Array = views[SNAPSHOTS_EACH - 1].players[0]
	var after: Array = views[-1].players[0]
	_t._check(
		before[PF.WEAPON_SLOTS] == null and Array(after[PF.WEAPON_SLOTS]) == expected_slots,
		"weapon slots only once a weapon broke (%s)" % [after[PF.WEAPON_SLOTS]]
	)
	_t._check(
		(
			after[PF.WEAPONS].size() == kept * Snapshot.WEAPON_STRIDE
			and host_player.current_weapons.size() == kept
		),
		"host player lost the weapon (%d left)" % kept
	)
	_t._check(
		late_start.weapon_slots[0] == expected_slots and start.weapon_slots[0].size() == kept + 1,
		"BATTLE_START tells a late joiner which weapons it builds"
	)
	_t._check(
		after[PF.SPEED] == int(round(host_player.get_move_speed())),
		"snapshot carries the host's current speed (%s px/s)" % after[PF.SPEED]
	)
	var sent := 0  # from the raw messages: the views have the speed filled in
	for msg in recorded:
		sent += 1 if Snapshot.parse(msg[1]).players[1][PF.SPEED] != null else 0
	_t._check(
		sent < recorded.size() / 2,
		"an unchanged speed is in %d of %d snapshots" % [sent, recorded.size()]
	)


func _client_from_start(
	client: Node,
	start: Dictionary,
	recorded: Array,
	last: Dictionary,
	kept_ids: Array,
	stomp_at: Vector2,
	walks: Array
):
	client._on_battle_start(start)
	yield(client, "battle_entered")
	var main: Node = client._main
	var layout = BattleScene._find_layout(main, BattleScene._layout_scenes(main))
	_t._check(
		layout != null and layout.filename == start.holes,
		"client shows the host's hole layout (%s)" % (layout.filename if layout != null else "none")
	)
	_t._check(
		layout != null and ZoneService.forbidden_circles.size() == layout.get_child_count(),
		"forbidden circles are the host layout's holes (%d)" % ZoneService.forbidden_circles.size()
	)
	_test_layout_swap(main, start.holes)
	var player: Node = main.get("_players")[0]
	var before: int = player.current_weapons.size()
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(_t.get_tree(), "idle_frame")
		client._on_snapshot(snap)
	yield(_t.get_tree().create_timer(0.3), "timeout")
	var ids := []
	var positions := []
	for weapon in player.current_weapons:
		ids.append(weapon.weapon_id)
		positions.append(weapon.weapon_pos)
	_t._check(
		before == kept_ids.size() + 1 and ids == kept_ids and positions == range(ids.size()),
		"puppet drops the broken weapon (%s, was %d)" % [ids, before]
	)
	_t._check(RunData.get_player_weapons(0).size() == ids.size(), "client run lists the weapons")
	var host_weapons: PoolRealArray = last.players[0][PF.WEAPONS]
	var weapons: Array = player.current_weapons
	var aim_ok: bool = weapons.size() * Snapshot.WEAPON_STRIDE == host_weapons.size()
	for k in weapons.size():
		var diff: float = abs(wrapf(player.current_weapons[k].rotation - host_weapons[4 * k], -PI, PI))
		aim_ok = aim_ok and diff < 0.01
	_t._check(aim_ok, "every weapon after the broken one aims like its host weapon")
	_test_prediction_speed(client, player, last.players[0], walks[0][0])
	_test_hole_walks(client, main, stomp_at, walks, last.players[WALKER])
	client._leave_battle()
	Puppet.set_active(false)


# The single hole is the host's (the game's scene with its body), and the own player's prediction
# of each host walk ends where the host's player did, also halfway.
func _test_hole_walks(
	client: Node, main: Node, stomp_at: Vector2, walks: Array, entry: Array
) -> void:
	var stomp = null
	for child in main.get("_gpe_container").get_children():
		stomp = child if child is Hole and child.global_position == stomp_at else stomp
	_t._check(
		stomp != null and stomp.collision_layer == 192,
		"client has the single hole, a body on the obstacles layer"
	)
	var player: Node = main.get("_players")[WALKER]
	var input_sync: Node = client.input_sync
	var saved: Array = input_sync.history
	client._newest_rx_msec = OS.get_ticks_msec()
	for k in walks.size():
		var walk: Array = walks[k]
		var host_entry := entry.duplicate()
		host_entry[PF.POSITION] = walk[0]
		host_entry[PF.INPUT_ACK] = 0
		var worst := 0.0
		for steps in [WALK_STEPS / 2, WALK_STEPS]:
			input_sync.history = []
			for seq in range(1, steps + 1):
				input_sync.history.append([seq, walk[1]])
			var predicted: Vector2 = client._own_target(player, host_entry)
			worst = max(worst, predicted.distance_to(walk[2][steps]))
		_t._check(
			worst < 0.1,
			(
				"prediction into the %s hole ends where the host's player did (off by %.2f px)"
				% [["layout", "single"][k], worst]
			)
		)
	input_sync.history = saved


# Another layout and back: the old one goes, its circles with it; paths outside the spawner's
# lists are refused.
func _test_layout_swap(main: Node, host_path: String) -> void:
	var scenes: Dictionary = BattleScene._layout_scenes(main)
	var other := ""
	for path in scenes:
		other = path if path != host_path and other == "" else other
	var swapped: bool = BattleScene.apply_hole_layout(main, other)
	var layout = BattleScene._find_layout(main, scenes)
	var refused: bool = not BattleScene.apply_hole_layout(main, "res://main.tscn")
	_t._check(
		swapped and refused and layout.filename == other,
		"a different local layout is replaced, unknown scenes refused"
	)
	var back: bool = BattleScene.apply_hole_layout(main, host_path)
	var holes := 0
	for child in main.get("_gpe_container").get_children():
		if child.filename in scenes:
			holes += 1
	_t._check(back and holes == 1, "one hole layout in the scene after swaps")


# The host's speed reaches the puppet, and the replay of an un-acked input moves by it, from a spot
# clear of the holes (a step along a hole's edge goes as far as the host's: test_motion and a
# slide, up to twice as far).
func _test_prediction_speed(client: Node, player: Node, entry: Array, clear: Vector2) -> void:
	var host_speed = entry[PF.SPEED]
	_t._check(
		host_speed != null and player.get_move_speed() == float(host_speed),
		"own player moves at the host's speed (%s px/s)" % host_speed
	)
	var input_sync: Node = client.input_sync
	var saved: Array = input_sync.history
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var direction := Vector2.RIGHT
	if clear.x > zone.get_center().x:
		direction = Vector2.LEFT
	input_sync.history = [[1, direction]]
	var host_entry := entry.duplicate()
	host_entry[PF.POSITION] = clear
	host_entry[PF.INPUT_ACK] = 0
	client._newest_rx_msec = OS.get_ticks_msec()
	var lead: float = client._own_target(player, host_entry).distance_to(clear)
	var step := float(host_speed) / Engine.iterations_per_second
	_t._check(abs(lead - step) < 0.01, "prediction steps %.2f px per input (host %.2f)" % [lead, step])
	input_sync.history = saved


func _client_late(
	client: Node, start: Dictionary, recorded: Array, kept_ids: Array, expected_slots: Array
):
	client._on_battle_start(start)
	yield(client, "battle_entered")
	var player: Node = client._main.get("_players")[0]
	_t._check(
		client._battle_scene._weapon_slots.get(0) == expected_slots,
		"late joiner knows its puppet's weapon slots"
	)
	var snap := Snapshot.parse(recorded[-1][1])
	snap.t = OS.get_ticks_msec() - 1000
	client._on_snapshot(snap)
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var ids := []
	for weapon in player.current_weapons:
		ids.append(weapon.weapon_id)
	_t._check(ids == kept_ids, "late joiner keeps the weapons the host has (%s)" % [ids])
	client._leave_battle()
	Puppet.set_active(false)
