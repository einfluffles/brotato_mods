extends Node
# Session state on top of the transport: role, handshake, per-peer liveness/RTT.

signal peer_ready(steam_id)
signal peer_removed(steam_id)
signal message(steam_id, msg_type, body)

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:Session"
const PING_INTERVAL_MSEC := 1000
const PEER_STALE_MSEC := 5000
const HOST_TIMEOUT_MSEC := 15000  # client gives up on a silent host (crash, network loss)

var transport: Node = null
# steam_id -> {name, ready, rtt_ms, last_seen_msec}
var peers := {}

var _next_ping_msec := 0


func setup(steam_transport: Node) -> void:
	transport = steam_transport
	transport.connect("lobby_ready", self, "_on_lobby_ready")
	transport.connect("lobby_left", self, "_on_lobby_left")
	transport.connect("peer_joined", self, "_on_peer_joined")
	transport.connect("peer_left", self, "_on_peer_left")
	transport.connect("message_received", self, "_on_message_received")


func is_host() -> bool:
	return transport.is_host()


func is_client() -> bool:
	return transport.is_active() and not transport.is_host()


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
	if not transport.is_active():
		return
	var now := OS.get_ticks_msec()
	if is_client() and _host_timed_out(now):
		ModLoaderLog.warning("No messages from the host for a while; leaving", LOG_NAME)
		transport.emit_signal("lobby_failed", "Connection to the host lost")
		transport.leave_lobby()
		return
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


func _add_peer(steam_id: int) -> Dictionary:
	if not peers.has(steam_id):
		peers[steam_id] = {
			"name": transport.get_persona_name(steam_id),
			"ready": false,
			"rtt_ms": -1,
			"last_seen_msec": OS.get_ticks_msec(),
		}
	return peers[steam_id]


func _on_lobby_ready(_lobby_id: int, _is_host: bool) -> void:
	peers.clear()


func _on_lobby_left() -> void:
	for steam_id in peers.keys():
		emit_signal("peer_removed", steam_id)
	peers.clear()


func _on_peer_joined(steam_id: int) -> void:
	if is_host():
		_add_peer(steam_id)  # becomes ready after HELLO
	elif steam_id == transport.host_id:
		_add_peer(steam_id)
		send_reliable(
			steam_id,
			Protocol.Msg.HELLO,
			{"version": Protocol.VERSION, "name": transport.get_persona_name(transport.local_id)}
		)


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


func _handle_hello(steam_id: int, body) -> void:
	if not is_host() or typeof(body) != TYPE_DICTIONARY:
		return
	var version := int(body.get("version", -1))
	var accepted := version == Protocol.VERSION
	var reason := "" if accepted else "protocol %s != host %s" % [version, Protocol.VERSION]
	send_reliable(
		steam_id,
		Protocol.Msg.WELCOME,
		{"version": Protocol.VERSION, "accepted": accepted, "reason": reason}
	)
	if accepted:
		_mark_ready(steam_id)
	else:
		ModLoaderLog.warning("Rejected %s: %s" % [steam_id, reason], LOG_NAME)


func _handle_welcome(steam_id: int, body) -> void:
	if steam_id != transport.host_id or typeof(body) != TYPE_DICTIONARY:
		return
	if body.get("accepted", false):
		_mark_ready(steam_id)
	else:
		ModLoaderLog.error("Host rejected us: %s" % body.get("reason", "?"), LOG_NAME)
		transport.leave_lobby()


func _mark_ready(steam_id: int) -> void:
	peers[steam_id].ready = true
	ModLoaderLog.info("Peer ready: %s (%s)" % [peers[steam_id].name, steam_id], LOG_NAME)
	emit_signal("peer_ready", steam_id)
