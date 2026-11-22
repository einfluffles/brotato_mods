extends Reference
# Suite magma_trail: the fire trail of magma boots (FireTrailEffectBehavior, a puddle every
# 0.25 s that lasts 2 s) worn by the other player. The client shows the whole trail, also once
# its puddle puppets come back from the pool.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const MAGMA_BOOTS := "res://items/all/04_primal_dread/magma_boots/magma_boots_effect_0.tres"
const WEARER := 1
const RECORD_MSEC := 5000
const REUSED_MSEC := 4000  # puppets of the first puddles are back from the pool by then
const STEP := 1.0  # px per physics tick
const MIN_TRAIL := 6  # of the 8 a 2 s lifetime and a 0.25 s timer keep on the ground

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
	var wearer: Node = players[WEARER]
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	wearer.global_position = zone.position + Vector2(150, zone.size.y / 2)

	var recorded := []
	var t0 := OS.get_ticks_msec()
	var next_snapshot := 0.0
	while OS.get_ticks_msec() - t0 < RECORD_MSEC:
		yield(tree, "physics_frame")
		wearer.global_position.x += STEP
		if OS.get_ticks_msec() - t0 >= next_snapshot:
			next_snapshot += 1000.0 / 30.0
			recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()
	var sent_least := 99
	var t_first: int = Snapshot.parse(recorded[0][1]).t
	for msg in recorded:
		var snap := Snapshot.parse(msg[1])
		if snap.t - t_first >= REUSED_MSEC:
			sent_least = int(min(sent_least, _fire_ids(snap, start.types)))
	t._check(sent_least >= MIN_TRAIL, "host sends the whole trail (at least %d)" % sent_least)

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var cmain: Node = client._main
	var shown_least := 99
	var local := 0
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(tree, "idle_frame")
		client._on_snapshot(snap)
		if snap.t - replay_start >= REUSED_MSEC:
			shown_least = int(min(shown_least, _shown_fire(cmain)))
		for child in cmain._fire_puddles_container.get_children():
			if child is FirePuddle and not child.has_meta(client.PUPPET_TYPE_META):
				local += 1
	t._check(
		shown_least >= MIN_TRAIL,
		"client shows the whole trail with reused puppets (at least %d)" % shown_least
	)
	t._check(local == 0, "the client's own wearer puts down no puddles (%d)" % local)
	trail.erase(boots)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


# On the ground and visible: a reused puppet that kept its old fade sits at alpha 0.
static func _shown_fire(main: Node) -> int:
	var count := 0
	for child in main._fire_puddles_container.get_children():
		if child is FirePuddle and child.is_active() and child.modulate.a > 0.0:
			count += 1
	return count


static func _fire_ids(snap: Dictionary, types: Dictionary) -> int:
	var count := 0
	for type_idx in snap.types:
		if "fire_puddle" in str(types.get(type_idx, "")):
			count += 1
	return count
