extends Reference
# Session lifecycle without Steam: a fake GodotSteam object stands in for the transport.
# Synchronous on purpose: no frame passes while the fake lobby is up, so the sync modules'
# _process (which would act on the fake host/client role) never runs.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const LinkWatch := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/link_watch.gd")
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

var _t: Node = null
var _together: Node = null
var _steam = null
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
	var invited := []  # lobby ids the invite dialog was opened for
	var presence := {}
	var inbox := []  # messages Steam has received and the game has not read yet
	var config_values := {}  # ESteamNetworkingConfigValue -> value set
	var config_accepted := true

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

	func activateGameOverlayInviteDialog(lobby_id: int) -> void:
		invited.append(lobby_id)

	func setLobbyData(_lobby_id: int, _key: String, _value: String) -> bool:
		return true

	func setLobbyJoinable(_lobby_id: int, _joinable: bool) -> bool:
		return true

	func setGlobalConfigValueInt32(config: int, value: int) -> bool:
		config_values[config] = value
		return config_accepted

	func getNumLobbyMembers(_lobby_id: int) -> int:
		return lobby_members.size()

	func getLobbyMemberByIndex(_lobby_id: int, index: int) -> int:
		return lobby_members[index]


# Joining someone else's lobby.
class JoinSteam:
	extends FakeSteam
	var lobby_tag := ""
	var lobby_owner := 0

	func getLobbyData(_lobby_id: int, _key: String) -> String:
		return lobby_tag

	func getLobbyOwner(_lobby_id: int) -> int:
		return lobby_owner


# getSessionConnectionInfo only, for the session path (net/link_watch.gd).
class PathSteam:
	extends Reference
	var infos := {}  # steam id -> getSessionConnectionInfo's answer

	func getSessionConnectionInfo(steam_id: int, _connection: bool, _status: bool) -> Dictionary:
		return infos.get(steam_id, {})


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
	_test_lobby_colors(transport, input_sync)
	_test_leave_confirmation(transport)
	_test_client_handshake(transport, session)
	_test_host_handshake(transport, session, input_sync)
	_test_ping(transport, session)
	_test_compat()
	_test_join_presence(transport)
	_test_relay_route(transport)
	_test_send_rate(transport)

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
	close_page(together.get_node("LobbyMenu"))


func _on_peer_ready(_steam_id: int) -> void:
	_peer_ready_count += 1


# The lobby page (popup, or in the current scene's menu) closed again, whatever it shows.
static func close_page(lobby: Node) -> void:
	for _step in 2:  # the question, then the page
		var page = lobby.open_page()
		if page != null:
			page.back()


func _enter_lobby(transport: Node, host_id: int, members: Array) -> void:
	transport.lobby_id = LOBBY
	transport.host_id = host_id
	transport.members = members.duplicate()
	_steam.lobby_members = [LOCAL] + members
	_together.session._on_lobby_ready(LOBBY, host_id == LOCAL)


# The shop resume path put the host's run into ProgressData.saved_run_state and nothing put the
# client's own back, so "Continue" (and the next save) used the host's run.
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


# lobby_left cleared every co-op slot even on the host, destroying a running run.
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


# Colour picks belong to the player while the lobby lives (an empty slot list between runs keeps
# them). Once the host closed it, a player keeps its pick only while it stays in its slot.
func _test_lobby_colors(transport: Node, input_sync: Node) -> void:
	var device := VirtualDevices.FIRST + 1
	var keyboard: int = CoopService.KEYBOARD_REMAPPED_DEVICE_ID
	var host := [keyboard, CoopService.PlayerType.KEYBOARD_AND_MOUSE]
	var remote := [device, CoopService.PlayerType.GAMEPAD_XBOX]
	for listening in [false, true]:
		_steam.lobby_members = [LOCAL]
		transport._on_lobby_created(transport.RESULT_OK, LOBBY)
		input_sync.devices = {CLIENT: device}
		CoopService.listening_for_inputs = listening
		CoopService.connected_players = [host, remote]
		CoopService.bt_apply_colors()
		var picked: bool = CoopService.bt_cycle_color(0) and CoopService.bt_cycle_color(1)
		var picks: Array = CoopService.bt_slot_colors.duplicate()
		CoopService.clear_coop_players()
		CoopService.connected_players = [remote, host]
		CoopService.bt_apply_colors()
		var slots: Array = CoopService.bt_slot_colors.duplicate()
		_t._check(
			picked and slots[0] == picks[1] and slots[1] == picks[0],
			"lobby colours: the next run keeps both picks, in the players' new slots (%s, %s)"
			% [picks, slots]
		)
		CoopService.connected_players = [host, remote]
		CoopService.bt_apply_colors()
		transport.leave_lobby()
		CoopService.bt_apply_colors()
		slots = CoopService.bt_slot_colors
		if not listening:
			_t._check(
				CoopService.connected_players.size() == 2 and slots[0] == picks[0] and slots[1] == picks[1],
				"lobby colours: the host leaving mid-run keeps both slots' picks (%s)" % [slots]
			)
		else:
			_t._check(
				CoopService.connected_players.size() == 1 and slots[0] == picks[0],
				"lobby colours: the host leaving before the run keeps its own pick (%s)" % [slots]
			)
		CoopService.clear_coop_players()
		input_sync.devices = {CLIENT: device}
		CoopService.connected_players = [host, remote]
		CoopService.bt_apply_colors()
		_t._check(
			CoopService.bt_slot_colors == [0, 1, 2, 3],
			"lobby colours: the next run after the lobby closed has no pick (%s)"
			% [CoopService.bt_slot_colors]
		)
		CoopService.connected_players.clear()
		CoopService.bt_apply_colors()
	CoopService.listening_for_inputs = false
	input_sync.devices = {}
	# A client's lobby opens and closes the picks the same way.
	var steam := JoinSteam.new()
	steam.lobby_tag = transport._lobby_tag
	steam.lobby_owner = HOST
	steam.lobby_members = [LOCAL, HOST]
	transport.steam = steam
	transport._on_lobby_joined(LOBBY, 0, false, transport.LOBBY_ENTER_SUCCESS)
	var opened: bool = transport.is_active() and not transport.is_host() and CoopService._bt_lobby
	transport.leave_lobby()
	transport.steam = _steam
	_t._check(
		opened and not CoopService._bt_lobby,
		"lobby colours: a client joining opens them, leaving closes them"
	)


# Wherever the page shows here (the scene's menu or the popup): lobby_menu_tests.gd has the places.
func _test_leave_confirmation(transport: Node) -> void:
	var lobby: Node = _together.get_node("LobbyMenu")
	_enter_lobby(transport, HOST, [HOST])
	Puppet.set_active(true)
	_t._check(lobby.is_mid_run(), "puppet run counts as mid-run")
	lobby.ask_leave()
	var page = lobby.open_page()
	_t._check(page != null and transport.is_active(), "Leave mid-run opens the page and only asks")
	if page == null:
		return
	var question: String = page._confirm.get_node("Buttons/Label").text
	_t._check(page.is_asking() and tr("BT_LEAVE_QUESTION") in question, "leave confirmation shown")
	page._on_confirm_yes()
	_t._check(not transport.is_active(), "confirming leaves")
	close_page(lobby)

	_enter_lobby(transport, HOST, [HOST])
	Puppet.set_active(true)
	_steam.joined.clear()
	transport._on_join_requested(555, 9)
	page = lobby.open_page()
	_t._check(
		transport.is_active() and _steam.joined.empty() and page != null,
		"invite mid-run waits for confirmation, on the lobby page"
	)
	_t._check(page._join_button.visible, "join invite button shown")
	page._on_join_pressed()
	_t._check(not transport.is_active() and _steam.joined == [555], "confirmed invite joins")
	_t._check(not Puppet.is_active(), "joining elsewhere ends puppet mode")
	close_page(lobby)

	_enter_lobby(transport, LOCAL, [])
	_steam.joined.clear()
	transport._on_join_requested(556, 9)
	_t._check(_steam.joined == [556], "invite outside a run joins directly")


# A lost HELLO left the client "connecting" forever: it is resent until WELCOME.
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

	var lobby: Node = _together.get_node("LobbyMenu")
	_enter_lobby(transport, HOST, [HOST])
	session._on_peer_joined(HOST)
	var rejected := {"version": Protocol.VERSION, "accepted": false, "reason": "game version x"}
	_deliver(session, HOST, Protocol.Msg.WELCOME, rejected)
	_t._check(not transport.is_active(), "rejected client leaves the lobby")
	_t._check(
		"game version x" in lobby.last_error and "! The host rejected" in lobby.details_text(),
		"rejection reason in the lobby page's details (%s)" % lobby.last_error
	)
	_t._check(lobby.open_page() == null, "an error opens nothing by itself")
	lobby.last_error = ""
	_test_coded_rejections(transport, session, lobby)


# The host's code and args are shown in the client's language; an unknown code shows the reason.
func _test_coded_rejections(transport: Node, session: Node, lobby: Node) -> void:
	var saved_locale := TranslationServer.get_locale()
	var shown := []
	var expected := []
	var args := ["0.0.1", "0.0.2"]
	for code in ["mod", "later"]:
		_enter_lobby(transport, HOST, [HOST])
		session._on_peer_joined(HOST)
		TranslationServer.set_locale("de")
		var body := {
			"version": Protocol.VERSION, "accepted": false, "reason": "an English reason",
			"code": code, "args": args,
		}
		_deliver(session, HOST, Protocol.Msg.WELCOME, body)
		shown.append(lobby.last_error)
		var reason: String = (
			Text.text("BT_REJECT_MOD", args) if code == "mod" else "an English reason"
		)
		expected.append(Text.text("BT_ERR_REJECTED", [reason]))
		TranslationServer.set_locale(saved_locale)
		lobby.last_error = ""
	var english: String = Text.text("BT_ERR_REJECTED", [Text.text("BT_REJECT_MOD", args)])
	_t._check(
		shown == expected and shown[0] != english and "0.0.1" in shown[0],
		"rejection by code in the client's language, an unknown code by reason %s" % [shown]
	)


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
	_t._check(
		answer.get("code") == "game"
		and answer.get("args") == ["0.0.0", str(ProgressData.VERSION)],
		"the rejection's code and args go along, for the client's language (%s)" % [answer]
	)
	input_sync.devices.erase(CLIENT)


# Messages are read once a frame, so a frame that stalled on either side (a scene load, a big run
# state) showed as ping: the ping is the network's round trip only.
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
	# No receive time and no "held": the stalls are all in it.
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
	var codes := []
	for change in [["version", 0], ["game_version", "0.0.0"], ["mod_version", "0.0.1"]]:
		client = host.duplicate()
		client[change[0]] = change[1]
		codes.append(Compat.rejection(host, client).code)
	codes.append(Compat.rejection(host, "x").code)
	_t._check(codes == ["protocol", "game", "mod", ""], "rejection codes %s" % [codes])
	var two := ["1", "2"]
	_t._check(
		Compat.describe({"code": "game", "args": two, "reason": "r"})
		== Text.text("BT_REJECT_GAME", two)
		and Compat.describe({"code": "game", "args": ["1"], "reason": "r"}) == "r"
		and Compat.describe({"reason": "r"}) == "r",
		"a rejection's text: by its code, else its reason"
	)


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


# Sessions go through Steam's relays only (its direct (ICE) route off) unless +bt_direct is given.
# Steam refusing the setting, or a GodotSteam without it, is never claimed as relay-only.
func _test_relay_route(transport: Node) -> void:
	var saved_watch = transport.link_watch
	transport.link_watch = LinkWatch.new()
	_steam.config_values.clear()
	_t._check(
		(
			transport.apply_route(["--foo", "+connect_lobby", "5"])
			and transport.relay_only
			and transport.link_watch.relay_only
			and _steam.config_values.size() == 1
			and _steam.config_values.get(104) == 0
			and "relays only (default" in transport.route_note
		),
		"route: relay-only by default %s (%s)" % [_steam.config_values, transport.route_note]
	)
	_steam.config_values.clear()
	_t._check(
		(
			not transport.apply_route(["+bt_direct"])
			and not transport.relay_only
			and not transport.link_watch.relay_only
			and _steam.config_values.empty()
			and "+bt_direct" in transport.route_note
		),
		"route: +bt_direct leaves Steam's direct route alone (%s)" % transport.route_note
	)
	_t._check(
		(
			transport.apply_route(["+bt_relay"])
			and transport.relay_only
			and _steam.config_values.get(104) == 0
			and "+bt_relay" in transport.route_note
			and "default" in transport.route_note
		),
		"route: +bt_relay still works and says it is the default (%s)" % transport.route_note
	)
	_steam.config_values.clear()
	_t._check(
		(
			not transport.apply_route(["+bt_relay", "+bt_direct"])
			and not transport.relay_only
			and _steam.config_values.empty()
		),
		"route: +bt_direct wins over +bt_relay (%s)" % transport.route_note
	)
	_steam.config_accepted = false
	_t._check(
		(
			not transport.apply_route([])
			and not transport.relay_only
			and not transport.link_watch.relay_only
			and "refused" in transport.route_note
			and not "relays only (" in transport.route_note
		),
		"route: not claimed when Steam refuses the setting (%s)" % transport.route_note
	)
	_steam.config_accepted = true
	transport.steam = Reference.new()  # a GodotSteam without setGlobalConfigValueInt32
	_t._check(
		not transport.apply_route([]) and not transport.relay_only and "cannot" in transport.route_note,
		"route: Steam's default without setGlobalConfigValueInt32 (%s)" % transport.route_note
	)
	transport.steam = _steam
	transport.relay_only = false
	transport.link_watch = saved_watch
	_test_direct_under_relay()


# Steam's send rate goes from its default 256 KB/s to 512 KB/s: SendRateMin (10) and SendRateMax
# (11) both, since Steam paces at the min for any real ping.
func _test_send_rate(transport: Node) -> void:
	var saved_rate: int = transport.send_rate
	var saved_watch = transport.link_watch
	transport.link_watch = LinkWatch.new()
	var rate: int = transport.SEND_RATE
	_steam.config_values.clear()
	_t._check(
		(
			transport.apply_send_rate()
			and transport.send_rate == rate
			and rate == 524288
			and _steam.config_values.size() == 2
			and _steam.config_values.get(10) == rate
			and _steam.config_values.get(11) == rate
			and transport.send_rate_note == "Send rate: up to 512 KB/s (Steam's default is 256)"
		),
		(
			"send rate: min and max set to 512 KB/s %s (%s)"
			% [_steam.config_values, transport.send_rate_note]
		)
	)
	_steam.config_values.clear()
	var relayed: bool = transport.apply_route([])
	var route_note: String = transport.route_note
	transport.apply_send_rate()
	_t._check(
		(
			relayed
			and transport.relay_only
			and transport.route_note == route_note
			and _steam.config_values.size() == 3
			and _steam.config_values.get(104) == 0
		),
		"send rate: the route's setting is left as it was %s" % [_steam.config_values]
	)
	_steam.config_values.clear()
	transport.apply_route(["+bt_direct"])
	_t._check(
		(
			transport.apply_send_rate()
			and not transport.relay_only
			and _steam.config_values.size() == 2
			and not _steam.config_values.has(104)
		),
		"send rate: set with +bt_direct too, the direct route untouched %s" % [_steam.config_values]
	)
	_steam.config_accepted = false
	_t._check(
		(
			not transport.apply_send_rate()
			and transport.send_rate == 0
			and "refused" in transport.send_rate_note
			and "default of 256 KB/s stays" in transport.send_rate_note
		),
		"send rate: not claimed when Steam refuses it (%s)" % transport.send_rate_note
	)
	_steam.config_accepted = true
	transport.steam = Reference.new()  # a GodotSteam without setGlobalConfigValueInt32
	_t._check(
		(
			not transport.apply_send_rate()
			and transport.send_rate == 0
			and "cannot" in transport.send_rate_note
			and "default of 256 KB/s stays" in transport.send_rate_note
		),
		"send rate: Steam's default without setGlobalConfigValueInt32 (%s)" % transport.send_rate_note
	)
	transport.steam = _steam
	transport.relay_only = false
	transport.send_rate = saved_rate
	transport.link_watch = saved_watch
	_steam.config_values.clear()


# A direct path although relay-only is on here (the other side runs an older build or +bt_direct):
# one warning per connection, none when relay-only is off.
func _test_direct_under_relay() -> void:
	var steam := PathSteam.new()
	steam.infos[CLIENT] = {"connection_state": 3, "ping": 20}
	var watch = LinkWatch.new()
	watch.relay_only = true
	watch.poll(steam, [CLIENT], 1000)
	var warned: String = watch.last_line
	watch.poll(steam, [CLIENT], 2000)
	steam.infos[CLIENT] = {"connection_state": 3, "info_flags": LinkWatch.FLAG_RELAYED}
	watch.poll(steam, [CLIENT], 3000)
	steam.infos[CLIENT] = {"connection_state": 3, "ping": 20}
	watch.poll(steam, [CLIENT], 4000)
	_t._check(
		(
			"direct although relay-only is on" in warned
			and watch.direct_warnings == 1
			and watch.lines == 4
		),
		"a direct path under relay-only is warned about once (%s)" % warned
	)
	watch.poll(steam, [], 5000)
	watch.poll(steam, [CLIENT], 6000)
	_t._check(watch.direct_warnings == 2, "a member who comes back is a new connection: warned again")
	var plain = LinkWatch.new()
	plain.poll(steam, [CLIENT], 1000)
	_t._check(plain.direct_warnings == 0 and plain.lines == 1, "no warning without relay-only")
