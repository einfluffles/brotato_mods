extends Reference
# The own player at the map's edge (issue #109), part of suite battle_scene. The host's player
# walks into the edge at an angle, then along it with the wall-side key let go. The client's
# prediction must step like Unit._physics_process, which slides only when RigidBody2D.test_motion
# reports a hit: a body that touches the wall and gets its whole way is none there.

const BattleScene := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_scene.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PF := Snapshot.PlayerField
const RADIUS := 24.0  # the player's body circle
const GAP := 40.0  # px between the body and the wall at the start
const INTO := 0.6  # rad off straight into the wall
const INTO_STEPS := 15  # ticks into the wall (it gets there in 7), then along it
const ALONG_STEPS := 25
const CLEAR := 160.0  # px from a hole's center along the way (a hole reaches 105, a player 24)
const GAPS := [0.0, 0.02, 0.05, 0.079, 0.081, 0.1, 0.3, 1.0]  # px off the wall for the sweep
const LATENCY := 6  # ticks each way: a 200 ms round trip
const EPSILON := 0.1  # px

var _t: Node


class Walk:
	extends MovementBehavior
	var direction := Vector2.ZERO

	func get_movement() -> Vector2:
		return direction


func _init(t: Node) -> void:
	_t = t


# On the host: the sweep, then the walk. Returns [moves (seq -> direction), path] or [].
func host(main: Node, walker: int):
	var player: Node = main.get("_players")[walker]
	var way := _clear_wall(player, main.get("_players")[1 - walker])
	yield(_t.get_tree(), "idle_frame")
	if way.empty():
		_t._check(false, "a stretch of the map's edge clear of holes and players")
		return []
	var start: Vector2 = way[0]
	var into: Vector2 = way[1]
	var along := Vector2(0, sign(into.y))
	var outward := Vector2(-sign(into.x), 0)
	var contact: Vector2 = start - outward * GAP
	_sweep(player, contact, outward, along)
	var moves := {}
	for seq in range(1, INTO_STEPS + ALONG_STEPS + 1):
		moves[seq] = into if seq <= INTO_STEPS else along
	var walk := Walk.new()
	walk.direction = moves[1]
	var saved = player._current_movement_behavior
	player.global_position = start
	player._current_movement_behavior = walk
	var path := []
	while path.size() <= moves.size():
		yield(_t.get_tree(), "physics_frame")  # before this tick's move
		path.append(player.global_position)
		walk.direction = moves.get(path.size(), Vector2.ZERO)
	player._current_movement_behavior = saved
	walk.free()
	var wall_x: float = path[INTO_STEPS].x
	var along_px: float = abs(path[-1].y - path[INTO_STEPS].y) / ALONG_STEPS
	var step: float = player.get_move_speed() / Engine.iterations_per_second
	_t._check(
		abs(path[-1].x - wall_x) < 0.05 and abs(along_px - step) < 0.01,
		(
			"the host's player slides along the map's edge, then walks along it at %.2f px a "
			+ "tick (its speed: %.2f)"
		) % [along_px, step]
	)
	return [moves, path]


# Where the walk goes from: GAP from the left or right edge, heading into it at INTO and turning
# along it, clear of holes and the other player. [start, direction] or [].
static func _clear_wall(player: Node, other: Node) -> Array:
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var step: float = player.get_move_speed() / Engine.iterations_per_second
	var reach: float = step * (INTO_STEPS + ALONG_STEPS)
	for side in [-1.0, 1.0]:
		var x: float = zone.position.x + RADIUS + GAP
		if side > 0:
			x = zone.end.x - RADIUS - GAP
		var direction := Vector2(side, 0).rotated(side * INTO)  # into the wall, downwards
		for y in range(int(zone.position.y) + 100, int(zone.end.y - reach) - 100, 20):
			var start := Vector2(x, y)
			var clear: bool = other.global_position.distance_to(start) > CLEAR + reach
			for k in 11:
				var at := Vector2(x, y + reach * k / 10.0)
				for circle in ZoneService.forbidden_circles:
					clear = clear and circle.center.distance_to(at) > CLEAR
			if clear:
				return [start, direction]
	return []


# BattleScene.step against the game's own tick, from GAPS off the wall at every angle from into it
# to away from it, at a slow, normal and fast speed.
func _sweep(player: Node, contact: Vector2, outward: Vector2, along: Vector2) -> void:
	var saved: Vector2 = player.global_position
	var result := Physics2DTestMotionResult.new()
	var worst := 0.0
	var cases := 0
	for gap in GAPS:
		var from: Vector2 = contact + outward * gap
		for k in range(-10, 11):
			for speed in [3.0, 7.5, 15.0]:
				var motion: Vector2 = along.rotated(0.15 * k) * speed
				var predicted: Vector2 = BattleScene.step(player, from, motion, result)
				worst = max(worst, predicted.distance_to(_game_step(player, from, motion)))
				cases += 1
	player.global_position = saved
	_t._check(
		worst < 0.01,
		"prediction steps like the game's own tick at the map's edge (%d cases, off by %.2f px)"
		% [cases, worst]
	)


# Unit._physics_process's move, with the node's own test_motion.
static func _game_step(player: Node, from: Vector2, motion: Vector2) -> Vector2:
	player.global_position = from
	var result := Physics2DTestMotionResult.new()
	var margin := BattleScene.MOTION_MARGIN
	if player.test_motion(motion, true, margin, result):
		player.global_position += result.motion
		player.test_motion(motion.slide(result.collision_normal), true, margin, result)
	player.global_position += result.motion
	return player.global_position


# On the client: the replay of the walk from its start, then the walk frame by frame with the
# snapshots LATENCY late.
func client(client: Node, main: Node, walker: int, walk: Array, entry: Array) -> void:
	if walk.empty():
		return
	var player: Node = main.get("_players")[walker]
	var input_sync: Node = client.input_sync
	var saved := [
		input_sync.history, client._own_base_t, client._own_error, client._own_display,
		client._own_seq, client._view.jump
	]
	client._view.place([], {"players": []}, walker)
	var moves: Dictionary = walk[0]
	var path: Array = walk[1]
	var host_entry: Array = entry.duplicate()
	host_entry[PF.POSITION] = path[0]
	host_entry[PF.INPUT_ACK] = 0
	var worst := 0.0
	for steps in range(1, moves.size() + 1):
		input_sync.history = _history(moves, steps)
		client._newest_rx_msec = OS.get_ticks_msec()
		worst = max(worst, client._own_target(player, host_entry).distance_to(path[steps]))
	_t._check(
		worst < EPSILON,
		"prediction into the map's edge and along it ends where the host's player did (off by "
		+ "%.2f px)" % worst
	)
	_frames(client, player, walker, walk, entry)
	input_sync.history = saved[0]
	client._own_base_t = saved[1]
	client._own_error = saved[2]
	client._own_display = saved[3]
	client._own_seq = saved[4]
	client._view.jump = saved[5]


# One input a frame at 60 Hz, a snapshot every second tick with the host's position at 0.5 px.
func _frames(client: Node, player: Node, walker: int, walk: Array, entry: Array) -> void:
	var moves: Dictionary = walk[0]
	var path: Array = walk[1]
	client._own_base_t = -1
	client._own_error = Vector2.ZERO
	client._own_seq = 0
	var worst := 0.0
	var ahead := 0.0  # px along the wall
	for seq in range(1, moves.size() + 1):
		client.input_sync.history = _history(moves, seq)
		var snapshot_tick: int = int(max(0, seq - LATENCY))
		snapshot_tick -= snapshot_tick % 2
		var ack: int = int(max(0, snapshot_tick - LATENCY))
		var host_entry: Array = entry.duplicate()
		var scale := 1.0 / Snapshot.POS_SCALE
		host_entry[PF.POSITION] = Vector2(stepify(path[ack].x, scale), stepify(path[ack].y, scale))
		host_entry[PF.INPUT_ACK] = ack
		var players := []
		for _i in walker + 1:
			players.append(host_entry)
		client._newest_rx_msec = OS.get_ticks_msec()
		client._predict_own(player, walker, {"t": snapshot_tick, "players": players}, 1.0 / 60)
		worst = max(worst, client._own_display.distance_to(path[seq]))
		if seq > INTO_STEPS:
			ahead = max(ahead, abs(client._own_display.y - path[0].y) - abs(path[seq].y - path[0].y))
	_t._check(
		worst < 1.0,
		(
			"the client's own player keeps to the host's path along the map's edge at a %d ms "
			+ "round trip (off by %.2f px, %.2f px ahead along it)"
		) % [2 * LATENCY * 1000 / 60, worst, ahead]
	)


static func _history(moves: Dictionary, upto: int) -> Array:
	var history := []
	for seq in range(1, upto + 1):
		history.append([seq, moves[seq]])
	return history
