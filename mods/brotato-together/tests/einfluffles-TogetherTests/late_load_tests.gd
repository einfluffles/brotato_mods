extends Reference
# Suite late_load: a crowded late wave (three players with six pistols each, CROWDS of enemies
# chasing them, a bullet hell) played by the real game on the host and replayed on a client in
# real time.
# Prints what the snapshots cost on the wire and on both sides, past the first frames (they
# instance the whole crowd at once, as when joining mid-wave). Headless there is no rendering,
# and the times are always this machine's, so compare them with each other.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const PLAYERS := 3
const WEAPONS := 6
const WAVE := 30
const CROWDS := [180, 400]  # enemies alive: the cap of endless wave 30 for 3 players, and more
const ENEMY := "res://entities/units/enemies/crash_zone/basic/baby_alien/baby_alien.tscn"
const BULLET_HELL := "res://projectiles/bullet_hells/BulletHell_Top_2.tscn"
const RECORD_MSEC := 5000
const SETTLE_MSEC := 1500  # the crowd closes in and the bullets come before recording
const PACKET_BYTES := 1200  # about what one UDP packet of Steam's carries

var _t: Node


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	_build()
	var host: Node = together.battle_host
	host.set_process(false)  # driven by hand: no Steam session, so it would end the battle
	var saved_hells: Array = ZoneService.bullets_hell
	ZoneService.bullets_hell = [load(BULLET_HELL)]  # also for the client's scene
	var replayed := true
	for crowd in CROWDS:
		var recording: Dictionary = yield(_record(host, crowd), "completed")
		var frames: Array = yield(
			_replay(together.battle_client, together.client_report, recording), "completed"
		)
		replayed = replayed and not recording.snapshots.empty() and not frames.empty()
	ZoneService.bullets_hell = saved_hells
	Puppet.set_active(false)
	host.set_process(true)
	RunData.invulnerable = false
	RunData.players_data[0].effects[Keys.bullet_hell_event_hash] = 0
	RunData.constant_projectile = 0
	_t._check(replayed, "the crowded waves are recorded and replayed")


# The host's snapshots of a wave with `crowd` enemies alive (topped up as the pistols kill them).
func _record(host: Node, crowd: int):
	var tree: SceneTree = _t.get_tree()
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main: Node = tree.current_scene
	host._start_battle(main)
	_top_up(main, crowd)
	yield(tree.create_timer(SETTLE_MSEC / 1000.0), "timeout")
	var snapshots := []
	var build_usec := []
	var frames := []  # the host's whole frames
	var t0 := OS.get_ticks_usec()
	var last := t0
	var due := t0
	while last - t0 < RECORD_MSEC * 1000:
		yield(tree, "idle_frame")
		var now := OS.get_ticks_usec()
		frames.append(now - last)
		last = now
		if now < due:
			continue
		due = max(due + 1000000 / 30, now)
		_top_up(main, crowd)
		var message: Array = host._build_snapshot()
		build_usec.append(OS.get_ticks_usec() - now)
		snapshots.append(bytes2var(var2bytes(message), false))
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	start.you = 1
	host._end_battle()
	_print_wire(crowd, snapshots, build_usec)
	print("  info:   host frames: %s ms" % _spread(frames, 1000.0))
	return {"start": start, "snapshots": snapshots}


func _top_up(main: Node, crowd: int) -> void:
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var spawner = main._entity_spawner
	for _i in crowd - spawner.enemies.size():
		var at := zone.position + Vector2(randf() * zone.size.x, randf() * zone.size.y)
		_t._spawn_on_host(spawner, ENEMY, EntityType.ENEMY, at)


func _build() -> void:
	CoopService.clear_coop_players()
	for i in PLAYERS:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(PLAYERS)
	var pistol = _t._find_by_id(ItemService.weapons, "weapon_pistol_1")
	for p in PLAYERS:
		RunData.add_character(ItemService.characters[p], p)
		for _w in WEAPONS:
			RunData.add_weapon(pistol, p)
	RunData.current_wave = WAVE
	RunData.is_endless_run = true
	RunData.invulnerable = true  # the wave would end the run before it is recorded
	RunData.constant_projectile = 2
	RunData.players_data[0].effects[Keys.bullet_hell_event_hash] = 1


func _print_wire(crowd: int, snapshots: Array, build_usec: Array) -> void:
	var sizes := []
	var entities := []
	var moving := []
	var events := []
	var poses := []
	var angles := []
	for msg in snapshots:
		sizes.append(var2bytes(msg).size())
		var snap := Snapshot.parse(msg[1])
		entities.append(snap.ids.size())
		var flags: PoolByteArray = snap.flags
		var resting := 0
		for i in snap.ids.size():
			var bit: int = i * Snapshot.FLAG_BITS
			resting += 1 if (flags[bit >> 3] >> (bit & 7)) & Snapshot.FLAG_REST else 0
		moving.append(snap.ids.size() - resting)
		events.append(snap.events.size())
		poses.append(snap.poses.size())
		angles.append(snap.get("angles", {}).size())
	var over := 0
	var packets := 0
	for size in sizes:
		over += 1 if size > PACKET_BYTES else 0
		packets += int(ceil(size / float(PACKET_BYTES)))
	print(
		(
			"  info: %d enemies: %d snapshots of %s entities (%s moving, %s posed, %s angles,"
			+ " %s events): %s B, %.1f KB/s per client; %d over %d B, %.1f packets each"
		)
		% [
			crowd, sizes.size(), _spread(entities), _spread(moving), _spread(poses),
			_spread(angles), _spread(events), _spread(sizes), _mean(sizes) * 30.0 / 1024.0, over,
			PACKET_BYTES, packets / float(sizes.size())
		]
	)
	print("  info:   host builds a snapshot in %s ms" % _spread(build_usec, 1000.0))


# The recording on the client, in real time; returns the mirror's usec per frame.
func _replay(client: Node, report: Node, recording: Dictionary):
	var tree: SceneTree = _t.get_tree()
	var snapshots: Array = recording.snapshots
	var snaps := []
	for msg in snapshots:
		snaps.append(SnapshotTests.retimed(msg, snapshots, 0))
	report.test_client = true
	report.sent.clear()
	client._on_battle_start(recording.start)
	yield(client, "battle_entered")
	client.set_process(false)  # run below, timed per frame
	yield(tree, "idle_frame")
	var frames := []
	var taking := []
	var whole := []  # the client's whole frames
	var phases := [0, 0, 0, 0]
	var replay_start := OS.get_ticks_msec()
	var next := 0
	var last_usec := OS.get_ticks_usec()
	var last_start := last_usec
	while OS.get_ticks_msec() < replay_start + RECORD_MSEC:
		yield(tree, "idle_frame")
		while next < snaps.size() and replay_start + snaps[next].t <= OS.get_ticks_msec():
			var snap: Dictionary = snaps[next]
			snap.t += replay_start
			var started := OS.get_ticks_usec()
			client._on_snapshot(snap)
			taking.append(OS.get_ticks_usec() - started)
			next += 1
		var before: Array = report._phases.duplicate()
		var started := OS.get_ticks_usec()
		whole.append(started - last_start)
		last_start = started
		client._process((started - last_usec) / 1000000.0)
		frames.append(OS.get_ticks_usec() - started)
		last_usec = OS.get_ticks_usec()
		for i in min(phases.size(), before.size()) if frames.size() > 2 else 0:
			phases[i] += report._phases[i] - before[i]
	client.set_process(true)
	report.test_client = false
	report.sent.clear()
	var entities: int = client._entities.size()
	client._leave_battle()
	var parse := []
	for msg in snapshots.slice(0, min(29, snapshots.size() - 1)):
		var started := OS.get_ticks_usec()
		Snapshot.parse(msg[1])
		parse.append(OS.get_ticks_usec() - started)
	var parts := []
	for i in phases.size():
		var per_frame: float = phases[i] / 1000.0 / max(1, frames.size() - 2)
		parts.append("%s %.2f" % [ClientReport.PHASE_NAMES[i], per_frame])
	print(
		(
			"  info:   client mirrors %d entities in %s ms per frame (%d frames; %s), takes a"
			+ " snapshot in %s ms after parsing it in %s ms"
		)
		% [
			entities, _spread(frames.slice(2, frames.size() - 1), 1000.0), frames.size(),
			PoolStringArray(parts).join(", "), _spread(taking, 1000.0), _spread(parse, 1000.0)
		]
	)
	print("  info:   client frames: %s ms" % _spread(whole.slice(2, whole.size() - 1), 1000.0))
	return frames


# "mean / 95th percentile / max"
static func _spread(values: Array, scale := 1.0) -> String:
	if values.empty():
		return "-"
	var sorted := values.duplicate()
	sorted.sort()
	var p95 = sorted[int(floor((sorted.size() - 1) * 0.95))]
	if scale == 1.0:
		return "%d / %d / %d" % [round(_mean(values)), p95, sorted[-1]]
	return "%.2f / %.2f / %.2f" % [_mean(values) / scale, p95 / scale, sorted[-1] / scale]


static func _mean(values: Array) -> float:
	var total := 0.0
	for value in values:
		total += value
	return total / max(1, values.size())
