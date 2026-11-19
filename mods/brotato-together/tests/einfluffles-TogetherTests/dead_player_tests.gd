extends Reference
# Suite dead_player: a player's death travels as Player.dead (Snapshot.PLAYER_DEAD), not as health
# 0. A Veteran (no_cure_between_wave) who died in the last wave starts the next one alive at 0
# health; clients took that for dead and hid his model all wave.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const PF := Snapshot.PlayerField
const VETERAN := 1
const SNAPSHOTS_EACH := 10

var _t: Node
var _added_veteran = null  # the Veteran (DLC 2) put into ItemService.characters for the test


func run(test_mod: Node, together: Node):
	_t = test_mod
	_test_wire()
	yield(_test_battle(together), "completed")
	if _added_veteran != null:
		ItemService.characters.erase(_added_veteran)
	_t.coop_run(3)


func _test_wire() -> void:
	var view: Dictionary = SnapshotTests.new(_t).scenario(3, 10, 4, 3, 1, 2, 1, 1, false)
	view.players[0][PF.HEALTH] = 0
	for p in [1, 2]:
		view.players[p].resize(PF.size())
		view.players[p][PF.DEAD] = p == 1
	var parsed := Snapshot.parse(Snapshot.encode(view))
	_t._check(not parsed.empty(), "snapshot with a dead player parses")
	if parsed.empty():
		return
	_t._check(
		(
			not Snapshot.is_dead(parsed.players[0])
			and parsed.players[0][PF.HEALTH] == 0
			and Snapshot.is_dead(parsed.players[1])
			and not Snapshot.is_dead(parsed.players[2])
		),
		"dead flag survives; 0 health alone is not dead"
	)
	var unknown := Snapshot.encode(view)
	unknown[11] |= 128  # player 0's flags: u32 battle id, u32 t, u16 wave time, u8 count
	_t._check(Snapshot.parse(unknown).empty(), "unknown player flag rejected")


# Player 1 is a Veteran who died in wave 2, as the game left his run: current_health 0 (from
# main._on_player_health_updated), max_health_end_of_wave set by RunData.on_wave_end.
func _veteran_run() -> void:
	_t.coop_run(3)
	var veteran = _t._find_by_id(ItemService.characters, "character_veteran")
	if veteran == null:  # DLC 2's: the client's run state finds characters there
		veteran = load("res://items/characters/veteran/veteran_data.tres")
		ItemService.characters.append(veteran)
		_added_veteran = veteran
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(2)
	RunData.add_character(ItemService.characters[0], 0)
	RunData.add_character(veteran, VETERAN)
	for i in 2:
		RunData.add_weapon(_t._find_by_id(ItemService.weapons, "weapon_pistol_1"), i)
	RunData.current_wave = 3
	var data = RunData.players_data[VETERAN]
	data.current_health = 0
	data.max_health_end_of_wave = RunData.get_player_max_health(VETERAN)


func _test_battle(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var tree: SceneTree = _t.get_tree()
	host.set_process(false)
	_veteran_run()
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main: Node = tree.current_scene
	host._start_battle(main)
	var veteran: Node = main.get("_players")[VETERAN]
	_t._check(
		RunData.get_player_effect(Keys.no_cure_between_wave_hash, VETERAN) > 0,
		"player 1 keeps his health between waves"
	)
	_t._check(
		veteran.current_stats.health == 0 and not veteran.dead,
		"host: the Veteran starts the wave alive at 0 health (%d)" % veteran.current_stats.health
	)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	yield(_record(host, recorded), "completed")
	_t._check(not veteran.dead, "host: nothing hit the Veteran while recording")
	var alive_count := recorded.size()
	veteran.die()
	yield(_record(host, recorded), "completed")
	var types := {}
	for path in host._types:
		types[host._types[path]] = path
	start.types = types
	host._end_battle()

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var puppet: Node = client._main.get("_players")[VETERAN]
	var replay_start := OS.get_ticks_msec()
	for k in recorded.size():
		if k == alive_count:
			yield(tree.create_timer(0.3), "timeout")
			_t._check(
				(
					not puppet.dead
					and puppet._legs.visible
					and puppet._weapons_container.visible
					and puppet.current_stats.health == 0
				),
				"client: the Veteran at 0 health is shown alive"
			)
		var snap := SnapshotTests.retimed(recorded[k], recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(tree, "idle_frame")
		client._on_snapshot(snap)
	yield(tree.create_timer(0.3), "timeout")
	_t._check(
		puppet.dead and not puppet._weapons_container.visible,
		"client: the Veteran shown dead once he dies on the host"
	)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


func _record(host: Node, recorded: Array):
	for _i in SNAPSHOTS_EACH:
		yield(_t.get_tree().create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
