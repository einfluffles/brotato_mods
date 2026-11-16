extends Node
# Steam lobby + Steam Networking Messages transport (star topology: lobby owner = host).
#
# Uses the GodotSteam singleton compiled into Brotato (fetched dynamically, like the game does in
# singletons/platforms/steam.gd). Payloads are opaque PoolByteArrays; see protocol.gd for
# the encoding.

signal lobby_ready(lobby_id, is_host)
signal lobby_failed(reason)
signal lobby_left  # was_host tells the handlers which role was left
signal peer_joined(steam_id)
signal peer_left(steam_id)
# received_usec: when Steam got the message, on its local clock (0: unknown), see held_msec
signal message_received(steam_id, channel, data, received_usec)
signal send_failed(steam_id, channel, result)
signal join_invite(lobby_id)  # Steam invite accepted while in a lobby: see accept_pending_join

const CHANNEL_RELIABLE := 0
const CHANNEL_UNRELIABLE := 1
const CHANNELS := [CHANNEL_RELIABLE, CHANNEL_UNRELIABLE]

# k_nSteamNetworkingSend_* flags
const SEND_UNRELIABLE := 0
const SEND_NO_NAGLE := 1
const SEND_RELIABLE := 8
const SEND_AUTO_RESTART_BROKEN_SESSION := 32

const LOBBY_TYPE_FRIENDS_ONLY := 1
const RESULT_OK := 1
const LOBBY_ENTER_SUCCESS := 1
const CHAT_MEMBER_ENTERED := 1
const MAX_LOBBY_MEMBERS := 4
const MAX_MESSAGES_PER_POLL := 128
const MAX_HELD_MSEC := 60000  # a longer wait is a clock that does not fit: unknown
const KICK_CLOSE_MSEC := 3000  # a kicked member's session stays open this long for the KICK
const LOBBY_KEY_MOD := "brotato_together"
# Launch option: sessions only through Steam's relays, never directly between the two machines.
const RELAY_ARG := "+bt_relay"
# ESteamNetworkingConfigValue P2P_Transport_ICE_Enable and its "disable" value, by GodotSteam's
# names, with the Steamworks SDK's numbers when the class does not list them.
const CONFIG_ICE_ENABLE := ["NETWORKING_CONFIG_P2P_TRANSPORT_ICE_ENABLE", 104]
const CONFIG_ICE_DISABLE := ["NETWORKING_CONFIG_P2P_TRANSPORT_ICE_DISABLE", 0]

const LinkWatch := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/link_watch.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:Transport"

var steam: Object = null
var link_watch = LinkWatch.new()  # each member's session path (direct / relayed), for the log
var local_id := 0
var lobby_id := 0
var host_id := 0
var members := []  # steam ids in the lobby, excluding local
var was_host := false  # role of the lobby left last (valid from lobby_left on)
var pending_join_id := 0  # invite waiting for confirmation (joining leaves the current lobby)
# host: steam id -> msec of the kick (-1: session closed). No member for us until it has left
# Steam's lobby; after that it can join again.
var kicked := {}

var relay_only := false  # RELAY_ARG took effect (see apply_route)
var join_presence := ""  # the "connect" rich presence we advertise ("" = no Join button)
var _lobby_tag := ""
var _next_send_warning_msec := 0


func setup(lobby_tag: String) -> bool:
	_lobby_tag = lobby_tag
	if not Engine.has_singleton("Steam"):
		ModLoaderLog.error("Steam singleton not available", LOG_NAME)
		return false
	steam = Engine.get_singleton("Steam")
	local_id = int(steam.getSteamID())
	if local_id == 0:
		ModLoaderLog.error("Steam not logged on (steam id 0)", LOG_NAME)
		return false
	ModLoaderLog.info(
		"GodotSteam %s, local id %s" % [str(steam.call("get_godotsteam_version")), local_id],
		LOG_NAME
	)
	_connect_steam("lobby_created", "_on_lobby_created")
	_connect_steam("lobby_joined", "_on_lobby_joined")
	_connect_steam("join_requested", "_on_join_requested")
	_connect_steam("lobby_chat_update", "_on_lobby_chat_update")
	_connect_steam("network_messages_session_request", "_on_session_request")
	_connect_steam("network_messages_session_failed", "_on_session_failed")
	steam.initRelayNetworkAccess()
	apply_route(Array(OS.get_cmdline_args()))
	_clear_join_presence()  # never inherit a Join button from an earlier (crashed) session
	_check_launch_args()
	return true


# Steam keeps two routes to a peer, a direct one (ICE, through both players' NATs) and one
# through its relays (SDR), uses the better one and keeps probing the other to see whether to
# switch. With RELAY_ARG among the launch options the direct route is off: one route, nothing
# to switch between. For telling a route problem from anything else (a stall that comes back on
# a fixed beat while both lines are fine); the relay costs the detour to Steam's nearest data
# center. Applies to sessions opened afterwards, so it is set before any lobby. One side is
# enough to keep the direct route from forming.
func apply_route(args: Array) -> bool:
	relay_only = false
	if not RELAY_ARG in args:
		return false
	if steam == null or not steam.has_method("setGlobalConfigValueInt32"):
		ModLoaderLog.warning("%s: this GodotSteam cannot set the route" % RELAY_ARG, LOG_NAME)
		return false
	var set = steam.setGlobalConfigValueInt32(
		_steam_constant(CONFIG_ICE_ENABLE), _steam_constant(CONFIG_ICE_DISABLE)
	)
	relay_only = set == true
	if relay_only:
		ModLoaderLog.info("%s: sessions go through Steam's relays only" % RELAY_ARG, LOG_NAME)
	else:
		ModLoaderLog.warning("%s: Steam refused the setting (%s)" % [RELAY_ARG, set], LOG_NAME)
	return relay_only


static func _steam_constant(entry: Array) -> int:
	if ClassDB.class_has_integer_constant("Steam", entry[0]):
		return ClassDB.class_get_integer_constant("Steam", entry[0])
	return entry[1]


func is_active() -> bool:
	return lobby_id != 0


func is_host() -> bool:
	return lobby_id != 0 and host_id == local_id


func get_persona_name(steam_id: int) -> String:
	if steam == null:
		return str(steam_id)
	if steam_id == local_id:
		return steam.getPersonaName()
	return steam.getFriendPersonaName(steam_id)


func host_lobby() -> void:
	if is_active():
		leave_lobby()
	steam.createLobby(LOBBY_TYPE_FRIENDS_ONLY, MAX_LOBBY_MEMBERS)


func join_lobby(id: int) -> void:
	pending_join_id = 0
	if is_active():
		leave_lobby()
	steam.joinLobby(id)


func open_invite_dialog() -> void:
	if is_active():
		steam.activateGameOverlayInviteDialog(lobby_id)


func leave_lobby() -> void:
	if not is_active():
		return
	was_host = is_host()
	for peer in members:
		steam.closeSessionWithUser(peer)
	steam.leaveLobby(lobby_id)
	lobby_id = 0
	host_id = 0
	members.clear()
	kicked.clear()
	_clear_join_presence()
	emit_signal("lobby_left")


# Host: the member is out for us at once (its messages are dropped); Steam has no kick, so it
# stays in Steam's lobby until its game leaves on the KICK the session sent.
func kick(steam_id: int) -> void:
	if not is_host() or not members.has(steam_id):
		return
	kicked[steam_id] = OS.get_ticks_msec()
	members.erase(steam_id)
	_update_join_presence()
	ModLoaderLog.info("Kicked %s" % steam_id, LOG_NAME)
	emit_signal("peer_left", steam_id)


func send(steam_id: int, channel: int, data: PoolByteArray) -> void:
	if steam == null or steam_id == 0 or steam_id == local_id:
		return
	var flags := SEND_AUTO_RESTART_BROKEN_SESSION
	if channel == CHANNEL_RELIABLE:
		flags |= SEND_RELIABLE
	else:
		flags |= SEND_UNRELIABLE | SEND_NO_NAGLE
	# ISteamNetworkingMessages::SendMessageToUser's EResult (k_EResultOK = 1; e.g. NoConnection 3,
	# InvalidParam 8, LimitExceeded 25 when too much is queued). Session decides what to do.
	var result = steam.sendMessageToUser(steam_id, data, flags, channel)
	if typeof(result) != TYPE_INT or result != RESULT_OK:
		emit_signal("send_failed", steam_id, channel, result)
		# Reliable failures are logged by Session; unreliable ones (snapshots) here, rate-limited.
		if channel != CHANNEL_RELIABLE and OS.get_ticks_msec() >= _next_send_warning_msec:
			_next_send_warning_msec = OS.get_ticks_msec() + 1000
			ModLoaderLog.warning(
				"Unreliable send to %s failed: %s (%d B)" % [steam_id, result, data.size()], LOG_NAME
			)


func broadcast(channel: int, data: PoolByteArray) -> void:
	for peer in members:
		send(peer, channel, data)


func _process(_delta: float) -> void:
	if steam == null:
		return
	for channel in CHANNELS:
		var messages: Array = steam.receiveMessagesOnChannel(channel, MAX_MESSAGES_PER_POLL)
		for msg in messages:
			var sender := _message_sender(msg)
			# A joiner's first messages can arrive before lobby_chat_update: refresh on a miss.
			if sender == 0 or not _is_lobby_member(sender):
				continue
			var received := int(msg.get("time_received", 0))
			var payload: PoolByteArray = msg.get("payload", PoolByteArray())
			emit_signal("message_received", sender, channel, payload, received)
	if is_active() and local_id != 0:
		link_watch.poll(steam, members, OS.get_ticks_msec())
	for steam_id in kicked:
		if kicked[steam_id] >= 0 and OS.get_ticks_msec() - kicked[steam_id] >= KICK_CLOSE_MSEC:
			kicked[steam_id] = -1
			steam.closeSessionWithUser(steam_id)


# How long a message has waited for the frame that handles it, since Steam received it
# (message_received's received_usec); 0 when unknown. Messages are only read once a frame.
func held_msec(received_usec: int) -> int:
	if received_usec <= 0 or steam == null or not steam.has_method("getLocalTimestamp"):
		return 0
	var held := (int(steam.getLocalTimestamp()) - received_usec) / 1000
	return held if held >= 0 and held < MAX_HELD_MSEC else 0


# Steam's own numbers for the connection to a peer (ping, queue_time in usec, pending_reliable,
# pending_unreliable, send_rate, ...), {} when unavailable. For the log.
func connection_status(steam_id: int) -> Dictionary:
	if steam == null or local_id == 0 or not steam.has_method("getSessionConnectionInfo"):
		return {}  # local_id 0: Steam not running (headless tests)
	var status = steam.getSessionConnectionInfo(steam_id, false, true)
	return status if typeof(status) == TYPE_DICTIONARY else {}


func _message_sender(msg: Dictionary) -> int:
	for key in ["remote_steam_id", "identity", "steam_id"]:
		if msg.has(key):
			return int(msg[key])
	return 0


func _connect_steam(signal_name: String, method: String) -> void:
	if not steam.has_signal(signal_name):
		ModLoaderLog.error("GodotSteam has no signal '%s'" % signal_name, LOG_NAME)
		return
	if not steam.is_connected(signal_name, self, method):
		steam.connect(signal_name, self, method)


func _check_launch_args() -> void:
	# Steam launches the game with "+connect_lobby <id>" when joining a friend before the game runs.
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if args[i] == "+connect_lobby":
			call_deferred("join_lobby", int(args[i + 1]))


func _refresh_members() -> void:
	members.clear()
	var count: int = steam.getNumLobbyMembers(lobby_id)
	for i in range(count):
		var member := int(steam.getLobbyMemberByIndex(lobby_id, i))
		if member != local_id and not kicked.has(member):
			members.append(member)


func _on_lobby_created(result: int, new_lobby_id: int) -> void:
	if result != RESULT_OK:
		emit_signal("lobby_failed", "createLobby failed (result %s)" % result)
		return
	lobby_id = new_lobby_id
	host_id = local_id
	members.clear()
	kicked.clear()
	steam.setLobbyData(lobby_id, LOBBY_KEY_MOD, _lobby_tag)
	steam.setLobbyJoinable(lobby_id, true)
	_update_join_presence()
	ModLoaderLog.info("Hosting lobby %s" % lobby_id, LOG_NAME)
	emit_signal("lobby_ready", lobby_id, true)


func _on_lobby_joined(
	joined_lobby_id: int, _permissions: int, _locked: bool, response: int
) -> void:
	if response != LOBBY_ENTER_SUCCESS:
		emit_signal("lobby_failed", "joinLobby failed (response %s)" % response)
		return
	if host_id == local_id and lobby_id == joined_lobby_id:
		return  # host also receives lobby_joined for its own lobby
	var tag: String = steam.getLobbyData(joined_lobby_id, LOBBY_KEY_MOD)
	if tag != _lobby_tag:
		steam.leaveLobby(joined_lobby_id)
		var reason := "Lobby mod version mismatch: host '%s', local '%s'" % [tag, _lobby_tag]
		emit_signal("lobby_failed", reason)
		return
	lobby_id = joined_lobby_id
	host_id = int(steam.getLobbyOwner(lobby_id))
	_refresh_members()
	_update_join_presence()
	ModLoaderLog.info("Joined lobby %s (host %s)" % [lobby_id, host_id], LOG_NAME)
	emit_signal("lobby_ready", lobby_id, false)
	if members.has(host_id):
		emit_signal("peer_joined", host_id)


# Accepting a Steam invite while in a lobby would silently leave it (and a hosted run with it):
# ui/lobby_menu.gd asks first (or accepts right away outside a run).
func _on_join_requested(requested_lobby_id: int, _friend_id: int) -> void:
	if requested_lobby_id == lobby_id:
		return  # already there
	if not is_active():
		join_lobby(requested_lobby_id)
		return
	pending_join_id = requested_lobby_id
	emit_signal("join_invite", requested_lobby_id)


func accept_pending_join() -> void:
	if pending_join_id != 0:
		join_lobby(pending_join_id)


func _on_lobby_chat_update(
	update_lobby_id: int, changed_id: int, _making_change_id: int, chat_state: int
) -> void:
	if update_lobby_id != lobby_id or changed_id == local_id:
		return
	if kicked.has(changed_id):
		if not chat_state & CHAT_MEMBER_ENTERED:
			kicked.erase(changed_id)  # gone from Steam's lobby: a new join counts again
			_update_join_presence()
		return
	var was_member := members.has(changed_id)
	_refresh_members()
	_update_join_presence()
	if chat_state & CHAT_MEMBER_ENTERED:
		# Its session request may have come (and been rejected) before it was a member.
		steam.acceptSessionWithUser(changed_id)
		if not was_member:
			emit_signal("peer_joined", changed_id)
	elif was_member:
		steam.closeSessionWithUser(changed_id)
		emit_signal("peer_left", changed_id)
		if changed_id == host_id:
			ModLoaderLog.warning("Host left the lobby", LOG_NAME)
			emit_signal("lobby_failed", "The host left the lobby")
			leave_lobby()


# Steam shows friends a "Join game" button exactly while rich presence "connect" is set: only
# while we're in a lobby that still has a free slot.
func _update_join_presence() -> void:
	if not is_active() or members.size() + 1 >= MAX_LOBBY_MEMBERS:
		_clear_join_presence()
		return
	var value := "+connect_lobby %s" % lobby_id
	if value == join_presence:
		return
	steam.setRichPresence("connect", value)
	join_presence = value
	ModLoaderLog.info("Steam Join button on (lobby %s)" % lobby_id, LOG_NAME)


func _clear_join_presence() -> void:
	if steam == null:
		return
	# clearRichPresence drops every key; setting "" only removes "connect" (older GodotSteam).
	if steam.has_method("clearRichPresence"):
		steam.clearRichPresence()
	else:
		steam.setRichPresence("connect", "")
	if join_presence != "":
		ModLoaderLog.info("Steam Join button off", LOG_NAME)
	join_presence = ""


func _on_session_request(remote_id: int) -> void:
	# Only accept message sessions from members of our lobby.
	if is_active() and _is_lobby_member(remote_id):
		steam.acceptSessionWithUser(remote_id)
	else:
		ModLoaderLog.debug("Rejected session request from %s" % remote_id, LOG_NAME)


func _is_lobby_member(steam_id: int) -> bool:
	if members.has(steam_id):
		return true
	_refresh_members()
	return members.has(steam_id)


# Signature differs between GodotSteam versions (3.x: reason, steam id, state, debug message).
# What happened next (up again, over which path; or still not) follows from net/link_watch.gd.
func _on_session_failed(a = null, b = null, c = null, d = null) -> void:
	var text: String = link_watch.session_failed([a, b, c, d], OS.get_ticks_msec())
	ModLoaderLog.warning(text, LOG_NAME)
