# gdlint: disable=function-name, max-public-methods
extends Reference
# A stand-in for GodotSteam with exactly the methods and signals brotato:together uses
# (net/steam_transport.gd, net/link_watch.gd), for local play and tests. Transport.bind_steam
# takes it like the engine's singleton. Dev only: never packaged (mods/*/dev/).
#
# No sockets here. What leaves this object goes to a wire (attach_wire): wire_memory.gd for two or
# more emulators in one process, wire_tcp.gd for game processes on one PC (local play). A wire has
# send_packet(packet: Dictionary) -> bool (false: the peer is unknown or gone) and hands what it
# receives to receive_packet. Packets hold plain values only (var2bytes-safe).
#
# Lobbies live in the emulator that created them; members keep a copy the owner updates. Lobby
# traffic and session control reach the wire after the link's latency (no jitter, loss or stalls:
# Steam's servers carry them). Messages go through a session per peer: a send queue paced at the
# send rate or the line's (token bucket), then the link (link.gd: latency, jitter, loss, stalls; a
# profile from link_profiles.gd), then the wire. Callbacks (the signals) are emitted in poll(), as
# Steam runs them once a frame.
# Docs: docs/implementation.md, "Local play (dev mod)".

# GodotSteam's signals, as Transport.STEAM_SIGNALS connects them
signal lobby_created(result, lobby_id)
signal lobby_joined(lobby_id, permissions, locked, response)
signal join_requested(lobby_id, friend_id)
signal lobby_chat_update(lobby_id, changed_id, making_change_id, chat_state)
signal network_messages_session_request(remote_id)
signal network_messages_session_failed(reason, remote_id, connection_state, debug)

const Link := preload("res://mods-unpacked/einfluffles-TogetherLocal/link.gd")

const VERSION := "local-play emulator 2"

# Ids: a real Steam user id has universe 1 (Public) in its top byte (7656119...); these have
# universe 0 (Invalid), so no fake id can ever be a real one. Lobby ids: universe 0, type 8 (chat),
# the owner's number and a counter in the low bits (lobby_owner).
const FAKE_ID_BASE := 0x0010000100000000
const FAKE_LOBBY_BASE := 0x0080000000000000
const MAX_NUMBER := 0xFFFFFFFF
const FAKE_POP := Link.FAKE_POP  # "lcl" as LinkWatch.pop_code reads it

# EResult
const RESULT_OK := 1
const RESULT_NO_CONNECTION := 3
const RESULT_INVALID_PARAM := 8
const RESULT_LIMIT_EXCEEDED := 25
# EChatRoomEnterResponse
const ENTER_SUCCESS := 1
const ENTER_DOESNT_EXIST := 2
const ENTER_NOT_ALLOWED := 3
const ENTER_FULL := 4
const ENTER_ERROR := 5
# EChatMemberStateChange
const CHAT_ENTERED := 1
const CHAT_LEFT := 2
const CHAT_DISCONNECTED := 4
# k_nSteamNetworkingSend_*
const SEND_RELIABLE := 8
const SEND_AUTO_RESTART_BROKEN_SESSION := 32
# ESteamNetworkingConnectionState
const STATE_NONE := 0
const STATE_CONNECTING := 1
const STATE_CONNECTED := 3
const STATE_CLOSED_BY_PEER := 4
const STATE_PROBLEM_DETECTED_LOCALLY := 5
# ESteamNetConnectionEnd
const END_APP_GENERIC := 1000
const END_REMOTE_TIMEOUT := 4001
const END_MISC_TIMEOUT := 5003
const FLAG_RELAYED := 16  # k_nSteamNetConnectionInfoFlags_Relayed

const MAX_MESSAGE_BYTES := 524288  # k_cbMaxSteamNetworkingSocketsMessageSizeSend
const SEND_BUFFER_BYTES := 524288  # k_ESteamNetworkingConfig_SendBufferSize's default
const STEAM_SEND_RATE := 262144  # SendRateMin / SendRateMax default
const BURST_BYTES := 4380  # what the token bucket holds at most
# ESteamNetworkingConfigValue by GodotSteam's names, the SDK's numbers when the class lacks them
# (the same lookup as Transport._steam_constant).
const CONFIG_SEND_RATE_MIN := ["NETWORKING_CONFIG_SEND_RATE_MIN", 10]
const CONFIG_SEND_RATE_MAX := ["NETWORKING_CONFIG_SEND_RATE_MAX", 11]
const CONFIG_ICE_ENABLE := ["NETWORKING_CONFIG_P2P_TRANSPORT_ICE_ENABLE", 104]
const CONFIG_ICE_DISABLE := ["NETWORKING_CONFIG_P2P_TRANSPORT_ICE_DISABLE", 0]
# getLocalTimestamp: Steam's clock starts elsewhere than the engine's (per emulator, see _init).
const CLOCK_ORIGIN_USEC := 5000000000
const ACCEPT_TIMEOUT_MSEC := 10000  # a session nobody accepts fails at the sender after this
const MEASURE_USEC := 1000000  # quality and bytes / packets per second: over the last second
const QUALITY_MIN_SENT := 20  # transmissions in a period that make a new quality

var steam_id := 0  # getSteamID; 0: not logged on (number 0 in _init)
var persona_name := ""
var clock = null  # now_usec(): RealClock, or the wire's clock (wire_memory.gd)
var clock_origin_usec := 0
var send_buffer_bytes := SEND_BUFFER_BYTES
var accept_timeout_msec := ACCEPT_TIMEOUT_MSEC
var link = null  # link.gd: what this side sends goes through it (set_link, set_profile)
# Recorded for tests and the director (PR 5): what the game asked Steam for.
var relay_inits := 0
var config_values := {}  # ESteamNetworkingConfigValue -> value set
var rich_presence := {}
var presence_log := []  # [key, value] per setRichPresence / clearRichPresence ("*", "")
var invite_dialogs := []  # lobby ids activateGameOverlayInviteDialog opened for
# Counters: messages paced out, dropped by the link, delivered to the wire, delivered here,
# reliable sends refused on command (fail_next_sends)
var sent_count := 0
var dropped_count := 0
var wire_count := 0
var received_count := 0
var refused_count := 0

var _wire = null
var _lobbies := {}  # lobby id -> {owner, members, data, joinable, max, type, names}
var _sessions := {}  # remote steam id -> session (_new_session)
var _inbox := {}  # channel -> messages as receiveMessagesOnChannel returns them
var _callbacks := []  # [signal name, args], emitted in poll()
var _names := {}  # steam id -> persona name
var _lobby_counter := 0
var _message_number := 0
var _ice_enabled := true
var _rate_min := STEAM_SEND_RATE
var _rate_max := STEAM_SEND_RATE
var _config_rate_min := 0
var _config_rate_max := 0
var _config_ice := 0
var _ice_disable := 0
var _last_poll_usec := -1
var _outbox := []  # lobby traffic and session control on their way: {due, packet}, by due
var _fail_sends := 0  # how many reliable sends to refuse yet (fail_next_sends)
var _fail_result := RESULT_LIMIT_EXCEEDED


class RealClock:
	extends Reference

	func now_usec() -> int:
		return OS.get_ticks_usec()


# number: 1 .. MAX_NUMBER gives the steam id make_id(number); 0 one that is not logged on.
func _init(number := 1, persona := "") -> void:
	steam_id = make_id(number)
	persona_name = persona if persona != "" else "Player %d" % number
	_names[steam_id] = persona_name
	clock = RealClock.new()
	clock_origin_usec = CLOCK_ORIGIN_USEC + number * 1000000000
	link = Link.new(number)
	_config_rate_min = _steam_constant(CONFIG_SEND_RATE_MIN)
	_config_rate_max = _steam_constant(CONFIG_SEND_RATE_MAX)
	_config_ice = _steam_constant(CONFIG_ICE_ENABLE)
	_ice_disable = _steam_constant(CONFIG_ICE_DISABLE)


static func make_id(number: int) -> int:
	return FAKE_ID_BASE + number if number > 0 and number <= MAX_NUMBER else 0


static func is_fake_id(id: int) -> bool:
	return id > FAKE_ID_BASE and id <= FAKE_ID_BASE + MAX_NUMBER


static func lobby_owner(lobby_id: int) -> int:
	if lobby_id <= FAKE_LOBBY_BASE:
		return 0
	return make_id((lobby_id - FAKE_LOBBY_BASE) >> 8)


static func _steam_constant(entry: Array) -> int:
	if ClassDB.class_has_integer_constant("Steam", entry[0]):
		return ClassDB.class_get_integer_constant("Steam", entry[0])
	return entry[1]


# --- Control (not GodotSteam) ---


# The wire this emulator sends through; null: offline (sends fail with NoConnection).
func attach_wire(wire) -> void:
	_wire = wire


func has_wire() -> bool:
	return _wire != null


# The lobbies this emulator owns (a wire tells the others, so a client joins once one exists).
func owned_lobby_ids() -> Array:
	var ids := []
	for lobby_id in _lobbies:
		if _lobbies[lobby_id].owner == steam_id:
			ids.append(lobby_id)
	ids.sort()
	return ids


# Steam's run_callbacks and the network in one: paces queued messages out, hands due ones to the
# wire, expires session requests nobody accepted, then emits the callbacks queued since.
func poll() -> void:
	var now := now_usec()
	var elapsed := 0 if _last_poll_usec < 0 else now - _last_poll_usec
	_last_poll_usec = now
	link.tick(now)
	var stalled: bool = link.stalled(now)
	_release_outbox(now)
	for remote_id in _sessions.keys():
		var session = _sessions.get(remote_id)
		if session != null:
			_pace(remote_id, session, now, elapsed, stalled)
		session = _sessions.get(remote_id)
		if session != null and not stalled:
			_release(remote_id, session, now)
		session = _sessions.get(remote_id)
		if session != null:
			_expire_held(remote_id, session, now)
		session = _sessions.get(remote_id)
		if session != null:
			_measure(session, now)
	var due := _callbacks
	_callbacks = []
	for callback in due:
		callv("emit_signal", [callback[0]] + callback[1])


func now_usec() -> int:
	return clock.now_usec()


# The link of what this side sends, by link.gd's DEFAULT keys; false (and nothing changed) for an
# unknown key or a bad value.
func set_link(settings: Dictionary) -> bool:
	return link.set_values(settings)


# A named profile (link_profiles.gd: lan, relay-good, relay-typical, bad, stall) for what this side
# sends from now on; what is on its way keeps its time. False for an unknown name.
func set_profile(name: String) -> bool:
	return link.set_profile(name)


func seed_link(value: int) -> void:
	link.reseed(value)


# Nothing this side sends moves for msec (a stall of the line or of Steam); the queues keep it.
func stall(msec: int) -> void:
	link.stall(now_usec(), msec)


# The next count reliable sends answer result instead of OK (LimitExceeded by default, as when
# Steam's send buffer is full): what makes the mod's Session run a full resync. Unreliable sends
# are not touched (a failed one changes nothing there).
func fail_next_sends(count := 1, result := RESULT_LIMIT_EXCEEDED) -> void:
	_fail_sends = int(max(0, count))
	_fail_result = result


# Every live session fails here and, by default, at the peer (fail_session); how many did.
func fail_sessions(reason := END_MISC_TIMEOUT, debug := "", both_sides := true) -> int:
	var count := 0
	for remote_id in _sessions.keys():
		var session = _sessions.get(remote_id)
		if session != null and session.state < STATE_CLOSED_BY_PEER:
			fail_session(remote_id, reason, debug, both_sides)
			count += 1
	return count


# The session with remote_id fails here (and, by default, at the remote too): what Steam reports
# when it loses a connection. The next send with AUTO_RESTART opens a new one.
func fail_session(
	remote_id: int, reason := END_MISC_TIMEOUT, debug := "", both_sides := true
) -> void:
	if not _sessions.has(remote_id):
		_sessions[remote_id] = _new_session(false)
	var text := debug if debug != "" else "injected by the local-play emulator"
	_fail(remote_id, reason, text)
	if both_sides:
		_send_control(remote_id, {"k": "fail", "reason": reason, "debug": text})


# A friend's invite accepted in the Steam overlay (or "Join game").
func fire_join_requested(lobby_id: int, friend_id: int) -> void:
	_queue("join_requested", [lobby_id, friend_id])


func send_rate() -> int:
	return _rate_min if _rate_min <= _rate_max else _rate_max


func is_relayed(remote_id: int) -> bool:
	var session = _sessions.get(remote_id)
	return not (_ice_enabled and (session == null or session.remote_ice))


# The wire lost remote_id (its game quit or crashed): its sessions fail, it leaves the lobbies.
func wire_lost(remote_id: int) -> void:
	var session = _sessions.get(remote_id)
	if session != null and session.state < STATE_CLOSED_BY_PEER:
		_fail(remote_id, END_REMOTE_TIMEOUT, "the peer's game is gone")
	# Members hear of another member from the owner; of the owner itself only from the wire.
	for lobby_id in _lobbies.keys():
		var lobby: Dictionary = _lobbies[lobby_id]
		var owned: bool = lobby.owner == steam_id
		if not lobby.members.has(remote_id) or not (owned or lobby.owner == remote_id):
			continue
		lobby.members.erase(remote_id)
		if owned:
			_broadcast_lobby(lobby_id, [remote_id, remote_id, CHAT_DISCONNECTED])
		elif not lobby.members.empty():
			lobby.owner = lobby.members[0]  # every member picks the same new owner
		_queue("lobby_chat_update", [lobby_id, remote_id, remote_id, CHAT_DISCONNECTED])


# --- GodotSteam: user ---


func getSteamID() -> int:
	return steam_id


func get_godotsteam_version() -> String:
	return VERSION


func initRelayNetworkAccess() -> void:
	relay_inits += 1


func getPersonaName() -> String:
	return persona_name


func getFriendPersonaName(id: int) -> String:
	return _names.get(id, "[unknown]")


func setRichPresence(key: String, value: String) -> bool:
	if value == "":
		rich_presence.erase(key)
	else:
		rich_presence[key] = value
	presence_log.append([key, value])
	return true


func clearRichPresence() -> void:
	rich_presence.clear()
	presence_log.append(["*", ""])


func activateGameOverlayInviteDialog(lobby_id: int) -> void:
	invite_dialogs.append(lobby_id)


func setGlobalConfigValueInt32(config: int, value: int) -> bool:
	config_values[config] = value
	if config == _config_rate_min or config == _config_rate_max:
		if value <= 0:
			return false
		if config == _config_rate_min:
			_rate_min = value
		else:
			_rate_max = value
	elif config == _config_ice:
		_ice_enabled = value != _ice_disable
	return true


# --- GodotSteam: lobbies ---


func createLobby(lobby_type: int, max_members: int) -> void:
	_lobby_counter += 1
	var number := steam_id - FAKE_ID_BASE
	var lobby_id := FAKE_LOBBY_BASE + (number << 8) + (_lobby_counter & 0xFF)
	_lobbies[lobby_id] = {
		"owner": steam_id,
		"members": [steam_id],
		"data": {},
		"joinable": true,
		"max": max_members,
		"type": lobby_type,
		"names": {steam_id: persona_name},
	}
	_queue("lobby_created", [RESULT_OK, lobby_id])
	_queue("lobby_joined", [lobby_id, 0, false, ENTER_SUCCESS])  # Steam enters its own lobby too


func joinLobby(lobby_id: int) -> void:
	if _lobbies.has(lobby_id):
		_queue("lobby_joined", [lobby_id, 0, false, ENTER_SUCCESS])
		return
	if _wire == null:
		_queue("lobby_joined", [lobby_id, 0, false, ENTER_ERROR])
		return
	var owner := lobby_owner(lobby_id)
	var asked := {"k": "join", "lobby": lobby_id, "name": persona_name}
	if owner == 0 or owner == steam_id or not _send_control(owner, asked):
		_queue("lobby_joined", [lobby_id, 0, false, ENTER_DOESNT_EXIST])


# The owner leaving hands the lobby to the next member (as Steam does); its id still names the
# first owner, so a join after that finds no lobby.
func leaveLobby(lobby_id: int) -> void:
	var lobby = _lobbies.get(lobby_id)
	if lobby == null:
		return
	_lobbies.erase(lobby_id)
	if lobby.owner != steam_id:
		_send_control(lobby.owner, {"k": "leave", "lobby": lobby_id})
		return
	lobby.members.erase(steam_id)
	if lobby.members.empty():
		return
	lobby.owner = lobby.members[0]
	var change := [steam_id, steam_id, CHAT_LEFT]
	for member in lobby.members:
		_send_control(member, {"k": "lobby", "lobby": lobby_id, "state": lobby, "change": change})


func getLobbyOwner(lobby_id: int) -> int:
	var lobby = _lobbies.get(lobby_id)
	return lobby.owner if lobby != null else 0


func getNumLobbyMembers(lobby_id: int) -> int:
	var lobby = _lobbies.get(lobby_id)
	return lobby.members.size() if lobby != null else 0


func getLobbyMemberByIndex(lobby_id: int, index: int) -> int:
	var lobby = _lobbies.get(lobby_id)
	if lobby == null or index < 0 or index >= lobby.members.size():
		return 0
	return lobby.members[index]


func getLobbyData(lobby_id: int, key: String) -> String:
	var lobby = _lobbies.get(lobby_id)
	return str(lobby.data.get(key, "")) if lobby != null else ""


func setLobbyData(lobby_id: int, key: String, value: String) -> bool:
	var lobby = _owned_lobby(lobby_id)
	if lobby == null:
		return false
	lobby.data[key] = value
	_broadcast_lobby(lobby_id, [])
	return true


func setLobbyJoinable(lobby_id: int, joinable: bool) -> bool:
	var lobby = _owned_lobby(lobby_id)
	if lobby == null:
		return false
	lobby.joinable = joinable
	_broadcast_lobby(lobby_id, [])
	return true


# --- GodotSteam: Networking Messages ---


func getLocalTimestamp() -> int:
	return now_usec() + clock_origin_usec


func sendMessageToUser(remote_id: int, data: PoolByteArray, flags: int, channel: int) -> int:
	if remote_id == 0 or remote_id == steam_id or channel < 0 or data.size() > MAX_MESSAGE_BYTES:
		return RESULT_INVALID_PARAM
	if _wire == null:
		return RESULT_NO_CONNECTION
	var session = _sessions.get(remote_id)
	if session != null and session.state >= STATE_CLOSED_BY_PEER:
		if not flags & SEND_AUTO_RESTART_BROKEN_SESSION:
			return RESULT_NO_CONNECTION
		session = null
	if session == null:
		session = _new_session(true)
		_sessions[remote_id] = session
	elif not session.accepted:
		_accept(remote_id, session)  # sending to a peer accepts its session request
	if session.pending_reliable + session.pending_unreliable + data.size() > send_buffer_bytes:
		return RESULT_LIMIT_EXCEEDED
	var reliable: bool = flags & SEND_RELIABLE != 0
	if reliable and _fail_sends > 0:
		_fail_sends -= 1
		refused_count += 1
		return _fail_result
	session.queue.append(
		{
			"payload": data,
			"channel": channel,
			"flags": flags,
			"reliable": reliable,
			"size": data.size(),
		}
	)
	if reliable:
		session.pending_reliable += data.size()
	else:
		session.pending_unreliable += data.size()
	return RESULT_OK


func receiveMessagesOnChannel(channel: int, max_messages: int) -> Array:
	var box: Array = _inbox.get(channel, [])
	var messages := []
	while not box.empty() and messages.size() < max_messages:
		messages.append(box.pop_front())
	return messages


# Steam answers false without a session request to accept.
func acceptSessionWithUser(remote_id: int) -> bool:
	var session = _sessions.get(remote_id)
	if session == null or session.state >= STATE_CLOSED_BY_PEER:
		return false
	if not session.accepted:
		_accept(remote_id, session)
	return true


func closeSessionWithUser(remote_id: int) -> bool:
	var session = _sessions.get(remote_id)
	if session == null:
		return false
	_sessions.erase(remote_id)
	if session.state < STATE_CLOSED_BY_PEER:
		_send_control(remote_id, {"k": "close"})
	return true


# SteamNetConnectionInfo_t (get_connection) and SteamNetConnectionRealTimeStatus_t (get_status)
# of the session with remote_id, from this emulator's own queues and link.
func getSessionConnectionInfo(remote_id: int, get_connection: bool, get_status: bool) -> Dictionary:
	var info := {"identity": remote_id, "connection_state": STATE_NONE}
	var session = _sessions.get(remote_id)
	if session == null:
		return info
	var relayed := is_relayed(remote_id)
	info.connection_state = session.state
	if get_connection:
		info.end_reason = session.end_reason
		info.end_debug = session.end_debug
		info.info_flags = FLAG_RELAYED if relayed else 0
		info.pop_relay = link.pop() if relayed else 0
		info.remote_pop = FAKE_POP if relayed else 0
		info.remote_address = "" if relayed else "127.0.0.1"
		info.debug_description = "local-play session with %s (%s)" % [remote_id, link.profile]
	if get_status:
		var waiting: int = session.pending_reliable + session.pending_unreliable
		var debt: float = max(0.0, -session.tokens)
		var connected: bool = session.state == STATE_CONNECTED
		info.state = session.state
		info.ping = _ping_msec(session, relayed) if connected else -1
		# Steam: local, the share of the peer's packets that arrive here (its link, which its
		# packets report); remote, of this side's packets at the peer. -1 before a measurement.
		info.local_quality = session.quality_in if connected else -1.0
		info.remote_quality = session.quality_out if connected else -1.0
		info.send_rate = send_rate()
		info.pending_reliable = session.pending_reliable
		info.pending_unreliable = session.pending_unreliable
		info.sent_unacknowledged_reliable = session.unacked_reliable
		info.queue_time = int((debt + waiting) * 1000000.0 / link.pace_rate(send_rate()))
		# GodotSteam 3.x's names; the mod does not read them (status.json does)
		info.packets_out_per_second = session.rates[0]
		info.bytes_out_per_second = session.rates[1]
		info.packets_in_per_second = session.rates[2]
		info.bytes_in_per_second = session.rates[3]
	return info


# For status.json: the link and the numbers Steam would show per peer.
func link_status() -> Dictionary:
	var peers := {}
	for remote_id in _sessions:
		var info := getSessionConnectionInfo(remote_id, false, true)
		var entry := {}
		for key in ["state", "ping", "queue_time", "pending_reliable", "pending_unreliable"]:
			entry[key] = info.get(key)
		for key in ["local_quality", "remote_quality"]:
			entry[key] = stepify(float(info.get(key, -1.0)), 0.001)
		entry.bytes_out_per_second = info.get("bytes_out_per_second")
		entry.bytes_in_per_second = info.get("bytes_in_per_second")
		entry.relayed = is_relayed(remote_id)
		peers[str(remote_id)] = entry
	var summary: Dictionary = link.summary()
	summary.sent = sent_count
	summary.dropped = dropped_count
	summary.refused = refused_count
	summary.peers = peers
	return summary


# --- Wire side ---


# A packet from the wire: lobby traffic, a message or session control.
func receive_packet(packet: Dictionary) -> void:
	var from := int(packet.get("from", 0))
	if from == 0:
		return
	var session = _sessions.get(from)
	var live: bool = session != null and session.state < STATE_CLOSED_BY_PEER
	match str(packet.get("k", "")):
		"msg":
			_receive_message(from, packet)
		"accepted":
			if live:
				session.state = STATE_CONNECTED
				session.remote_ice = bool(packet.get("ice", true))
				session.remote_one_way = float(packet.get("lat", -1.0))
		"close":
			if live:
				_end(session, STATE_CLOSED_BY_PEER, END_APP_GENERIC, "closed by peer")
		"fail":
			if session != null:
				_fail(from, int(packet.get("reason", 0)), str(packet.get("debug", "")))
		"refused":
			if session != null:
				_fail(from, END_MISC_TIMEOUT, "the peer did not accept the session")
		"join":
			_owner_join(from, int(packet.get("lobby", 0)), str(packet.get("name", "")))
		"leave":
			_owner_leave(from, int(packet.get("lobby", 0)))
		"lobby":
			_member_update(packet)
		"join_fail":
			var lobby_id := int(packet.get("lobby", 0))
			_queue("lobby_joined", [lobby_id, 0, false, int(packet.get("response", ENTER_ERROR))])


func _receive_message(from: int, packet: Dictionary) -> void:
	var session = _sessions.get(from)
	if session == null or session.state >= STATE_CLOSED_BY_PEER:
		session = _new_session(false)
		_sessions[from] = session
	session.remote_ice = bool(packet.get("ice", true))
	session.remote_one_way = float(packet.get("lat", -1.0))
	session.quality_in = float(packet.get("q", session.quality_in))
	var size: int = packet.get("payload", PoolByteArray()).size()
	session.counts[2] += 1
	session.counts[3] += size
	if session.accepted:
		_deliver(from, session, packet)
		return
	packet["held_usec"] = now_usec()
	session.held.append(packet)
	if not session.requested:
		session.requested = true
		_queue("network_messages_session_request", [from])


func _deliver(from: int, session: Dictionary, packet: Dictionary) -> void:
	var channel := int(packet.get("channel", 0))
	var payload: PoolByteArray = packet.get("payload", PoolByteArray())
	if not _inbox.has(channel):
		_inbox[channel] = []
	_inbox[channel].append(
		{
			"payload": payload,
			"size": payload.size(),
			"identity": from,
			"channel": channel,
			"flags": int(packet.get("flags", 0)),
			"message_number": int(packet.get("n", 0)),
			"time_received": getLocalTimestamp(),
		}
	)
	received_count += 1
	_confirm(from, session)


# Both sides accepted: connected, and the other side learns it.
func _confirm(remote_id: int, session: Dictionary) -> void:
	session.state = STATE_CONNECTED
	if not session.acked:
		session.acked = true
		var one_way: float = link.base_msec(is_relayed(remote_id))
		_send_control(remote_id, {"k": "accepted", "ice": _ice_enabled, "lat": one_way})


func _accept(remote_id: int, session: Dictionary) -> void:
	session.accepted = true
	var held: Array = session.held
	session.held = []
	for packet in held:
		_deliver(remote_id, session, packet)
	if session.requested:
		_confirm(remote_id, session)


# opened: this side sends first (and so accepts the session).
func _new_session(opened: bool) -> Dictionary:
	return {
		"state": STATE_CONNECTING,
		"accepted": opened,
		"requested": false,
		"acked": false,
		"remote_ice": true,
		"end_reason": 0,
		"end_debug": "",
		"queue": [],  # not paced out yet
		"in_flight": [],  # {due, packet, reliable, size}, ordered by due
		"held": [],  # received before this side accepted
		"tokens": float(BURST_BYTES),
		"last_reliable_due": 0,
		"pending_reliable": 0,
		"pending_unreliable": 0,
		"unacked_reliable": 0,
		"remote_one_way": -1.0,  # the peer's link without jitter (msec), as its packets say
		# Measured per MEASURE_USEC: quality out (transmissions that arrived) and as the peer
		# measured it for its packets (in); counts: packets out, bytes out, packets in, bytes in,
		# transmissions, lost transmissions; rates: the last period's counts per second
		"quality_in": -1.0,
		"quality_out": -1.0,
		"counts": [0, 0, 0, 0, 0, 0],
		"rates": [0.0, 0.0, 0.0, 0.0],
		"sent_weight": 0.0,
		"lost_weight": 0.0,
		"measured_usec": -1,
	}


func _end(session: Dictionary, state: int, reason: int, debug: String) -> void:
	session.state = state
	session.end_reason = reason
	session.end_debug = debug
	session.queue.clear()
	session.in_flight.clear()
	session.held.clear()
	session.pending_reliable = 0
	session.pending_unreliable = 0
	session.unacked_reliable = 0


func _fail(remote_id: int, reason: int, debug: String) -> void:
	var session = _sessions.get(remote_id)
	if session == null:
		return
	_end(session, STATE_PROBLEM_DETECTED_LOCALLY, reason, debug)
	var args := [reason, remote_id, STATE_PROBLEM_DETECTED_LOCALLY, debug]
	_queue("network_messages_session_failed", args)


# Token bucket: refills at the send rate up to BURST_BYTES; a message leaves when the bucket is not
# in debt and takes its size out, so the next one waits until the line has carried it.
func _pace(remote_id: int, session: Dictionary, now: int, elapsed: int, stalled: bool) -> void:
	var rate: int = link.pace_rate(send_rate())
	session.tokens = min(float(BURST_BYTES), session.tokens + rate * elapsed / 1000000.0)
	if stalled:
		return
	while not session.queue.empty() and session.tokens >= 0.0:
		var message: Dictionary = session.queue.pop_front()
		session.tokens -= message.size
		if message.reliable:
			session.pending_reliable -= message.size
		else:
			session.pending_unreliable -= message.size
		var on_line := int(max(0.0, -session.tokens) * 1000000.0 / rate)
		_launch(remote_id, session, message, now + on_line)


func _launch(remote_id: int, session: Dictionary, message: Dictionary, sent_usec: int) -> void:
	sent_count += 1
	_message_number += 1
	var relayed := is_relayed(remote_id)
	var due: int = sent_usec + link.latency_usec(relayed)
	session.counts[4] += 1
	if not message.reliable and link.lost():
		dropped_count += 1
		session.counts[5] += 1
		return
	if message.reliable:
		var retry: Array = link.retransmit_usec()  # a retransmit per loss
		due += retry[0]
		session.counts[4] += retry[1]
		session.counts[5] += retry[1]
		due = int(max(due, session.last_reliable_due))  # reliable keeps its order
		session.last_reliable_due = due
		session.unacked_reliable += message.size
	var packet := {
		"k": "msg",
		"from": steam_id,
		"to": remote_id,
		"channel": message.channel,
		"flags": message.flags,
		"payload": message.payload,
		"ice": _ice_enabled,
		"n": _message_number,
		"lat": link.base_msec(relayed),
		"q": session.quality_out,
	}
	var item := {"due": due, "packet": packet, "reliable": message.reliable, "size": message.size}
	var at: int = session.in_flight.size()
	while at > 0 and session.in_flight[at - 1].due > due:
		at -= 1  # an unreliable message may overtake
	session.in_flight.insert(at, item)


func _release(remote_id: int, session: Dictionary, now: int) -> void:
	while not session.in_flight.empty() and session.in_flight[0].due <= now:
		var item: Dictionary = session.in_flight.pop_front()
		if item.reliable:
			session.unacked_reliable -= item.size
		if _wire == null or not _wire.send_packet(item.packet):
			_fail(remote_id, END_REMOTE_TIMEOUT, "the peer cannot be reached")
			return
		wire_count += 1
		session.counts[0] += 1
		session.counts[1] += item.size


func _expire_held(remote_id: int, session: Dictionary, now: int) -> void:
	if session.accepted or session.held.empty():
		return
	if now - int(session.held[0].held_usec) < accept_timeout_msec * 1000:
		return
	_sessions.erase(remote_id)  # the next message is a new request
	_send_control(remote_id, {"k": "refused"})


# Steam's ping: this side's way plus the peer's (as its packets say; twice this side's before).
func _ping_msec(session: Dictionary, relayed: bool) -> int:
	var one_way: float = link.base_msec(relayed)
	var back: float = session.remote_one_way if session.remote_one_way >= 0.0 else one_way
	return int(round(one_way + back))


# Once a period: the quality of this side's transmissions and the rates, from the counts.
func _measure(session: Dictionary, now: int) -> void:
	if session.measured_usec < 0:
		session.measured_usec = now
		return
	var period: int = now - session.measured_usec
	if period < MEASURE_USEC:
		return
	var counts: Array = session.counts
	# Transmissions and losses, each period's weight halved in the next: a quiet period keeps the
	# last quality (one lost of two is no measure).
	session.sent_weight = session.sent_weight * 0.5 + counts[4]
	session.lost_weight = session.lost_weight * 0.5 + counts[5]
	if session.sent_weight >= QUALITY_MIN_SENT or (counts[4] > 0 and session.quality_out < 0.0):
		session.quality_out = 1.0 - session.lost_weight / session.sent_weight
	elif session.state == STATE_CONNECTED and session.quality_out < 0.0:
		session.quality_out = 1.0
	var seconds := period / 1000000.0
	var rates := []
	for i in 4:
		rates.append(counts[i] / seconds)
	session.rates = rates
	session.counts = [0, 0, 0, 0, 0, 0]
	session.measured_usec = now


# --- Lobby owner and member side ---


func _owned_lobby(lobby_id: int):
	var lobby = _lobbies.get(lobby_id)
	return lobby if lobby != null and lobby.owner == steam_id else null


func _owner_join(from: int, lobby_id: int, name: String) -> void:
	var lobby = _owned_lobby(lobby_id)
	var response := ENTER_SUCCESS
	if lobby == null:
		response = ENTER_DOESNT_EXIST
	elif not lobby.joinable:
		response = ENTER_NOT_ALLOWED
	elif not lobby.members.has(from) and lobby.members.size() >= lobby.max:
		response = ENTER_FULL
	if response != ENTER_SUCCESS:
		_send_control(from, {"k": "join_fail", "lobby": lobby_id, "response": response})
		return
	_names[from] = name
	lobby.names[from] = name
	var entered: bool = not lobby.members.has(from)
	if entered:
		lobby.members.append(from)
	_send_control(from, {"k": "lobby", "lobby": lobby_id, "state": lobby, "entered": true})
	if entered:
		var change := [from, from, CHAT_ENTERED]
		_broadcast_lobby(lobby_id, change, from)
		_queue("lobby_chat_update", [lobby_id] + change)


func _owner_leave(from: int, lobby_id: int) -> void:
	var lobby = _owned_lobby(lobby_id)
	if lobby == null or not lobby.members.has(from):
		return
	lobby.members.erase(from)
	var change := [from, from, CHAT_LEFT]
	_broadcast_lobby(lobby_id, change)
	_queue("lobby_chat_update", [lobby_id] + change)


# The owner's lobby to every other member (but skip), with the member change that caused it.
func _broadcast_lobby(lobby_id: int, change: Array, skip := 0) -> void:
	var lobby = _owned_lobby(lobby_id)
	if lobby == null:
		return
	for member in lobby.members:
		if member != steam_id and member != skip:
			var update := {"k": "lobby", "lobby": lobby_id, "state": lobby, "change": change}
			_send_control(member, update)


func _member_update(packet: Dictionary) -> void:
	var lobby_id := int(packet.get("lobby", 0))
	var entered := bool(packet.get("entered", false))
	if not _lobbies.has(lobby_id) and not entered:
		return  # left it meanwhile
	var state: Dictionary = packet.get("state", {})
	_lobbies[lobby_id] = state
	for id in state.get("names", {}):
		_names[id] = state.names[id]
	if entered:
		_queue("lobby_joined", [lobby_id, 0, false, ENTER_SUCCESS])
	var change: Array = packet.get("change", [])
	if change.size() == 3:
		_queue("lobby_chat_update", [lobby_id] + change)


# Lobby traffic and session control: at once without latency (false: the wire does not know the
# peer), else after it (true; a join the wire then cannot carry answers "no such lobby").
func _send_control(to: int, packet: Dictionary) -> bool:
	if _wire == null:
		return false
	packet["from"] = steam_id
	packet["to"] = to
	var delay := int(link.base_msec(is_relayed(to)) * 1000.0)
	if delay <= 0 and _outbox.empty():
		return _wire.send_packet(packet)
	var due := now_usec() + delay
	var at := _outbox.size()
	while at > 0 and _outbox[at - 1].due > due:
		at -= 1
	_outbox.insert(at, {"due": due, "packet": packet})
	return true


func _release_outbox(now: int) -> void:
	while not _outbox.empty() and _outbox[0].due <= now:
		var packet: Dictionary = _outbox.pop_front().packet
		if _wire != null and _wire.send_packet(packet):
			continue
		if packet.k == "join":
			_queue("lobby_joined", [int(packet.lobby), 0, false, ENTER_DOESNT_EXIST])


func _queue(signal_name: String, args: Array) -> void:
	_callbacks.append([signal_name, args])
