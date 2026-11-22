extends Reference
# Suite puddle_reuse: trails of fire, acid and petrol puddles, a new one of each every 0.25 s that
# lasts 2 s, replayed on a client. The fire trail is the other player's magma boots
# (FireTrailEffectBehavior); acid and petrol come from GPESpawner beside it. The client shows each
# whole trail, also once its puddle puppets come back from the pool.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const MAGMA_BOOTS := "res://items/all/04_primal_dread/magma_boots/magma_boots_effect_0.tres"
const KINDS := ["fire", "acid", "petrol"]
const WEARER := 1
const RECORD_MSEC := 5000
const REUSED_MSEC := 4000  # puppets of the first puddles are back from the pool by then
const DROP_MSEC := 250  # FireTrailEffectBehavior's SpawnTimer
const LIFETIME := 2.0  # GPESpawner.FIRE_PUDDLE_LIFETIME, also for acid and petrol here
const STEP := 1.0  # px per physics tick
const SIDE := 250.0  # px between the trails
const MIN_TRAIL := 6  # of the 8 that LIFETIME and DROP_MSEC keep on the ground

var t: Node


func _init(test_mod: Node) -> void:
	t = test_mod


func run(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var tree := t.get_tree()
	host.set_process(false)
	var trail: Array = RunData.players_data[WEARER].effects[Keys.fire_trail_hash]
	var boots: Resource = load(MAGMA_BOOTS)
	trail.append(boots)  # also on the client's wearer: its puppet must put down none
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main := tree.current_scene
	host._start_battle(main)
	var players: Array = main.get("_players")
	for player in players:
		player._weapons_container.propagate_call("set_physics_process", [false])
		player._weapons_container.propagate_call("set_process", [false])
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	players[0].global_position = zone.position + Vector2(zone.size.x - 150, 150)  # off the trails
	var wearer: Node = players[WEARER]
	wearer.global_position = zone.position + Vector2(150, zone.size.y / 2)

	var recorded := []
	var t0 := OS.get_ticks_msec()
	var next_snapshot := 0.0
	var next_drop := 0
	while OS.get_ticks_msec() - t0 < RECORD_MSEC:
		yield(tree, "physics_frame")
		wearer.global_position.x += STEP
		if OS.get_ticks_msec() - t0 >= next_drop:
			next_drop += DROP_MSEC
			_drop(main._gpe_spawner, wearer.global_position)
		if OS.get_ticks_msec() - t0 >= next_snapshot:
			next_snapshot += 1000.0 / 30.0
			recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()
	var sent_least := _counts(99)
	var t_first: int = Snapshot.parse(recorded[0][1]).t
	for msg in recorded:
		var snap := Snapshot.parse(msg[1])
		if snap.t - t_first >= REUSED_MSEC:
			var sent := _sent(snap, start.types)
			for kind in KINDS:
				sent_least[kind] = int(min(sent_least[kind], sent[kind]))
	for kind in KINDS:
		t._check(
			sent_least[kind] >= MIN_TRAIL,
			"host sends the whole %s trail (at least %d)" % [kind, sent_least[kind]]
		)

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var cmain: Node = client._main
	var lives := {}  # puppet instance id -> [lives so far, seen in the last sample]
	var shown_least := _counts(99)
	var reused_shown := _counts(0)
	var unsettled := []  # puppets whose tween is done that are not fully shown
	var local := 0
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(tree, "idle_frame")
		client._on_snapshot(snap)
		var late: bool = snap.t - replay_start >= REUSED_MSEC
		var shown := _counts(0)
		var alive := {}
		for puddle in _puppets(cmain, client):
			var key: int = puddle.get_instance_id()
			alive[key] = true
			var life = lives.get(key)
			if life == null or not life[1]:  # new, or back from the pool
				life = [(life[0] if life != null else 0) + 1, true]
				lives[key] = life
			var kind := _kind(puddle)
			if puddle.tween.is_active():
				shown[kind] += 1  # coming up
				continue
			if not _fully_shown(puddle):
				if late:
					unsettled.append("%s a %.2f x%.2f" % [kind, puddle.modulate.a, puddle.scale.x])
				continue
			shown[kind] += 1
			if late and life[0] >= 2:
				reused_shown[kind] += 1
		for key in lives:
			if not alive.has(key):
				lives[key][1] = false  # fading or pooled: its next appearance is a new life
		if late:
			for kind in KINDS:
				shown_least[kind] = int(min(shown_least[kind], shown[kind]))
		for container in [cmain._fire_puddles_container, cmain._gpe_container]:
			for child in container.get_children():
				if _is_trail(child) and not child.has_meta(client.PUPPET_TYPE_META):
					local += 1
	for kind in KINDS:
		t._check(
			reused_shown[kind] > 0,
			"%s puddle puppets reused from the pool (shown %d times)" % [kind, reused_shown[kind]]
		)
		t._check(
			shown_least[kind] >= MIN_TRAIL,
			"client shows the whole %s trail (at least %d)" % [kind, shown_least[kind]]
		)
	t._check(
		unsettled.empty(),
		"every puddle puppet whose tween is done is fully shown %s" % [unsettled.slice(0, 4)]
	)
	t._check(local == 0, "the client puts down no puddles of its own (%d)" % local)
	trail.erase(boots)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


# Acid and petrol beside the fire trail, with its lifetime.
func _drop(gpe: Node, at: Vector2) -> void:
	for puddle in [
		gpe.get_new_acid_puddle_at_pos(at + Vector2(0, -SIDE), false, false),
		gpe.get_new_petrol_puddle_at_pos(at + Vector2(0, SIDE), false, false),
	]:
		puddle.lifetime = LIFETIME
		puddle._lifetime_timer.start(LIFETIME)


# On the ground and not fading.
static func _puppets(main: Node, client: Node) -> Array:
	var found := []
	for container in [main._fire_puddles_container, main._gpe_container]:
		for child in container.get_children():
			if _is_trail(child) and child.has_meta(client.PUPPET_TYPE_META) and child.is_active():
				found.append(child)
	return found


# The spawn tween's end: a reused puppet that kept its old fade sits at alpha 0 and x0.3.
static func _fully_shown(puddle: Node) -> bool:
	return (
		is_equal_approx(puddle.modulate.a, 1.0)
		and puddle.scale.distance_to(puddle._target_scale) < 0.01
	)


static func _is_trail(node: Node) -> bool:
	return node is FirePuddle or node is AcidPuddle or node is PetrolPuddle


static func _kind(puddle: Node) -> String:
	if puddle is FirePuddle:
		return "fire"
	return "acid" if puddle is AcidPuddle else "petrol"


static func _counts(value: int) -> Dictionary:
	var counts := {}
	for kind in KINDS:
		counts[kind] = value
	return counts


static func _sent(snap: Dictionary, types: Dictionary) -> Dictionary:
	var counts := _counts(0)
	for type_idx in snap.types:
		var path := str(types.get(type_idx, ""))
		for kind in KINDS:
			if "/%s_puddle.tscn#" % kind in path:
				counts[kind] += 1
	return counts
