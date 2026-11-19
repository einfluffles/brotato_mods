extends Reference
# Snapshot wire format (sync/snapshot.gd): round trip and quantization, strict parsing, sizes of
# realistic small/mid/late-wave snapshots, the O(1) id index, resolve() (resting entities, sparse
# player stats) and event selection.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const PF := Snapshot.PlayerField
const MAP := Vector2(2048, 1536)

var _t: Node
var _rng := RandomNumberGenerator.new()


func _init(tests: Node) -> void:
	_t = tests
	_rng.seed = 4242


# Host snapshots in recording order, parsed and resolved like a client receiving all of them.
static func views(recorded: Array) -> Array:
	var cache := {}
	var result := []
	for msg in recorded:
		result.append(Snapshot.resolve(Snapshot.parse(msg[1]), cache))
	return result


# A recorded message parsed, its host time moved onto a replay timeline starting at `start`.
static func retimed(msg: Array, recorded: Array, start: int) -> Dictionary:
	var snap := Snapshot.parse(msg[1])
	snap.t = start + (snap.t - Snapshot.parse(recorded[0][1]).t)
	return snap


func run() -> void:
	_test_round_trip()
	_test_malformed()
	_test_sizes()
	_test_index()
	_test_resolve()
	_test_event_selection()


func _test_round_trip() -> void:
	var view := scenario(3, 30, 20, 10, 4, 8, 4, 3, false)
	view.players[1][PF.HEALTH] = null  # stats left out for this player
	for field in Snapshot.STAT_FIELDS:
		view.players[1][field] = null
	var parsed := Snapshot.parse(Snapshot.encode(view))
	_t._check(not parsed.empty(), "snapshot round trip parses")
	if parsed.empty():
		return
	var worst := 0.0
	for i in view.ids.size():
		worst = max(worst, parsed.positions[i].distance_to(view.positions[i]))
	_t._check(
		parsed.ids == view.ids and parsed.types == view.types and parsed.flags == view.flags,
		"ids, types (as runs) and flags survive"
	)
	_t._check(worst <= 0.36, "positions within 0.25 px per axis (worst %.3f px)" % worst)
	var weapons_ok := true
	for p in view.players.size():
		var a: PoolRealArray = view.players[p][PF.WEAPONS]
		var b: PoolRealArray = parsed.players[p][PF.WEAPONS]
		weapons_ok = weapons_ok and a.size() == b.size()
		for k in min(a.size(), b.size()):
			var tolerance := 0.07 if k % 4 in [1, 2] else 0.0002  # 1/8 px offsets, i16 angles
			var diff: float = abs(wrapf(a[k] - b[k], -PI, PI)) if k % 4 in [0, 3] else abs(a[k] - b[k])
			weapons_ok = weapons_ok and diff <= tolerance
		var position_error: float = parsed.players[p][PF.POSITION].distance_to(view.players[p][0])
		weapons_ok = weapons_ok and position_error <= 0.36
	_t._check(weapons_ok, "player positions and weapon poses within quantization")
	_t._check(
		(
			parsed.players[0][PF.HEALTH] == view.players[0][PF.HEALTH]
			and parsed.players[0][PF.GOLD] == view.players[0][PF.GOLD]
			and is_equal_approx(parsed.players[0][PF.XP], view.players[0][PF.XP])
			and parsed.players[2][PF.HIT_PROTECTION] == 2
			and parsed.players[0][PF.INPUT_ACK] == view.players[0][PF.INPUT_ACK]
			and parsed.players[1][PF.HEALTH] == null
			and not Snapshot.has_stats(parsed.players[1])
		),
		"player stats exact when sent, null when left out"
	)
	var poses_ok: bool = parsed.poses.keys() == view.poses.keys()
	for i in view.poses:
		poses_ok = poses_ok and parsed.poses.get(i) == view.poses[i]
	_t._check(poses_ok, "poses survive (f32)")
	_t._check(_events_match(view.events, parsed.events), "damage, sound and anim events survive")


func _events_match(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var x: Array = a[i]
		var y: Array = b[i]
		if x[0] != y[0] or x[1] != y[1] or x.size() != y.size():
			return false
		match x[0]:
			Snapshot.EVENT_DAMAGE:
				if x[2] != y[2] or x[4] != y[4] or x[5] != y[5] or x[3].distance_to(y[3]) > 0.01:
					return false
			Snapshot.EVENT_SOUND:
				var same_position: bool = (
					(x[2] == null and y[2] == null)
					or (x[2] != null and y[2] != null and x[2].distance_to(y[2]) < 0.5)
				)
				if not same_position or abs(x[3] - y[3]) > 0.25 or abs(x[4] - y[4]) > 0.005:
					return false
				if x[5] != y[5] or abs(x[6] - y[6]) > 0.01:
					return false
			Snapshot.EVENT_ANIM:
				if x[2] != y[2] or abs(x[3] - y[3]) > 0.001 or abs(x[4] - y[4]) > 0.001:
					return false
	return true


func _test_malformed() -> void:
	var view := scenario(2, 12, 6, 4, 2, 4, 3, 2, true)
	var bytes := Snapshot.encode(view)
	var truncated_rejected := true
	for size in bytes.size():
		var prefix: PoolByteArray = bytes.subarray(0, size - 1) if size > 0 else PoolByteArray()
		truncated_rejected = truncated_rejected and Snapshot.parse(prefix).empty()
	_t._check(truncated_rejected, "every truncation of a %d B snapshot rejected" % bytes.size())
	var longer := bytes
	longer.append(0)
	_t._check(Snapshot.parse(longer).empty(), "trailing bytes rejected")
	_t._check(Snapshot.parse([1, 2, 3]).empty() and Snapshot.parse(null).empty(), "non-bytes rejected")
	var bad := {
		"pose index out of range": [view.ids.size(), PoolRealArray([0.5])],
		"NaN pose value": [0, PoolRealArray([NAN])],
		"over the pose value limit": [0, _reals(Snapshot.MAX_POSE_VALUES + 1)],
	}
	for label in bad:
		var broken := view.duplicate(true)
		broken.poses = {bad[label][0]: bad[label][1]}
		_t._check(Snapshot.parse(Snapshot.encode(broken)).empty(), "malformed poses rejected: %s" % label)
	var many := view.duplicate(true)
	many.events = []
	for i in Snapshot.MAX_EVENTS + 1:
		many.events.append([Snapshot.EVENT_DAMAGE, 1, i, Vector2.ZERO, 0, 0])
	_t._check(Snapshot.parse(Snapshot.encode(many)).empty(), "too many events rejected")
	var odd_name := view.duplicate(true)
	odd_name.events = [[Snapshot.EVENT_ANIM, 1, "shööt", 0.0, 1.0]]
	var parsed_name := Snapshot.parse(Snapshot.encode(odd_name))
	_t._check(
		not parsed_name.empty() and parsed_name.events[0][2] == "",
		"non-ASCII animation names sent empty (ignored by the client)"
	)
	# Random corruption: anything goes as long as parsing never errors.
	var survived := 0
	for i in 300:
		var corrupt := bytes
		for _k in 3:
			corrupt[_rng.randi() % corrupt.size()] = _rng.randi() % 256
		survived += 0 if Snapshot.parse(corrupt).empty() else 1
	_t._check(true, "300 corrupted snapshots parsed without errors (%d still well-formed)" % survived)


func _reals(count: int) -> PoolRealArray:
	var values := PoolRealArray()
	for i in count:
		values.append(float(i))
	return values


# Sizes on the wire (message envelope included) for realistic waves, against old_format().
func _test_sizes() -> void:
	var scenarios := {
		"small (wave 3, 2 players)": [2, 20, 15, 10, 0, 4, 3, 1],
		"mid (wave 10, 3 players)": [3, 60, 40, 30, 6, 6, 3, 2],
		"late (wave 18, 4 players)": [4, 150, 90, 50, 10, 30, 6, 8],
	}
	var sizes := {}
	for label in scenarios:
		var args: Array = scenarios[label]
		var view: Dictionary = callv("scenario", args + [true])
		var old_size := var2bytes([Protocol.Msg.SNAPSHOT, old_format(view)]).size()
		view.events = Snapshot.select_events(view.events, 48)  # BattleHost.MAX_EVENTS
		var new_size := Protocol.encode(Protocol.Msg.SNAPSHOT, Snapshot.encode(view)).size()
		sizes[label] = new_size
		print(
			(
				"  info: snapshot %s, %d entities, %d events: %d B before, %d B now (%d%%)"
				% [
					label,
					view.ids.size(),
					args[5] + args[6] + args[7],
					old_size,
					new_size,
					100 * new_size / old_size
				]
			)
		)
	_t._check(sizes["mid (wave 10, 3 players)"] < 1000, "mid-wave snapshot well under 1200 B")
	_t._check(sizes["late (wave 18, 4 players)"] < 2200, "late-wave snapshot about a quarter")


# var2bytes of plain arrays (the format of protocol 3), for the size comparison.
static func old_format(view: Dictionary) -> Array:
	var players := []
	for entry in view.players:
		var old: Array = entry.duplicate()
		for field in Snapshot.STAT_FIELDS:
			old[field] = 0 if old[field] == null else old[field]
		old[PF.XP] = float(old[PF.XP])
		players.append(old)
	var events := []
	for event in view.events:
		events.append(event.slice(0, 4) if event[0] == Snapshot.EVENT_SOUND else event)
	var flags := []
	for i in view.ids.size():
		flags.append(Snapshot.get_flags(view.flags, i) & 7)
	var poses := PoolRealArray()
	for i in view.poses:
		poses.append(i)
		poses.append(view.poses[i].size())
		poses.append_array(view.poses[i])
	var packed := PoolByteArray()
	packed.resize((flags.size() * 3 + 7) / 8)
	return [
		view.battle_id, view.t, view.wave_time_left, players, view.ids, view.types, view.positions,
		events, packed, poses
	]


# 600 entities looked up per frame.
func _test_index() -> void:
	var view := scenario(4, 300, 200, 80, 20, 0, 0, 0, false)
	var count: int = view.ids.size()
	var start := OS.get_ticks_usec()
	var found := 0
	for i in count:
		var id: int = view.ids[count - 1 - i]
		for k in count:  # a linear index_of, for comparison
			if view.ids[k] == id:
				found += 1
				break
	var linear_usec := OS.get_ticks_usec() - start
	start = OS.get_ticks_usec()
	var correct := true
	for i in count:
		correct = correct and Snapshot.index_of(view, view.ids[count - 1 - i]) == count - 1 - i
	var indexed_usec := OS.get_ticks_usec() - start
	print(
		(
			"  info: %d entity lookups per frame: linear %.2f ms, indexed %.2f ms (incl. building)"
			% [count, linear_usec / 1000.0, indexed_usec / 1000.0]
		)
	)
	_t._check(correct and found == count and Snapshot.index_of(view, 99999) == -1, "id index exact")


func _test_resolve() -> void:
	var cache := {}
	var p0 := [Vector2(1, 1), 10, 20, 0, 5, 2, 1.5, PoolRealArray(), null, null, 0]
	var p1 := [Vector2(2, 2), null, null, 0, null, null, null, PoolRealArray(), null, null, null]
	var first := _view(100, [5, 6], [Vector2(10, 20), Vector2.ZERO], [0, Snapshot.FLAG_REST], [p0, p1])
	first.poses = {1: PoolRealArray([0.5])}
	Snapshot.resolve(first, cache)
	_t._check(
		Array(first.ids) == [5] and first.poses.empty() and Snapshot.index_of(first, 5) == 0,
		"resting entity never seen yet left out"
	)
	_t._check(not Snapshot.has_stats(first.players[1]), "player stats unknown until first sent")
	var p1_stats := [Vector2(2, 2), 30, 40, 0, 7, 3, 2.5, PoolRealArray(), null, null, 1]
	var second := _view(
		200, [5, 6], [Vector2.ZERO, Vector2(30, 40)], [Snapshot.FLAG_REST, 0], [p0.duplicate(), p1_stats]
	)
	Snapshot.resolve(second, cache)
	_t._check(
		second.positions[0] == Vector2(10, 20) and second.positions[1] == Vector2(30, 40),
		"resting entity keeps its last position"
	)
	var late := _view(150, [6], [Vector2.ZERO], [Snapshot.FLAG_REST], [p0.duplicate(), p1.duplicate()])
	Snapshot.resolve(late, cache)
	_t._check(
		late.positions.size() == 1 and late.positions[0] == Vector2(30, 40) and cache.t == 200,
		"out-of-order snapshot filled, cache kept"
	)
	_t._check(
		(
			late.players[1][PF.HEALTH] == 30
			and late.players[1][PF.XP] == 2.5
			and late.players[1][PF.HIT_PROTECTION] == 1
		),
		"stats filled in"
	)


func _view(t: int, ids: Array, positions: Array, flags: Array, players: Array) -> Dictionary:
	return {
		"battle_id": 1,
		"t": t,
		"wave_time_left": 10.0,
		"players": players,
		"ids": PoolIntArray(ids),
		"types": PoolIntArray(range(ids.size())),
		"positions": PoolVector2Array(positions),
		"flags": Snapshot.pack_flags(flags),
		"poses": {},
		"events": [],
	}


func _test_event_selection() -> void:
	var events := []
	for i in 10:
		events.append([Snapshot.EVENT_ANIM, i, "shoot", 0.0, 1.0])
	for i in 5:
		events.append([Snapshot.EVENT_DAMAGE, -1, i, Vector2.ZERO, 0, 0])
	for i in 30:
		events.append([Snapshot.EVENT_DAMAGE, 100 + i, i, Vector2.ZERO, 0, 0])
	for i in 15:
		events.append([Snapshot.EVENT_SOUND, i % 5, null, 0.0, 0.0, false, 0.0])
	var selected := Snapshot.select_events(events, 48)
	var kinds := {"anim": 0, "player": 0, "enemy": 0, "sound": 0}
	for event in selected:
		match event[0]:
			Snapshot.EVENT_ANIM:
				kinds.anim += 1
			Snapshot.EVENT_DAMAGE:
				kinds["player" if event[1] < 0 else "enemy"] += 1
			Snapshot.EVENT_SOUND:
				kinds.sound += 1
	_t._check(
		selected.size() == 48 and kinds.anim == 10 and kinds.player == 5 and kinds.sound == 5,
		"event cap drops duplicate sounds first, then enemy damage numbers %s" % kinds
	)
	_t._check(kinds.enemy == 28 and selected[0][0] == Snapshot.EVENT_ANIM, "kept events in order")


# A host-like view: entities grouped by type (bosses/enemies, projectiles, gold, structures),
# gold and structures resting when `resting`.
func scenario(
	players: int,
	enemies: int,
	projectiles: int,
	golds: int,
	structures: int,
	damage: int,
	sounds: int,
	anims: int,
	resting: bool
) -> Dictionary:
	var view := {
		"battle_id": 3,
		"t": 123456,
		"wave_time_left": 42.37,
		"players": [],
		"poses": {},
		"events": [],
	}
	for p in players:
		var weapons := PoolRealArray()
		for w in 6:
			var sprite := [12.3, -4.6, 0.3] if w == 0 else [0.0, 0.0, 0.0]  # mid-thrust
			weapons.append_array(PoolRealArray([_rng.randf_range(-PI, PI)] + sprite))
		var position := Vector2(_rng.randf_range(0, MAP.x), _rng.randf_range(0, MAP.y))
		var entry := [position, 25 + p, 40, 1000 + p * 7, 150 + p, 9, 37.5, weapons, null, null, p]
		view.players.append(entry)
	var ids := PoolIntArray()
	var types := PoolIntArray()
	var positions := PoolVector2Array()
	var flags := []
	# Live ids are a sparse sample of recent spawns (projectiles churn through most ids): about
	# one live entity per 8 ids; the host sorts each type's ids.
	var total := enemies + projectiles + golds + structures
	var used := {}
	var groups := [[enemies, 6, true, false], [projectiles, 2, false, false], [golds, 1, false, true]]
	groups.append([structures, 2, true, true])
	var type_base := 0
	for group in groups:
		for kind in group[1]:
			var count: int = group[0] / group[1] + (1 if kind < group[0] % group[1] else 0)
			var group_ids := []
			while group_ids.size() < count:
				var id := 1000 + _rng.randi() % (8 * total)
				if not used.has(id):
					used[id] = true
					group_ids.append(id)
			group_ids.sort()
			for id in group_ids:
				ids.append(id)
				types.append(type_base + kind)
				positions.append(Vector2(_rng.randf_range(0, MAP.x), _rng.randf_range(0, MAP.y)))
				var entity_flags: int = Snapshot.FLAG_FACING_LEFT if group[2] and _rng.randf() < 0.5 else 0
				if resting and group[3] and _rng.randf() > 1.0 / 15.0:
					entity_flags |= Snapshot.FLAG_REST
				flags.append(entity_flags)
		type_base += group[1]
	view["ids"] = ids
	view["types"] = types
	view["positions"] = positions
	view["flags"] = Snapshot.pack_flags(flags)
	if ids.size() > 3:
		view.poses[1] = PoolRealArray([0.7])
		view.poses[3] = PoolRealArray([1.2, 85.5])
	for i in damage:
		var target: int = ids[_rng.randi() % ids.size()]
		if i % 8 == 0 and players > 0:
			target = -(i % players) - 1
		var knockback := Vector2.RIGHT.rotated(_rng.randf_range(-PI, PI))
		view.events.append([Snapshot.EVENT_DAMAGE, target, _rng.randi() % 60, knockback, i % 3, 0])
	for i in sounds:
		var position = null
		if i % 2 == 0:
			position = Vector2(_rng.randf_range(0, MAP.x), _rng.randf_range(0, MAP.y))
		var cooldown := 0.5 if i == 1 else 0.0
		view.events.append([Snapshot.EVENT_SOUND, 20 + i, position, -5.5, 0.2, i == 1, cooldown])
	for i in anims:
		view.events.append([Snapshot.EVENT_ANIM, ids[i % ids.size()], "shoot", 0.25, 1.5])
	return view
