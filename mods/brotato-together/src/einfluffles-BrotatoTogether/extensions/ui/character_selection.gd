extends "res://ui/menus/run/character_selection.gd"
# A client's copy of the host's character selection (sync/menu_puppet.gd) shows the host's
# elements and decides nothing: selections, zone, run options and who joins are the host's
# (mirrored from its state), and this machine's settings are not written.

const PuppetMenu := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet_menu.gd"
)

var _bt_slot_devices := []  # device per slot at the last change of the players


# A player who leaves takes its pick along. The game keeps a slot's pick (_has_player_selected,
# _player_characters), so whoever takes the slot next (a rejoin, a player moving up) would start
# locked in on it, with that character. Cleared from the first slot that changed on; a client's
# copy shows the host's picks.
func _on_connected_players_updated(connected_players: Array, initialize: bool) -> void:
	var devices := []
	for player in connected_players:
		devices.append(player[0])
	if not initialize and not PuppetMenu.Puppet.is_active():
		var first := 0
		while (
			first < devices.size()
			and first < _bt_slot_devices.size()
			and devices[first] == _bt_slot_devices[first]
		):
			first += 1
		for p in range(first, min(_bt_slot_devices.size(), _has_player_selected.size())):
			_clear_selected_element(p)
	_bt_slot_devices = devices
	._on_connected_players_updated(connected_players, initialize)


func _get_all_possible_elements(player_index: int) -> Array:
	var elements = PuppetMenu.elements(player_index)
	return elements if elements != null else ._get_all_possible_elements(player_index)


func _get_unlocked_elements(player_index: int) -> Array:
	var unlocked = PuppetMenu.unlocked(player_index)
	return unlocked if unlocked != null else ._get_unlocked_elements(player_index)


func _on_element_pressed(element, inventory_player_index: int) -> void:
	if not PuppetMenu.Puppet.is_active():
		._on_element_pressed(element, inventory_player_index)


func _on_selections_completed() -> void:
	if not PuppetMenu.Puppet.is_active():
		._on_selections_completed()


func _go_back() -> void:
	if not PuppetMenu.Puppet.is_active():
		._go_back()


func _on_BackButton_pressed() -> void:
	if not PuppetMenu.Puppet.is_active():
		._on_BackButton_pressed()


# Writes ProgressData.settings (zone_selected / zone_is_random); also called by _ready.
func _on_ZoneSelectionButton_item_selected(index: int) -> void:
	if not PuppetMenu.Puppet.is_active():
		._on_ZoneSelectionButton_item_selected(index)


func _on_coop_initialized(active: bool, initialize: bool) -> void:
	if not PuppetMenu.Puppet.is_active():
		._on_coop_initialized(active, initialize)


# The game listens for joining devices again after these; on a client only the host does.
func _play_mode_init(mode: int, initialize: bool) -> void:
	._play_mode_init(mode, initialize)
	if PuppetMenu.Puppet.is_active():
		CoopService.listening_for_inputs = false


func _on_element_focused(element, inventory_player_index: int, display_panel_data := true) -> void:
	._on_element_focused(element, inventory_player_index, display_panel_data)
	if PuppetMenu.Puppet.is_active():
		CoopService.listening_for_inputs = false
