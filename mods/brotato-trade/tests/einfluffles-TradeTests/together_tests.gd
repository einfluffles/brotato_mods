extends Reference
# brotato:trade next to brotato:together (this process loads both): first as the host, then as a
# client in the same shop as the host sent it.

const TOGETHER_DIR := "res://mods-unpacked/einfluffles-BrotatoTogether/"
const Hotkey := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/hotkey.gd")
const TRADE := "brotato_trade"
const FAKE_PEER := 4242
# On the host player 0 is local and player 1 remote (a virtual device). Later player 1 is the
# client's own player.
const REMOTE := 1
const ITEM := "trade.item"
const WEAPON := "trade.weapon"
const BUY := "trade.buy"
const FocusTargets := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd")
const Together := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/together.gd")

var _t: Node = null
var _sync: Node = null
var _shop: Node = null
var _section := 0
var _plain = null
var _unique = null
var _states := {}  # name -> shop state as a client gets it
var _host_ledger := ""


func run(t: Node):
	_t = t
	yield(t.get_tree(), "idle_frame")
	var together: Node = t.get_node_or_null(t.TOGETHER)
	t.check(together != null, "brotato:together is loaded (shards.txt: +brotato-together)")
	if together == null:
		return
	_sync = together.shop_sync
	_section = load(TOGETHER_DIR + "sync/state_stream.gd").RUN_SHOP
	var input: Node = together.input_sync
	var saved_devices: Dictionary = input.devices.duplicate()
	_sync.set_process(false)  # driven by hand (no Steam session)
	yield(_host(input), "completed")
	yield(_client(), "completed")
	load(TOGETHER_DIR + "session/puppet.gd").set_active(false)
	input.devices = saved_devices
	_sync._host_shop = null
	_sync.set_process(true)


func _host(input: Node):
	var device: int = load(TOGETHER_DIR + "sync/virtual_devices.gd").FIRST
	_t.coop_run(2)
	CoopService.connected_players[REMOTE] = [device, CoopService.PlayerType.GAMEPAD_XBOX]
	input.devices[FAKE_PEER] = device
	_plain = _t.item_with_limit(-1)
	_unique = _t.item_with_limit(1)
	for _i in 2:
		RunData.add_item(_plain, REMOTE)
		RunData.add_weapon(_t.weapon(), REMOTE)
	RunData.add_item(_unique, REMOTE)
	RunData.add_item(_unique.duplicate(), 0)
	_shop = yield(_t.open_shop(), "completed")
	_sync._host_shop = _shop
	_sync._shop_id = 5
	_t.check(_sync._kinds() == [BUY, ITEM, WEAPON], "the host takes trades as shop intents")
	_capture("start")
	_t.check(_states.start.get("kinds") == [BUY, ITEM, WEAPON], "and its state says so")
	# A reroll's gold: the remote player's data changes, its gear does not.
	RunData.add_gold(3, REMOTE)
	_capture("rerolled")

	var before: String = _t.ledger()
	var slot: int = RunData.get_player_items_ref(REMOTE).find(_plain)
	_t.check(not _apply(ITEM, slot, "item_none", 0), "a request naming another item is dropped")
	_t.check(not _apply(ITEM, 99, "item_none", 0), "one from an empty place too")
	_t.check(not _apply(ITEM, slot, _plain.my_id, REMOTE), "nothing is given to oneself")
	_t.check(not _apply(ITEM, slot, _plain.my_id, 7), "nor to a player who is not there")
	var unique_slot: int = RunData.get_player_items_ref(REMOTE).find(_unique)
	_t.check(not _apply(ITEM, unique_slot, _unique.my_id, 0), "nor a unique item to its owner")
	_t.check(_t.ledger() == before, "dropped requests change nothing")

	# Two quick trades of the same thing: the second leaves the client before the host's state
	# with the first arrived, so both carry the same panel revision.
	var request := _intent(ITEM, slot, _plain.my_id, 0)
	var again := _intent(ITEM, slot, _plain.my_id, 0)
	_t.check(_sync.host_apply_intent(_shop, REMOTE, request), "a remote player's trade is applied")
	_t.check(
		_count(0, _plain) == 1 and _count(REMOTE, _plain) == 1, "one of its two copies changed hands"
	)
	_t.check(_row_has(0, _plain), "the host's panels show it")
	_t.check(
		_sync.host_apply_intent(_shop, REMOTE, again),
		"a second trade of the same item made before the host's answer is applied too"
	)
	_t.check(
		_count(0, _plain) == 2 and _count(REMOTE, _plain) == 0 and _t.ledger() == before,
		"both copies changed hands, nothing lost"
	)
	_t.check(not _sync.host_apply_intent(_shop, REMOTE, again), "a third finds nothing to give")
	_t.check(_shop.trade_give(_plain, 0, REMOTE), "(one given back)")

	var weapon = RunData.get_player_weapons_ref(REMOTE)[1]
	request = _intent(WEAPON, 7, weapon.my_id, 0)
	again = _intent(WEAPON, 1, weapon.my_id, 0)
	_t.check(
		_sync.host_apply_intent(_shop, REMOTE, request),
		"a weapon trade is applied, found by its id when the slot is off"
	)
	_t.check(_sync.host_apply_intent(_shop, REMOTE, again), "a quick second one too")
	_t.check(not _sync.host_apply_intent(_shop, REMOTE, again), "a third finds nothing to give")
	var sizes := [
		RunData.get_player_weapons_ref(0).size(), RunData.get_player_weapons_ref(REMOTE).size()
	]
	_t.check(sizes == [2, 0], "both weapons changed hands (%s)" % [sizes])
	_t.check(_shop.trade_give(RunData.get_player_weapons_ref(0)[1], 0, REMOTE), "(one given back)")
	_t.check(_t.ledger() == before, "the run still holds exactly the same things")
	yield(_t.frames(2), "completed")

	# The host's own player trades on its screen: no intent, the changed run is found and sent.
	var key: String = _sync.state_key(_section)
	var revision: int = _sync.run_cache.rev
	var back = RunData.get_player_weapons_ref(0)[0]
	_t.check(_shop.trade_receivers(back, 0) == [REMOTE], "the host's own panel offers its peer")
	_t.check(_shop.trade_give(back, 0, REMOTE), "a local player's trade is applied at once")
	_t.check(
		_sync.state_key(_section) != key and _sync.run_cache.rev > revision,
		"and the next check sends the changed run to the clients"
	)
	back = RunData.get_player_weapons_ref(REMOTE).back()
	_t.check(_shop.trade_give(back, REMOTE, 0), "(given back)")
	_t.check(_t.ledger() == before, "still the same things")
	_capture("traded")
	_host_ledger = _t.ledger()
	yield(_host_hotkey(), "completed")
	yield(_host_buy(), "completed")
	_host_mirror()
	# Player 1 hands the client's player an item: the state for _client_receive.
	_t.check(_shop.trade_give(_owned(0, _plain.my_id), 0, REMOTE), "(player 1 gives an item)")
	_capture("received")
	input.devices.erase(FAKE_PEER)


# The host's own player has the trade key as in local co-op.
func _host_hotkey():
	var popup = _shop._get_item_popup(0)
	var element = _weapon_element(0, 0)
	_t.check(element != null, "(player 1 has a weapon to give)")
	if element == null:
		return
	Utils.get_focus_emulator(0, _shop).focused_control = element
	yield(_t.frames(1), "completed")
	_t.check(popup._trade_hint.visible, "the host's own weapon shows the trade hint")
	yield(_t.tap(TRADE, 0), "completed")
	var first: Button = popup._trade_players[0]
	_t.check(
		popup._focused and popup._trade_choosing and first.get_meta("trade_to", -1) == REMOTE,
		"the trade key opens its give list, with the remote player"
	)
	var emulator = Utils.get_focus_emulator(0, _shop)
	var cursor = emulator.focused_control
	var item = _owned(REMOTE, _plain.my_id)
	var weapon = RunData.get_player_weapons_ref(REMOTE)[0]
	_t.check(
		_apply(ITEM, RunData.get_player_items_ref(REMOTE).find(item), item.my_id, 0)
		and _apply(WEAPON, 0, weapon.my_id, 0),
		"(the remote player gives player 1 an item and a weapon meanwhile)"
	)
	yield(_t.frames(2), "completed")
	_t.check(
		popup._focused and popup._trade_choosing and emulator.focused_control == cursor,
		"player 1's give list stays open, its cursor where it was"
	)
	_t.check(
		is_instance_valid(element) and _shop._popup_manager._elements_pressed[0] == element,
		"on the weapon it was opened from"
	)
	_t.check(_row_has(0, item) and _weapon_element(0, 1) != null, "the rows show what came")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")
	_t.check(not popup._focused, "cancel closes it")
	_t.check(
		_shop.trade_give(item, 0, REMOTE)
		and _shop.trade_give(RunData.get_player_weapons_ref(0).back(), 0, REMOTE),
		"(given back)"
	)


# The remote player's open trade lists (its client reports them with its cursor) show on the
# host's copy of its panel, and go on to the other clients from there.
func _host_mirror() -> void:
	var popup = _shop._get_item_popup(REMOTE)
	var element = _element(REMOTE, _plain)
	_t.check(element != null, "(the remote player has an item to give)")
	if element == null:
		return
	var target: Array = FocusTargets.describe(element, _shop, REMOTE)
	var first: Array = FocusTargets.describe(popup._trade_players[0], _shop, REMOTE)
	var give := [target, _plain.my_id, 0, [["give"], null]]
	_sync.host_apply_focus(_shop, REMOTE, 0, first, _wire(give))
	_t.check(
		(
			popup._focused
			and popup._trade_choosing
			and popup._trade_players[0].get_meta("trade_to", -1) == 0
		),
		"host: a remote player's give list shows on its copy"
	)
	_t.check(
		Utils.get_focus_emulator(REMOTE, _shop).focused_control == popup._trade_players[0],
		"with that player's cursor on the receiver"
	)
	_t.check(popup.together_menu() == ["give"], "and goes on to the other clients")
	_sync.host_apply_focus(_shop, REMOTE, 0, target, [])
	_t.check(not popup._focused and not popup._trade_choosing, "host: closed with the client's")
	var nodes: Array = _shop._get_shop_items_container(REMOTE)._shop_items
	var node = _buyable(nodes, 0)
	if node == null:
		print("  info: nothing the remote player could buy for player 1, buy-for copy not tested")
		return
	var buy := [[], "", 0, [["buy", nodes.find(node)], null]]
	_sync.host_apply_focus(_shop, REMOTE, 0, first, _wire(buy))
	_t.check(
		popup._focused and popup.trade_buy_item() == node,
		"host: a remote player's buy-for list shows on its copy"
	)
	_sync.host_apply_focus(_shop, REMOTE, 0, [], [])
	_t.check(not popup._focused and popup.trade_buy_item() == null, "and closes with the client's")


# Player 1 has its popup open on a weapon while the remote player buys for it.
func _host_buy():
	yield(_t.frames(1), "completed")
	var nodes: Array = _shop._get_shop_items_container(REMOTE)._shop_items
	var node = _buyable(nodes, 0)
	_t.check(node != null, "(the remote player is offered something player 1 can take)")
	if node == null:
		return
	var popup = _shop._get_item_popup(0)
	var emulator = Utils.get_focus_emulator(0, _shop)
	var element = _weapon_element(0, 0)
	emulator.focused_control = element
	yield(_t.tap("ui_accept", 0), "completed")
	var cursor = emulator.focused_control
	_t.check(popup._focused and popup.is_a_parent_of(cursor), "(player 1's popup is open)")
	RunData.add_gold(node.value, REMOTE)
	var gold := [RunData.get_player_gold(0), RunData.get_player_gold(REMOTE)]
	var count: int = _held(0, node.item_data)
	var slot := nodes.find(node)
	_t.check(not _apply(BUY, slot, node.item_data.my_id, REMOTE), "nothing is bought for oneself")
	var request := _intent(BUY, slot, node.item_data.my_id, 0)
	_t.check(_sync.host_apply_intent(_shop, REMOTE, request), "a remote player's buy for another")
	_t.check(
		_held(0, node.item_data) == count + 1 and not node.active,
		"the item went to player 1, the slot is bought"
	)
	_t.check(
		[RunData.get_player_gold(0), RunData.get_player_gold(REMOTE)] == [gold[0], gold[1] - node.value],
		"paid by the remote player"
	)
	_t.check(not _sync.host_apply_intent(_shop, REMOTE, request), "the same buy twice: once")
	_t.check(_held(0, node.item_data) == count + 1, "no second copy")
	yield(_t.frames(2), "completed")
	_t.check(
		popup._focused and emulator.focused_control == cursor,
		"player 1's popup stayed open through the buy, its cursor where it was"
	)
	_t.check(_shop._popup_manager._elements_pressed[0] == element, "on the same weapon")
	yield(_t.tap("ui_cancel", 0), "completed")
	_t.check(not popup._focused, "(closed)")


func _client():
	var local = _sync.local
	_sync._client_shop_id = 0
	_receive(_states.start)
	yield(_sync, "shop_entered")
	yield(_t.frames(2), "completed")
	_shop = _sync._client_shop
	_t.check(local.active and local.you == REMOTE, "the client's own panel is the giver's")
	var popup = _shop._get_item_popup(REMOTE)
	var emulator = Utils.get_focus_emulator(REMOTE, _shop)
	var own = _owned(REMOTE, _plain.my_id)
	var theirs = _owned(0, _unique.my_id)
	_t.check(_shop.trade_receivers(own, REMOTE) == [0], "the own panel offers the other player")
	_t.check(_shop.trade_receivers(theirs, 0).empty(), "another player's panel offers nothing")
	var before: String = _t.ledger()
	_t.check(not _shop.trade_give(own, REMOTE, 0), "the copy of the shop gives nothing itself")

	emulator.focused_control = _element(REMOTE, own)
	yield(_t.tap("ui_accept", REMOTE), "completed")
	_t.check(popup._focused and popup._trade_button.visible, "the own popup has Trade")
	emulator.focused_control = popup._trade_button
	yield(_t.tap("ui_accept", REMOTE), "completed")
	_t.check(popup._trade_players[0].visible, "and lists the receiver")
	_t.check(popup.together_menu() == ["give"], "the list goes to the host with the cursor")
	local.last_intent = {}
	yield(_t.tap("ui_accept", REMOTE), "completed")
	var sent: Dictionary = local.last_intent
	var slot: int = RunData.get_player_items_ref(REMOTE).find(own)
	_t.check(
		sent.get("kind") == ITEM and sent.get("slot") == slot and sent.get("id") == own.my_id,
		"picking the player sends the trade to the host (%s)" % [sent]
	)
	_t.check(
		sent.get("arg") == 0 and sent.get("seq") == _states.start.seqs[REMOTE],
		"with the receiver and the panel's revision"
	)
	_t.check(_t.ledger() == before, "nothing changed hands here")
	_t.check(not popup._focused, "the popup closed like after any decision")
	local.last_intent = {}
	popup.emit_signal("trade_requested", own, 0)
	_t.check(
		local.last_intent.hash() == sent.hash(),
		"a second trade before the host's answer leaves with the same revision (%s)" % [sent]
	)

	var weapon = RunData.get_player_weapons_ref(REMOTE)[1]
	popup.emit_signal("trade_requested", weapon, 0)
	sent = local.last_intent
	_t.check(
		sent.get("kind") == WEAPON and sent.get("slot") == 1 and sent.get("arg") == 0,
		"a weapon leaves as its own kind (%s)" % [sent]
	)
	local.last_intent = {}
	_shop._get_item_popup(0).emit_signal("trade_requested", theirs, REMOTE)
	_t.check(local.last_intent.empty(), "another player's popup sends nothing")
	_t.check(_t.ledger() == before, "and still nothing changed here")

	# A reroll changes the own player's data (gold) but not its gear: the client's run keeps its
	# item objects but gets fresh weapons, the gear rows keep their elements and what those show.
	_receive(_states.rerolled)
	yield(_t.frames(2), "completed")
	var shown = _element(REMOTE, own).item
	var shown_weapon = _weapon_element(REMOTE, 1).item
	_t.check(
		RunData.get_player_items_ref(REMOTE).has(shown)
		and not RunData.get_player_weapons_ref(REMOTE).has(shown_weapon),
		"(after a reroll the weapon row shows an object the run has no more, the items not)"
	)
	_t.check(_shop.trade_receivers(shown, REMOTE) == [0], "the old element still offers Trade")
	_t.check(_shop.trade_receivers(shown_weapon, REMOTE) == [0], "an old weapon element too")
	local.last_intent = {}
	popup.emit_signal("trade_requested", shown, 0)
	sent = local.last_intent
	slot = RunData.get_player_items_ref(REMOTE).find(_owned(REMOTE, _plain.my_id))
	_t.check(
		slot >= 0 and sent.get("slot") == slot and sent.get("id") == _plain.my_id,
		"a trade from it names the player's own item (%s)" % [sent]
	)
	local.last_intent = {}
	popup.emit_signal("trade_requested", shown_weapon, 0)
	sent = local.last_intent
	var weapons: Array = RunData.get_player_weapons_ref(REMOTE)
	var at: int = sent.get("slot", -1)
	_t.check(
		sent.get("kind") == WEAPON and at >= 0 and at < weapons.size(),
		"and one from the weapon names one of the player's weapons (%s)" % [sent]
	)
	_t.check(
		at >= 0 and at < weapons.size() and weapons[at].my_id == shown_weapon.my_id,
		"with the same id"
	)
	_t.check(_t.ledger() == before, "nothing changed hands here either")
	yield(_client_buy(popup), "completed")

	# A host without brotato:trade does not name the kinds: no Trade on this client.
	var plain_host: Dictionary = _states.start.duplicate()
	plain_host.kinds = []
	_receive(plain_host)
	own = _owned(REMOTE, _plain.my_id)
	_t.check(_shop.trade_receivers(own, REMOTE).empty(), "a host without trading: nothing offered")
	_t.check(not popup.will_show_buttons_when_focused(own), "and an item has no popup buttons again")
	var offers: Array = _shop._get_shop_items_container(REMOTE)._shop_items
	_t.check(
		not _shop.trade_buy_offered(offers[0], REMOTE), "nor can an offered item be bought for another"
	)
	_receive(_states.start)
	own = _owned(REMOTE, _plain.my_id)
	_t.check(_shop.trade_receivers(own, REMOTE) == [0], "trading is back with it")

	_receive(_states.traded)
	yield(_t.frames(2), "completed")
	_t.check(_t.ledger() == _host_ledger, "the host's state brings the trades to the client")
	_t.check(
		_count(0, _plain) == 1 and RunData.get_player_weapons_ref(0).size() == 1,
		"the receiver has the item and the weapon"
	)
	_t.check(
		_row_has(0, _plain) and _row_has(REMOTE, _plain), "and both panels show what each has now"
	)
	_t.check(
		_shop._get_gear_container(REMOTE).weapons_container._elements.get_child_count() == 1,
		"the giver's weapon row has one weapon left"
	)
	yield(_client_receive(popup), "completed")
	_client_mirror()


# The own give list is open when the host's state brings the own player an item from another.
func _client_receive(popup):
	var own = _owned(REMOTE, _plain.my_id)
	var element = _element(REMOTE, own)
	var emulator = Utils.get_focus_emulator(REMOTE, _shop)
	emulator.focused_control = element
	yield(_t.get_tree().create_timer(0.15), "timeout")
	yield(_pad(JOY_SELECT), "completed")
	var cursor = emulator.focused_control
	_t.check(popup._focused and popup._trade_choosing, "(the own give list is open)")
	_receive(_states.received)
	yield(_t.frames(2), "completed")
	_t.check(_count(REMOTE, _plain) == 2, "(the state brings a second copy of the item)")
	_t.check(
		popup._focused and popup._trade_choosing and emulator.focused_control == cursor,
		"an item from another player keeps the own give list open, its cursor where it was"
	)
	_t.check(
		is_instance_valid(element) and _shop._popup_manager._elements_pressed[REMOTE] == element,
		"on the same element"
	)
	_t.check(RunData.get_player_items_ref(REMOTE).has(popup._item_data), "holding the run's object")
	_sync.local.last_intent = {}
	yield(_t.tap("ui_accept", REMOTE), "completed")
	var sent: Dictionary = _sync.local.last_intent
	_t.check(
		sent.get("kind") == ITEM and sent.get("id") == _plain.my_id and sent.get("arg") == 0,
		"and still sends the trade (%s)" % [sent]
	)


# Player 1's open trade lists on this client's copy of its panel, from the host's state.
func _client_mirror() -> void:
	_receive(_states.traded)  # player 1 holds the plain item again (_client_receive took it)
	var other = _shop._get_item_popup(0)
	var element = _element(0, _plain)
	if element == null:
		_t.check(false, "(player 1 has an item to give)")
		return
	var before: String = _t.ledger()
	_sync.local.last_intent = {}
	var target: Array = FocusTargets.describe(element, _shop, 0)
	var body: Dictionary = _states.traded.duplicate(true)
	body.popups[0] = [target, _plain.my_id, 0, [["give"], null]]
	_receive(body)
	_t.check(
		(
			other._focused
			and other._trade_choosing
			and other._trade_players[0].get_meta("trade_to", -1) == REMOTE
		),
		"client: another player's give list shows on its panel here"
	)
	body.popups[0] = [target, _plain.my_id, 0, [null, null]]
	_receive(body)
	_t.check(
		other._focused and not other._trade_choosing and other._trade_button.visible,
		"back to its popup's buttons, Trade among them"
	)
	body.popups[0] = []
	_receive(body)
	_t.check(not other._focused, "and closed with the host's state")
	var nodes: Array = _shop._get_shop_items_container(0)._shop_items
	var node = _buyable(nodes, REMOTE)
	if node != null:
		body.popups[0] = [[], "", 0, [["buy", nodes.find(node)], null]]
		_receive(body)
		_t.check(
			other._focused and other.trade_buy_item() == node,
			"client: another player's buy-for list shows here"
		)
		body.popups[0] = []
		_receive(body)
		_t.check(not other._focused and other.trade_buy_item() == null, "and closes with it")
	_t.check(
		_sync.local.last_intent.empty() and _t.ledger() == before,
		"the copies send and trade nothing"
	)


# Trade with the mouse and the keyboard's T, then with the pad (LocalPanel: the own cursor).
func _client_buy(popup):
	var nodes: Array = _shop._get_shop_items_container(REMOTE)._shop_items
	var node = _buyable(nodes, 0)
	var theirs: Array = _shop._get_shop_items_container(0)._shop_items
	var emulator = Utils.get_focus_emulator(REMOTE, _shop)
	yield(_t.frames(2), "completed")
	emulator.focused_control = _shop._get_go_button(REMOTE)  # no gear popup over the offers
	yield(_hover(node._button), "completed")
	_t.check(
		emulator.focused_control == node._button and popup._trade_hint.visible,
		"the mouse on an own offer: its popup shows the trade hint"
	)
	_t.check(_glyph(popup) == Hotkey._icon("key_t.png"), "with the T glyph")
	_t.check(
		not Together.can_request_buy(_shop, 0), "another player's offers are not bought from here"
	)
	var before: String = _t.ledger()
	_sync.local.last_intent = {}
	yield(_key(KEY_T), "completed")
	_t.check(popup._focused and popup.trade_buy_item() == node, "T opens the buy-for list")
	yield(_click(popup._trade_players[0]), "completed")
	var sent: Dictionary = _sync.local.last_intent
	_t.check(
		sent.get("kind") == BUY and sent.get("slot") == nodes.find(node) and sent.get("arg") == 0,
		"a click on the player sends the buy to the host (%s)" % [sent]
	)
	_t.check(
		sent.get("id") == node.item_data.my_id and sent.get("seq") == _states.start.seqs[REMOTE],
		"naming the item and the panel's revision"
	)
	_t.check(_t.ledger() == before and node.active, "nothing bought here")
	_t.check(not popup._focused, "the popup closed")
	_t.check(emulator.focused_control == node._button, "the cursor is back on the item")
	_t.check(popup._trade_hint.visible, "its hint shows again")
	_sync.local.set_paused(true)
	yield(_t.get_tree().create_timer(0.15), "timeout")
	yield(_key(KEY_T), "completed")
	_t.check(not popup._focused, "while the host pauses the shop, T opens nothing")
	_sync.local.set_paused(false)
	yield(_pad(JOY_L3), "completed")
	_t.check(
		_glyph(popup) == Hotkey._icon("pad_xbox_view.png"), "a pad in the hand: the View glyph"
	)
	_sync.local.last_intent = {}
	yield(_t.get_tree().create_timer(0.15), "timeout")
	yield(_pad(JOY_SELECT), "completed")
	_t.check(popup._focused and popup.trade_buy_item() == node, "so does the pad's Back")
	yield(_t.tap("ui_accept", REMOTE), "completed")
	sent = _sync.local.last_intent
	_t.check(sent.get("kind") == BUY and sent.get("arg") == 0, "and accept sends the buy")
	yield(_client_give(popup), "completed")


# The trade key on the own gear: the give list at once.
func _client_give(popup):
	var own = _owned(REMOTE, _plain.my_id)
	var emulator = Utils.get_focus_emulator(REMOTE, _shop)
	emulator.focused_control = _element(REMOTE, own)
	yield(_t.frames(1), "completed")
	_t.check(popup._trade_hint.visible, "the own item's popup shows the trade hint")
	_sync.local.last_intent = {}
	yield(_t.get_tree().create_timer(0.15), "timeout")
	yield(_pad(JOY_SELECT), "completed")
	_t.check(popup._focused and popup._trade_choosing, "Back on it opens the give list")
	yield(_t.tap("ui_accept", REMOTE), "completed")
	var sent: Dictionary = _sync.local.last_intent
	_t.check(
		sent.get("kind") == ITEM and sent.get("id") == own.my_id and sent.get("arg") == 0,
		"and accept sends the trade (%s)" % [sent]
	)
	emulator.focused_control = _element(REMOTE, own)
	var field := LineEdit.new()
	_shop.add_child(field)
	field.grab_focus()
	yield(_t.get_tree().create_timer(0.15), "timeout")
	yield(_key(KEY_T), "completed")
	_t.check(not popup._focused, "T while a text field has the focus: typing, no trade")
	field.queue_free()
	yield(_t.frames(1), "completed")


func _buyable(nodes: Array, to: int):
	for node in nodes:
		if node.active and node.item_data != null and not node.item_data.is_meca:
			if _shop.trade_buy_room(node, to):
				return node
	return null


# The mouse moves onto the control and clicks it (window coordinates, like a real one): on a
# client LocalPanel turns that into the own cursor and its accept.
func _click(control: Control):
	var at: Vector2 = control.get_global_transform_with_canvas().xform(control.rect_size / 2.0)
	at = control.get_viewport().get_final_transform().xform(at)
	for step in ["move", "down", "up"]:
		var event: InputEventMouse = InputEventMouseMotion.new()
		if step != "move":
			event = InputEventMouseButton.new()
			event.button_index = BUTTON_LEFT
			event.pressed = step == "down"
		event.position = at
		event.global_position = at
		Input.parse_input_event(event)
		yield(_t.frames(3), "completed")


func _capture(name: String) -> void:
	var body: Dictionary = _sync.state_body(_section)
	body["you"] = REMOTE
	_states[name] = body


# Through the client's stream, like a state from the host.
func _receive(body: Dictionary) -> void:
	var stream: Node = _sync.state_stream
	var revision: int = stream._revs.get(_section, 0)
	stream.receive(bytes2var(var2bytes([_section, revision, body]), false))


func _intent(kind: String, slot: int, id: String, to: int, seq_offset := 0) -> Dictionary:
	_sync._update_seqs(_shop)
	var intent := {
		"shop_id": _sync._shop_id,
		"seq": _sync._seqs[REMOTE] + seq_offset,
		"kind": kind,
		"slot": slot,
		"id": id,
		"arg": to,
	}
	return bytes2var(var2bytes(intent), false)


func _apply(kind: String, slot: int, id: String, to: int, seq_offset := 0) -> bool:
	return _sync.host_apply_intent(_shop, REMOTE, _intent(kind, slot, id, to, seq_offset))


static func _wire(value):
	return bytes2var(var2bytes(value), false)


func _held(player: int, item) -> int:
	if item is WeaponData:
		return _t.ids(RunData.get_player_weapons_ref(player)).count(item.my_id)
	return _count(player, item)


func _count(player: int, item) -> int:
	return RunData.get_nb_item(item.my_id_hash, player, false)


# The player's own object with that id (a client's objects are its own copies of the host's).
func _owned(player: int, my_id: String):
	return _t.find(RunData.get_player_items_ref(player), my_id)


func _element(player: int, item):
	var row: Node = _shop._get_gear_container(player).items_container._elements
	for element in row.get_children():
		if not element.is_queued_for_deletion() and element.item != null:
			if element.item.my_id == item.my_id:
				return element
	return null


func _weapon_element(player: int, index: int):
	var row: Node = _shop._get_gear_container(player).weapons_container._elements
	var shown := []
	for element in row.get_children():
		if not element.is_queued_for_deletion():
			shown.append(element)
	return shown[index] if index < shown.size() else null


func _row_has(player: int, item) -> bool:
	return _element(player, item) != null


func _glyph(popup):
	var hint = popup._trade_hint
	return hint._key_icon.texture if hint.visible and hint._key_icon.visible else null


# The mouse onto the control, as a real one moves (LocalPanel puts the own cursor there).
func _hover(control: Control):
	var at: Vector2 = control.get_global_transform_with_canvas().xform(control.rect_size / 2.0)
	at = control.get_viewport().get_final_transform().xform(at)
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	Input.parse_input_event(event)
	yield(_t.frames(3), "completed")


func _key(scancode: int):
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.scancode = scancode
		event.physical_scancode = scancode
		event.pressed = pressed
		Input.parse_input_event(event)
		yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")


# A pad of this computer: device 0, whatever slot the client's own player has.
func _pad(button: int):
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = 0
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)
		yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
