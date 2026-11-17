extends Reference
# sync/state_stream.gd on its own: streams of their own (outside the tree, stepped by hand) on a
# fake session that keeps what the host sends, with probe sections that record what the client
# applies. Then the mod's own stream: created before the sync modules, given to each of them.
#  - host: change key and interval, per-peer bodies built once, dirty, flush, resync on
#    peer_ready in section order (next step, after what other peer_ready handlers send), inactive
#    -> null once, nothing while not host, the state_sent hook (after each send, not by
#    message_for), heavy sections held while Steam's send queue to a peer is full
#  - client: pending until the handler accepts, retry(), superseding, revisions, timeout, clear,
#    section order, malformed STATE, senders other than the host, a broken handler, lobby_left,
#    the accept_state hook (every body that is not stale, as it arrives, before it is pending)
#  - host -> client in one process (message_for -> receive) and the idle cost per frame

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const HOST := 2
const P1 := 11
const P2 := 12
const P3 := 13
const IDLE_STEPS := 5000

var t: Node  # the test mod: _check, scene tree
var _nodes := []  # streams and fake sessions, freed at the end


class FakeTransport:
	extends Reference
	signal lobby_left
	var host_id := 0
	var statuses := {}  # steam_id -> what Steam says about the connection ({}: no Steam)

	func connection_status(steam_id: int) -> Dictionary:
		return statuses.get(steam_id, {})


class FakeSession:
	extends Node
	signal peer_ready(steam_id)
	signal message(steam_id, msg_type, body)
	var transport: Reference = null
	var peers := {}
	var host := true
	var sent := []  # [steam_id, msg_type, body], the body as it comes off the wire
	var resyncs_asked := 0  # ask_resync calls (sync/run_parts.gd: a missing run part)

	func is_host() -> bool:
		return host

	func is_client() -> bool:
		return not host

	func ask_resync() -> void:
		resyncs_asked += 1

	func send_reliable(steam_id: int, msg_type: int, body = null) -> void:
		sent.append([steam_id, msg_type, bytes2var(var2bytes(body), false)])


# Provider and handler of one or more sections.
class Probe:
	extends Reference
	var key := ""
	var body = null
	var builds := 0
	var patches := {}  # steam_id -> per-peer patch
	var accept := true
	var answer = null  # returned instead of accept when not null: a broken handler
	var tries := 0
	var applied := []  # [section, body, revision]
	var cleared := []
	var order := []  # applied sections, shared between probes

	func state_key(_section: int) -> String:
		return key

	func state_body(_section: int):
		builds += 1
		return body

	func state_patch(_section: int, steam_id: int) -> Dictionary:
		return patches.get(steam_id, {})

	func apply_state(section: int, state, revision: int):
		tries += 1
		if answer != null:
			return answer
		if accept:
			applied.append([section, state, revision])
			order.append(section)
		return accept

	func clear_state(section: int) -> void:
		cleared.append(section)


# Provider and handler with the optional hooks: when each send was recorded, what arrived.
class Hooked:
	extends Reference
	var key := ""
	var body = null
	var accept := true
	var stream: Node = null
	var events := []  # ["sent", section, steam_id, messages sent so far] | ["accept", ...] | ...

	func state_key(_section: int) -> String:
		return key

	func state_body(_section: int):
		return body

	func state_sent(section: int, steam_id: int) -> void:
		events.append(["sent", section, steam_id, stream.session.sent.size()])

	func accept_state(section: int, state, revision: int) -> void:
		events.append(["accept", section, state, revision, stream.is_pending(section)])

	func apply_state(section: int, state, revision: int) -> bool:
		if accept:
			events.append(["apply", section, state, revision])
		return accept


# A module that sends from its own peer_ready (as BattleHost sends BATTLE_START).
class Joiner:
	extends Reference
	var session: Node = null

	func _on_peer_ready(steam_id: int) -> void:
		session.send_reliable(steam_id, Protocol.Msg.BATTLE_START, {"battle_id": 7})


# A handler without clear_state.
class Plain:
	extends Reference
	var tries := 0

	func apply_state(_section: int, _state, _revision: int) -> bool:
		tries += 1
		return true


func run(test_mod: Node, together: Node):
	t = test_mod
	_test_wiring(together)
	_test_changes()
	_test_per_peer()
	_test_hooks()
	_test_dirty()
	_test_hold()
	yield(_test_flush(), "completed")
	_test_resync()
	yield(_test_resync_after_modules(), "completed")
	_test_inactive()
	_test_pending()
	_test_revisions()
	_test_timeout()
	_test_clear()
	_test_apply_order()
	_test_malformed()
	_test_broken_handler()
	_test_lobby_left()
	_test_round_trip()
	_measure_idle()
	for node in _nodes:
		node.free()
	_nodes.clear()


func _stream(host: bool, ready_peers: Array) -> Node:
	var session := FakeSession.new()
	session.transport = FakeTransport.new()
	session.transport.host_id = HOST
	session.host = host
	for peer in ready_peers:
		session.peers[peer] = {"ready": true}
	var stream: Node = StateStream.new()
	stream.setup(session)
	_nodes.append(stream)
	_nodes.append(session)
	return stream


func _probe(key := "", body = null) -> Probe:
	var probe := Probe.new()
	probe.key = key
	probe.body = body
	return probe


# What the host sent since the last call, as [steam_id, [section, revision, body]].
func _take(stream: Node) -> Array:
	var messages := []
	for sent in stream.session.sent:
		if sent[1] == Protocol.Msg.STATE:
			messages.append([sent[0], sent[2]])
	stream.session.sent.clear()
	return messages


# Dictionaries compare by reference in Godot 3.
func _same(a, b) -> bool:
	return var2str(a) == var2str(b)


func _test_wiring(together: Node) -> void:
	var stream: Node = together.state_stream
	t._check(
		stream != null and stream.name == "StateStream"
		and stream.get_index() < together.input_sync.get_index(),
		"the mod's state stream comes before the sync modules"
	)
	var missing := []
	for module in [
		together.shop_sync, together.upgrades_sync, together.menu_sync, together.retry_sync,
		together.pickup_list,
		together.focus_sync, together.pause_control, together.battle_host, together.battle_client
	]:
		if module.state_stream != stream:
			missing.append(module.name)
	t._check(missing.empty(), "every state module has the stream (missing: %s)" % [missing])
	var heavy := []
	for section in stream._providers:
		if stream._providers[section].heavy:
			heavy.append(section)
	heavy.sort()
	t._check(
		heavy == [StateStream.RUN_SHOP, StateStream.UPGRADES],
		"shop and upgrades are the heavy sections: %s" % [heavy]
	)
	t._check(Protocol.Msg.STATE == Protocol.Msg.size() - 1, "STATE is the last message")


func _test_changes() -> void:
	var stream := _stream(true, [P1])
	var probe := _probe("a", {"x": 1})
	stream.register_provider(StateStream.RUN_SHOP, probe, 0.1)
	stream.step(0.0)
	var sent := _take(stream)
	t._check(_same(sent, [[P1, [0, 1, {"x": 1}]]]), "first check sends the section: %s" % [sent])
	stream.step(0.05)
	t._check(_take(stream).empty(), "unchanged key: nothing sent")
	probe.key = "b"
	probe.body = {"x": 2}
	stream.step(0.04)
	t._check(_take(stream).empty(), "a change waits for the interval")
	stream.step(0.02)
	sent = _take(stream)
	t._check(_same(sent, [[P1, [0, 2, {"x": 2}]]]), "change sent at the next check, rev 2")
	stream.step(0.5)
	stream.step(0.5)
	t._check(_take(stream).empty() and probe.builds == 2, "body built on change only")
	stream.session.host = false
	probe.key = "c"
	stream.step(1.0)
	t._check(_take(stream).empty() and probe.builds == 2, "nothing while not host")


func _test_per_peer() -> void:
	var stream := _stream(true, [P1, P2])
	stream.session.peers[P3] = {"ready": false}
	var probe := _probe("m", {"kind": "menu"})
	probe.patches = {P1: {"you": 0}, P2: {"you": 1}}
	stream.register_provider(StateStream.MENU, probe)
	stream.step(0.0)
	var sent := _take(stream)
	var expected := [
		[P1, [StateStream.MENU, 1, {"kind": "menu", "you": 0}]],
		[P2, [StateStream.MENU, 1, {"kind": "menu", "you": 1}]],
	]
	t._check(_same(sent, expected), "per-peer patch, not-ready peer skipped: %s" % [sent])
	t._check(
		probe.builds == 1 and not probe.body.has("you"), "shared body built once, left untouched"
	)


# state_sent: once per peer, right after its send (sync/run_parts.gd records what the peer
# has); not for a body message_for builds. accept_state: every body that is not stale as it
# arrives, before it is pending (also one a newer body replaces before it is applied), never a
# stale one or a null.
func _test_hooks() -> void:
	var stream := _stream(true, [P1, P2])
	var hooked := Hooked.new()
	hooked.stream = stream
	hooked.key = "a"
	hooked.body = {"x": 1}
	stream.register_provider(StateStream.RUN_SHOP, hooked, 0.1)
	stream.message_for(StateStream.RUN_SHOP, P1)
	t._check(hooked.events.empty(), "state_sent: not for a body message_for builds")
	stream.step(0.0)
	var expected := [["sent", 0, P1, 1], ["sent", 0, P2, 2]]
	t._check(
		_same(hooked.events, expected), "state_sent: per peer after its send: %s" % [hooked.events]
	)
	stream.step(1.0)
	t._check(hooked.events.size() == 2, "state_sent: nothing sent, nothing called")
	var client := _stream(false, [])
	var handler := Hooked.new()
	handler.stream = client
	handler.accept = false
	client.register_handler(StateStream.UPGRADES, handler)
	client.receive([StateStream.UPGRADES, 1, {"v": 1}])
	client.receive([StateStream.UPGRADES, 2, {"v": 2}])
	client.receive([StateStream.UPGRADES, 1, {"v": 0}])  # stale
	handler.accept = true
	client.step(0.016)
	client.receive([StateStream.UPGRADES, 3, null])
	expected = [
		["accept", 1, {"v": 1}, 1, false],
		["accept", 1, {"v": 2}, 2, true],  # the first one is pending, this one not yet
		["apply", 1, {"v": 2}, 2],
	]
	t._check(
		_same(handler.events, expected),
		"accept_state: each body as it arrives, the replaced one too: %s" % [handler.events]
	)


func _test_dirty() -> void:
	var stream := _stream(true, [P1, P2])
	var probe := _probe("u", {"v": 1})
	stream.register_provider(StateStream.UPGRADES, probe, 0.1)
	stream.step(0.0)
	_take(stream)
	stream.mark_dirty(StateStream.UPGRADES, P2)
	stream.step(0.05)
	t._check(_take(stream).empty(), "dirty waits for the next check")
	stream.step(0.06)
	var sent := _take(stream)
	t._check(_same(sent, [[P2, [1, 1, {"v": 1}]]]), "dirty for one peer: only it, same rev")
	stream.mark_dirty(StateStream.UPGRADES)
	stream.step(0.11)
	sent = _take(stream)
	t._check(sent.size() == 2 and sent[0][1][1] == 1, "dirty for all: every ready peer")


# Heavy sections (shop, upgrades) wait while Steam's send queue to a peer is over HOLD_BYTES:
# that peer stays dirty and later gets the then-current revision in one message, the others get
# every change. Never held: a null body, a light section, a peer held for MAX_HOLD_MSEC, a peer
# Steam has no numbers for. A resync target is held the same way; the holds are logged per peer
# when the section turns inactive. state_sent only for the peers sent to.
func _test_hold() -> void:
	var stream := _stream(true, [P1, P2])
	var statuses: Dictionary = stream.session.transport.statuses
	var over := {"pending_reliable": StateStream.HOLD_BYTES + 1}
	var shop := Hooked.new()
	shop.stream = stream
	shop.key = "a"
	shop.body = {"x": 1}
	stream.register_provider(StateStream.RUN_SHOP, shop, 0.1, true)
	var menu := _probe("m", {"m": 1})
	stream.register_provider(StateStream.MENU, menu, 0.1)
	stream.step(0.0)
	_take(stream)
	shop.events.clear()
	statuses[P1] = over
	for x in [2, 3, 4]:
		shop.key = str(x)
		shop.body = {"x": x}
		stream.step(0.1)
	var sent := _take(stream)
	var expected := [
		[P2, [StateStream.RUN_SHOP, 2, {"x": 2}]],
		[P2, [StateStream.RUN_SHOP, 3, {"x": 3}]],
		[P2, [StateStream.RUN_SHOP, 4, {"x": 4}]],
	]
	t._check(
		_same(sent, expected),
		"hold: three changes over the limit go to the other peer only: %s" % [sent]
	)
	var sent_to := []
	for event in shop.events:
		sent_to.append(event[2])
	t._check(sent_to == [P2, P2, P2], "hold: state_sent only for the peer sent to: %s" % [sent_to])
	t._check(
		stream._providers[StateStream.RUN_SHOP].dirty.has(P1), "hold: the held peer stays dirty"
	)
	menu.key = "n"
	stream.step(0.1)
	sent = _take(stream)
	t._check(
		_same(sent, [[P1, [StateStream.MENU, 2, {"m": 1}]], [P2, [StateStream.MENU, 2, {"m": 1}]]]),
		"hold: a light section is never held: %s" % [sent]
	)
	statuses[P1] = {"pending_reliable": StateStream.HOLD_BYTES}
	stream.step(0.1)
	sent = _take(stream)
	t._check(
		_same(sent, [[P1, [StateStream.RUN_SHOP, 4, {"x": 4}]]]),
		"hold: under the limit, one message with the latest revision: %s" % [sent]
	)
	stream.step(0.1)
	t._check(_take(stream).empty(), "hold: then nothing more")

	statuses[P1] = over
	shop.key = "5"
	stream.step(0.1)
	_take(stream)
	stream._providers[StateStream.RUN_SHOP].holds[P1] -= StateStream.MAX_HOLD_MSEC
	stream.step(0.1)
	sent = _take(stream)
	t._check(
		sent.size() == 1 and sent[0][0] == P1 and sent[0][1][1] == 5,
		"hold: sent anyway after MAX_HOLD_MSEC: %s" % [sent]
	)
	shop.key = "6"
	stream.step(0.1)
	_take(stream)
	shop.key = ""
	stream.step(0.1)
	sent = _take(stream)
	t._check(
		_same(sent, [[P1, [StateStream.RUN_SHOP, 7, null]], [P2, [StateStream.RUN_SHOP, 7, null]]]),
		"hold: a null body is not held: %s" % [sent]
	)
	var lines: Array = stream.hold_lines
	t._check(
		(
			lines.size() == 1
			and lines[0].begins_with("Shop state held 3 times for %d, longest " % P1)
			and lines[0].ends_with(" ms (Steam's queue over 24 KB)")
			and stream._providers[StateStream.RUN_SHOP].held.empty()
		),
		"hold: one line per held client when the screen closes: %s" % [lines]
	)

	statuses[P1] = {}
	shop.key = "8"
	stream.step(0.1)
	sent = _take(stream)
	t._check(sent.size() == 2, "hold: no status from Steam, no hold: %s" % [sent])
	statuses[P1] = over
	stream.session.emit_signal("peer_ready", P1)
	stream.step(0.0)
	sent = _take(stream)
	t._check(
		(
			_same(sent, [[P1, [StateStream.MENU, 2, {"m": 1}]]])
			and stream._providers[StateStream.RUN_SHOP].dirty.has(P1)
		),
		"hold: a resync target is held the same way: %s" % [sent]
	)


func _test_flush():
	var stream := _stream(true, [P1])
	var probe := _probe("a", {"x": 1})
	stream.register_provider(StateStream.RUN_SHOP, probe, 10.0)
	stream.step(0.0)
	_take(stream)
	probe.key = "b"
	stream.flush(StateStream.RUN_SHOP)
	stream.step(0.0)
	t._check(_take(stream).empty(), "flush waits for the next idle frame")
	yield(t.get_tree(), "idle_frame")
	stream.step(0.0)
	var sent := _take(stream)
	t._check(sent.size() == 1 and sent[0][1][1] == 2, "flush checks in the next frame: %s" % [sent])
	stream.step(0.0)
	t._check(_take(stream).empty(), "flush done: back to the interval")


func _test_resync() -> void:
	var stream := _stream(true, [P1])
	var probes := {}
	var keys := {
		StateStream.CURSORS: "c",
		StateStream.PAUSE_SHOP: "",
		StateStream.MENU_GRIDS: "g",
		StateStream.MENU: "m",
		StateStream.RUN_SHOP: "s",
	}
	for section in keys:  # registered out of order on purpose
		probes[section] = _probe(keys[section], {"s": section})
		stream.register_provider(section, probes[section])
	stream.step(0.0)
	probes[StateStream.MENU_GRIDS].key = ""
	stream.step(1.0)
	_take(stream)
	stream.session.peers[P2] = {"ready": true}
	stream.session.emit_signal("peer_ready", P2)
	t._check(_take(stream).empty(), "peer_ready: the resync waits for the next step")
	stream.step(0.0)
	var sent := _take(stream)
	var expected := [
		[P2, [StateStream.RUN_SHOP, 1, {"s": StateStream.RUN_SHOP}]],
		[P2, [StateStream.MENU, 1, {"s": StateStream.MENU}]],
		[P2, [StateStream.MENU_GRIDS, 2, null]],
		[P2, [StateStream.CURSORS, 1, {"s": StateStream.CURSORS}]],
	]
	t._check(_same(sent, expected), "peer_ready: every section again, in order: %s" % [sent])
	probes[StateStream.MENU].key = "m2"
	stream.session.emit_signal("peer_ready", P2)
	stream.session.emit_signal("peer_ready", P2)  # twice before the step: one resync
	stream.step(0.0)
	sent = _take(stream)
	var to_p1 := []
	for message in sent:
		if message[0] == P1:
			to_p1.append(message[1])
	t._check(
		sent.size() == 5 and _same(to_p1, [[StateStream.MENU, 2, {"s": StateStream.MENU}]]),
		"a change found on peer_ready goes to everyone"
	)


# Every message to steam_id the session kept, as [msg_type, section or -1]. Clears nothing.
func _sent_to(stream: Node, steam_id: int) -> Array:
	var messages := []
	for sent in stream.session.sent:
		if sent[0] == steam_id:
			messages.append([sent[1], sent[2][0] if sent[1] == Protocol.Msg.STATE else -1])
	return messages


# The resync comes after what another peer_ready handler sends (BATTLE_START here), even one
# connected after the stream, and before any interval check: a key change and a mark_dirty in
# between reach the new peer in section order with the rest. A held section holds the resync
# (one real frame: flush is frame based); lobby_left drops a queued one.
func _test_resync_after_modules():
	var stream := _stream(true, [P1])
	var shop := _probe("s", {"s": 0})
	var pause := _probe("p", {"p": 0})
	stream.register_provider(StateStream.PAUSE_BATTLE, pause)
	stream.register_provider(StateStream.RUN_SHOP, shop, 10.0)
	var joiner := Joiner.new()
	joiner.session = stream.session
	stream.session.connect("peer_ready", joiner, "_on_peer_ready")
	stream.step(0.0)
	_take(stream)
	var start := [Protocol.Msg.BATTLE_START, -1]
	var in_order := [
		start, [Protocol.Msg.STATE, StateStream.RUN_SHOP],
		[Protocol.Msg.STATE, StateStream.PAUSE_BATTLE]
	]
	stream.session.peers[P2] = {"ready": true}
	stream.session.emit_signal("peer_ready", P2)
	t._check(_same(_sent_to(stream, P2), [start]), "peer_ready: the module's message, no state")
	pause.key = "p2"
	stream.mark_dirty(StateStream.RUN_SHOP)
	stream.step(1.0)
	var to_p2 := _sent_to(stream, P2)
	t._check(_same(to_p2, in_order), "BATTLE_START first, then the sections in order: %s" % [to_p2])
	var others := _take(stream)
	var pause_rev := -1
	for message in others:
		if message[0] == P1 and message[1][0] == StateStream.PAUSE_BATTLE:
			pause_rev = message[1][1]
	t._check(
		_sections(others, P1) == [StateStream.RUN_SHOP, StateStream.PAUSE_BATTLE] and pause_rev == 2,
		"the change and the dirty mark in between go to the others once: %s" % [others]
	)
	stream.session.peers[P3] = {"ready": true}
	stream.flush(StateStream.RUN_SHOP, true)
	stream.session.emit_signal("peer_ready", P3)
	stream.step(1.0)
	t._check(_same(_sent_to(stream, P3), [start]), "a held section holds the resync")
	yield(t.get_tree(), "idle_frame")
	stream.step(0.0)
	var to_p3 := _sent_to(stream, P3)
	t._check(_same(to_p3, in_order), "and it goes out the frame after, in order: %s" % [to_p3])
	_take(stream)
	stream.session.emit_signal("peer_ready", P3)
	stream.session.transport.emit_signal("lobby_left")
	t._check(stream._resyncs.empty(), "lobby_left drops a queued resync")


static func _sections(messages: Array, steam_id: int) -> Array:
	var sections := []
	for message in messages:
		if message[0] == steam_id:
			sections.append(message[1][0])
	return sections


func _test_inactive() -> void:
	var stream := _stream(true, [P1])
	var probe := _probe("r", {"visible": true})
	stream.register_provider(StateStream.RETRY, probe)
	stream.step(0.0)
	_take(stream)
	probe.key = ""
	stream.step(1.0)
	var sent := _take(stream)
	t._check(_same(sent, [[P1, [StateStream.RETRY, 2, null]]]), "inactive: null once, rev 2")
	stream.step(1.0)
	t._check(_take(stream).empty() and probe.builds == 1, "still inactive: nothing more")
	var never := _probe("")
	stream.register_provider(StateStream.PAUSE_BATTLE, never)
	stream.mark_dirty(StateStream.PAUSE_BATTLE)
	stream.step(1.0)
	t._check(_take(stream).empty(), "never active: no null")


func _test_pending() -> void:
	var stream := _stream(false, [])
	var probe := _probe()
	probe.accept = false
	stream.register_handler(StateStream.RUN_SHOP, probe)
	stream.receive([StateStream.RUN_SHOP, 1, {"a": 1}])
	t._check(
		probe.tries == 1 and stream.is_pending(StateStream.RUN_SHOP), "not ready: tried, pending"
	)
	stream.step(0.016)
	t._check(probe.tries == 2 and probe.applied.empty(), "pending: retried every frame")
	probe.accept = true
	stream.step(0.016)
	t._check(
		_same(probe.applied, [[0, {"a": 1}, 1]]) and not stream.is_pending(StateStream.RUN_SHOP),
		"applied once the handler accepts"
	)
	stream.step(0.016)
	t._check(probe.tries == 3, "applied: no more tries")
	probe.accept = false
	stream.receive([StateStream.RUN_SHOP, 2, {"a": 2}])
	probe.accept = true
	stream.retry()
	t._check(
		probe.applied.size() == 2 and not stream.is_pending(StateStream.RUN_SHOP),
		"retry() from outside the frame loop"
	)


func _test_revisions() -> void:
	var stream := _stream(false, [])
	var probe := _probe()
	probe.accept = false
	stream.register_handler(StateStream.UPGRADES, probe)
	stream.receive([StateStream.UPGRADES, 3, {"v": 3}])
	stream.receive([StateStream.UPGRADES, 4, {"v": 4}])
	probe.accept = true
	stream.step(0.016)
	t._check(_same(probe.applied, [[1, {"v": 4}, 4]]), "superseded while pending: latest only")
	var tries := probe.tries
	stream.receive([StateStream.UPGRADES, 2, {"v": 2}])
	t._check(probe.tries == tries and probe.applied.size() == 1, "lower revision dropped")
	stream.receive([StateStream.UPGRADES, 4, {"v": 4}])
	t._check(probe.applied.size() == 2, "equal revision applied again (resync)")


func _test_timeout() -> void:
	var stream := _stream(false, [])
	var short := _probe()
	var long := _probe()
	short.accept = false
	long.accept = false
	stream.register_handler(StateStream.RETRY, short, 0.05)
	stream.register_handler(StateStream.CURSORS, long)
	stream.receive([StateStream.RETRY, 1, {}])
	stream.receive([StateStream.CURSORS, 1, {}])
	OS.delay_msec(80)
	stream.step(0.016)
	var tries := short.tries
	stream.step(0.016)
	t._check(
		not stream.is_pending(StateStream.RETRY) and short.tries == tries,
		"timed out: dropped, no more tries"
	)
	t._check(stream.is_pending(StateStream.CURSORS), "timeout is per section")


func _test_clear() -> void:
	var stream := _stream(false, [])
	var probe := _probe()
	var plain := Plain.new()
	stream.register_handler(StateStream.PAUSE_SHOP, probe)
	stream.register_handler(StateStream.PAUSE_BATTLE, probe)
	stream.register_handler(StateStream.RETRY, plain)
	stream.receive([StateStream.PAUSE_SHOP, 1, {"paused": true}])
	stream.receive([StateStream.PAUSE_SHOP, 2, null])
	t._check(_same(probe.cleared, [StateStream.PAUSE_SHOP]), "null body: clear handler")
	probe.accept = false
	stream.receive([StateStream.PAUSE_SHOP, 3, {"paused": true}])
	stream.receive([StateStream.PAUSE_SHOP, 4, null])
	t._check(
		not stream.is_pending(StateStream.PAUSE_SHOP) and probe.cleared.size() == 2,
		"null drops a pending state"
	)
	stream.receive([StateStream.PAUSE_SHOP, 5, null])
	stream.receive([StateStream.PAUSE_BATTLE, 1, null])
	t._check(probe.cleared.size() == 2, "nothing to clear: no clear call")
	stream.receive([StateStream.RETRY, 1, {}])
	stream.receive([StateStream.RETRY, 2, null])
	t._check(plain.tries == 1, "a handler without clear_state is fine")


func _test_apply_order() -> void:
	var stream := _stream(false, [])
	var order := []
	var probes := []
	for section in [StateStream.CURSORS, StateStream.MENU, StateStream.RUN_SHOP]:
		var probe := _probe()
		probe.accept = false
		probe.order = order
		probes.append(probe)
		stream.register_handler(section, probe)
		stream.receive([section, 1, {}])
	for probe in probes:
		probe.accept = true
	stream.step(0.016)
	t._check(
		_same(order, [StateStream.RUN_SHOP, StateStream.MENU, StateStream.CURSORS]),
		"pending sections apply in section order: %s" % [order]
	)


func _test_malformed() -> void:
	var stream := _stream(false, [])
	var probe := _probe()
	stream.register_handler(StateStream.MENU, probe)
	var bad := [
		null,
		"state",
		[],
		[StateStream.MENU, 1],
		[StateStream.MENU, 1, {}, 0],
		["2", 1, {}],
		[StateStream.MENU, "1", {}],
		[StateStream.MENU, 1.0, {}],
		[StateStream.MENU, -1, {}],
		[99, 1, {}],
		[-1, 1, {}],
		[StateStream.RUN_SHOP, 1, {}],  # nobody handles it
	]
	for message in bad:
		stream.receive(message)
	t._check(probe.tries == 0, "malformed STATE messages ignored")
	var session: Node = stream.session
	session.emit_signal("message", P1, Protocol.Msg.STATE, [StateStream.MENU, 1, {}])
	session.emit_signal("message", HOST, Protocol.Msg.SHOP_FOCUS, [StateStream.MENU, 1, {}])
	t._check(probe.tries == 0, "only STATE from the host")
	session.host = true
	session.emit_signal("message", HOST, Protocol.Msg.STATE, [StateStream.MENU, 1, {}])
	t._check(probe.tries == 0, "not applied while host")
	session.host = false
	session.emit_signal("message", HOST, Protocol.Msg.STATE, [StateStream.MENU, 1, {}])
	t._check(probe.applied.size() == 1, "STATE from the host applied")


func _test_broken_handler() -> void:
	var stream := _stream(false, [])
	var broken := _probe()
	var wrong := _probe()
	var good := _probe()
	broken.answer = 0  # not a bool, like null from a script error
	wrong.answer = "yes"
	good.accept = false
	stream.register_handler(StateStream.MENU, broken)
	stream.register_handler(StateStream.MENU_GRIDS, wrong)
	stream.register_handler(StateStream.CURSORS, good)
	stream.receive([StateStream.CURSORS, 1, {}])
	stream.receive([StateStream.MENU, 1, {}])
	stream.receive([StateStream.MENU_GRIDS, 1, {}])
	good.accept = true
	stream.step(0.016)
	t._check(
		good.applied.size() == 1
		and not stream.is_pending(StateStream.MENU)
		and not stream.is_pending(StateStream.MENU_GRIDS)
		and broken.tries == 1
		and wrong.tries == 1,
		"handlers returning garbage: their state dropped, the others go on"
	)


func _test_lobby_left() -> void:
	var stream := _stream(false, [])
	var probe := _probe()
	stream.register_handler(StateStream.RETRY, probe)
	stream.receive([StateStream.RETRY, 5, {}])
	probe.accept = false
	stream.receive([StateStream.RETRY, 6, {}])
	stream.session.transport.emit_signal("lobby_left")
	t._check(not stream.is_pending(StateStream.RETRY), "lobby_left drops pending states")
	probe.accept = true
	stream.receive([StateStream.RETRY, 1, {}])
	t._check(probe.applied.size() == 2, "lobby_left forgets revisions")
	stream.receive([StateStream.RETRY, 2, null])
	t._check(probe.cleared.size() == 1, "state after lobby_left can be cleared")

	var host := _stream(true, [P1])
	var shop := _probe("a", {})
	host.register_provider(StateStream.RUN_SHOP, shop)
	host.step(0.0)
	shop.key = "b"
	host.step(1.0)
	_take(host)
	host.session.transport.emit_signal("lobby_left")
	host.step(0.0)
	var sent := _take(host)
	t._check(sent.size() == 1 and sent[0][1][1] == 1, "host: lobby_left starts the section over")


func _test_round_trip() -> void:
	var host := _stream(true, [])
	var client := _stream(false, [])
	var provider := _probe("m", {"kind": "menu"})
	provider.patches = {P1: {"you": 1}}
	host.register_provider(StateStream.MENU, provider)
	var handler := _probe()
	client.register_handler(StateStream.MENU, handler)
	client.receive(bytes2var(var2bytes(host.message_for(StateStream.MENU, P1)), false))
	t._check(
		_same(handler.applied, [[StateStream.MENU, {"kind": "menu", "you": 1}, 0]]),
		"message_for -> receive in one process: %s" % [handler.applied]
	)
	provider.key = ""
	var message: Array = host.message_for(StateStream.MENU, P1)
	t._check(message[2] == null and _take(host).empty(), "message_for: null when inactive, no send")


func _measure_idle() -> void:
	var stream := _stream(true, [P1, P2])
	for section in StateStream.NAMES.size():
		# Half of them active (sent once, unchanged since), half inactive.
		stream.register_provider(section, _probe("k" if section % 2 == 0 else "", {}))
	stream.step(0.0)
	_take(stream)
	var started := OS.get_ticks_usec()
	for _i in IDLE_STEPS:
		stream.step(0.1)  # every section checked every step
	var usec := float(OS.get_ticks_usec() - started) / IDLE_STEPS
	var idle := _stream(true, [P1, P2])
	for section in StateStream.NAMES.size():
		idle.register_provider(section, _probe())
	started = OS.get_ticks_usec()
	for _i in IDLE_STEPS:
		idle.step(0.1)
	var inactive := float(OS.get_ticks_usec() - started) / IDLE_STEPS
	t._check(_take(stream).empty() and _take(idle).empty(), "idle steps send nothing")
	var line := "  info: state stream idle frame, %d sections checked: %.2f us all inactive, "
	line += "%.2f us half active and unchanged"
	print(line % [StateStream.NAMES.size(), inactive, usec])
