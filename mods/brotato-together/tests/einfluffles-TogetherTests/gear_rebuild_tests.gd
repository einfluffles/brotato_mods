extends Reference
# The gear page (carousel page 1) of the level-up panels while this client's own panel runs
# locally, and the host's run state changes under it. UpgradesSync.apply then rebuilds every
# panel's gear (CoopUpgradesUIPlayerContainer.update_inventory frees each InventoryElement and
# builds new ones). A real session crashed there: the own FocusEmulator kept its freed element
# (a released build dereferences it; a debug build reads it as null, so these checks look at
# the references themselves), and the weapons inventory's focus neighbour named a freed item
# element ("Node not found" from Inventory._inherit_or_set_neighbour for each weapon).
# Called from local_panel_tests.client_part with the own panel (player 0) on its gear page.

const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const MARGINS := [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]

var _t: Node = null


func run(t: Node, panels: Node, main: Node, msg: Dictionary):
	_t = t
	var ui = main.get("_coop_upgrades_ui")
	var own = ui._get_player_container(0)
	var other = ui._get_player_container(1)
	var emulator = own.focus_emulator
	var mirrored = other.focus_emulator
	var helmet = t._find_by_id(ItemService.items, "item_helmet")
	var hedgehog = t._find_by_id(ItemService.items, "item_hedgehog")
	var coupon = t._find_by_id(ItemService.items, "item_coupon")
	t._check(own.carousel.index == 1, "gear: the own panel is on its gear page")

	# More items for both players, so the cursors have places to keep.
	RunData.add_item(helmet, 0)
	RunData.add_item(hedgehog, 0)
	RunData.add_item(helmet, 1)
	panels.apply(main, _with_run(msg))
	yield(_frames(2), "completed")
	var items = own.player_gear_container.items_container._elements
	t._check(items.get_child_count() >= 3, "gear: own items shown (%d)" % items.get_child_count())
	var start = items.get_child(1)
	emulator.focused_control = start
	other.carousel.index = 1  # the other player looks at its gear too (mirrored)
	yield(_frames(1), "completed")
	var other_items = other.player_gear_container.items_container._elements
	var other_start = other_items.get_child(other_items.get_child_count() - 1)
	mirrored.focused_control = other_start
	t._check(
		emulator.focused_control == start and mirrored.focused_control == other_start,
		"gear: both cursors on an item element"
	)

	# The other player's pick adds an item: the run changes, every panel's gear is rebuilt.
	var start_id: String = start.item.my_id
	var start_index: int = start.get_index()
	var other_id: String = other_start.item.my_id
	RunData.add_item(coupon, 1)
	panels.apply(main, _with_run(msg))
	t._check(start.is_queued_for_deletion(), "gear: (control) the run change rebuilt the gear")
	yield(_frames(2), "completed")  # the old elements are freed, the inventories relinked
	_check_cursor(emulator, items, start_id, start_index, "own cursor after the other's pick")
	_check_cursor(
		mirrored, other_items, other_id, -1, "mirrored cursor after the other's pick"
	)
	_check_neighbours(own, "own panel after the other's pick")
	_check_neighbours(other, "other panel after the other's pick")
	# The emulator's own input path (where a released build dereferenced the freed control).
	yield(_tap("ui_left"), "completed")
	t._check(
		is_instance_valid(emulator.focused_control)
		and not emulator.focused_control.is_queued_for_deletion(),
		"gear: the own cursor moves on from there"
	)
	emulator.focused_control = items.get_child(start_index)

	# This player's own pick: the new item is shown first (newest first), so the cursor's item
	# moved one place on; the cursor goes with its item.
	RunData.add_item(coupon, 0)
	panels.apply(main, _with_run(msg))
	yield(_frames(2), "completed")
	_check_cursor(emulator, items, start_id, start_index + 1, "own cursor after its own pick")
	_check_neighbours(own, "own panel after its own pick")

	# Off the gear page: the game remembers the gear cursor for the way back
	# (_resume_inventory_control_focus); it must survive a rebuild too.
	yield(_tap("ltrigger"), "completed")
	t._check(own.carousel.index == 0, "gear: (control) the own panel paged back")
	RunData.remove_item(coupon, 0, true)
	panels.apply(main, _with_run(msg))
	yield(_frames(2), "completed")
	var resume = own._resume_inventory_control_focus
	t._check(
		is_instance_valid(resume)
		and not resume.is_queued_for_deletion()
		and resume.item.my_id == start_id,
		"gear: the way back to the gear page names a live element of the same item"
	)
	_check_neighbours(own, "own panel rebuilt on another page")
	yield(_tap("rtrigger"), "completed")
	_check_cursor(emulator, items, start_id, start_index, "own cursor back on the gear page")

	# Safety net (extensions/ui/focus_emulator.gd): an element freed under a cursor by a path
	# that did not move it first is dropped without being touched, and the cursor goes to the
	# element now at its place. The elements freed here are ones no focus neighbour names (the
	# gear links the first weapon and the last item): the mod never frees one this way.
	var other_weapons = other.player_gear_container.weapons_container._elements
	t._check(
		other_items.get_child_count() >= 3 and other_weapons.get_child_count() >= 2,
		"gear: (control) the other player has items and weapons to lose"
	)
	var drops: int = mirrored.freed_drops
	var victim = other_items.get_child(1)
	var successor = other_items.get_child(2)
	mirrored.focused_control = victim
	victim.free()
	mirrored.set_process(true)
	yield(_frames(1), "completed")
	t._check(
		mirrored.freed_drops == drops + 1 and mirrored.focused_control == successor,
		"gear: a freed cursor control is replaced by the element at its place"
	)
	t._check(not mirrored.is_processing(), "gear: the game's own _process still ran")
	victim = other_weapons.get_child(other_weapons.get_child_count() - 1)
	mirrored.focused_control = victim
	victim.free()
	mirrored.focused_control = other.carousel.arrow_left  # the setter: nothing touches the freed one
	t._check(
		mirrored.freed_drops == drops + 2 and mirrored.focused_control == other.carousel.arrow_left,
		"gear: setting a cursor over a freed control works"
	)
	mirrored.focused_control = null

	# Back to the run the tests that follow expect (one rebuild puts back the freed elements).
	RunData.remove_item(coupon, 1, true)
	RunData.remove_item(hedgehog, 0, true)
	RunData.remove_item(helmet, 0, true)
	RunData.remove_item(helmet, 1, true)
	panels.apply(main, _with_run(msg, 0))
	yield(_frames(2), "completed")
	_check_neighbours(own, "own panel after the cleanup")
	t._check(
		is_instance_valid(emulator.focused_control)
		and emulator.focused_control.get_parent() == items,
		"gear: the own cursor is still in the gear"
	)


# msg with the run as it is now (the host's state after a change of the gear); the other
# player's page is mirrored from it (its gear page while these tests look at it).
static func _with_run(msg: Dictionary, other_page := 1) -> Dictionary:
	var changed := msg.duplicate()
	changed.run = bytes2var(var2bytes(RunStateCodec.encode()), false)
	changed.pages = [msg.pages[0], other_page]
	return changed


# The cursor is on a live element of inventory: the one of item id (at index when >= 0).
func _check_cursor(emulator: Node, inventory: Node, id: String, index: int, label: String) -> void:
	var control = emulator.focused_control
	var live: bool = is_instance_valid(control) and not control.is_queued_for_deletion()
	var where := ""
	if live and control.get_parent() == inventory:
		where = "%s at %d" % [control.item.my_id, control.get_index()]
	_t._check(
		live
		and control.get_parent() == inventory
		and control.item.my_id == id
		and (index < 0 or control.get_index() == index),
		"gear: %s: %s at %d (%s)" % [label, id, index, where if live else "freed or none"]
	)


# Every focus neighbour of the gear's inventories and their elements names a node that exists.
func _check_neighbours(container: Node, label: String) -> void:
	var gear = container.player_gear_container
	var nodes := []
	for inventory in [gear.weapons_container, gear.items_container]:
		nodes.append(inventory)
		nodes.append(inventory._elements)
		nodes.append_array(inventory._elements.get_children())
	var dead := []
	for node in nodes:
		for margin in MARGINS:
			var path: NodePath = node.get_focus_neighbour(margin)
			if not path.is_empty() and node.get_node_or_null(path) == null:
				dead.append("%s:%d" % [node.name, margin])
	_t._check(dead.empty(), "gear: %s: no neighbour names a freed node %s" % [label, dead])


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")


# Press and release on the own slot's virtual device, as RemoteButtons delivers it.
func _tap(action: String):
	for pressed in [true, false]:
		VirtualDevices.press_button(VirtualDevices.action(action, _t.DEVICE), _t.DEVICE, pressed)
		yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
