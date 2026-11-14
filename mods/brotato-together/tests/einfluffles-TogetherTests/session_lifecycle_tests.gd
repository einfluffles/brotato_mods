extends Reference
# Session lifecycle without Steam: a fake GodotSteam object stands in for the transport.
# Synchronous on purpose: no frame passes while the fake lobby is up, so the sync modules'
# _process (which would act on the fake host/client role) never runs.
#  - leaving as a client restores the client's own saved run / stats (session/puppet.gd)
#  - host leaving mid-run keeps the co-op slots; pre-run it frees them; F9 leave confirmation;
#    Steam invite while mid-run waits for confirmation
#  - HELLO resend until WELCOME, duplicate HELLO -> WELCOME again + resync, failed reliable
#    send -> resync, member join accepts the session
#  - join compatibility (game / mod version, DLC) with the reason shown on the client

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

	func sendMessageToUser(steam_id: int, data: PoolByteArray, _flags: int, channel: int) -> int:
		sent.append([steam_id, channel, data])
		return send_result

	func receiveMessagesOnChannel(_channel: int, _max: int) -> Array:
		return []

	func getPersonaName() -> String:
		return "local"

	func getFriendPersonaName(steam_id: int) -> String:
		return "friend %s" % steam_id

	func closeSessionWithUser(_steam_id: int) -> bool:
		return true

	func leaveLobby(_lobby_id: int) -> void:
		pass

	func setRichPresence(_key: String, _value: String) -> bool:
		return true

	func acceptSessionWithUser(steam_id: int) -> bool:
		accepted.append(steam_id)
		return true

	func joinLobby(lobby_id: int) -> void:
		joined.append(lobby_id)

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
	_test_compat()

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
	session.send_reliable(CLIENT, Protocol.Msg.SHOP_STATE, {})
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


func _test_compat() -> void:
	var host := Compat.local_info("host")
	host.dlcs = ["abyssal_terrors"]
	var client := host.duplicate()
	_t._check(Compat.incompatibility(host, client) == "", "same versions and DLCs join")
	client.dlcs = ["abyssal_terrors", "primal_dread"]
	_t._check(Compat.incompatibility(host, client) == "", "extra client DLC is fine")
	client.dlcs = []
	_t._check("DLC" in Compat.incompatibility(host, client), "missing host DLC rejected")
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
