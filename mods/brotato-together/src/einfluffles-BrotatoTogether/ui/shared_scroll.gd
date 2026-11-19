extends Reference
# A grid that several cursors share (co-op character selection) scrolls after this machine's
# own players' cursors only. The game scrolls it for every cursor
# (FocusEmulator._ensure_control_visible), which is right on one shared screen only.
# Names no game classes: the FocusEmulator extension preloads it at mod init.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
# Client: the player slot of this machine's player on the host's screen (-1: none).
const OWN_PLAYER_META := "brotato_together_own_player"


static func set_own_player(player_index: int) -> void:
	Engine.set_meta(OWN_PLAYER_META, player_index)


static func clear_own_player() -> void:
	if Engine.has_meta(OWN_PLAYER_META):
		Engine.remove_meta(OWN_PLAYER_META)


static func own_player() -> int:
	var own = Engine.get_meta(OWN_PLAYER_META) if Engine.has_meta(OWN_PLAYER_META) else -1
	return own if typeof(own) == TYPE_INT else -1


# Whether emulator's cursor may scroll scroll (the ScrollContainer around its control).
static func follows(emulator: Node, scroll: Node) -> bool:
	return is_local_player(emulator.player_index) or not is_shared(emulator, scroll)


# While none of this machine's players has joined, every cursor counts as local.
static func is_local_player(player_index: int) -> bool:
	var players: Array = CoopService.connected_players
	if player_index < 0 or player_index >= players.size():
		return true
	if Puppet.is_active():
		var own := own_player()
		return own == player_index or own < 0 or own >= players.size()
	if not VirtualDevices.is_virtual(players[player_index][0]):
		return true
	for player in players:
		if not VirtualDevices.is_virtual(player[0]):
			return false
	return true


# Another FocusEmulator of the same menu reaches into scroll (one of its focus bases is scroll,
# inside it or around it).
static func is_shared(emulator: Node, scroll: Node) -> bool:
	var parent := emulator.get_parent()
	if parent == null:
		return false
	for other in parent.get_children():
		if other == emulator or not other.has_method("_ensure_control_visible"):
			continue
		var bases = other.get("_focus_base_nodes")
		if not (bases is Array):
			continue
		for base in bases:
			if not (base is Node) or not is_instance_valid(base):
				continue
			if base == scroll or scroll.is_a_parent_of(base) or base.is_a_parent_of(scroll):
				return true
	return false
