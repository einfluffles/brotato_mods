extends "res://singletons/input_service.gd"
# Re-register virtual device actions every time the game rebuilds its per-device InputMap.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)


func _copy_device_actions():
	._copy_device_actions()
	VirtualDevices.register_actions()
