extends Reference
# The host's player joins first (extensions/singletons/coop_service.gd): in character selection a
# remote player's hold to join counts only once a player of the host's machine is in. Part of the
# selection suite; sets up its own screen and puts the players back.

const COOP_RESUME := "res://ui/menus/shop/coop_resume.tscn"
const KEYBOARD := 7  # CoopService.KEYBOARD_REMAPPED_DEVICE_ID
const BIT_ACCEPT := 1
const AIM := Vector2(0.0, -1.0)

var t: Node = null
var _input: Node = null


func run(test_mod: Node, together: Node):
	t = test_mod
	_input = together.input_sync
	var tree: SceneTree = t.get_tree()
	var players: Array = CoopService.connected_players.duplicate(true)
	var devices: Dictionary = _input.devices.duplicate()
	var listening: bool = CoopService.listening_for_inputs
	tree.change_scene(MenuData.character_selection_scene)
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	RunData.set_coop_run(true)
	CoopService.clear_coop_players()
	CoopService.listening_for_inputs = true
	CoopService.set_process_input(true)
	_input.devices[t.FAKE_PEER] = t.DEVICE
	_input._remote.erase(t.FAKE_PEER)  # other suites' sequence numbers would make ours stale
	_hold(false)  # a first packet with nothing held
	yield(tree, "idle_frame")
	for _i in 10:  # until the press (buffered) has started the hold
		_hold(true)
		yield(tree, "idle_frame")
		if CoopService._hold_timers.has(t.DEVICE):
			break
	t._check(CoopService._hold_timers.has(t.DEVICE), "host first: the remote player's hold started")
	CoopService._hold_timers[t.DEVICE] = CoopService.HOLD_DURATION
	for _i in 3:
		_hold(true)
		yield(tree, "idle_frame")
	t._check(
		not CoopService.is_device_assigned(t.DEVICE),
		"host first: a remote hold does not count before a local player joined"
	)
	# A frame as long as joining takes, which the game adds at once after the extension's level
	# (called alone here: the engine caps a real frame's delta well below HOLD_DURATION).
	var long_frame: float = CoopService.HOLD_DURATION + 1.0
	CoopService._process(long_frame)
	t._check(
		CoopService._hold_timers.get(t.DEVICE, 0.0) + long_frame < CoopService.HOLD_DURATION,
		"host first: a long frame does not complete the held-back hold either"
	)
	CoopService._hold_timers[t.DEVICE] = 0.0  # where the game's level would have left it
	var resume := Node.new()
	resume.filename = COOP_RESUME
	t._check(
		CoopService.bt_holds_wait(tree.current_scene) and not CoopService.bt_holds_wait(resume),
		"host first: only in character selection, not on the co-op resume screen (saved slots)"
	)
	resume.free()
	CoopService._add_player(KEYBOARD, CoopService.PlayerType.KEYBOARD_AND_MOUSE)
	var hold_until := OS.get_ticks_msec() + int(CoopService.HOLD_DURATION * 1000) + 300
	while OS.get_ticks_msec() < hold_until and not CoopService.is_device_assigned(t.DEVICE):
		_hold(true)
		yield(tree, "idle_frame")
	t._check(
		(
			CoopService.get_remapped_player_device(0) == KEYBOARD
			and CoopService.get_remapped_player_device(1) == t.DEVICE
		),
		"host first: with the host's player in, the remote hold joins as player 2"
	)
	_hold(false)
	yield(tree, "idle_frame")
	_input.devices = devices
	CoopService.listening_for_inputs = listening
	CoopService.connected_players = players


func _hold(accept: bool) -> void:
	t._send(_input, Vector2.ZERO, AIM if accept else Vector2.ZERO, BIT_ACCEPT if accept else 0)
