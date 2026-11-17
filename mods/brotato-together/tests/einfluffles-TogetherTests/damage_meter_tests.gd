extends Reference
# Damage meter (sync/damage_meter.gd, ui/damage_views.gd): what a player's weapons and items
# dealt, read off the game's counters; the biggest hit and the wave's time; the short numbers;
# the board as the state stream carries it; the row in the wave's HUD; the damage page in the
# co-op shop's and end of run's carousels, the third stats tab in the solo shop and end of run,
# and the switch. Driven from mod_main.gd (two-player co-op run); checks go through its _check.

const DamageMeter := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/damage_meter.gd")
const DamageViews := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/damage_views.gd")
const ShopIntents := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_intents.gd"
)
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const Settings := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/settings.gd")
const MenuOptionsButton := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/extensions/ui/menu_options.gd"
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
	var item = _test_measure(meter)
	_test_short()
	_test_board(meter)
	yield(_test_hud(meter, item), "completed")
	yield(_test_shop(item), "completed")
	yield(_test_coop_end_run(), "completed")
	yield(_test_crowded_wave(meter), "completed")
	_test_cost(meter)
	yield(_test_solo_shop(meter), "completed")
	meter.disconnect("changed", self, "_on_changed")
	meter.clear_state(StateStream.DAMAGE)


func _on_changed() -> void:
	_changes += 1


# Two pistols of player 0 are one source; an item's damage is what its counter gained since the
# wave started; a counter that is no damage is left out. Returns the damage item.
func _test_measure(meter: Node):
	RunData.add_weapon(_t._find_by_id(ItemService.weapons, PISTOL), 0)
	var pistols: Array = RunData.get_player_weapons(0)
	pistols[0].dmg_dealt_last_wave = 120
	pistols[1].dmg_dealt_last_wave = 30
	var mine: Array = meter.measure_player(0, {})
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
	var theirs: Array = meter.measure_player(1, baseline)
	_t._check(
		theirs[0] == 77 and theirs[1] == [[item.my_id, 1, 77]],
		"an item's damage is what its counter gained this wave %s (%s)" % [theirs, item.my_id]
	)
	return item


# Up to 9,999 as it is, then three digits and a unit, also where rounding reaches the next one.
func _test_short() -> void:
	var cases := {
		0: "0",
		999: "999",
		9999: "9,999",
		10000: "10.0K",
		12345: "12.3K",
		99960: "100K",
		123456: "123K",
		999600: "1.00M",
		4567890: "4.57M",
		9996000: "10.0M",
		7890000000: "7.89B",
		1230000000000: "1.23T",
	}
	var wrong := []
	for number in cases:
		if DamageViews.short(number) != cases[number]:
			wrong.append("%d: %s" % [number, DamageViews.short(number)])
	_t._check(wrong.empty(), "short numbers: 9,999, 12.3K, 4.57M, 7.89B %s" % [wrong])
	_t._check(
		DamageViews.per_second(1234, 10.0) == 123 and DamageViews.per_second(50, 0.5) == -1,
		"damage per second, none before the wave ran a second"
	)


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
		"a negative time": {"wave": 1, "players": [], "time": -1.0},
		"a hit without a number": {"wave": 1, "players": [], "hits": [["weapon_x", 5]]},
		"a hit with a long id": {"wave": 1, "players": [], "hits": [[5, "x".repeat(200)]]},
	}
	for label in bad:
		_t._check(DamageMeter.clean(bad[label]).empty(), "malformed board rejected: %s" % label)
	var received := {
		"wave": 4,
		"players": [[9, [[PISTOL, 1, 9]]], [0, []]],
		"time": 12.5,
		"hits": [[7, PISTOL], [0, ""]],
	}
	meter.apply_state(StateStream.DAMAGE, received, 1)
	_t._check(
		var2str(meter.board) == var2str(received) and _changes == 2,
		"a client shows the host's board"
	)
	var older := DamageMeter.clean({"wave": 4, "players": [[9, []]]})
	_t._check(
		older.get("time") == 0.0 and older.get("hits") == [],
		"a board without time and hits (an older host's) is still one %s" % [older]
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
	var total: Label = rows[0].get_node("Main/Total")
	var detail: Node = rows[0].get_node("Detail")
	_t._check(
		rows[0].visible and total.text == "1,234" and detail.get_node("Source0Icon").texture == icon,
		"the row shows the total and the strongest source (%s)" % total.text
	)
	_t._check(
		detail.get_node("Source0").text == "1,234" and not detail.get_node("Source1").visible,
		"with its number, and no second source where there is none"
	)
	_t._check(
		not rows[0].get_node("Main/Dps").visible and not detail.get_node("Hit").visible,
		"no damage per second before the wave ran a second, no biggest hit before a hit"
	)
	_t._check(
		item == null
		or (
			rows[1].visible
			and rows[1].get_node("Main/Total").text == "77"
			and rows[1].get_node("Main/Share").text == "6%"
		),
		"the other player's row shows that player's own, with its share of the team's"
	)
	# A hit: the biggest one stays, a smaller one after it does not replace it.
	var args := TakeDamageArgs.new(0)
	meter.on_hit(null, 52345, Vector2.ZERO, true, false, false, false, args, 0, false)
	meter.on_hit(null, 900, Vector2.ZERO, false, false, false, false, args, 0, false)
	var nobody := TakeDamageArgs.new(-1)
	meter.on_hit(null, 99999, Vector2.ZERO, false, false, false, false, nobody, 0, false)
	meter._wave_time = 10.0
	meter.measure()
	_t._check(
		meter.board.hits[0] == [52345, ""] and meter.board.hits[1] == [0, ""],
		"the biggest hit per player, none for a hit that was no player's %s" % [meter.board.hits]
	)
	_t._check(
		detail.get_node("Hit").visible and detail.get_node("Hit").text == "52.3K",
		"the row shows it, short (%s)" % detail.get_node("Hit").text
	)
	var dps: Label = rows[0].get_node("Main/Dps")
	_t._check(dps.visible and dps.text == "123/s", "and the damage per second (%s)" % dps.text)


# The co-op shop: a fourth page "Damage" in each player's carousel, reached with the arrows (LB /
# RB on a gamepad), with that player's board of the wave before.
func _test_shop(item):
	_t.get_tree().change_scene(RunData.get_shop_scene_path())
	for _i in 4:
		yield(_t.get_tree(), "idle_frame")
	var shop := _t.get_tree().current_scene
	var panels := []
	for p in 2:
		var panel: Node = shop._get_coop_player_container(p)
		panels.append(panel)
		var carousel: Node = panel.carousel
		var page = carousel.get_node("%Content").get_node_or_null(DamageViews.PAGE_NAME)
		var heading = carousel.get_node("%Headings").get_node_or_null(DamageViews.HEADING_NAME)
		_t._check(
			page != null and heading != null and carousel._get_max_index() == 3
			and page.get_index() == 3 and heading.get_index() == 3,
			"player %d: the carousel has a fourth page, Damage" % p
		)
		if page == null or heading == null:
			return
		_t._check(
			carousel.index == 0 and not page.visible and heading.text == DamageViews.PAGE_TITLE,
			"player %d: the shop page shows first, the damage page waits" % p
		)
	var carousel: Node = panels[1].carousel
	for _i in 3:
		carousel._on_ArrowRight_pressed()
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var page: Control = _page(panels[1])
	_t._check(
		carousel.index == 3 and page.visible and _heading(panels[1]).visible
		and panels[0].carousel.index == 0 and not _page(panels[0]).visible,
		"three pages on (RB RB RB): player 2's damage page, player 1 still shops"
	)
	_t._check(carousel.arrow_right.disabled, "the last page: no way further right")
	_t._check(not _t.get_tree().paused, "nothing pauses")
	var cursor = Utils.get_focus_emulator(1, shop).focused_control
	_t._check(
		not carousel.are_trigger_buttons_active() or cursor == shop._get_go_button(1),
		"with a gamepad the cursor waits on Go, as on the stats pages (%s)" % [cursor]
	)
	var list: Node = _list(panels[0])
	var tiles: Node = list.get_node("Tiles")
	var title: String = tiles.get_node("Total/Caption").text
	var share: Label = tiles.get_node("Total/Line/Share")
	_t._check(
		title == Text.text("WAVE", [str(RunData.current_wave)]) and share.visible,
		"the total's caption is the wave, with the share of the team's (%s, %s)" % [title, share.text]
	)
	var values := []
	for tile in ["Total", "Dps", "Hit"]:
		values.append(tiles.get_node(tile + "/Line/Value").text)
	_t._check(
		values[0] == "1,234" and values[1] != "-" and values[2] == "52.3K",
		"tiles: the total, damage per second and the biggest hit %s" % [values]
	)
	var rows: Node = list.get_node("Sources")
	var row: Node = rows.get_child(0)
	var number := "%s %s" % [row.get_node("Amount").text, row.get_node("Share").text]
	_t._check(
		row.visible and number == "1,234 100%" and not rows.get_child(1).visible,
		"a row per source with number and share (%s)" % number
	)
	_t._check(row.get_node("Text/Bar").value == 1000, "the strongest source's bar is full")
	if item != null:
		var theirs: Node = _list(panels[1]).get_node("Sources").get_child(0)
		var item_icon: Texture = theirs.get_node("Icon").texture
		_t._check(theirs.visible and item_icon == item.icon, "player 2's page: its own item")
	# Online the page index travels like the game's own pages: a client's page on the host.
	ShopIntents.apply_focus(shop, 0, 3, [])
	_t._check(panels[0].carousel.index == 3, "a page 3 from the network shows the damage page")
	ShopIntents.apply_focus(shop, 0, 0, [])
	yield(_test_switch(shop, panels), "completed")


func _page(panel: Node) -> Control:
	return panel.carousel.get_node("%Content").get_node(DamageViews.PAGE_NAME) as Control


func _heading(panel: Node) -> Control:
	return panel.carousel.get_node("%Headings").get_node(DamageViews.HEADING_NAME) as Control


func _list(panel: Node) -> Node:
	return _page(panel).get_node(DamageViews.LIST_NAME)


# Options > Gameplay has the switch; off, the damage page cannot be reached (a player on it goes
# back to the page before), and the setting is kept.
func _test_switch(shop: Node, panels: Array):
	var meter: Node = shop.get_node(MenuOptionsButton.METER)
	var options: Node = load("res://ui/menus/pages/menu_options.tscn").instance()
	shop.add_child(options)
	var gameplay: Node = options.boss_hp_bar_button.get_parent()
	var toggle = gameplay.get_node_or_null(MenuOptionsButton.BUTTON_NAME)
	_t._check(
		toggle is CheckButton and toggle.pressed
		and toggle.get_index() == options.boss_hp_bar_button.get_index() + 1,
		"the options' Gameplay tab has the damage meter's switch, on"
	)
	if not toggle is CheckButton:
		options.free()
		return
	var carousel: Node = panels[1].carousel
	_t._check(carousel.index == 3, "player 2 is on the damage page")
	toggle.pressed = false
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	_t._check(
		not meter.shown and carousel.index == 2 and carousel._get_max_index() == 2
		and not _page(panels[1]).visible,
		"switched off: player 2 is back on the page before, the last one now"
	)
	carousel._on_ArrowRight_pressed()
	_t._check(carousel.index == 2, "and RB leads no further")
	_t._check(panels[0].carousel.index == 0, "player 1's page stays")
	ShopIntents.apply_focus(shop, 1, 3, [])
	_t._check(carousel.index == 2, "a page 3 from the network shows the page before")
	_t._check(Settings.read(DamageMeter.SETTING, true) == false, "the switch is kept in the config")
	toggle.pressed = true
	yield(_t.get_tree(), "idle_frame")
	carousel._on_ArrowRight_pressed()
	_t._check(
		meter.shown and carousel._get_max_index() == 3 and carousel.index == 3,
		"switched on again: the damage page is back"
	)
	_t._check(Settings.read(DamageMeter.SETTING, false) == true, "and so is the setting")
	options.free()


# The co-op end of run: the same page in each player's carousel, the last wave's board.
func _test_coop_end_run():
	_t.get_tree().change_scene(RunData.get_end_run_scene_path())
	for _i in 3:
		yield(_t.get_tree(), "idle_frame")
	var scene := _t.get_tree().current_scene
	var containers: Array = scene.player_containers
	var found := true
	for p in 2:
		var carousel: Node = containers[p].carousel
		found = found and carousel._get_max_index() == 3
		found = found and carousel.get_node("%Content").has_node(DamageViews.PAGE_NAME)
	_t._check(found, "the co-op end of run has the damage page for each player")
	if not found:
		return
	for _i in 3:
		containers[0].carousel._on_ArrowRight_pressed()
	yield(_t.get_tree(), "idle_frame")
	var total: String = _list(containers[0]).get_node("Tiles/Total/Line/Value").text
	_t._check(
		containers[0].carousel.index == 3 and _page(containers[0]).visible and total == "1,234",
		"three pages on: the last wave's board (%s)" % total
	)


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


# A late endless run, four players with 6 weapons and 250 items each, every counter gaining:
# what a measurement costs and what the board weighs on the wire.
func _test_cost(meter: Node) -> void:
	CoopService.connected_players.clear()
	for i in 4:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(4)
	var pool: Array = ItemService.items
	var weapons: Array = ItemService.weapons
	for p in 4:
		RunData.add_character(ItemService.characters[p], p)
		for w in 6:
			RunData.add_weapon(weapons[(p + w * 7) % weapons.size()], p)
		for i in 250:
			RunData.add_item(pool[(i * 13 + p) % pool.size()], p)
	meter._baseline = RunData.tracked_item_effects.duplicate(true)
	var calls := 20
	var started := OS.get_ticks_usec()
	for call in calls:
		for p in 4:
			for weapon in RunData.get_player_weapons(p):
				weapon.dmg_dealt_last_wave += 1000 + call
			var tracked: Dictionary = RunData.tracked_item_effects[p]
			for key in tracked:
				if typeof(tracked[key]) == TYPE_INT:
					tracked[key] += 100 + call
	var setting := (OS.get_ticks_usec() - started) / float(calls)
	started = OS.get_ticks_usec()
	for _i in calls:
		meter.measure()
	var live := (OS.get_ticks_usec() - started) / float(calls)
	var live_size := var2bytes([StateStream.DAMAGE, 1, meter.state_body(StateStream.DAMAGE)]).size()
	started = OS.get_ticks_usec()
	for _i in calls:
		meter.measure(true)
	var final := (OS.get_ticks_usec() - started) / float(calls)
	var size := var2bytes([StateStream.DAMAGE, 1, meter.state_body(StateStream.DAMAGE)]).size()
	var sources := 0
	for entry in meter.board.players:
		sources += entry[1].size()
	_t._check(live < 1500.0, "a measurement in a late run stays under 1.5 ms (%.0f usec)" % live)
	_t._check(live_size < 800, "the board of a running wave stays under 800 B (%d)" % live_size)
	print(
		(
			"  info: damage meter, late run, 4 players: %.0f usec per measurement, %d B during the"
			+ " wave; at its end %.0f usec, %d B for %d sources (setting the counters: %.0f usec)"
		)
		% [live, live_size, final, size, sources, setting]
	)


# The solo shop: a third tab in the stats panel next to Primary / Secondary, the board on it. LB /
# RB (real gamepad events) cycle through the three; the mouse reaches it too; the switch hides it.
func _test_solo_shop(meter: Node):
	CoopService.clear_coop_players()
	RunData.reset()
	RunData.add_character(ItemService.characters[0], 0)
	RunData.add_weapon(_t._find_by_id(ItemService.weapons, PISTOL), 0)
	_t.get_tree().change_scene(RunData.get_shop_scene_path())
	for _i in 4:
		yield(_t.get_tree(), "idle_frame")
	# After the battle scene before it is gone: leaving, it measured its own last word.
	meter.apply_state(StateStream.DAMAGE, {"wave": 2, "players": [[50, [[PISTOL, 1, 50]]]]}, 0)
	var shop := _t.get_tree().current_scene
	var stats: Node = shop.get_node("%StatsContainer")
	var row: Node = stats._primary_tab.get_parent()
	var tab = row.get_node_or_null("DamageTab")
	var page = stats._secondary_stats.get_parent().get_node_or_null(DamageViews.PAGE_NAME)
	_t._check(
		tab is Button and page != null and tab.get_index() == stats._secondary_tab.get_index() + 1
		and not page.visible,
		"the solo shop's stats panel has a third tab after Secondary"
	)
	if not tab is Button or page == null:
		return
	_t._check(
		stats._secondary_tab.get_node_or_null(stats._secondary_tab.focus_neighbour_right) == tab
		and tab.get_node_or_null(tab.focus_neighbour_left) == stats._secondary_tab,
		"reached from Secondary with right"
	)
	tab.emit_signal("pressed")
	_t._check(
		page.visible and not stats._primary_stats.visible and not stats._secondary_stats.visible
		and not stats._general_stats.visible,
		"pressed: the board instead of the stats"
	)
	var list: Node = page.get_node(DamageViews.LIST_NAME)
	var total: String = list.get_node("Tiles/Total/Line/Value").text
	var share: Label = list.get_node("Tiles/Total/Line/Share")
	_t._check(total == "50" and not share.visible, "with the wave's total, no share alone")
	_t._check(
		list.get_node("Tiles/Hit/Line/Value").text == "-",
		"a board without hits (an older host's): no biggest hit"
	)
	stats.update_tab(stats.Tab.PRIMARY)
	var seen := []
	for button in [JOY_R, JOY_R, JOY_R, JOY_L]:
		yield(_press_joypad(button), "completed")
		seen.append(_solo_tab(stats, page))
	_t._check(
		seen == ["secondary", "damage", "primary", "damage"],
		"RB steps Primary, Secondary, Damage and around, LB back %s" % [seen]
	)
	# Widths of buttons and gaps (texts measure 0 px headless): the row still fits the panel.
	var width: float = row.get_combined_minimum_size().x
	_t._check(width <= 360, "the three tabs fit the panel's 360 px row (%d)" % width)
	tab.grab_focus()
	meter.set_shown(false)
	yield(_t.get_tree(), "idle_frame")
	_t._check(
		not tab.visible and _solo_tab(stats, page) == "primary",
		"switched off: no tab, the open one falls back to Primary"
	)
	_t._check(stats._primary_tab.has_focus(), "the focus on the tab moves to Primary")
	_t._check(
		stats._primary_tab.rect_min_size.x == 150 and row.get_constant("separation") == 10,
		"and the row has the game's widths again"
	)
	tab.grab_focus()  # what the shop does after a pause in which the meter went off
	yield(_t.get_tree(), "idle_frame")
	_t._check(stats._primary_tab.has_focus(), "focus handed to the hidden tab goes on to Primary")
	seen = []
	for button in [JOY_R, JOY_R]:
		yield(_press_joypad(button), "completed")
		seen.append(_solo_tab(stats, page))
	_t._check(seen == ["secondary", "primary"], "and the triggers toggle two tabs again %s" % [seen])
	meter.set_shown(true)
	yield(_t.get_tree(), "idle_frame")
	_t._check(tab.visible, "switched on again: the tab is back")
	yield(_test_solo_end_run(), "completed")


func _press_joypad(button: int):
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = 0
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)
		yield(_t.get_tree(), "idle_frame")


static func _solo_tab(stats: Node, page: Node) -> String:
	if page.visible:
		return "damage"
	return "primary" if stats._primary_stats.visible else "secondary"


# The solo end of run: the same tab, and a stats panel elsewhere (a bare one) stays as it was.
func _test_solo_end_run():
	_t.get_tree().change_scene(RunData.get_end_run_scene_path())
	for _i in 3:
		yield(_t.get_tree(), "idle_frame")
	var stats: Node = _t.get_tree().current_scene.get_node("%StatsContainer")
	var tab = stats._primary_tab.get_parent().get_node_or_null("DamageTab")
	_t._check(tab is Button and tab.visible, "the solo end of run has the tab too")
	var bare: Node = load("res://ui/menus/shop/stats_container.tscn").instance()
	_t.get_tree().current_scene.add_child(bare)
	yield(_t.get_tree(), "idle_frame")
	var buttons: int = bare._primary_tab.get_parent().get_child_count()
	yield(_press_joypad(JOY_R), "completed")
	_t._check(
		buttons == 2 and bare.focused_tab == bare.Tab.SECONDARY,
		"any other stats panel: two tabs, RB toggles them as the game does"
	)
	bare.free()
