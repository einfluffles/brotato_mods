extends Reference
# The gear page and the crate weapons list of a puppet's level-up / crate panels, rebuilt when
# the host's run state changes (static helpers of sync/upgrades_sync.gd). The shop's gear rows
# use sync_gear too (sync/shop_sync.gd).


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


# The gear page after a run change (update_inventory), its elements kept where they show the same
# thing (sync_inventory). Nothing may keep a freed one (a FocusEmulator with a freed control
# crashes, a focus neighbour naming one logs "Node not found"), so a cursor on one is taken off
# and the rows are relinked (relink_gear: this does not go through the panel's update_inventory).
# Returns where the cursor was ([] when not in the gear) for put_gear_cursor. items false: only
# the player's other parts changed (its weapons are new objects of the same weapons).
static func rebuild_gear(ui: Node, container: Node, p: int, items := true) -> Array:
	var emulator = container.focus_emulator
	var cursor := _gear_place(container, emulator.focused_control)
	var on_gear := not cursor.empty()
	if not on_gear:
		# In the popup opened from a gear element: the crate list's refresh closes it.
		cursor = _gear_place(container, ui._popup_manager._elements_pressed[p])
	var resume := _gear_place(container, container._resume_inventory_control_focus)
	var gear = container.player_gear_container
	sync_gear(gear, emulator, RunData.get_player_weapons(p), RunData.get_player_items(p), items)
	if on_gear and _gear_place(container, emulator.focused_control).empty():
		emulator.focused_control = null  # its element was freed
	var resume_control = container._resume_inventory_control_focus
	if not resume.empty() and _gear_place(container, resume_control).empty():
		container._resume_inventory_control_focus = _gear_element(container, resume)
	relink_gear(container)
	return cursor


# A PlayerGearContainer's rows after a run change, in place where sync_inventory applies, else
# the game's set_data (set_weapons_data / set_items_data) with the cursor taken off the row first.
# The level-up panels (rebuild_gear) and the shop (ShopSync._refresh_gear) share it. with_items
# false: the weapons only. The caller handles a cursor or popup on an element freed here.
static func sync_gear(gear: Node, emulator, weapons: Array, items: Array, with_items: bool) -> void:
	if not sync_inventory(gear.weapons_container._elements, weapons, false, false):
		_release(emulator, gear.weapons_container._elements)
		gear.weapons_container.set_data("", Category.WEAPON, weapons)
	gear._on_weapons_changed()  # what set_weapons_data does after it
	# The items' sort inherits their row's neighbours: one may name a weapon element freed above.
	_drop_dead_rows(gear)
	if with_items and not sync_inventory(gear.items_container._elements, items, true, true):
		_release(emulator, gear.items_container._elements)
		gear.set_items_data(items)


# Takes the cursor off inventory before the game frees all of its elements.
static func _release(emulator, inventory: Node) -> void:
	if emulator != null and is_child_of(emulator.focused_control, inventory):
		emulator.focused_control = null


# Inventory.set_elements(elements, reverse, true, first) without instancing an element that
# shows the same as one already there (a run change brings new item objects, mostly of the same
# items): the elements are matched by what they show, pointed at the new objects, only the
# difference is instanced or freed, and the game's sorter orders them as after set_elements.
# false where it does not apply (an empty inventory, a locked item): the caller sets the data.
static func sync_inventory(inventory: Node, elements: Array, reverse: bool, first: bool) -> bool:
	if inventory.get_child_count() == 0:
		return false
	for element in elements:
		if not element is Resource or element.is_locked:
			return false
	for node in inventory.get_children():
		if node.is_special or node.item == null:
			return false
	var check: bool = elements.size() >= 2 and elements[1].get_category() == Category.ITEM
	var entries := []  # [element, count], in the order set_elements adds them
	if check:
		entries = inventory.get_elements_with_count(elements)
	else:
		for element in elements:
			entries.append([element, 1])
	var spare := {}  # what a node shows -> the nodes showing it, in child order
	for node in inventory.get_children():
		var key := shows(node.item)
		if not spare.has(key):
			spare[key] = []
		spare[key].append(node)
	var nodes := []
	for entry in entries:
		var same: Array = spare.get(shows(entry[0]), [])
		nodes.append(same.pop_front() if not same.empty() else null)
	var left := []
	for same in spare.values():
		left.append_array(same)
	for i in entries.size():
		var item = entries[i][0]
		if nodes[i] == null and not left.empty():
			nodes[i] = left.pop_back()
			nodes[i].set_element(item)
		elif nodes[i] == null:
			nodes[i] = inventory._spawn_element(item, inventory.display_banned)
		else:
			nodes[i].item = item
			_set_marks(nodes[i])
		_set_count(nodes[i], entries[i][1])
	for node in left:
		inventory.remove_child(node)
		node.queue_free()
	inventory.order_of_addition = nodes.duplicate()
	var order := nodes.duplicate()
	if reverse:
		order.invert()
	for i in order.size():
		inventory.move_child(order[i], i)
	if first:  # set_elements' prioritize_gameplay_elements
		for node in inventory.get_children():
			if node.item is CharacterData or "item_builder_turret" in node.item.my_id:
				inventory.move_child(node, 0)
	inventory.emit_signal("elements_changed")
	inventory.queue_set_focus_neighbours()
	inventory.emit_signal("need_to_sort_inventory")
	return true


# What an InventoryElement shows of item (InventoryElement.set_element).
static func shows(item) -> String:
	var icon = item.get_icon()
	return "%s %s %s %s %s %s" % [
		item.my_id,
		item.get("tier"),
		item.get("is_cursed"),
		item.get("is_meca"),
		item.get("is_mutant"),
		icon.get_instance_id() if icon != null else 0,
	]


# What set_element shows from the player's run rather than from the item, on a kept element:
# banned, and recently mutated (the shop's items row shows that).
static func _set_marks(node: Node) -> void:
	node.update_banned_item()
	var mutated = node.get("_recently_mutated")
	if mutated != null:
		mutated.visible = node.display_recently_mutated and node._is_recently_mutated()


# As add_element_with_count leaves it.
static func _set_count(node: Node, count: int) -> void:
	node.current_number = count
	node._number_label.text = "x" + str(count)
	node._number_label.visible = count > 1


# Returns whether the cursor is back on the rebuilt gear.
static func put_gear_cursor(container: Node, place: Array) -> bool:
	if place.empty() or container.item_popup._focused:
		return false
	var current = container.focus_emulator.focused_control
	var at := _gear_place(container, current)
	var element = current if not at.empty() and at[2] == place[2] else null
	if element == null:
		element = _gear_element(container, place)
	if element == null or not element.is_visible_in_tree():
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


# After a gear rebuild. A focus neighbour naming a freed element logs "Node not found" and
# "p_node is null" when the rows set their elements' neighbours. On the gear page the game's own
# links are redone (_set_focus_neighbours, which the game runs on a page change only). On another
# page a path to a freed element is dropped.
static func relink_gear(container: Node) -> void:
	var gear = container.player_gear_container
	_drop_dead_rows(gear)
	if container.carousel.index == 1 and gear.items_container.get_element_count() > 0:
		container._set_focus_neighbours()


static func _drop_dead_rows(gear: Node) -> void:
	for inventory in [gear.weapons_container, gear.items_container]:
		_drop_dead_neighbours(inventory)
		_drop_dead_neighbours(inventory._elements)


static func _drop_dead_neighbours(control: Control) -> void:
	for margin in [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]:
		var path := control.get_focus_neighbour(margin)
		if not path.is_empty() and control.get_node_or_null(path) == null:
			control.set_focus_neighbour(margin, NodePath(""))


static func is_child_of(control, parent: Node) -> bool:
	return is_instance_valid(control) and control.get_parent() == parent
