extends "res://ui/menus/run/difficulty_selection/difficulty_selection.gd"
# A client's copy shows the host's elements and decides nothing (see character_selection.gd).

const PuppetMenu := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet_menu.gd"
)


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
