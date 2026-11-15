extends Node
# Client: sample local input every physics frame and send it to the host (unreliable and
# state-based, so a lost packet only delays; button presses also travel as counters, see
# press_counter.gd). Host: apply each peer's input to that peer's virtual device
# (remote_buttons.gd: edges, pause, menu echo).

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
const LOG_NAME := "einfluffles-BrotatoTogether:InputSync"
const INPUT_TIMEOUT_MSEC := 300
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

# client
var _seq := 0
var _presses = PressCounter.new()
# client: this player's own slot device while a screen runs locally (see set_local_device)
var _local_buttons = null
# client: the same for its own Esc menu during a wave (see set_local_menu); the host gets
# neutral input meanwhile
var _menu_buttons = null
var _menu_presses = PressCounter.new()

# host: steam_id -> {seq, last_msec, released, buttons: RemoteButtons}
var _remote := {}


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("peer_ready", self, "_on_peer_ready")
	session.connect("peer_removed", self, "_on_peer_removed")
	session.connect("message", self, "_on_message")
	session.transport.connect("lobby_left", self, "_on_lobby_left")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	VirtualDevices.register_actions()


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
# (RemoteButtons: counted edges, menu echo). -1 turns it off. Pause always goes to the host.
func set_local_device(device: int) -> void:
	if _local_buttons != null:
		if _local_buttons.device == device:
			return
		_local_buttons.release_held()
		_local_buttons = null
	if device >= 0:
		_local_buttons = RemoteButtons.new(device)
		_local_buttons.blocked = 1 << VirtualDevices.PAUSE_INDEX


# This client's own Esc menu is open (sync/pause_control.gd): the local buttons drive its slot
# device and nothing else; the host sees a player who lets go of everything. -1 turns it off.
func set_local_menu(device: int) -> void:
	if menu_device() == device:
		return
	if _menu_buttons != null:
		_menu_buttons.release_held()
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
		move = _local_movement()
		aim = LocalAim.sample(LocalAim.own_player(battle_client), InputService.using_gamepad)
	var counts: int = _presses.sample(buttons)
	if _local_buttons != null:
		_local_buttons.apply(buttons, counts)
	history.append([_seq, move])
	if history.size() > HISTORY_SIZE:
		history.pop_front()
	return [_seq, move, aim[1], buttons, counts, aim[0]]


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


func last_applied_seq(steam_id: int) -> int:
	return _remote[steam_id].seq if _remote.has(steam_id) else 0


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
	set_local_device(-1)
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
			"seq": 0, "last_msec": 0, "released": false, "buttons": RemoteButtons.new(device)
		}
	var state: Dictionary = _remote[steam_id]
	if body[0] <= state.seq:
		return  # stale / reordered
	var move: Vector2 = body[1].clamped(1.0)
	var aim: Vector2 = body[2].clamped(1.0)
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


# Never leave a remote player running into a wall because their packets stopped.
func _release_timed_out() -> void:
	var now := OS.get_ticks_msec()
	for steam_id in _remote:
		var state: Dictionary = _remote[steam_id]
		if not state.released and now - state.last_msec > INPUT_TIMEOUT_MSEC:
			VirtualDevices.release_analog(devices[steam_id])
			state.buttons.release_held()
			state.released = true


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
