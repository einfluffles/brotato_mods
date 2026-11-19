extends Reference
# Suite traffic: what went out reliably to a peer, for the log (net/traffic.gd, Session). A real
# Session on a fake transport whose connection_status reports a chosen pending value.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Traffic := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/traffic.gd")
const LinkWatch := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/link_watch.gd")
const Session := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/session.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const PEER := 7
const OTHER := 8
const SUMMARY := "; reliable in the last 2 s: "

var _t: Node


class FakeTransport:
	extends Node
	const CHANNEL_RELIABLE := 0
	const CHANNEL_UNRELIABLE := 1
	var link_watch = LinkWatch.new()
	var pending := 0  # pending_reliable reported; -1: no status at all (Steam not running)
	var asked := 0  # connection_status calls
	var sent := []  # [steam_id, channel, size]

	func send(steam_id: int, channel: int, data: PoolByteArray) -> void:
		sent.append([steam_id, channel, data.size()])

	func connection_status(_steam_id: int) -> Dictionary:
		asked += 1
		return {} if pending < 0 else {"ping": 20, "pending_reliable": pending}


func _init(test_mod: Node) -> void:
	_t = test_mod


func run() -> void:
	_test_labels()
	_test_window()
	var session: Node = Session.new()
	var transport := FakeTransport.new()
	session.transport = transport
	session.peers[PEER] = {"name": "peer"}
	_test_sums(session, transport)
	_test_status_threshold(session, transport)
	_test_burst_lines(session, transport)
	_test_query_limit(session, transport)
	_test_peer_left(session, transport)
	_measure()
	session.free()
	transport.free()


func _test_labels() -> void:
	var shop := [StateStream.RUN_SHOP, 3, {}]
	var cursors := [StateStream.CURSORS, 1, null]
	_t._check(
		(
			Traffic.label(Protocol.Msg.STATE, shop) == "STATE shop"
			and Traffic.label(Protocol.Msg.STATE, cursors) == "STATE cursors"
			and Traffic.label(Protocol.Msg.UI_SOUNDS, {"sounds": []}) == "UI_SOUNDS"
			and Traffic.label(Protocol.Msg.BATTLE_START, null) == "BATTLE_START"
		),
		"labels: the message type, STATE with its section"
	)
	_t._check(
		(
			Traffic.label(Protocol.Msg.STATE, [99, 0, null]) == "STATE"
			and Traffic.label(Protocol.Msg.STATE, "x") == "STATE"
			and Traffic.label(999, null) == "999"
		),
		"odd sections and types still get a label"
	)


func _test_window() -> void:
	var traffic = Traffic.new()
	traffic.note(PEER, "A", 100, 10100)
	traffic.note(PEER, "A", 50, 10900)
	traffic.note(PEER, "B", 10, 11500)
	_t._check(
		_same(traffic.window(PEER, 11500), {"A": [2, 150], "B": [1, 10]}),
		"the window holds this second and the one before (%s)" % [traffic.window(PEER, 11500)]
	)
	_t._check(
		_same(traffic.window(PEER, 12000), {"B": [1, 10]}),
		"a second later the older bucket is gone (%s)" % [traffic.window(PEER, 12000)]
	)
	traffic.note(PEER, "C", 1, 12999)
	_t._check(
		_same(traffic.window(PEER, 13000), {"C": [1, 1]}) and traffic.window(PEER, 15000).empty(),
		"a jump of seconds leaves nothing older behind"
	)
	_t._check(traffic.window(OTHER, 13000).empty(), "per peer")
	for k in 3:
		traffic.note(OTHER, "STATE shop", 13414, 20000 + k)
	for k in 4:
		traffic.note(OTHER, "UI_SOUNDS", 205, 20100 + k)
	_t._check(
		traffic.summary(OTHER, 20500) == "STATE shop 3 x 13.1 KB, UI_SOUNDS 4 x 0.2 KB",
		"summary: count x mean size, largest first (%s)" % traffic.summary(OTHER, 20500)
	)
	for text in ["a", "b", "c", "d", "e"]:
		traffic.note(PEER, text, 1000 + text.ord_at(0), 30000)
	_t._check(
		traffic.summary(PEER, 30000) == "e 1 x 1.1 KB, d 1 x 1.1 KB, c 1 x 1.1 KB, b 1 x 1.1 KB",
		"at most four (%s)" % traffic.summary(PEER, 30000)
	)


# Sizes as they go out: what Session.send_reliable encoded.
func _test_sums(session: Node, transport: FakeTransport) -> void:
	var traffic = session.get("traffic")
	var shop := [StateStream.RUN_SHOP, 1, {"run": PoolByteArray(_bytes(5000))}]
	var sounds := {"sounds": [["res://a.wav", 0.0, 1.0, null]]}
	for _k in 3:
		session.send_reliable(PEER, Protocol.Msg.STATE, shop)
	for _k in 4:
		session.send_reliable(PEER, Protocol.Msg.UI_SOUNDS, sounds)
	var shop_size := Protocol.encode(Protocol.Msg.STATE, shop).size()
	var sounds_size := Protocol.encode(Protocol.Msg.UI_SOUNDS, sounds).size()
	var window: Dictionary = traffic.window(PEER, OS.get_ticks_msec()) if traffic != null else {}
	_t._check(
		(
			transport.sent.size() == 7
			and window.get("STATE shop") == [3, 3 * shop_size]
			and window.get("UI_SOUNDS") == [4, 4 * sounds_size]
		),
		"Session notes each reliable message with its encoded size (%s)" % [window]
	)


func _test_status_threshold(session: Node, transport: FakeTransport) -> void:
	transport.link_watch.paths[PEER] = "relayed via fra"
	transport.pending = Traffic.BACKLOG_TEXT_BYTES - 1
	var below: String = session.steam_status_text(PEER)
	transport.pending = Traffic.BACKLOG_TEXT_BYTES
	var above: String = session.steam_status_text(PEER)
	transport.pending = -1
	var none: String = session.steam_status_text(PEER)
	_t._check(not SUMMARY in below, "below 4 KB pending the status has no traffic: %s" % below)
	_t._check(
		(
			SUMMARY + "STATE shop 3 x " in above
			and ", UI_SOUNDS 4 x " in above
			and above.ends_with("; path: relayed via fra")
		),
		"from 4 KB on it names what went out, before the path: %s" % above
	)
	_t._check(none == "; path: relayed via fra", "no Steam numbers, no traffic: %s" % none)


func _test_burst_lines(session: Node, transport: FakeTransport) -> void:
	var traffic = session.get("traffic")
	if traffic == null:
		_t._check(false, "a big queue gets a line of its own")
		return
	var lines: int = traffic.lines
	transport.pending = Traffic.BIG_BACKLOG_BYTES
	session.send_reliable(PEER, Protocol.Msg.UI_SOUNDS, {"sounds": []})
	_t._check(traffic.lines == lines, "64 KB pending is no burst yet")
	transport.pending = Traffic.BIG_BACKLOG_BYTES + 1
	traffic.peers[PEER].next_query_msec = 0  # 250 ms later
	session.send_reliable(PEER, Protocol.Msg.UI_SOUNDS, {"sounds": []})
	_t._check(
		(
			traffic.lines == lines + 1
			and traffic.last_line.begins_with("Reliable burst to peer: UI_SOUNDS of ")
			and " queued, 64.0 KB pending" + SUMMARY + "STATE shop 3 x " in traffic.last_line
		),
		"over 64 KB pending: a line of its own: %s" % traffic.last_line
	)
	var asked: int = transport.asked
	var big := [StateStream.UPGRADES, 2, {"run": PoolByteArray(_bytes(40000))}]
	session.send_reliable(PEER, Protocol.Msg.STATE, big)
	session.send_reliable(PEER, Protocol.Msg.UI_SOUNDS, {"sounds": []})
	_t._check(
		traffic.lines == lines + 1 and transport.asked == asked,
		"within 5 s no other line, and Steam's queue is not asked"
	)
	traffic.peers[PEER].next_line_msec = OS.get_ticks_msec()  # 5 s later
	transport.pending = 0
	session.send_reliable(PEER, Protocol.Msg.STATE, big)
	_t._check(
		(
			traffic.lines == lines + 2
			and traffic.last_line.begins_with("Reliable burst to peer: STATE upgrades of 39.")
		),
		"then a message over 32 KB gets one too: %s" % traffic.last_line
	)
	traffic.peers[PEER].next_line_msec = OS.get_ticks_msec()
	session.send_reliable(PEER, Protocol.Msg.STATE, [StateStream.UPGRADES, 3, null])
	_t._check(traffic.lines == lines + 2, "a small message on a short queue does not")


# Small messages ask Steam's queue at most every 250 ms per peer, a message of 4 KB or more
# always: a shower of sounds or cursors costs no Steam call per send.
func _test_query_limit(session: Node, transport: FakeTransport) -> void:
	var traffic = session.get("traffic")
	if traffic == null or not traffic.has_method("query_due"):
		_t._check(false, "small messages do not ask Steam on every send")
		return
	transport.pending = 0
	traffic.peers[PEER].next_line_msec = 0
	traffic.peers[PEER].next_query_msec = 0
	var asked: int = transport.asked
	for k in 10:
		session.send_reliable(PEER, Protocol.Msg.UI_SOUNDS, {"sounds": [k]})
	_t._check(
		transport.asked == asked + 1,
		"10 small messages at once ask Steam once (%d)" % [transport.asked - asked]
	)
	var body := [StateStream.RUN_SHOP, 4, {"run": PoolByteArray(_bytes(Traffic.QUERY_MIN_BYTES))}]
	session.send_reliable(PEER, Protocol.Msg.STATE, body)
	session.send_reliable(PEER, Protocol.Msg.STATE, body)
	_t._check(
		transport.asked == asked + 3,
		"a message of 4 KB or more always asks (%d)" % [transport.asked - asked]
	)


func _test_peer_left(session: Node, transport: FakeTransport) -> void:
	var traffic = session.get("traffic")
	session.send_reliable(OTHER, Protocol.Msg.STATE, [StateStream.MENU, 1, {}])
	session._on_peer_left(PEER)
	transport.pending = Traffic.BIG_BACKLOG_BYTES
	var status: String = session.steam_status_text(PEER)
	_t._check(
		traffic != null and not traffic.peers.has(PEER) and traffic.peers.has(OTHER),
		"a peer that left is forgotten, the others are kept"
	)
	_t._check(not SUMMARY in status, "its status has no traffic any more: %s" % status)
	session._on_lobby_left()
	_t._check(traffic != null and traffic.peers.empty(), "nothing is kept after the lobby")


# What noting one message costs Session.send_reliable (label and buckets; Steam is not asked).
func _measure() -> void:
	var traffic = Traffic.new()
	var body := [StateStream.RUN_SHOP, 1, null]
	var count := 20000
	var start := OS.get_ticks_usec()
	for k in count:
		traffic.note(PEER, Traffic.label(Protocol.Msg.STATE, body), 100, k / 10)
	var each := float(OS.get_ticks_usec() - start) / count
	print("  info: noting a reliable message: %.2f us" % each)
	_t._check(each < 50.0, "noting a message is cheap (%.2f us)" % each)


# Dictionaries compare by reference in Godot 3.
static func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key) or a[key] != b[key]:
			return false
	return true


static func _bytes(count: int) -> Array:
	var bytes := []
	for k in count:
		bytes.append((k * 7919) % 251)  # little for compression to find (var2bytes does none)
	return bytes
