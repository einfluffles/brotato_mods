extends "res://singletons/utils.gd"
# Remote players are typed as gamepads, so the game would apply the host's manual-aim setting to
# them. Their own client decides instead (sent with every INPUT, see sync/local_aim.gd).

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)


# By the slot's own type: a remote player aims with the stick its client sends, whatever its key
# hints show (CoopService.get_player_input_type).
func is_player_using_gamepad(player_index: int) -> bool:
	if RunData.is_coop_run and not on_console:
		return CoopService.bt_slot_uses_gamepad(player_index)
	return .is_player_using_gamepad(player_index)


func is_manual_aim(player_index: int) -> bool:
	if RunData.is_coop_run:
		var device: int = CoopService.get_remapped_player_device(player_index)
		if VirtualDevices.is_virtual(device):
			return VirtualDevices.is_manual_aim(device)
	return .is_manual_aim(player_index)
