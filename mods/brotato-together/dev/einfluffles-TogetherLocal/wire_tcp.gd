extends Reference
# The wire between game processes on one PC: TCP on 127.0.0.1, one emulator per process
# (steam_emulator.gd). The host's game listens (TCP_Server bound to 127.0.0.1 only), every client
# connects to it (an outgoing StreamPeerTCP: no socket of its own that anything could reach).
# Polled by hand (poll()), never blocking: what a socket does not take now waits for the next poll.
#
# Why not ENet: Godot 3's ENet client binds its UDP socket to every interface, whatever
# set_bind_ip says (checked on the game's engine and on Godot 3.6.2), and local play must not
# open anything beyond 127.0.0.1. Nothing is lost by it: the emulator's link already decides loss,
# delay and order of unreliable messages before they reach the wire, and loopback adds nothing to
# that. So the wire carries every packet reliable and in order.
#
# Star: a client only ever talks to the host's game; a packet for another client goes through
# it, and it passes it on. The mod's clients only talk to the host anyway, but the lobby passes to
# a client when the host leaves it, and then the others reach the new owner through the host.
#
# Every frame: its length (4 bytes, little endian), MAGIC, WIRE_VERSION, then var2bytes of a
# Dictionary (never objects). The first frame of a client is a hello with the launcher's token and
# its steam id; the host drops a connection whose hello is wrong, missing or late. After that the
# wire's own packets (k in WIRE_KINDS) keep the client's view of the others: welcome, roster
# (connected ids, the host's lobbies), invite. Everything else is an emulator packet (k msg,
# accepted, close, ...) for receive_packet; the host sets its "from" to the sender's id, so no
# client speaks for another. A closed or killed game closes its sockets: the other side sees it
# at once and the emulator hears wire_lost.
#
# Docs: docs/implementation.md, "Local play (dev mod)".

signal note(level, text)  # level "info" / "warning": for the dev mod's log
signal online  # client: the host's welcome is in
signal invited(lobby_id, friend_id)  # client: the host opened its invite dialog

const MAGIC := [0x42, 0x54, 0x4C, 0x57]  # "BTLW": brotato:together local wire
const WIRE_VERSION := 1
const ADDRESS := "127.0.0.1"
const MAX_CLIENTS := 3
const MAX_FRAME_BYTES := 2097152  # a Steam message is at most 512 KB
const HELLO_TIMEOUT_MSEC := 5000
const RETRY_MSEC := 1000  # a client tries again this long after a failed attempt
const WIRE_KINDS := ["hello", "welcome", "refused", "roster", "invite"]
const HOST_KEY := 1  # a client's only connection

var role := ""  # "host" or "client"
var port := 0
var state := "idle"  # idle, listening (host), connecting, online (client), closed, failed
var host_id := 0  # the host's steam id (client: from the welcome)
var host_lobbies := []  # client: the lobbies the host's emulator owns
var peer_ids := []  # steam ids reachable over this wire (host: clients; client: host and others)
var packets_out := 0
var packets_in := 0
var bytes_out := 0
var bytes_in := 0

var _emulator = null
var _token := ""
var _server: TCP_Server = null
var _links := {}  # key -> Link (host: one per client; client: HOST_KEY)
var _next_key := 1
var _clients := {}  # host: steam id -> key
var _lobbies_sent := []  # host: the lobbies in the last roster
var _retry_msec := 0  # client: when to try again (0: not waiting)


# One TCP connection: what came in and is not a whole frame yet, what waits to go out.
class Link:
	extends Reference
	var stream: StreamPeerTCP = null
	var steam_id := 0  # 0: no hello yet (host), or not online yet (client)
	var opened_msec := 0
	var inbox := PoolByteArray()
	var outbox := PoolByteArray()
	var closing := false  # refused: goes once the outbox is out

	func _init(tcp: StreamPeerTCP) -> void:
		stream = tcp
		opened_msec = OS.get_ticks_msec()

	# Pool arrays are values: appended to here, never through link.outbox from outside (that would
	# append to a copy).
	func push(frame: PoolByteArray) -> void:
		outbox.append_array(frame)

	func feed(data: PoolByteArray) -> void:
		inbox.append_array(data)

	func connected() -> bool:
		return stream.get_status() == StreamPeerTCP.STATUS_CONNECTED

	# Sends what the socket takes now; false once the connection is gone.
	func flush() -> bool:
		if outbox.empty():
			return true
		var result: Array = stream.put_partial_data(outbox)
		if result[0] != OK:
			return false
		var sent: int = result[1]
		if sent >= outbox.size():
			outbox = PoolByteArray()
		elif sent > 0:
			outbox = outbox.subarray(sent, outbox.size() - 1)
		return true

	# Reads what has arrived; false once the other side has closed it.
	func receive() -> bool:
		var available := stream.get_available_bytes()
		var result: Array = stream.get_partial_data(available if available > 0 else 1)
		var data: PoolByteArray = result[1]
		if not data.empty():
			inbox.append_array(data)
		return result[0] == OK and stream.get_status() == StreamPeerTCP.STATUS_CONNECTED

	# The next whole frame's body, an empty array when none is complete, null when it is broken.
	func next_frame():
		if inbox.size() < 4:
			return PoolByteArray()
		var size := inbox[0] | (inbox[1] << 8) | (inbox[2] << 16) | (inbox[3] << 24)
		if size <= 0 or size > MAX_FRAME_BYTES:
			return null
		if inbox.size() < 4 + size:
			return PoolByteArray()
		var body := inbox.subarray(4, 3 + size)
		if inbox.size() > 4 + size:
			inbox = inbox.subarray(4 + size, inbox.size() - 1)
		else:
			inbox = PoolByteArray()
		return body


# --- Setup ---


# The host's side: listens on 127.0.0.1:at_port, emulator gets this wire. OK or an Error.
func listen(emulator, at_port: int, token: String) -> int:
	role = "host"
	port = at_port
	_token = token
	_adopt(emulator)
	host_id = emulator.steam_id
	_server = TCP_Server.new()
	var error := _server.listen(at_port, ADDRESS)
	if error != OK:
		_server = null
		state = "failed"
		_note("warning", "Wire: cannot listen on %s:%s (error %s)" % [ADDRESS, at_port, error])
		return error
	state = "listening"
	_note("info", "Wire: listening on %s:%s" % [ADDRESS, at_port])
	return OK


# A client's side: connects to the host's game on 127.0.0.1:at_port and keeps trying until the
# host's game is up (and again after the host's game is gone).
func join(emulator, at_port: int, token: String) -> void:
	role = "client"
	port = at_port
	_token = token
	_adopt(emulator)
	_connect()


# Leaves the line: what waits goes out first (a client's last "leave"), then the sockets close and
# the other side hears it at once.
func close() -> void:
	for key in _links.keys():
		var link: Link = _links[key]
		if link.connected():
			link.flush()  # what the socket takes now; never waits for the other side
		link.stream.disconnect_from_host()
	_links.clear()
	if _server != null:
		_server.stop()
		_server = null
	state = "closed"
	_retry_msec = 0
	for id in peer_ids.duplicate():
		_lose(id)
	_clients.clear()


func _adopt(emulator) -> void:
	_emulator = emulator
	emulator.attach_wire(self)


func _connect() -> void:
	_retry_msec = 0
	var stream := StreamPeerTCP.new()
	var error := stream.connect_to_host(ADDRESS, port)
	if error != OK:
		_note("warning", "Wire: cannot connect to %s:%s (error %s)" % [ADDRESS, port, error])
		_retry_msec = OS.get_ticks_msec() + RETRY_MSEC
		return
	_links[HOST_KEY] = Link.new(stream)
	state = "connecting"


# --- Each frame ---


# Reads the sockets and hands what arrived to the emulator (before the emulator's own poll()),
# then sends what is waiting.
func poll() -> void:
	if role == "host":
		_host_poll()
	else:
		_client_poll()


func _host_poll() -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var stream := _server.take_connection()
		stream.set_no_delay(true)
		_links[_next_key] = Link.new(stream)
		_next_key += 1
	var now := OS.get_ticks_msec()
	for key in _links.keys():
		var link: Link = _links.get(key)
		if link == null:
			continue
		var alive := link.receive()
		_read_frames(key, link)
		if link.steam_id == 0 and not link.closing and now - link.opened_msec > HELLO_TIMEOUT_MSEC:
			_refuse(key, "no hello in time")
		if not link.flush() or not alive or (link.closing and link.outbox.empty()):
			_drop(key)
	var lobbies: Array = _emulator.owned_lobby_ids()
	if lobbies != _lobbies_sent:
		_lobbies_sent = lobbies
		_send_rosters()


func _client_poll() -> void:
	var link: Link = _links.get(HOST_KEY)
	if link == null:
		if _retry_msec > 0 and OS.get_ticks_msec() >= _retry_msec:
			_connect()
		return
	var status := link.stream.get_status()
	if state == "connecting":
		if status == StreamPeerTCP.STATUS_CONNECTING:
			return
		if status != StreamPeerTCP.STATUS_CONNECTED:  # nobody listens yet
			_links.erase(HOST_KEY)
			_retry_msec = OS.get_ticks_msec() + RETRY_MSEC
			return
		link.stream.set_no_delay(true)
		state = "hello"
		var hello := {"k": "hello", "token": _token, "id": _emulator.steam_id}
		hello["name"] = _emulator.persona_name
		_queue(link, hello)
	var alive := link.receive()
	_read_frames(HOST_KEY, link)
	if not _links.has(HOST_KEY):
		return  # refused while reading
	if not link.flush() or not alive:
		_host_gone()


func _read_frames(key: int, link: Link) -> void:
	while _links.get(key) == link:
		var body = link.next_frame()
		if body == null:
			_note("warning", "Wire: a broken frame, the connection goes")
			if role == "host":
				_drop(key)
			else:
				_host_gone()
			return
		if body.empty():
			return
		packets_in += 1
		bytes_in += body.size() + 4
		var packet = decode(body)
		if role == "host":
			_host_receive(key, link, packet)
		elif packet != null:
			_client_receive(packet)


# --- Sending (the emulator's side) ---


# False when the packet's target cannot be reached over this wire (unknown or gone).
func send_packet(packet: Dictionary) -> bool:
	var to := int(packet.get("to", 0))
	if not to in peer_ids:
		return false
	var key: int = _clients.get(to, 0) if role == "host" else HOST_KEY
	var link: Link = _links.get(key)
	if link == null:
		return false
	_queue(link, packet)
	return true


# Host: every connected client gets an invite to lobby_id (the overlay's invite, accepted).
func send_invite(lobby_id: int) -> int:
	var count := 0
	for id in _clients:
		var link: Link = _links.get(_clients[id])
		if link != null:
			_queue(link, {"k": "invite", "lobby": lobby_id, "from": host_id})
			count += 1
	return count


static func encode(packet: Dictionary) -> PoolByteArray:
	var body := PoolByteArray(MAGIC)
	body.append(WIRE_VERSION)
	body.append_array(var2bytes(packet))
	var size := body.size()
	var frame := PoolByteArray([size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF, size >> 24])
	frame.append_array(body)
	return frame


func _queue(link: Link, packet: Dictionary) -> void:
	var frame := encode(packet)
	link.push(frame)
	packets_out += 1
	bytes_out += frame.size()
	link.flush()  # a connection that is gone: the next poll notices


# --- Receiving ---


# The Dictionary in a frame's body, or null (another magic or version, not a Dictionary).
static func decode(data: PoolByteArray):
	if data.size() <= MAGIC.size() + 1:
		return null
	for i in MAGIC.size():
		if data[i] != MAGIC[i]:
			return null
	if data[MAGIC.size()] != WIRE_VERSION:
		return null
	var value = bytes2var(data.subarray(MAGIC.size() + 1, data.size() - 1), false)
	if not value is Dictionary or not value.has("k"):
		return null
	return value


func _host_receive(key: int, link: Link, packet) -> void:
	if link.closing:
		return
	if link.steam_id == 0:
		_hello(key, link, packet)
		return
	if packet == null or str(packet.k) in WIRE_KINDS:
		return
	packet["from"] = link.steam_id
	var to := int(packet.get("to", 0))
	if to == host_id:
		_emulator.receive_packet(packet)
	elif _clients.has(to):  # for another client: pass it on
		send_packet(packet)


func _hello(key: int, link: Link, packet) -> void:
	if packet == null or str(packet.k) != "hello":
		_refuse(key, "not a hello of this wire")
		return
	if str(packet.get("token", "")) != _token:
		_refuse(key, "wrong token")
		return
	var id := int(packet.get("id", 0))
	if not _emulator.is_fake_id(id) or id == host_id:
		_refuse(key, "steam id %s not free" % id)
		return
	if _clients.has(id):  # that game again (restarted before its old connection closed)
		_note("info", "Wire: client %s is back, its old connection is dropped" % id)
		_drop(_clients[id])
	if _clients.size() >= MAX_CLIENTS:
		_refuse(key, "already %s clients" % MAX_CLIENTS)
		return
	link.steam_id = id
	_clients[id] = key
	peer_ids.append(id)
	_note("info", "Wire: client %s connected" % id)
	_queue(link, {"k": "welcome", "id": host_id})
	_send_rosters()


func _refuse(key: int, why: String) -> void:
	var link: Link = _links.get(key)
	if link == null:
		return
	_note("warning", "Wire: refused a connection (%s)" % why)
	_queue(link, {"k": "refused", "why": why})
	link.closing = true


func _drop(key: int) -> void:
	var link: Link = _links.get(key)
	if link == null:
		return
	_links.erase(key)
	link.stream.disconnect_from_host()
	var id := link.steam_id
	if id == 0 or _clients.get(id) != key:
		return
	_clients.erase(id)
	_note("info", "Wire: client %s is gone" % id)
	_lose(id)
	_send_rosters()


func _send_rosters() -> void:
	for id in _clients:
		var others := [host_id]
		for other in _clients:
			if other != id:
				others.append(other)
		var link: Link = _links.get(_clients[id])
		if link != null:
			_queue(link, {"k": "roster", "ids": others, "lobbies": _lobbies_sent})


func _client_receive(packet: Dictionary) -> void:
	match str(packet.k):
		"welcome":
			host_id = int(packet.get("id", 0))
			state = "online"
			if not host_id in peer_ids:
				peer_ids.append(host_id)
			_note("info", "Wire: online with the host's game (host %s)" % host_id)
			emit_signal("online")
		"refused":
			_note("warning", "Wire: the host's game refused this one (%s)" % packet.get("why"))
			close()
			state = "failed"
		"roster":
			_roster(packet.get("ids", []), packet.get("lobbies", []))
		"invite":
			emit_signal("invited", int(packet.get("lobby", 0)), int(packet.get("from", 0)))
		"hello":
			pass
		_:
			_emulator.receive_packet(packet)


func _roster(ids: Array, lobbies: Array) -> void:
	host_lobbies = lobbies
	for id in peer_ids.duplicate():
		if id != host_id and not id in ids:
			_lose(id)
	for id in ids:
		if not int(id) in peer_ids:
			peer_ids.append(int(id))


# id's game is gone: the emulator hears it as Steam would (sessions fail, it leaves the lobby).
func _lose(id: int) -> void:
	peer_ids.erase(id)
	if _emulator != null:
		_emulator.wire_lost(id)


func _host_gone() -> void:
	var link: Link = _links.get(HOST_KEY)
	if link != null:
		link.stream.disconnect_from_host()
	_links.erase(HOST_KEY)
	for id in peer_ids.duplicate():
		_lose(id)
	host_lobbies = []
	if state == "failed" or state == "closed":
		return
	_note("warning", "Wire: the host's game is gone; trying again")
	state = "connecting"
	_retry_msec = OS.get_ticks_msec() + RETRY_MSEC


func _note(level: String, text: String) -> void:
	emit_signal("note", level, text)
