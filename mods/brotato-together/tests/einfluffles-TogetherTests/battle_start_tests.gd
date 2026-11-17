extends Reference
# Suite battle_start: BATTLE_START carries the run in parts, only those the client lacks
# (BattleHost._send_battle_start, sync/battle_run.gd; protocol 25). In late endless runs with 2
# and 4 players (250 items each), every player hurt in the last wave: the host's co-op shop
# sends its state to two peers on a fake session, every player presses Go, the host's battle
# starts on that session.
# - Each peer's BATTLE_START carries no "p" or "g" part (the run as the scene entered, before
#   main._ready healed the players), its run under RUN_LIMIT, the message under START_LIMIT. The
#   host watches the scene's entry (node_added) between battles only, while a peer is ready.
# - The client (BattleClient on a fake client session, its store fed by that shop state, as its
#   shop applied it) starts the battle from it: once its own main._ready ran, its RunData is the
#   host's (through the game's deserializer, as the whole run gave it before).
# - peer_ready: that peer gets every part again.
# - A start naming a part the client lacks asks for a resync and starts nothing.
# - A start queued while a scene loads applies its own ids, though newer versions of its parts
#   came in meanwhile.
# Prints the bytes of a BATTLE_START per client and what the client takes before change_scene,
# with the run's parse, deserialize and apply (ClientReport's marks).
# Left out of the test run (LEFT_OUT): the items Go takes (hourglass, lifeform scanner), whose
# owner's parts change after the last shop state, and the candy bag, whose random stats at wave
# start each main._ready rolls itself (the host's and the client's differ, before and now).

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const RunCache := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_cache.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const ShopChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_change_tests.gd"
)
const UpgradesChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/upgrades_change_tests.gd"
)
const HOST := 4545
const P1 := 4646
const P2 := 4747
const LATE_ITEMS := 250
const RUN_LIMIT := 2 * 1024
const START_LIMIT := 4 * 1024  # with the type table and weapon slots (1.6 to 1.9 KB here)
const LOAD_TIMEOUT_MSEC := 20000
const LEFT_OUT := ["item_hourglass", "item_lifeform_scanner", "item_candy_bag"]

var _t: Node = null
var _together: Node = null
var _host_session: Node = null  # the host's fake session (peers P1 and P2)
var _client_session: Node = null  # P1's fake session (the host is HOST)
var _store = null  # what P1 has (RunParts.Store)
var _entered_json := ""  # the client's run when its battle scene was ready


func run(t: Node, together: Node):
	_t = t
	_together = together
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	var saved_holding: bool = ProgressData.settings.holding_button
	ProgressData.settings.holding_button = false
	together.shop_sync.set_process(false)  # driven by hand (no Steam session)
	together.battle_host.set_process(false)
	for players in [2, 4]:
		yield(_run(players), "completed")
	yield(_panel_tests()._blank_scene(), "completed")
	ProgressData.settings.holding_button = saved_holding
	CoopService.connected_players = saved_players
	together.shop_sync.set_process(true)
	together.battle_host.set_process(true)


func _run(players: int):
	var label := "%d players" % players
	yield(_panel_tests()._blank_scene(), "completed")
	var shop_sync: Node = _together.shop_sync
	var shop_tests = ShopChangeTests.new()
	shop_tests._t = _t
	shop_tests._sync = shop_sync
	shop_tests._cache = shop_sync.run_cache
	shop_tests._build_run(players, LATE_ITEMS)
	for p in players:
		_leave_out(p)
		RunData.players_data[p].current_health = 1 + p  # hurt in the last wave
	yield(shop_tests._enter_shop(), "completed")
	_sessions()
	_shop_state(label)

	# Every player presses Go: the shop saves its state, the wave moves on, the battle loads (the
	# host's battle module on the fake session, whose peers became ready in the shop).
	var host: Node = _together.battle_host
	var saved_session: Node = host.session
	host.session = _host_session
	host._on_peer_ready(P1)
	host._on_peer_ready(P2)
	var tree: SceneTree = _t.get_tree()
	var watched: bool = tree.is_connected("node_added", host, "_on_node_added")
	var shop: Node = shop_tests._shop
	for p in players:
		FocusEmulatorSignal.emit(shop._get_go_button(p), "pressed", p)
	yield(_frames(2), "completed")
	var main: Node = _t.get_tree().current_scene
	var loaded: bool = main != null and main.filename == "res://main.tscn"
	_t._check(loaded, "%s: Go loads the battle" % label)
	if not loaded:
		host.session = saved_session
		_host_session.free()
		_client_session.free()
		return
	var started := OS.get_ticks_usec()
	host._start_battle(main)
	var host_usec := OS.get_ticks_usec() - started
	_t._check(
		watched and not tree.is_connected("node_added", host, "_on_node_added"),
		"%s: the host watches the battle scene's entry between battles only" % label
	)
	var host_run := RunStateCodec.encode()  # the run after the host's main._ready
	var whole_bytes := var2bytes(host_run).size()
	var starts := _take(Protocol.Msg.BATTLE_START)
	var start: Dictionary = starts.get(P1, {})
	var bytes := Protocol.encode(Protocol.Msg.BATTLE_START, start).size()
	var keys: Array = _parts_of(start)
	var run_bytes := var2bytes(start.get("run")).size()
	started = OS.get_ticks_usec()
	RunCache.new().refresh(host)  # what the host's entry hook does (now)
	var pack_usec := OS.get_ticks_usec() - started
	print(
		(
			"  info: battle start, late run, %s: BATTLE_START %d B per client (its run %d B, the"
			+ " whole run %d B), parts %s; host %d usec in _start_battle, the run in parts %d"
		)
		% [label, bytes, run_bytes, whole_bytes, keys, host_usec, pack_usec]
	)
	var players_parts := []
	for key in keys:
		if key.begins_with("p") or key.begins_with("g"):
			players_parts.append(key)
	_t._check(
		_has_ids(start) and players_parts.empty() and starts.size() == 2,
		"%s: after a shop state, BATTLE_START carries no p or g part (%s)" % [label, keys]
	)
	_t._check(
		run_bytes < RUN_LIMIT and bytes < START_LIMIT,
		"%s: BATTLE_START is %d B on the wire, its run %d B" % [label, bytes, run_bytes]
	)

	# peer_ready: every part to that peer.
	host._on_peer_ready(P2)
	var again: Dictionary = _take(Protocol.Msg.BATTLE_START).get(P2, {})
	var all: int = start.get("run", {}).get("ids", {}).size()
	var sent: int = _parts_of(again).size()
	_t._check(
		_has_ids(again) and all > 1 and sent == all,
		"%s: peer_ready sends that peer every part (%d of %d)" % [label, sent, all]
	)
	var queued: Dictionary = _queued_start(host)
	var newer: Dictionary = _newer_parts(host)
	host.session = saved_session
	host._end_battle()
	_t._check(
		not tree.is_connected("node_added", host, "_on_node_added"),
		"%s: nor once the battle ended without a ready peer" % label
	)

	# What the whole run gave a client before: the host's run after its main._ready, through
	# the game's deserializer and serializer.
	var state := RunStateCodec.decode(host_run)
	var expected := JSON.print(ProgressDataLoaderV3.new().serialize_run_state(state))
	yield(_client(label, start, expected, queued, newer), "completed")
	_host_session.free()
	_client_session.free()


# The shop's state goes to both peers (every part: their records are forgotten first); P1's
# store takes it and builds its state, as P1's shop does.
func _shop_state(label: String) -> void:
	var shop_sync: Node = _together.shop_sync
	var stream: Node = StateStream.new()
	stream.setup(_host_session)
	stream.register_provider(StateStream.RUN_SHOP, shop_sync, shop_sync.CHECK_INTERVAL, true)
	shop_sync.state_stream = stream
	shop_sync.run_cache.clear()
	shop_sync.run_sender.forget(P1)
	shop_sync.run_sender.forget(P2)
	stream.step(1.0)
	var states := _take(Protocol.Msg.STATE)
	var body = states.get(P1, [0, 0, null])[2]
	_store = RunParts.Store.new()
	_store.session = _client_session
	var taken: bool = body is Dictionary and _store.take(body.get("run"), "shop")
	var built: bool = taken and not _store.state_for(_store.ids_for(body.run)).empty()
	_t._check(built and states.size() == 2, "%s: the shop state reaches both peers" % label)
	shop_sync.state_stream = _together.state_stream
	stream.free()


# A start of the next battle that will arrive while the client loads this one: built and sent
# to P1 now, its run as it is now.
func _queued_start(host: Node) -> Dictionary:
	host._battle_id += 1
	RunData.add_gold(3, 0)
	var expected_gold: int = RunData.get_player_gold(0)
	var start: Dictionary = host._battle_start_body()
	host._send_battle_start(P1, start)
	_close(host)
	return {"body": _take(Protocol.Msg.BATTLE_START).get(P1, {}), "gold": expected_gold}


# Newer versions of the parts of the queued start (c and p0), as a state that reaches the
# client after it (a level-up choice, say) would deliver them.
func _newer_parts(host: Node) -> Dictionary:
	RunData.add_gold(5, 0)
	var start: Dictionary = host._battle_start_body()
	host._send_battle_start(P1, start)
	_close(host)
	return _take(Protocol.Msg.BATTLE_START).get(P1, {}).get("run", {})


func _client(label: String, start: Dictionary, expected: String, queued: Dictionary, newer):
	var client: Node = _together.battle_client
	var saved_session: Node = client.session
	var saved_store = client.get("run_store")
	client.session = _client_session

	# A store that lacks the players' parts: a resync is asked, nothing starts.
	var lacking = RunParts.Store.new()
	var asked := StateStreamTests.FakeSession.new()
	lacking.session = asked
	client.set("run_store", lacking)
	var battle_id: int = client._battle_id
	client._on_message(HOST, Protocol.Msg.BATTLE_START, start.duplicate(true))
	var started: bool = client._battle_id != battle_id or client._loading
	_t._check(
		asked.resyncs_asked == 1 and not started,
		"%s: a start naming a part the client lacks asks for a resync and starts nothing" % label
	)
	if started:
		yield(_entered(client), "completed")
		client._leave_battle()
	asked.free()

	# P1's store: the start runs. Once its scene is ready (the client's own main._ready started
	# the wave), the client's RunData is the host's.
	client.set("run_store", _store)
	for p in RunData.get_player_count():
		RunData.players_data[p].gold = 7  # the start must bring the host's back
	_entered_json = ""
	client.connect("battle_entered", self, "_on_battle_entered", [], CONNECT_ONESHOT)
	Puppet.set_active(true)  # its stash of the client's own save is not the run's cost
	var report: Node = _together.client_report
	var was_active: bool = report.active
	report.active = true  # its marks: run parse, deserialize, apply
	report._marks = report._no_marks()
	var begun := OS.get_ticks_usec()
	client._on_message(HOST, Protocol.Msg.BATTLE_START, start.duplicate(true))
	var usec := OS.get_ticks_usec() - begun
	var marks: Array = report._marks.duplicate()
	report.active = was_active
	print(
		(
			"  info: battle start, late run, %s: the client takes %d usec before change_scene"
			+ " (run parse %d, deserialize %d, apply %d)"
		)
		% [label, usec, marks[0], marks[1], marks[2]]
	)
	var running: bool = Puppet.is_active() and client._battle_id == start.get("battle_id")

	# The next start arrives while this scene loads (queued), then newer parts: the queued start
	# applies its own ids.
	client._on_message(HOST, Protocol.Msg.BATTLE_START, queued.body.duplicate(true))
	_store.take(newer.duplicate(true), "test")  # what a state after it delivers
	var queued_ids = queued.body.get("run", {}).get("ids")
	var waiting: bool = client._queued_start.get("battle_id") == queued.body.get("battle_id")
	yield(_entered(client), "completed")
	_t._check(
		running and _entered_json == expected,
		"%s: the client's RunData is the host's after the start (%s)"
		% [label, _differences(expected, _entered_json)]
	)
	var until := OS.get_ticks_msec() + LOAD_TIMEOUT_MSEC
	while client._battle_id != queued.body.battle_id and OS.get_ticks_msec() < until:
		yield(_t.get_tree(), "idle_frame")
	var own: bool = RunParts.same_ids(_store._ids, queued_ids)
	_t._check(
		waiting and own and RunData.get_player_gold(0) == queued.gold,
		(
			"%s: a start queued while a scene loads applies its own ids (gold %d, expected %d)"
			% [label, RunData.get_player_gold(0), queued.gold]
		)
	)
	yield(_entered(client), "completed")
	client._leave_battle()
	Puppet.set_active(false)
	client.session = saved_session
	client.set("run_store", saved_store)


func _sessions() -> void:
	_host_session = StateStreamTests.FakeSession.new()
	_host_session.transport = StateStreamTests.FakeTransport.new()
	_host_session.peers[P1] = {"ready": true}
	_host_session.peers[P2] = {"ready": true}
	_client_session = StateStreamTests.FakeSession.new()
	_client_session.transport = StateStreamTests.FakeTransport.new()
	_client_session.transport.host_id = HOST
	_client_session.host = false


# Until the client's battle scene is ready (or it is not loading one).
func _entered(client: Node):
	var until := OS.get_ticks_msec() + LOAD_TIMEOUT_MSEC
	yield(_t.get_tree(), "idle_frame")
	while client._loading and OS.get_ticks_msec() < until:
		yield(_t.get_tree(), "idle_frame")


# steam_id -> the body of the last message of msg_type the host's fake session sent it.
func _take(msg_type: int) -> Dictionary:
	var bodies := {}
	for sent in _host_session.sent:
		if sent[1] == msg_type:
			bodies[sent[0]] = sent[2]
	_host_session.sent.clear()
	return bodies


static func _has_ids(start: Dictionary) -> bool:
	var run = start.get("run")
	return run is Dictionary and run.get("ids") is Dictionary and not run.ids.empty()


static func _parts_of(start: Dictionary) -> Array:
	var run = start.get("run")
	var parts = run.get("parts") if run is Dictionary else null
	var keys: Array = parts.keys() if parts is Dictionary else []
	keys.sort()
	return keys


func _panel_tests():
	var tests = UpgradesChangeTests.new()
	tests._t = _t
	tests._together = _together
	tests._sync = _together.upgrades_sync
	tests._cache = _together.upgrades_sync.run_cache
	return tests


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")


# The cache of the start's run is cleared after its sends (the old code had none: fail-before).
static func _close(host: Node) -> void:
	if host.get("run_sender") != null:
		host.run_sender.close(host._run_cache)


func _on_battle_entered() -> void:
	_entered_json = RunStateCodec.encode_json()


# LEFT_OUT (header): what Go takes, and the candy bag's rolls. The test run has every item.
func _leave_out(p: int) -> void:
	for item in RunData.players_data[p].items.duplicate():
		if item.my_id in LEFT_OUT:
			RunData.remove_item(item, p, false, false)


# The paths in which two run texts differ, for the check's label ("same" when none).
static func _differences(expected: String, got: String) -> String:
	if got == expected:
		return "same"
	if got == "":
		return "no run"
	var old := RunParts.split(JSON.parse(expected).result)
	var new := RunParts.split(JSON.parse(got).result)
	var paths := []
	for key in new:
		paths += RunParts.changed_paths(old.get(key), new[key], 4)
	return ", ".join(PoolStringArray(paths.slice(0, int(min(paths.size(), 8)) - 1)))
