extends Reference
# The gear page of a level-up panel as tests read it (upgrades_change_tests.gd).


# [instance ids of the live elements of a panel's gear page, of their items] (weapons, then
# items).
static func ids(container: Node) -> Array:
	var nodes := []
	var items := []
	var gear = container.player_gear_container
	for inventory in [gear.weapons_container._elements, gear.items_container._elements]:
		for element in inventory.get_children():
			if not element.is_queued_for_deletion():
				nodes.append(element.get_instance_id())
				items.append(element.item.get_instance_id())
	return [nodes, items]


# The gear page shows p's own weapon and item objects, each item counted once.
static func shows_run(container: Node, p: int) -> bool:
	var gear = container.player_gear_container
	var weapons: Array = RunData.get_player_weapons(p)
	var items: Array = RunData.get_player_items(p)
	var shown := 0
	for element in gear.weapons_container._elements.get_children():
		if not element.item in weapons:
			return false
		shown += 1
	if shown != weapons.size():
		return false
	shown = 0
	for element in gear.items_container._elements.get_children():
		if not element.item in items:
			return false
		shown += element.current_number
	return shown == items.size()
