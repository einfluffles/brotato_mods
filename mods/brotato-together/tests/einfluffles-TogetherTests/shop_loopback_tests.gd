extends Reference
# Suite shop_loopback: the host opens the real co-op shop (rolls items) and buys slot 1; the
# client mirrors both states, the host's cursor and the shop's sounds. Plays on mod_main's
# two-player run (coop_run); checks go through its _check.

const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const PerfTests := preload("res://mods-unpacked/einfluffles-TogetherTests/battle_perf_tests.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const CursorTargetTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/cursor_target_tests.gd"
)
const FocusSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/focus_sync.gd")
const HOST := 2
const PEER := 11
const KEY_CHECKS := 200

var t: Node  # the test mod: _check, helpers, scene tree
var _perf = null


func _init(test_mod: Node) -> void:
	t = test_mod
	_perf = PerfTests.new(test_mod)


func run(together: Node):
	var shop_sync: Node = together.shop_sync
	shop_sync.set_process(false)  # driven by hand (no Steam session)
	CoopService.connected_players.clear()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.current_wave = 2
	RunData.add_gold(500, 0)
	t.get_tree().change_scene(RunData.get_shop_scene_path())
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var host_shop := t.get_tree().current_scene
	t._check(host_shop.filename == shop_sync.SHOP_SCENE, "host co-op shop loaded")
	shop_sync._host_shop = host_shop
	shop_sync._shop_id = 7
	_perf.test_shop_compare(shop_sync)
	var before: Dictionary = bytes2var(var2bytes(shop_sync._shop_body()), false)
	var host_before: Array = t._shop_slots(host_shop, 0)

	var container = host_shop._get_shop_items_container(0)
	var bought = container.get_shop_item_node(1)
	var bought_id: String = bought.item_data.my_id
	var gold_before: int = RunData.get_player_gold(0)
	var host_sounds: Dictionary = yield(_ui_sounds_host_buy(together, bought), "completed")
	var after: Dictionary = bytes2var(var2bytes(shop_sync._shop_body()), false)

	# Host cursor for player 0 on shop slot 2 (focus mirroring, another mod's nodes on the host).
	var focus_sync: Node = together.focus_sync
	var host_emulator = Utils.get_focus_emulator(0, host_shop)
	host_emulator.focused_control = container.get_shop_item_node(2)._button
	var cursor_messages: Array = _host_cursors(focus_sync, host_shop)
	var host_after: Array = t._shop_slots(host_shop, 0)
	var host_gold_after: int = RunData.get_player_gold(0)
	t._check(host_gold_after < gold_before, "host bought %s" % bought_id)
	print("  info: shop state %d B on the wire" % var2bytes(after).size())

	# --- client ---
	shop_sync._client_shop_id = 0
	var state := RunStateCodec.decode(before.run)
	shop_sync._pending = {"state": state, "slots": before.slots, "go": before.go}
	shop_sync._client_shop_id = before.shop_id
	shop_sync._enter_shop(state)
	yield(shop_sync, "shop_entered")
	var client_shop: Node = shop_sync._client_shop
	t._check(client_shop != host_shop, "client loaded its own shop")
	t._check(not client_shop._pause_menu.enabled, "client shop can't pause locally")
	t._check(
		t._shop_slots(client_shop, 0) == host_before,
		"client shows host's items %s" % [t._shop_slots(client_shop, 0)]
	)

	var dropped_before: int = t._hold_sounds(true)
	shop_sync._pending = {
		"state": RunStateCodec.decode(after.run), "slots": after.slots, "go": after.go
	}
	shop_sync._apply_pending()
	t._check(
		t._shop_slots(client_shop, 0) == host_after,
		"client mirrors purchase %s == %s" % [t._shop_slots(client_shop, 0), host_after]
	)
	t._check(RunData.get_player_gold(0) == host_gold_after, "client gold matches host")
	yield(t.get_tree(), "idle_frame")
	_client_cursors(focus_sync, client_shop, cursor_messages)
	_test_ui_sounds_client(together, host_sounds, dropped_before)
	var owned := false
	for element in RunData.get_player_weapons(0) + RunData.get_player_items(0):
		owned = owned or element.my_id == bought_id
	t._check(owned, "client inventory has %s" % bought_id)
	Puppet.set_active(false)
	shop_sync._host_shop = null  # set by hand above: the host shop is gone with the next scene
	shop_sync.set_process(true)


# The host's cursors through sync/state_stream.gd end to end: FocusSync is the CURSORS provider
# of a host stream on a fake session (what it sends one peer: first check, then the resend on
# peer_ready), with what another mod would add on the host only (a node first in the scene and
# a Damage-Meter-like button before player 0's reroll). Returns the two STATE messages.
func _host_cursors(focus_sync: Node, shop: Node) -> Array:
	var stream := _fake_stream(true)
	stream.register_provider(StateStream.CURSORS, focus_sync, FocusSync.CHECK_INTERVAL)
	var extras := CursorTargetTests.add_mod_nodes(shop, [], shop._get_reroll_button(0))
	stream.step(0.0)
	var first := _sent(stream)
	stream.step(FocusSync.CHECK_INTERVAL)
	var unchanged := _sent(stream)
	stream.session.emit_signal("peer_ready", PEER)
	var resent := _sent(stream)
	_measure_key(focus_sync)
	var emulator = Utils.get_focus_emulator(0, shop)
	var slot_2 = emulator.focused_control
	emulator.focused_control = shop._get_shop_items_container(0).get_shop_item_node(1)._button
	stream.step(FocusSync.CHECK_INTERVAL)
	var moved := _sent(stream)
	emulator.focused_control = slot_2
	CursorTargetTests.remove_nodes(extras)
	_free_stream(stream)
	t._check(
		moved.size() == 1 and moved[0][1][1] == 2
		and var2str(moved[0][1][2]) != var2str(first[0][1][2] if first.size() == 1 else null),
		"a moved cursor goes out with the next revision"
	)
	var body = first[0][1][2] if first.size() == 1 and first[0][0] == PEER else null
	t._check(
		body is Dictionary and first[0][1][0] == StateStream.CURSORS and body.scene == shop.filename
		and not body.cursors.empty(),
		"host sends its cursors as STATE section cursors %s" % [first]
	)
	t._check(unchanged.empty(), "unchanged cursors: nothing sent")
	t._check(
		resent.size() == 1 and body != null and var2str(resent[0]) == var2str(first[0]),
		"peer_ready: the same cursors again"
	)
	if body == null or resent.size() != 1:
		return []
	return [first[0][1], resent[0][1]]


# What one check of the host's key costs (it runs 20 times a second: identities and child
# indices), next to the body it stands for (every cursor described through ui/focus_targets.gd,
# built on change only).
func _measure_key(focus_sync: Node) -> void:
	var started := OS.get_ticks_usec()
	for _i in KEY_CHECKS:
		focus_sync.state_key(StateStream.CURSORS)
	var key_usec := float(OS.get_ticks_usec() - started) / KEY_CHECKS
	started = OS.get_ticks_usec()
	for _i in KEY_CHECKS:
		focus_sync.state_body(StateStream.CURSORS)
	var body_usec := float(OS.get_ticks_usec() - started) / KEY_CHECKS
	var line := "  info: cursors key per check, co-op shop with %d emulators, %d cursors: %.1f us"
	line += " (%.3f ms per second at 20 checks); the body it stands for: %.1f us"
	var cursors: int = focus_sync._cursors().size()
	var emulators: int = focus_sync._emulators.size()
	print(line % [emulators, cursors, key_usec, key_usec * 20.0 / 1000.0, body_usec])


# The client's stream hands the host's STATE to FocusSync: the cursor lands, a resync puts it
# back, a cursor that never resolves times out while the rest of its body is applied.
func _client_cursors(focus_sync: Node, shop: Node, messages: Array) -> void:
	var stream := _fake_stream(false)
	stream.register_handler(StateStream.CURSORS, focus_sync, FocusSync.PENDING_TIMEOUT_SEC)
	var emulator = Utils.get_focus_emulator(0, shop)
	var expected = shop._get_shop_items_container(0).get_shop_item_node(2)._button
	var reroll = shop._get_reroll_button(0)
	if messages.size() == 2:
		stream.session.emit_signal("message", HOST, Protocol.Msg.STATE, messages[0])
	t._check(
		emulator.focused_control == expected,
		"client cursor mirrors host cursor through the stream (another mod's nodes on the host only)"
	)
	emulator.focused_control = reroll
	if messages.size() == 2:
		stream.session.emit_signal("message", HOST, Protocol.Msg.STATE, messages[1])
	t._check(emulator.focused_control == expected, "resync on peer_ready re-delivers the cursor")
	_free_stream(stream)

	var waits: Dictionary = focus_sync.state_stream._handlers.get(StateStream.CURSORS, {})
	t._check(
		waits.get("timeout_msec") == int(FocusSync.PENDING_TIMEOUT_SEC * 1000.0),
		"cursors wait %s ms for their controls" % [waits.get("timeout_msec")]
	)
	stream = _fake_stream(false)
	stream.register_handler(StateStream.CURSORS, focus_sync, 0.05)
	var cursor := FocusSync.cursor_of(emulator, reroll, shop)
	var host_only := [cursor[0], cursor[1], ["scene", -1, -1, ["HostOnlyButton"]]]
	var body := {"scene": shop.filename, "cursors": [cursor, host_only]}
	stream.receive([StateStream.CURSORS, 1, bytes2var(var2bytes(body), false)])
	t._check(
		emulator.focused_control == reroll and stream.is_pending(StateStream.CURSORS),
		"a cursor on a control only the host has: the others applied, the body kept"
	)
	OS.delay_msec(80)
	stream.step(0.016)
	t._check(not stream.is_pending(StateStream.CURSORS), "a cursor that never resolves times out")
	_free_stream(stream)


func _fake_stream(host: bool) -> Node:
	var session: Node = StateStreamTests.FakeSession.new()
	session.transport = StateStreamTests.FakeTransport.new()
	session.transport.host_id = HOST
	session.host = host
	if host:
		session.peers[PEER] = {"ready": true}
	var stream: Node = StateStream.new()
	stream.setup(session)
	return stream


func _free_stream(stream: Node) -> void:
	stream.session.free()
	stream.free()


# What the stream sent since the last call, as [steam_id, [section, revision, body]].
func _sent(stream: Node) -> Array:
	var messages := []
	for sent in stream.session.sent:
		if sent[1] == Protocol.Msg.STATE:
			messages.append([sent[0], sent[2]])
	stream.session.sent.clear()
	return messages


# Host presses the shop item's real Buy button: its press sound plays through SoundManager, and
# everything the host plays outside battle is recorded for clients (UiSounds).
func _ui_sounds_host_buy(together: Node, shop_item: Node):
	var ui_sounds: Node = together.ui_sounds
	ui_sounds.set_process(false)  # driven by hand (no Steam session)
	SoundRelay.set_ui_sink(ui_sounds)
	t._hold_sounds(true)
	shop_item._button.emit_signal("pressed")  # the buy itself is a deferred connection
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var played := _queued_sound_paths()
	var body: Dictionary = bytes2var(var2bytes(ui_sounds.take_batch()), false)
	SoundRelay.set_ui_sink(null)
	t._hold_sounds(false)
	ui_sounds.set_process(true)
	var sent := _batch_paths(body)
	print("  info: host played %s, sent %s (%d B)" % [played, sent, var2bytes(body).size()])
	t._check("res://ui/sounds/button_press.wav" in sent, "host sends the purchase sound")
	t._check(sent == played, "host sends every sound it played in the shop")
	return body


# Client: mirroring the purchase and the cursor in the puppet shop plays nothing locally; the
# host's batch plays exactly once.
func _test_ui_sounds_client(together: Node, host_sounds: Dictionary, dropped_before: int) -> void:
	var local := _queued_sound_paths()
	var dropped: int = SoundRelay.dropped_count() - dropped_before
	print("  info: client mirroring muted %d local sounds" % dropped)
	t._check(local.empty() and dropped > 0, "mirrored shop plays no local sounds %s" % [local])
	var played: int = together.ui_sounds.play_batch(host_sounds)
	var heard := _queued_sound_paths()
	t._check(
		played > 0 and heard == _batch_paths(host_sounds),
		"client plays exactly the host's sounds %s" % [heard]
	)
	t._hold_sounds(false)
	_test_ui_sound_validation(together.ui_sounds)


# Sound paths come from the network: only existing res:// sound files are played.
func _test_ui_sound_validation(ui_sounds: Node) -> void:
	t._check(SoundRelay.is_sound_path("res://ui/sounds/buy.wav"), "UI sound path accepted")
	var rejected := true
	for path in ["user://a.wav", "res://../a.wav", "res://main.tscn", "res://a.wav::1", 42, null]:
		rejected = rejected and not SoundRelay.is_sound_path(path)
	t._check(rejected, "non-sound paths rejected")
	t._hold_sounds(true)
	var bad := {
		"sounds":
		[
			["res://ui/menus/shop/coop_shop.tscn", 0.0, 0.0, null],
			["res://../ui/sounds/buy.wav", 0.0, 0.0, null],
			["user://buy.wav", 0.0, 0.0, null],
			["res://ui/sounds/does_not_exist.wav", 0.0, 0.0, null],
			["res://ui/sounds/buy.wav", "loud", 0.0, null],
			["res://ui/sounds/buy.wav", 0.0, 0.0, "here"],
			["res://ui/sounds/buy.wav"],
			"res://ui/sounds/buy.wav",
		]
	}
	var played: int = ui_sounds.play_batch(bad)
	played += ui_sounds.play_batch("res://ui/sounds/buy.wav")
	played += ui_sounds.play_batch({"sounds": 3})
	t._check(played == 0 and _queued_sound_paths().empty(), "malformed UI sounds rejected")
	t._hold_sounds(false)


func _queued_sound_paths() -> Array:
	var paths := []
	for manager in [SoundManager, SoundManager2D]:
		for entry in manager.sounds_to_play:
			paths.append(entry[0].resource_path if entry[0] != null else "")
	paths.sort()
	return paths


func _batch_paths(body: Dictionary) -> Array:
	var paths := []
	if typeof(body.get("sounds")) == TYPE_ARRAY:
		for entry in body.sounds:
			paths.append(entry[0])
	paths.sort()
	return paths
