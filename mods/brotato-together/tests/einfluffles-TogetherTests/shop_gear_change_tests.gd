extends Reference
# Suite shop_gear_change: a client's shop applies the host's states late in a run (2 / 4 players,
# 250 items each). The gear rows are updated in place (UpgradesGear.sync_gear): a purchase
# instances one element, a reroll none. The old way (set_weapons_data / set_items_data: every
# element of that player freed and instanced again) is timed in the same shop. The client report's
# "shop panels" mark holds what applying a state costs after the run's own marks.

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const ShopStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_stream_tests.gd"
)
const ShopChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_change_tests.gd"
)
const BUYER := 1  # the player whose gear changes (another player's panel on this client)
const KINDS := ["purchase", "reroll", "weapon"]

var _t: Node = null
var _together: Node = null
var _sync: Node = null
var _change = ShopChangeTests.new()  # its late run and shop entry


func run(t: Node, together: Node):
	_t = t
	_together = together
	_sync = together.shop_sync
	_change._t = t
	_change._sync = _sync
	_sync.set_process(false)  # driven by hand (no Steam session)
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	for players in [2, 4]:
		yield(_late_run(players), "completed")
	Puppet.set_active(false)
	_sync._host_shop = null
	CoopService.connected_players = saved_players
	_sync.set_process(true)


func _late_run(players: int):
	var label := "late endless run, %d players, %d items each" % [players, ShopChangeTests.LATE_ITEMS]
	_change._build_run(players, ShopChangeTests.LATE_ITEMS)
	yield(_change._enter_shop(), "completed")
	var states := {"start": _capture()}
	var item = ItemService.items[7]
	RunData.add_item(item, BUYER)
	RunData.remove_gold(10, BUYER)
	states.purchase = _capture()
	RunData.remove_gold(3, BUYER)
	states.reroll = _capture()
	RunData.add_weapon(ItemService.weapons[3], BUYER)
	RunData.remove_gold(10, BUYER)
	states.weapon = _capture()

	_sync._client_shop_id = 0
	ShopStreamTests.deliver(_sync.state_stream, StateStream.RUN_SHOP, states.start)
	yield(_sync, "shop_entered")
	yield(_frames(2), "completed")
	var shop: Node = _sync._client_shop
	var done := {}
	for kind in KINDS:
		done[kind] = yield(_client_apply(shop, states[kind], players), "completed")
	var most := {"purchase": 1, "reroll": 0, "weapon": 1}
	for kind in KINDS:
		_t._check(
			done[kind].instanced <= most[kind] and done[kind].shows_run,
			(
				"%s, client: a %s's state instances %d gear elements (at most %d), every gear row"
				+ " shows the run's objects"
			)
			% [label, kind, done[kind].instanced, most[kind]]
		)
	var old: int = yield(_old_gear(shop), "completed")
	var marks: Array = done.purchase.marks
	var panels: int = marks[ClientReport.Mark.SHOP_PANELS]
	print(
		(
			"  info: shop client, %s: a purchase's state %d usec (run parse %d, deserialize %d,"
			+ " apply %d, shop panels %d); the old way's gear rebuild of that player alone %d;"
			+ " a reroll's state %d (shop panels %d), a weapon's %d (shop panels %d)"
		)
		% [
			label,
			done.purchase.usec,
			marks[ClientReport.Mark.PARSE],
			marks[ClientReport.Mark.DESERIALIZE],
			marks[ClientReport.Mark.APPLY],
			panels,
			old,
			done.reroll.usec,
			done.reroll.marks[ClientReport.Mark.SHOP_PANELS],
			done.weapon.usec,
			done.weapon.marks[ClientReport.Mark.SHOP_PANELS],
		]
	)
	_t._check(
		panels > 0 and panels * 2 < old,
		(
			"%s, client: the shop panels of a purchase take under half of the old gear rebuild"
			+ " (%d usec, the old way %d)"
		)
		% [label, panels, old]
	)


# The host's state now, as a client gets it (every part, a copy), for no player of its own.
func _capture() -> Dictionary:
	_sync.run_cache.force()
	var body: Dictionary = _sync.state_body(StateStream.RUN_SHOP)
	body["you"] = -1
	return bytes2var(var2bytes(body), false)


# Applies body as the client's stream does, one frame later (the freed elements are gone):
# {usec, marks (usec per ClientReport.Mark), instanced: gear elements new, shows_run}.
func _client_apply(shop: Node, body: Dictionary, players: int):
	var views := []
	for p in players:
		views.append(_gear_nodes(shop, p))
	var report: Node = _together.client_report
	var was_active: bool = report.active
	report.active = true
	report._marks = report._no_marks()
	var started := OS.get_ticks_usec()
	_sync.accept_state(StateStream.RUN_SHOP, body, 0)
	_sync.apply_state(StateStream.RUN_SHOP, body, 0)
	var usec := OS.get_ticks_usec() - started
	var marks: Array = report._marks.duplicate()
	report._marks = report._no_marks()
	report.active = was_active
	var done := {"usec": usec, "marks": marks, "instanced": 0, "shows_run": true}
	for p in players:
		for node in _gear_nodes(shop, p):
			if not node in views[p]:
				done.instanced += 1
		done.shows_run = done.shows_run and _shows_run(shop, p)
	yield(_frames(1), "completed")
	return done


# What the shop did before: BUYER's rows rebuilt by the game, in usec.
func _old_gear(shop: Node):
	var emulator = Utils.get_focus_emulator(BUYER, shop)
	if emulator != null:
		emulator.focused_control = null  # off the elements freed here
	var gear = shop._get_gear_container(BUYER)
	var started := OS.get_ticks_usec()
	gear.set_weapons_data(RunData.get_player_weapons(BUYER))
	gear.set_items_data(RunData.get_player_items(BUYER))
	var usec := OS.get_ticks_usec() - started
	yield(_frames(1), "completed")
	return usec


# Instance ids of the live elements of p's gear rows.
static func _gear_nodes(shop: Node, p: int) -> Array:
	var nodes := []
	var gear = shop._get_gear_container(p)
	for inventory in [gear.weapons_container._elements, gear.items_container._elements]:
		for element in inventory.get_children():
			if not element.is_queued_for_deletion():
				nodes.append(element.get_instance_id())
	return nodes


# p's rows show its own weapon objects (a reroll brings new ones of the same weapons) and every
# item of the run, counted.
static func _shows_run(shop: Node, p: int) -> bool:
	var gear = shop._get_gear_container(p)
	var weapons: Array = RunData.get_player_weapons(p)
	var shown := 0
	for element in gear.weapons_container._elements.get_children():
		if element.is_queued_for_deletion():
			continue
		if not element.item in weapons:
			return false
		shown += 1
	if shown != weapons.size():
		return false
	shown = 0
	for element in gear.items_container._elements.get_children():
		if not element.is_queued_for_deletion():
			shown += element.current_number
	return shown == RunData.get_player_items(p).size()


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")
