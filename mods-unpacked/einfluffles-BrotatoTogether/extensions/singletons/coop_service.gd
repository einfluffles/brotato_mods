extends "res://singletons/coop_service.gd"
# Remote players join through the normal hold-to-join flow on their virtual device. The game
# would type them as keyboard (no joypad name) — force a gamepad type so stick aim and gamepad
# UI hints apply.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)


func _add_player(device: int, player_type: int) -> void:
	if VirtualDevices.is_virtual(device):
		player_type = PlayerType.GAMEPAD_XBOX
	._add_player(device, player_type)
