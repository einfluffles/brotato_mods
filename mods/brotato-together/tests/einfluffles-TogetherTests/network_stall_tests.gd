extends Reference
# Suite network_stalls: network stalls of 300 to 500 ms (seen every 20 to 50 s on a client's
# connection while Steam's own ping stayed at 25 ms).
#  - the render delay (sync/render_delay.gd): exactly the base delay on a good connection; holds
#    render time on the newest snapshot through a stall and gives the extra delay back slowly;
#    stays up under recurring lateness and comes back down once it calms; a stall too long to hold
#    leaves no extra delay behind
#  - gap log lines for snapshots and inputs (sync/stream_gaps.gd): once per gap, rate limited,
#    with the cause; the host's INPUT stream per client, which tells a client's own stall from
#    inputs held up or lost on the way (the client's clock and seq)
#  - the session's path (net/link_watch.gd): direct / relayed with the relay's POP, logged on
#    change only; a failed session is followed by when it was up again
# test_client_stall runs inside battle_loopback (a client in a real puppet battle): a 400 ms
# snapshot gap keeps the own player's prediction and holds the world instead of running past it.

const RenderDelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/render_delay.gd"
)
const StreamGaps := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/stream_gaps.gd")
const LinkWatch := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/link_watch.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PF := Snapshot.PlayerField
const BASE := 100
const FRAME_MSEC := 16
const SNAPSHOT_MSEC := 33
const LATENCY := 12  # one way, on top of which a stall comes
const PEER := 5

var _t: Node = null  # test runner: _check()


# gdlint: disable=function-name
class FakeSteam:
	extends Reference
	var infos := {}  # steam id -> getSessionConnectionInfo's answer

	func getSessionConnectionInfo(steam_id: int, _connection: bool, _status: bool) -> Dictionary:
		return infos.get(steam_id, {})


# gdlint: enable=function-name


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node) -> void:
	_test_good_network()
	_test_stall_hold()
	_test_recurring_lateness()
	_test_long_stall()
	_test_gap_lines()
	_test_gap_wiring(together)
	_test_input_gap_causes(together)
	_test_link_watch()
	_test_session_failed(together)


# --- render delay, on a simulated clock ---


# Host times of snapshots sent every SNAPSHOT_MSEC for to_msec, each arriving LATENCY (+ jitter)
# later; the ones sent during a stall [start, start + length) all arrive when it ends.
static func _arrivals(to_msec: int, stalls: Array, jitter := 0) -> Array:
	var arrivals := []
	for k in to_msec / SNAPSHOT_MSEC:
		var sent: int = k * SNAPSHOT_MSEC
		var arrival: int = sent + LATENCY + (k * 37) % (jitter + 1)
		for stall in stalls:
			if sent >= stall[0] and sent < stall[0] + stall[1]:
				arrival = int(max(arrival, stall[0] + stall[1] + LATENCY))
		arrivals.append([sent, arrival])
	return arrivals


# Plays the arrivals frame by frame through delay (the client's min-filtered clock offset as in
# BattleClient._on_snapshot) from from_msec to to_msec. Returns per frame [now, delay, render
# time, newest t], and whether render time ever went backwards.
static func _play(delay, arrivals: Array, from_msec: int, to_msec: int, state: Dictionary) -> Array:
	var frames := []
	for now in range(from_msec, to_msec, FRAME_MSEC):
		while state.k < arrivals.size() and arrivals[state.k][1] <= now:
			var sent: int = arrivals[state.k][0]
			var sample := float(arrivals[state.k][1] - sent)
			if not state.has_clock or sample < state.offset:
				state.offset = sample
				state.has_clock = true
			else:
				state.offset += 0.5  # BattleClient.CLOCK_CREEP_MSEC
			if sent > state.newest:
				state.newest = sent
			state.k += 1
		if not state.has_clock:
			continue
		var render: float = delay.render_time(now, state.offset, state.newest, FRAME_MSEC / 1000.0)
		if render < state.last_render - 0.01:
			state.backwards = true
		state.last_render = render
		frames.append([now, delay.delay_msec, render, state.newest])
	return frames


static func _new_state() -> Dictionary:
	return {
		"k": 0, "offset": 0.0, "has_clock": false, "newest": -1, "last_render": -1e9,
		"backwards": false
	}


# Frames in which render time stood still or passed the newest snapshot (the world froze).
static func _frozen(frames: Array) -> int:
	var count := 0
	for i in range(1, frames.size()):
		if frames[i][2] <= frames[i - 1][2] + 0.01 or frames[i][2] > frames[i][3]:
			count += 1
	return count


func _test_good_network() -> void:
	var delay = RenderDelay.new(BASE)
	var state := _new_state()
	var frames := _play(delay, _arrivals(10000, [], 40), 0, 10000, state)
	var exact := true
	for frame in frames:
		exact = exact and frame[1] == BASE
	_t._check(
		exact and delay.holds == 0 and _frozen(frames) == 0,
		"good connection (up to 40 ms jitter): render delay stays %d ms, never frozen" % BASE
	)


func _test_stall_hold() -> void:
	var delay = RenderDelay.new(BASE)
	var state := _new_state()
	var arrivals := _arrivals(9000, [[2000, 400]])
	var before := _play(delay, arrivals, 0, 2000, state)
	var stall := _play(delay, arrivals, 2000, 2400 + LATENCY + FRAME_MSEC, state)
	var held := true  # render time never past the newest snapshot during the stall
	for frame in stall:
		held = held and frame[2] <= frame[3] + 0.01
	var peak: float = delay.delay_msec
	var after := _play(delay, arrivals, stall[-1][0] + FRAME_MSEC, 9000, state)
	_t._check(
		held and not state.backwards and peak > 350 and peak <= RenderDelay.MAX_HOLD_MSEC,
		"a 400 ms stall holds render time on the newest snapshot (delay %d ms), never backwards" % peak
	)
	var one_second: Array = after[1000 / FRAME_MSEC]
	_t._check(
		one_second[1] > BASE + 50 and after[-1][1] == BASE and _frozen(after) == 0,
		(
			"after it the delay shrinks slowly (%d ms 1 s later) back to %d ms, without freezing"
			% [one_second[1], after[-1][1]]
		)
	)
	_t._check(before[-1][1] == BASE, "before the stall the delay was %d ms" % BASE)


func _test_recurring_lateness() -> void:
	var delay = RenderDelay.new(BASE)
	var state := _new_state()
	var stalls := []
	for start in range(1000, 5000, 600):  # a 150 ms stall every 0.6 s for 4 s, then calm
		stalls.append([start, 150])
	var arrivals := _arrivals(16000, stalls)
	var early := _play(delay, arrivals, 0, 3100, state)
	var late := _play(delay, arrivals, 3100, 5000, state)
	var calm := _play(delay, arrivals, 5000, 16000, state)
	_t._check(
		late[-1][1] >= 150 and delay.holds <= 4 and _frozen(late) == 0,
		(
			"recurring lateness: the delay stays up (%d ms), %d holds for 7 stalls, none frozen later"
			% [late[-1][1], delay.holds]
		)
	)
	_t._check(
		calm[-1][1] == BASE and not state.backwards and _frozen(calm) == 0 and early.size() > 0,
		"calm again: the delay is back at %d ms (%d ms)" % [BASE, calm[-1][1]]
	)


func _test_long_stall() -> void:
	var delay = RenderDelay.new(BASE)
	var state := _new_state()
	var arrivals := _arrivals(6000, [[2000, 1500]])
	_play(delay, arrivals, 0, 3000, state)
	var during: float = delay.delay_msec
	var after := _play(delay, arrivals, 3000, 4000, state)
	_t._check(
		during == BASE and after[-1][1] == BASE,
		(
			"a 1.5 s stall (or a pause) is not held: %d ms during, %d ms after, no lag left behind"
			% [during, after[-1][1]]
		)
	)


# --- gap lines ---


func _test_gap_lines() -> void:
	var gaps = StreamGaps.new("snapshot")
	var lines := []
	for k in 10:
		lines.append(gaps.arrived(1000 + k * SNAPSHOT_MSEC, k * SNAPSHOT_MSEC))
	lines.append(gaps.arrived(1000 + 9 * SNAPSHOT_MSEC + 150, 10 * SNAPSHOT_MSEC))
	_t._check(
		PoolStringArray(lines).join("") == "" and gaps.logged == 0,
		"no line for a steady stream or 150 ms"
	)
	var now: int = 1000 + 9 * SNAPSHOT_MSEC + 150
	var held: String = gaps.arrived(now + 420, 11 * SNAPSHOT_MSEC)
	_t._check(
		"No snapshot for 420 ms, sent 33 ms apart: held up on the way" in held and gaps.logged == 1,
		"a 420 ms gap is logged once, held up on the way: %s" % held
	)
	now += 420
	var rate_limited: String = gaps.arrived(now + 1000, 11 * SNAPSHOT_MSEC + 1000)
	var reordered: String = gaps.arrived(now + 1300, 11 * SNAPSHOT_MSEC + 500)
	_t._check(
		rate_limited == "" and reordered == "" and gaps.logged == 1,
		"the next gap within %d ms is not logged; an older message is no gap"
		% StreamGaps.LOG_INTERVAL_MSEC
	)
	now += 1000
	var next: String = gaps.arrived(now + StreamGaps.LOG_INTERVAL_MSEC, 20000)
	_t._check(
		"not sent or lost" in next and "1 more gap(s) since the last line, longest 1000 ms" in next,
		"later, the next gap counts the one left out: %s" % next
	)
	gaps.reset()
	var quiet: String = gaps.arrived(now + 20000, 40000)
	var paused: String = gaps.arrived(now + 30000, 50000, true)
	_t._check(
		quiet == "" and paused == "" and gaps.logged == 2,
		"no gap after a reset or for a quiet arrival (pause)"
	)


func _test_gap_wiring(together: Node) -> void:
	var session: Node = together.session
	var input_sync: Node = together.input_sync
	var gaps = StreamGaps.new("snapshot")
	gaps.arrived(OS.get_ticks_msec() - 300, 1000)
	var logged: bool = gaps.note(session, PEER, 1033, "test", "; render delay 300 ms")
	_t._check(
		logged and "No snapshot for 300 ms" in gaps.last_line and "render delay 300" in gaps.last_line,
		"a logged gap carries its context: %s" % gaps.last_line
	)
	# Host: a client's INPUT stream (seq = its physics steps, the last field its clock).
	var input := [60, Vector2.ZERO, Vector2.ZERO, 0, 0, 0, PoolVector2Array(), 1000]
	input_sync.note_input_gap(PEER, input)
	var tracker = input_sync._input_gaps[PEER]
	tracker._last_arrival -= 350
	input = input.duplicate()
	input[0] = 61
	input[7] = 1000 + FRAME_MSEC
	input_sync.note_input_gap(PEER, input)
	_t._check(
		tracker.logged == 1 and "No input from %s for 35" % PEER in tracker.last_line,
		"host: a stall in a client's inputs is logged: %s" % tracker.last_line
	)
	input_sync._input_gaps.erase(PEER)


# The host tells whose stall an input gap was from the client's clock and seq (sync/stream_gaps.gd).
# A client's frame that stalls at a scene change runs no physics steps meanwhile and then sends up
# to 8 at once with consecutive seqs: its own stall. Before protocol 22 the host took the send time
# from the seq and logged each of those (200 to 850 ms, at every battle start and shop entry) as
# "sent 17 ms apart: held up on the way".
func _test_input_gap_causes(together: Node) -> void:
	var input_sync: Node = together.input_sync
	var lines := {}
	for label in ["own stall", "held up", "lost"]:
		input_sync._input_gaps.erase(PEER)
		var clock := 50000
		var seq := 1
		for _k in 10:  # a steady stream first
			input_sync.note_input_gap(PEER, _input(seq, clock))
			seq += 1
			clock += FRAME_MSEC
		var tracker = input_sync._input_gaps[PEER]
		match label:
			"own stall":  # nothing sent for 650 ms, then 8 steps in one frame
				tracker._last_arrival -= 650
				clock += 650 - FRAME_MSEC
				input_sync._remote[PEER] = {"released": true}  # the timeout fired meanwhile
				for _k in 8:
					input_sync.note_input_gap(PEER, _input(seq, clock))
					seq += 1
				input_sync._remote.erase(PEER)
			"held up":  # sent at the usual pace, arriving together 400 ms late
				tracker._last_arrival -= 400
				for _k in 24:
					input_sync.note_input_gap(PEER, _input(seq, clock))
					seq += 1
					clock += FRAME_MSEC
			"lost":  # 20 sent at the usual pace and lost: the next one arrives on time
				tracker._last_arrival -= 21 * FRAME_MSEC
				seq += 20
				clock += 20 * FRAME_MSEC
				input_sync.note_input_gap(PEER, _input(seq, clock))
		lines[label] = tracker.last_line if tracker.logged == 1 else "%d lines" % tracker.logged
	_t._check(
		"sent 650 ms apart (seq +1): its game sent nothing for 650 ms (its own stall)"
		in lines["own stall"] and "; buttons released" in lines["own stall"],
		"input gap: a client that sent nothing for 650 ms stalled itself: %s" % lines["own stall"]
	)
	_t._check(
		"No input from %s for 40" % PEER in lines["held up"]
		and "sent %d ms apart (seq +1): held up on the way" % FRAME_MSEC in lines["held up"]
		and not "buttons released" in lines["held up"],
		"input gap: inputs sent evenly that arrive together were held up: %s" % lines["held up"]
	)
	_t._check(
		"(seq +21): 20 inputs lost on the way" in lines["lost"],
		"input gap: a seq jump at the usual pace means lost inputs: %s" % lines["lost"]
	)
	input_sync._input_gaps.erase(PEER)


static func _input(seq: int, clock: int) -> Array:
	return [seq, Vector2.ZERO, Vector2.ZERO, 0, 0, 0, PoolVector2Array(), clock]


# --- session path ---


func _test_link_watch() -> void:
	var fra: int = ("f".ord_at(0) << 16) | ("r".ord_at(0) << 8) | "a".ord_at(0)
	var ams: int = ("a".ord_at(0) << 16) | ("m".ord_at(0) << 8) | "s".ord_at(0)
	_t._check(LinkWatch.pop_code(fra) == "fra", "POP id -> code (%s)" % LinkWatch.pop_code(fra))
	var relayed := {"connection_state": 3, "pop_relay": fra, "remote_pop": ams, "ping": 30}
	var texts := [
		LinkWatch.describe({"connection_state": 3, "ping": 25}),
		LinkWatch.describe(relayed),
		LinkWatch.describe({"connection_state": 3, "info_flags": LinkWatch.FLAG_RELAYED}),
		LinkWatch.describe({"connection_state": 2}),
		LinkWatch.describe({"connection_state": 5, "end_reason": 5008, "end_debug": "x"}),
		LinkWatch.describe({}),
	]
	var expected := [
		"direct",
		"relayed via fra (peer's POP ams)",
		"relayed",
		"connecting",
		"closed: P2P rendezvous failed (reason 5008: x)",
		"",
	]
	_t._check(texts == expected, "session paths described: %s" % [texts])

	var steam := FakeSteam.new()
	var watch = LinkWatch.new()
	steam.infos[PEER] = {"connection_state": 1}
	watch.poll(steam, [PEER], 1000)
	var connecting: String = watch.last_line
	steam.infos[PEER] = {"connection_state": 3, "ping": 25}
	watch.poll(steam, [PEER], 1500)  # within the poll interval: not asked
	var lines_early: int = watch.lines
	watch.poll(steam, [PEER], 2000)
	var direct: String = watch.last_line
	watch.poll(steam, [PEER], 3000)
	_t._check(
		(
			connecting == "Connection to %s: connecting" % PEER
			and lines_early == 1
			and direct == "Connection to %s: direct (Steam ping 25 ms)" % PEER
			and watch.lines == 2
		),
		"the path is logged when it changes, at most once a second: %s / %s" % [connecting, direct]
	)
	steam.infos[PEER] = relayed
	watch.poll(steam, [PEER], 4000)
	_t._check(
		watch.last_line == "Connection to %s: relayed via fra (peer's POP ams) (Steam ping 30 ms)" % PEER,
		"a switch to the relay is logged: %s" % watch.last_line
	)
	watch.poll(steam, [], 5000)
	_t._check(watch.paths.empty(), "a member who left is forgotten")


func _test_session_failed(together: Node) -> void:
	var steam := FakeSteam.new()
	var watch = LinkWatch.new()
	var debug := "Timed out attempting to negotiate rendezvous"
	var text: String = watch.session_failed([5008, PEER, 5, debug], 1000)
	_t._check(
		(
			"P2P rendezvous failed (reason 5008, state 5: %s)" % debug in text
			and "the next message opens a new one" in text
		),
		"a failed session says what failed: %s" % text
	)
	steam.infos[PEER] = {"connection_state": 2}
	watch.poll(steam, [PEER], 1500)
	var lines: int = watch.lines
	steam.infos[PEER] = {"connection_state": 3, "info_flags": LinkWatch.FLAG_RELAYED, "ping": 40}
	watch.poll(steam, [PEER], 2600)
	_t._check(
		(
			lines == 0
			and watch.last_line
			== "Session with %s up again 1600 ms after it failed: relayed (Steam ping 40 ms)" % PEER
		),
		"what happened after it: %s" % watch.last_line
	)
	watch.session_failed([5009, PEER, 5, "x"], 10000)
	steam.infos[PEER] = {"connection_state": 2}
	watch.poll(steam, [PEER], 10000 + LinkWatch.FOLLOW_UP_MSEC)
	_t._check(
		"Session with %s still not up 15 s after it failed (connecting)" % PEER == watch.last_line,
		"or that it did not come back: %s" % watch.last_line
	)
	var odd: String = watch.session_failed(["a", null, null, null], 0)
	_t._check(odd.begins_with("Networking session failed: "), "other signatures still logged")
	# The transport's handler goes through it; the session's log lines carry the path.
	var transport: Node = together.transport
	var saved = transport.link_watch
	transport.link_watch = LinkWatch.new()
	transport._on_session_failed(5008, PEER, 5, debug)
	var pending: bool = transport.link_watch._failures.has(PEER)
	transport.link_watch.paths[PEER] = "relayed via fra"
	var status: String = together.session.steam_status_text(PEER)
	transport.link_watch = saved
	_t._check(
		pending and status.ends_with("; path: relayed via fra"),
		"transport hands failures to it; Session's status text has the path (%s)" % status
	)


# --- in a puppet battle (battle_loopback) ---


# The client in its puppet battle, playing slot 0 with 15 un-acked inputs: fresh snapshots for a
# third of a second, then none for 400 ms (sent meanwhile, arriving after it). The own player keeps
# its predicted lead instead of snapping back to the host's last position; the world holds on
# the newest snapshot instead of running past it; the gap is logged.
func test_client_stall(client: Node, input_sync: Node, player: Node2D, msg: Array):
	var saved: Array = input_sync.history
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var host_position: Vector2 = Snapshot.parse(msg[1]).players[0][PF.POSITION]
	var direction := Vector2.RIGHT if host_position.x < zone.get_center().x else Vector2.LEFT
	input_sync.history = []
	for seq in range(1, 16):
		input_sync.history.append([seq, direction])
	# Host times follow this clock (as the host's do the wall clock), so only the gap is late.
	var start: int = int(max(OS.get_ticks_msec(), client._buffer[-1].t + SNAPSHOT_MSEC))
	var feed_start := OS.get_ticks_msec()
	var t := start
	for _k in 10:
		t = int(max(t + 1, start + OS.get_ticks_msec() - feed_start))
		client._on_snapshot(_snapshot(msg, t))
		yield(_t.get_tree().create_timer(SNAPSHOT_MSEC / 1000.0), "timeout")
	client._snapshot_gaps._next_log_msec = 0  # earlier gaps of this suite: not rate limited here
	var logged: int = client._snapshot_gaps.logged
	var expected: Vector2 = client._own_target(player, client._buffer[-1].players[0])
	var lead: float = expected.distance_to(host_position)
	var gap_start := OS.get_ticks_msec()
	var worst := 0.0  # the own player's distance from its prediction
	var lowest_lag := 1000  # newest snapshot - render time: below 0, the world ran past it
	while OS.get_ticks_msec() - gap_start < 400:
		yield(_t.get_tree(), "idle_frame")
		worst = max(worst, player.global_position.distance_to(expected))
		lowest_lag = int(min(lowest_lag, client.interp_lag_msec))
	_t._check(
		lead > 20 and worst < 3,
		(
			"a 400 ms snapshot gap keeps the own player's prediction (%.0f px ahead, off by %.1f)"
			% [lead, worst]
		)
	)
	_t._check(lowest_lag >= -1, "the world holds on the newest snapshot (lag %d ms)" % lowest_lag)
	client._on_snapshot(_snapshot(msg, t + SNAPSHOT_MSEC))  # sent before the gap, held up
	_t._check(
		(
			client._snapshot_gaps.logged == logged + 1
			and "No snapshot for 4" in client._snapshot_gaps.last_line
			and "held up on the way" in client._snapshot_gaps.last_line
			and "; render delay 4" in client._snapshot_gaps.last_line
		),
		"the gap is logged: %s" % client._snapshot_gaps.last_line
	)
	yield(_t.get_tree(), "idle_frame")  # a new snapshot blends the prediction's correction in
	client._newest_rx_msec = OS.get_ticks_msec() - client.PREDICTION_STALE_MSEC - 50
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	_t._check(
		player.global_position.distance_to(host_position) < 1.0,
		"%d ms without snapshots: the own player stays with the frozen world"
		% (client.PREDICTION_STALE_MSEC + 50)
	)
	input_sync.history = saved


# The recorded snapshot msg at host time t, without its one-shot events.
static func _snapshot(msg: Array, t: int) -> Dictionary:
	var snapshot := Snapshot.parse(msg[1])
	snapshot.t = t
	snapshot.events = []
	return snapshot
