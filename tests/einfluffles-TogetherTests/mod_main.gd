extends Node
# Headless integration tests, run by tools/check.sh inside the decompiled game (no Steam).
# Prints "TOGETHER-TESTS: PASS" or "TOGETHER-TESTS: FAIL" and quits.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const FAKE_PEER := 4242
const DEVICE := VirtualDevices.FIRST
const BIT_ACCEPT := 1

var _failures := []
var _seq := 0


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	call_deferred("_run")


# Desktop platforms flush parsed input events every frame; the headless platform never does.
func _process(_delta: float) -> void:
	Input.flush_buffered_events()


func _run() -> void:
	yield(get_tree().create_timer(1.0), "timeout")
	var together := get_node("/root/ModLoader/einfluffles-BrotatoTogether")
	var input_sync: Node = together.input_sync

	# Virtual actions exist and survive the game's InputMap rebuild.
	_check(InputMap.has_action("ui_accept_%s" % DEVICE), "virtual actions registered")
	InputService.enable_gamepad_movement()
	_check(InputMap.has_action("analog_move_left_%s" % DEVICE), "actions survive rebuild")

	# Remote player joins via hold-to-join and is typed as a gamepad.
	RunData.set_coop_run(true)
	CoopService.clear_coop_players()
	CoopService.listening_for_inputs = true
	CoopService.set_process_input(true)
	input_sync.devices[FAKE_PEER] = DEVICE
	# Hold accept for longer than CoopService.HOLD_DURATION (time-based: headless frames are uncapped).
	var hold_until := OS.get_ticks_msec() + int(CoopService.HOLD_DURATION * 1000) + 300
	while OS.get_ticks_msec() < hold_until:
		_send(input_sync, Vector2(0.5, 0.0), Vector2(0.0, -1.0), BIT_ACCEPT)
		yield(get_tree(), "idle_frame")
	_check(CoopService.is_device_assigned(DEVICE), "virtual device joined co-op")
	if CoopService.is_device_assigned(DEVICE):
		_check(
			CoopService.get_player_input_type(0) == CoopService.PlayerType.GAMEPAD_XBOX,
			"virtual player typed as gamepad"
		)
		_check(Utils.get_player_rjoy_vector(0).is_equal_approx(Vector2(0, -1)), "aim reaches game")

	var move := Input.get_vector(
		"analog_move_left_%s" % DEVICE,
		"analog_move_right_%s" % DEVICE,
		"analog_move_up_%s" % DEVICE,
		"analog_move_down_%s" % DEVICE
	)
	_check(move.is_equal_approx(Vector2(0.5, 0.0)), "movement strength exact (got %s)" % move)

	# Reordered (stale) packets are ignored.
	_seq -= 10
	_send(input_sync, Vector2(-1.0, 0.0), Vector2.ZERO, 0)
	yield(get_tree(), "idle_frame")
	_check(Input.is_action_pressed("ui_accept_%s" % DEVICE), "stale packet ignored")
	_seq += 20

	# Button release edge.
	_send(input_sync, Vector2(0.5, 0.0), Vector2.ZERO, 0)
	yield(get_tree(), "idle_frame")
	_check(not Input.is_action_pressed("ui_accept_%s" % DEVICE), "button released")

	# Input timeout releases everything.
	yield(get_tree().create_timer(0.4), "timeout")
	input_sync._release_timed_out()
	_check(
		Input.get_action_strength("analog_move_right_%s" % DEVICE) == 0.0, "timeout releases move"
	)

	_finish()


func _send(input_sync: Node, move: Vector2, aim: Vector2, buttons: int) -> void:
	_seq += 1
	input_sync._apply_input(FAKE_PEER, [_seq, move, aim, buttons])


func _check(condition: bool, label: String) -> void:
	print("  %s %s" % ["ok  " if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _finish() -> void:
	print("TOGETHER-TESTS: %s" % ("PASS" if _failures.empty() else "FAIL %s" % [_failures]))
	get_tree().quit(0 if _failures.empty() else 1)
