extends Reference
# Damage meter in real waves (sync/damage_meter.gd, sync/damage_ledger.gd): the total against the
# health the enemies lost with items whose counters overlap the weapons', a hit on an enemy the
# game removed, a crowded wave, the wave's last measurement before the end of wave panels, and the
# run stats over waves, retries and new runs.

const DamageLedger := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/damage_ledger.gd"
)
const DamageViews := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/damage_views.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const PISTOL := "weapon_pistol_1"
const ENEMY := "res://entities/units/enemies/crash_zone/basic/baby_alien/baby_alien.tscn"
const BATTLE_MSEC := 4000
const SPAWN_MSEC := 3000  # then the last ones are fought down
const CROWD := 350  # enemies in the crowded wave
const STALL_MSEC := 60  # added to every frame of it: a machine that cannot keep up

var _t: Node
var _lost := 0  # health the units that are gone had lost
var _kills := 0  # by player 0
var _taken := 0  # by the players
var _biggest := 0  # the biggest number player 0's hits showed above a unit
var _corpses := {}  # a unit gone without a kill -> the health it had left


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	var meter: Node = together.damage_meter
	_test_ledger()
	yield(_test_battle(meter, "giant belt, all crits", ["item_giant_belt"], 100, 120, 0), "completed")
	var burn := ["item_scared_sausage", "item_scared_sausage", "item_scared_sausage"]
	burn.append("item_greek_fire")
	yield(_test_battle(meter, "scared sausage x3, greek fire", burn, 0, 120, 0), "completed")
	yield(_test_battle(meter, "overkill, +2000% damage", [], 0, 0, 2000), "completed")
	yield(_test_corpse_hit(meter), "completed")
	yield(_test_crowded_wave(meter), "completed")
	yield(_test_waves(meter), "completed")
	yield(_test_retry(meter), "completed")
	yield(_test_new_run(meter), "completed")
	meter.clear_state(StateStream.DAMAGE)


static func _number(value: int) -> String:
	return Text.get_formatted_number(value)


static func _wave(sources: Dictionary, total: int, hit: Array, kills: int, taken: int) -> Array:
	return [{"sources": sources, "total": total, "hit": hit, "kills": kills, "taken": taken}]


func _test_ledger() -> void:
	var ledger := DamageLedger.new()
	ledger.start_wave(1)
	var first := {"weapon_pistol": [PISTOL, 2, 100]}
	ledger.hold(1, 20.0, _wave(first, 100, [60, PISTOL], 3, 10))
	var sent: Dictionary = ledger.wire(10)
	_t._check(
		sent.waves == 1 and sent.players == [[100, [[PISTOL, 2, 100]], [60, PISTOL], 3, 10]],
		"a held wave is on the board's run before it counts %s" % [sent]
	)
	ledger.commit()
	ledger.start_wave(2)
	var second := {"weapon_pistol": ["weapon_pistol_2", 1, 50], "item_x": ["item_x", 0, 30]}
	ledger.hold(2, 30.0, _wave(second, 80, [70, "weapon_pistol_2"], 4, 5))
	ledger.commit()
	sent = ledger.wire(10)
	var expected := [180, [["weapon_pistol_2", 1, 150], ["item_x", 0, 30]], [70, "weapon_pistol_2"]]
	_t._check(
		sent.waves == 2 and sent.time == 50.0 and sent.players == [expected + [7, 15]],
		"two waves sum up, a weapon's tiers in one row under the latest %s" % [sent]
	)
	ledger.start_wave(3)
	ledger.hold(3, 10.0, _wave({}, 999, [999, ""], 9, 9))
	ledger.start_wave(3)  # the retry
	sent = ledger.wire(10)
	_t._check(sent.waves == 2 and sent.players[0][0] == 180, "a retried wave's held part is gone")
	ledger.start_wave(1)
	_t._check(ledger.is_empty() and ledger.wire(10).waves == 0, "a battle at wave 1: a new run")


# A kill took all of the unit's health; one the game removed (its cap on enemies) or a tree's last
# hit had lost what it had lost, and loses what hits on it take after (see _settle_corpses).
func _on_unit_died(unit, args) -> void:
	var health: int = unit.max_stats.health
	if args.killed_by_player_index >= 0:
		_lost += health
		if args.killed_by_player_index == 0 and unit.get("enemy_id") != null:
			_kills += 1
	else:
		var left := int(clamp(unit.current_stats.health, 0, health))
		_lost += health - left
		_corpses[unit] = left


# What the units gone without a kill lost since: a bullet that entered one in the physics step
# the game removed it in (Unit.hurt_area_entered_deferred checks _pending_die, not dead), a burn.
# Until the unit is used again, after its death animation.
func _settle_corpses() -> void:
	for unit in _corpses.keys():
		if not unit.dead:
			_corpses.erase(unit)
			continue
		var left := int(clamp(unit.current_stats.health, 0, unit.max_stats.health))
		_lost += _corpses[unit] - left
		_corpses[unit] = left


func _on_unit_spawned(unit) -> void:
	if not unit.is_connected("died", self, "_on_unit_died"):
		unit.connect("died", self, "_on_unit_died")
		unit.connect("took_damage", self, "_on_unit_hit")


# What FloatingTextManager._on_unit_took_damage shows: the value, unless the hit is hidden or a
# one-shot that is no crit ("ONE_SHOT").
func _on_unit_hit(_unit, value: int, _kb, crit, _dodge, _protected, _armor, args, _type, one):
	if args.from_player_index != 0 or args.hide_feedback or (one and not crit):
		return
	_biggest = int(max(_biggest, value))


func _on_player_hurt(_unit, value: int, _kb, _crit, dodge, protected, _armor, _args, _type, _one):
	if value > 0 and not dodge and not protected:
		_taken += value


# Player 0 with six pistols and the items fights baby aliens for a few seconds: the meter's total
# is the health they lost, though the items' counters hold damage the weapons' hold too.
func _test_battle(meter: Node, title: String, items: Array, crit: int, health: int, damage: int):
	_t.coop_run(3)
	var pistol = _t._find_by_id(ItemService.weapons, PISTOL)
	while RunData.get_player_weapons(0).size() < 6:
		RunData.add_weapon(pistol, 0)
	for id in items:
		RunData.add_item(_t._find_by_id(ItemService.items, id), 0)
	RunData.add_stat(Keys.stat_attack_speed_hash, 300, 0)
	RunData.add_stat(Keys.stat_crit_chance_hash, crit, 0)
	RunData.add_stat(Keys.stat_percent_damage_hash, damage, 0)
	for p in 2:
		RunData.add_stat(Keys.stat_max_hp_hash, 500, p)
	_t.get_tree().change_scene("res://main.tscn")
	# One frame: the battle is the current scene, and the test watches its units from the same frame
	# as the meter, before any hit.
	yield(_t.get_tree(), "idle_frame")
	var main := _t.get_tree().current_scene
	var spawner = main.get("_entity_spawner")
	var players: Array = main.get("_players")
	# Only the test's enemies: the wave's own include loot aliens, which leave the map without
	# dying (despawn), so the health they lost would not be seen here.
	var waves = main.get("_wave_manager")
	var group_signal := "group_spawn_timing_reached"
	if waves.is_connected(group_signal, spawner, "on_group_spawn_timing_reached"):
		waves.disconnect(group_signal, spawner, "on_group_spawn_timing_reached")
	_lost = 0
	_kills = 0
	_taken = 0
	_biggest = 0
	_corpses = {}
	for signal_name in ["enemy_respawned", "neutral_respawned"]:
		spawner.connect(signal_name, self, "_on_unit_spawned")
	for unit in spawner.enemies + spawner.neutrals:  # the wave's own, from its first frames
		_on_unit_spawned(unit)
	for player in players:
		player.connect("took_damage", self, "_on_player_hurt")
	var started := OS.get_ticks_msec()
	var next_spawn := 0
	var max_health := 0
	while OS.get_ticks_msec() - started < BATTLE_MSEC:
		yield(_t.get_tree(), "idle_frame")
		var now := OS.get_ticks_msec() - started
		_settle_corpses()
		for player in players:
			player.current_stats.health = player.max_stats.health
		if now >= next_spawn and now < SPAWN_MSEC and spawner.enemies.size() < 120:
			next_spawn = now + 300
			for k in 20:
				var at: Vector2 = players[0].global_position + Vector2(220, 0).rotated(k * 0.7)
				var unit = _t._spawn_on_host(spawner, ENEMY, EntityType.ENEMY, at)
				if unit != null and health > 0:
					unit.max_stats.health = health
					unit.current_stats.health = health
				if unit != null:
					max_health = int(max(max_health, unit.max_stats.health))
	_settle_corpses()
	var lost := _lost
	for unit in spawner.enemies + spawner.neutrals:
		if not unit.dead:
			lost += int(unit.max_stats.health - unit.current_stats.health)
	meter.measure(true)
	var entry: Array = meter.board.players[0]
	var team := 0  # a burn without its source picks a random player
	for player_entry in meter.board.players:
		team += player_entry[0]
	var counters := 0
	for source in entry[1]:
		counters += source[2]
	print(
		"  info: %s: total %d, health lost %d, the sources' counters %d, %d kills, biggest hit %s"
		% [title, team, lost, counters, _kills, meter.board.hits[0]]
	)
	_t._check(_kills > 0 and team == lost, "%s: the totals are the health lost" % title)
	var hit: Array = meter.board.hits[0]
	_t._check(
		hit[0] > 0 and hit[0] == _biggest and hit[1] == PISTOL,
		"%s: the biggest hit is the biggest number shown (%d) %s" % [title, _biggest, hit]
	)
	if damage > 0:
		_t._check(
			hit[0] > max_health,
			"%s: with overkill above an enemy's health (%d) %s" % [title, max_health, hit]
		)
	var line: String = meter.wave_line()
	print("  info: %s" % line)
	var head := "total %s, health lost %s (by no player 0, after death 0, hidden 0); p0 %s (rows "
	head = head % [_number(team), _number(lost), _number(entry[0])]
	var tail := "biggest hit %s %s, %d kills)" % [_number(hit[0]), PISTOL, _kills]
	_t._check(
		head in line and tail in line,
		"%s: the wave's log line: totals, health lost, biggest hit (%s)" % [title, line]
	)
	var kills: int = meter._kills[0] if meter._kills.size() > 0 else 0
	var taken := 0
	for value in meter._taken:
		taken += value
	_t._check(
		kills == _kills and taken == _taken,
		"%s: kills %d (%d), damage taken %d (%d)" % [title, kills, _kills, taken, _taken]
	)
	if "item_giant_belt" in items:
		var belt := []
		for source in entry[1]:
			if source[0] == "item_giant_belt":
				belt = source
		_t._check(
			not belt.empty() and counters > entry[0],
			"%s: the belt keeps its row, though the weapons' rows hold its bonus too" % title
		)
	for player in players:
		player.disconnect("took_damage", self, "_on_player_hurt")


# The game's cap on enemies removes some in its _physics_process (EntitySpawner
# .on_group_spawn_timing_reached: die() without a hit), between the physics step that saw a
# bullet enter one of them and the deferred hit (Unit.hurt_area_entered_deferred, which checks
# _pending_die but not dead). That hit takes what the removed enemy had left, and the weapon's
# counter counts it. The meter counts it too, so its total stays the health the hits took and the
# weapon's row no more than it.
func _test_corpse_hit(meter: Node):
	_t.coop_run(3)
	var main: Node = yield(_enter_battle(3), "completed")
	var players: Array = main.get("_players")
	var spawner = main.get("_entity_spawner")
	var at: Vector2 = players[0].global_position + Vector2(900, 0)
	var unit = _t._spawn_on_host(spawner, ENEMY, EntityType.ENEMY, at)
	unit.max_stats.health = 50
	unit.current_stats.health = 50
	var weapon = players[0].current_weapons[0]
	var hitbox = weapon._hitbox
	hitbox.crit_chance = 0.0
	hitbox.damage = 30
	var data: WeaponData = RunData.get_player_weapons(0)[weapon.weapon_pos]
	var counted := data.dmg_dealt_last_wave
	var dealt: int = meter._dealt[0] if meter._dealt.size() > 0 else 0
	var lost: int = meter._lost
	var kills: int = meter._kills[0] if meter._kills.size() > 0 else 0
	unit.hurt_area_entered_deferred(hitbox)  # alive
	var left: int = unit.current_stats.health
	unit.can_drop_loot = false
	unit.die()  # the cap's removal
	hitbox.ignored_objects.clear()
	unit.hurt_area_entered_deferred(hitbox)  # the bullet that was on its way
	counted = data.dmg_dealt_last_wave - counted
	dealt = meter._dealt[0] - dealt
	_t._check(
		left > 0 and unit.current_stats.health == 0 and counted == 50,
		"a removed enemy's last hit: the game counts what it had left (%d of 50)" % counted
	)
	_t._check(
		dealt == 50 and meter._lost - lost == 50 and meter._kills[0] == kills,
		"the meter counts it too, no kill (%d, %d)" % [dealt, meter._lost - lost]
	)
	meter.measure()
	var entry: Array = meter.board.players[0]
	_t._check(
		entry[0] == meter._dealt[0] and entry[1][0][2] <= entry[0],
		"the total is the health the hits took, the weapon's row no more %s" % [entry]
	)
	yield(_t.get_tree(), "idle_frame")


# A crowded wave on a machine that cannot keep up: the meter's total is the health the units lost,
# the wave's own and those the game removed (its cap on enemies) included.
func _test_crowded_wave(meter: Node):
	_t.coop_run(3)
	var pistol = _t._find_by_id(ItemService.weapons, PISTOL)
	for p in 2:
		while RunData.get_player_weapons(p).size() < 6:
			RunData.add_weapon(pistol, p)
		RunData.add_stat(Keys.stat_attack_speed_hash, 400, p)
		RunData.add_stat(Keys.stat_max_hp_hash, 500, p)
	_t.get_tree().change_scene("res://main.tscn")
	# One frame: the test watches the units from the same frame as the meter.
	yield(_t.get_tree(), "idle_frame")
	var main := _t.get_tree().current_scene
	var spawner = main.get("_entity_spawner")
	var players: Array = main.get("_players")
	_lost = 0
	_kills = 0
	_corpses = {}
	for signal_name in ["enemy_respawned", "neutral_respawned"]:
		spawner.connect(signal_name, self, "_on_unit_spawned")
	for unit in spawner.enemies + spawner.neutrals:
		_on_unit_spawned(unit)
	var totals := []
	var t0 := OS.get_ticks_msec()
	var next_spawn := 0
	var frames := 0
	while OS.get_ticks_msec() - t0 < 5000:
		yield(_t.get_tree(), "idle_frame")
		OS.delay_msec(STALL_MSEC)
		frames += 1
		var now := OS.get_ticks_msec() - t0
		_settle_corpses()
		for player in players:
			player.current_stats.health = player.max_stats.health
		if now >= next_spawn and spawner.enemies.size() < CROWD:
			next_spawn = now + 200
			for k in 60:
				var at: Vector2 = players[k % 2].global_position + Vector2(260, 0).rotated(k * 0.7)
				_t._spawn_on_host(spawner, ENEMY, EntityType.ENEMY, at)
		if now >= 1000 * (totals.size() + 1):
			totals.append(_total(meter))
	_settle_corpses()
	var lost := _lost
	var alive := 0
	for unit in spawner.enemies + spawner.neutrals:
		if not unit.dead:
			alive += 1
			lost += int(unit.max_stats.health - unit.current_stats.health)
	var total := _total(meter)
	# At a few frames a second, a second can pass without a hit: never less, and more at the end.
	var rising: bool = totals.size() >= 3 and totals[-1] > totals[0]
	for i in range(1, totals.size()):
		rising = rising and totals[i] >= totals[i - 1]
	print(
		"  info: crowded wave: %d frames in 5 s, %d enemies alive, %d kills, meter per second %s"
		% [frames, alive, _kills, totals]
	)
	_t._check(rising, "the meter counts on through a crowded wave %s" % [totals])
	_t._check(_kills > 0 and total == lost, "to the point: %d dealt, %d health lost" % [total, lost])
	_t._check(
		meter._lost == lost and meter._unowned == 0,
		"the wave's log line has it too: %d health lost (%d after death)"
		% [meter._lost, meter._after_death]
	)
	var hits: Array = meter.board.hits
	_t._check(
		hits.size() == 2 and hits[0][0] > 0 and hits[0][1] == PISTOL and hits[1][1] == PISTOL,
		"the biggest hit of a real wave, with the weapon that dealt it %s" % [hits]
	)
	_t._check(meter.board.time > 0.0, "and the wave's time (%.1f s)" % meter.board.time)


func _total(meter: Node) -> int:
	meter.measure()
	var total := 0
	for entry in meter.board.players:
		total += entry[0]
	return total


func _enter_battle(wave: int):
	RunData.current_wave = wave
	_t.get_tree().change_scene("res://main.tscn")
	for _i in 3:
		yield(_t.get_tree(), "idle_frame")
	return _t.get_tree().current_scene


# A scene of that path other than `old`.
func _wait_for_scene(path: String, old: Node = null):
	for _i in 30:
		yield(_t.get_tree(), "idle_frame")
		var scene := _t.get_tree().current_scene
		if scene != null and scene != old and scene.filename == path:
			break
	for _i in 2:
		yield(_t.get_tree(), "idle_frame")
	return _t.get_tree().current_scene


static func _end_wave(main: Node) -> void:
	main.get("_end_wave_timer").emit_signal("timeout")


# A hit the meter saw, and the weapons' counters to go with it: my_id -> amount per weapon.
static func _deal(meter: Node, amounts: Dictionary) -> void:
	var total := 0
	var used := {}
	for weapon in RunData.get_player_weapons(0):
		var mine: Array = amounts.get(weapon.my_id, [])
		var k: int = used.get(weapon.my_id, 0)
		weapon.dmg_dealt_last_wave = mine[k] if k < mine.size() else 0
		total += weapon.dmg_dealt_last_wave
		used[weapon.my_id] = k + 1
	var args := TakeDamageArgs.new(0)
	meter.on_hit(null, total, Vector2.ZERO, false, false, false, false, args, 0, false)


static func _weapons(my_id: String) -> Array:
	var found := []
	for weapon in RunData.get_player_weapons(0):
		if weapon.my_id == my_id:
			found.append(weapon)
	return found


# main -> shop -> main -> end of run, weapons combined and recycled after the wave's end: the run's
# total is what the waves' totals sum to.
func _test_waves(meter: Node):
	meter.ledger.reset()  # what suites before left (a run that ended without a menu after it)
	_t.coop_run(3)
	var pistol = _t._find_by_id(ItemService.weapons, PISTOL)
	RunData.add_weapon(pistol, 0)
	RunData.add_weapon(_t._find_by_id(ItemService.weapons, "weapon_knife_1"), 0)
	var main: Node = yield(_enter_battle(3), "completed")
	_deal(meter, {PISTOL: [600, 300], "weapon_knife_1": [100]})
	_end_wave(main)
	var pistols := _weapons(PISTOL)
	RunData.combine_weapon(pistols[0], pistols[1], 0)  # under the crate panel
	RunData.remove_weapon(_weapons("weapon_knife_1")[0], 0)  # recycled
	var shop: Node = yield(_wait_for_scene(RunData.get_shop_scene_path()), "completed")
	var first: int = meter.board.players[0][0]
	_t._check(
		shop.filename == RunData.get_shop_scene_path() and first == 1000,
		"the wave's board was taken before combining and recycling (%d)" % first
	)
	_t._check(
		meter.board.run.waves == 1 and meter.ledger.waves == 1 and meter.ledger.last_wave == 3,
		"in the shop the wave counts for the run"
	)
	main = yield(_enter_battle(4), "completed")
	_t._check(not meter.board.has("run"), "the next wave's board: no run")
	_deal(meter, {"weapon_pistol_2": [500]})  # the combined pistol
	main.set("_is_run_won", true)
	_end_wave(main)
	var end_path: String = RunData.get_end_run_scene_path()
	var end_run: Node = yield(_wait_for_scene(end_path), "completed")
	var second: int = meter.board.players[0][0]
	var run: Dictionary = meter.board.get("run", {})
	var players: Array = run.get("players", [[0, []]])
	_t._check(
		end_run.filename == end_path and run.get("waves") == 2 and players[0][0] == first + second,
		"at the end of the run: two waves, %d + %d %s" % [first, second, run]
	)
	_t._check(
		players[0][1].size() == 2 and players[0][1][0] == ["weapon_pistol_2", 1, 1400],
		"the pistol's tiers are one row, the knife keeps its own %s" % [players[0][1]]
	)
	var container = end_run.player_containers[0]
	var list: Node = container.carousel.get_node("%Content").get_node(DamageViews.PAGE_NAME)
	var head: Node = list.get_child(0).get_node("Head")
	_t._check(
		head.get_node("Wave").text == Text.text(DamageViews.RUN_TITLE, ["2"])
		and head.get_node("Stats/Total").text == "1,500",
		"the end of run's page shows the run (%s)" % head.get_node("Wave").text
	)


# A failed wave that is tried again counts once, with the try that ended the run.
func _test_retry(meter: Node):
	_t.coop_run(2)
	var main: Node = yield(_enter_battle(2), "completed")
	_t._check(meter.ledger.is_empty(), "a battle before the last counted wave: a new run")
	_deal(meter, {PISTOL: [600]})
	main.set("_is_wave_failed", true)
	_end_wave(main)
	_t._check(
		meter.board.run.waves == 1 and meter.board.run.players[0][0] == 600,
		"the failed wave's board, with the run as it would end"
	)
	main.get("_retry_wave")._on_ConfirmButton_pressed()
	main = yield(_wait_for_scene("res://main.tscn", main), "completed")
	_t._check(meter.ledger.is_empty(), "retried: the failed try does not count")
	_deal(meter, {PISTOL: [400]})
	main.set("_is_wave_failed", true)
	_end_wave(main)
	main.get("_retry_wave")._on_CancelButton_pressed()
	yield(_wait_for_scene(RunData.get_end_run_scene_path()), "completed")
	var run: Dictionary = meter.board.get("run", {})
	_t._check(
		run.get("waves") == 1 and run.players[0][0] == 400 and meter.ledger.last_wave == 2,
		"given up: the run ends with the last try %s" % [run]
	)


# A new run starts the ledger anew; a menu outside a run clears the board.
func _test_new_run(meter: Node):
	_t.coop_run(0)
	yield(_enter_battle(1), "completed")
	_t._check(meter.ledger.is_empty(), "a battle at wave 1 after the end of a run: a new run")
	_t.get_tree().change_scene(MenuData.character_selection_scene)
	for _i in 3:
		yield(_t.get_tree(), "idle_frame")
	_t._check(
		meter.board.empty() and meter.ledger.is_empty(),
		"outside a run: no board (a run resumed later starts without the last one's)"
	)
