extends Reference
# Suite client_report (sync/client_report.gd): a client's frame windows, scene-change stalls and
# prediction corrections, fed with made-up frame times, then the host's lines for them (checked,
# clamped, budgeted), then a battle the host records and a client replays, with the reports that
# real frames give. Without a session the report runs as test_client: it keeps what it would
# send instead of sending it.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const PEER := 4343
const PEER_NAME := "player two"
const FRAME_USEC := 16000

var _t: Node
var _now := 0  # msec of the fed frames
var _scenes := []  # stand-ins for current_scene


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	var report: Node = together.client_report
	_t._check(report.process_priority < 0, "the report's _process runs ahead of the others")
	_test_not_a_client(report)
	_begin(report)
	_test_windows(report)
	_test_paused(report)
	_test_budget(report)
	_test_stall(report)
	_test_corrections(report)
	_end(report)
	_test_host(together, report)
	yield(_test_battle(together, report), "completed")
	for scene in _scenes:
		scene.free()


func _scene(file: String) -> Node:
	var scene := Node.new()
	scene.filename = file
	_scenes.append(scene)
	return scene


# A ready client as far as the report goes; no frame passes until _end.
func _begin(report: Node) -> void:
	report.test_client = true
	report.active = true
	report._reset()
	report.sent.clear()
	_now = 100000


func _end(report: Node) -> void:
	report.test_client = false
	report.active = false
	report._reset()
	report.sent.clear()


# frames of usec each, the clock moving with them.
func _feed(report: Node, scene: Node, count: int, usec := FRAME_USEC, paused := false) -> void:
	for _i in count:
		_now += usec / 1000
		report.step(usec, scene, paused, _now)


func _test_not_a_client(report: Node) -> void:
	report.test_client = false
	report._process(0.0)
	report._process(0.0)
	ClientReport.mark(ClientReport.Mark.PARSE, 5000)
	ClientReport.mirror_cost(5000, 3)
	ClientReport.note_correction(100.0, 10.0, 2, 400.0)
	_t._check(
		not report.active and report._window.empty() and report.sent.empty()
		and report._marks == [0, 0, 0, 0],
		"not a ready client: nothing is measured"
	)


func _test_windows(report: Node) -> void:
	var battle := _scene("res://main.tscn")
	_feed(report, battle, 1)  # the first scene is taken as it is, no stall
	_t._check(report._stall.empty() and report._window.scene == 1, "first scene: no stall")
	# 100 frames of 20 ms, one of 70, one of exactly 50, then 20 ms frames up to 10 s.
	_feed(report, battle, 100, 20000)
	_feed(report, battle, 1, 70000)
	_feed(report, battle, 1, 50000)
	_feed(report, battle, 393, 20000)
	_t._check(report.sent.empty(), "a window is not sent before it holds 10 s of frames")
	_feed(report, battle, 1, 20000)
	_t._check(report.sent.size() == 1, "a window with a slow frame is sent at 10 s")
	if report.sent.size() != 1:
		return
	var body: Dictionary = report.sent[0]
	_t._check(
		body.kind == ClientReport.KIND_FRAMES and body.scene == 1 and body.frames == 496
		and is_equal_approx(body.msec, 10000.0) and is_equal_approx(body.worst, 70.0)
		and body.over == 2 and abs(body.avg - 10000.0 / 496) < 0.01,
		"window maths: 496 frames, avg %.2f, worst %s, %s over 50 ms" % [body.avg, body.worst, body.over]
	)
	_t._check(body.mirror_avg == 0.0 and body.corrections == 0, "no mirror outside a battle")
	report.sent.clear()
	_feed(report, battle, 625)  # 10 s of 16 ms frames
	_t._check(report.sent.empty() and report._window.frames == 0, "a smooth window is dropped")
	_now += 60000
	_feed(report, battle, 625)
	_t._check(
		report.sent.size() == 1 and report.sent[0].worst == 16.0,
		"a smooth window goes out once a minute as a baseline"
	)
	report.sent.clear()


func _test_paused(report: Node) -> void:
	var battle: Node = _scenes[0]
	var before: float = report._window.msec
	_feed(report, battle, 50, 100000, true)
	_t._check(
		report._window.msec == before and report._window.over == 0 and report.sent.empty(),
		"paused: no frame windows"
	)


# Six window lines a minute; a window waiting for room grows and goes out when there is some.
func _test_budget(report: Node) -> void:
	var battle: Node = _scenes[0]
	report._window_lines.clear()
	report.window_msec = 1000
	for _i in 7:
		_feed(report, battle, 1, 60000)
		_feed(report, battle, 59)  # 60 + 59 * 16 ms: 1 s
	_t._check(report.sent.size() == 6, "six slow windows a minute (%d)" % report.sent.size())
	_t._check(report._window.msec > 1000.0, "the seventh waits and grows")
	_now += 60000
	_feed(report, battle, 1)
	_t._check(
		report.sent.size() == 7 and report.sent[6].msec > 1000.0,
		"and goes out with its whole time once there is room again"
	)
	report.sent.clear()
	report._window_lines.clear()
	report.window_msec = ClientReport.WINDOW_MSEC


func _test_stall(report: Node) -> void:
	var shop := _scene("res://ui/menus/shop/coop_shop.tscn")
	var battle := _scene("res://main.tscn")
	_feed(report, shop, 1)
	report.sent.clear()
	_feed(report, shop, 5)
	# The 600 ms frame that changed the scene: the mod's marks in it, the rest the game's.
	ClientReport.mark(ClientReport.Mark.PARSE, 22000)
	ClientReport.mark(ClientReport.Mark.DESERIALIZE, 78000)
	ClientReport.mark(ClientReport.Mark.APPLY, 9000)
	ClientReport.mark(ClientReport.Mark.PUPPET_SETUP, 31000)
	_feed(report, battle, 1, 600000)
	ClientReport.mark(ClientReport.Mark.APPLY, 1000)  # a later, shorter frame's
	_feed(report, battle, 1, 30000)
	_t._check(report.sent.empty(), "the stall is watched for 3 s")
	_feed(report, battle, 200)
	var stalls := _of_kind(report.sent, ClientReport.KIND_SCENE)
	_t._check(stalls.size() == 1, "then reported once (%d)" % stalls.size())
	if stalls.empty():
		return
	var body: Dictionary = stalls[0]
	var sum := 0.0
	for value in body.marks:
		sum += value
	_t._check(
		body.kind == ClientReport.KIND_SCENE and body.scene == 1 and body.stall == 600.0
		and body.marks == [22.0, 78.0, 9.0, 31.0] and sum <= body.stall,
		"a 600 ms frame at a scene change: its marks %s (sum %s) within the stall" % [body.marks, sum]
	)
	var lines: Array = ClientReport.report_lines(PEER_NAME, bytes2var(var2bytes(body), false))
	var expected := (
		"Client %s entered main.tscn: stalled 600 ms (run parse 22, deserialize 78, apply 9,"
		% PEER_NAME
		+ " puppet setup 31, rest 460)"
	)
	_t._check(
		lines == [expected],
		"the host's line for it: %s" % [lines]
	)
	# Loaded before this node's frame began: the frame before the change holds the stall.
	report.sent.clear()
	ClientReport.mark(ClientReport.Mark.PARSE, 40000)
	_feed(report, battle, 1, 300000)
	_feed(report, shop, 1, 20000)
	_feed(report, shop, 200)
	stalls = _of_kind(report.sent, ClientReport.KIND_SCENE)
	_t._check(
		stalls.size() == 1 and stalls[0].stall == 300.0 and stalls[0].scene == 3
		and stalls[0].marks[0] == 40.0,
		"the frame before a change counts as the change's too"
	)
	report.sent.clear()
	report._scene_lines.clear()
	_feed(report, battle, 1, 20000)
	_feed(report, battle, 200)
	var quiet := _of_kind(report.sent, ClientReport.KIND_SCENE).empty()
	_t._check(quiet, "a change without a slow frame is no line")


func _test_corrections(report: Node) -> void:
	var battle: Node = _scenes[-1]
	_feed(report, battle, 1)
	report.sent.clear()
	var step := 420.0 / Engine.iterations_per_second
	ClientReport.note_correction(step * 0.9, 30.0, 2, 420.0)
	_t._check(report._window.corrections == 0, "a correction under a step is not counted")
	ClientReport.note_correction(38.0, 70.0, 6, 420.0)
	ClientReport.note_correction(step * 1.5, 10.0, 1, 420.0)
	_t._check(
		report._window.corrections == 2 and report._window.largest == 38.0
		and report._window.age == 70.0 and report._window.unacked == 6
		and report._window.speed == 420.0,
		"corrections over a step are counted, the largest with its values"
	)
	_t._check(
		ClientReport.unacked([[4, Vector2.ZERO], [5, Vector2.ZERO], [6, Vector2.ZERO]], 4) == 2,
		"unacked inputs: those after the ack"
	)
	_feed(report, battle, 625)
	_t._check(
		report.sent.size() == 1 and report.sent[0].corrections == 2,
		"a window with corrections is sent (smooth frames or not)"
	)


func _test_host(together: Node, report: Node) -> void:
	var session: Node = together.session
	var transport: Node = session.transport
	var lobby: int = transport.lobby_id
	var host: int = transport.host_id
	transport.lobby_id = 99
	transport.host_id = transport.local_id  # this game is the host
	session.peers[PEER] = {"name": PEER_NAME, "ready": true, "rtt_ms": 40, "last_seen_msec": 0}
	report.lines_logged = 0
	report.lines_dropped = 0
	report._host_lines.clear()
	report._host_dropped.clear()
	var frames := {
		"kind": ClientReport.KIND_FRAMES, "scene": 1, "msec": 10012.0, "frames": 590,
		"avg": 16.97, "worst": 48.2, "over": 0, "mirror_avg": 1.94, "mirror_worst": 6.2,
		"entities": 412, "corrections": 4, "largest": 38.3, "age": 70.2, "unacked": 6,
		"speed": 420.0,
	}
	var now := 1000000
	report.host_receive(PEER, frames, now)
	var frames_line := (
		"Client %s frames in main.tscn, 10 s: avg 17, worst 48, 0 over 50 ms;" % PEER_NAME
		+ " mirror avg 1.9, worst 6.2 ms; up to 412 entities"
	)
	var corrections_line := (
		"Client %s corrections, 10 s: 4 over a step, largest 38 px (snapshot 70 ms old," % PEER_NAME
		+ " 6 inputs unacked, 420 px/s)"
	)
	_t._check(
		report.last_lines == [frames_line, corrections_line],
		"the host logs a report as lines: %s" % [report.last_lines]
	)
	var malformed := [
		null, [1, 2], {"kind": "frames"}, {"kind": 7, "scene": 1},
		_with(frames, "avg", "17"), _with(frames, "worst", null), _with(frames, "scene", "main"),
		_with(frames, "speed", NAN), {"kind": ClientReport.KIND_SCENE, "scene": 1, "stall": 600},
		{"kind": ClientReport.KIND_SCENE, "scene": 1, "stall": 600, "marks": [1, 2, 3]},
		{"kind": ClientReport.KIND_SCENE, "scene": 1, "stall": 600, "marks": [1, 2, "x", 4]},
	]
	var logged: int = report.lines_logged
	for body in malformed:
		report.host_receive(PEER, body, now)
	_t._check(report.lines_logged == logged, "malformed reports are dropped")
	report.host_receive(PEER + 1, frames, now)
	session.peers[PEER + 1] = {"name": "x", "ready": false, "rtt_ms": -1, "last_seen_msec": 0}
	report.host_receive(PEER + 1, frames, now)
	_t._check(report.lines_logged == logged, "and those of non-members")
	var wild := _with(_with(_with(frames, "worst", 1e12), "over", -5), "scene", 99)
	report.host_receive(PEER, _with(wild, "corrections", 0), now)
	_t._check(
		report.last_lines.size() == 1
		and report.last_lines[0].begins_with("Client %s frames in the waiting screen" % PEER_NAME)
		and "worst 600000, 0 over" in report.last_lines[0],
		"values are clamped: %s" % [report.last_lines]
	)
	# 3 lines so far this minute: 8 at most.
	for _i in 4:
		report.host_receive(PEER, frames, now + 1000)
	_t._check(
		report.lines_logged == 8 and report.lines_dropped == 3,
		"at most 8 lines a minute per client (%d logged, %d dropped)"
		% [report.lines_logged, report.lines_dropped]
	)
	report.host_receive(PEER, _with(frames, "corrections", 0), now + 60500)
	_t._check(
		report.last_lines.size() == 1
		and report.last_lines[0].ends_with("(3 lines of this client left out before)"),
		"the next line says how many were left out: %s" % [report.last_lines]
	)
	# Through the session, as the message arrives.
	logged = report.lines_logged
	var data := Protocol.encode(Protocol.Msg.CLIENT_REPORT, _with(frames, "corrections", 0))
	report._host_lines.clear()
	session._on_message_received(PEER, 0, data)
	_t._check(report.lines_logged == logged + 1, "a CLIENT_REPORT message reaches the host's log")
	transport.lobby_id = 0
	report.host_receive(PEER, frames, now + 200000)
	_t._check(report.lines_logged == logged + 1, "not a host: nothing logged")
	session.peers.erase(PEER)
	session.peers.erase(PEER + 1)
	transport.lobby_id = lobby
	transport.host_id = host


func _with(body: Dictionary, key: String, value) -> Dictionary:
	var copy := body.duplicate()
	copy[key] = value
	return copy


# The host records a short battle, the client replays it while its report runs on real frames:
# the scene change's stall with the mod's marks, and a window with the mirror's cost.
func _test_battle(together: Node, report: Node):
	var tree: SceneTree = _t.get_tree()
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)  # driven by hand: no Steam session, so it would end the battle
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main := tree.current_scene
	host._start_battle(main)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < 2000:
		yield(tree.create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
	var host_types: Dictionary = host._types.duplicate()
	host._end_battle()
	start.types = {}
	for path in host_types:
		start.types[host_types[path]] = path

	report.test_client = true
	report.window_msec = 1000
	report.baseline_msec = 0
	report.sent.clear()
	yield(tree.create_timer(0.2), "timeout")  # active, on the host's battle scene
	client._on_battle_start(start)  # after this frame's _process, like a message would be
	yield(client, "battle_entered")
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(tree, "idle_frame")
		client._on_snapshot(snap)
	var until := OS.get_ticks_msec() + ClientReport.STALL_WATCH_MSEC + 500
	while OS.get_ticks_msec() < until and _of_kind(report.sent, ClientReport.KIND_SCENE).empty():
		yield(tree, "idle_frame")
	var stalls := _of_kind(report.sent, ClientReport.KIND_SCENE)
	_t._check(stalls.size() == 1, "the battle's scene change is reported (%d)" % stalls.size())
	if stalls.size() == 1:
		var stall: Dictionary = stalls[0]
		var sum := 0.0
		var all_marked := true
		for value in stall.marks:
			sum += value
			all_marked = all_marked and value > 0.0
		print("  info: battle scene change: stall %.0f ms, marks %s" % [stall.stall, stall.marks])
		_t._check(
			stall.scene == 1 and all_marked and sum <= stall.stall,
			"with run parse, deserialize, apply and puppet setup in it (sum %.1f of %.1f ms)"
			% [sum, stall.stall]
		)
	var mirrored := []
	for body in _of_kind(report.sent, ClientReport.KIND_FRAMES):
		if body.scene == 1 and body.mirror_avg > 0.0:
			mirrored.append(body)
	_t._check(not mirrored.empty(), "a frames report of the battle has the mirror's cost")
	if not mirrored.empty():
		var body: Dictionary = bytes2var(var2bytes(mirrored[0]), false)
		var lines := ClientReport.report_lines(PEER_NAME, body)
		print("  info: %s" % [lines])
		_t._check(
			body.entities > 0 and lines.size() >= 1 and "; mirror avg" in lines[0],
			"and the host's line shows it with the entities (%d)" % body.entities
		)
	report.test_client = false
	report.window_msec = ClientReport.WINDOW_MSEC
	report.baseline_msec = ClientReport.BASELINE_MSEC
	report.sent.clear()
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)


func _of_kind(bodies: Array, kind: int) -> Array:
	var found := []
	for body in bodies:
		if body.kind == kind:
			found.append(body)
	return found
