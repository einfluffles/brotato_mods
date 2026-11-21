extends "res://ui/menus/shop/coop_item_popup.gd"
# BasePopup leaves DIST between an item and its popup. In a co-op panel the next item of the shop
# stack (or the next gear row) lies in that gap, so a mouse on its way into the popup hovers that
# item instead (sync/local_panel.gd). The popup touches its item; the game's flip above, clamping
# and sideways shift stay. On every machine: the host's own mouse closes the popup on leaving the
# item anyway, and all machines draw the panels alike.


func _get_new_position(control: Control, panel: Node) -> Vector2:
	var pos: Vector2 = ._get_new_position(control, panel)
	if not is_instance_valid(control) or not control.is_inside_tree():
		return pos
	var item := Rect2(control.rect_global_position, control.rect_size)
	var below := pos.y - item.end.y
	var above := item.position.y - (pos.y + rect_size.y)
	if below > 0 and below <= DIST:
		pos.y = item.end.y
	elif above > 0 and above <= DIST:
		pos.y = item.position.y - rect_size.y
	return pos
