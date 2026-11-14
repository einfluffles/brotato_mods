extends Reference
# Virtual (networked) input devices on the host. Each remote player gets one remapped device id;
# the game reads it through the same device-suffixed InputMap actions it uses for local co-op
# ("ui_accept_12", ...).
# Ids 0..7 are the game's remapped devices, 8..11 its debug devices (CoopService constants).

const FIRST := 12
const COUNT := 4

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

# Order defines the bit index in the INPUT message's button mask — append only.
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

# Exist so the game's per-device lookups never hit a missing action; never pressed.
const UNUSED_ACTIONS := [
	"button_move_left",
	"button_move_right",
	"button_move_up",
	"button_move_down",
]


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


# Client puppet runs (battle, shop): the scenes spawn players from CoopService.connected_players,
# so give them one slot per host player. Cleared again when the client leaves the lobby.
static func fill_puppet_slots(count: int) -> void:
	CoopService.connected_players.clear()
	for i in count:
		CoopService.connected_players.push_back([FIRST + i, CoopService.PlayerType.GAMEPAD_XBOX])


static func release_all(device: int) -> void:
	for base in ANALOG_ACTIONS:
		Input.action_release(action(base, device))
	for base in BUTTON_ACTIONS:
		var name := action(base, device)
		if Input.is_action_pressed(name):
			press_button(name, device, false)


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
