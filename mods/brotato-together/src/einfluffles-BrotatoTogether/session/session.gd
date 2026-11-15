extends Node
# Session state on top of the transport: role, handshake, per-peer liveness/RTT.
# Handshake: the client sends HELLO (session/compat.gd local_info) every HELLO_INTERVAL_MSEC
# until WELCOME: the first one can be lost while Steam's member list / session acceptance on the
# host lags behind the join. The host answers every HELLO; a repeated HELLO from a ready peer
# means it missed WELCOME (and everything after it), so it gets a full resync.
# WELCOME carries the host's DLCs: the client borrows the ones it lacks while it is that host's
# client (session/dlc_borrow.gd); every way out (lobby_left, a new lobby) reverts them.

# Became ready, or needs a full resync (every sync module resends its whole state on this).
signal peer_ready(steam_id)
signal peer_removed(steam_id)
signal message(steam_id, msg_type, body)

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")
const DlcBorrow := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/dlc_borrow.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:Session"
const PING_INTERVAL_MSEC := 1000
const PEER_STALE_MSEC := 5000
const HOST_TIMEOUT_MSEC := 15000  # client gives up on a silent host (crash, network loss)
const HELLO_INTERVAL_MSEC := 1000
const RESYNC_INTERVAL_MSEC := 1000  # at most one full resync per peer and interval

var transport: Node = null
# steam_id -> {name, ready, rtt_ms, last_seen_msec, resync, last_resync_msec}
var peers := {}

var _next_ping_msec := 0
var _next_send_warning_msec := 0
var _next_hello_msec := -1  # client: next HELLO (re)send, -1 when not waiting for WELCOME


func setup(steam_transport: Node) -> void:
	transport = steam_transport
	transport.connect("lobby_ready", self, "_on_lobby_ready")
	transport.connect("lobby_left", self, "_on_lobby_left")
	transport.connect("peer_joined", self, "_on_peer_joined")
	transport.connect("peer_left", self, "_on_peer_left")
	transport.connect("message_received", self, "_on_message_received")
	transport.connect("send_failed", self, "_on_send_failed")


func is_host() -> bool:
	return transport.is_host()


func is_client() -> bool:
	return transport.is_active() and not transport.is_host()


# A client the host has welcomed (borrowed DLC may only exist in this state).
func is_ready_client() -> bool:
	var host_id: int = transport.host_id
	return is_client() and peers.has(host_id) and peers[host_id].ready


func send_reliable(steam_id: int, msg_type: int, body = null) -> void:
	transport.send(steam_id, transport.CHANNEL_RELIABLE, Protocol.encode(msg_type, body))


func send_unreliable(steam_id: int, msg_type: int, body = null) -> void:
	transport.send(steam_id, transport.CHANNEL_UNRELIABLE, Protocol.encode(msg_type, body))


func broadcast_reliable(msg_type: int, body = null) -> void:
	for steam_id in peers:
		if peers[steam_id].ready:
			send_reliable(steam_id, msg_type, body)


func broadcast_unreliable(msg_type: int, body = null) -> void:
	for steam_id in peers:
		if peers[steam_id].ready:
			send_unreliable(steam_id, msg_type, body)


func is_peer_stale(steam_id: int) -> bool:
	return OS.get_ticks_msec() - peers[steam_id].last_seen_msec > PEER_STALE_MSEC


func _process(_delta: float) -> void:
	if DlcBorrow.is_active() and not is_ready_client():
		DlcBorrow.revert()  # safety net: borrowed DLC never outlives client mode
	if not transport.is_active():
		return
	var now := OS.get_ticks_msec()
	if is_client() and _host_timed_out(now):
		ModLoaderLog.warning("No messages from the host for a while; leaving", LOG_NAME)
		transport.emit_signal("lobby_failed", "Connection to the host lost")
		transport.leave_lobby()
		return
	resend_hello(now)
	process_resyncs(now)
	if now >= _next_ping_msec:
		_next_ping_msec = now + PING_INTERVAL_MSEC
		for steam_id in peers:
			if peers[steam_id].ready:
				send_unreliable(steam_id, Protocol.Msg.PING, {"t": now})


func _host_timed_out(now: int) -> bool:
	var host_id: int = transport.host_id
	if not peers.has(host_id) or not peers[host_id].ready:
		return false
	return now - peers[host_id].last_seen_msec > HOST_TIMEOUT_MSEC


# Client: (re)send HELLO until the host's WELCOME arrives.
func resend_hello(now: int) -> void:
	if _next_hello_msec < 0 or now < _next_hello_msec or not is_client():
		return
	var host_id: int = transport.host_id
	if not peers.has(host_id) or peers[host_id].ready:
		_next_hello_msec = -1
		return
	_next_hello_msec = now + HELLO_INTERVAL_MSEC
	var persona: String = transport.get_persona_name(transport.local_id)
	send_reliable(host_id, Protocol.Msg.HELLO, Compat.local_info(persona))


# Host: peers whose reliable stream lost a message get everything again (peer_ready path).
func process_resyncs(now: int) -> void:
	if not is_host():
		return
	for steam_id in peers.keys():
		var peer: Dictionary = peers[steam_id]
		if not peer.resync or not peer.ready:
			continue
		if now - peer.last_resync_msec < RESYNC_INTERVAL_MSEC:
			continue
		peer.resync = false
		peer.last_resync_msec = now
		ModLoaderLog.info("Full resync for %s (%s)" % [peer.name, steam_id], LOG_NAME)
		emit_signal("peer_ready", steam_id)


func request_resync(steam_id: int) -> void:
	if peers.has(steam_id):
		peers[steam_id].resync = true


func _add_peer(steam_id: int) -> Dictionary:
	if not peers.has(steam_id):
		peers[steam_id] = {
			"name": transport.get_persona_name(steam_id),
			"ready": false,
			"rtt_ms": -1,
			"last_seen_msec": OS.get_ticks_msec(),
			"resync": false,
			"last_resync_msec": -RESYNC_INTERVAL_MSEC,
		}
	return peers[steam_id]


func _on_lobby_ready(_lobby_id: int, _is_host: bool) -> void:
	DlcBorrow.revert()  # a new lobby (either role) starts with this machine's own DLC only
	peers.clear()
	_next_hello_msec = -1


func _on_lobby_left() -> void:
	DlcBorrow.revert()  # every way out of a lobby; the title screen loads after (deferred)
	_next_hello_msec = -1
	for steam_id in peers.keys():
		emit_signal("peer_removed", steam_id)
	peers.clear()


func _on_peer_joined(steam_id: int) -> void:
	if is_host():
		_add_peer(steam_id)  # becomes ready after HELLO
	elif steam_id == transport.host_id:
		_add_peer(steam_id)
		_next_hello_msec = 0
		resend_hello(OS.get_ticks_msec())


# Reliable messages are state the client can't do without (BATTLE_START, TYPE_DEF, STATE,
# ...): a failed send means a full resync. Unreliable ones are superseded by the next anyway.
func _on_send_failed(steam_id: int, channel: int, result) -> void:
	if channel != transport.CHANNEL_RELIABLE:
		return  # the transport warns once a second; the Mod Loader keeps every log entry
	var peer = peers.get(steam_id)
	if is_host() and peer != null and peer.ready:
		if not peer.resync:
			ModLoaderLog.warning(
				"Reliable send to %s failed (result %s); full resync queued" % [steam_id, result],
				LOG_NAME
			)
		peer.resync = true
	elif OS.get_ticks_msec() >= _next_send_warning_msec:
		_next_send_warning_msec = OS.get_ticks_msec() + 1000
		ModLoaderLog.warning("Reliable send to %s failed (result %s)" % [steam_id, result], LOG_NAME)


func _on_peer_left(steam_id: int) -> void:
	if peers.erase(steam_id):
		emit_signal("peer_removed", steam_id)


func _on_message_received(steam_id: int, _channel: int, data: PoolByteArray) -> void:
	var decoded = Protocol.decode(data)
	if decoded == null:
		ModLoaderLog.debug("Malformed message from %s" % steam_id, LOG_NAME)
		return
	var msg_type: int = decoded[0]
	var body = decoded[1]
	var peer := _add_peer(steam_id)
	peer.last_seen_msec = OS.get_ticks_msec()
	match msg_type:
		Protocol.Msg.HELLO:
			_handle_hello(steam_id, body)
		Protocol.Msg.WELCOME:
			_handle_welcome(steam_id, body)
		Protocol.Msg.PING:
			send_unreliable(steam_id, Protocol.Msg.PONG, body)
		Protocol.Msg.PONG:
			if typeof(body) == TYPE_DICTIONARY and body.has("t"):
				peer.rtt_ms = OS.get_ticks_msec() - int(body.t)
		_:
			if peer.ready:
				emit_signal("message", steam_id, msg_type, body)


# Idempotent: answered every time (the client resends until it sees WELCOME).
func _handle_hello(steam_id: int, body) -> void:
	if not is_host():
		return
	var local: Dictionary = Compat.local_info(transport.get_persona_name(transport.local_id))
	var reason := Compat.incompatibility(local, body)
	var accepted := reason == ""
	send_reliable(
		steam_id,
		Protocol.Msg.WELCOME,
		{"version": Protocol.VERSION, "accepted": accepted, "reason": reason, "dlcs": local.dlcs}
	)
	if not accepted:
		ModLoaderLog.warning("Rejected %s: %s" % [steam_id, reason], LOG_NAME)
		return
	var lent := Compat.missing_dlcs(local.dlcs, body.get("dlcs"))
	if not lent.empty() and not peers[steam_id].ready:
		ModLoaderLog.info("%s plays with the host's DLC: %s" % [steam_id, lent], LOG_NAME)
	if peers[steam_id].ready:
		request_resync(steam_id)  # it missed WELCOME, so it dropped what followed too
	else:
		_mark_ready(steam_id)


func _handle_welcome(steam_id: int, body) -> void:
	if steam_id != transport.host_id or typeof(body) != TYPE_DICTIONARY:
		return
	_next_hello_msec = -1
	if body.get("accepted", false):
		if not peers[steam_id].ready:
			# Before peer_ready: the client view and every sync module see the host's DLC.
			var borrowed := DlcBorrow.borrow(body.get("dlcs"))
			if not borrowed.empty():
				ModLoaderLog.info("Using the host's DLC: %s" % [borrowed], LOG_NAME)
			_mark_ready(steam_id)
	else:
		var reason := "The host rejected the join: %s" % str(body.get("reason", "?"))
		ModLoaderLog.error(reason, LOG_NAME)
		transport.emit_signal("lobby_failed", reason)  # ui/lobby_menu.gd shows it
		transport.leave_lobby()


func _mark_ready(steam_id: int) -> void:
	peers[steam_id].ready = true
	ModLoaderLog.info("Peer ready: %s (%s)" % [peers[steam_id].name, steam_id], LOG_NAME)
	emit_signal("peer_ready", steam_id)
