extends Reference
# Session lifecycle without Steam: a fake GodotSteam object stands in for the transport.
# Synchronous on purpose: no frame passes while the fake lobby is up, so the sync modules'
# _process (which would act on the fake host/client role) never runs.
#  - leaving as a client restores the client's own saved run / stats (session/puppet.gd)
#  - host leaving mid-run keeps the co-op slots; pre-run it frees them; F9 leave confirmation;
#    Steam invite while mid-run waits for confirmation
#  - HELLO resend until WELCOME, duplicate HELLO -> WELCOME again + resync, failed reliable
#    send -> resync, member join accepts the session
#  - join compatibility (game / mod version; DLC never rejects) with the reason shown on the client
#  - the ping is the network's round trip: not the frames either game let the messages wait

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const LOCAL := 1
const HOST := 2
const CLIENT := 5
const LOBBY := 99
const RESULT_NO_CONNECTION := 3
const STALL_MSEC := 60  # a frame that takes this long (a scene load takes several of these)
const TIMER_SLACK_MSEC := 40

var _t: Node = null  # test runner: _check()
var _together: Node = null
var _steam = null  # FakeSteam
var _peer_ready_count := 0


# gdlint: disable=function-name
class FakeSteam:
	extends Reference
	var sent := []  # [steam_id, channel, data]
	var send_result := 1
	var accepted := []
	var joined := []
	var lobby_members := []
	var created := 0
	var presence := {}
	var inbox := []  # messages Steam has received and the game has not read yet

	# stamped: with Steam's receive time, as GodotSteam delivers it.
	func queue(sender: int, channel: int, data: PoolByteArray, stamped := true) -> void:
		var message := {"identity": sender, "channel": channel, "payload": data}
		if stamped:
			message["time_received"] = getLocalTimestamp()
		inbox.append(message)

	# Steam's local clock: usec, with another start than the engine's.
	func getLocalTimestamp() -> int:
		return OS.get_ticks_usec() + 5000000000

	func getSessionConnectionInfo(_steam_id: int, _connection: bool, _status: bool) -> Dictionary:
		return {
			"ping": 21,
			"queue_time": 9000,
			"pending_reliable": 3000,
			"pending_unreliable": 40,
			"sent_unacknowledged_reliable": 0,
			"send_rate": 262144,
			"local_quality": 0.5,
		}

	func sendMessageToUser(steam_id: int, data: PoolByteArray, _flags: int, channel: int) -> int:
		sent.append([steam_id, channel, data])
		return send_result

	func receiveMessagesOnChannel(channel: int, _max: int) -> Array:
		var messages := []
		for message in inbox.duplicate():
			if message.channel == channel:
				messages.append(message)
				inbox.erase(message)
		return messages

	func getPersonaName() -> String:
		return "local"

	func getFriendPersonaName(steam_id: int) -> String:
		return "friend %s" % steam_id

	func closeSessionWithUser(_steam_id: int) -> bool:
		return true

	func leaveLobby(_lobby_id: int) -> void:
		pass

	func setRichPresence(key: String, value: String) -> bool:
		if value == "":
			presence.erase(key)
		else:
			presence[key] = value
		return true

	func clearRichPresence() -> void:
		presence.clear()

	func acceptSessionWithUser(steam_id: int) -> bool:
		accepted.append(steam_id)
		return true

	func joinLobby(lobby_id: int) -> void:
		joined.append(lobby_id)

	func createLobby(_lobby_type: int, _max_members: int) -> void:
		created += 1

	func setLobbyData(_lobby_id: int, _key: String, _value: String) -> bool:
		return true

	func setLobbyJoinable(_lobby_id: int, _joinable: bool) -> bool:
		return true

	func getNumLobbyMembers(_lobby_id: int) -> int:
		return lobby_members.size()

	func getLobbyMemberByIndex(_lobby_id: int, index: int) -> int:
		return lobby_members[index]


# gdlint: enable=function-name


func run(t: Node, together: Node) -> void:
	_t = t
	_together = together
	var transport: Node = together.transport
	var session: Node = together.session
	var input_sync: Node = together.input_sync
	var saved := {
		"steam": transport.steam,
		"local_id": transport.local_id,
		"devices": input_sync.devices.duplicate(),
		"players": CoopService.connected_players.duplicate(true),
		"listening": CoopService.listening_for_inputs,
		"run_state": ProgressData.saved_run_state,
		"last_run_state": ProgressData.last_saved_run_state,
		"client_active": together._client_active,
	}
	_steam = FakeSteam.new()
	transport.steam = _steam
	transport.local_id = LOCAL
	session.connect("peer_ready", self, "_on_peer_ready")

	_test_client_leave_restores_own_run(transport)
	_test_host_leave(transport, input_sync)
	_test_leave_confirmation(transport)
	_test_client_handshake(transport, session)
	_test_host_handshake(transport, session, input_sync)
	_test_ping(transport, session)
	_test_compat()
	_test_join_presence(transport)

	session.disconnect("peer_ready", self, "_on_peer_ready")
	transport.leave_lobby()
	transport.steam = saved.steam
	transport.local_id = saved.local_id
	transport.pending_join_id = 0
	session.peers.clear()
	input_sync.devices = saved.devices
	CoopService.connected_players = saved.players
	CoopService.listening_for_inputs = saved.listening
	ProgressData.saved_run_state = saved.run_state
	ProgressData.last_saved_run_state = saved.last_run_state
	together._client_active = saved.client_active
	together.get_node("TogetherMenu").close()


func _on_peer_ready(_steam_id: int) -> void:
	_peer_ready_count += 1


func _enter_lobby(transport: Node, host_id: int, members: Array) -> void:
	transport.lobby_id = LOBBY
	transport.host_id = host_id
	transport.members = members.duplicate()
	_steam.lobby_members = [LOCAL] + members
	_together.session._on_lobby_ready(LOBBY, host_id == LOCAL)


# Finding: the shop resume path put the host's run into ProgressData.saved_run_state and nothing
# put the client's own back, so "Continue" (and the next save) used the host's run.
func _test_client_leave_restores_own_run(transport: Node) -> void:
	var own := {"has_run_state": true, "marker": "own"}
	ProgressData.saved_run_state = own.duplicate()
	ProgressData.last_saved_run_state = own.duplicate()
	var stats_before := var2str(ProgressData.data)
	var bought_before := var2str(ProgressData.items_bought)
	_enter_lobby(transport, HOST, [HOST])
	Puppet.set_active(true)
	ProgressData.saved_run_state = {"has_run_state": true, "marker": "host"}  # shop resume path
	ProgressData.data["enemies_killed"] = int(ProgressData.data.get("enemies_killed", 0)) + 99
	ProgressData.items_bought[123456] = 1
	Puppet.set_active(true)  # every battle/shop turns it on again: must not re-stash
	VirtualDevices.fill_puppet_slots(2)
	transport.leave_lobby()
	_t._check(not transport.was_host, "left as client")
	_t._check(not Puppet.is_active(), "client leave ends puppet mode")
	_t._check(
		ProgressData.saved_run_state.get("marker") == "own",
		"client's own saved run restored (%s)" % ProgressData.saved_run_state.get("marker")
	)
	_t._check(ProgressData.last_saved_run_state.get("marker") == "own", "last saved run restored")
	_t._check(var2str(ProgressData.data) == stats_before, "client's stats restored")
	_t._check(var2str(ProgressData.items_bought) == bought_before, "items bought restored")
	_t._check(CoopService.connected_players.empty(), "client puppet slots cleared")


# Finding: lobby_left cleared every co-op slot even on the host, destroying a running run.
func _test_host_leave(transport: Node, input_sync: Node) -> void:
	var device := VirtualDevices.FIRST + 1
	for listening in [false, true]:
		_enter_lobby(transport, LOCAL, [CLIENT])
		_together.session._add_peer(CLIENT).ready = true
		input_sync.devices = {CLIENT: device}
		CoopService.listening_for_inputs = listening
		CoopService.connected_players = [
			[0, CoopService.PlayerType.KEYBOARD_AND_MOUSE],
			[device, CoopService.PlayerType.GAMEPAD_XBOX],
		]
		transport.leave_lobby()
		_t._check(transport.was_host, "left as host")
		if not listening:
			_t._check(
				CoopService.connected_players.size() == 2,
				"host leaving mid-run keeps every co-op slot"
			)
			_t._check(input_sync.devices.get(CLIENT) == device, "remote slot kept for a rejoin")
		else:
			_t._check(
				CoopService.connected_players.size() == 1,
				"host leaving before the run frees the remote slot"
			)
			_t._check(input_sync.devices.empty(), "pre-run device mapping dropped")
	CoopService.listening_for_inputs = false
	CoopService.connected_players.clear()
	input_sync.devices = {}


func _test_leave_confirmation(transport: Node) -> void:
	var menu: Node = _together.get_node("TogetherMenu")
	_enter_lobby(transport, HOST, [HOST])
	Puppet.set_active(true)
	menu.open()
	_t._check(menu.is_mid_run(), "puppet run counts as mid-run")
	menu._on_leave_pressed()
	_t._check(transport.is_active(), "first Leave click mid-run only asks")
	_t._check(
		menu._confirm_box.visible and "Leave the lobby?" in menu._confirm_label.text,
		"leave confirmation shown"
	)
	menu._on_confirm_yes()
	_t._check(not transport.is_active(), "confirming leaves")
	menu.close()

	# Steam invite while mid-run: nothing happens until the player confirms.
	_enter_lobby(transport, HOST, [HOST])
	Puppet.set_active(true)
	_steam.joined.clear()
	transport._on_join_requested(555, 9)
	_t._check(
		transport.is_active() and _steam.joined.empty() and menu.is_open(),
		"invite mid-run waits for confirmation"
	)
	_t._check(menu._join_button.visible, "join invite button shown")
	menu._on_join_pressed()
	_t._check(not transport.is_active() and _steam.joined == [555], "confirmed invite joins")
	_t._check(not Puppet.is_active(), "joining elsewhere ends puppet mode")
	menu.close()

	# Outside a run an invite is taken right away (as before).
	_enter_lobby(transport, LOCAL, [])
	_steam.joined.clear()
	transport._on_join_requested(556, 9)
	_t._check(_steam.joined == [556], "invite outside a run joins directly")


# Finding: HELLO was sent once; a lost one left the client "connecting" forever.
func _test_client_handshake(transport: Node, session: Node) -> void:
	_together._client_active = true  # no client view scene switch on peer_ready
	_enter_lobby(transport, HOST, [HOST])
	_steam.sent.clear()
	var now := OS.get_ticks_msec()
	session._on_peer_joined(HOST)
	session.resend_hello(now + 500)
	_t._check(_count_sent(Protocol.Msg.HELLO) == 1, "HELLO sent on join")
	session.resend_hello(now + session.HELLO_INTERVAL_MSEC + 10)
	_t._check(_count_sent(Protocol.Msg.HELLO) == 2, "HELLO resent until WELCOME")
	var hello = _last_body(Protocol.Msg.HELLO)
	_t._check(
		hello.get("game_version") == ProgressData.VERSION
		and hello.get("mod_version") == Compat.mod_version()
		and typeof(hello.get("dlcs")) == TYPE_ARRAY,
		"HELLO carries game/mod version and DLCs (%s)" % [hello]
	)
	var welcome := {"version": Protocol.VERSION, "accepted": true, "reason": ""}
	_deliver(session, HOST, Protocol.Msg.WELCOME, welcome)
	_t._check(session.peers[HOST].ready, "WELCOME makes the host ready")
	session.resend_hello(now + 10 * session.HELLO_INTERVAL_MSEC)
	_t._check(_count_sent(Protocol.Msg.HELLO) == 2, "no HELLO after WELCOME")
	_together._client_active = false  # else leaving would switch to the title screen

	# Rejected: the reason reaches the F9 menu and the client leaves.
	var menu: Node = _together.get_node("TogetherMenu")
	_enter_lobby(transport, HOST, [HOST])
	session._on_peer_joined(HOST)
	var rejected := {"version": Protocol.VERSION, "accepted": false, "reason": "game version x"}
	_deliver(session, HOST, Protocol.Msg.WELCOME, rejected)
	_t._check(not transport.is_active(), "rejected client leaves the lobby")
	_t._check(
		"game version x" in menu._last_error and menu.is_open(),
		"rejection reason shown in the F9 menu (%s)" % menu._last_error
	)
	menu._last_error = ""
	menu.close()


func _test_host_handshake(transport: Node, session: Node, input_sync: Node) -> void:
	_enter_lobby(transport, LOCAL, [])
	# A session request from a joiner Steam doesn't list yet is rejected; the member join
	# accepts it, and its messages are let through after a member list refresh.
	_steam.lobby_members = [LOCAL, CLIENT]
	_steam.accepted.clear()
	transport._on_lobby_chat_update(LOBBY, CLIENT, CLIENT, transport.CHAT_MEMBER_ENTERED)
	_t._check(_steam.accepted.has(CLIENT), "member join accepts its message session")
	transport.members.clear()
	_t._check(transport._is_lobby_member(CLIENT), "unknown sender found after member refresh")

	_steam.sent.clear()
	_peer_ready_count = 0
	var hello := Compat.local_info("joiner")
	_deliver(session, CLIENT, Protocol.Msg.HELLO, hello)
	_t._check(session.peers[CLIENT].ready and _peer_ready_count == 1, "compatible HELLO accepted")
	_deliver(session, CLIENT, Protocol.Msg.HELLO, hello)
	_t._check(_count_sent(Protocol.Msg.WELCOME) == 2, "duplicate HELLO answered again")
	_t._check(
		_peer_ready_count == 1 and session.peers[CLIENT].resync,
		"duplicate HELLO queues a resync"
	)
	var now := OS.get_ticks_msec()
	session.process_resyncs(now)
	_t._check(_peer_ready_count == 2, "resync re-runs the peer_ready path")
	session.request_resync(CLIENT)
	session.process_resyncs(now + 10)
	_t._check(_peer_ready_count == 2, "resyncs are rate limited")

	session.process_resyncs(now + 2 * session.RESYNC_INTERVAL_MSEC)
	_t._check(_peer_ready_count == 3, "queued resync runs after the interval")

	_steam.send_result = RESULT_NO_CONNECTION
	session.send_unreliable(CLIENT, Protocol.Msg.PING, {"t": 0})
	_t._check(not session.peers[CLIENT].resync, "failed unreliable send needs no resync")
	session.send_reliable(CLIENT, Protocol.Msg.STATE, [])
	_steam.send_result = 1
	_t._check(session.peers[CLIENT].resync, "failed reliable send queues a resync")
	session.process_resyncs(now + 4 * session.RESYNC_INTERVAL_MSEC)
	_t._check(_peer_ready_count == 4, "failed reliable send -> full resync")

	var old_game := Compat.local_info("old")
	old_game.game_version = "0.0.0"
	_deliver(session, 6, Protocol.Msg.HELLO, old_game)
	var answer = _last_body(Protocol.Msg.WELCOME)
	_t._check(
		not answer.accepted and "game version 0.0.0" in answer.reason and not session.peers[6].ready,
		"other game version rejected: %s" % answer.reason
	)
	input_sync.devices.erase(CLIENT)


# Finding: the ping was the time until the PONG was handled. Messages are read once a frame, so
# a frame that stalled on either side (a scene load, a big run state) showed as ping.
func _test_ping(transport: Node, session: Node) -> void:
	_enter_lobby(transport, LOCAL, [CLIENT])
	var peer: Dictionary = session._add_peer(CLIENT)
	peer.ready = true
	var unreliable: int = transport.CHANNEL_UNRELIABLE
	var logged: int = session.slow_answers
	# Answering: the PING waits in Steam's queue for this game's frame.
	_steam.sent.clear()
	_steam.queue(CLIENT, unreliable, Protocol.encode(Protocol.Msg.PING, {"t": 7}))
	OS.delay_msec(STALL_MSEC)
	transport._process(0.0)
	var pong = _last_body(Protocol.Msg.PONG)
	var held: int = pong.get("held", -1)
	_t._check(
		pong.get("t") == 7 and held >= STALL_MSEC and held < STALL_MSEC + TIMER_SLACK_MSEC,
		"PONG says how long the PING waited for the frame (%d ms of %d)" % [held, STALL_MSEC]
	)
	# Asking, on a network without any delay: the other game's frame stalls, then this one's.
	_ask(session)
	var ping = _last_body(Protocol.Msg.PING)
	OS.delay_msec(STALL_MSEC)
	var answer := {"t": ping.get("t"), "held": STALL_MSEC}
	_steam.queue(CLIENT, unreliable, Protocol.encode(Protocol.Msg.PONG, answer))
	OS.delay_msec(STALL_MSEC)
	transport._process(0.0)
	_t._check(
		peer.answer_ms >= 2 * STALL_MSEC and peer.rtt_ms >= 0 and peer.rtt_ms < TIMER_SLACK_MSEC,
		"stalled frames are not ping (%d ms, %d ms with them)" % [peer.rtt_ms, peer.answer_ms]
	)
	# No receive time and no "held" (what the ping was before): the stalls are all in it.
	_ask(session)
	ping = _last_body(Protocol.Msg.PING)
	OS.delay_msec(STALL_MSEC)
	var plain: PoolByteArray = Protocol.encode(Protocol.Msg.PONG, {"t": ping.get("t")})
	_steam.queue(CLIENT, unreliable, plain, false)
	OS.delay_msec(STALL_MSEC)
	transport._process(0.0)
	_t._check(
		peer.rtt_ms == peer.answer_ms and peer.rtt_ms >= 2 * STALL_MSEC,
		"without Steam's receive time the ping holds the frames (%d ms)" % peer.rtt_ms
	)
	_t._check(_steam.inbox.empty(), "every queued message was read")
	_t._check(session.slow_answers == logged, "answers under the limit are not logged")
	# A late answer is logged with where its time went and what Steam says about the connection.
	_ask(session)
	ping = _last_body(Protocol.Msg.PING)
	var late := {"t": ping.get("t") - session.SLOW_ANSWER_MSEC, "held": 100}
	_steam.queue(CLIENT, unreliable, Protocol.encode(Protocol.Msg.PONG, late))
	transport._process(0.0)
	var text: String = session.slow_answer_text(CLIENT, 100, 0)
	_t._check(
		(
			session.slow_answers == logged + 1
			and "+ its frame 100 +" in text
			and "ping 21 ms, send queue 9000 us, pending 3000 + 40 B" in text
			and "quality 0.5 / ?" in text
		),
		"a late answer is logged with the frames and Steam's numbers (%s)" % text
	)
	session.peers.erase(CLIENT)


func _ask(session: Node) -> void:
	_steam.sent.clear()
	session._next_ping_msec = 0
	session._process(0.0)


func _test_compat() -> void:
	var host := Compat.local_info("host")
	host.dlcs = ["abyssal_terrors"]
	var client := host.duplicate()
	_t._check(Compat.incompatibility(host, client) == "", "same versions and DLCs join")
	client.dlcs = ["abyssal_terrors", "primal_dread"]
	_t._check(Compat.incompatibility(host, client) == "", "extra client DLC is fine")
	client.dlcs = []
	_t._check(Compat.incompatibility(host, client) == "", "client without the host's DLC joins")
	_t._check(Compat.missing_dlcs(host.dlcs, client.dlcs) == host.dlcs, "its missing DLC listed")
	client.dlcs = "abyssal_terrors"
	_t._check("DLC" in Compat.incompatibility(host, client), "malformed DLC list rejected")
	client = host.duplicate()
	client.dlcs = []
	client.game_version = "0.0.0"
	_t._check(
		"game version" in Compat.incompatibility(host, client),
		"other game version rejected, DLC or not"
	)
	client = host.duplicate()
	client.mod_version = "0.0.1"
	_t._check("0.0.1" in Compat.incompatibility(host, client), "other mod version rejected")
	client = host.duplicate()
	client.version = Protocol.VERSION - 1
	_t._check("protocol" in Compat.incompatibility(host, client), "other protocol rejected")
	_t._check(Compat.incompatibility(host, "x") != "", "malformed HELLO rejected")


func _deliver(session: Node, from: int, msg_type: int, body) -> void:
	var data := Protocol.encode(msg_type, bytes2var(var2bytes(body), false))
	session._on_message_received(from, 0, data)


func _count_sent(msg_type: int) -> int:
	var count := 0
	for entry in _steam.sent:
		var decoded = Protocol.decode(entry[2])
		if decoded != null and decoded[0] == msg_type:
			count += 1
	return count


func _last_body(msg_type: int):
	for i in range(_steam.sent.size() - 1, -1, -1):
		var decoded = Protocol.decode(_steam.sent[i][2])
		if decoded != null and decoded[0] == msg_type:
			return decoded[1]
	return {}


# The overlay's "Join game" button follows rich presence "connect": only in a lobby with room.
func _test_join_presence(transport: Node) -> void:
	transport.leave_lobby()
	_steam.presence["connect"] = "+connect_lobby 1"  # stale, e.g. from an earlier crash
	transport._clear_join_presence()
	_t._check(not _steam.presence.has("connect"), "no Join button outside a lobby")
	_steam.lobby_members = [LOCAL]
	transport._on_lobby_created(transport.RESULT_OK, LOBBY)
	_t._check(_steam.presence.get("connect", "") == "+connect_lobby %s" % LOBBY, "host: Join on")
	_steam.lobby_members = [LOCAL, 6, 7, 8]
	transport._on_lobby_chat_update(LOBBY, 8, 8, transport.CHAT_MEMBER_ENTERED)
	_t._check(not _steam.presence.has("connect"), "full lobby: Join off")
	_steam.lobby_members = [LOCAL, 6, 7]
	transport._on_lobby_chat_update(LOBBY, 8, 8, 2)  # 2 = left
	_t._check(_steam.presence.has("connect"), "slot free again: Join on")
	transport.leave_lobby()
	_t._check(not _steam.presence.has("connect") and transport.join_presence == "", "left: Join off")
