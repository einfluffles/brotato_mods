extends Reference
# The gear page and the crate weapons list of a puppet's level-up / crate panels, rebuilt when
# the host's run state changes (static helpers of sync/upgrades_sync.gd).


# p -> whether its gear ("g<p>" part) changed, for each player whose parts changed. store: the
# RunParts.Store right after its state_for(ids); old: the ids the panels showed before ({}: none
# yet, so every player, gear too), compared as well: another section may have built a state since.
static func changed_players(store, old: Dictionary, ids: Dictionary) -> Dictionary:
	var changed := {}
	var rebuilt: Array = store.changed_players()
	for p in RunData.get_player_count():
		var gear_key: String = "g%d" % p
		var gear: bool = (
			old.empty()
			or store.gear_changed(p)
			or not _same_id(ids.get(gear_key), old.get(gear_key))
		)
		if gear or p in rebuilt or not _same_id(ids.get("p%d" % p), old.get("p%d" % p)):
			changed[p] = gear
	return changed


# Whether apply's refresh can have taken the popup p's cursor was in: the crate list's refresh
# closes it, a gear rebuild frees the gear element it was opened from.
static func popup_refreshed(ui: Node, p: int, in_popup: bool, gear: bool) -> bool:
	return in_popup and (gear or ui._weapons_inventory_enabled[p])


static func _same_id(a, b) -> bool:
	return typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY and a == b


# UpgradesUI._show_next_player_options refreshes the crate weapons list on the host; a puppet
# never runs it, and the run state brings new weapon objects. slot: where the cursor was in the
# list; returns whether it kept its place.
static func refresh_weapons(ui: Node, container: Node, p: int, slot: int, own: bool) -> bool:
	if not ui._weapons_inventory_enabled[p]:
		return false
	var elements = container.crate_weapons_container._elements
	var emulator = container.focus_emulator
	if is_child_of(emulator.focused_control, elements):
		emulator.focused_control = null  # its element is freed now; slot puts it back
	ui._refresh_weapons_inventory(p)
	var list = container.crate_weapons_container
	var count: int = list.get_element_count()
	if slot < 0 or count == 0:
		return false
	var element = list.get_element(int(min(slot, count - 1)))
	if element == null or not element.is_visible_in_tree():
		return false
	if own:
		Utils.focus_player_control(element, p, container.focus_emulator)
	else:
		container.focus_emulator.focused_control = element  # mirrored, like FocusSync
	return true


# The slot in p's crate weapons list its cursor is on, or its popup was opened from; -1 when
# the cursor is elsewhere.
static func weapon_slot(ui: Node, container: Node, p: int) -> int:
	if not ui._weapons_inventory_enabled[p]:
		return -1
	var elements = container.crate_weapons_container._elements
	var pressed = ui._popup_manager._elements_pressed[p]
	for control in [pressed, container.focus_emulator.focused_control]:
		if is_child_of(control, elements):
			return control.get_index()
	return -1


# update_inventory frees every gear element. Nothing may keep an old one (a FocusEmulator with a
# freed control crashes, a focus neighbour naming one logs "Node not found"), so the cursor is
# taken off first. Returns where it was ([] when not in the gear) for put_gear_cursor.
static func rebuild_gear(ui: Node, container: Node, p: int) -> Array:
	var emulator = container.focus_emulator
	var cursor := _gear_place(container, emulator.focused_control)
	if not cursor.empty():
		emulator.focused_control = null
	else:
		# In the popup opened from a gear element: the crate list's refresh closes it.
		cursor = _gear_place(container, ui._popup_manager._elements_pressed[p])
	var resume := _gear_place(container, container._resume_inventory_control_focus)
	container.update_inventory()
	if not resume.empty():
		container._resume_inventory_control_focus = _gear_element(container, resume)
	_relink_gear(container)
	return cursor


# Returns whether the cursor is back on the rebuilt gear.
static func put_gear_cursor(container: Node, place: Array) -> bool:
	var element = _gear_element(container, place)
	if element == null or not element.is_visible_in_tree() or container.item_popup._focused:
		return false
	if container.focus_emulator.focused_control != element:
		container.focus_emulator.focused_control = element
	return true


static func _gear_inventories(container: Node) -> Array:
	var gear = container.player_gear_container
	return [gear.weapons_container._elements, gear.items_container._elements]


# [inventory (0 weapons, 1 items), element index, item id] of a gear element, else [].
static func _gear_place(container: Node, control) -> Array:
	var inventories := _gear_inventories(container)
	for i in inventories.size():
		if is_child_of(control, inventories[i]):
			var item = control.item
			return [i, control.get_index(), item.my_id if item != null else ""]
	return []


# The same item (the one nearest its old index: items are shown newest first), else the element
# at the same index (the last one if there are fewer). null when that inventory is empty.
static func _gear_element(container: Node, place: Array):
	if place.empty():
		return null
	var inventory: Node = _gear_inventories(container)[place[0]]
	var best = null
	var best_distance := 0
	for element in inventory.get_children():
		if element.is_queued_for_deletion() or element.item == null:
			continue
		var distance := int(abs(element.get_index() - place[1]))
		if element.item.my_id == place[2] and (best == null or distance < best_distance):
			best = element
			best_distance = distance
	var count: int = inventory.get_child_count()
	if best == null and count > 0:
		best = inventory.get_child(int(min(place[1], count - 1)))
	return best


# On the gear page the game's own links are redone (_set_focus_neighbours, which the game runs on
# a page change only). On another page a path to a freed element is dropped.
static func _relink_gear(container: Node) -> void:
	var gear = container.player_gear_container
	for inventory in [gear.weapons_container, gear.items_container]:
		_drop_dead_neighbours(inventory)
		_drop_dead_neighbours(inventory._elements)
	if container.carousel.index == 1 and gear.items_container.get_element_count() > 0:
		container._set_focus_neighbours()


static func _drop_dead_neighbours(control: Control) -> void:
	for margin in [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]:
		var path := control.get_focus_neighbour(margin)
		if not path.is_empty() and control.get_node_or_null(path) == null:
			control.set_focus_neighbour(margin, NodePath(""))


static func is_child_of(control, parent: Node) -> bool:
	return is_instance_valid(control) and control.get_parent() == parent
