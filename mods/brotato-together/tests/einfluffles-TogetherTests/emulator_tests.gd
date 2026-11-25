extends Reference
# Suite emulator: the local-play dev mod's Steam stand-in (dev/einfluffles-TogetherLocal) on the
# memory wire: ids, lobbies, sessions, send results, pacing, the link, connection info, what it
# records, and the dev mod staying inert. Synchronous: the wire's clock moves only when a test
# steps it, so every number here is exact.

const SteamEmulator := preload("res://mods-unpacked/einfluffles-TogetherLocal/steam_emulator.gd")
const WireMemory := preload("res://mods-unpacked/einfluffles-TogetherLocal/wire_memory.gd")
const LocalMain := preload("res://mods-unpacked/einfluffles-TogetherLocal/mod_main.gd")
const LinkWatch := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/link_watch.gd")
const DEV_MOD_PATH := "/root/ModLoader/einfluffles-TogetherLocal"
const RELIABLE := 8 | 32  # the flags Transport.send sets
const UNRELIABLE := 1 | 32
const REAL_STEAM_ID := 76561197960287930
const STEP_MSEC := 5

var _t: Node


# Every GodotSteam signal of one emulator, in order: [name, args...].
class Recorder:
	extends Reference
	var events := []

	func _init(emulator) -> void:
		emulator.connect("lobby_created", self, "_on_lobby_created")
		emulator.connect("lobby_joined", self, "_on_lobby_joined")
		emulator.connect("join_requested", self, "_on_join_requested")
		emulator.connect("lobby_chat_update", self, "_on_lobby_chat_update")
		emulator.connect("network_messages_session_request", self, "_on_session_request")
		emulator.connect("network_messages_session_failed", self, "_on_session_failed")

	func named(name: String) -> Array:
		var found := []
		for event in events:
			if event[0] == name:
				found.append(event.slice(1, event.size() - 1))
		return found

	func _on_lobby_created(result, lobby_id) -> void:
		events.append(["lobby_created", result, lobby_id])

	func _on_lobby_joined(lobby_id, permissions, locked, response) -> void:
		events.append(["lobby_joined", lobby_id, permissions, locked, response])

	func _on_join_requested(lobby_id, friend_id) -> void:
		events.append(["join_requested", lobby_id, friend_id])

	func _on_lobby_chat_update(lobby_id, changed_id, making_change_id, chat_state) -> void:
		events.append(["lobby_chat_update", lobby_id, changed_id, making_change_id, chat_state])

	func _on_session_request(remote_id) -> void:
		events.append(["session_request", remote_id])

	func _on_session_failed(reason, remote_id, state, debug) -> void:
		events.append(["session_failed", reason, remote_id, state, debug])


func _init(test_mod: Node) -> void:
	_t = test_mod


func run() -> void:
	_test_ids()
	_test_lobby()
	_test_send_results()
	_test_sessions()
	_test_pacing()
	_test_link()
	_test_session_failure()
	_test_connection_info()
	_test_recorded()
	_test_dev_mod()


# A wire with emulators 1..count on it: [wire, emulators..., recorders...].
func _setup(count: int) -> Array:
	var wire = WireMemory.new()
	var emulators := []
	var recorders := []
	for number in range(1, count + 1):
		var emulator = SteamEmulator.new(number, "P%d" % number)
		wire.add(emulator)
		emulators.append(emulator)
		recorders.append(Recorder.new(emulator))
	return [wire] + emulators + recorders


static func _run(wire, msec: int) -> void:
	for _i in range(msec / STEP_MSEC):
		wire.step(STEP_MSEC)


static func _bytes(size: int, value := 0) -> PoolByteArray:
	var data := PoolByteArray()
	data.resize(size)
	for i in range(int(min(size, 4))):
		data[i] = (value >> (8 * i)) & 0xFF
	return data


static func _numbers(messages: Array) -> Array:
	var numbers := []
	for message in messages:
		var data: PoolByteArray = message.payload
		numbers.append(data[0] | (data[1] << 8))
	return numbers


# Both sides send once and accept, so the session is up both ways.
static func _connect(wire, a, b) -> void:
	a.sendMessageToUser(b.steam_id, _bytes(4), RELIABLE, 0)
	wire.step(0)
	b.acceptSessionWithUser(a.steam_id)
	b.sendMessageToUser(a.steam_id, _bytes(4), RELIABLE, 0)
	wire.step(0)
	for emulator in [a, b]:
		emulator.receiveMessagesOnChannel(0, 100)


func _test_ids() -> void:
	var s := _setup(2)
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	_t._check(
		(
			a.getSteamID() == SteamEmulator.FAKE_ID_BASE + 1
			and SteamEmulator.is_fake_id(a.getSteamID())
			and a.getSteamID() >> 56 == 0
			and REAL_STEAM_ID >> 56 == 1
			and not SteamEmulator.is_fake_id(REAL_STEAM_ID)
			and SteamEmulator.new(0).getSteamID() == 0
		),
		"emulator: fake ids have universe 0, so none is a real Steam id; number 0 is not logged on"
	)
	a.createLobby(1, 4)
	wire.step(0)
	var lobby_id: int = s[3].named("lobby_created")[0][1]
	_t._check(
		SteamEmulator.lobby_owner(lobby_id) == a.steam_id and lobby_id >> 56 == 0,
		"emulator: a lobby id names its owner (%x)" % lobby_id
	)
	var start_a: int = a.getLocalTimestamp()
	var start_b: int = b.getLocalTimestamp()
	wire.step(7)
	_t._check(
		(
			start_a != start_b
			and start_a != wire.clock.usec
			and a.getLocalTimestamp() - start_a == 7000
		),
		"emulator: getLocalTimestamp runs on the wire's clock, from its own origin per emulator"
	)


func _test_lobby() -> void:
	var s := _setup(4)
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	var c = s[3]
	var rec_a = s[5]
	var rec_b = s[6]
	var rec_c = s[7]
	a.createLobby(1, 2)
	_t._check(rec_a.events.empty(), "emulator: callbacks wait for poll(), as Steam's run_callbacks")
	wire.step(0)
	var lobby_id: int = rec_a.named("lobby_created")[0][1]
	_t._check(
		(
			rec_a.named("lobby_created") == [[1, lobby_id]]
			and rec_a.named("lobby_joined") == [[lobby_id, 0, false, 1]]
		),
		"emulator: createLobby gives lobby_created and the owner's own lobby_joined"
	)
	a.setLobbyData(lobby_id, "tag", "v1")
	b.joinLobby(lobby_id)
	wire.step(0)
	_t._check(
		(
			rec_b.named("lobby_joined") == [[lobby_id, 0, false, 1]]
			and b.getLobbyData(lobby_id, "tag") == "v1"
			and b.getLobbyOwner(lobby_id) == a.steam_id
			and b.getNumLobbyMembers(lobby_id) == 2
			and b.getLobbyMemberByIndex(lobby_id, 0) == a.steam_id
			and b.getLobbyMemberByIndex(lobby_id, 1) == b.steam_id
			and rec_a.named("lobby_chat_update") == [[lobby_id, b.steam_id, b.steam_id, 1]]
		),
		"emulator: a join enters the owner's lobby, with its data, and the owner sees it"
	)
	_t._check(
		(
			b.getFriendPersonaName(a.steam_id) == "P1"
			and a.getFriendPersonaName(b.steam_id) == "P2"
			and a.getFriendPersonaName(REAL_STEAM_ID) == "[unknown]"
			and b.getPersonaName() == "P2"
		),
		"emulator: persona names travel with the lobby"
	)
	c.joinLobby(lobby_id)
	wire.step(0)
	var full: Array = rec_c.named("lobby_joined")
	b.leaveLobby(lobby_id)
	wire.step(0)
	_t._check(
		(
			full == [[lobby_id, 0, false, SteamEmulator.ENTER_FULL]]
			and rec_a.named("lobby_chat_update").back() == [lobby_id, b.steam_id, b.steam_id, 2]
			and b.getNumLobbyMembers(lobby_id) == 0
			and a.getNumLobbyMembers(lobby_id) == 1
		),
		"emulator: a full lobby refuses a join (%s); a member leaves" % [full]
	)
	a.setLobbyJoinable(lobby_id, false)
	c.joinLobby(lobby_id)
	c.joinLobby(SteamEmulator.FAKE_LOBBY_BASE + (99 << 8) + 1)  # owner 99 is on no wire
	var offline = SteamEmulator.new(9)
	var rec_offline = Recorder.new(offline)
	offline.joinLobby(lobby_id)
	offline.poll()
	wire.step(0)
	var answers: Array = rec_c.named("lobby_joined")
	_t._check(
		(
			answers.size() == 3
			and answers[1][3] == SteamEmulator.ENTER_NOT_ALLOWED
			and answers[2][3] == SteamEmulator.ENTER_DOESNT_EXIST
			and rec_offline.named("lobby_joined")[0][3] == SteamEmulator.ENTER_ERROR
			and not b.setLobbyData(lobby_id, "tag", "x")
		),
		"emulator: not joinable, no such lobby, no wire; only the owner sets data (%s)" % [answers]
	)
	a.setLobbyJoinable(lobby_id, true)
	b.joinLobby(lobby_id)
	wire.step(0)
	a.leaveLobby(lobby_id)
	wire.step(0)
	_t._check(
		(
			rec_b.named("lobby_chat_update").back() == [lobby_id, a.steam_id, a.steam_id, 2]
			and b.getLobbyOwner(lobby_id) == b.steam_id
			and b.getNumLobbyMembers(lobby_id) == 1
		),
		"emulator: the owner leaving hands the lobby to the next member"
	)


func _test_send_results() -> void:
	var s := _setup(2)
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	var data := _bytes(16)
	var results := [
		a.sendMessageToUser(0, data, RELIABLE, 0),
		a.sendMessageToUser(a.steam_id, data, RELIABLE, 0),
		a.sendMessageToUser(b.steam_id, _bytes(SteamEmulator.MAX_MESSAGE_BYTES + 1), RELIABLE, 0),
		a.sendMessageToUser(b.steam_id, data, RELIABLE, -1),
		SteamEmulator.new(9).sendMessageToUser(b.steam_id, data, RELIABLE, 0),
		a.sendMessageToUser(b.steam_id, _bytes(400000), RELIABLE, 0),
		a.sendMessageToUser(b.steam_id, _bytes(200000), UNRELIABLE, 1),
	]
	_t._check(
		results == [8, 8, 8, 8, 3, 1, 25],
		"emulator: InvalidParam (no id, self, > 512 KB, bad channel), NoConnection (no wire), OK,"
		+ " LimitExceeded (512 KB queued) (%s)" % [results]
	)
	b.acceptSessionWithUser(a.steam_id)
	a.fail_session(b.steam_id)
	wire.step(0)
	var plain: int = a.sendMessageToUser(b.steam_id, data, 8, 0)
	var restart: int = a.sendMessageToUser(b.steam_id, data, RELIABLE, 0)
	_t._check(
		plain == 3 and restart == 1,
		"emulator: a broken session gives NoConnection without AUTO_RESTART, opens again with it"
	)


func _test_sessions() -> void:
	var s := _setup(3)
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	var c = s[3]
	var rec_b = s[5]
	var rec_c = s[6]
	for i in 5:
		a.sendMessageToUser(b.steam_id, _bytes(8, i), RELIABLE, 0)
	a.sendMessageToUser(b.steam_id, _bytes(8, 77), UNRELIABLE, 1)
	wire.step(0)
	wire.step(3)
	var held: Array = b.receiveMessagesOnChannel(0, 10)
	var waiting: int = a.getSessionConnectionInfo(b.steam_id, true, true).connection_state
	_t._check(
		rec_b.named("session_request") == [[a.steam_id]] and held.empty() and waiting == 1,
		"emulator: a new session is a request; its messages wait for the accept (state %d)" % waiting
	)
	var received_at: int = b.getLocalTimestamp()
	_t._check(
		b.acceptSessionWithUser(a.steam_id) and not b.acceptSessionWithUser(9),
		"emulator: acceptSessionWithUser true for a request, false without one"
	)
	var first: Array = b.receiveMessagesOnChannel(0, 2)
	var rest: Array = b.receiveMessagesOnChannel(0, 10)
	var other: Array = b.receiveMessagesOnChannel(1, 10)
	_t._check(
		(
			_numbers(first) == [0, 1]
			and _numbers(rest) == [2, 3, 4]
			and _numbers(other) == [77]
			and first[0].identity == a.steam_id
			and first[0].channel == 0
			and first[0].size == 8
			and first[0].time_received == received_at
			and a.getSessionConnectionInfo(b.steam_id, true, true).connection_state == 3
		),
		"emulator: accepted, the messages come per channel, in order, up to max_messages,"
		+ " with sender and receive time; the sender's session is connected"
	)
	b.sendMessageToUser(a.steam_id, _bytes(8, 5), UNRELIABLE, 1)
	wire.step(0)
	_t._check(
		_numbers(a.receiveMessagesOnChannel(1, 10)) == [5] and s[4].named("session_request").empty(),
		"emulator: the other way needs no request (the opener accepted)"
	)
	b.closeSessionWithUser(a.steam_id)
	var closed: Dictionary = a.getSessionConnectionInfo(b.steam_id, true, true)
	a.sendMessageToUser(b.steam_id, _bytes(8, 6), RELIABLE, 0)
	wire.step(0)
	wire.step(0)
	_t._check(
		(
			closed.connection_state == 4
			and closed.end_reason == 1000
			and rec_b.named("session_request").size() == 2
		),
		"emulator: closeSessionWithUser closes the peer's side too; its next send is a new request"
	)
	c.sendMessageToUser(b.steam_id, _bytes(8), RELIABLE, 0)
	wire.step(0)
	_run(wire, b.accept_timeout_msec + 10)
	var failed: Array = rec_c.named("session_failed")
	_t._check(
		failed.size() == 1 and failed[0][0] == 5003 and failed[0][1] == b.steam_id,
		"emulator: a session nobody accepts fails at the sender after %d ms (%s)"
		% [b.accept_timeout_msec, failed]
	)


func _test_pacing() -> void:
	var s := _setup(2)
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	_connect(wire, a, b)
	var rate := 100000
	a.setGlobalConfigValueInt32(a._config_rate_max, rate)
	a.setGlobalConfigValueInt32(a._config_rate_min, rate)
	for i in 10:
		a.sendMessageToUser(b.steam_id, _bytes(10000, i), RELIABLE, 0)
	wire.step(0)
	var info: Dictionary = a.getSessionConnectionInfo(b.steam_id, true, true)
	_run(wire, 500)
	var half: Array = _numbers(b.receiveMessagesOnChannel(0, 100))
	_run(wire, 500)
	var rest: Array = _numbers(b.receiveMessagesOnChannel(0, 100))
	_t._check(
		(
			a.send_rate() == rate
			and info.send_rate == rate
			and info.pending_reliable == 90000
			and info.queue_time > 900000
			and half == [0, 1, 2, 3, 4]
			and rest == [5, 6, 7, 8, 9]
		),
		"emulator: 100 KB at 100 KB/s take a second: half in 500 ms (%s, queue %d us)"
		% [half, info.queue_time]
	)


func _test_link() -> void:
	var s := _setup(2)
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	_connect(wire, a, b)
	a.set_link({"latency_msec": 40})
	a.sendMessageToUser(b.steam_id, _bytes(8, 1), UNRELIABLE, 1)
	_run(wire, 35)
	var early: int = b.receiveMessagesOnChannel(1, 10).size()
	_run(wire, 10)
	_t._check(
		early == 0 and b.receiveMessagesOnChannel(1, 10).size() == 1,
		"emulator: latency delays a message"
	)
	_t._check(
		not a.set_link({"latency": 1}) and a.set_link({"latency_msec": 0, "loss": 1.0}),
		"emulator: set_link refuses unknown keys"
	)
	for i in 5:
		a.sendMessageToUser(b.steam_id, _bytes(8, i), UNRELIABLE, 1)
	_run(wire, 50)
	_t._check(
		b.receiveMessagesOnChannel(1, 10).empty() and a.dropped_count == 5,
		"emulator: loss drops unreliable messages"
	)
	a.seed_link(3)
	a.set_link({"loss": 0.5})
	for i in 20:
		a.sendMessageToUser(b.steam_id, _bytes(8, i), RELIABLE, 0)
	wire.step(0)
	var at_once: int = b.receiveMessagesOnChannel(0, 100).size()
	_run(wire, 2000)
	var later: Array = _numbers(b.receiveMessagesOnChannel(0, 100))
	_t._check(
		at_once < 20 and at_once + later.size() == 20 and later == range(at_once, 20),
		"emulator: lost reliable messages come later, in order (%d at once)" % at_once
	)
	a.seed_link(7)
	a.set_link({"loss": 0.0, "latency_msec": 50, "jitter_msec": 40})
	for i in 30:
		a.sendMessageToUser(b.steam_id, _bytes(8, i), RELIABLE, 0)
		a.sendMessageToUser(b.steam_id, _bytes(8, i), UNRELIABLE, 1)
	_run(wire, 200)
	var reliable: Array = _numbers(b.receiveMessagesOnChannel(0, 100))
	var unreliable: Array = _numbers(b.receiveMessagesOnChannel(1, 100))
	var sorted := unreliable.duplicate()
	sorted.sort()
	_t._check(
		reliable == range(30) and sorted == range(30) and unreliable != sorted,
		"emulator: jitter reorders unreliable messages, never reliable ones"
	)
	a.set_link({"latency_msec": 0, "jitter_msec": 0})
	a.stall(300)
	a.sendMessageToUser(b.steam_id, _bytes(8, 1), RELIABLE, 0)
	_run(wire, 290)
	var stalled: int = b.receiveMessagesOnChannel(0, 10).size()
	_run(wire, 15)
	_t._check(
		stalled == 0 and b.receiveMessagesOnChannel(0, 10).size() == 1,
		"emulator: a stall holds what is sent until it ends"
	)


func _test_session_failure() -> void:
	var s := _setup(3)
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	var c = s[3]
	var rec_a = s[4]
	var rec_b = s[5]
	_connect(wire, a, b)
	a.fail_session(b.steam_id, 5008, "rendezvous")
	wire.step(0)
	var info: Dictionary = a.getSessionConnectionInfo(b.steam_id, true, true)
	_t._check(
		(
			rec_a.named("session_failed") == [[5008, b.steam_id, 5, "rendezvous"]]
			and rec_b.named("session_failed") == [[5008, a.steam_id, 5, "rendezvous"]]
			and info.end_reason == 5008
			and "P2P rendezvous failed" in LinkWatch.describe(info)
		),
		"emulator: a failed session reports Steam's end reason on both sides"
	)
	a.sendMessageToUser(b.steam_id, _bytes(8, 4), RELIABLE, 0)
	wire.step(0)
	wire.step(0)
	b.acceptSessionWithUser(a.steam_id)
	_t._check(
		(
			_numbers(b.receiveMessagesOnChannel(0, 10)) == [4]
			and rec_b.named("session_request").size() == 2
			and a.getSessionConnectionInfo(b.steam_id, true, true).connection_state == 3
		),
		"emulator: the next send opens a new session, the peer accepts it"
	)
	a.createLobby(1, 4)
	wire.step(0)
	var lobby_id: int = rec_a.named("lobby_created")[0][1]
	c.joinLobby(lobby_id)
	c.sendMessageToUser(a.steam_id, _bytes(8), RELIABLE, 0)
	wire.step(0)
	a.acceptSessionWithUser(c.steam_id)
	wire.unplug(c.steam_id)
	wire.step(0)
	_t._check(
		(
			rec_a.named("lobby_chat_update").back() == [lobby_id, c.steam_id, c.steam_id, 4]
			and rec_a.named("session_failed").back()[0] == 4001
			and a.getNumLobbyMembers(lobby_id) == 1
			and c.sendMessageToUser(a.steam_id, _bytes(8), RELIABLE, 0) == 3
		),
		"emulator: a game gone from the wire disconnects from the lobby, its session fails"
	)


func _test_connection_info() -> void:
	var s := _setup(2)
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	_t._check(
		(
			a.getSessionConnectionInfo(b.steam_id, true, true).connection_state == 0
			and LinkWatch.describe(a.getSessionConnectionInfo(b.steam_id, true, true)) == ""
		),
		"emulator: no session, no path"
	)
	_connect(wire, a, b)
	var direct: Dictionary = a.getSessionConnectionInfo(b.steam_id, true, true)
	a.setGlobalConfigValueInt32(a._config_ice, 0)  # Transport.apply_route's relay-only
	a.set_link({"latency_msec": 20, "relay_latency_msec": 5})
	a.sendMessageToUser(b.steam_id, _bytes(8), RELIABLE, 0)
	a.sendMessageToUser(b.steam_id, _bytes(1000), RELIABLE, 0)
	wire.step(0)
	var relayed: Dictionary = a.getSessionConnectionInfo(b.steam_id, true, true)
	_run(wire, 30)
	var peer_view: Dictionary = b.getSessionConnectionInfo(a.steam_id, true, false)
	_t._check(
		(
			LinkWatch.describe(direct) == "direct"
			and direct.ping == 0
			and LinkWatch.describe(relayed) == "relayed via lcl"
			and relayed.info_flags & LinkWatch.FLAG_RELAYED
			and relayed.ping == 50
			and relayed.sent_unacknowledged_reliable == 1008
			and relayed.pending_reliable == 0
			and LinkWatch.describe(peer_view) == "relayed via lcl"
		),
		"emulator: path, ping and unacked bytes from its own link; relay-only on one side relays"
		+ " both (%s, %s)" % [LinkWatch.describe(direct), relayed]
	)


func _test_recorded() -> void:
	var s := _setup(1)
	var wire = s[0]
	var a = s[1]
	var rec_a = s[2]
	a.initRelayNetworkAccess()
	a.setRichPresence("connect", "+connect_lobby 5")
	a.setRichPresence("status", "x")
	a.setRichPresence("status", "")
	var presence: Dictionary = a.rich_presence.duplicate()
	a.clearRichPresence()
	a.activateGameOverlayInviteDialog(42)
	a.fire_join_requested(43, 2)
	var before: int = rec_a.named("join_requested").size()
	wire.step(0)
	var ok: bool = a.setGlobalConfigValueInt32(104, 0)
	_t._check(
		(
			a.relay_inits == 1
			and str(presence) == str({"connect": "+connect_lobby 5"})
			and a.rich_presence.empty()
			and a.presence_log.size() == 4
			and a.invite_dialogs == [42]
			and before == 0
			and rec_a.named("join_requested") == [[43, 2]]
			and ok
			and a.config_values.get(104) == 0
			and "emulator" in a.get_godotsteam_version()
		),
		"emulator: relay init, rich presence, invite dialog and config recorded;"
		+ " join_requested fires on the next poll"
	)


func _test_dev_mod() -> void:
	var dev: Node = _t.get_node_or_null(DEV_MOD_PATH)
	_t._check(
		dev != null and not dev.active and dev.note == "Local play off: BT_LOCAL_ROLE is not set",
		"emulator: the dev mod loads and stays inert without BT_LOCAL_ROLE (%s)"
		% (dev.note if dev != null else "not loaded")
	)
	var own := ["C:/Users/x/AppData/Roaming/Brotato"]
	var instance := "C:\\Users\\x\\AppData\\Local\\brotato-modtools\\play\\1\\appdata\\Brotato"
	var cases := [
		[LocalMain.refusal("", 0, false, instance, own), "BT_LOCAL_ROLE is not set"],
		[LocalMain.refusal("spectator", 0, false, instance, own), "none of"],
		[LocalMain.refusal("host", REAL_STEAM_ID, false, instance, own), "Steam is logged on"],
		[LocalMain.refusal("host", 0, true, instance, own), "Steam build"],
		[LocalMain.refusal("host", 0, false, "", own), "no user folder"],
		[
			LocalMain.refusal("client", 0, false, "c:\\users\\x\\AppData\\Roaming\\Brotato\\", own),
			"the game's own",
		],
	]
	var wrong := []
	for case in cases:
		if not case[1] in case[0]:
			wrong.append(case)
	_t._check(
		wrong.empty() and LocalMain.refusal("client", 0, false, instance, own) == "",
		"emulator: the dev mod refuses without a role, with Steam logged on, in the Steam build"
		+ " and in the game's own user folder (%s)" % [wrong]
	)
	# The test copy of tools/check-window.ps1 has a user folder of its own (BrotatoModTests); the
	# container runs with the game's name under HOME, which counts as the game's own.
	var user_dir := OS.get_user_data_dir()
	var here: String = LocalMain.refusal("host", 0, false, user_dir, LocalMain.own_user_dirs())
	var own_name: bool = user_dir.replace("\\", "/").get_file() == "Brotato"
	_t._check(
		("the game's own" in here) == own_name,
		"emulator: this game's user folder is refused exactly when it is the game's own (%s: %s)"
		% [user_dir, here]
	)
