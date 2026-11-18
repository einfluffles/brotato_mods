extends Reference
# The crate trade next to brotato:together (this process loads both), on the host's battle
# scene with its crate panels up. Host: a remote player's crate trade arrives as an
# UPGRADE_INTENT of kind trade.crate and is applied once, by the same code as a local one.
# Client (its side of UpgradesSync set up by hand on the same panels, puppet mode on): its own
# panel offers Trade when the host handles it, a press only sends the intent.

const KIND := "trade.crate"
const REMOTE := 1  # the remote player on the host, the client's own player later

var _t: Node = null
var _sync: Node = null
var _host: Node = null
var _ui: Node = null
var _unique = null
var _plain = null


func run(t: Node):
	_t = t
	yield(t.get_tree(), "idle_frame")
	var together: Node = t.get_node_or_null(t.TOGETHER)
	t.check(together != null, "brotato:together is loaded (shards.txt: +brotato-together)")
	if together == null:
		return
	_sync = together.upgrades_sync
	_host = together.battle_host
	_host.set_process(false)  # driven by hand (no Steam session)
	t.coop_run(2)
	_unique = t.item_with_limit(1)
	_plain = t.item_with_limit(-1)
	var main = yield(t.open_battle(), "completed")
	_host._start_battle(main)
	_ui = main.get("_coop_upgrades_ui")
	t.show_crates(_ui, [0, 2])
	yield(t.frames(2), "completed")
	_panel(REMOTE).show_item(_unique)
	_host_part()
	_client_part()
	_ui.hide()
	_host._end_battle()
	_host.set_process(true)


func _host_part() -> void:
	_t.check(KIND in _sync._kinds(), "the host takes crate trades as level-up intents")
	_t.check(KIND in _sync.body(_sync.capture(_ui)).get("kinds", []), "and its state says so")
	var before: String = _t.ledger()
	_t.check(not _apply("item_none", 0), "a request naming another crate item is dropped")
	_t.check(not _apply(_unique.my_id, REMOTE), "nothing is given to oneself")
	_t.check(not _apply(_unique.my_id, 7), "nor to a player who is not there")
	_t.check(not _apply(_unique.my_id, 0, -1), "a request on an old panel is dropped")
	_t.check(_t.ledger() == before, "dropped requests change nothing")
	var request := _intent(_unique.my_id, 0)
	_t.check(_sync.host_apply_intent(_ui, REMOTE, request), "a remote player's crate trade is applied")
	_t.check(
		_count(0, _unique) == 1 and _count(REMOTE, _unique) == 0,
		"the crate item went to the other player"
	)
	_t.check(
		not _sync.host_apply_intent(_ui, REMOTE, request),
		"the same request arriving twice is applied once"
	)
	_t.check(_count(0, _unique) == 1, "no second copy")
	_t.check(
		_panel(REMOTE)._items_container.visible and _panel(REMOTE)._item_data != null,
		"the remote player's panel shows its next crate"
	)


func _client_part() -> void:
	var panel = _panel(REMOTE)
	panel.show_item(_plain)
	_sync._guard(_ui, REMOTE)
	_sync._local_active = true
	_sync._own_seq = 9
	_sync._host_kinds = [KIND]
	var puppet_mode = load("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
	puppet_mode.set_active(true)
	_t.check(_ui.trade_crate_offered(REMOTE), "a client's own crate panel offers Trade")
	_t.check(not _ui.trade_crate_offered(0), "another player's panel does not")
	var before: String = _t.ledger()
	_t.check(not _ui.trade_crate(REMOTE, 0), "the copy of the panels gives nothing itself")
	_sync.last_intent = {}
	panel._on_trade_button_pressed()
	_t.check(panel.trade_is_choosing(), "Trade lists the receiver")
	panel._on_trade_player_pressed(0)
	var sent: Dictionary = _sync.last_intent
	_t.check(
		sent.get("kind") == KIND and sent.get("id") == _plain.my_id and sent.get("arg") == 0,
		"picking the player sends the trade to the host (%s)" % [sent]
	)
	_t.check(sent.get("seq") == 9, "with the panel's revision")
	_t.check(_t.ledger() == before, "nothing changed hands here")
	_t.check(not panel.trade_is_choosing(), "the list closes")
	_sync._host_kinds = []
	_t.check(not _ui.trade_crate_offered(REMOTE), "a host without crate trades: no Trade")
	puppet_mode.set_active(false)
	_sync.stop_local("test over")
	_sync._guarded_ui = null
	_sync._own = null


# --- helpers ---


func _intent(id: String, to: int, seq_offset := 0) -> Dictionary:
	_sync._update_seqs(_ui, _sync.capture(_ui))
	var intent := {
		"battle_id": _host._battle_id,
		"seq": _sync._seqs[REMOTE] + seq_offset,
		"kind": KIND,
		"id": id,
		"meca": -1,
		"arg": to,
	}
	return bytes2var(var2bytes(intent), false)


func _apply(id: String, to: int, seq_offset := 0) -> bool:
	return _sync.host_apply_intent(_ui, REMOTE, _intent(id, to, seq_offset))


func _count(player: int, item) -> int:
	return RunData.get_nb_item(item.my_id_hash, player, false)


func _panel(player: int):
	return _ui._get_player_container(player)
