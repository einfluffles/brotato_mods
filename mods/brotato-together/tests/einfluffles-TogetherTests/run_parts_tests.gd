extends Reference
# Suite run_parts: the run state of the shop and of the level-up panels travels in parts, and
# each client gets only the parts it lacks (sync/run_parts.gd). On a host stream of its own (a
# fake session with two peers, stepped by hand) with the real co-op shop and the host's battle
# with its panels, in late endless runs with 2 and 4 players (250 items each):
# - a page flip or a Go flag sends no run part, not even its ids (under 1 KB on the wire); a
#   purchase by player 0 sends exactly c, p0 and g0, a (paid) reroll c and p0, a level-up choice
#   p<p> only;
# - a client's store builds the same run state as the whole text did (its parts joined and
#   printed equal RunStateCodec.encode_json), keeps the PlayerRunData objects of the players
#   that did not change and names the ones that did;
# - peer_ready sends every part to that peer and only the change to the other; message_for
#   records nothing; a body replaced while pending leaves the store complete; a missing part
#   asks the host for a resync and applies nothing; the shop's counters for its log line.
# Prints the bytes per page flip, Go, lock, reroll, purchase and level-up choice, the host's
# time per change and a client's time per changed state, before (the whole run in every body,
# parsed and deserialized whole) and now.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const ShopChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_change_tests.gd"
)
const UpgradesChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/upgrades_change_tests.gd"
)
const P1 := 4646
const P2 := 4747
const LATE_ITEMS := 250
const GOLD := 1000000
const VIEW_LIMIT := 1024  # bytes on the wire for a change that moves no run part

var _t: Node = null
var _together: Node = null
var _stream: Node = null  # the host stream of this suite
var _provider: Node = null  # ShopSync or UpgradesSync
var _store = null  # what the client P1 has (RunParts.Store)
var _state := {}  # the run state P1's store built last
var _numbers := []  # [change, bytes before, now, host usec before, now, client before, now]


# Holds every body (a shop that is still loading) until told otherwise; stores the run parts as
# they arrive, like ShopSync and UpgradesSync.
class Holder:
	extends Reference
	var store = null
	var accept := false
	var applied := []  # the bodies applied, with whether the store had all their parts

	func accept_state(_section: int, body, _revision: int) -> void:
		store.take(body.get("run"), "test")

	func apply_state(_section: int, body, _revision: int) -> bool:
		if accept:
			applied.append([body, not store.state_for(body.run.ids).empty()])
		return accept


func run(t: Node, together: Node):
	_t = t
	_together = together
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	var saved_colors: Array = CoopService.bt_slot_colors.duplicate()
	var saved_holding: bool = ProgressData.settings.holding_button
	ProgressData.settings.holding_button = false
	together.shop_sync.set_process(false)  # driven by hand (no Steam session)
	together.battle_host.set_process(false)
	for players in [2, 4]:
		_numbers = []
		yield(_shop(players), "completed")
		yield(_panels(players), "completed")
		_print_numbers(players)
	var panel_tests = _panel_tests()
	yield(panel_tests._blank_scene(), "completed")
	ProgressData.settings.holding_button = saved_holding
	CoopService.connected_players = saved_players
	CoopService.bt_slot_colors = saved_colors
	together.shop_sync.set_process(true)
	together.battle_host.set_process(true)


# --- the shop ---


func _shop(players: int):
	yield(_panel_tests()._blank_scene(), "completed")  # no battle may see the new run's players
	var provider_node: Node = _together.shop_sync
	var tests = ShopChangeTests.new()
	tests._t = _t
	tests._sync = provider_node
	tests._cache = provider_node.run_cache
	tests._build_run(players, LATE_ITEMS)
	for p in players:
		RunData.add_gold(GOLD, p)
	yield(tests._enter_shop(), "completed")
	var shop: Node = tests._shop
	var label: String = "%d players" % players
	_start(StateStream.RUN_SHOP, provider_node)
	_first(label)
	_test_message_for(provider_node)

	var panel = shop._get_coop_player_container(0)
	panel.carousel.index = 1
	_change("page flip", [])
	panel.carousel.index = 0
	_change("page back", [])
	FocusEmulatorSignal.emit(shop._get_go_button(0), "pressed", 0)
	_change("Go", [])
	shop._clear_go_button_pressed(0)
	_change("Go cleared", [])
	var node = tests._offered(0)
	if node.item_data.is_lockable:
		node.change_lock_status(true)
		_change("lock", null)
		node.change_lock_status(false)
		_change("unlock", null)
	shop._free_rerolls[0] = 0  # a paid reroll
	shop._reroll_price[0] = int(max(shop._reroll_price[0], 1))
	FocusEmulatorSignal.emit(shop._get_reroll_button(0), "pressed", 0)
	yield(_frames(1), "completed")
	var before: Array = _state.players_data.duplicate()
	_change("reroll", ["c", "p0"])
	_check_players(label + ", reroll", before, false)
	yield(tests._buy_delay(), "completed")
	FocusEmulatorSignal.emit(tests._offered(0)._button, "pressed", 0)
	yield(_frames(1), "completed")
	before = _state.players_data.duplicate()
	_change("purchase", ["c", "g0", "p0"])
	_check_players(label + ", purchase", before, true)
	yield(tests._buy_delay(), "completed")

	_test_peer_ready(provider_node, label)
	_test_pending(provider_node, label)
	_test_missing(provider_node, label)
	_test_close(provider_node, label)
	_end_stream()


# message_for builds what the peer would get now and records nothing: twice the same parts.
func _test_message_for(provider_node: Node) -> void:
	var record := var2str(provider_node.run_sender.sent_to(P1))
	RunData.add_gold(1, 0)
	var first: Array = _stream.message_for(StateStream.RUN_SHOP, P1)
	var again: Array = _stream.message_for(StateStream.RUN_SHOP, P1)
	_t._check(
		(
			first[2].run.parts.keys() == ["p0"]
			and again[2].run.parts.keys() == ["p0"]
			and var2str(provider_node.run_sender.sent_to(P1)) == record
		),
		"run parts: message_for records nothing (%s)" % [first[2].run.parts.keys()]
	)
	_change("gold", ["p0"])


# peer_ready: the providers forget what the peer has, the stream's resync (its next step) sends
# that peer every part; a change made meanwhile goes to the other peer as that change only.
func _test_peer_ready(provider_node: Node, label: String) -> void:
	provider_node._on_peer_ready(P2)
	_together.upgrades_sync._on_peer_ready(P2)  # both providers forget it, in one emission
	_stream.session.emit_signal("peer_ready", P2)
	RunData.add_gold(1, 0)
	_stream.step(0.0)
	var sent := _take()
	var parts := {}
	for message in sent:
		parts[message[0]] = message[1][2].run.get("parts", {}).keys()
	_t._check(
		(
			sent.size() == 2
			and parts.get(P1) == ["p0"]
			and parts.get(P2, []).size() == provider_node.run_cache.parts.size()
		),
		"run parts, %s: peer_ready sends that peer every part, the other the change (%s)"
		% [label, parts]
	)
	for message in sent:
		if message[0] == P1:
			_ingest(message[1][2])


# A body replaced while it is pending (the shop still loading) is never applied: its parts were
# stored as it arrived, so the newer body, which only names them, still finds them.
func _test_pending(provider_node: Node, label: String) -> void:
	var client: Node = _client_stream()
	var holder := Holder.new()
	holder.store = RunParts.Store.new()
	client.register_handler(StateStream.RUN_SHOP, holder)
	holder.store.ingest(provider_node.run_cache.all())  # what P2 has since its resync
	var applied_only = RunParts.Store.new()  # a store fed at apply time instead
	applied_only.ingest(provider_node.run_cache.all())
	var bodies := []
	for p in 2:
		RunData.add_gold(1, p)
		_stream.step(1.0)
		var sent := _take()
		_ingest(_message_to(P1, sent)[2])  # P1 stays up to date
		bodies.append(_message_to(P2, sent))
		client.receive(bodies[p])
	holder.accept = true
	client.step(0.016)
	var applied: Array = holder.applied[0] if holder.applied.size() == 1 else [{}, false]
	_t._check(
		(
			bodies[0][2].run.parts.keys() == ["p0"]
			and bodies[1][2].run.parts.keys() == ["p1"]
			and var2str(applied[0].get("run")) == var2str(bodies[1][2].run)
			and applied[1]
		),
		"run parts, %s: a body replaced while pending leaves the store complete" % label
	)
	_t._check(
		not applied_only.ingest(bodies[1][2].run),
		"run parts, %s: (a store fed at apply time would lack the replaced body's part)" % label
	)
	client.session.free()
	client.free()


# A body that names a part the client has neither stored nor been sent: the host is asked for a
# full resync (Session.ask_resync) and the shop applies nothing of the body.
func _test_missing(provider_node: Node, label: String) -> void:
	RunData.add_gold(1, 0)
	_stream.step(1.0)
	var message := _message_to(P1, _take())
	_ingest(message[2])
	var lacking = RunParts.Store.new()
	var session := StateStreamTests.FakeSession.new()
	lacking.session = session
	var saved = provider_node.run_store
	var state: Dictionary = provider_node._state
	var shop_id: int = provider_node._client_shop_id
	provider_node.run_store = lacking
	provider_node.accept_state(StateStream.RUN_SHOP, message[2], message[1])
	var dropped = provider_node.apply_state(StateStream.RUN_SHOP, message[2], message[1])
	provider_node.run_store = saved
	_t._check(
		(
			session.resyncs_asked == 1
			and lacking.misses >= 1
			and dropped == true
			and provider_node._state == state
			and provider_node._client_shop_id == shop_id
			and not provider_node.is_in_shop()
		),
		"run parts, %s: a missing part asks for a resync and applies nothing" % label
	)
	session.free()


# The shop's counters: what went out, for the line logged when it closes (then they start over).
func _test_close(provider_node: Node, label: String) -> void:
	var sender = provider_node.run_sender
	var stats = sender.stats.get("shop", {})
	var copy: Dictionary = stats.duplicate(true)
	_t._check(
		stats.get("states", 0) > 0 and stats.states > stats.run_states and stats.parts.has("p0"),
		"run parts, %s: the shop counts its states (%s)" % [label, stats]
	)
	provider_node._host_shop = null
	provider_node.state_key(StateStream.RUN_SHOP)
	_t._check(
		not sender.stats.has("shop") and provider_node.run_cache.parts.empty(),
		"run parts, %s: the shop closed: logged once, cache and counters start over" % label
	)
	sender.stats["shop"] = copy
	print("  info: run parts, %s: shop log line: %s" % [label, sender.summary("shop")])


# --- the level-up panels ---


func _panels(players: int):
	var provider_node: Node = _together.upgrades_sync
	var tests = _panel_tests()
	yield(tests._blank_scene(), "completed")  # the old scene must not see the new run's players
	tests._build_run(players, LATE_ITEMS)
	yield(tests._enter_battle(), "completed")
	var crates := []
	var levels := []
	for p in players:
		crates.append([])
		levels.append([tests._level(p, 30)])
	tests._show(crates, levels)
	_start(StateStream.UPGRADES, provider_node)
	_first("%d players, panels" % players)
	yield(tests._button_delay(), "completed")
	var p: int = players - 1
	var container = tests._ui._get_player_container(p)
	var choose: Dictionary = tests._intent(p, "choose", container._old_upgrades[0].my_id)
	var chosen: bool = provider_node.host_apply_intent(tests._ui, p, choose)
	_t._check(chosen, "run parts: level-up choice applied")
	var before: Array = _state.players_data.duplicate()
	_change("level-up choice", ["p%d" % p])
	_check_players("%d players, level-up choice" % players, before, false, p)
	_end_stream()
	provider_node.run_sender.close(provider_node.run_cache)


func _panel_tests():
	var tests = UpgradesChangeTests.new()
	tests._t = _t
	tests._together = _together
	tests._sync = _together.upgrades_sync
	tests._cache = _together.upgrades_sync.run_cache
	return tests


# --- helpers ---


func _start(section: int, provider: Node) -> void:
	var session := StateStreamTests.FakeSession.new()
	session.transport = StateStreamTests.FakeTransport.new()
	session.peers[P1] = {"ready": true}
	session.peers[P2] = {"ready": true}
	_stream = StateStream.new()
	_stream.setup(session)
	_stream.register_provider(section, provider, provider.CHECK_INTERVAL)
	_provider = provider
	provider.state_stream = _stream  # host_apply_intent flushes this one
	provider.run_cache.clear()  # as when the screen comes up
	_store = RunParts.Store.new()
	_state = {}


func _end_stream() -> void:
	_provider.state_stream = _together.state_stream
	var session: Node = _stream.session
	_stream.free()
	session.free()
	_stream = null


func _client_stream() -> Node:
	var session := StateStreamTests.FakeSession.new()
	session.transport = StateStreamTests.FakeTransport.new()
	session.host = false
	var stream: Node = StateStream.new()
	stream.setup(session)
	return stream


# The first check: every part to both peers (records of earlier runs name other content).
func _first(label: String) -> void:
	_provider.run_sender.forget(P1)
	_provider.run_sender.forget(P2)
	_stream.step(1.0)
	var sent := _take()
	var all: int = _provider.run_cache.parts.size()
	var complete := sent.size() == 2
	for message in sent:
		complete = complete and message[1][2].run.parts.size() == all
	_t._check(complete and all > 1, "run parts, %s: the first state carries every part" % label)
	var body: Dictionary = _message_to(P1, sent)[2] if complete else {}
	_t._check(_ingest(body), "run parts, %s: the client builds the first state" % label)
	_check_join(label + ", first state")


# One check of the host stream after a change: both peers get it, the parts are the expected
# ones (sorted; null: any), P1's store builds the same run as the whole text. Measured.
func _change(change: String, expected) -> void:
	var started := OS.get_ticks_usec()
	_stream.step(1.0)
	var host := OS.get_ticks_usec() - started
	var sent := _take()
	var message := _message_to(P1, sent)
	if sent.size() != 2 or message.empty():
		_t._check(false, "run parts: %s goes out to both peers (%d sent)" % [change, sent.size()])
		return
	var body: Dictionary = message[2]
	var keys: Array = body.run.get("parts", {}).keys()
	keys.sort()
	if expected != null:
		_t._check(keys == expected, "run parts: %s carries %s (%s)" % [change, expected, keys])
	var now := Protocol.encode(Protocol.Msg.STATE, message).size()
	if keys.empty():
		_t._check(now < VIEW_LIMIT, "run parts: %s is %d B on the wire" % [change, now])
	var whole: Dictionary = body.duplicate()
	started = OS.get_ticks_usec()
	whole.run = RunStateCodec.encode(_args())
	var host_before := OS.get_ticks_usec() - started
	var before := Protocol.encode(Protocol.Msg.STATE, [message[0], message[1], whole]).size()
	started = OS.get_ticks_usec()
	RunStateCodec.deserialize(RunStateCodec.parse(whole.run))
	var client_before := OS.get_ticks_usec() - started
	started = OS.get_ticks_usec()
	var built: bool = _ingest(body) if not keys.empty() else _store.ingest(body.run)
	var client := OS.get_ticks_usec() - started
	_t._check(built, "run parts: the client builds the state after %s" % change)
	_check_join(change)
	if keys.empty():
		_numbers.append([change, before, now, -1, -1, -1, -1])
	else:
		_numbers.append([change, before, now, host_before, host, client_before, client])


# P1's store takes the body's parts and builds its run state (as a handler does on a change).
func _ingest(body: Dictionary) -> bool:
	if body.empty() or not _store.ingest(body.run):
		return false
	_state = _store.state_for(body.run.ids)
	return not _state.empty() and _state.get("has_run_state", false)


# The shop's save arguments while the shop is the provider, else none (the panels).
func _args() -> Array:
	var shop_sync: Node = _together.shop_sync
	return shop_sync.shop_args(shop_sync._host_shop) if _provider == shop_sync else []


# The client's parts joined and printed are the host's whole run state as JSON.
func _check_join(label: String) -> void:
	var ids: Dictionary = _store._ids
	var text := JSON.print(RunParts.join(_store.raws(ids)))
	var expected := RunStateCodec.encode_json(_args())
	_t._check(
		text == expected,
		"run parts: after %s the client's parts make the host's run (%d / %d B of JSON)"
		% [label, text.length(), expected.length()]
	)


# After a change of player changed only (-1: player 0): its PlayerRunData is new, the others
# keep theirs; the store names it, and its gear when gear.
func _check_players(label: String, before: Array, gear: bool, changed := 0) -> void:
	var players: Array = _state.players_data
	var kept := players.size() == before.size()
	for p in min(players.size(), before.size()):
		kept = kept and (players[p] == before[p]) == (p != changed)
	_t._check(
		(
			kept
			and _store.changed_players() == [changed]
			and _store.gear_changed(changed) == gear
		),
		"run parts, %s: only player %d rebuilt (gear: %s), the others keep their objects"
		% [label, changed, gear]
	)


func _print_numbers(players: int) -> void:
	for entry in _numbers:
		var text: String = (
			"  info: run parts, late run, %d players, %s: %d B per client (before %d B)"
			% [players, entry[0], entry[2], entry[1]]
		)
		if entry[3] >= 0:
			text += (
				"; host %d usec (before %d); client %d usec (before %d)"
				% [entry[4], entry[3], entry[6], entry[5]]
			)
		print(text)


# [section, revision, body] the host sent the peer (empty when none).
static func _message_to(peer: int, sent: Array) -> Array:
	for message in sent:
		if message[0] == peer:
			return message[1]
	return []


# What the host stream sent since the last call, as [steam_id, [section, revision, body]].
func _take() -> Array:
	var messages := []
	for sent in _stream.session.sent:
		if sent[1] == Protocol.Msg.STATE:
			messages.append([sent[0], sent[2]])
	_stream.session.sent.clear()
	return messages


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")
