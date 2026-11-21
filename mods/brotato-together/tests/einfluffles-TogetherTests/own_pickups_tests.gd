extends Reference
# Suite own_pickups: the client's own player picks up consumables and gold at once
# (sync/own_pickups.gd). First the game's own rules on the host (OwnPickups.overlaps must match
# them), then a client predicting pickups on snapshots of that host battle, also running fast.

const OwnPickups := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/own_pickups.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const PF := Snapshot.PlayerField
const YOU := 1
const RULE_TICKS := 8  # physics ticks for a touch to land on the host
const ATTRACT_TICKS := 40
const EDGE := 2.0  # px inside / outside the reach
const FAST := 1200  # px/s, the own player's speed in the gold test: 20 px per input
const INPUTS_PER_FRAME := 3  # a slow client: 50 ms frames
const GOLD_GAP := 150.0  # px from the attract circle to the gold
const SWEEP_ROW := 3  # the crate between two frames is passed after this many frames

var _t: Node
var _host_t := 0
var _moved := {}  # net id -> offset from the recorded position in the snapshots sent
var _speed = null  # the own player's speed in the snapshots sent


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var tree: SceneTree = _t.get_tree()
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main: Node = tree.current_scene
	host._start_battle(main)
	var player: Node = main.get("_players")[YOU]
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	player.global_position = zone.get_center()
	main.get("_players")[1 - YOU].global_position = zone.position + Vector2(150, 150)
	yield(tree, "physics_frame")
	yield(_test_touch_rule(main, player), "completed")
	yield(_test_attract_rule(main, player), "completed")
	yield(_test_gold_rule(main, player), "completed")
	_test_way()
	var scene: Dictionary = yield(_record(host, main, player), "completed")
	host._end_battle()
	yield(_test_client(client, scene), "completed")
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


func _test_touch_rule(main: Node, player: Node):
	var crate = _t._find_by_id(ItemService.consumables, "consumable_item_box")
	var reach: Array = OwnPickups.area_circle(player, player._item_pickup_area)
	var center: Vector2 = player.global_position + reach[0]
	var radius: float = reach[1]
	var extents := Vector2(16, 16)
	var corner := Vector2(1, -1).normalized()
	var cases := []
	for edge in [-EDGE, EDGE]:
		cases.append(Vector2(radius + extents.x + edge, 0))
		cases.append(Vector2(0, -(radius + extents.y + edge)))
		cases.append(Vector2(extents.x, -extents.y) + corner * (radius + edge))
	var mismatches := []
	var taken := 0
	for offset in cases:
		var at: Vector2 = center + offset
		var item: Node = yield(_spawn(main, crate, at), "completed")
		extents = OwnPickups.item_extents(item)
		for _i in RULE_TICKS:
			yield(_t.get_tree(), "physics_frame")
		var picked: bool = not item in main.get("_consumables")
		if not picked:
			main.despawn_consumable(item)
		taken += 1 if picked else 0
		if picked != OwnPickups.overlaps(center, radius, at, extents):
			mismatches.append([offset, picked])
	_t._check(
		mismatches.empty() and taken == 3,
		"the host takes a crate exactly where the client's reach does (%d of 6, off: %s)"
		% [taken, mismatches]
	)


func _test_attract_rule(main: Node, player: Node):
	var fruit = _t._find_by_id(ItemService.consumables, "consumable_fruit")
	var at: Vector2 = _attract_spot(player)
	var health: int = player.max_stats.health
	player.current_stats.health = health
	var item: Node = yield(_spawn(main, fruit, at), "completed")
	for _i in ATTRACT_TICKS:
		yield(_t.get_tree(), "physics_frame")
	var stayed: bool = item in main.get("_consumables") and item.global_position == at
	if stayed:
		main.despawn_consumable(item)
	player.current_stats.health = health - 5
	item = yield(_spawn(main, fruit, at), "completed")
	for _i in ATTRACT_TICKS:
		yield(_t.get_tree(), "physics_frame")
	var hurt_taken: bool = not item in main.get("_consumables")
	if not hurt_taken:
		main.despawn_consumable(item)
	player.current_stats.health = health
	_t._check(
		stayed and hurt_taken,
		"host: a fruit in the attract circle stays at full health, flies in when hurt (%s, %s)"
		% [stayed, hurt_taken]
	)


# Below the player: in its attract circle, out of its reach.
func _attract_spot(player: Node) -> Vector2:
	var attract: Array = OwnPickups.area_circle(player, player._item_attract_area)
	return player.global_position + attract[0] + Vector2(0, attract[1] - 20)


func _spawn(main: Node, data, at: Vector2):
	var state = main.spawn_consumable(data, at, at)
	if state is GDScriptFunctionState:
		yield(state, "completed")
	else:
		yield(_t.get_tree(), "idle_frame")
	return main.get("_consumables")[-1]  # before a tick can take it


# Gold lying at `at` (no push out), unturned: drop() turns it at random, which clients do not
# get (OwnPickups.overlaps takes its box unturned, up to 7 px short at a corner).
func _spawn_gold(main: Node, at: Vector2):
	var state = main.spawn_gold(1.0, at, 0)
	if state is GDScriptFunctionState:
		yield(state, "completed")
	else:
		yield(_t.get_tree(), "idle_frame")
	var gold: Node = main.get("_active_golds")[-1]
	gold.global_position = at
	gold.push_back_destination = at
	gold.rotation = 0.0
	return gold


# Gold at full health too: in the attract circle it flies in and is taken, just outside it stays.
func _test_gold_rule(main: Node, player: Node):
	player.current_stats.health = player.max_stats.health
	var attract: Array = OwnPickups.area_circle(player, player._item_attract_area)
	var center: Vector2 = player.global_position + attract[0]
	var taken := []
	for edge in [-EDGE, EDGE]:
		var gold: Node = yield(
			_spawn_gold(main, center + Vector2(0, attract[1] + 400)), "completed"
		)
		var at: Vector2 = center + Vector2(0, attract[1] + OwnPickups.item_extents(gold).y + edge)
		gold.global_position = at
		gold.push_back_destination = at
		for _i in ATTRACT_TICKS:
			yield(_t.get_tree(), "physics_frame")
		var gone: bool = not gold in main.get("_active_golds")
		if not gone:
			gold.pickup(-1)  # nobody's: main pools it
		taken.append(gone)
	_t._check(
		taken == [true, false],
		"host: gold in the attract circle flies in at full health, outside it stays (%s)" % [taken]
	)


# A frame's way in short steps; a jump (a correction) is just its end.
func _test_way() -> void:
	var walked := OwnPickups.way(Vector2.ZERO, Vector2(0, -60), 90.0)
	var even := walked.size() == 8 and walked[-1] == Vector2(0, -60)
	for k in range(1, walked.size()):
		even = even and walked[k - 1].distance_to(walked[k]) <= OwnPickups.SWEEP_STEP_PX
	var jumped := OwnPickups.way(Vector2.ZERO, Vector2(0, -200), 90.0)
	var first := OwnPickups.way(null, Vector2(0, -60), 90.0)
	_t._check(
		even and Array(jumped) == [Vector2(0, -200)] and Array(first) == [Vector2(0, -60)],
		"a frame's way is checked every 8 px, a jump only where it ends (%s)" % [walked]
	)


# The host with a crate WALK inputs to the right of player 1's reach, a fruit as far to the left
# and a fruit in its attract circle; then the host takes the crate (its sound in that snapshot).
func _record(host: Node, main: Node, player: Node):
	var step: float = player.get_move_speed() / Engine.iterations_per_second
	var attract: Array = OwnPickups.area_circle(player, player._item_attract_area)
	var walk := int(ceil((attract[1] + 60) / step))
	var reach: Array = OwnPickups.area_circle(player, player._item_pickup_area)
	var start: Vector2 = player.global_position
	var scene := {"walk": walk}
	scene.crate_at = start + reach[0] + Vector2(walk * step, 0)
	scene.fruit_at = start + reach[0] - Vector2(walk * step, 0)
	scene.flier_at = _attract_spot(player)
	host._build_snapshot()  # takes the rule tests' pickup sounds
	var crate: Node = yield(
		_spawn(main, _t._find_by_id(ItemService.consumables, "consumable_item_box"), scene.crate_at),
		"completed"
	)
	var fruit_data = _t._find_by_id(ItemService.consumables, "consumable_fruit")
	var fruit: Node = yield(_spawn(main, fruit_data, scene.fruit_at), "completed")
	var flier: Node = yield(_spawn(main, fruit_data, scene.flier_at), "completed")
	var gold: Node = yield(_spawn_gold(main, _gold_spot(player, start)), "completed")
	scene.gold_at = gold.global_position
	scene.sweep_at = _sweep_spot(player, start, OwnPickups.item_extents(crate))
	var crate_data = _t._find_by_id(ItemService.consumables, "consumable_item_box")
	var swept: Node = yield(_spawn(main, crate_data, scene.sweep_at), "completed")
	player.current_stats.health = player.max_stats.health
	yield(_t.get_tree(), "physics_frame")
	scene.all = bytes2var(var2bytes(host._build_snapshot()), false)
	scene.ids = []
	for node in [crate, fruit, flier, gold, swept]:
		scene.ids.append(node.get_meta(host.NET_ID_META))
	crate.pickup(YOU)
	scene.taken = bytes2var(var2bytes(host._build_snapshot()), false)
	scene.crate_sounds = []
	for sound in crate.consumable_data.pickup_sounds:
		scene.crate_sounds.append(host._types.get(sound.resource_path, -1))
	gold.pickup(YOU)
	scene.gold_taken = bytes2var(var2bytes(host._build_snapshot()), false)
	scene.gold_sounds = []
	for sound in main.gold_pickup_sounds + main.gold_alt_pickup_sounds:
		scene.gold_sounds.append(host._types.get(sound.resource_path, -1))
	var start_body: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	start_body.types = {}
	for path in host._types:
		start_body.types[host._types[path]] = path
	start_body.you = YOU
	scene.start = start_body
	_t._check(
		walk <= 45 and _sounds_in(Snapshot.parse(scene.taken[1]).events, scene.crate_sounds) == 1,
		"host: %d inputs to the crate, its pickup sound in the snapshot that drops it" % walk
	)
	_t._check(
		_sounds_in(Snapshot.parse(scene.gold_taken[1]).events, scene.gold_sounds) == 1,
		"host: the gold's pickup sound in the snapshot that drops it"
	)
	return scene


# Above the player, GOLD_GAP beyond its attract circle.
static func _gold_spot(player: Node, start: Vector2) -> Vector2:
	var attract: Array = OwnPickups.area_circle(player, player._item_attract_area)
	return start + attract[0] - Vector2(0, attract[1] + GOLD_GAP)


# Beside the way up at FAST, between the reach's positions of two frames of INPUTS_PER_FRAME
# inputs: just in reach of the steps in between, not of the frames' ends.
static func _sweep_spot(player: Node, start: Vector2, extents: Vector2) -> Vector2:
	var reach: Array = OwnPickups.area_circle(player, player._item_pickup_area)
	var frame := float(FAST * INPUTS_PER_FRAME) / Engine.iterations_per_second
	var side: float = reach[1] + extents.x - EDGE
	return start + reach[0] + Vector2(side, -frame * (SWEEP_ROW + 0.5))


func _test_client(client: Node, scene: Dictionary):
	client._on_battle_start(scene.start)
	yield(client, "battle_entered")
	var input_sync: Node = client.input_sync
	var saved: Array = input_sync.history
	input_sync.history = []
	var crate_id: int = scene.ids[0]
	var fruit_id: int = scene.ids[1]
	var flier_id: int = scene.ids[2]
	var walk: int = scene.walk
	yield(_feed(client, scene.all, 0, 300), "completed")
	_t._check(
		_shown_at(client, crate_id, scene.crate_at) and _shown_at(client, fruit_id, scene.fruit_at),
		"client shows the crate and the fruit where the host has them"
	)
	# Onto the crate while the host moves it away (pushed out, attracted by someone): not taken
	# on the way, though it is shown in reach for a moment.
	input_sync.history = _inputs(1, walk, Vector2.RIGHT)
	_moved[crate_id] = Vector2(0, 80)
	yield(_feed(client, scene.all, 0, 300), "completed")
	_t._check(
		client._entities.has(crate_id) and not client._pickups.holds(crate_id),
		"a crate the host moves is not taken on its way"
	)
	_t._hold_sounds(true)
	_moved.clear()
	yield(_feed(client, scene.all, 0, 300), "completed")
	var queued := 0
	for entry in SoundManager.sounds_to_play:
		queued += 1 if entry[0].resource_path in _paths(client, scene.crate_sounds) else 0
	_t._hold_sounds(false)
	_t._check(
		not client._entities.has(crate_id) and client._pickups.holds(crate_id) and queued == 1,
		"the own player takes the crate at once, with its pickup sound (%d)" % queued
	)
	yield(_feed(client, scene.all, walk - 1, 250), "completed")
	_t._check(
		not client._entities.has(crate_id),
		"it stays gone while the host has not caught up with the inputs"
	)
	var confirming: Dictionary = _send(client, scene.taken, walk)
	var queued_sounds := []
	for entry in client._events:
		queued_sounds.append(entry[1])
	_t._check(
		(
			_sounds_in(confirming.events, scene.crate_sounds) == 0
			and _sounds_in(queued_sounds, scene.crate_sounds) == 0
		),
		"the host took it: its pickup sound is not played a second time"
	)
	yield(_feed(client, scene.taken, walk, 300), "completed")
	_t._check(
		not client._entities.has(crate_id) and not client._pickups.holds(crate_id),
		"gone for good once the render reached the host's pickup"
	)
	yield(_test_rejected(client, scene), "completed")
	yield(_test_flight(client, scene, flier_id), "completed")
	yield(_test_gold(client, scene), "completed")
	input_sync.history = saved


func _test_rejected(client: Node, scene: Dictionary):
	var input_sync: Node = client.input_sync
	var walk: int = scene.walk
	var fruit_id: int = scene.ids[1]
	input_sync.history = _inputs(walk + 1, 2 * walk, Vector2.LEFT)
	yield(_feed(client, scene.taken, walk, 100), "completed")
	_t._check(
		not client._entities.has(fruit_id) and client._pickups.holds(fruit_id),
		"the own player takes the fruit on the other side"
	)
	var last_seq: int = 2 * walk
	yield(_feed(client, scene.taken, last_seq + OwnPickups.CONFIRM_INPUTS - 1, 250), "completed")
	_t._check(
		not client._entities.has(fruit_id), "still gone while the host could take it a tick later"
	)
	yield(_feed(client, scene.taken, last_seq + OwnPickups.CONFIRM_INPUTS, 250), "completed")
	_t._check(
		_shown_at(client, fruit_id, scene.fruit_at) and not client._pickups.holds(fruit_id),
		"the host did not take it: it is back where the host has it"
	)
	input_sync.history = _inputs(last_seq + 1, last_seq + walk, Vector2.LEFT)
	yield(_feed(client, scene.taken, last_seq, 150), "completed")
	_t._check(
		_reaches(client, scene.fruit_at) and _shown_at(client, fruit_id, scene.fruit_at),
		"walked onto again, it stays: the host's alone now (no take and come back loop)"
	)
	var stand := last_seq + walk + 1
	input_sync.history = _inputs(stand, stand, Vector2.ZERO)  # all applied: the player stands


func _test_flight(client: Node, scene: Dictionary, flier_id: int):
	var ack: int = client.input_sync.history[-1][0]
	var player: Node = client._main.get("_players")[YOU]
	var health: int = player.max_stats.health
	yield(_feed(client, scene.taken, ack, 300, health), "completed")
	_t._check(
		_shown_at(client, flier_id, scene.flier_at),
		"full health: the fruit in the attract circle stays where it lies"
	)
	var start_distance: float = scene.flier_at.distance_to(player.global_position)
	var closest := start_distance
	var until := OS.get_ticks_msec() + 600
	while OS.get_ticks_msec() < until and not client._pickups.holds(flier_id):
		_send(client, scene.taken, ack, health - 5)
		yield(_t.get_tree(), "idle_frame")
		var node = client._entities.get(flier_id)
		if node != null:
			closest = min(closest, node.global_position.distance_to(player.global_position))
	_t._check(
		client._pickups.holds(flier_id) and not client._entities.has(flier_id),
		"hurt: it flies in and is taken (%.0f px to %.0f px)" % [start_distance, closest]
	)
	_t._check(closest < start_distance - 20.0, "it flew towards the player on the way")


# The own player runs up at FAST on a slow client (INPUTS_PER_FRAME inputs a frame) while the
# host's snapshots still have it standing, as they do for a round trip and the render delay:
# the gold flies to the player at once, and the crate beside the way is taken though no frame
# ends in its reach.
func _test_gold(client: Node, scene: Dictionary):
	var input_sync: Node = client.input_sync
	var ack: int = input_sync.history[-1][0]
	var gold_id: int = scene.ids[3]
	var swept_id: int = scene.ids[4]
	_speed = FAST
	yield(_feed(client, scene.taken, ack, 150), "completed")
	_t._check(
		_shown_at(client, gold_id, scene.gold_at) and _shown_at(client, swept_id, scene.sweep_at),
		"client shows the gold and the crate above the player where the host has them"
	)
	_t._hold_sounds(true)
	var seq := ack
	var frames := 0
	var ends_reach := false
	var gold_taken_at = null  # the own player's position
	while frames < 14 and (gold_taken_at == null or not client._pickups.holds(swept_id)):
		for _i in INPUTS_PER_FRAME:
			seq += 1
			input_sync.history.append([seq, Vector2.UP])
		if frames % 2 == 0:
			_send(client, scene.taken, ack)
		yield(_t.get_tree().create_timer(INPUTS_PER_FRAME / 60.0), "timeout")
		frames += 1
		ends_reach = ends_reach or _reaches(client, scene.sweep_at)
		if gold_taken_at == null and client._pickups.holds(gold_id):
			gold_taken_at = client._own_display
	var gold_paths := []  # any of them: the client picks one at random
	for sound in client._main.gold_pickup_sounds + client._main.gold_alt_pickup_sounds:
		gold_paths.append(sound.resource_path)
	var queued := 0
	for entry in SoundManager.sounds_to_play:
		queued += 1 if entry[0].resource_path in gold_paths else 0
	_t._hold_sounds(false)
	var away := -1.0  # the player from where the gold lay
	if gold_taken_at != null:
		away = scene.gold_at.distance_to(gold_taken_at)
	_t._check(
		gold_taken_at != null and not client._entities.has(gold_id) and queued == 1,
		(
			"running at %d px/s, the gold flies in and is taken at once (frame %d, %.0f px from"
			+ " where it lay, %d sound)"
		)
		% [FAST, frames, away, queued]
	)
	_t._check(
		client._pickups.holds(swept_id) and not ends_reach,
		"the crate between two frames' positions is taken on the way between them"
	)
	# The host's gold flies (to this player, likely) past the acks: wait for it.
	_moved[gold_id] = Vector2(0, 40)
	yield(_feed(client, scene.taken, seq, 300), "completed")
	_moved.clear()
	_t._check(
		client._pickups.holds(gold_id) and not client._entities.has(gold_id),
		"still gone while the host's gold moves after the acks"
	)
	var confirming: Dictionary = _send(client, scene.gold_taken, seq)
	var queued_sounds := []
	for entry in client._events:
		queued_sounds.append(entry[1])
	_t._check(
		(
			_sounds_in(confirming.events, scene.gold_sounds) == 0
			and _sounds_in(queued_sounds, scene.gold_sounds) == 0
		),
		"the host took the gold: its pickup sound is not played a second time"
	)
	yield(_feed(client, scene.gold_taken, seq, 300), "completed")
	_t._check(
		not client._entities.has(gold_id) and not client._pickups.holds(gold_id),
		"the gold is gone for good once the render reached the host's pickup"
	)
	_speed = null


func _inputs(first: int, last: int, move: Vector2) -> Array:
	var inputs := []
	for seq in range(first, last + 1):
		inputs.append([seq, move])
	return inputs


# A recorded snapshot as the newest one, with the own player's input ack (and health).
func _send(client: Node, msg: Array, ack: int, health = null) -> Dictionary:
	var snap := Snapshot.parse(msg[1])
	_host_t = int(max(_host_t + 1, OS.get_ticks_msec()))
	snap.t = _host_t
	snap.players[YOU][PF.INPUT_ACK] = ack
	if health != null:
		snap.players[YOU][PF.HEALTH] = health
	if _speed != null:
		snap.players[YOU][PF.SPEED] = _speed
	var positions: PoolVector2Array = snap.positions
	for id in _moved:
		var k: int = Snapshot.index_of(snap, id)
		if k >= 0:
			positions[k] += _moved[id]
	snap.positions = positions
	client._on_snapshot(snap)
	return snap


func _feed(client: Node, msg: Array, ack: int, msec: int, health = null):
	var until := OS.get_ticks_msec() + msec
	while OS.get_ticks_msec() < until:
		_send(client, msg, ack, health)
		yield(_t.get_tree().create_timer(1.0 / 30.0), "timeout")


# The own player's predicted reach covers an item at `at`.
func _reaches(client: Node, at: Vector2) -> bool:
	var player: Node = client._main.get("_players")[YOU]
	var reach: Array = OwnPickups.area_circle(player, player._item_pickup_area)
	var center: Vector2 = client._own_display - client._own_error + reach[0]
	return OwnPickups.overlaps(center, reach[1], at, Vector2(16, 16))


func _shown_at(client: Node, id: int, at: Vector2) -> bool:
	var node = client._entities.get(id)
	return node != null and node.visible and node.global_position.distance_to(at) < 1.0


func _paths(client: Node, type_indices: Array) -> Array:
	var paths := []
	for idx in type_indices:
		var sound = client._types.get(idx)
		if sound is AudioStream:
			paths.append(sound.resource_path)
	return paths


static func _sounds_in(events: Array, type_indices: Array) -> int:
	var count := 0
	for event in events:
		if typeof(event) == TYPE_ARRAY and event.size() > 1 and event[0] == Snapshot.EVENT_SOUND:
			count += 1 if event[1] in type_indices else 0
	return count
