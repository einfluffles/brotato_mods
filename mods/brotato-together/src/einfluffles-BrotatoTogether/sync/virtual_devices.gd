extends Reference
# Virtual (networked) input devices on the host: each remote player gets one remapped device id,
# read by the game through its device-suffixed InputMap actions ("ui_accept_12", ...).
# Ids 0..7 are the game's remapped devices, 8..11 its debug devices (CoopService constants).

const FIRST := 12
const COUNT := 4
# Nobody presses this one: a player whose movement reads it stands still (sync/pause_control.gd).
const IDLE := FIRST + COUNT
const CLIENT_MODE_META := "brotato_together_client"
const MANUAL_AIM_META := "brotato_together_manual_aim"

const ANALOG_ACTIONS := [
	"analog_move_left",
	"analog_move_right",
	"analog_move_up",
	"analog_move_down",
	"rjoy_left",
	"rjoy_right",
	"rjoy_up",
	"rjoy_down",
]

# Order defines the bit index in the INPUT message's button mask: append only.
const BUTTON_ACTIONS := [
	"ui_accept",
	"ui_select",
	"ui_cancel",
	"ui_info",
	"ui_pause",
	"ui_ban",
	"ui_left",
	"ui_right",
	"ui_up",
	"ui_down",
	"ltrigger",
	"rtrigger",
]

# Indices into BUTTON_ACTIONS.
const PAUSE_INDEX := 4
const NAV_INDICES := [6, 7, 8, 9]  # ui_left/right/up/down: repeated while held (echo)

# Exist so the game's per-device lookups never hit a missing action; never pressed.
const UNUSED_ACTIONS := [
	"button_move_left",
	"button_move_right",
	"button_move_up",
	"button_move_down",
]

# Words in a pad's name -> CoopService.PlayerType (2: PlayStation, 3: Switch; else Xbox).
const PAD_BRANDS := {
	"ps4": 2, "ps5": 2, "playstation": 2, "dualsense": 2, "nintendo": 3, "switch": 3
}


static func is_virtual(device: int) -> bool:
	return device >= FIRST and device < FIRST + COUNT


static func action(base: String, device: int) -> String:
	return "%s_%s" % [base, device]


# Idempotent. Must run again after InputService wipes the InputMap (load_from_globals).
static func register_actions() -> void:
	for device in range(FIRST, FIRST + COUNT):
		for base in ANALOG_ACTIONS + BUTTON_ACTIONS + UNUSED_ACTIONS:
			var name := action(base, device)
			if not InputMap.has_action(name):
				# Deadzone 0: the client already applied its own deadzone.
				InputMap.add_action(name, 0.0)
	for base in ANALOG_ACTIONS + UNUSED_ACTIONS:
		if not InputMap.has_action(action(base, IDLE)):
			InputMap.add_action(action(base, IDLE), 0.0)


# Host: the remote player's own aim preference (Utils.is_manual_aim for virtual devices).
static func set_manual_aim(device: int, manual: bool) -> void:
	var by_device := {}
	if Engine.has_meta(MANUAL_AIM_META):
		by_device = Engine.get_meta(MANUAL_AIM_META)
	by_device[device] = manual
	Engine.set_meta(MANUAL_AIM_META, by_device)


static func is_manual_aim(device: int) -> bool:
	return Engine.has_meta(MANUAL_AIM_META) and Engine.get_meta(MANUAL_AIM_META).get(device, false)


# Set while this game is a client of a brotato:together lobby: its one local player's input goes
# to the host, so local co-op input handling (mouse hiding, menu echo) must not apply.
static func set_client_mode(active: bool) -> void:
	Engine.set_meta(CLIENT_MODE_META, active)


static func is_client_mode() -> bool:
	return Engine.has_meta(CLIENT_MODE_META) and Engine.get_meta(CLIENT_MODE_META)


# Client puppet runs (battle, shop): the scenes spawn players from CoopService.connected_players,
# so give them one slot per host player. Cleared again when the client leaves the lobby.
static func fill_puppet_slots(count: int) -> void:
	CoopService.connected_players.clear()
	for i in count:
		CoopService.connected_players.push_back([FIRST + i, CoopService.PlayerType.GAMEPAD_XBOX])


# Client: every puppet slot starts as a gamepad; its own slot follows the device its player
# really uses while a screen runs locally (sync/local_panel.gd). Returns whether it changed.
static func set_slot_type(player_index: int, player_type: int) -> bool:
	var players: Array = CoopService.connected_players
	if player_index < 0 or player_index >= players.size():
		return false
	if players[player_index][1] == player_type:
		return false
	players[player_index][1] = player_type
	return true


# The PlayerType of a real pad, from its name: the brands the game has glyphs for.
static func pad_type(joy_device: int) -> int:
	var name := Input.get_joy_name(joy_device).to_lower()
	for brand in PAD_BRANDS:
		if brand in name:
			return PAD_BRANDS[brand]
	return CoopService.PlayerType.GAMEPAD_XBOX


# Client: the PlayerType of what its one local player used last (InputService tracks pad vs.
# keyboard / mouse in client mode).
static func local_player_type() -> int:
	if not InputService.using_gamepad:
		return CoopService.PlayerType.KEYBOARD_AND_MOUSE
	var pads := Input.get_connected_joypads()
	return pad_type(pads[0] if not pads.empty() else 0)


static func release_all(device: int) -> void:
	release_analog(device)
	for base in BUTTON_ACTIONS:
		var name := action(base, device)
		if Input.is_action_pressed(name):
			press_button(name, device, false)


static func release_analog(device: int) -> void:
	for base in ANALOG_ACTIONS:
		Input.action_release(action(base, device))


# Button edges go through the event pipeline so FocusEmulators and screen _input handlers see them.
static func press_button(action_name: String, device: int, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = pressed
	event.strength = 1.0 if pressed else 0.0
	# CoopService._input treats device 0 as the keyboard; tag the event with our device.
	event.device = device
	Input.parse_input_event(event)


# Analog values are state only (Input.get_vector reads action strengths).
static func set_axis_pair(negative: String, positive: String, value: float) -> void:
	_set_strength(negative, max(0.0, -value))
	_set_strength(positive, max(0.0, value))


static func _set_strength(action_name: String, strength: float) -> void:
	if strength > 0.0:
		Input.action_press(action_name, min(strength, 1.0))
	else:
		Input.action_release(action_name)
