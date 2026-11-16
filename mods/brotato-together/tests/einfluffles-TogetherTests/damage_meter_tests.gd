extends Reference
# Damage meter (sync/damage_meter.gd, ui/damage_views.gd): what a player's weapons and items
# dealt, read off the game's counters; the board as the state stream carries it; the row in the
# wave's HUD; the button and board in the co-op shop, up while a player's cursor rests on the
# button. Driven from mod_main.gd (two-player co-op run); checks go through its _check.

const DamageMeter := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/damage_meter.gd")
const DamageViews := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/damage_views.gd")
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const PISTOL := "weapon_pistol_1"
const CROWD := 350  # enemies in the crowded wave
const STALL_MSEC := 60  # added to every frame of it: a machine that cannot keep up

var _t: Node
var _changes := 0
var _killed := 0  # health the enemies that are gone had lost, in the crowded wave
var _kills := 0


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	var meter: Node = together.damage_meter
	meter.connect("changed", self, "_on_changed")
	var item = _test_measure()
	_test_board(meter)
	yield(_test_hud(meter, item), "completed")
	yield(_test_shop(item), "completed")
	yield(_test_crowded_wave(meter), "completed")
	meter.disconnect("changed", self, "_on_changed")
	meter.clear_state(StateStream.DAMAGE)


func _on_changed() -> void:
	_changes += 1


# Two pistols of player 0 are one source; an item's damage is what its counter gained since the
# wave started; a counter that is no damage is left out. Returns the damage item.
func _test_measure():
	RunData.add_weapon(_t._find_by_id(ItemService.weapons, PISTOL), 0)
	var pistols: Array = RunData.get_player_weapons(0)
	pistols[0].dmg_dealt_last_wave = 120
	pistols[1].dmg_dealt_last_wave = 30
	var mine := DamageMeter.measure_player(0, {})
	_t._check(mine == [150, [[PISTOL, 2, 150]]], "equal weapons are one source %s" % [mine])
	var item = null
	var other = null
	for data in ItemService.items:
		if item == null and data.tracking_text == "DAMAGE_DEALT":
			item = data
		elif other == null and data.tracking_text != "":
			other = data if not data.tracking_text in DamageMeter.DAMAGE_TEXTS else null
	_t._check(item != null and other != null, "the game has items that count damage, and others")
	if item == null or other == null:
		return item
	RunData.add_item(item, 1)
	RunData.add_item(other, 1)
	for data in [item, other]:
		if typeof(RunData.tracked_item_effects[1].get(data.my_id_hash)) != TYPE_INT:
			RunData.tracked_item_effects[1][data.my_id_hash] = 0
	RunData.add_tracked_value(1, item.my_id_hash, 500)  # earlier waves
	var baseline: Dictionary = RunData.tracked_item_effects[1].duplicate(true)
	RunData.add_tracked_value(1, item.my_id_hash, 77)
	RunData.add_tracked_value(1, other.my_id_hash, 9)
	var theirs := DamageMeter.measure_player(1, baseline)
	_t._check(
		theirs[0] == 77 and theirs[1] == [[item.my_id, 1, 77]],
		"an item's damage is what its counter gained this wave %s (%s)" % [theirs, item.my_id]
	)
	return item


func _test_board(meter: Node) -> void:
	meter.clear_state(StateStream.DAMAGE)
	_t._check(meter.state_key(StateStream.DAMAGE) == "", "no board, no state")
	_changes = 0
	meter.measure()
	var key: String = meter.state_key(StateStream.DAMAGE)
	var sent = bytes2var(var2bytes(meter.state_body(StateStream.DAMAGE)), false)
	_t._check(
		key != "" and _changes == 1 and sent.wave == RunData.current_wave and sent.players.size() == 2,
		"measuring makes the board the state carries %s" % [sent]
	)
	meter.measure()
	_t._check(meter.state_key(StateStream.DAMAGE) == key and _changes == 1, "unchanged: nothing sent")
	_t._check(var2str(DamageMeter.clean(sent)) == var2str(sent), "the board passes the client's check")
	var bad := {
		"too many players": {"wave": 1, "players": [[0, []], [0, []], [0, []], [0, []], [0, []]]},
		"a negative total": {"wave": 1, "players": [[-5, []]]},
		"a source without a number": {"wave": 1, "players": [[5, [["weapon_x", 1, "5"]]]]},
		"no wave": {"players": []},
	}
	for label in bad:
		_t._check(DamageMeter.clean(bad[label]).empty(), "malformed board rejected: %s" % label)
	var received := {"wave": 4, "players": [[9, [[PISTOL, 1, 9]]], [0, []]]}
	meter.apply_state(StateStream.DAMAGE, received, 1)
	_t._check(
		var2str(meter.board) == var2str(received) and _changes == 2,
		"a client shows the host's board"
	)


# The row under each player's life bar.
func _test_hud(meter: Node, item):
	_t.get_tree().change_scene("res://main.tscn")
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var main := _t.get_tree().current_scene
	var rows := []
	for p in 2:
		var path := "UI/HUD/LifeContainerP%d/%s" % [p + 1, DamageViews.ROW_NAME]
		rows.append(main.get_node_or_null(path))
	_t._check(not (null in rows), "each player's life bar has a damage row")
	if null in rows:
		return
	_t._check(not rows[0].visible, "hidden until something dealt damage")
	var pistols: Array = RunData.get_player_weapons(0)
	pistols[0].dmg_dealt_last_wave = 1200
	pistols[1].dmg_dealt_last_wave = 34
	if item != null:
		RunData.add_tracked_value(1, item.my_id_hash, 77)
	meter.measure()
	var icon: Texture = meter.data_of(PISTOL).icon
	_t._check(
		rows[0].visible and rows[0].get_child(1).text == "1,234" and rows[0].get_child(2).texture == icon,
		"the row shows the total and the strongest source (%s)" % rows[0].get_child(1).text
	)
	_t._check(
		rows[0].get_child(3).text == "1,234" and not rows[0].get_child(4).visible,
		"with its number, and no second source where there is none"
	)
	_t._check(
		item == null or (rows[1].visible and rows[1].get_child(1).text == "77"),
		"the other player's row shows that player's own"
	)


# The button next to reroll and the board over the shop items.
func _test_shop(item):
	_t.get_tree().change_scene(RunData.get_shop_scene_path())
	for _i in 4:
		yield(_t.get_tree(), "idle_frame")
	var shop := _t.get_tree().current_scene
	var buttons := []
	var boards := []
	for p in 2:
		var reroll: Control = shop._get_reroll_button(p)
		var button = reroll.get_parent().get_node_or_null(DamageViews.BUTTON_NAME)
		buttons.append(button)
		var slots_panel: Node = shop._get_shop_items_container(p).get_parent()
		boards.append(slots_panel.get_node_or_null(DamageViews.BOARD_NAME))
		if button != null:
			_t._check(
				reroll.get_node_or_null(reroll.focus_neighbour_right) == button
				and button.get_index() == reroll.get_index() + 1,
				"player %d: the button sits next to reroll and is reached from it" % p
			)
	_t._check(not (null in buttons) and not (null in boards), "each shop panel has button and board")
	if null in buttons or null in boards:
		return
	_t._check(not boards[0].visible and not boards[1].visible, "no board is up by itself")
	_t._check(_t.get_tree().paused == false, "and nothing is paused")
	var emulator = Utils.get_focus_emulator(1, shop)
	var before = emulator.focused_control
	emulator.focused_control = buttons[1]
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	_t._check(boards[1].visible and not boards[0].visible, "a cursor on the button: that board is up")
	_t._check(not _t.get_tree().paused, "the shop runs on meanwhile")
	var slots: Control = shop._get_shop_items_container(1)
	_t._check(
		boards[1].get_global_rect().encloses(slots.get_global_rect().grow(-2)),
		"over that player's shop items %s" % [boards[1].get_global_rect()]
	)
	var list: Node = boards[0].get_child(0)
	var title: String = list.get_child(0).text
	_t._check("1,234" in title, "the board's title is the total (%s)" % title)
	var row: Node = list.get_child(1)
	_t._check(
		row.visible and row.get_child(2).text == "1,234  100%" and not list.get_child(2).visible,
		"a row per source with number and share (%s)" % row.get_child(2).text
	)
	if item != null:
		var theirs: Node = boards[1].get_child(0).get_child(1)
		_t._check(theirs.visible and theirs.get_child(0).texture == item.icon, "an item's row: its icon")
	var target: Array = FocusTargets.describe(buttons[1], shop, 1)
	_t._check(
		not target.empty() and FocusTargets.resolve(target, shop, 1) == buttons[1],
		"the cursor on it is mirrored: the others see whose board is up %s" % [target]
	)
	emulator.focused_control = before
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	_t._check(not boards[1].visible, "the board goes when the cursor leaves")


# A kill took all of the enemy's health; one the game removed (its cap on enemies) had lost what
# it had lost.
func _on_enemy_died(enemy, args) -> void:
	var health: int = enemy.max_stats.health
	if args.killed_by_player_index >= 0:
		_killed += health
		_kills += 1
	else:
		_killed += health - int(clamp(enemy.current_stats.health, 0, health))


# A crowded wave on a machine that cannot keep up (350 enemies, twelve fast pistols, a few frames
# a second): the meter counts on, and its total is the health the enemies lost, to the point.
func _test_crowded_wave(meter: Node):
	_t.coop_run(3)
	var pistol = _t._find_by_id(ItemService.weapons, PISTOL)
	for p in 2:
		while RunData.get_player_weapons(p).size() < 6:
			RunData.add_weapon(pistol, p)
		RunData.add_stat(Keys.stat_attack_speed_hash, 400, p)
		RunData.add_stat(Keys.stat_max_hp_hash, 500, p)
	_t.get_tree().change_scene("res://main.tscn")
	for _i in 3:
		yield(_t.get_tree(), "idle_frame")
	var main := _t.get_tree().current_scene
	var spawner = main.get("_entity_spawner")
	var players: Array = main.get("_players")
	var enemy := "res://entities/units/enemies/crash_zone/basic/baby_alien/baby_alien.tscn"
	_killed = 0
	_kills = 0
	var totals := []
	var t0 := OS.get_ticks_msec()
	var next_spawn := 0
	var frames := 0
	while OS.get_ticks_msec() - t0 < 5000:
		yield(_t.get_tree(), "idle_frame")
		OS.delay_msec(STALL_MSEC)
		frames += 1
		var now := OS.get_ticks_msec() - t0
		for player in players:
			player.current_stats.health = player.max_stats.health
		if now >= next_spawn and spawner.enemies.size() < CROWD:
			next_spawn = now + 200
			for k in 60:
				var at: Vector2 = players[k % 2].global_position + Vector2(260, 0).rotated(k * 0.7)
				var unit = _t._spawn_on_host(spawner, enemy, EntityType.ENEMY, at)
				if unit != null and not unit.is_connected("died", self, "_on_enemy_died"):
					unit.connect("died", self, "_on_enemy_died")
		if now >= 1000 * (totals.size() + 1):
			totals.append(_total(meter))
	var lost := _killed
	var alive := 0
	for unit in spawner.enemies:
		if not unit.dead:
			alive += 1
			lost += int(unit.max_stats.health - unit.current_stats.health)
	var total := _total(meter)
	var rising := totals.size() >= 3
	for i in range(1, totals.size()):
		rising = rising and totals[i] > totals[i - 1]
	print(
		"  info: crowded wave: %d frames in 5 s, %d enemies alive, %d kills, meter per second %s"
		% [frames, alive, _kills, totals]
	)
	_t._check(rising, "the meter counts on through a crowded wave %s" % [totals])
	_t._check(_kills > 0 and total == lost, "to the point: %d dealt, %d health lost" % [total, lost])


func _total(meter: Node) -> int:
	meter.measure()
	var total := 0
	for entry in meter.board.players:
		total += entry[0]
	return total
