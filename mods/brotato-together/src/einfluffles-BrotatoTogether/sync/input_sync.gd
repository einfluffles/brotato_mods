extends Node
# Client: sample local input every physics frame and send it to the host. Host: apply it to
# the peer's virtual device, movement as exactly one input per physics tick (the client predicts
# it) with an ack of the newest one whose tick has run; aim and buttons are newest-wins.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const PressCounter := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/press_counter.gd"
)
const RemoteButtons := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/remote_buttons.gd"
)
const LocalAim := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/local_aim.gd")
const SharedScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/shared_scroll.gd")
const StreamGaps := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/stream_gaps.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:InputSync"
# host: without INPUT for this long a remote player lets go of its buttons, aim and stick. Equal
# to the client's prediction limit and longer than a full backlog takes to drain.
const INPUT_TIMEOUT_MSEC := Protocol.STALL_LIMIT_MSEC
# host: queued inputs beyond the one the next tick takes. Each one delays this player on the
# host by a tick.
const MAX_WAITING := 2
# Moves of the inputs right before the current one that ride along in each INPUT (8 bytes each),
# so a lost packet still gets its step.
const REDUNDANCY := 4
# host: queued inputs kept after a gap: STALL_LIMIT_MSEC at 60 Hz, below
# BattleClient.MAX_REPLAY_INPUTS, so a gap the client predicts through is caught up in full.
const MAX_BACKLOG := 36
# host: extra inputs taken per tick while more than MAX_WAITING wait, each as a physics step of
# its own. 1: at most double speed while catching up, instead of lagging or jumping ahead.
const CATCH_UP_PER_TICK := 1
const RECOVERY_LOG_INTERVAL_MSEC := StreamGaps.LOG_INTERVAL_MSEC
const HISTORY_SIZE := 180  # 3 s at 60 Hz
const NAV_DEADZONE := 0.5  # InputService.joystick_deadzone (left stick -> menu directions)

var session: Node = null
var battle_client: Node = null  # client: own player position for mouse aim
var menu_puppet: Node = null  # client: the copy of the host's selection screen (own stick)
# host: steam_id -> device. Kept for the whole lobby so a rejoining player gets the same
# device and therefore the same co-op slot.
var devices := {}

# client: recent [seq, move] pairs, replayed on top of the host's position for prediction
var history := []
# client: the lobby popup is open and owns the keyboard/pad; the host gets neutral input
var local_input_blocked := false
# host: BUTTON_ACTIONS bits not delivered to remote players' virtual devices while a screen runs
# on the clients themselves: a remote accept must not also press the host's copy of the panel.
var blocked_buttons := 0
# host: more masks of that kind, one per screen (key: its name), so that two screens never
# overwrite each other's block. OR-ed with blocked_buttons.
var blocked_by := {}
# client: owner ("battle", "shop") -> true while the host's game is paused there
var host_paused := {}
# client: what last switched the local buttons ("owner: reason"), for the logs
var last_local_change := ""
# host: the last line about filled-in, caught-up or dropped inputs
var last_recovery_line := ""

var _seq := 0
var _presses = PressCounter.new()
# client: this player's own slot device while a screen runs locally (see set_local_device)
var _local_buttons = null
# client: [owner, device] of each screen that wants the local buttons now, oldest first
var _local_claims := []
# client: the same for its own Esc menu during a wave (see set_local_menu); the host gets
# neutral input meanwhile
var _menu_buttons = null
var _menu_presses = PressCounter.new()
var _stick_device := -1  # the slot device _drive_local_stick drove last (-1: none)

# host: steam_id -> {seq, last_msec, released, buttons: RemoteButtons, queue: [[seq, move]...],
# applied, ack, move, dropped_to, and for the log: filled, caught_up, dropped, dropped_moving,
# next_log_msec} (see _apply_input, _tick_movement)
var _remote := {}
# host: steam_id -> StreamGaps of its INPUT stream (logs the stalls)
var _input_gaps := {}


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("peer_ready", self, "_on_peer_ready")
	session.connect("peer_removed", self, "_on_peer_removed")
	session.connect("message", self, "_on_message")
	session.transport.connect("lobby_ready", self, "_on_lobby_ready")
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	CoopService.bt_players = self  # colour picks belong to the steam id


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	VirtualDevices.register_actions()
	# Emitted at the start of every physics tick (also while paused), before any node's
	# _physics_process: the players read their device after the tick's input is on it.
	get_tree().connect("physics_frame", self, "_on_physics_frame")


func _physics_process(_delta: float) -> void:
	# Off while the lobby popup owns the input: it navigates with InputService's echo actions.
	var client_mode: bool = session.is_client() and not local_input_blocked
	if client_mode != VirtualDevices.is_client_mode():
		VirtualDevices.set_client_mode(client_mode)
	if session.is_client():
		_send_local_input()
	elif session.is_host():
		_release_timed_out()


func _process(delta: float) -> void:
	if _local_buttons != null:
		_local_buttons.process_echo(delta, true)
	if _menu_buttons != null:
		_menu_buttons.process_echo(delta, true)
	if not session.is_host():
		return
	var echo: bool = InputService.is_virtual_echo_enabled()
	for steam_id in _remote:
		_remote[steam_id].buttons.process_echo(delta, echo)


func _input(event: InputEvent) -> void:
	if session.is_client() and not local_input_blocked:
		(_menu_presses if _menu_buttons != null else _presses).on_event(event)


# A screen that runs on this client itself: the local buttons also drive this player's slot
# device, as the host applies a remote player's. Each owner ("shop", "upgrades") has its own
# claim, so a late stop of one screen never turns off another's. The newest claim drives.
func set_local_device(owner: String, device: int, reason := "") -> void:
	var index := _claim_index(owner)
	var old: int = _local_claims[index][1] if index >= 0 else -1
	if index >= 0:
		_local_claims.remove(index)
	if device >= 0:
		_local_claims.append([owner, device])
	if old != device:
		var what: String = "takes device %d" % device if device >= 0 else "gives up device %d" % old
		ModLoaderLog.info("Local device: %s %s (%s)" % [owner, what, reason], LOG_NAME)
	_apply_local_claims("%s: %s" % [owner, reason])


func local_device() -> int:
	return _local_buttons.device if _local_buttons != null else -1


func local_device_owner() -> String:
	return _local_claims[-1][0] if not _local_claims.empty() else ""


func _claim_index(owner: String) -> int:
	for i in _local_claims.size():
		if _local_claims[i][0] == owner:
			return i
	return -1


func _apply_local_claims(why: String) -> void:
	var device: int = _local_claims[-1][1] if not _local_claims.empty() else -1
	if local_device() == device:
		return
	if _local_buttons != null:
		_local_buttons.release_held()
		VirtualDevices.release_analog(_local_buttons.device)
		_local_buttons = null
	if device >= 0:
		_local_buttons = RemoteButtons.new(device)
		_local_buttons.blocked = 1 << VirtualDevices.PAUSE_INDEX
	last_local_change = why
	var live: String = "device %d" % device if device >= 0 else "nothing"
	ModLoaderLog.info("Local buttons drive %s (%s)" % [live, why], LOG_NAME)


# This client's own Esc menu is open (sync/pause_control.gd): the local buttons drive its slot
# device and nothing else; the host sees a player who lets go of everything.
func set_local_menu(device: int) -> void:
	if menu_device() == device:
		return
	ModLoaderLog.info("Esc menu device %d -> %d" % [menu_device(), device], LOG_NAME)
	if _menu_buttons != null:
		_menu_buttons.release_held()
		VirtualDevices.release_analog(_menu_buttons.device)
		_presses.resume(local_buttons())
	_menu_buttons = null
	if device >= 0:
		_menu_buttons = RemoteButtons.new(device)
		_menu_buttons.blocked = 1 << VirtualDevices.PAUSE_INDEX  # PauseControl polls pause
		_menu_presses = PressCounter.new()


func menu_device() -> int:
	return _menu_buttons.device if _menu_buttons != null else -1


func set_host_paused(owner: String, paused: bool) -> void:
	if paused == host_paused.has(owner):
		return
	ModLoaderLog.info("Host paused (%s): %s" % [owner, paused], LOG_NAME)
	if paused:
		host_paused[owner] = true
	else:
		host_paused.erase(owner)


func is_host_paused() -> bool:
	return not host_paused.empty()


static func held_while_paused_mask() -> int:
	return ((1 << VirtualDevices.BUTTON_ACTIONS.size()) - 1) & ~(1 << VirtualDevices.PAUSE_INDEX)


func _send_local_input() -> void:
	var host_id: int = session.transport.host_id
	if not session.peers.has(host_id) or not session.peers[host_id].ready:
		return
	session.send_unreliable(host_id, Protocol.Msg.INPUT, sample_local())


func sample_local() -> Array:
	_seq += 1
	var buttons := 0
	var move := Vector2.ZERO
	var aim := [0, Vector2.ZERO]
	if not local_input_blocked:
		buttons = local_buttons()
	if _menu_buttons != null:
		_menu_buttons.apply(buttons, _menu_presses.sample(buttons))
		buttons = 0
	elif not local_input_blocked:
		# A screen running here (level-up panels, shop) moves its cursor with the same keys and
		# stick: the character stands still, on the host and in this client's prediction.
		if _local_buttons == null:
			move = _local_movement()
		aim = LocalAim.sample(LocalAim.own_player(battle_client), InputService.using_gamepad)
	# The host is paused: presses go nowhere, none is kept for after (pause still resumes).
	var dropped := held_while_paused_mask() if is_host_paused() else 0
	var counts: int = _presses.sample(buttons, dropped)
	buttons &= ~dropped
	if _local_buttons != null:
		_local_buttons.apply(buttons, counts)
	var screen = _menu_buttons if _menu_buttons != null else _local_buttons
	_drive_stick_of(screen.device if screen != null else _menu_copy_device())
	var previous := redundant_moves(history, _seq)
	history.append([_seq, move])
	if history.size() > HISTORY_SIZE:
		history.pop_front()
	var flags: int = aim[0] | LocalAim.type_flags(VirtualDevices.local_player_type())
	return [_seq, move, aim[1], buttons, counts, flags, previous, OS.get_ticks_msec()]


# The moves of the up to REDUNDANCY inputs right before seq (oldest first), from [seq, move]
# pairs; only an unbroken run up to seq - 1, so the host can tell each one's seq by its place.
static func redundant_moves(inputs: Array, seq: int) -> PoolVector2Array:
	var moves := []
	var k := inputs.size() - 1
	while k >= 0 and moves.size() < REDUNDANCY and inputs[k][0] == seq - 1 - moves.size():
		moves.push_front(inputs[k][1])
		k -= 1
	return PoolVector2Array(moves)


func _drive_stick_of(device: int) -> void:
	if device != _stick_device and _stick_device >= 0:
		for pair in [["rjoy_left", "rjoy_right"], ["rjoy_up", "rjoy_down"]]:
			VirtualDevices.set_axis_pair(
				VirtualDevices.action(pair[0], _stick_device),
				VirtualDevices.action(pair[1], _stick_device),
				0.0
			)
	_stick_device = device
	if device >= 0:
		_drive_local_stick(device)


# Each player's panel on a copy of the host's selection screen scrolls its description with that
# player's right stick (CharacterPanelUI._process, ItemDescription._process).
func _menu_copy_device() -> int:
	if menu_puppet == null or menu_puppet.current() == null:
		return -1
	return CoopService.get_remapped_player_device(SharedScroll.own_player())


# A screen running here scrolls item descriptions, item lists and the stats sheet with its slot
# device's right stick (Utils.get_player_rjoy_vector).
func _drive_local_stick(device: int) -> void:
	var stick := Vector2.ZERO
	if not local_input_blocked:
		stick = Input.get_vector("rjoy_left", "rjoy_right", "rjoy_up", "rjoy_down")
	VirtualDevices.set_axis_pair(
		VirtualDevices.action("rjoy_left", device),
		VirtualDevices.action("rjoy_right", device),
		stick.x
	)
	VirtualDevices.set_axis_pair(
		VirtualDevices.action("rjoy_up", device), VirtualDevices.action("rjoy_down", device), stick.y
	)


# Mirrors PlayerMovementBehavior.get_movement(): the stronger of analog and digital input.
func _local_movement() -> Vector2:
	var analog := Input.get_vector(
		"analog_move_left", "analog_move_right", "analog_move_up", "analog_move_down"
	)
	var digital := Input.get_vector(
		"button_move_left", "button_move_right", "button_move_up", "button_move_down"
	)
	return analog if analog.length() > digital.length() else digital


# Held mask of BUTTON_ACTIONS. The left stick also counts as menu directions (the game turns it
# into ui_* actions only through its echo emulation, which a client doesn't run).
static func local_buttons() -> int:
	var buttons := 0
	for i in VirtualDevices.BUTTON_ACTIONS.size():
		if Input.is_action_pressed(VirtualDevices.BUTTON_ACTIONS[i]):
			buttons |= 1 << i
	for pad in Input.get_connected_joypads():
		var x := Input.get_joy_axis(pad, JOY_AXIS_0)
		var y := Input.get_joy_axis(pad, JOY_AXIS_1)
		var nav := ""
		if abs(x) > NAV_DEADZONE:
			nav = "ui_right" if x > 0 else "ui_left"
		elif abs(y) > NAV_DEADZONE:
			nav = "ui_down" if y > 0 else "ui_up"
		if nav != "":
			buttons |= 1 << VirtualDevices.BUTTON_ACTIONS.find(nav)
	return buttons


func blocked_mask() -> int:
	var mask := blocked_buttons
	for screen in blocked_by:
		mask |= int(blocked_by[screen])
	return mask


# INPUT_ACK: the newest input whose physics tick has run. Valid from this tick's _tick_movement
# up to the player's own _physics_process, the window in which battle_host.gd builds snapshots.
func last_applied_seq(steam_id: int) -> int:
	return _remote[steam_id].ack if _remote.has(steam_id) else 0


func last_pause_msec(device: int) -> int:
	for steam_id in _remote:
		if _remote[steam_id].buttons.device == device:
			return _remote[steam_id].buttons.last_pause_msec
	return -1


func _on_peer_ready(steam_id: int) -> void:
	if not session.is_host() or devices.has(steam_id):
		return
	_forget_unassigned_devices()
	var device := _free_device()
	if device < 0:
		ModLoaderLog.warning("No free virtual device for %s" % steam_id, LOG_NAME)
		return
	devices[steam_id] = device
	ModLoaderLog.info("Peer %s -> virtual device %s" % [steam_id, device], LOG_NAME)


func steam_id_of(device: int) -> int:
	for steam_id in devices:
		if devices[steam_id] == device:
			return steam_id
	return -1


func _on_peer_removed(steam_id: int) -> void:
	if not devices.has(steam_id):
		CoopService.bt_forget_player(steam_id)
		return
	var device: int = devices[steam_id]
	VirtualDevices.release_all(device)
	VirtualDevices.set_manual_aim(device, false)
	CoopService.bt_device_types.erase(device)
	_remote.erase(steam_id)
	_input_gaps.erase(steam_id)
	# Free the co-op slot only while players can still join; mid-run the slot waits for a rejoin,
	# and so does the player's colour pick.
	var assigned: bool = CoopService.is_device_assigned(device)
	if CoopService.listening_for_inputs or not assigned:
		CoopService.bt_forget_player(steam_id)
	if CoopService.listening_for_inputs and assigned:
		CoopService._remove_player(device)


func _on_lobby_ready(_lobby_id: int, _is_host: bool) -> void:
	CoopService.bt_set_lobby(true)


# A host leaving mid-run keeps the run: remote players' slots and their steam id -> device
# mapping stay, so the same friends get their characters back in a new lobby.
func _on_lobby_left() -> void:
	CoopService.bt_set_lobby(false)
	history.clear()
	_remote.clear()
	_input_gaps.clear()
	_local_claims.clear()
	_apply_local_claims("lobby left")
	set_local_menu(-1)
	blocked_buttons = 0
	blocked_by.clear()
	host_paused.clear()
	var was_host: bool = session.transport.was_host
	for steam_id in devices.keys():
		var device: int = devices[steam_id]
		VirtualDevices.release_all(device)
		VirtualDevices.set_manual_aim(device, false)
		if was_host and not CoopService.listening_for_inputs:
			if CoopService.is_device_assigned(device):
				continue
		elif CoopService.is_device_assigned(device):
			CoopService._remove_player(device)
		devices.erase(steam_id)


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type == Protocol.Msg.INPUT and session.is_host() and devices.has(steam_id):
		note_input_gap(steam_id, body)
		_apply_input(steam_id, body)


# 8 fields; a body of another shape is dropped whole.
func _apply_input(steam_id: int, body) -> void:
	if (
		typeof(body) != TYPE_ARRAY
		or body.size() != 8
		or typeof(body[0]) != TYPE_INT
		or typeof(body[1]) != TYPE_VECTOR2
		or typeof(body[2]) != TYPE_VECTOR2
		or typeof(body[3]) != TYPE_INT
		or typeof(body[4]) != TYPE_INT
		or typeof(body[5]) != TYPE_INT
		or typeof(body[6]) != TYPE_VECTOR2_ARRAY
		or body[6].size() > REDUNDANCY
		or typeof(body[7]) != TYPE_INT
		or not _finite(body[1])
	):
		return
	for move in body[6]:
		if not _finite(move):
			return
	var device: int = devices[steam_id]
	if not _remote.has(steam_id):
		_remote[steam_id] = {
			"seq": 0,
			"last_msec": 0,
			"released": false,
			"buttons": RemoteButtons.new(device),
			"queue": [],
			"applied": 0,
			"ack": 0,
			"move": Vector2.ZERO,
			"dropped_to": 0,
			"filled": 0,
			"caught_up": 0,
			"dropped": 0,
			"dropped_moving": 0,
			"next_log_msec": 0,
		}
	var state: Dictionary = _remote[steam_id]
	var previous: PoolVector2Array = body[6]
	for i in previous.size():
		# Usually already queued from its own packet; else it was lost or is late.
		if _queue_movement(state, body[0] - previous.size() + i, previous[i].clamped(1.0)):
			state.filled += 1
	_queue_movement(state, body[0], body[1].clamped(1.0))
	if body[0] <= state.seq:
		return  # stale / reordered: its movement may still be due, its buttons and aim are old
	var aim: Vector2 = body[2].clamped(1.0)
	VirtualDevices.set_axis_pair(
		VirtualDevices.action("rjoy_left", device),
		VirtualDevices.action("rjoy_right", device),
		aim.x
	)
	VirtualDevices.set_axis_pair(
		VirtualDevices.action("rjoy_up", device), VirtualDevices.action("rjoy_down", device), aim.y
	)
	VirtualDevices.set_manual_aim(device, bool(body[5] & LocalAim.FLAG_MANUAL))
	var player_type := LocalAim.flags_type(body[5])
	if player_type >= 0:
		CoopService.bt_set_device_type(device, player_type)
	state.buttons.blocked = blocked_mask()
	state.buttons.apply(body[3], body[4])
	state.seq = body[0]
	state.last_msec = OS.get_ticks_msec()
	state.released = false


static func _finite(v: Vector2) -> bool:
	return not (is_nan(v.x) or is_nan(v.y) or is_inf(v.x) or is_inf(v.y))


# In seq order, so a reordered packet still gets its tick if the next one hasn't taken it yet.
# Beyond MAX_BACKLOG the oldest goes. True when the input is new in the queue.
static func _queue_movement(state: Dictionary, seq: int, move: Vector2) -> bool:
	if seq <= state.applied or seq <= state.dropped_to:
		return false
	var queue: Array = state.queue
	var at := queue.size()
	while at > 0 and queue[at - 1][0] >= seq:
		if queue[at - 1][0] == seq:
			return false
		at -= 1
	queue.insert(at, [seq, move])
	if queue.size() > MAX_BACKLOG:
		_count_dropped(state, [queue.front()])
		state.dropped_to = queue.pop_front()[0]
		return at > 0
	return true


func _on_physics_frame() -> void:
	for steam_id in _remote:
		if devices.has(steam_id):
			_tick_movement(_remote[steam_id], devices[steam_id])
			_log_recovery(steam_id, _remote[steam_id])


# The input put on the device in the previous tick has been moved with: it becomes the ack.
# With nothing queued the player stands and the ack waits: repeating the last input would add a
# step the client never predicted. A backlog is caught up as extra steps, acked at once.
func _tick_movement(state: Dictionary, device: int) -> void:
	state.ack = state.applied
	var queue: Array = state.queue
	_skip_standing(queue)
	var extra := 0
	while extra < CATCH_UP_PER_TICK and queue.size() > MAX_WAITING + 1:
		var behind: Array = queue.pop_front()
		_extra_step(device, behind[1])
		state.applied = behind[0]
		state.ack = behind[0]
		state.caught_up += 1
		extra += 1
		_skip_standing(queue)
	if not queue.empty():
		var input: Array = queue.pop_front()
		state.applied = input[0]
		_set_move(state, device, input[1])
	elif state.move != Vector2.ZERO:
		_set_move(state, device, Vector2.ZERO)


# Catching up for free: skipping an input that doesn't move leaves the position the same.
static func _skip_standing(queue: Array) -> void:
	while queue.size() > 1 and queue[0][1] == Vector2.ZERO:
		queue.pop_front()


# One physics step outside the player's own _physics_process, the way Unit._physics_process
# moves a kinematic body (test_motion, then a slide), at the speed the client predicts with.
func _extra_step(device: int, move: Vector2) -> void:
	var player = _player_of(device)
	if player == null or move == Vector2.ZERO or get_tree().paused:
		return
	if player.dead or not player._can_move or player.mode != RigidBody2D.MODE_KINEMATIC:
		return
	var speed: float = player.get_move_speed() / float(Engine.iterations_per_second)
	var motion: Vector2 = move.normalized() * speed
	var result := Physics2DTestMotionResult.new()
	var colliding: bool = player.test_motion(motion, true, 0.08, result)
	var moved: Vector2 = result.motion
	player.global_position += result.motion
	if colliding:
		player.test_motion(motion.slide(result.collision_normal), true, 0.08, result)
		player.global_position += result.motion
		moved += result.motion
	player._on_moved(moved)


func _player_of(device: int) -> Node:
	var scene: Node = get_tree().current_scene
	var players = scene.get("_players") if scene != null else null
	if typeof(players) != TYPE_ARRAY:
		return null
	for i in min(players.size(), CoopService.connected_players.size()):
		if CoopService.connected_players[i][0] == device:
			var player = players[i]
			if is_instance_valid(player) and player is RigidBody2D and "dead" in player:
				return player
	return null


static func _set_move(state: Dictionary, device: int, move: Vector2) -> void:
	state.move = move
	VirtualDevices.set_axis_pair(
		VirtualDevices.action("analog_move_left", device),
		VirtualDevices.action("analog_move_right", device),
		move.x
	)
	VirtualDevices.set_axis_pair(
		VirtualDevices.action("analog_move_up", device),
		VirtualDevices.action("analog_move_down", device),
		move.y
	)


func _release_timed_out() -> void:
	var now := OS.get_ticks_msec()
	for steam_id in _remote:
		var state: Dictionary = _remote[steam_id]
		if not state.released and now - state.last_msec > INPUT_TIMEOUT_MSEC:
			VirtualDevices.release_analog(devices[steam_id])
			state.buttons.release_held()
			if not state.queue.empty():  # normally drained long before
				_count_dropped(state, state.queue)
				state.dropped_to = int(max(state.dropped_to, state.queue[-1][0]))
				state.queue.clear()
			state.move = Vector2.ZERO
			state.released = true


# Queued inputs the host never takes. Only the moving ones cost the client a correction: it
# predicted a step for them; a standing one moves neither side.
static func _count_dropped(state: Dictionary, inputs: Array) -> void:
	state.dropped += inputs.size()
	for input in inputs:
		if input[1] != Vector2.ZERO:
			state.dropped_moving += 1


# host: one line when missing inputs were filled in, a backlog was caught up or moving inputs
# were dropped, once the queue is back to normal. Dropped standing inputs alone cost nothing.
func _log_recovery(steam_id: int, state: Dictionary) -> void:
	if state.filled + state.caught_up + state.dropped_moving == 0:
		state.dropped = 0
		return
	var now := OS.get_ticks_msec()
	if state.queue.size() > MAX_WAITING + 1 or now < state.next_log_msec:
		return
	state.next_log_msec = now + RECOVERY_LOG_INTERVAL_MSEC
	last_recovery_line = (
		"Input from %s: %d missing input(s) filled in from later packets, %d step(s) caught up"
		% [steam_id, state.filled, state.caught_up]
		+ (
			", %d dropped, %d of them moving (corrected on the client)"
			% [state.dropped, state.dropped_moving]
		)
	)
	ModLoaderLog.info(last_recovery_line, LOG_NAME)
	state.filled = 0
	state.caught_up = 0
	state.dropped = 0
	state.dropped_moving = 0


# The client's clock at sending (field 7) and the seq tell its own stalls from inputs held up or
# lost on the way. Called before _apply_input, so the line can say the timeout released the player.
func note_input_gap(steam_id: int, body) -> void:
	if (
		typeof(body) != TYPE_ARRAY
		or body.size() != 8
		or typeof(body[0]) != TYPE_INT
		or typeof(body[7]) != TYPE_INT
	):
		return
	if not _input_gaps.has(steam_id):
		var gaps = StreamGaps.new("input from %s" % steam_id)
		gaps.step_msec = 1000.0 / Engine.iterations_per_second
		gaps.redundancy = REDUNDANCY
		_input_gaps[steam_id] = gaps
	var released: bool = _remote.has(steam_id) and _remote[steam_id].released
	var extra := "; buttons released" if released else ""
	_input_gaps[steam_id].note(session, steam_id, body[7], LOG_NAME, extra, false, body[0])


# Mappings kept from an earlier lobby (see _on_lobby_left) only matter while their slot exists.
func _forget_unassigned_devices() -> void:
	for steam_id in devices.keys():
		if not session.peers.has(steam_id) and not CoopService.is_device_assigned(devices[steam_id]):
			devices.erase(steam_id)
			CoopService.bt_forget_player(steam_id)


func _free_device() -> int:
	var used := devices.values()
	for device in range(VirtualDevices.FIRST, VirtualDevices.FIRST + VirtualDevices.COUNT):
		if not used.has(device):
			return device
	return -1
