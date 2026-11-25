extends Reference
# Suite emulator_wire: the local-play dev mod's wire between games (dev/einfluffles-TogetherLocal/
# wire_tcp.gd) with real sockets on 127.0.0.1, all ends in this one process: a host's emulator and
# clients' emulators, each on its own wire. Framing, the handshake and its token, the host's
# lobbies reaching the clients, a join, messages both ways (reliable, unreliable, 300 KB in one),
# a client reaching another through the host, a client and then the host leaving. Real time:
# pump() polls every wire and emulator until a condition holds or a few seconds have passed.

const SteamEmulator := preload("res://mods-unpacked/einfluffles-TogetherLocal/steam_emulator.gd")
const WireTcp := preload("res://mods-unpacked/einfluffles-TogetherLocal/wire_tcp.gd")
const EmulatorTests := preload("res://mods-unpacked/einfluffles-TogetherTests/emulator_tests.gd")
const TOKEN := "0123456789abcdef0123456789abcdef"
const RELIABLE := 8 | 32  # the flags Transport.send sets
const UNRELIABLE := 1 | 32
const BIG_BYTES := 300000
const WAIT_MSEC := 5000
const DEV_DIR := "res://mods-unpacked/einfluffles-TogetherLocal/"
const DEV_SCRIPTS := [
	"mod_main.gd",
	"steam_emulator.gd",
	"wire_memory.gd",
	"wire_tcp.gd",
	"local_instance.gd",
	"local_transport.gd",
]
const CHAT_DISCONNECTED := 4

var _t: Node
var _ends := []  # [emulator, wire]


func _init(test_mod: Node) -> void:
	_t = test_mod


func run() -> void:
	_test_scripts()
	_test_decode()
	var host = SteamEmulator.new(1, "Host")
	var host_wire = WireTcp.new()
	var port := _listen(host, host_wire)
	_t._check(port > 0 and host_wire.state == "listening", "emulator_wire: the host listens")
	if port <= 0:
		return
	var host_events = EmulatorTests.Recorder.new(host)
	var client = SteamEmulator.new(2, "Client")
	var client_wire = _join(client, port, TOKEN)
	var client_events = EmulatorTests.Recorder.new(client)
	pump("_is_online", [client_wire])
	_t._check(
		(
			client_wire.state == "online"
			and client_wire.host_id == host.steam_id
			and host_wire.peer_ids == [client.steam_id]
			and client_wire.peer_ids == [host.steam_id]
		),
		"emulator_wire: a client with the launcher's token is online: host id, peers"
	)
	var stranger = SteamEmulator.new(5, "Stranger")
	var stranger_wire = _join(stranger, port, "not-the-token-not-the-token-0000")
	pump("_has_state", [stranger_wire, "failed"])
	_t._check(
		stranger_wire.state == "failed" and not stranger.steam_id in host_wire.peer_ids,
		"emulator_wire: a wrong token is refused, the peer dropped"
	)
	var lobby_id := _test_lobby(host, client, client_wire, client_events)
	_test_messages(host, client)
	var third = SteamEmulator.new(3, "Third")
	var third_wire = _join(third, port, TOKEN)
	pump("_is_online", [third_wire])
	third.joinLobby(lobby_id)
	pump("_has_members", [host, lobby_id, 3])
	_test_relay(client, third)
	third_wire.close()
	pump("_has_members", [host, lobby_id, 2])
	_t._check(
		(
			host.getNumLobbyMembers(lobby_id) == 2
			and [lobby_id, third.steam_id, third.steam_id, CHAT_DISCONNECTED]
			in host_events.named("lobby_chat_update")
			and not third.steam_id in host_wire.peer_ids
		),
		"emulator_wire: a client's game that closes leaves the host's lobby (disconnected)"
	)
	host_wire.close()
	pump("_has_state", [client_wire, "connecting"])
	_t._check(
		(
			client_wire.state == "connecting"
			and client_wire.peer_ids.empty()
			and [lobby_id, host.steam_id, host.steam_id, CHAT_DISCONNECTED]
			in client_events.named("lobby_chat_update")
		),
		"emulator_wire: the host's game gone: the client hears the host leave, then tries again"
	)
	for end in _ends:
		end[1].close()
	_ends.clear()


func _test_decode() -> void:
	var good := PoolByteArray(WireTcp.MAGIC)
	good.append(WireTcp.WIRE_VERSION)
	good.append_array(var2bytes({"k": "msg"}))
	var other_version := PoolByteArray(WireTcp.MAGIC)
	other_version.append(WireTcp.WIRE_VERSION + 1)
	other_version.append_array(var2bytes({"k": "msg"}))
	var other_magic := PoolByteArray([1, 2, 3, 4, WireTcp.WIRE_VERSION])
	other_magic.append_array(var2bytes({"k": "msg"}))
	var no_kind := PoolByteArray(WireTcp.MAGIC)
	no_kind.append(WireTcp.WIRE_VERSION)
	no_kind.append_array(var2bytes([1, 2]))
	_test_frames(good)
	_t._check(
		(
			WireTcp.decode(good) is Dictionary
			and WireTcp.decode(other_version) == null
			and WireTcp.decode(other_magic) == null
			and WireTcp.decode(no_kind) == null
			and WireTcp.decode(PoolByteArray()) == null
		),
		"emulator_wire: only this wire's magic and version decode, to a Dictionary with a kind"
	)


func _test_lobby(host, client, client_wire, client_events) -> int:
	host.createLobby(2, 4)
	host.poll()
	var lobby_id: int = host.owned_lobby_ids()[0]
	pump("_knows_lobby", [client_wire, lobby_id])
	_t._check(
		lobby_id in client_wire.host_lobbies,
		"emulator_wire: the host's new lobby reaches the client (its +connect_lobby can go)"
	)
	client.joinLobby(lobby_id)
	pump("_has_members", [client, lobby_id, 2])
	var joined: Array = client_events.named("lobby_joined")
	_t._check(
		(
			joined == [[lobby_id, 0, false, 1]]
			and host.getNumLobbyMembers(lobby_id) == 2
			and client.getLobbyOwner(lobby_id) == host.steam_id
			and client.getFriendPersonaName(host.steam_id) == "Host"
			and host.getFriendPersonaName(client.steam_id) == "Client"
		),
		"emulator_wire: the client joins the host's lobby over the wire: members, owner, names"
	)
	return lobby_id


func _test_messages(host, client) -> void:
	var small := PoolByteArray([1, 2, 3])
	var big := PoolByteArray()
	big.resize(BIG_BYTES)
	for i in BIG_BYTES:
		big[i] = i % 251
	var mid := PoolByteArray()
	mid.resize(5000)  # unreliable and bigger than a UDP packet would be
	client.sendMessageToUser(host.steam_id, small, RELIABLE, 0)
	pump("_has_session_request", [host])
	host.acceptSessionWithUser(client.steam_id)
	host.sendMessageToUser(client.steam_id, big, RELIABLE, 0)
	host.sendMessageToUser(client.steam_id, small, UNRELIABLE, 1)
	host.sendMessageToUser(client.steam_id, mid, UNRELIABLE, 1)
	var at_host := []
	var at_client := []
	var deadline := OS.get_ticks_msec() + WAIT_MSEC
	while OS.get_ticks_msec() < deadline and (at_host.size() < 1 or at_client.size() < 3):
		pump_once()
		at_host += host.receiveMessagesOnChannel(0, 10)
		at_client += client.receiveMessagesOnChannel(0, 10)
		at_client += client.receiveMessagesOnChannel(1, 10)
	var payloads := []
	for message in at_client:
		payloads.append(message.payload.size())
	payloads.sort()
	_t._check(
		(
			at_host.size() == 1
			and at_host[0].payload == small
			and at_host[0].identity == client.steam_id
			and payloads == [small.size(), mid.size(), BIG_BYTES]
			and _payload_of(at_client, BIG_BYTES) == big
		),
		"emulator_wire: messages both ways, reliable 300 KB intact, unreliable small and big"
	)


func _test_relay(client, third) -> void:
	var data := PoolByteArray([7, 7, 7])
	client.sendMessageToUser(third.steam_id, data, RELIABLE, 0)
	pump("_has_session_request", [third])
	third.acceptSessionWithUser(client.steam_id)
	var got := []
	var deadline := OS.get_ticks_msec() + WAIT_MSEC
	while OS.get_ticks_msec() < deadline and got.empty():
		pump_once()
		got += third.receiveMessagesOnChannel(0, 10)
	_t._check(
		got.size() == 1 and got[0].payload == data and got[0].identity == client.steam_id,
		"emulator_wire: a client reaches another through the host's game, as itself"
	)


static func _payload_of(messages: Array, size: int) -> PoolByteArray:
	for message in messages:
		if message.payload.size() == size:
			return message.payload
	return PoolByteArray()


# A free port: a few tries in a range nothing else of the tests uses.
func _listen(emulator, wire) -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for _i in 8:
		var port := 41000 + rng.randi_range(0, 8000)
		if wire.listen(emulator, port, TOKEN) == OK:
			_ends.append([emulator, wire])
			return port
	return 0


func _join(emulator, port: int, token: String):
	var wire = WireTcp.new()
	wire.join(emulator, port, token)
	_ends.append([emulator, wire])
	return wire


func pump_once() -> void:
	for end in _ends:
		end[1].poll()
	for end in _ends:
		end[0].poll()
	OS.delay_msec(2)


# Polls until method(args...) holds or WAIT_MSEC have passed.
func pump(method: String, args: Array) -> bool:
	var deadline := OS.get_ticks_msec() + WAIT_MSEC
	while OS.get_ticks_msec() < deadline:
		pump_once()
		if callv(method, args):
			return true
	return false


func _is_online(wire) -> bool:
	return wire.state == "online"


func _has_state(wire, state: String) -> bool:
	return wire.state == state


func _knows_lobby(wire, lobby_id: int) -> bool:
	return lobby_id in wire.host_lobbies


func _has_members(emulator, lobby_id: int, count: int) -> bool:
	return emulator.getNumLobbyMembers(lobby_id) == count


func _has_session_request(emulator) -> bool:
	for session in emulator._sessions.values():
		if session.requested:
			return true
	return false


# Frames as TCP hands them over: in pieces, two in one read, a length nobody would send.
func _test_frames(body: PoolByteArray) -> void:
	var frame: PoolByteArray = WireTcp.encode({"k": "msg"})
	var link = WireTcp.Link.new(StreamPeerTCP.new())
	link.inbox = frame.subarray(0, 5)
	var partial = link.next_frame()
	link.feed(frame.subarray(6, frame.size() - 1))
	link.feed(frame)
	var first = link.next_frame()
	var second = link.next_frame()
	var none = link.next_frame()
	var broken = WireTcp.Link.new(StreamPeerTCP.new())
	broken.inbox = PoolByteArray([0xFF, 0xFF, 0xFF, 0x7F, 1, 2])
	_t._check(
		(
			partial is PoolByteArray
			and partial.empty()
			and first == body
			and second == body
			and none.empty()
			and link.inbox.empty()
			and broken.next_frame() == null
		),
		"emulator_wire: frames in pieces and two in one read come out whole; a huge length breaks"
	)


# Every script of the dev mod compiles (the game loads most of them only in a local instance).
func _test_scripts() -> void:
	var broken := []
	for file in DEV_SCRIPTS:
		var script = load(DEV_DIR + file)
		if script == null or not script.can_instance():
			broken.append(file)
	_t._check(broken.empty(), "emulator_wire: every dev mod script compiles %s" % [broken])
