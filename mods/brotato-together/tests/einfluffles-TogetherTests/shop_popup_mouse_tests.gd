extends Reference
# The mouse on the own shop panel's item popup (sync/local_panel.gd). Part of the local shop suite
# (local_shop_tests.gd; s: that suite).


# The popup of the hovered item covers what lies below it: the mouse over it (scrolling its
# description) neither moves the cursor nor presses what is below.
func cover(s, emulator: Node, own: Control, hovered: Control):
	var local = s._sync.local
	var popup = s._shop._get_item_popup(0)
	var covered = _covered_point(local.local_panel, own, popup, hovered)
	s._t._check(popup.visible and covered != null, "the hovered item's popup covers a control")
	if covered == null:
		yield(s._t.get_tree(), "idle_frame")
		return
	local.last_intent = {}
	yield(s._mouse_at(covered, "move"), "completed")
	yield(s._mouse_at(covered, "down"), "completed")
	yield(s._mouse_at(covered, "up"), "completed")
	s._t._check(
		emulator.focused_control == hovered and popup.visible and local.last_intent.empty(),
		"the mouse over the popup keeps it open and presses nothing below (%s)" % [local.last_intent]
	)
	yield(s._mouse(hovered, "move"), "completed")


# The middle of where the popup lies over a focusable control of the panel (canvas coordinates).
static func _covered_point(panel: Node, node: Node, popup: Control, hovered: Control):
	if node == popup or (node is CanvasItem and not node.visible):
		return null
	if node is Control and node != hovered and panel._is_focusable(node):
		var overlap: Rect2 = panel._rect(node).clip(panel._rect(popup))
		if not overlap.has_no_area():
			return overlap.position + overlap.size / 2.0
	for child in node.get_children():
		var found = _covered_point(panel, child, popup, hovered)
		if found != null:
			return found
	return null


# The mouse in the own inventory popup: a click on a weapon opens it with the cursor inside,
# the mouse stays inside, a held recycle ends with the mouse button, cancel closes it.
func inventory(s, emulator: Node):
	var local = s._sync.local
	var shop: Node = s._shop
	var popup = shop._get_item_popup(0)
	var element: Control = shop._get_gear_container(0).weapons_container._elements.get_child(0)
	yield(s._click(element), "completed")
	s._t._check(
		popup._focused and popup.is_a_parent_of(emulator.focused_control),
		"a click on an own weapon opens its popup with the cursor in it"
	)
	var outside: Control = null
	for control in [shop._get_reroll_button(0), shop._get_go_button(0)]:
		var middle: Vector2 = control.get_global_rect().position + control.rect_size / 2.0
		if control.is_visible_in_tree() and not popup.get_global_rect().has_point(middle):
			outside = control
			break
	if outside != null:
		local.last_intent = {}
		yield(s._mouse(outside, "move"), "completed")
		yield(s._click(outside), "completed")
		s._t._check(
			(
				popup._focused
				and popup.is_a_parent_of(emulator.focused_control)
				and local.last_intent.empty()
			),
			"the mouse stays inside the open shop popup (%s)" % outside.name
		)
	else:
		print("  info: the shop popup covers reroll and Go, mouse outside it not tested")

	ProgressData.settings.holding_button = true
	local.last_intent = {}
	if popup._focused and popup._requires_recycle_hold() and popup._discard_button.visible:
		yield(s._mouse(popup._discard_button, "down"), "completed")
		s._t._check(popup._recycle_button_held, "mouse down on recycle starts the shop popup's hold")
		yield(s._mouse(popup._discard_button, "up"), "completed")
		s._t._check(
			not popup._recycle_button_held and local.last_intent.empty(),
			"mouse up ends the hold: a short click recycles nothing"
		)
	else:
		print("  info: no hold-to-recycle in the shop popup, mouse hold not tested")
	yield(s._click(popup._cancel_button), "completed")
	s._t._check(not popup._focused, "a click on cancel closes the shop popup")
