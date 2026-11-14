extends Node
# Client: sample local input every physics frame and send it to the host (unreliable and
# state-based, so a lost packet only delays). Host: apply each peer's input to that peer's
# virtual device.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:InputSync"
const INPUT_TIMEOUT_MSEC := 300
const HISTORY_SIZE := 180  # 3 s at 60 Hz

var session: Node = null
# host: steam_id -> device. Kept for the whole lobby so a rejoining player gets the same
# device and therefore the same co-op slot.
var devices := {}

# client: recent [seq, move] pairs, replayed on top of the host's position for prediction
var history := []

# client
var _seq := 0

# host: steam_id -> {seq, buttons, last_msec, released}
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
	if session.is_client():
		_send_local_input()
	elif session.is_host():
		_release_timed_out()


# --- client ---


func _send_local_input() -> void:
	var host_id: int = session.transport.host_id
	if not session.peers.has(host_id) or not session.peers[host_id].ready:
		return
	_seq += 1
	var buttons := 0
	for i in VirtualDevices.BUTTON_ACTIONS.size():
		if Input.is_action_pressed(VirtualDevices.BUTTON_ACTIONS[i]):
			buttons |= 1 << i
	var move := _local_movement()
	session.send_unreliable(host_id, Protocol.Msg.INPUT, [_seq, move, _local_aim(), buttons])
	history.append([_seq, move])
	if history.size() > HISTORY_SIZE:
		history.pop_front()


# Mirrors PlayerMovementBehavior.get_movement(): the stronger of analog and digital input.
func _local_movement() -> Vector2:
	var analog := Input.get_vector(
		"analog_move_left", "analog_move_right", "analog_move_up", "analog_move_down"
	)
	var digital := Input.get_vector(
		"button_move_left", "button_move_right", "button_move_up", "button_move_down"
	)
	return analog if analog.length() > digital.length() else digital


func _local_aim() -> Vector2:
	return Input.get_vector("rjoy_left", "rjoy_right", "rjoy_up", "rjoy_down")


# --- host ---


func last_applied_seq(steam_id: int) -> int:
	return _remote[steam_id].seq if _remote.has(steam_id) else 0


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
	var was_host: bool = session.transport.was_host
	for steam_id in devices.keys():
		var device: int = devices[steam_id]
		VirtualDevices.release_all(device)
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
		or body.size() != 4
		or typeof(body[0]) != TYPE_INT
		or typeof(body[1]) != TYPE_VECTOR2
		or typeof(body[2]) != TYPE_VECTOR2
		or typeof(body[3]) != TYPE_INT
	):
		return
	var state: Dictionary = _remote.get(steam_id, {"seq": 0, "buttons": 0})
	if body[0] <= state.seq:
		return  # stale / reordered
	var device: int = devices[steam_id]
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
	var changed: int = state.buttons ^ body[3]
	for i in VirtualDevices.BUTTON_ACTIONS.size():
		if changed & (1 << i):
			VirtualDevices.press_button(
				VirtualDevices.action(VirtualDevices.BUTTON_ACTIONS[i], device),
				device,
				bool(body[3] & (1 << i))
			)
	_remote[steam_id] = {
		"seq": body[0], "buttons": body[3], "last_msec": OS.get_ticks_msec(), "released": false
	}


# Never leave a remote player running into a wall because their packets stopped.
func _release_timed_out() -> void:
	var now := OS.get_ticks_msec()
	for steam_id in _remote:
		var state: Dictionary = _remote[steam_id]
		if not state.released and now - state.last_msec > INPUT_TIMEOUT_MSEC:
			VirtualDevices.release_all(devices[steam_id])
			state.buttons = 0
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
