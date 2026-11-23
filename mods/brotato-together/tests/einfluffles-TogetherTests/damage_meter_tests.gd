extends Reference
# Damage meter (sync/damage_meter.gd, ui/damage_views.gd): the measurement, the board on the state
# stream, the HUD row, and the damage page / tab in the shop and end of run screens. The crowded
# wave is in damage_run_tests.gd.

const DamageMeter := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/damage_meter.gd")
const DamageViews := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/damage_views.gd")
const DamageLedger := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/damage_ledger.gd"
)
const ShopIntents := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_intents.gd"
)
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const Settings := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/settings.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const MenuOptionsButton := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/extensions/ui/menu_options.gd"
)
const PISTOL := "weapon_pistol_1"

var _t: Node
var _changes := 0


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	var meter: Node = together.damage_meter
	meter.connect("changed", self, "_on_changed")
	var item = _test_measure(meter)
	_test_capped_hits(meter)
	_test_overlaps(meter)
	_test_extra_counters(meter)
	_test_short()
	_test_board(meter)
	_test_run_board(meter)
	yield(_test_hud(meter, item), "completed")
	yield(_test_shop(meter, item), "completed")
	yield(_test_coop_end_run(), "completed")
	_test_cost(meter)
	yield(_test_solo_shop(meter), "completed")
	meter.disconnect("changed", self, "_on_changed")
	meter.clear_state(StateStream.DAMAGE)


func _on_changed() -> void:
	_changes += 1


# Returns the damage item.
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
	RunData.add_tracked_value(1, item.my_id_hash, 500)
	var baseline: Dictionary = RunData.tracked_item_effects[1].duplicate(true)
	RunData.add_tracked_value(1, item.my_id_hash, 77)
	RunData.add_tracked_value(1, other.my_id_hash, 9)
	var theirs: Array = meter.measure_player(1, baseline)
	_t._check(
		theirs[0] == 77 and theirs[1] == [[item.my_id, 1, 77]],
		"an item's damage is what its counter gained this wave %s (%s)" % [theirs, item.my_id]
	)
	_test_strongest()
	return item


# A wave's hits on fresh state.
static func _clear_hits(meter: Node) -> void:
	meter._frozen = false
	meter._hits = []
	meter._dealt = []
	meter._kills = []
	meter._taken = []
	meter._health = {}
	meter._gone = {}
	meter._lost = 0
	meter._unowned = 0
	meter._after_death = 0
	meter._hidden = 0
	meter._all_kills = 0


static func _hit(meter: Node, unit, value: int, args, crit := false, one_shot := false) -> void:
	meter.on_hit(unit, value, Vector2.ZERO, crit, false, false, false, args, 0, one_shot)


# A hit takes its value, a killing hit at most the health that was left: the total is the health
# the hits took. The biggest hit is the biggest number shown above a unit: a killing hit's whole
# value.
func _test_capped_hits(meter: Node) -> void:
	_clear_hits(meter)
	var weak := FakeUnit.new(9)
	weak.current_stats.health = 0
	_hit(meter, weak, 504, TakeDamageArgs.new(0))
	_t._check(
		meter._dealt[0] == 9 and meter._hits[0][0] == 504,
		"an overkill hit: the total counts 9, the biggest hit is the 504 shown (%d, %s)"
		% [meter._dealt[0], meter._hits[0]]
	)
	_clear_hits(meter)
	var args := TakeDamageArgs.new(0)
	var unit := FakeUnit.new(300)
	unit.current_stats.health = 200
	_hit(meter, unit, 100, args)
	unit.current_stats.health = 0
	_hit(meter, unit, 5000, args)
	var fresh := FakeUnit.new(300)
	fresh.current_stats.health = 0
	_hit(meter, fresh, 9999, args)  # killed by its first hit: it had all its health
	var healed := FakeUnit.new(300)
	healed.current_stats.health = 50
	_hit(meter, healed, 250, args)
	healed.current_stats.health = 280
	meter._on_health_set(healed)  # a healer's heal, a buffer's boost
	healed.current_stats.health = 0
	_hit(meter, healed, 1000, args)
	var tree := FakeUnit.new(40, false)
	tree.current_stats.health = 0
	_hit(meter, tree, 70, args)
	var forwarded := TakeDamageArgs.new(0)
	forwarded.hide_feedback = true  # the brachiosaurus' foot hands its hit on to the boss
	_hit(meter, FakeUnit.new(300), 60000, forwarded)
	var one_shot := FakeUnit.new(400)
	one_shot.current_stats.health = 0
	_hit(meter, one_shot, 20000, args, false, true)  # shows "ONE_SHOT", no number
	var crit_shot := FakeUnit.new(500)
	crit_shot.current_stats.health = 0
	_hit(meter, crit_shot, 12000, args, true, true)  # a crit shows its number
	var nobody := FakeUnit.new(30)
	nobody.current_stats.health = 0
	_hit(meter, nobody, 90, TakeDamageArgs.new(-1))  # no player's
	# Removed by the game's cap on enemies (died without a hit), then hit by a bullet that was
	# on its way: that hit takes the 25 it had left, as the weapon's counter counts it.
	var removed := FakeUnit.new(60)
	removed.current_stats.health = 25
	_hit(meter, removed, 35, args)
	removed.dead = true
	meter._on_unit_gone(removed, null)
	removed.current_stats.health = 0
	_hit(meter, removed, 40, args)
	_hit(meter, removed, 40, args)  # nothing left
	var dealt: int = meter._dealt[0]
	var expected := 100 + 200 + 300 + 250 + 280 + 40 + 400 + 500 + 35 + 25
	_t._check(
		dealt == expected, "the total is the health the hits took, not the overkill (%d)" % dealt
	)
	_t._check(
		meter._hits[0][0] == 12000,
		"the biggest hit is the biggest number shown, not a hidden hit or a one-shot's %s"
		% [meter._hits[0]]
	)
	_t._check(meter._kills[0] == 5, "kills: the enemies only, not the tree (%d)" % meter._kills[0])
	var own := [meter._lost, meter._unowned, meter._after_death, meter._hidden, meter._all_kills]
	_t._check(
		own == [expected + 30, 30, 25, 60000, 6],
		"the wave's own count: health lost whoever hit, no player's, after death, hidden, kills %s"
		% [own]
	)
	meter.measure()
	var team := 0
	for entry in meter.board.players:
		team += entry[0]
	var line: String = meter.wave_line()
	print("  info: %s" % line)
	var head := "damage: total %s, health lost 2,160 (by no player 30, after death 25, hidden"
	head = (head + " 60,000); p0 2,130 (") % Text.get_formatted_number(team)
	_t._check(
		(
			head in line
			and "biggest hit 12,000 unknown, 5 kills)" in line
			and line.ends_with("; 6 kills")
		),
		"the wave's log line: totals, health lost, per player rows, biggest hit, kills (%s)" % line
	)
	var hurt := FakeUnit.new(100)
	hurt.player_index = 1
	for case in [[30, false, false], [500, true, false], [20, false, true]]:
		meter._on_hurt(hurt, case[0], Vector2.ZERO, false, case[1], case[2], false, args, 0, false)
	_t._check(meter._taken[1] == 30, "damage taken: not what was dodged or blocked")
	_clear_hits(meter)


# Giant Belt's bonus is in the weapon's hit: the total holds it once, the belt's row shows it as
# included.
func _test_overlaps(meter: Node) -> void:
	var belt = _t._find_by_id(ItemService.items, "item_giant_belt")
	_t._check(belt != null and DamageMeter.overlaps("item_giant_belt"), "Giant Belt overlaps")
	if belt == null:
		return
	RunData.add_item(belt, 0)
	var tracked: Dictionary = RunData.tracked_item_effects[0]
	if typeof(tracked.get(belt.my_id_hash)) != TYPE_INT:
		tracked[belt.my_id_hash] = 0
	var baseline: Dictionary = tracked.duplicate(true)
	tracked[belt.my_id_hash] += 400
	var pistols: Array = RunData.get_player_weapons(0)
	pistols[0].dmg_dealt_last_wave = 1000  # with the belt's 400
	pistols[1].dmg_dealt_last_wave = 0
	var got: Array = meter.measure_player(0, baseline, 10, false, 1000)
	_t._check(
		got[0] == 1000 and got[1] == [[PISTOL, 2, 1000], ["item_giant_belt", 1, 400]],
		"the total counts the belt's bonus once, the belt keeps its row %s" % [got]
	)
	got = meter.measure_player(0, baseline, 10, false, 0)
	_t._check(got[0] == 1000, "with no hit seen: what the other rows sum to (%d)" % got[0])
	RunData.remove_item(belt, 0)
	pistols[0].dmg_dealt_last_wave = 120
	pistols[1].dmg_dealt_last_wave = 30


# The chef's consumable explosions and the builder's turret count damage without saying so in
# their item text; each builder turret zeroes its levels' counters when it spawns.
func _test_extra_counters(meter: Node) -> void:
	var p := 1
	var tracked: Dictionary = RunData.tracked_item_effects[p]
	var keys := []
	for id in ["item_builder_turret_1", "item_builder_turret_2", "character_chef"]:
		keys.append(Keys.generate_hash(id))
	tracked[keys[0]] = 500
	tracked[keys[1]] = 0
	tracked[keys[2]] = 40
	var saved: Array = meter._baseline
	meter._baseline = RunData.tracked_item_effects.duplicate(true)
	tracked[keys[0]] = 0  # the turret's set_data, after the wave's start values
	meter._check_resets()
	tracked[keys[0]] = 120
	tracked[keys[1]] = 30
	tracked[keys[2]] = 100
	var got: Array = meter.measure_player(p, meter._baseline[p])
	var sources := {}
	for source in got[1]:
		sources[source[0]] = source[2]
	_t._check(
		sources.get("item_builder_turret_1") == 150 and not sources.has("item_builder_turret_2"),
		"the builder's turret: one row for its levels, counted from its reset %s" % [got[1]]
	)
	_t._check(sources.get("character_chef") == 60, "the chef's explosions %s" % [got[1]])
	for key in keys:
		tracked.erase(key)
	meter._baseline = saved


# The HUD shows 4 sources, 3 with 3 or 4 players; the shop's board (-1) keeps its order.
func _test_strongest() -> void:
	var weapons := {"a": true, "b": true, "c": true}
	var a := ["a", 1, 90]
	var b := ["b", 1, 50]
	var c := ["c", 1, 30]
	var t := ["t", 0, 10]
	var cases := [
		[[a, b, t], 2, 0, [a, t]],
		[[["t", 0, 90], ["u", 1, 50], ["a", 1, 10]], 2, 0, [["t", 0, 90], ["a", 1, 10]]],
		[[a, t, b], 2, 0, [a, t]],
		[[a, b], 2, 0, [a, b]],
		[[a, b, c, t], 3, 0, [a, b, t]],
		[[a, b, c, t], 3, 11, [a, b, c]],
		[[a, b, c, t], 3, -1, [a, b, c]],
		[[a, b, t], 10, 0, [a, b, t]],
		[[a], 2, 0, [a]],
		[[], 2, 0, []],
	]
	for case in cases:
		var got: Array = DamageMeter.strongest(case[0], weapons, case[1], case[2])
		_t._check(got == case[3], "strongest %s (%s) of %s: %s" % [case[1], case[2], case[0], got])
	var counts := [DamageMeter.live_sources(1), DamageMeter.live_sources(2)]
	counts += [DamageMeter.live_sources(3), DamageMeter.live_sources(4)]
	_t._check(counts == [4, 4, 3, 3], "the HUD's sources by players %s" % [counts])


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
	var shares := [
		DamageViews.percent(1290000, 2270000),
		DamageViews.percent(266, 2270000),
		DamageViews.percent(10, 2270000),
		DamageViews.percent(1000, 1000),
		DamageViews.percent(1, 1000),
		DamageViews.percent(0, 1000),
	]
	_t._check(
		shares == ["56.83%", "0.01%", "<0.01%", "100.00%", "0.10%", "0.00%"],
		"the board's shares to two places, <0.01%% for a little %s" % [shares]
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
	_t._check(not older.has("run"), "a board without the run: no run view")


# The board of a wave that is over carries the run so far.
func _test_run_board(meter: Node) -> void:
	var saved: Reference = meter.ledger
	meter.ledger = DamageLedger.new()
	meter.measure()
	_t._check(not meter.board.has("run"), "a running wave's board has no run")
	meter.measure(true)
	var sent = bytes2var(var2bytes(meter.state_body(StateStream.DAMAGE)), false)
	var run = sent.get("run", {})
	_t._check(
		run.get("waves") == 1 and run.players.size() == 2 and run.players[0][0] == sent.players[0][0],
		"the wave's last measurement carries the run with it %s" % [run]
	)
	_t._check(
		var2str(DamageMeter.clean(sent)) == var2str(sent),
		"and passes the client's check, run and all"
	)
	meter.ledger = saved
	var good := {"waves": 2, "time": 40.0, "players": [[90, [[PISTOL, 1, 90]], [30, PISTOL], 5, 7]]}
	var sources := []
	for i in 11:
		sources.append(["weapon_%d" % i, 1, 1])
	var five := []
	for _i in 5:
		five.append(good.players[0])
	var bad := {
		"run without waves": {"time": 1.0, "players": []},
		"run with a negative time": {"waves": 1, "time": -1.0, "players": []},
		"run with five players": _run(five),
		"run with eleven sources": _run([[11, sources, [1, ""], 0, 0]]),
		"run without kills": _run([[90, [], [30, PISTOL], 7]]),
		"run with negative kills": _run([[90, [], [3, ""], -1, 0]]),
		"run with a long hit id": _run([[9, [], [3, "x".repeat(200)], 0, 0]]),
		"run not a dictionary": [1, 2],
	}
	for label in bad:
		var body := {"wave": 3, "players": [], "run": bad[label]}
		_t._check(DamageMeter.clean(body).empty(), "malformed board rejected: %s" % label)
	var body := {"wave": 3, "players": [[90, [[PISTOL, 1, 90]]]], "run": good}
	_t._check(
		var2str(DamageMeter.clean(body).get("run")) == var2str(good),
		"a good run passes %s" % [DamageMeter.clean(body)]
	)


static func _run(players: Array) -> Dictionary:
	return {"waves": 1, "time": 1.0, "players": players}


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
	var total: Label = rows[0].get_node("Lines/Main/Total")
	var first: Node = rows[0].get_node("Lines/Sources/Source0")
	var hit: Node = rows[0].get_node("Lines/Hit")
	_t._check(
		rows[0].visible and total.text == "1.23K" and first.get_node("Icon").texture == icon,
		"the row shows the total and the strongest source (%s)" % total.text
	)
	_t._check(
		first.get_node("Amount").text == "1.23K" and first.get_node("Icon/Count").text == "x2",
		"on its own line with its number, the count of equal weapons in the icon's corner"
	)
	_t._check(
		not rows[0].get_node("Lines/Sources/Source1").visible,
		"no second source line where there is none"
	)
	_t._check(
		not rows[0].get_node("Lines/Main/Dps").visible and not hit.visible,
		"no damage per second before the wave ran a second, no biggest hit before a hit"
	)
	_t._check(
		(
			rows[0].get_node("Lines").get_child(0).name == "Main"
			and first.get_child(0).name == "Icon"
			and first.get_child(1).name == "Amount"
			and rows[1].get_node("Lines/Sources/Source0").get_child(1).name == "Icon"
			and rows[1].get_node("Lines/Main").get_child(3).name == "Icon"
		),
		"the total first under the bar, the icons at the screen's edge (the right-hand player's last)"
	)
	_t._check(
		(
			rows[0] is PanelContainer
			and rows[0].size_flags_horizontal == 0
			and rows[1].size_flags_horizontal == Control.SIZE_SHRINK_END
		),
		"on a backing as wide as its lines, at the screen's edge"
	)
	_t._check(
		item == null
		or (
			rows[1].visible
			and rows[1].get_node("Lines/Main/Total").text == "77"
			and rows[1].get_node("Lines/Main/Share").text == "6%"
		),
		"the other player's row shows that player's own, with its share of the team's"
	)
	var args := TakeDamageArgs.new(0)
	meter.on_hit(null, 1000, Vector2.ZERO, true, false, false, false, args, 0, false)
	meter.on_hit(null, 234, Vector2.ZERO, false, false, false, false, args, 0, false)
	var nobody := TakeDamageArgs.new(-1)
	meter.on_hit(null, 99999, Vector2.ZERO, false, false, false, false, nobody, 0, false)
	meter._wave_time = 10.0
	meter.measure()
	_t._check(
		meter.board.hits[0] == [1000, ""] and meter.board.hits[1] == [0, ""],
		"the biggest hit per player, none for a hit that was no player's %s" % [meter.board.hits]
	)
	_t._check(
		(
			hit.visible
			and hit.get_node("Value").text == "1.00K"
			and not hit.get_node("Icon/Source").visible
		),
		"the row shows it, short, on its own line (%s)" % hit.get_node("Value").text
	)
	var dps: Label = rows[0].get_node("Lines/Main/Dps")
	_t._check(dps.visible and dps.text == "123/s", "and the damage per second (%s)" % dps.text)


func _test_shop(meter: Node, item):
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
	var stats: Node = list.get_node("Head/Stats")
	var title: String = list.get_node("Head/Wave").text
	var share: Label = stats.get_node("Share")
	_t._check(
		title == Text.text("WAVE", [str(RunData.current_wave)]) and share.visible,
		"the wave over the total, with the share of the team's (%s, %s)" % [title, share.text]
	)
	var values := []
	for part in ["Total", "Dps", "Hit"]:
		values.append(stats.get_node(part).text)
	_t._check(
		values[0] == "1,234" and values[1] != "-" and values[2] == "1,000",
		"one line: the total, damage per second and the biggest hit %s" % [values]
	)
	var rows: Node = list.get_node("Sources")
	var row: Node = rows.get_child(0)
	var content: Node = row.get_node("Content")
	var number := "%s %s" % [content.get_node("Amount").text, content.get_node("Share").text]
	_t._check(
		row.visible and number == "1,234 100.00%" and not rows.get_child(1).visible,
		"a row per source with number and share (%s)" % number
	)
	_t._check(row.value == 1000, "the strongest source's row is a full bar")
	if item != null:
		var theirs: Node = _list(panels[1]).get_node("Sources").get_child(0)
		var item_icon: Texture = theirs.get_node("Content/Icon").texture
		_t._check(theirs.visible and item_icon == item.icon, "player 2's page: its own item")
	_t._check(
		not rows.get_node(DamageViews.OTHER_ROW).visible and meter.board.has("run"),
		"the shop shows the wave, though its board has the run; nothing past the rows: no other"
	)
	_test_other_row(meter, list)
	# Online the page index travels like the game's own pages: a client's page on the host.
	ShopIntents.apply_focus(shop, 0, 3, [])
	_t._check(panels[0].carousel.index == 3, "a page 3 from the network shows the damage page")
	ShopIntents.apply_focus(shop, 0, 0, [])
	yield(_test_switch(shop, panels), "completed")


# Shares add up: an overlapping source shows as included, what no row holds is "other".
func _test_other_row(meter: Node, list: Node) -> void:
	var saved: Dictionary = meter.board
	var sources := [[PISTOL, 2, 1000], ["item_giant_belt", 1, 400]]
	var body := {"wave": 3, "players": [[1500, sources], [0, []]], "time": 10.0, "hits": []}
	meter.apply_state(StateStream.DAMAGE, body, 1)
	var rows: Node = list.get_node("Sources")
	var other: Node = rows.get_node(DamageViews.OTHER_ROW)
	var shares := []
	for row in [rows.get_child(0), rows.get_child(1), other]:
		shares.append(row.get_node("Content/Share").text)
	_t._check(
		shares == ["66.67%", DamageViews.INCLUDED, "33.33%"],
		"the belt's row is included in the weapon's, the rest is other %s" % [shares]
	)
	var content: Node = other.get_node("Content")
	_t._check(
		other.visible and content.get_node("Amount").text == "500"
		and content.get_node("Name").text == DamageViews.OTHER_ROW,
		"the other row: what the total holds past the shown rows"
	)
	meter.apply_state(StateStream.DAMAGE, saved, 2)
	_t._check(var2str(meter.board) == var2str(saved), "a board with the run passes the check")


func _page(panel: Node) -> Control:
	return panel.carousel.get_node("%Content").get_node(DamageViews.PAGE_NAME) as Control


func _heading(panel: Node) -> Control:
	return panel.carousel.get_node("%Headings").get_node(DamageViews.HEADING_NAME) as Control


func _list(panel: Node) -> Node:
	return _page(panel).get_node(DamageViews.LIST_NAME)


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
	var player: Array = CoopService.connected_players[1]
	var device: int = player[0]
	player[0] = VirtualDevices.FIRST  # player 2 plays on another machine
	yield(_t.get_tree(), "idle_frame")
	carousel._on_ArrowRight_pressed()
	_t._check(
		carousel._get_max_index() == 3 and carousel.index == 3,
		"switched off here: a remote player's panel keeps its damage page"
	)
	player[0] = device
	yield(_t.get_tree(), "idle_frame")
	_t._check(carousel.index == 2, "a player of this machine goes back to the page before")
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
	var total: String = _list(containers[0]).get_node("Head/Stats/Total").text
	_t._check(
		containers[0].carousel.index == 3 and _page(containers[0]).visible and total == "1,234",
		"three pages on: the run's board, one wave here (%s)" % total
	)
	var head: Node = _list(containers[0]).get_node("Head")
	_t._check(
		head.get_node("Wave").text == DamageViews.RUN_TITLE_ONE and head.get_node("Extra").visible,
		"titled with the run's waves, with kills and damage taken (%s)" % head.get_node("Wave").text
	)
	_t._check(
		head.get_node("Extra/Kills").text == DamageViews.KILLS % "0",
		"kills: %s" % head.get_node("Extra/Kills").text
	)


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
	_t._check(live_size < 1100, "the board of a running wave stays under 1100 B (%d)" % live_size)
	print(
		(
			"  info: damage meter, late run, 4 players: %.0f usec per measurement, %d B during the"
			+ " wave; at its end %.0f usec, %d B for %d sources (setting the counters: %.0f usec)"
		)
		% [live, live_size, final, size, sources, setting]
	)


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
	var total: String = list.get_node("Head/Stats/Total").text
	var share: Label = list.get_node("Head/Stats/Share")
	_t._check(total == "50" and not share.visible, "with the wave's total, no share alone")
	_t._check(
		list.get_node("Head/Stats/Hit").text == "-",
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
	yield(_test_solo_end_run(meter), "completed")


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


func _test_solo_end_run(meter: Node):
	var run := {"waves": 3, "time": 60.0, "players": [[150, [[PISTOL, 1, 120]], [40, PISTOL], 12, 34]]}
	var body := {"wave": 3, "players": [[50, [[PISTOL, 1, 50]]]], "run": run}
	meter.apply_state(StateStream.DAMAGE, body, 0)
	_t.get_tree().change_scene(RunData.get_end_run_scene_path())
	for _i in 3:
		yield(_t.get_tree(), "idle_frame")
	var stats: Node = _t.get_tree().current_scene.get_node("%StatsContainer")
	var tab = stats._primary_tab.get_parent().get_node_or_null("DamageTab")
	_t._check(tab is Button and tab.visible, "the solo end of run has the tab too")
	var list: Node = stats._secondary_stats.get_parent().get_node(DamageViews.PAGE_NAME).get_child(0)
	var seen := []
	for part in ["Wave", "Stats/Total", "Stats/Dps", "Stats/Hit", "Extra/Kills", "Extra/Taken"]:
		seen.append(list.get_node("Head/" + part).text)
	var expected := [DamageViews.RUN_TITLE % 3, "150", "3/s", "40"]
	expected += [DamageViews.KILLS % "12", DamageViews.TAKEN % "34"]
	_t._check(seen == expected, "its tab shows the run %s" % [seen])
	var other: Node = list.get_node("Sources").get_node(DamageViews.OTHER_ROW)
	_t._check(
		other.visible and other.get_node("Content/Amount").text == "30",
		"with an other row for the 10 sources' rest"
	)
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


# What on_hit reads off a unit: its health after the hit, its full health, whether it is an enemy.
class FakeUnit:
	extends Reference
	var current_stats := {"health": 0}
	var max_stats := {"health": 0}
	var enemy_id = "fake"
	var player_index = null
	var dead := false

	func _init(health: int, enemy := true) -> void:
		current_stats = {"health": health}
		max_stats = {"health": health}
		enemy_id = "fake" if enemy else null
