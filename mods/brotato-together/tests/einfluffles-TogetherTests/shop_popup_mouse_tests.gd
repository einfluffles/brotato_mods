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


# Leaving the hovered item's popup: through the gap and into it keeps it, into empty space closes
# it (the cursor stays), the item shows it again, another item shows its own. A popup the keys
# opened stays when the mouse moves in empty space.
func leave(s, emulator: Node, own: Control, hovered: Control):
	var local = s._sync.local
	var panel = local.local_panel
	var popup = s._shop._get_item_popup(0)
	var empty = _empty_point(panel, own, popup, hovered)
	s._t._check(popup.visible and empty != null, "the own shop panel has empty space")
	if empty == null:
		yield(s._t.get_tree(), "idle_frame")
		return
	var gap = _gap_point(panel, popup, hovered)
	if gap == null:
		print("  info: no gap between the shop item and its popup, not tested")
	elif panel.control_at(own, gap) != null:
		s._t._check(
			panel._near_popup(popup, hovered, gap),
			"the gap between an item and its popup counts as on them (it lies over another control)"
		)
	else:
		yield(s._mouse_at(gap, "move"), "completed")
		s._t._check(
			popup.visible and emulator.focused_control == hovered,
			"the mouse between an item and its popup keeps the popup"
		)
	yield(s._mouse(popup, "move"), "completed")
	s._t._check(
		popup.visible and emulator.focused_control == hovered,
		"the mouse from an item into its popup keeps the popup"
	)
	local.last_intent = {}
	yield(s._mouse_at(empty, "move"), "completed")
	s._t._check(
		not popup.visible and emulator.focused_control == hovered and local.last_intent.empty(),
		"the mouse out of the popup into empty space closes it, the cursor stays"
	)
	yield(s._mouse(hovered, "move"), "completed")
	s._t._check(
		popup.visible and popup._attachment == hovered, "the mouse back on the item shows its popup"
	)

	var other: Control = null
	var on_other = null
	for i in 4:
		var button: Control = s._node(0, i)._button
		on_other = _point_on(panel, own, button) if s._node(0, i).active else null
		if button != hovered and on_other != null:
			other = button
			break
	if other != null:
		yield(s._mouse(popup, "move"), "completed")
		yield(s._mouse_at(on_other, "move"), "completed")
		s._t._check(
			emulator.focused_control == other and popup.visible and popup._attachment == other,
			"the mouse out of the popup onto another item shows that item's popup"
		)
		emulator.focused_control = hovered  # as the cursor keys do, the mouse still on other
		yield(s._mouse_at(empty, "move"), "completed")
		s._t._check(
			popup.visible and popup._attachment == hovered,
			"a popup the cursor keys opened stays when the mouse moves in empty space"
		)
	else:
		print("  info: no other shop item outside the popup, leaving onto one not tested")
	yield(s._mouse(hovered, "move"), "completed")


# A point of the panel over no focusable control, away from the item and its popup.
static func _empty_point(panel: Node, own: Control, popup: Control, item: Control):
	var area: Rect2 = panel._rect(own)
	var step := 16.0
	var y := area.position.y + step / 2.0
	while y < area.end.y:
		var x := area.position.x + step / 2.0
		while x < area.end.x:
			var point := Vector2(x, y)
			if panel.control_at(own, point) == null and not panel._near_popup(popup, item, point):
				return point
			x += step
		y += step
	return null


# The middle of the gap between the item and its popup, on the line between their middles.
static func _gap_point(panel: Node, popup: Control, item: Control):
	var from: Rect2 = panel._rect(item)
	var to: Rect2 = panel._rect(popup)
	var gap := []
	for i in 201:
		var point: Vector2 = (from.position + from.size / 2.0).linear_interpolate(
			to.position + to.size / 2.0, i / 200.0
		)
		if not from.has_point(point) and not to.has_point(point):
			gap.append(point)
	return gap[gap.size() / 2] if not gap.empty() else null


# A point where the mouse hits control (part of it can lie under the popup).
static func _point_on(panel: Node, own: Control, control: Control):
	var area: Rect2 = panel._rect(control)
	var step := 8.0
	var y := area.position.y + step / 2.0
	while y < area.end.y:
		var x := area.position.x + step / 2.0
		while x < area.end.x:
			if panel.control_at(own, Vector2(x, y)) == control:
				return Vector2(x, y)
			x += step
		y += step
	return null


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
