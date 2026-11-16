extends Reference
# Suite input_ack: a remote player's movement on the host against the client's own-player
# prediction (battle_client.gd _own_target). The client counts one physics step per input newer
# than the snapshot's INPUT_ACK, so the host has to move exactly one step per acked input, however
# the packets arrive. A jittered INPUT stream (bunched packets, ticks without one, a late stop, a
# swapped pair, a duplicate, a stale packet) drives player 1 of a real battle on the host.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
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
const AIM_FROM := 30  # seqs from here aim up
const TICKS := 50

var t: Node  # the test mod: _check, scene tree


# Runs in the physics pass like battle_host.gd: after InputSync took this tick's input (the
# tree's physics_frame signal), before the battle scene's players move. Records what a snapshot
# of this tick would hold, then delivers the packets that arrive before the next tick (on a real
# host they come in with the idle frame).
class Feeder:
	extends Node

	var input_sync: Node
	var player: Node2D
	var arrivals := {}  # tick -> [seq, ...] in arrival order
	var moves := {}  # seq -> move
	var tick := 0
	var records := []  # [tick, ack, position]
	var aim_on_arrival := true

	func _physics_process(_delta: float) -> void:
		tick += 1
		records.append([tick, input_sync.last_applied_seq(FAKE_PEER), player.global_position])
		for seq in arrivals.get(tick, []):
			var aim := Vector2.UP if seq >= AIM_FROM else Vector2.ZERO
			input_sync._apply_input(FAKE_PEER, [seq, moves[seq], aim, 0, 0, 0])
			if seq == AIM_FROM:
				aim_on_arrival = (
					Input.get_action_strength("rjoy_up_%s" % DEVICE) == 1.0
					and aim_on_arrival
				)


func run(test_mod: Node, together: Node):
	t = test_mod
	var input_sync: Node = together.input_sync
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
	var player: Node2D = main._players[1]
	t._check(player._movement_behavior.device == DEVICE, "player 1 moves with the remote device")
	yield(t.get_tree().create_timer(0.2), "timeout")  # the wave under way

	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var direction := Vector2.RIGHT
	if player.global_position.x > zone.get_center().x:
		direction = Vector2.LEFT
	var feeder := Feeder.new()
	feeder.input_sync = input_sync
	feeder.player = player
	for seq in range(1, JITTER.size() + 1):
		feeder.moves[seq] = direction if seq <= MOVING_INPUTS else Vector2.ZERO
		var tick: int = seq + LATENCY + JITTER[seq - 1]
		if not feeder.arrivals.has(tick):
			feeder.arrivals[tick] = []
		feeder.arrivals[tick].append(seq)
	feeder.arrivals[28].invert()  # the stop (25) behind its successor (26) in one tick
	feeder.arrivals[15].append(10)  # duplicate
	feeder.arrivals[33].append(3)  # long stale
	var step: float = player.get_move_speed() / float(Engine.iterations_per_second)
	t.add_child(feeder)
	while feeder.tick < TICKS:
		yield(t.get_tree(), "physics_frame")
	feeder.queue_free()
	_check_records(feeder, step, direction)
	t._check(feeder.aim_on_arrival, "aim reaches the device on arrival, not a tick later")
	t._check(
		player.get_move_speed() / float(Engine.iterations_per_second) == step,
		"the player's speed stayed the same during the stream"
	)

	input_sync._remote.erase(FAKE_PEER)
	input_sync.devices.erase(FAKE_PEER)
	VirtualDevices.release_all(DEVICE)
	pause_control.set_process(true)


# For every tick: host position = start + one step per input up to the ack (the host moved one
# step per acked input), and the client's prediction (host position + one step per input it sent
# after the ack) = start + one step per input it sent, so it never needs a correction.
func _check_records(feeder: Feeder, step: float, direction: Vector2) -> void:
	var records: Array = feeder.records
	var start: Vector2 = records[0][2]
	var host_error := 0.0
	var prediction_error := 0.0
	var max_ack_advance := 0
	var previous_ack := 0
	for record in records:
		var tick: int = record[0]
		var ack: int = record[1]
		var position: Vector2 = record[2]
		var acked_steps := 0
		var sent_steps := 0
		for seq in feeder.moves:
			if feeder.moves[seq] == Vector2.ZERO:
				continue
			if seq <= ack:
				acked_steps += 1
			if seq <= tick:  # the client sends seq s in its tick s
				sent_steps += 1
		var host_expected: Vector2 = start + direction * step * acked_steps
		host_error = max(host_error, position.distance_to(host_expected))
		var predicted: Vector2 = position + direction * step * (sent_steps - acked_steps)
		var ideal: Vector2 = start + direction * step * sent_steps
		prediction_error = max(prediction_error, predicted.distance_to(ideal))
		if ack <= MOVING_INPUTS:
			max_ack_advance = max(max_ack_advance, ack - previous_ack)
		previous_ack = ack
	var last: Array = records[-1]
	t._check(
		host_error < 0.05,
		"host moves one step per acked input (worst %.2f px, step %.2f)" % [host_error, step]
	)
	t._check(
		prediction_error < 0.05,
		"client prediction needs no correction, also at the stop (worst %.2f px)" % prediction_error
	)
	t._check(max_ack_advance <= 1, "one moving input per host tick (ack +%d)" % max_ack_advance)
	t._check(
		last[1] == JITTER.size(),
		"every input acked once the stream ends (ack %d of %d)" % [last[1], JITTER.size()]
	)
	var final_expected: Vector2 = start + direction * step * MOVING_INPUTS
	t._check(
		last[2].distance_to(final_expected) < 0.05,
		"host stops where the client stopped (%.2f px off)" % last[2].distance_to(final_expected)
	)
