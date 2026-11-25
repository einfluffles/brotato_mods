extends Reference
# Suite emulator_transport: brotato:together's real Transport and Session, one pair per player,
# each bound to a local-play emulator (Transport.bind_steam) on the memory wire: hosting, joining
# and the HELLO / WELCOME handshake, messages both ways on both channels, send results down to the
# full resync, leaving, kicking, a game that is gone, a failed session and its restart. The nodes
# are not in the tree: pump() moves the wire's clock and runs each transport's _process, so the
# run is the same every time.

const Transport := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/steam_transport.gd")
const Session := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/session.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const LinkWatch := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/link_watch.gd")
const DlcBorrow := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/dlc_borrow.gd")
const SteamEmulator := preload("res://mods-unpacked/einfluffles-TogetherLocal/steam_emulator.gd")
const WireMemory := preload("res://mods-unpacked/einfluffles-TogetherLocal/wire_memory.gd")
const STEP_MSEC := 5
const BIG_BYTES := 300000  # two of these are more than Steam's 512 KB send buffer

var _t: Node
var _wire = null
var _sides := []


# One player's game: an emulator, a Transport bound to it, a Session on the transport, and what
# their signals said.
class Side:
	extends Reference
	var emulator = null
	var transport: Node = null
	var session: Node = null
	var bound := false
	var id := 0
	var events := []  # [signal name, args...]
	var received := []  # [sender, channel, msg_type, body, received_usec]
	var messages := []  # Session "message": [sender, msg_type, body]

	func _init(wire, number: int, persona: String, tag: String) -> void:
		emulator = SteamEmulator.new(number, persona)
		wire.add(emulator)
		id = emulator.steam_id
		transport = Transport.new()
		transport._lobby_tag = tag  # what setup() keeps before it binds the engine's singleton
		session = Session.new()
		session.setup(transport)
		for name in ["lobby_ready", "lobby_failed", "peer_joined", "peer_left", "send_failed"]:
			transport.connect(name, self, "_on_" + name)
		transport.connect("lobby_left", self, "_on_lobby_left")
		transport.connect("join_invite", self, "_on_join_invite")
		transport.connect("message_received", self, "_on_message_received")
		session.connect("peer_ready", self, "_on_peer_ready")
		session.connect("peer_removed", self, "_on_peer_removed")
		session.connect("message", self, "_on_message")
		bound = transport.bind_steam(emulator)

	func named(name: String) -> Array:
		var found := []
		for event in events:
			if event[0] == name:
				found.append(event[1] if event.size() == 2 else event.slice(1, event.size() - 1))
		return found

	func received_types(channel: int) -> Array:
		var types := []
		for entry in received:
			if entry[1] == channel:
				types.append(entry[2])
		return types

	func free_nodes() -> void:
		transport.bind_steam(null)
		session.free()
		transport.free()

	func _on_lobby_ready(lobby_id, is_host) -> void:
		events.append(["lobby_ready", lobby_id, is_host])

	func _on_lobby_failed(reason) -> void:
		events.append(["lobby_failed", reason])

	func _on_lobby_left() -> void:
		events.append(["lobby_left", true])

	func _on_peer_joined(steam_id) -> void:
		events.append(["peer_joined", steam_id])

	func _on_peer_left(steam_id) -> void:
		events.append(["peer_left", steam_id])

	func _on_send_failed(steam_id, channel, result) -> void:
		events.append(["send_failed", steam_id, channel, result])

	func _on_join_invite(lobby_id) -> void:
		events.append(["join_invite", lobby_id])

	func _on_peer_ready(steam_id) -> void:
		events.append(["peer_ready", steam_id])

	func _on_peer_removed(steam_id) -> void:
		events.append(["peer_removed", steam_id])

	func _on_message(steam_id, msg_type, body) -> void:
		messages.append([steam_id, msg_type, body])

	func _on_message_received(steam_id, channel, data, received_usec) -> void:
		var decoded = Protocol.decode(data)
		var msg_type: int = decoded[0] if decoded != null else -1
		var body = decoded[1] if decoded != null else null
		received.append([steam_id, channel, msg_type, body, received_usec])


func _init(test_mod: Node) -> void:
	_t = test_mod


func run() -> void:
	_wire = WireMemory.new()
	var tag := "einfluffles-BrotatoTogether/p%s" % Protocol.VERSION
	var host := _side(1, "Host", tag)
	var client := _side(2, "Client", tag)
	var lobby_id := _test_handshakes(host, client)
	_test_messages(host, client)
	_test_send_results(host, client)
	_test_session_restart(host, client)
	_test_leave_and_rejoin(host, client, lobby_id)
	_test_kick(host, client)
	_test_game_gone(host, client, _side(3, "Third", tag), lobby_id)
	_test_host_leaves(host, client, lobby_id)
	var other := _side(4, "Older", "einfluffles-BrotatoTogether/p0")
	_test_version_mismatch(host, other)
	for side in _sides:
		side.free_nodes()
	_sides.clear()
	DlcBorrow.revert()


func _side(number: int, persona: String, tag: String) -> Side:
	var side := Side.new(_wire, number, persona, tag)
	_sides.append(side)
	return side


# The wire's clock msec on in steps; each step every emulator polls, then every transport reads.
func _pump(msec := 0) -> void:
	var steps: int = max(1, msec / STEP_MSEC)
	for _i in steps:
		_wire.step(STEP_MSEC if msec > 0 else 0)
		for side in _sides:
			if side.bound:
				side.transport._process(0.0)


static func _state(side: Side, other: Side) -> int:
	return side.emulator.getSessionConnectionInfo(other.id, true, false).connection_state


func _clear(sides: Array) -> void:
	for side in sides:
		side.events.clear()
		side.received.clear()
		side.messages.clear()


func _test_handshakes(host: Side, client: Side) -> int:
	_t._check(
		(
			host.bound
			and client.bound
			and host.transport.local_id == host.id
			and host.transport.relay_only
			and host.transport.send_rate == host.transport.SEND_RATE
			and host.emulator.send_rate() == host.transport.SEND_RATE
			and host.emulator.relay_inits == 1
		),
		"emulator_transport: the real transport binds the emulator: id, relay-only, send rate"
	)
	host.transport.host_lobby()
	_pump(10)
	var ready: Array = host.named("lobby_ready")
	var lobby_id: int = ready[0][0] if not ready.empty() else 0
	_t._check(
		(
			ready == [[lobby_id, true]]
			and host.transport.is_host()
			and host.emulator.getLobbyData(lobby_id, "brotato_together") == host.transport._lobby_tag
			and host.emulator.rich_presence.get("connect") == "+connect_lobby %s" % lobby_id
		),
		"emulator_transport: host_lobby: lobby with the mod's tag, Join button on"
	)
	client.transport.join_lobby(lobby_id)
	_pump(50)
	var client_ready: Array = client.named("lobby_ready")
	_t._check(
		(
			client_ready == [[lobby_id, false]]
			and client.transport.host_id == host.id
			and host.named("peer_joined") == [client.id]
			and client.named("peer_joined") == [host.id]
			and host.named("peer_ready") == [client.id]
			and client.named("peer_ready") == [host.id]
			and host.session.peers[client.id].ready
			and client.session.is_ready_client()
			and host.session.peers[client.id].name == "Client"
		),
		"emulator_transport: a client joins, HELLO and WELCOME make both sides ready (%s, %s)"
		% [host.events, client.events]
	)
	host.transport.link_watch._next_poll_msec = 0
	host.transport._process(0.0)
	var info: Dictionary = host.emulator.getSessionConnectionInfo(client.id, true, true)
	_t._check(
		(
			info.connection_state == LinkWatch.STATE_CONNECTED
			and host.transport.link_watch.paths.get(client.id) == "relayed via lcl"
			and host.transport.connection_status(client.id).get("send_rate") == 524288
		),
		"emulator_transport: link_watch reads the relayed path, connection_status the send rate"
	)
	host.transport.open_invite_dialog()
	_t._check(
		host.emulator.invite_dialogs == [lobby_id],
		"emulator_transport: the invite dialog opens for the lobby"
	)
	return lobby_id


func _test_messages(host: Side, client: Side) -> void:
	_clear([host, client])
	host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, 1, {"a": 1}])
	host.session.send_unreliable(client.id, Protocol.Msg.SNAPSHOT, {"s": 2})
	client.session.send_reliable(host.id, Protocol.Msg.SHOP_INTENT, {"kind": "buy"})
	client.session.send_unreliable(host.id, Protocol.Msg.INPUT, [3])
	_pump(10)
	_t._check(
		(
			client.received_types(0) == [Protocol.Msg.STATE]
			and client.received_types(1) == [Protocol.Msg.SNAPSHOT]
			and host.received_types(0) == [Protocol.Msg.SHOP_INTENT]
			and host.received_types(1) == [Protocol.Msg.INPUT]
			and client.messages.size() == 2
			and str(client.messages[0]) == str([host.id, Protocol.Msg.STATE, [0, 1, {"a": 1}]])
			and str(host.messages[0]) == str([client.id, Protocol.Msg.SHOP_INTENT, {"kind": "buy"}])
		),
		"emulator_transport: messages both ways, reliable on channel 0, unreliable on 1"
	)
	# The PING waits 30 ms in Steam's queue before the host's transport reads it: the PONG says so.
	_clear([host, client])
	client.session.send_unreliable(host.id, Protocol.Msg.PING, {"t": OS.get_ticks_msec()})
	_wire.step(0)
	_wire.step(30)
	host.transport._process(0.0)
	_pump(10)
	var pongs := []
	for entry in client.received:
		if entry[2] == Protocol.Msg.PONG:
			pongs.append(entry[3])
	_t._check(
		pongs.size() == 1 and pongs[0].get("held") == 30,
		"emulator_transport: time_received and getLocalTimestamp give the PONG's held (%s)" % [pongs]
	)


func _test_send_results(host: Side, client: Side) -> void:
	_clear([host, client])
	var peer: Dictionary = host.session.peers[client.id]
	var now := OS.get_ticks_msec()
	var big := PoolByteArray()
	big.resize(SteamEmulator.MAX_MESSAGE_BYTES)
	host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, 1, big])
	var too_big: Array = host.named("send_failed")
	var queued: bool = peer.resync
	host.session.process_resyncs(now)
	_t._check(
		(
			too_big == [[client.id, 0, SteamEmulator.RESULT_INVALID_PARAM]]
			and queued
			and host.named("peer_ready") == [client.id]
		),
		"emulator_transport: a message over 512 KB fails (InvalidParam) and runs a full resync"
	)
	_clear([host, client])
	var half := PoolByteArray()
	half.resize(BIG_BYTES)
	host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, 2, half])
	host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, 3, half])
	host.session.process_resyncs(now + 2 * host.session.RESYNC_INTERVAL_MSEC)
	var full: Array = host.named("send_failed")
	_pump(400)
	var early: int = client.messages.size()
	_pump(300)
	_t._check(
		(
			full == [[client.id, 0, SteamEmulator.RESULT_LIMIT_EXCEEDED]]
			and host.named("peer_ready") == [client.id]
			and early == 0
			and client.messages.size() == 1
			and client.messages[0][2][1] == 2
		),
		"emulator_transport: a full send buffer fails (LimitExceeded) and resyncs; 300 KB take"
		+ " about 0.6 s at 512 KB/s (%s, %d early)" % [full, early]
	)
	_clear([host, client])
	host.emulator.attach_wire(null)
	host.session.send_unreliable(client.id, Protocol.Msg.SNAPSHOT, {})
	var unreliable_resync: bool = peer.resync
	host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, 4, null])
	host.emulator.attach_wire(_wire)
	host.session.process_resyncs(now + 4 * host.session.RESYNC_INTERVAL_MSEC)
	_t._check(
		(
			host.named("send_failed")
			== [
				[client.id, 1, SteamEmulator.RESULT_NO_CONNECTION],
				[client.id, 0, SteamEmulator.RESULT_NO_CONNECTION],
			]
			and not unreliable_resync
			and host.named("peer_ready") == [client.id]
		),
		"emulator_transport: no connection (NoConnection): unreliable needs nothing, reliable resyncs"
	)


func _test_session_restart(host: Side, client: Side) -> void:
	_clear([host, client])
	host.emulator.fail_session(client.id, 5008, "test")
	_pump(10)
	var failed_host: String = host.transport.link_watch.paths.get(client.id, "")
	var failed_client: String = client.transport.link_watch.paths.get(host.id, "")
	host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, 5, null])
	_pump(20)
	host.transport.link_watch._next_poll_msec = 0
	host.transport._process(0.0)
	_t._check(
		(
			failed_host == "failed"
			and failed_client == "failed"
			and client.messages.size() == 1
			and client.messages[0][2][1] == 5
			and "up again" in host.transport.link_watch.last_line
		),
		"emulator_transport: a failed session is logged on both sides; the next reliable message"
		+ " opens a new one the client accepts (%s)" % host.transport.link_watch.last_line
	)


func _test_leave_and_rejoin(host: Side, client: Side, lobby_id: int) -> void:
	_clear([host, client])
	client.transport.leave_lobby()
	var by_peer: int = _state(host, client)
	_pump(10)
	_t._check(
		(
			client.named("lobby_left") == [true]
			and host.named("peer_left") == [client.id]
			and host.named("peer_removed") == [client.id]
			and host.emulator.getNumLobbyMembers(lobby_id) == 1
			and by_peer == LinkWatch.STATE_CLOSED_BY_PEER
			and _state(host, client) == 0
		),
		"emulator_transport: a client leaves: its session closes, the host sees it go and closes"
		+ " its side too"
	)
	_clear([host, client])
	client.emulator.fire_join_requested(lobby_id, host.id)
	_pump(50)
	host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, 6, null])
	_pump(10)
	_t._check(
		(
			client.named("lobby_ready") == [[lobby_id, false]]
			and host.named("peer_ready") == [client.id]
			and client.named("peer_ready") == [host.id]
			and client.messages.size() == 1
		),
		"emulator_transport: a Steam invite (join_requested) joins again, handshake and messages"
	)
	_clear([client])
	client.emulator.fire_join_requested(lobby_id + 1, host.id)
	_pump(10)
	_t._check(
		client.named("join_invite") == [lobby_id + 1] and client.transport.pending_join_id != 0,
		"emulator_transport: an invite while in a lobby waits for the question"
	)
	client.transport.pending_join_id = 0


func _test_kick(host: Side, client: Side) -> void:
	_clear([host, client])
	host.session.kick(client.id)
	var kicked: bool = host.transport.kicked.has(client.id)
	_pump(20)
	_t._check(
		(
			kicked
			and host.named("peer_left") == [client.id]
			and client.named("lobby_failed") == [client.transport.tr("BT_ERR_KICKED")]
			and not client.transport.is_active()
			and not host.transport.kicked.has(client.id)
			and host.transport.members.empty()
		),
		"emulator_transport: a kick: KICK reaches the client, it leaves, the host may take it again"
	)


func _test_game_gone(host: Side, client: Side, third: Side, lobby_id: int) -> void:
	client.transport.join_lobby(lobby_id)
	third.transport.join_lobby(lobby_id)
	_pump(50)
	_clear([host, client, third])
	_wire.unplug(client.id)
	_pump(10)
	_t._check(
		(
			host.named("peer_left") == [client.id]
			and host.named("peer_removed") == [client.id]
			and third.named("peer_left") == [client.id]
			and host.transport.link_watch.paths.get(client.id, "") in ["failed", ""]
			and host.transport.members == [third.id]
			and host.session.peers.has(third.id)
		),
		"emulator_transport: a client's game is gone: the others see it leave, the third stays"
	)
	third.transport.leave_lobby()
	client.transport.bind_steam(null)
	client.bound = false
	_pump(10)
	_wire.add(client.emulator)
	client.bound = client.transport.bind_steam(client.emulator)


func _test_host_leaves(host: Side, client: Side, lobby_id: int) -> void:
	client.transport.join_lobby(lobby_id)
	_pump(50)
	var joined: bool = client.session.is_ready_client()
	_clear([host, client])
	host.transport.leave_lobby()
	_pump(10)
	_t._check(
		(
			joined
			and host.transport.was_host
			and client.named("lobby_failed") == [client.transport.tr("BT_ERR_HOST_LEFT")]
			and not client.transport.is_active()
			and client.emulator.getNumLobbyMembers(lobby_id) == 0
		),
		"emulator_transport: the host leaves: the client is told and leaves too"
	)


func _test_version_mismatch(host: Side, other: Side) -> void:
	host.transport.host_lobby()
	_pump(10)
	var lobby_id: int = host.transport.lobby_id
	_clear([other])
	other.transport.join_lobby(lobby_id)
	_pump(10)
	var failed: Array = other.named("lobby_failed")
	_t._check(
		(
			failed.size() == 1
			and "p0" in failed[0]
			and not other.transport.is_active()
			and host.emulator.getNumLobbyMembers(lobby_id) == 1
		),
		"emulator_transport: another protocol's lobby tag: the joiner leaves again (%s)" % [failed]
	)
	host.transport.leave_lobby()
