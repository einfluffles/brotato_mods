extends "res://singletons/utils.gd"
# Remote players are typed as gamepads, so the game would apply the host's manual-aim setting to
# them. Their own client decides instead (sent with every INPUT, see sync/local_aim.gd).

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)


func is_manual_aim(player_index: int) -> bool:
	if RunData.is_coop_run:
		var device: int = CoopService.get_remapped_player_device(player_index)
		if VirtualDevices.is_virtual(device):
			return VirtualDevices.is_manual_aim(device)
	return .is_manual_aim(player_index)
