extends Reference
# Suite input_ack: a remote player's movement on the host against the client's own-player
# prediction (battle_client.gd _own_target / _predict_own, run here on a copy of the player). The
# client counts one physics step per input newer than the snapshot's INPUT_ACK, so the host has to
# move exactly one step per acked input, however the packets arrive. INPUT streams drive player 1
# of a real battle on the host:
#  - jittered (bunched packets, ticks without one, a late stop, a swapped pair, a duplicate, a
#    stale packet): one moving input per tick, no correction
#  - one lost packet, and a burst of REDUNDANCY lost ones: the next packet brings their moves, no
#    step lost, no correction
#  - a 450 ms gap (packets held up on the way): no release, the host catches up, no correction
#  - a 1.2 s gap: the player lets go of everything, the backlog beyond MAX_BACKLOG is dropped and
#    the client's own player blends back by exactly that much
# Plus malformed redundancy fields and the protocol bump (no protocol 15 client or body).

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const InputSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/input_sync.gd")
const BattleClient := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_client.gd"
)
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")
const PF := Snapshot.PlayerField
const FAKE_PEER := 4242
const DEVICE := VirtualDevices.FIRST
const LATENCY := 2  # ticks from sending an input to its packet arriving, before jitter
# Extra ticks per seq (index seq - 1). Rising jitter leaves a tick without a packet, falling
# jitter bunches two into one tick. Seq 25 (the stop) is one tick late: tick 27 gets nothing,
# tick 28 gets the stop together with the next input.
const JITTER := [
	0, 0, 1, 1, 0, 0, 0, 1, 2, 2, 1, 0, 0, 1, 0, 0, 1, 1, 2, 1, 0, 0, 0, 0, 1, 0, 0, 1, 2, 1,
	0, 0, 0, 0, 1, 0, 0, 0, 0, 0
]
const MOVING_INPUTS := 24  # seqs 1..24 move, the rest stand still
const AIM_FROM := 30  # seqs from here aim up (jittered stream)
const TICKS := 50
const HELD := "ui_accept"  # BUTTON_ACTIONS bit 0, held through the long gap
const EPSILON := 0.05  # px

var t: Node  # the test mod: _check, scene tree
var input_sync: Node
var player: Node2D
var direction := Vector2.RIGHT  # towards the zone's middle
var step := 0.0
var _done := []  # finished feeders, out of the tree (freed at the end)


# The client's own player: what BattleClient._predict_own moves (it reads the speed, nothing else).
class OwnCopy:
	extends Node2D
	var dead := false
	var speed := 0.0

	func get_move_speed() -> float:
		return speed


class SentInputs:
	extends Node
	var history := []  # what InputSync.history holds on the client: [seq, move] sent so far


# Runs in the physics pass like battle_host.gd: after InputSync took this tick's input (the
# tree's physics_frame signal), before the battle scene's players move. Records what a snapshot
# of this tick would hold and what the client shows for it, then delivers the packets that arrive
# before the next tick (on a real host they come in with the idle frame).
class Feeder:
	extends Node

	var input_sync: Node
	var player: Node2D
	var client: Node  # a BattleClient outside the tree: only its own-player prediction runs
	var own: Node2D  # OwnCopy
	var arrivals := {}  # tick -> [seq, ...] in arrival order
	var moves := {}  # seq -> move
	var bodies := {}  # seq -> INPUT body
	var tick := 0
	# [tick, ack, host position, client display, released, HELD down on the device, msec,
	# client target (host position + replay)]
	var records := []
	var aim_on_arrival := true

	func _physics_process(delta: float) -> void:
		tick += 1
		input_sync._release_timed_out()  # input_sync.gd's own _physics_process, on a real host
		if moves.has(tick):  # the client sends seq s in its tick s
			client.input_sync.history.append([tick, moves[tick]])
		var ack: int = input_sync.last_applied_seq(FAKE_PEER)
		var entry := []
		entry.resize(PF.size())
		entry[PF.POSITION] = player.global_position
		entry[PF.INPUT_ACK] = ack
		client._newest_rx_msec = OS.get_ticks_msec()  # snapshots keep coming
		client._predict_own(own, 0, {"t": tick, "players": [entry]}, delta)
		var state: Dictionary = input_sync._remote.get(FAKE_PEER, {})
		records.append(
			[
				tick,
				ack,
				player.global_position,
				own.global_position,
				state.get("released", false),
				Input.is_action_pressed("%s_%s" % [HELD, DEVICE]),
				OS.get_ticks_msec(),
				client._own_display - client._own_error,
			]
		)
		for seq in arrivals.get(tick, []):
			input_sync._apply_input(FAKE_PEER, bodies[seq])
			if seq == AIM_FROM and bodies[seq][2] == Vector2.UP:
				aim_on_arrival = (
					Input.get_action_strength("rjoy_up_%s" % DEVICE) == 1.0
					and aim_on_arrival
				)


func run(test_mod: Node, together: Node):
	t = test_mod
	input_sync = together.input_sync
	var pause_control: Node = together.pause_control
	pause_control.set_process(false)
	CoopService.connected_players.clear()
	CoopService.connected_players.push_back([0, CoopService.PlayerType.GAMEPAD_XBOX])
	CoopService.connected_players.push_back([DEVICE, CoopService.PlayerType.GAMEPAD_XBOX])
	input_sync.devices[FAKE_PEER] = DEVICE
	input_sync._remote.erase(FAKE_PEER)
	VirtualDevices.release_all(DEVICE)
	t.get_tree().paused = false
	t.get_tree().change_scene("res://main.tscn")
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var main: Node = t.get_tree().current_scene
	player = main._players[1]
	t._check(player._movement_behavior.device == DEVICE, "player 1 moves with the remote device")
	yield(t.get_tree().create_timer(0.2), "timeout")  # the wave under way
	# The streams take about 9 s: no enemies that would kill player 1, no wave end that would stop it.
	main._wave_timer.stop()
	main._entity_spawner.clean_up_room()
	main._wave_manager.clean_up_room()

	var zone: Rect2 = ZoneService.get_current_zone_rect()
	if player.global_position.x > zone.get_center().x:
		direction = Vector2.LEFT
	step = player.get_move_speed() / float(Engine.iterations_per_second)
	yield(_test_jitter(), "completed")
	yield(_test_lost(), "completed")
	yield(_test_held_up_gap(), "completed")
	yield(_test_long_gap(), "completed")
	t._check(
		player.get_move_speed() / float(Engine.iterations_per_second) == step,
		"the player's speed stayed the same during the streams"
	)
	_test_redundant_moves()
	_test_malformed()
	_test_protocol()

	for feeder in _done:
		feeder.free()
	input_sync._remote.erase(FAKE_PEER)
	input_sync.devices.erase(FAKE_PEER)
	VirtualDevices.release_all(DEVICE)
	pause_control.set_process(true)


# --- streams ---


func _test_jitter():
	var standing := JITTER.size() - MOVING_INPUTS
	var moves := _moves([[MOVING_INPUTS, direction], [standing, Vector2.ZERO]])
	var arrivals := {}
	for seq in moves:
		_arrive(arrivals, seq + LATENCY + JITTER[seq - 1], seq)
	arrivals[28].invert()  # the stop (25) behind its successor (26) in one tick
	_arrive(arrivals, 15, 10)  # duplicate
	_arrive(arrivals, 33, 3)  # long stale
	var feeder = yield(_stream(moves, arrivals, TICKS, 0, AIM_FROM), "completed")
	_check_stream(feeder, "jittered stream", 1)
	t._check(feeder.aim_on_arrival, "aim reaches the device on arrival, not a tick later")


# A packet lost in a moving stream, then a burst of REDUNDANCY: the next packet brings their moves.
func _test_lost():
	var moves := _moves([[MOVING_INPUTS, direction], [16, Vector2.ZERO]])
	var arrivals := _arrivals(moves, [10])
	var feeder = yield(_stream(moves, arrivals, TICKS), "completed")
	_check_stream(feeder, "one lost packet", 1)
	_check_line(": 1 missing input(s) filled in", "one lost packet")

	var lost := range(10, 10 + InputSync.REDUNDANCY)
	var label := "%d lost packets in a row" % lost.size()
	feeder = yield(_stream(moves, _arrivals(moves, lost), TICKS), "completed")
	_check_stream(feeder, label, 1 + InputSync.CATCH_UP_PER_TICK)
	_check_line(": %d missing input(s) filled in" % lost.size(), label)


# 450 ms without INPUT (longer than the old 300 ms timeout, shorter than the client's prediction
# limit), the packets of that time held up on the way: they all arrive when it ends. The client
# predicted every step meanwhile; the host takes them all, up to twice as fast until it is back.
func _test_held_up_gap():
	var moves := _moves([[30, direction], [30, -direction], [30, Vector2.ZERO]])
	var arrivals := _arrivals(moves, [], [11, 27])
	var feeder = yield(_stream(moves, arrivals, 100), "completed")
	_check_stream(feeder, "450 ms gap", 1 + InputSync.CATCH_UP_PER_TICK)
	_check_line(" 0 dropped", "450 ms gap")
	var line: String = input_sync.last_recovery_line
	t._check(
		line != "" and not ", 0 step(s) caught up" in line,
		"450 ms gap: the host caught up (%s)" % line
	)
	# The timeout counts real milliseconds: from the last packet before the gap (tick 12) to the
	# first after it (tick 40). Physics ticks never run ahead of real time.
	var released := false
	for record in feeder.records:
		released = released or record[4]
	var gap_msec: int = feeder.records[39][6] - feeder.records[11][6]
	t._check(
		not released or gap_msec >= BattleClient.PREDICTION_STALE_MSEC,
		(
			"450 ms gap: the player is not released (gap %d ms, client limit %d ms)"
			% [gap_msec, BattleClient.PREDICTION_STALE_MSEC]
		)
	)


# 1.2 s without INPUT, far beyond both limits, with a button held: the host lets go of the
# button and the stick, and of the packets that arrive late it keeps the newest MAX_BACKLOG. The
# client's own player blends over to the host's path (the dropped steps, and what its replay of at
# most MAX_REPLAY_INPUTS left out during the gap), no snap.
func _test_long_gap():
	var moves := _moves([[30, direction], [30, -direction], [30, direction], [100, Vector2.ZERO]])
	var arrivals := _arrivals(moves, [], [11, 72])
	var feeder = yield(_stream(moves, arrivals, 200, 2), "completed")
	# Tick 85 brings seqs 11 to 83 (72 held up, 83 on time): the host keeps the newest MAX_BACKLOG.
	var dropped := [11, 83 - InputSync.MAX_BACKLOG]
	var kept: int = 83 - input_sync._remote[FAKE_PEER].dropped_to
	var limit: int = Protocol.STALL_LIMIT_MSEC * Engine.iterations_per_second / 1000
	t._check(
		kept == InputSync.MAX_BACKLOG and kept >= limit,
		"1.2 s gap: the host drops the oldest late inputs, keeps the newest %d (%d)" % [limit, kept]
	)
	_check_stream(feeder, "1.2 s gap", 1 + InputSync.CATCH_UP_PER_TICK, dropped)
	_check_line(", %d dropped" % (dropped[1] - dropped[0] + 1), "1.2 s gap")
	var line: String = input_sync.last_recovery_line
	t._check(not ", 0 step(s) caught up" in line, "1.2 s gap: the host caught up (%s)" % line)
	var held_before := false
	var released := false
	for record in feeder.records:
		if record[0] == 10:
			held_before = record[5]
		if record[0] > 10 and record[0] <= 11 + 72 and record[4]:
			released = released or not record[5]
	t._check(held_before, "1.2 s gap: the button is down before it")
	t._check(released, "1.2 s gap: the remote player lets go of its button and stick")


# Feeds the bodies of moves (built like InputSync.sample_local; HELD held from seq held_from on,
# aiming up from seq aim_from on, 0: never) as they arrive, for the given ticks, on a fresh remote
# player state and client copy.
func _stream(moves: Dictionary, arrivals: Dictionary, ticks: int, held_from := 0, aim_from := 0):
	input_sync._remote.erase(FAKE_PEER)
	input_sync.last_recovery_line = ""
	var client = BattleClient.new()
	client.input_sync = SentInputs.new()
	var own := OwnCopy.new()
	own.speed = player.get_move_speed()
	var feeder := Feeder.new()
	feeder.add_child(own)  # in the tree: _predict_own sets its global_position
	feeder.input_sync = input_sync
	feeder.player = player
	feeder.client = client
	feeder.own = own
	feeder.moves = moves
	feeder.arrivals = arrivals
	var sent := []
	var press := 1 << (4 * VirtualDevices.BUTTON_ACTIONS.find(HELD))  # counts one press
	for seq in range(1, moves.size() + 1):
		var aim := Vector2.UP if aim_from > 0 and seq >= aim_from else Vector2.ZERO
		var holds := held_from > 0 and seq >= held_from
		var held := 1 if holds else 0
		var counts := press if holds else 0
		var previous := InputSync.redundant_moves(sent, seq)
		feeder.bodies[seq] = [seq, moves[seq], aim, held, counts, 0, previous]
		sent.append([seq, moves[seq]])
	t.add_child(feeder)
	while feeder.tick < ticks:
		yield(t.get_tree(), "physics_frame")
	t.remove_child(feeder)
	_done.append(feeder)
	client.input_sync.free()
	client.free()
	VirtualDevices.release_all(DEVICE)
	return feeder


# seq -> move from [[count, move], ...], seqs from 1.
static func _moves(runs: Array) -> Dictionary:
	var moves := {}
	for run in runs:
		for _i in run[0]:
			moves[moves.size() + 1] = run[1]
	return moves


static func _arrive(arrivals: Dictionary, tick: int, seq: int) -> void:
	if not arrivals.has(tick):
		arrivals[tick] = []
	arrivals[tick].append(seq)


# Each seq LATENCY ticks after it was sent, except the lost ones; gap [first tick, ticks]: the
# packets sent in it arrive together after it.
static func _arrivals(moves: Dictionary, lost: Array, gap := []) -> Dictionary:
	var arrivals := {}
	for seq in moves:
		if seq in lost:
			continue
		var tick: int = seq + LATENCY
		if not gap.empty() and seq >= gap[0] and seq < gap[0] + gap[1]:
			tick = gap[0] + gap[1] + LATENCY
		_arrive(arrivals, tick, seq)
	return arrivals


# Position after one step for each seq up to `upto` that moves, except the dropped range.
func _walk(start: Vector2, moves: Dictionary, upto: int, dropped: Array) -> Vector2:
	var position := start
	for seq in range(1, int(min(upto, moves.size())) + 1):
		if dropped.empty() or seq < dropped[0] or seq > dropped[1]:
			position += moves[seq].normalized() * step
	return position


# For every tick: host position = start + one step per acked input (but the dropped ones), the
# host taking at most max_advance moving inputs a tick. The client shows start + one step per
# input it sent, exactly, as long as the host drops nothing; else it blends over to the host's
# path (each tick at most a step plus BLEND of the way to its new target, never a snap), and ends
# where the host stopped, which is where the client stopped minus the dropped steps.
func _check_stream(feeder: Feeder, label: String, max_advance: int, dropped := []) -> void:
	var records: Array = feeder.records
	var moves: Dictionary = feeder.moves
	var start: Vector2 = records[0][2]
	var blend := 1.0 - exp(-BattleClient.PREDICTION_ERROR_DECAY / Engine.iterations_per_second)
	var host_error := 0.0
	var display_error := 0.0
	var snap := 0.0  # px a tick the display moved beyond a step + blend of the way to its target
	var largest_correction := 0.0  # px between the display and its new target
	var ack_advance := 0
	var worst := 0  # tick of the worst host error
	for k in records.size():
		var record: Array = records[k]
		var host_expected := _walk(start, moves, record[1], dropped)
		if record[2].distance_to(host_expected) > host_error:
			host_error = record[2].distance_to(host_expected)
			worst = record[0]
		display_error = max(display_error, record[3].distance_to(_walk(start, moves, k + 1, [])))
		if k > 0:
			var shown: Vector2 = records[k - 1][3]
			var correction: float = shown.distance_to(record[7])
			largest_correction = max(largest_correction, correction)
			snap = max(snap, shown.distance_to(record[3]) - step - blend * correction)
			var steps := 0  # moving inputs the host took this tick
			for seq in range(records[k - 1][1] + 1, record[1] + 1):
				var taken: bool = dropped.empty() or seq < dropped[0] or seq > dropped[1]
				if taken and moves[seq] != Vector2.ZERO:
					steps += 1
			ack_advance = int(max(ack_advance, steps))
	var last: Array = records[-1]
	t._check(
		host_error < EPSILON,
		(
			"%s: host moves one step per acked input (worst %.2f px at tick %d, step %.2f)"
			% [label, host_error, worst, step]
		)
	)
	t._check(
		ack_advance <= max_advance,
		"%s: at most %d moving input(s) a host tick (%d)" % [label, max_advance, ack_advance]
	)
	t._check(
		last[1] == moves.size(),
		"%s: every input acked once the stream ends (ack %d of %d)" % [label, last[1], moves.size()]
	)
	var end := _walk(start, moves, moves.size(), dropped)
	var apart: float = last[2].distance_to(last[3])
	t._check(
		last[2].distance_to(end) < EPSILON and apart < EPSILON,
		"%s: host and client stop at the same place (%.2f px apart)" % [label, apart]
	)
	if dropped.empty():
		t._check(
			display_error < EPSILON,
			"%s: the client's prediction needs no correction (worst %.2f px)" % [label, display_error]
		)
	else:
		t._check(
			snap < EPSILON and largest_correction > step,
			(
				"%s: the correction blends in, no snap (up to %.1f px, %.2f px beyond the blend)"
				% [label, largest_correction, snap]
			)
		)


func _check_line(part: String, label: String) -> void:
	t._check(
		part in input_sync.last_recovery_line,
		"%s: logged \"%s\" (%s)" % [label, part, input_sync.last_recovery_line]
	)


# --- wire format ---


func _test_redundant_moves() -> void:
	var sent := [[3, Vector2.UP], [5, Vector2.LEFT], [6, Vector2.DOWN], [7, Vector2.RIGHT]]
	var run := PoolVector2Array([Vector2.LEFT, Vector2.DOWN, Vector2.RIGHT])
	t._check(
		InputSync.redundant_moves(sent, 8) == run,
		"redundancy: the unbroken run of moves right before the seq, oldest first"
	)
	for seq in range(8, 20):
		sent.append([seq, Vector2.ONE * seq])
	t._check(
		InputSync.redundant_moves(sent, 20).size() == InputSync.REDUNDANCY,
		"redundancy: at most %d moves" % InputSync.REDUNDANCY
	)
	t._check(InputSync.redundant_moves([], 1).size() == 0, "redundancy: none before the first")


func _test_malformed() -> void:
	input_sync._remote.erase(FAKE_PEER)
	var good := [1, Vector2.RIGHT, Vector2.ZERO, 0, 0, 0, PoolVector2Array()]
	input_sync._apply_input(FAKE_PEER, good)
	var nan := Vector2(NAN, 0.0)
	var too_many := PoolVector2Array()
	for _i in InputSync.REDUNDANCY + 1:
		too_many.append(Vector2.RIGHT)
	var bad := {
		"protocol 15 body (no redundancy)": [2, Vector2.RIGHT, Vector2.ZERO, 0, 0, 0],
		"redundancy as an Array": [2, Vector2.RIGHT, Vector2.ZERO, 0, 0, 0, [Vector2.RIGHT]],
		"redundancy too long": [2, Vector2.RIGHT, Vector2.ZERO, 0, 0, 0, too_many],
		"NaN in the redundancy": [2, Vector2.RIGHT, Vector2.ZERO, 0, 0, 0, PoolVector2Array([nan])],
		"inf in the redundancy":
		[2, Vector2.RIGHT, Vector2.ZERO, 0, 0, 0, PoolVector2Array([Vector2(INF, 0.0)])],
		"NaN move": [2, nan, Vector2.ZERO, 0, 0, 0, PoolVector2Array()],
		"redundancy as a string": [2, Vector2.RIGHT, Vector2.ZERO, 0, 0, 0, "x"],
	}
	for label in bad:
		input_sync._apply_input(FAKE_PEER, bad[label])
		var state: Dictionary = input_sync._remote[FAKE_PEER]
		var queued := false
		for input in state.queue:
			queued = queued or input[0] != 1
		t._check(state.seq == 1 and not queued, "malformed INPUT rejected: %s" % label)
	var later := [3, Vector2.RIGHT, Vector2.ZERO, 0, 0, 0, PoolVector2Array([Vector2.UP])]
	input_sync._apply_input(FAKE_PEER, later)
	var state: Dictionary = input_sync._remote[FAKE_PEER]
	var seqs := []
	for input in state.queue:
		seqs.append(input[0])
	t._check(
		state.seq == 3 and 2 in seqs and 3 in seqs,
		"a well-formed INPUT queues its own move and the one before it (%s)" % [seqs]
	)
	input_sync._remote.erase(FAKE_PEER)
	VirtualDevices.release_all(DEVICE)


# INPUT changed shape (protocol 16): a protocol 15 build is turned away at HELLO instead of
# joining with inputs the host drops (see _test_malformed for its body).
func _test_protocol() -> void:
	var host := {
		"version": Protocol.VERSION, "game_version": "1", "mod_version": "1", "dlcs": []
	}
	var client := host.duplicate()
	t._check(Compat.incompatibility(host, client) == "", "protocol: the same build joins")
	client.version = 15
	t._check(
		Protocol.VERSION >= 16 and "protocol" in Compat.incompatibility(host, client),
		"protocol: a client without input redundancy (15) is refused (host %d)" % Protocol.VERSION
	)
	t._check(
		BattleClient.PREDICTION_STALE_MSEC == InputSync.INPUT_TIMEOUT_MSEC,
		"the client predicts exactly as long as the host keeps a silent player's input"
	)
	t._check(
		InputSync.MAX_BACKLOG <= BattleClient.MAX_REPLAY_INPUTS,
		"the host never catches up on more than the client replays"
	)
