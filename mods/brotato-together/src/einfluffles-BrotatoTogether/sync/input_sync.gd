extends Node
# Client: sample local input every physics frame and send it to the host (unreliable and
# state-based, so a lost packet only delays; button presses also travel as counters, see
# press_counter.gd). Host: apply each peer's input to that peer's virtual device
# (remote_buttons.gd: edges, pause, menu echo).
#
# Movement is the one part a client predicts (battle_client.gd _own_target: the host's position
# plus one physics step per input newer than the snapshot's INPUT_ACK). So the host moves a remote
# player by exactly one input per physics tick, and the ack names the newest input whose tick has
# run. Packets don't arrive one per tick (jitter bunches them, or a tick gets none), so the host
# queues them (see _tick_movement). Aim and buttons are not predicted and stay newest-wins, applied
# on arrival: no added delay, and the press counters already cover lost or bunched presses.

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
const StreamGaps := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/stream_gaps.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:InputSync"
const INPUT_TIMEOUT_MSEC := 300
# host: queued inputs beyond the one the next tick takes. Each one delays this player on the host
# by a tick; jitter rarely leaves more than one, more only piles up after a stall.
const MAX_WAITING := 2
const HISTORY_SIZE := 180  # 3 s at 60 Hz
const NAV_DEADZONE := 0.5  # InputService.joystick_deadzone (left stick -> menu directions)

var session: Node = null
var battle_client: Node = null  # client: own player position for mouse aim
# host: steam_id -> device. Kept for the whole lobby so a rejoining player gets the same
# device and therefore the same co-op slot.
var devices := {}

# client: recent [seq, move] pairs, replayed on top of the host's position for prediction
var history := []
# client: the lobby popup is open and owns the keyboard/pad; the host gets neutral input
var local_input_blocked := false
# host: BUTTON_ACTIONS bits not delivered to remote players' virtual devices. Set while a
# screen runs on the clients themselves and sends its decisions as messages (level-up panels,
# sync/upgrades_sync.gd): a remote accept must not also press the host's copy of the panel.
var blocked_buttons := 0
# host: more masks of that kind, one per screen (key: its name), so that two screens never
# overwrite each other's block (the shop, sync/shop_sync.gd). OR-ed with blocked_buttons.
var blocked_by := {}
# client: what last switched the local buttons ("owner: reason"), for the logs
var last_local_change := ""

# client
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

# host: steam_id -> {seq, last_msec, released, buttons: RemoteButtons, queue: [[seq, move]...],
# applied, ack, move} (see _apply_input, _tick_movement)
var _remote := {}
# host: steam_id -> StreamGaps of its INPUT stream (logs the stalls)
var _input_gaps := {}


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("peer_ready", self, "_on_peer_ready")
	session.connect("peer_removed", self, "_on_peer_removed")
	session.connect("message", self, "_on_message")
	session.transport.connect("lobby_left", self, "_on_lobby_left")


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


# --- client ---


# A screen that runs on this client itself (its own cursor, pages, popups): the local buttons
# also drive this player's slot device here, exactly as the host applies a remote player's
# (RemoteButtons: counted edges, menu echo). Pause always goes to the host.
# owner names the screen ("shop", "upgrades"). Each one claims the device for itself, and -1
# gives up only its own claim: one screen never switches off another screen's input (the level-up
# panels' late stop used to turn off the shop's). The newest claim drives; claiming again, also
# with the same device, makes it the newest. reason goes to the log.
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


# The device the local buttons drive now (-1: none).
func local_device() -> int:
	return _local_buttons.device if _local_buttons != null else -1


# The screen whose claim drives the local device ("" for none).
func local_device_owner() -> String:
	return _local_claims[-1][0] if not _local_claims.empty() else ""


func _claim_index(owner: String) -> int:
	for i in _local_claims.size():
		if _local_claims[i][0] == owner:
			return i
	return -1


# The local buttons follow the newest claim (also when something else had cleared them).
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
# device and nothing else; the host sees a player who lets go of everything. -1 turns it off.
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


func _send_local_input() -> void:
	var host_id: int = session.transport.host_id
	if not session.peers.has(host_id) or not session.peers[host_id].ready:
		return
	session.send_unreliable(host_id, Protocol.Msg.INPUT, sample_local())


# One INPUT body from what the local player holds now; also feeds the screens that run here.
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
	var counts: int = _presses.sample(buttons)
	if _local_buttons != null:
		_local_buttons.apply(buttons, counts)
	var screen = _menu_buttons if _menu_buttons != null else _local_buttons
	if screen != null:
		_drive_local_stick(screen.device)
	history.append([_seq, move])
	if history.size() > HISTORY_SIZE:
		history.pop_front()
	return [_seq, move, aim[1], buttons, counts, aim[0]]


# A screen running here scrolls item descriptions, item lists and the stats sheet with its slot
# device's right stick (Utils.get_player_rjoy_vector), which only the host's copy got before (as
# the INPUT's aim): give the local slot device this player's right stick too.
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


# --- host ---


func blocked_mask() -> int:
	var mask := blocked_buttons
	for screen in blocked_by:
		mask |= int(blocked_by[screen])
	return mask


# INPUT_ACK: the newest input whose physics tick has run, so the player's position holds one step
# for each input up to it and none for later ones. Valid from this tick's _tick_movement up to
# the player's own _physics_process: battle_host.gd builds snapshots in that window (its node sits
# under the ModLoader autoload, before the battle scene in the physics order).
func last_applied_seq(steam_id: int) -> int:
	return _remote[steam_id].ack if _remote.has(steam_id) else 0


# msec timestamp of the last pause press delivered for this device (-1: none).
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


func _on_peer_removed(steam_id: int) -> void:
	if not devices.has(steam_id):
		return
	var device: int = devices[steam_id]
	VirtualDevices.release_all(device)
	VirtualDevices.set_manual_aim(device, false)
	_remote.erase(steam_id)
	_input_gaps.erase(steam_id)
	# Free the co-op slot only while players can still join; mid-run the slot waits for a rejoin.
	if CoopService.listening_for_inputs and CoopService.is_device_assigned(device):
		CoopService._remove_player(device)


# Host leaving mid-run keeps the run: remote players' slots stay (idle, like a local pad
# unplugged mid-run in the base game) and so does their steam id -> device mapping, so the same
# friends get their own characters back if the host opens a new lobby. Before the run starts
# (players can still join) their slots go away.
func _on_lobby_left() -> void:
	history.clear()
	_remote.clear()
	_input_gaps.clear()
	_local_claims.clear()
	_apply_local_claims("lobby left")
	set_local_menu(-1)
	blocked_buttons = 0
	blocked_by.clear()
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


func _apply_input(steam_id: int, body) -> void:
	if (
		typeof(body) != TYPE_ARRAY
		or body.size() != 6
		or typeof(body[0]) != TYPE_INT
		or typeof(body[1]) != TYPE_VECTOR2
		or typeof(body[2]) != TYPE_VECTOR2
		or typeof(body[3]) != TYPE_INT
		or typeof(body[4]) != TYPE_INT
		or typeof(body[5]) != TYPE_INT
	):
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
		}
	var state: Dictionary = _remote[steam_id]
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
	state.buttons.blocked = blocked_mask()
	state.buttons.apply(body[3], body[4])
	state.seq = body[0]
	state.last_msec = OS.get_ticks_msec()
	state.released = false


# In seq order, so a reordered packet still gets its tick if the next one hasn't taken it yet; a
# duplicate or an input whose turn went by is dropped. Beyond MAX_WAITING + 1 the oldest goes:
# the client predicted a step the host then never takes (a one-off correction, as for a lost
# packet), instead of a lasting delay.
static func _queue_movement(state: Dictionary, seq: int, move: Vector2) -> void:
	if seq <= state.applied:
		return
	var queue: Array = state.queue
	var at := queue.size()
	while at > 0 and queue[at - 1][0] >= seq:
		if queue[at - 1][0] == seq:
			return
		at -= 1
	queue.insert(at, [seq, move])
	if queue.size() > MAX_WAITING + 1:
		queue.pop_front()


func _on_physics_frame() -> void:
	for steam_id in _remote:
		if devices.has(steam_id):
			_tick_movement(_remote[steam_id], devices[steam_id])


# One remote player's movement for the physics tick that starts now. The input put on the device
# in the previous tick has been moved with (or the world was paused, then neither side moved for
# it): it becomes the ack. Then this tick takes the oldest queued input.
# With none queued, the player stands still for this tick and the ack waits. Repeating the last
# input instead would look smoother on the host, but the client counts no step for it: when the
# late input then differs (above all a stop), its own player gets pulled. Standing still keeps
# the client's replay exact; the late input gets the next tick, and the queue it leaves behind
# absorbs the next bit of jitter (it drains while the player stands, see below).
func _tick_movement(state: Dictionary, device: int) -> void:
	state.ack = state.applied
	var queue: Array = state.queue
	# Catching up for free: skipping an input that doesn't move leaves the position the same.
	while queue.size() > 1 and queue[0][1] == Vector2.ZERO:
		queue.pop_front()
	if not queue.empty():
		var input: Array = queue.pop_front()
		state.applied = input[0]
		_set_move(state, device, input[1])
	elif state.move != Vector2.ZERO:
		_set_move(state, device, Vector2.ZERO)


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


# Never leave a remote player running into a wall because their packets stopped.
func _release_timed_out() -> void:
	var now := OS.get_ticks_msec()
	for steam_id in _remote:
		var state: Dictionary = _remote[steam_id]
		if not state.released and now - state.last_msec > INPUT_TIMEOUT_MSEC:
			VirtualDevices.release_analog(devices[steam_id])
			state.buttons.release_held()
			state.queue.clear()
			state.move = Vector2.ZERO
			state.released = true


# Host: a stall in a client's INPUT stream is logged (sync/stream_gaps.gd); the seq counts the
# client's physics steps, which gives the time it sent them at.
func note_input_gap(steam_id: int, body) -> void:
	if typeof(body) != TYPE_ARRAY or body.empty() or typeof(body[0]) != TYPE_INT:
		return
	if not _input_gaps.has(steam_id):
		_input_gaps[steam_id] = StreamGaps.new("input from %s" % steam_id)
	var sent_msec: int = body[0] * 1000 / Engine.iterations_per_second
	_input_gaps[steam_id].note(session, steam_id, sent_msec, LOG_NAME)


# Mappings kept from an earlier lobby (see _on_lobby_left) only matter while their slot exists.
func _forget_unassigned_devices() -> void:
	for steam_id in devices.keys():
		if not session.peers.has(steam_id) and not CoopService.is_device_assigned(devices[steam_id]):
			devices.erase(steam_id)


func _free_device() -> int:
	var used := devices.values()
	for device in range(VirtualDevices.FIRST, VirtualDevices.FIRST + VirtualDevices.COUNT):
		if not used.has(device):
			return device
	return -1
