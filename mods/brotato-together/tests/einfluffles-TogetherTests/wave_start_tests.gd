extends Reference
# Suite wave_start: the start of a late endless wave with a build of structures and rocket
# launchers, played by the real game on the host and replayed on a client in real time. Prints
# what the client's mirror spends its frames on and what each freshly instanced puppet costs.
# Headless: no rendering, and the times are this machine's, so compare them with each other.

const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const WAVE := 25
const RECORD_MSEC := 8000
const SETTLE_MSEC := 500
const STRUCTURE_ITEMS := [
	"item_turret",
	"item_turret_flame",
	"item_turret_laser",
	"item_turret_rocket",
	"item_landmines",
	"item_garden",
	"item_wandering_bot",
	"item_pocket_factory",
	"item_tyler",
]
const COPIES := 2
const WEAPON := "weapon_rocket_launcher_2"
const SLOW_MIRROR_MSEC := [5.0, 10.0]
const TOP_FRAMES := 5
const TOP_FRESH_PER_FRAME := 3
const TOP_SCENES := 10

var _t: Node


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	var items := _build()
	var tree: SceneTree = _t.get_tree()
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var report: Node = together.client_report
	host.set_process(false)  # driven by hand: no Steam session, so it would end the battle
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	host._start_battle(tree.current_scene)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < RECORD_MSEC:
		yield(tree.create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	var host_types: Dictionary = host._types.duplicate()
	host._end_battle()
	start.types = {}
	for path in host_types:
		start.types[host_types[path]] = path
	var snaps := []
	var most := 0
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, 0)
		most = max(most, snap.ids.size())
		snaps.append(snap)
	print(
		(
			"  info: wave %d endless, 2 players with %d structure items and %s: %d snapshots"
			+ " over %d s, up to %d entities"
		)
		% [WAVE, items, WEAPON, snaps.size(), RECORD_MSEC / 1000, most]
	)

	report.test_client = true
	report.sent.clear()
	report.fresh_log = []
	yield(tree.create_timer(0.2), "timeout")  # active, on the host's battle scene
	client._on_battle_start(start)
	yield(client, "battle_entered")
	client.set_process(false)  # run below, timed per frame
	var frames := []
	var replay_start := OS.get_ticks_msec()
	var next := 0
	var last_usec := OS.get_ticks_usec()
	while OS.get_ticks_msec() < replay_start + RECORD_MSEC + SETTLE_MSEC:
		yield(tree, "idle_frame")
		while next < snaps.size() and replay_start + snaps[next].t <= OS.get_ticks_msec():
			var snap: Dictionary = snaps[next]
			snap.t += replay_start
			client._on_snapshot(snap)
			next += 1
		frames.append(_mirror_frame(client, report, replay_start, last_usec))
		last_usec = OS.get_ticks_usec()
	var fresh: Array = report.fresh_log
	client.set_process(true)
	report.fresh_log = null
	report.test_client = false
	report.sent.clear()
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)
	RunData.invulnerable = false

	_print_frames(frames)
	_print_scenes(fresh)
	var structures := false
	for entry in fresh:
		structures = structures or "turret" in entry[0]
	_t._check(most > 0 and not frames.empty(), "the late wave is recorded and replayed")
	_t._check(structures, "the build's structures are mirrored as fresh puppets")


# Both players: the structure items COPIES times, a rocket launcher, no damage taken.
func _build() -> int:
	var count := 0
	for i in 2:
		var weapon = _t._find_by_id(ItemService.weapons, WEAPON)
		if weapon != null:
			RunData.add_weapon(weapon, i)
		for id in STRUCTURE_ITEMS:
			var item = _t._find_by_id(ItemService.items, id)
			if item == null:
				continue
			for _c in COPIES:
				RunData.add_item(item, i)
				count += 1
	RunData.is_endless_run = true
	RunData.invulnerable = true  # the wave would end the run before it is recorded
	return count / 2


# One client frame: BattleClient._process timed, with its phases and fresh puppets.
func _mirror_frame(client: Node, report: Node, replay_start: int, last_usec: int) -> Dictionary:
	var phases_before: Array = report._phases.duplicate()
	var fresh_before: int = report.fresh_log.size()
	var started := OS.get_ticks_usec()
	client._process((started - last_usec) / 1000000.0)
	var usec := OS.get_ticks_usec() - started
	var phases := []
	for i in phases_before.size():
		phases.append(report._phases[i] - phases_before[i])
	var fresh := []
	for k in range(fresh_before, report.fresh_log.size()):
		fresh.append(report.fresh_log[k])
	return {"at": OS.get_ticks_msec() - replay_start, "usec": usec, "phases": phases, "fresh": fresh}


func _print_frames(frames: Array) -> void:
	var total := 0
	var slow := [0, 0]
	for frame in frames:
		total += frame.usec
		for i in SLOW_MIRROR_MSEC.size():
			if frame.usec >= SLOW_MIRROR_MSEC[i] * 1000:
				slow[i] += 1
	print(
		(
			"  info: client replay: %d frames, mirror avg %.2f ms; %d frames of %d ms or more,"
			+ " %d of %d ms or more"
		)
		% [
			frames.size(), total / 1000.0 / max(1, frames.size()), slow[0], SLOW_MIRROR_MSEC[0],
			slow[1], SLOW_MIRROR_MSEC[1]
		]
	)
	var worst := frames.duplicate()
	worst.sort_custom(self, "_slower")
	for frame in worst.slice(0, min(TOP_FRAMES, worst.size()) - 1):
		var parts := []
		for i in ClientReport.PHASE_NAMES.size():
			parts.append("%s %.1f" % [ClientReport.PHASE_NAMES[i], frame.phases[i] / 1000.0])
		var fresh: Array = frame.fresh.duplicate()
		fresh.sort_custom(self, "_costlier")
		var named := []
		for entry in fresh.slice(0, min(TOP_FRESH_PER_FRAME, fresh.size()) - 1):
			named.append("%s %.1f" % [entry[0], entry[1] / 1000.0])
		print(
			"  info:   at %.2f s: mirror %.1f ms (%s), %d fresh %s"
			% [
				frame.at / 1000.0, frame.usec / 1000.0, PoolStringArray(parts).join(", "),
				frame.fresh.size(), named
			]
		)


# Fresh puppets per scene file, the costliest single one first.
func _print_scenes(fresh: Array) -> void:
	var by_file := {}
	var total := 0
	for entry in fresh:
		var stats: Array = by_file.get(entry[0], [entry[0], 0, 0, 0])
		stats[1] += 1
		stats[2] += entry[1]
		stats[3] = max(stats[3], entry[1])
		by_file[entry[0]] = stats
		total += entry[1]
	var rows: Array = by_file.values()
	rows.sort_custom(self, "_costlier_scene")
	print(
		"  info: %d fresh puppets in %.1f ms; per scene: count, avg, max"
		% [fresh.size(), total / 1000.0]
	)
	for row in rows.slice(0, min(TOP_SCENES, rows.size()) - 1):
		print(
			"  info:   %s: %d, %.2f ms, %.2f ms"
			% [row[0], row[1], row[2] / 1000.0 / row[1], row[3] / 1000.0]
		)


func _slower(a: Dictionary, b: Dictionary) -> bool:
	return a.usec > b.usec


func _costlier(a: Array, b: Array) -> bool:
	return a[1] > b[1]


func _costlier_scene(a: Array, b: Array) -> bool:
	return a[3] > b[3]
