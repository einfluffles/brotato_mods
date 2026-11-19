extends "res://singletons/input_service.gd"
# Virtual device actions are registered again whenever the game rebuilds its per-device InputMap.
# On a client (one local player whose input goes to the host) the local co-op handling would get
# in the way: pad vs. mouse use is tracked as in solo play, and no local ui_* echo is emulated
# (it would stay pressed: the client sends held buttons and the host repeats them itself).

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)

var virtual_echo_enabled := true


func _copy_device_actions():
	._copy_device_actions()
	VirtualDevices.register_actions()


func set_gamepad_echo_processing(enable: bool) -> void:
	virtual_echo_enabled = enable
	.set_gamepad_echo_processing(enable)


func is_virtual_echo_enabled() -> bool:
	return virtual_echo_enabled and not _disable_input


# Godot 3 runs the game's _input right after this one (multilevel call). In co-op it hides the
# mouse on every event, so showing it again is deferred.
func _input(event: InputEvent) -> void:
	if not VirtualDevices.is_client_mode():
		return
	var is_gamepad_input: bool = (
		event is InputEventJoypadButton
		or Utils.is_valid_joypad_motion_event(event)
	)
	var is_mouse_input := event is InputEventMouseMotion or event is InputEventMouseButton
	if is_gamepad_input:
		using_gamepad = true
	elif event is InputEventKey or is_mouse_input:
		using_gamepad = false
	if is_mouse_input:
		Input.call_deferred("set_mouse_mode", Input.MOUSE_MODE_VISIBLE)


func _emulate_action(device: int, input, action: String) -> void:
	if VirtualDevices.is_client_mode():
		return
	._emulate_action(device, input, action)
