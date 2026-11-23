extends Reference
# Suite shop_gear_change: a client's shop applies the host's states late in a run (2 / 4 players,
# 250 items each). The gear rows are updated in place (UpgradesGear.sync_gear): a purchase
# instances one element, a reroll none. The old way (set_weapons_data / set_items_data: every
# element of that player freed and instanced again) is timed in the same shop. The client report's
# "shop panels" mark holds what applying a state costs after the run's own marks. Then the race of
# another player's cursor with the state that changes its gear (_cursor_race).

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const ShopStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_stream_tests.gd"
)
const ShopChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_change_tests.gd"
)
const FocusSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/focus_sync.gd")
const BUYER := 1  # the player whose gear changes (another player's panel on this client)
const KINDS := ["purchase", "reroll", "weapon"]
const RACE_ITEMS := 40

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
	yield(_cursor_race(), "completed")
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
	if players == 2:
		yield(_unreadable_part(shop, states.weapon, players), "completed")
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


# A later state with a part the client cannot read (a NaN as a host without FiniteJson printed
# it): the shop keeps its run and applies the rest of the body (ShopSync.apply_state).
func _unreadable_part(shop: Node, body: Dictionary, players: int):
	var broken: Dictionary = body.duplicate(true)
	var bad := RunStateCodec.pack('{"a":nan}')
	broken.run.ids["p%d" % BUYER] = [1, bad.size]
	broken.run.parts["p%d" % BUYER] = {"size": bad.size, "data": bad.data}
	var run_ids = _sync._run_ids
	var unreadable: int = _sync.run_store.unreadable
	var done: Dictionary = yield(_client_apply(shop, broken, players), "completed")
	_t._check(
		done.marks[ClientReport.Mark.SHOP_PANELS] > 0
		and _sync._run_ids == run_ids  # the same dictionary: the run was kept
		and _sync.run_store.unreadable == unreadable + 1
		and _sync._client_shop == shop,
		"client: a shop state with an unreadable run part keeps the run and applies the rest"
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


# The host's cursor rests on BUYER's next to last item (a high tier) while an item comes in before
# it (a purchase, a trade): its element moves one place on, where the client's row still has
# another item, and the cursor body names it there.
# The body and the run state reach the client in either order (the stream sends the cursors on
# their own timer), and the client ends on the host's item. A cursor on the item that came in
# waits for the run state that brings it.
func _cursor_race():
	_change._build_run(2, RACE_ITEMS)
	yield(_change._enter_shop(), "completed")
	var host_shop: Node = _change._shop
	var host_row: Node = host_shop._get_gear_container(BUYER).items_container._elements
	var host_emulator = Utils.get_focus_emulator(BUYER, host_shop)
	var states := {"start": _capture()}
	var rest: Control = host_row.get_child(host_row.get_child_count() - 2)
	var rest_key := _key(rest)
	var bought = _new_item(BUYER)
	var before: Array = FocusSync.cursor_of(host_emulator, rest, host_shop)
	RunData.add_item(bought, BUYER)
	host_row.add_element(bought, true)  # as BaseShop.buy_item and brotato:trade's gift do
	var after: Array = FocusSync.cursor_of(host_emulator, rest, host_shop)
	var on_new: Array = []
	for element in host_row.get_children():
		if element.item == bought:
			on_new = FocusSync.cursor_of(host_emulator, element, host_shop)
	states.purchase = _capture()
	var bought_key := "%s %d 000" % [bought.my_id, bought.tier]
	print(
		"  info: cursor race: %s at %d, then %d after %s came in"
		% [rest_key, rest.get_index() - 1, rest.get_index(), bought.my_id]
	)
	var scene: String = host_shop.filename

	_sync._client_shop_id = 0
	ShopStreamTests.deliver(_sync.state_stream, StateStream.RUN_SHOP, states.start)
	yield(_sync, "shop_entered")
	yield(_frames(2), "completed")
	var shop: Node = _sync._client_shop
	var stream: Node = _sync.state_stream
	var emulator = Utils.get_focus_emulator(BUYER, shop)
	_cursors(stream, scene, before)
	var at_start := _under(emulator)
	_cursors(stream, scene, after)  # first: the client's row is the old one
	var early := _under(emulator)
	ShopStreamTests.deliver(stream, StateStream.RUN_SHOP, states.purchase)
	yield(_frames(1), "completed")
	_t._check(
		at_start == rest_key and early == rest_key and _under(emulator) == rest_key,
		(
			"cursor race, client: the cursor body before the run state: on the host's item"
			+ " (%s, then %s, after the state %s; host %s)"
		)
		% [at_start, early, _under(emulator), rest_key]
	)

	yield(_restart(stream, scene, states.start, before), "completed")
	ShopStreamTests.deliver(stream, StateStream.RUN_SHOP, states.purchase)
	yield(_frames(1), "completed")
	var between := _under(emulator)
	_cursors(stream, scene, after)
	_t._check(
		between == rest_key and _under(emulator) == rest_key,
		"cursor race, client: the run state first, then the body: on the host's item (%s, %s)"
		% [between, _under(emulator)]
	)

	yield(_restart(stream, scene, states.start, before), "completed")
	_cursors(stream, scene, on_new)
	var waiting: bool = stream.is_pending(StateStream.CURSORS)
	var meanwhile := _under(emulator)
	ShopStreamTests.deliver(stream, StateStream.RUN_SHOP, states.purchase)
	yield(_frames(1), "completed")
	_t._check(
		(
			waiting
			and meanwhile == rest_key
			and not stream.is_pending(StateStream.CURSORS)
			and _under(emulator) == bought_key
		),
		(
			"cursor race, client: a cursor on an item not here yet waits, then lands with the run"
			+ " state (pending %s, meanwhile %s, then %s)"
		)
		% [waiting, meanwhile, _under(emulator)]
	)
	stream._pending.erase(StateStream.CURSORS)
	emulator.focused_control = null


# Back to the start (the row before the item came in) with the cursor where the host had it.
func _restart(stream: Node, scene: String, start: Dictionary, cursor: Array):
	ShopStreamTests.deliver(stream, StateStream.RUN_SHOP, start)
	yield(_frames(1), "completed")
	_cursors(stream, scene, cursor)


# A cursors body through the client's stream, as the host sends it.
static func _cursors(stream: Node, scene: String, cursor: Array) -> void:
	ShopStreamTests.deliver(stream, StateStream.CURSORS, {"scene": scene, "cursors": [cursor]})


# What the cursor's element shows, "none" off the gear.
static func _under(emulator) -> String:
	var control = emulator.focused_control
	if not is_instance_valid(control):
		return "none"
	return _key(control) if control is InventoryElement else str(control.name)


# As FocusTargets.item_key.
static func _key(element: Node) -> String:
	var item = element.item
	return "%s %d %d%d%d" % [
		item.my_id, item.tier, int(item.is_cursed), int(item.is_meca), int(item.is_mutant)
	]


# A tier 1 item p does not have yet.
static func _new_item(p: int):
	var owned := {}
	for item in RunData.get_player_items(p):
		owned[item.my_id] = true
	for item in ItemService.items:
		if item.tier == 0 and not owned.has(item.my_id) and not item.is_cursed:
			return item
	return null
