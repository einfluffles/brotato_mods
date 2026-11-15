extends Reference
# brotato:trade next to brotato:together (this process loads both). Host: a remote player's
# trade arrives as a shop intent and is applied once, by the same code as a local one.
# Client: the own panel offers Trade when the host handles it, a press only sends the intent,
# and the host's next state shows the result.

const TOGETHER_DIR := "res://mods-unpacked/einfluffles-BrotatoTogether/"
const FAKE_PEER := 4242
const REMOTE := 1  # the remote player's slot on the host, the client's own player later
const ITEM := "trade.item"
const WEAPON := "trade.weapon"

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


# --- host: player 0 is local, player 1 remote (a virtual device) ---


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
	_t.check(_sync._kinds() == [ITEM, WEAPON], "the host takes trades as shop intents")
	_capture("start")
	_t.check(_states.start.get("kinds") == [ITEM, WEAPON], "and its state says so")

	var before: String = _t.ledger()
	var slot: int = RunData.get_player_items_ref(REMOTE).find(_plain)
	_t.check(not _apply(ITEM, slot, "item_none", 0), "a request naming another item is dropped")
	_t.check(not _apply(ITEM, 99, _plain.my_id, 0), "one from an empty place too")
	_t.check(not _apply(ITEM, slot, _plain.my_id, REMOTE), "nothing is given to oneself")
	_t.check(not _apply(ITEM, slot, _plain.my_id, 7), "nor to a player who is not there")
	var unique_slot: int = RunData.get_player_items_ref(REMOTE).find(_unique)
	_t.check(not _apply(ITEM, unique_slot, _unique.my_id, 0), "nor a unique item to its owner")
	_t.check(not _apply(ITEM, slot, _plain.my_id, 0, -1), "a request on an old panel is dropped")
	_t.check(_t.ledger() == before, "dropped requests change nothing")

	var request := _intent(ITEM, slot, _plain.my_id, 0)
	_t.check(_sync.host_apply_intent(_shop, REMOTE, request), "a remote player's trade is applied")
	_t.check(
		_count(0, _plain) == 1 and _count(REMOTE, _plain) == 1, "one of its two copies changed hands"
	)
	_t.check(
		not _sync.host_apply_intent(_shop, REMOTE, request),
		"the same request arriving twice is applied once"
	)
	_t.check(_count(0, _plain) == 1 and _t.ledger() == before, "no second copy, nothing lost")
	_t.check(_row_has(0, _plain), "the host's panels show it")

	var weapon = RunData.get_player_weapons_ref(REMOTE)[1]
	request = _intent(WEAPON, 1, weapon.my_id, 0)
	_t.check(_sync.host_apply_intent(_shop, REMOTE, request), "a weapon trade is applied")
	_t.check(not _sync.host_apply_intent(_shop, REMOTE, request), "and only once")
	var sizes := [
		RunData.get_player_weapons_ref(0).size(), RunData.get_player_weapons_ref(REMOTE).size()
	]
	_t.check(sizes == [1, 1], "one weapon each now (%s)" % [sizes])
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
	input.devices.erase(FAKE_PEER)


# --- client: the same shop as the host sent it, the own player is the giver ---


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

	# The whole way with the own buttons: element, Trade, the player.
	emulator.focused_control = _element(REMOTE, own)
	yield(_t.tap("ui_accept", REMOTE), "completed")
	_t.check(popup._focused and popup._trade_button.visible, "the own popup has Trade")
	emulator.focused_control = popup._trade_button
	yield(_t.tap("ui_accept", REMOTE), "completed")
	_t.check(popup._trade_players[0].visible, "and lists the receiver")
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

	# A host without brotato:trade does not name the kinds: no Trade on this client.
	var plain_host: Dictionary = _states.start.duplicate()
	plain_host.kinds = []
	_receive(plain_host)
	own = _owned(REMOTE, _plain.my_id)
	_t.check(_shop.trade_receivers(own, REMOTE).empty(), "a host without trading: nothing offered")
	_t.check(not popup.will_show_buttons_when_focused(own), "and an item has no popup buttons again")
	_receive(_states.start)
	own = _owned(REMOTE, _plain.my_id)
	_t.check(_shop.trade_receivers(own, REMOTE) == [0], "trading is back with it")

	# The host's answer: its state after both trades.
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


# --- helpers ---


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


func _row_has(player: int, item) -> bool:
	return _element(player, item) != null
