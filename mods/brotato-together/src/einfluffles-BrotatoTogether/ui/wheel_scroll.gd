extends Reference
# The mouse wheel on co-op screens (character / weapon / difficulty selection, the shop, the
# level-up and crate panels). The game turns it off there: every FocusEmulator with a cursor marks
# each event that is not a co-op action as handled while nobody can join (so no ScrollContainer
# gets it), and BaseSelection._scroll_with_mouse_wheel returns at once in a co-op run. Where an
# event did get through (character selection while players can join), the GUI scrolled whatever
# was under the pointer, any player's panel.
# The mouse belongs to one player, so the wheel scrolls what is under the pointer in that player's
# own panel and never anything of another player:
#  - host and local co-op: the keyboard player (KEYBOARD_REMAPPED_DEVICE_ID); with none, nothing;
#  - a client's copy of the host's selection screens: its own player (ui/shared_scroll.gd);
#  - a client's own shop / level-up panel: sync/local_panel.gd calls scroll_at with that panel.
# The FocusEmulator extension calls handle(): the emulators are children of the screen, and the
# first of them to see the event marks it handled, so the game's handling never sees it either.
# Names no game classes: the FocusEmulator extension preloads it at mod init.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SharedScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/shared_scroll.gd")
const STEP := 70  # ItemDescription.MOUSE_SCROLL_STEP
const KEYBOARD := 7  # CoopService.KEYBOARD_REMAPPED_DEVICE_ID


# -1 / 1 for a wheel step up / down, 0 for any other event.
static func direction(event: InputEvent) -> int:
	if not (event is InputEventMouseButton):
		return 0
	if event.button_index == BUTTON_WHEEL_UP:
		return -1
	if event.button_index == BUTTON_WHEEL_DOWN:
		return 1
	return 0


# A wheel event reaching a FocusEmulator of menu (its parent). True: it was a wheel event of a
# co-op screen and is done with (scrolled in the mouse player's panel, or nothing to scroll).
static func handle(menu: Node, event: InputEvent) -> bool:
	var step := direction(event)
	if step == 0 or not RunData.is_coop_run or menu == null:
		return false
	var roots = own_roots(menu, mouse_player())
	if roots == null:
		return false  # not a screen with player panels: the game's handling
	if event.pressed:
		for root in roots:
			if scroll_at(root, event.position, step):
				break
	return true


# The player slot the mouse belongs to on this machine (-1: none).
static func mouse_player() -> int:
	if Puppet.is_active():
		return SharedScroll.own_player()
	var players: Array = CoopService.connected_players
	for i in players.size():
		if players[i][0] == KEYBOARD:
			return i
	return -1


# What the wheel may scroll for player on menu: its panel (and its grid on the selection screens,
# the shared one in character selection). null: menu is not a screen with player panels.
static func own_roots(menu: Node, player: int):
	var roots := []
	if menu.has_method("_get_coop_player_container"):  # CoopShop
		if _has_player(player):
			roots.append(menu._get_coop_player_container(player))
	elif menu.has_method("_get_player_container"):  # UpgradesUI
		if _has_player(player):
			roots.append(menu._get_player_container(player))
	elif menu.has_method("_get_panels") and menu.has_method("_get_inventory_containers"):
		if _has_player(player):
			var panels: Array = menu._get_panels()
			if player < panels.size():
				roots.append(panels[player])
			var grids: Array = menu._get_inventory_containers()
			if grids.size() == 1 and menu.has_method("_get_wheel_grid"):
				roots.append(menu._get_wheel_grid())  # every cursor's grid
			elif player < grids.size():
				roots.append(grids[player])
	else:
		return null
	return roots


static func _has_player(player: int) -> bool:
	return player >= 0 and player < CoopService.connected_players.size()


# Scrolls the innermost ScrollContainer under pos (viewport coordinates, like the events _input
# gets) inside root that has more content than room, by one wheel step. False: nothing to scroll.
static func scroll_at(root, pos: Vector2, step: int) -> bool:
	if not (root is Control) or not is_instance_valid(root) or not root.is_visible_in_tree():
		return false
	var found := []
	_collect(root, pos, found)
	for i in range(found.size() - 1, -1, -1):
		var scroll: ScrollContainer = found[i]
		if can_scroll(scroll):
			scroll.scroll_vertical += step * STEP
			return true
	return false


# BaseSelection._can_scroll_vertically (some hint labels are ScrollContainers that never scroll).
static func can_scroll(scroll: ScrollContainer) -> bool:
	return (
		scroll.is_visible_in_tree()
		and scroll.scroll_vertical_enabled
		and scroll.get_v_scrollbar().max_value > scroll.rect_size.y
	)


# The ScrollContainers under pos, outermost first; what a clipping parent cuts off is not under it.
static func _collect(node: Node, pos: Vector2, found: Array) -> void:
	if node is CanvasItem and not node.visible:
		return
	if node is Control:
		var inside: bool = rect_of(node).has_point(pos)
		if not inside and (node.rect_clip_content or node is ScrollContainer):
			return
		if inside and node is ScrollContainer:
			found.append(node)
	for child in node.get_children():
		_collect(child, pos, found)


static func rect_of(control: Control) -> Rect2:
	return control.get_global_transform_with_canvas().xform(Rect2(Vector2.ZERO, control.rect_size))
