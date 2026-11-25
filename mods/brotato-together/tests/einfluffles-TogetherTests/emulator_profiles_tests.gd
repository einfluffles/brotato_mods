extends Reference
# Suite emulator_profiles: the local-play emulator's link profiles (dev/einfluffles-TogetherLocal:
# link_profiles.gd, link.gd) on the memory wire: each profile's ping, per direction impairment
# (delay queue, loss, retransmits, the line's rate, stalls, relay POP changes), lobby traffic
# after the latency, quality and rates, switching at run time and forced failures (the director's
# link commands that switch and force them: director_tests.gd). Then the acceptance: a real
# Transport and Session per player under "bad" log the path, "Slow answer", traffic and gap lines,
# and a failed reliable send runs a full resync; under "lan" none of these lines appear. The
# emulators' clock moves only when a test steps it; the diagnostics part keeps real time at or
# behind it (the mod's Session times with OS.get_ticks_msec), so a line that needs a delay is
# certain and "lan" stays far below every threshold.

const SteamEmulator := preload("res://mods-unpacked/einfluffles-TogetherLocal/steam_emulator.gd")
const WireMemory := preload("res://mods-unpacked/einfluffles-TogetherLocal/wire_memory.gd")
const LinkProfiles := preload("res://mods-unpacked/einfluffles-TogetherLocal/link_profiles.gd")
const LinkWatch := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/link_watch.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StreamGaps := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/stream_gaps.gd")
const DlcBorrow := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/dlc_borrow.gd")
const TransportTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/emulator_transport_tests.gd"
)
const RELIABLE := 8 | 32  # the flags Transport.send sets
const UNRELIABLE := 1 | 32
const STEP_MSEC := 5
# Ping (both ways) per profile on a relayed session, both sides on the profile
const PINGS := {"lan": 2, "relay-good": 26, "relay-typical": 40, "bad": 200, "stall": 16}
const LOG_NAME := "einfluffles-TogetherTests:Profiles"
const RUN_MSEC := 3000  # the diagnostics scenario
const STATE_BYTES := 30000  # a shop purchase's run state per client (Measurements: 30.4 KB)
const SNAPSHOT_BYTES := 1500  # a crowded wave's snapshot (Measurements: 1.5 KB, 43 KB/s)

var _t: Node
var _wire = null
var _sides := []
var _holder: Node = null
var _gaps = null


func _init(test_mod: Node) -> void:
	_t = test_mod


func run() -> void:
	_test_profiles()
	_test_directions()
	_test_stall_profile()
	_test_line_and_quality()
	_test_lobby_latency()
	_test_switching()
	_test_failures()
	var bad := _diagnostics("bad")
	var lan := _diagnostics("lan")
	_t._check(
		(
			bad.ready
			and bad.path
			and bad.slow
			and bad.burst
			and bad.backlog
			and bad.gap
			and bad.resync
		),
		"emulator_profiles: under bad the host logs a path change, Slow answer, traffic and gap"
		+ " lines, and a failed reliable send runs a full resync (%s)" % [bad]
	)
	_t._check(
		(
			lan.ready
			and lan.lines == 0
			and lan.slow_answers == 0
			and lan.traffic == 0
			and lan.gaps == 0
			and lan.resync
		),
		"emulator_profiles: under lan no path, Slow answer, traffic or gap line; a failed reliable"
		+ " send still resyncs (%s)" % [lan]
	)


# A wire with emulators 1..count, relay-only (as the transport sets it), each on profile.
static func _setup(count: int, profile := "") -> Array:
	var wire = WireMemory.new()
	var list := [wire]
	for number in range(1, count + 1):
		var emulator = SteamEmulator.new(number, "P%d" % number)
		wire.add(emulator)
		emulator.setGlobalConfigValueInt32(emulator._config_ice, 0)
		if profile != "":
			emulator.set_profile(profile)
		list.append(emulator)
	return list


static func _run(wire, msec: int, step := STEP_MSEC) -> void:
	for _i in range(msec / step):
		wire.step(step)


static func _bytes(size: int, value := 0) -> PoolByteArray:
	var data := PoolByteArray()
	data.resize(size)
	for i in range(int(min(size, 4))):
		data[i] = (value >> (8 * i)) & 0xFF
	return data


static func _numbers(messages: Array) -> Array:
	var numbers := []
	for message in messages:
		var data: PoolByteArray = message.payload
		numbers.append(data[0] | (data[1] << 8))
	return numbers


# Both sides send once and accept, then wait out the link, so the session is up both ways.
static func _connect(wire, a, b) -> void:
	a.sendMessageToUser(b.steam_id, _bytes(4), RELIABLE, 0)
	_run(wire, 1000)
	b.acceptSessionWithUser(a.steam_id)
	b.sendMessageToUser(a.steam_id, _bytes(4), RELIABLE, 0)
	_run(wire, 1000)
	for emulator in [a, b]:
		emulator.receiveMessagesOnChannel(0, 100)


func _test_profiles() -> void:
	var wrong := []
	for name in LinkProfiles.NAMES:
		var s := _setup(2, name)
		_connect(s[0], s[1], s[2])
		var ping: int = s[1].getSessionConnectionInfo(s[2].steam_id, false, true).ping
		if ping != PINGS[name] or s[1].link.profile != name:
			wrong.append([name, ping, s[1].link.profile])
	var e = SteamEmulator.new(1)
	var refused: bool = not e.set_profile("dial-up") and e.link.profile == ""
	_t._check(
		(
			wrong.empty()
			and LinkProfiles.NAMES.size() == LinkProfiles.PROFILES.size()
			and refused
			and e.set_profile("bad")
			and e.set_profile("none")
			and e.link.settings.latency_msec == 0
		),
		"emulator_profiles: every profile's Steam ping (lan 2, relay-good 26, relay-typical 40, bad"
		+ " 200, stall 16 ms); an unknown name changes nothing, none clears (%s)" % [wrong]
	)


# Each side's profile is what it sends: bad one way, lan the other.
func _test_directions() -> void:
	var s := _setup(2)
	var a = s[1]
	var b = s[2]
	a.set_profile("bad")
	b.set_profile("lan")
	_connect(s[0], a, b)
	a.set_link({"loss": 0.0})  # this one message must not be the lost one
	a.sendMessageToUser(b.steam_id, _bytes(8, 1), UNRELIABLE, 1)
	b.sendMessageToUser(a.steam_id, _bytes(8, 2), UNRELIABLE, 1)
	_run(s[0], 10)
	var fast: int = a.receiveMessagesOnChannel(1, 10).size()
	var slow_early: int = b.receiveMessagesOnChannel(1, 10).size()
	_run(s[0], 200)
	_t._check(
		(
			fast == 1
			and slow_early == 0
			and b.receiveMessagesOnChannel(1, 10).size() == 1
			and a.getSessionConnectionInfo(b.steam_id, false, true).ping == 101
			and b.getSessionConnectionInfo(a.steam_id, false, true).ping == 101
		),
		"emulator_profiles: per direction: bad's 100 ms one way, lan's 1 ms back; Steam's ping is"
		+ " both ways (101 ms) on both sides"
	)


# The stall profile over two minutes: an unreliable 30 Hz stream shows its stalls as gaps.
func _test_stall_profile() -> void:
	var s := _setup(2, "stall")
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	_connect(wire, a, b)
	var stalls_before: int = a.link.stalls
	var last := -1
	var gaps := []
	var step := 10
	for i in range(120000 / step):
		if i % 3 == 0:
			a.sendMessageToUser(b.steam_id, _bytes(8, i), UNRELIABLE, 1)
		wire.step(step)
		if not b.receiveMessagesOnChannel(1, 10).empty():
			var now: int = wire.now_msec()
			if last >= 0 and now - last >= 300:
				gaps.append(now - last)
			last = now
	var stalls: int = a.link.stalls - stalls_before
	var longest := 0
	for gap in gaps:
		longest = int(max(longest, gap))
	_t._check(
		gaps.size() >= 3 and gaps.size() <= stalls and stalls <= 16 and longest <= 3400,
		"emulator_profiles: stall: %d stalls in 2 minutes (beat and 20 to 50 s), %d gaps of 300 ms"
		% [stalls, gaps.size()]
		+ " to 3.3 s in the stream (%s)" % [gaps]
	)


# bad's slow line backs up Steam's queue; its loss shows in the quality on both ends; rates.
func _test_line_and_quality() -> void:
	var s := _setup(2, "bad")
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	_connect(wire, a, b)
	a.link.settings.stalls = []
	a.link._restart_schedule()
	for i in 10:
		a.sendMessageToUser(b.steam_id, _bytes(10000, i), RELIABLE, 0)
	wire.step(0)
	var info: Dictionary = a.getSessionConnectionInfo(b.steam_id, false, true)
	_run(wire, 1000)
	var first_second: int = b.receiveMessagesOnChannel(0, 100).size()
	_run(wire, 2000)
	var after_two: int = first_second + b.receiveMessagesOnChannel(0, 100).size()
	_t._check(
		(
			info.send_rate == SteamEmulator.STEAM_SEND_RATE
			and info.queue_time > 1400000
			and first_second >= 5
			and first_second <= 7
			and after_two == 10
		),
		"emulator_profiles: bad's line carries 64 KB/s: Steam's queue waits 1.5 s for 100 KB, its"
		+ " send rate unchanged (queue %d us, %d in the first second)"
		% [info.queue_time, first_second]
	)
	for i in 1200:
		a.sendMessageToUser(b.steam_id, _bytes(100, i), UNRELIABLE, 1)
		if i % 10 == 0:
			wire.step(STEP_MSEC)
	_run(wire, 2500)
	b.receiveMessagesOnChannel(1, 2000)
	a.set_link({"loss": 0.0})  # the message that carries the quality arrives
	a.sendMessageToUser(b.steam_id, _bytes(100), UNRELIABLE, 1)
	_run(wire, 300)
	var out: Dictionary = a.getSessionConnectionInfo(b.steam_id, false, true)
	var seen: Dictionary = b.getSessionConnectionInfo(a.steam_id, false, true)
	_t._check(
		(
			a.dropped_count >= 15
			and a.dropped_count <= 60
			and out.remote_quality > 0.9
			and out.remote_quality < 1.0
			and abs(seen.local_quality - out.remote_quality) < 0.005
		),
		"emulator_profiles: 3 %% loss: %d of 1200 dropped, remote quality %.3f here is the peer's"
		% [a.dropped_count, out.remote_quality]
		+ " local quality %.3f" % seen.local_quality
	)
	var r := _setup(2, "lan")
	_connect(r[0], r[1], r[2])
	for i in 150:
		r[1].sendMessageToUser(r[2].steam_id, _bytes(1000, i), UNRELIABLE, 1)
		_run(r[0], 10)
	var rates: Dictionary = r[1].getSessionConnectionInfo(r[2].steam_id, false, true)
	var back: Dictionary = r[2].getSessionConnectionInfo(r[1].steam_id, false, true)
	_t._check(
		(
			abs(rates.packets_out_per_second - 100.0) <= 5.0
			and abs(rates.bytes_out_per_second - 100000.0) <= 5000.0
			and abs(back.bytes_in_per_second - 100000.0) <= 5000.0
		),
		"emulator_profiles: bytes and packets per second out here and in at the peer (%s, %s)"
		% [rates.bytes_out_per_second, back.bytes_in_per_second]
	)


# Lobby traffic and session control wait for the link too.
func _test_lobby_latency() -> void:
	var s := _setup(2, "bad")
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	var joined := []
	b.connect("lobby_joined", self, "_on_lobby_joined", [joined])
	a.createLobby(1, 4)
	wire.step(0)
	var lobby_id: int = a.owned_lobby_ids()[0]
	b.joinLobby(lobby_id)
	_run(wire, 190)
	var early: int = joined.size()
	_run(wire, 20)
	var in_time: int = joined.size()
	b.joinLobby(lobby_id + (5 << 8))  # the lobby of number 6, a game the wire does not know
	_run(wire, 150)
	_t._check(
		(
			early == 0
			and in_time == 1
			and joined.size() == 2
			and joined[0] == [lobby_id, SteamEmulator.ENTER_SUCCESS]
			and joined[1][1] == SteamEmulator.ENTER_DOESNT_EXIST
		),
		"emulator_profiles: a join takes the link both ways (200 ms relayed on bad); a join nobody"
		+ " can carry still answers 'no such lobby' (%s)" % [joined]
	)


func _on_lobby_joined(lobby_id, _permissions, _locked, response, joined: Array) -> void:
	joined.append([lobby_id, response])


# A switch applies to what is sent from then on; what is on its way keeps its time and order.
func _test_switching() -> void:
	var s := _setup(2, "bad")
	var wire = s[0]
	var a = s[1]
	var b = s[2]
	_connect(wire, a, b)
	a.seed_link(1)
	a.set_link({"loss": 0.0, "jitter_msec": 0})
	a.sendMessageToUser(b.steam_id, _bytes(8, 1), RELIABLE, 0)
	wire.step(STEP_MSEC)
	var switched: bool = a.set_profile("lan")
	a.sendMessageToUser(b.steam_id, _bytes(8, 2), RELIABLE, 0)
	a.sendMessageToUser(b.steam_id, _bytes(8, 3), UNRELIABLE, 1)
	_run(wire, 10)
	var overtook: Array = _numbers(b.receiveMessagesOnChannel(1, 10))
	var reliable_early: int = b.receiveMessagesOnChannel(0, 10).size()
	_run(wire, 100)
	var reliable: Array = _numbers(b.receiveMessagesOnChannel(0, 10))
	_t._check(
		(
			switched
			and a.link.profile == "lan"
			and overtook == [3]
			and reliable_early == 0
			and reliable == [1, 2]
			and a.getSessionConnectionInfo(b.steam_id, false, true).ping == 101
		),
		"emulator_profiles: bad to lan at run time: unreliable overtakes at once, reliable waits"
		+ " for the one on its way (%s, %s)" % [overtook, reliable]
	)
	a.set_profile("bad")
	var before: String = LinkWatch.describe(a.getSessionConnectionInfo(b.steam_id, true, false))
	a.link.bring_forward(a.now_usec(), 0)
	wire.step(STEP_MSEC)
	var after: String = LinkWatch.describe(a.getSessionConnectionInfo(b.steam_id, true, false))
	_t._check(
		(
			before == "relayed via lcl"
			and after == "relayed via lcx (peer's POP lcl)"
			and a.link.pop_switches == 1
			and a.link.stalls >= 1
		),
		"emulator_profiles: bad changes the relay POP and stalls on its schedule (%s)" % after
	)


func _test_failures() -> void:
	var s := _setup(3, "lan")
	var wire = s[0]
	var a = s[1]
	_connect(wire, a, s[2])
	_connect(wire, a, s[3])
	a.fail_next_sends(1)
	var refused: int = a.sendMessageToUser(s[2].steam_id, _bytes(8), RELIABLE, 0)
	var unreliable: int = a.sendMessageToUser(s[2].steam_id, _bytes(8), UNRELIABLE, 1)
	var next: int = a.sendMessageToUser(s[2].steam_id, _bytes(8), RELIABLE, 0)
	var failed: int = a.fail_sessions(5008, "test")
	_run(wire, 10)
	_t._check(
		(
			refused == SteamEmulator.RESULT_LIMIT_EXCEEDED
			and unreliable == SteamEmulator.RESULT_OK
			and next == SteamEmulator.RESULT_OK
			and a.refused_count == 1
			and failed == 2
			and s[2].getSessionConnectionInfo(a.steam_id, true, false).end_reason == 5008
			and s[3].getSessionConnectionInfo(a.steam_id, true, false).connection_state == 5
		),
		"emulator_profiles: a forced failed reliable send (LimitExceeded) once; every session fails"
		+ " on command at both ends"
	)


# The acceptance run on one profile: host and client with a real Transport and Session each, in
# the tree (the Session's lines name the scene). The client sends inputs, the host snapshots, four
# 30 KB states at a shop's pace and a PING every 500 ms; real time is held at or behind the
# emulators' clock.
func _diagnostics(profile: String) -> Dictionary:
	_wire = WireMemory.new()
	_holder = Node.new()
	_holder.name = "ProfileDiagnostics"
	_t.add_child(_holder)
	var tag := "einfluffles-BrotatoTogether/p%s" % Protocol.VERSION
	var host = _side(1, "Host", tag)
	var client = _side(2, "Client", tag)
	for side in _sides:
		side.emulator.set_profile(profile)
	host.transport.host_lobby()
	var start := OS.get_ticks_usec()
	var manual := 0
	var asked := false
	var ready_at := -1
	# The handshake, then a second and more for link_watch's first poll of the connected session
	for _i in 1000:
		manual = _pump_real(start, manual)
		if not asked and not host.named("lobby_ready").empty():
			asked = true
			client.transport.join_lobby(host.transport.lobby_id)
		var both: bool = client.session.is_ready_client() and host.session.peers.has(client.id)
		if ready_at < 0 and both and host.session.peers[client.id].ready:
			ready_at = manual
		if ready_at >= 0 and manual - ready_at >= 1200:
			break
	var ready: bool = ready_at >= 0
	host.transport.link_watch.lines = 0  # count what the run logs from here on
	host.session.slow_answers = 0
	host.session.traffic.lines = 0
	_gaps = StreamGaps.new("input from %s" % client.id)
	_gaps.step_msec = 1000.0 / 60.0
	_gaps.redundancy = 4
	host.session.connect("message", self, "_on_host_message")
	for side in _sides:
		side.emulator.link.bring_forward(side.emulator.now_usec(), 500)
	var backlog := ""
	var seq := 0
	for step in range(RUN_MSEC / STEP_MSEC):
		var msec := step * STEP_MSEC
		if msec % 15 == 0:
			seq += 1
			var input := [seq, 0, 0, 0, 0, 0, 0, msec]
			client.session.send_unreliable(host.id, Protocol.Msg.INPUT, input)
		if msec % 35 == 0:
			host.session.send_unreliable(client.id, Protocol.Msg.SNAPSHOT, _bytes(SNAPSHOT_BYTES))
		if msec % 500 == 0:
			host.session.send_unreliable(client.id, Protocol.Msg.PING, {"t": OS.get_ticks_msec()})
		if msec >= 1000 and msec <= 1600 and msec % 200 == 0:
			host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, step, _bytes(STATE_BYTES)])
			backlog = host.session.steam_status_text(client.id)
		manual = _pump_real(start, manual)
	var result := {
		"ready": ready,
		"lines": host.transport.link_watch.lines,
		"path_line": host.transport.link_watch.last_line,
		"slow_answers": host.session.slow_answers,
		"traffic": host.session.traffic.lines,
		"traffic_line": host.session.traffic.last_line,
		"gaps": _gaps.logged,
		"gap_line": _gaps.last_line,
	}
	result.path = result.lines >= 1 and "relayed via lcx" in result.path_line
	result.slow = result.slow_answers >= 1
	result.burst = result.traffic >= 1 and "Reliable burst" in result.traffic_line
	result.backlog = "reliable in the last 2 s" in backlog
	result.gap = (
		result.gaps >= 1
		and "No input from" in result.gap_line
		and "; Steam: ping" in result.gap_line
		and "path: relayed" in result.gap_line
	)
	result.resync = _forced_resync(host, client)
	host.session.disconnect("message", self, "_on_host_message")
	for side in _sides:
		side.free_nodes()
	_sides.clear()
	_holder.free()
	_holder = null
	DlcBorrow.revert()
	return result


func _side(number: int, persona: String, tag: String):
	var side = TransportTests.Side.new(_wire, number, persona, tag)
	_holder.add_child(side.transport)
	_holder.add_child(side.session)
	_sides.append(side)
	return side


# One step of the emulators' clock, each transport reads, then real time catches up with it.
func _pump_real(start_usec: int, manual_msec: int) -> int:
	_wire.step(STEP_MSEC)
	for side in _sides:
		if side.bound:
			side.transport._process(0.0)
	manual_msec += STEP_MSEC
	while OS.get_ticks_usec() - start_usec < manual_msec * 1000:
		OS.delay_usec(250)
	return manual_msec


func _on_host_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type == Protocol.Msg.INPUT and typeof(body) == TYPE_ARRAY and body.size() == 8:
		_gaps.note(_sides[0].session, steam_id, body[7], LOG_NAME, "", false, body[0])


# A reliable send the emulator refuses: the host's Session queues a full resync and runs it.
func _forced_resync(host, client) -> bool:
	host.events.clear()
	host.emulator.fail_next_sends(1)
	host.session.send_reliable(client.id, Protocol.Msg.STATE, [0, 99, null])
	var queued: bool = host.session.peers[client.id].resync
	host.session.process_resyncs(OS.get_ticks_msec() + host.session.RESYNC_INTERVAL_MSEC)
	return (
		queued
		and host.named("send_failed") == [[client.id, 0, SteamEmulator.RESULT_LIMIT_EXCEEDED]]
		and host.named("peer_ready") == [client.id]
		and not host.session.peers[client.id].resync
	)
