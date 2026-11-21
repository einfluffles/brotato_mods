extends Node
# Client: the mouse on the end-of-run copy, for looking. Hovering an item or a stat shows its
# popup (any player's), a click on a carousel arrow turns that panel's page here only, and the
# wheel goes on to the FocusEmulators (WheelScroll: the own panel). No cursor moves, nothing is
# sent, and the copy's own controls never get a mouse event: restart, new run and exit stay the
# host's. Must be the emulators' last sibling: _input runs in reverse tree order.

const LocalPanel := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/local_panel.gd")
const WheelScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/wheel_scroll.gd")
const SharedScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/shared_scroll.gd")

var menu_puppet: Node = null  # host_page(), input_sync

var _hover_pos := Vector2.ZERO
var _hover_pending := false
var _hovered = null  # the item or stat whose popup the mouse shows
var _hovered_player := -1


func _input(event: InputEvent) -> void:
	if _blocked():
		_unhover()
		return
	if not (event is InputEventMouse):
		if LocalPanel.event_player_type(event) >= 0:
			# The keys move the own cursor on the host, on the host's page.
			_show_host_page(SharedScroll.own_player())
		return
	if WheelScroll.direction(event) != 0:
		return
	get_tree().set_input_as_handled()
	if event is InputEventMouseMotion:
		_hover_pos = event.position
		_hover_pending = true  # resolved once per frame
	elif event.button_index == BUTTON_LEFT and event.pressed:
		_turn_page(event.position)


func _process(_delta: float) -> void:
	if _hovered != null and not _shows(_hovered):
		_unhover()
	if not _hover_pending:
		return
	_hover_pending = false
	if _blocked():
		return
	if _hovered != null and _near_popup(_hovered, _hovered_player, _hover_pos):
		return  # its popup lies over what is below, and the way to it stays open
	var target := _target_at(_hover_pos)
	if target.empty():
		_unhover()
	elif target[0] != _hovered:
		_hover(target[0], target[1])


# The lobby popup owns the mouse.
func _blocked() -> bool:
	var input_sync = menu_puppet.input_sync if menu_puppet != null else null
	return input_sync != null and input_sync.local_input_blocked


# [control, player] for an item or stat under pos, [] for anything else.
func _target_at(pos: Vector2) -> Array:
	var scene := get_parent()
	var containers: Array = scene.player_containers
	for p in min(RunData.get_player_count(), containers.size()):
		var control := LocalPanel.control_at(containers[p], pos)
		if control != null:
			return [control, p] if _has_popup(control) else []
	var reward := LocalPanel.control_at(scene._progress_container, pos)
	if reward is InventoryElement:
		return [reward, int(max(SharedScroll.own_player(), 0))]
	return []


static func _has_popup(control) -> bool:
	return control is InventoryElement or control is StatContainer


static func _shows(control) -> bool:
	return is_instance_valid(control) and control.is_visible_in_tree()


func _popup_for(control, p: int) -> Control:
	var scene := get_parent()
	return scene.item_popups[p] if control is InventoryElement else scene.stat_popups[p]


# On the control's shown popup, or within BasePopup.DIST of the control (the gap to it).
func _near_popup(control, p: int, pos: Vector2) -> bool:
	var popup := _popup_for(control, p)
	if not popup.visible or popup._attachment != control:
		return false
	var item_rect: Rect2 = WheelScroll.rect_of(control).grow(BasePopup.DIST)
	return WheelScroll.rect_of(popup).has_point(pos) or item_rect.has_point(pos)


func _hover(control: Control, p: int) -> void:
	_unhover(_hovered_player != p)
	_hovered = control
	_hovered_player = p
	var scene := get_parent()
	scene.item_popups[p].hide()
	scene.stat_popups[p].hide()
	if control is InventoryElement:
		# Not PopupManager._on_element_hovered: it grabs the focus, a cursor would follow.
		scene.item_popups[p].display_element(control)
	else:
		# StatContainer takes the player from FocusEmulatorSignal; the native signal has none.
		FocusEmulatorSignal.emit(control._label, "mouse_entered", p)


# restore: the popup of that player's cursor shows again.
func _unhover(restore := true) -> void:
	var control = _hovered
	var p := _hovered_player
	_hovered = null
	_hovered_player = -1
	if not is_instance_valid(control):
		return
	if control is InventoryElement:
		var popup = get_parent().item_popups[p]
		if popup._attachment == control:
			popup.hide()
	else:
		FocusEmulatorSignal.emit(control._label, "mouse_exited", p)
	if restore:
		_show_cursor_popup(p)


func _show_cursor_popup(p: int) -> void:
	var emulator = Utils.get_focus_emulator(p, get_parent())
	var cursor = emulator.focused_control if emulator != null else null
	if _has_popup(cursor) and _shows(cursor):
		FocusEmulatorSignal.emit(cursor, "focus_entered", p)


func _turn_page(pos: Vector2) -> void:
	var containers: Array = get_parent().player_containers
	for p in min(RunData.get_player_count(), containers.size()):
		var carousel = containers[p].carousel
		if not carousel.active or carousel.locked:
			continue
		for arrow in [carousel.arrow_left, carousel.arrow_right]:
			# Carousel hides the arrow at either end (alpha 0) and greys out trigger glyphs.
			if arrow.is_visible_in_tree() and arrow.modulate.a > 0.0:
				if WheelScroll.rect_of(arrow).has_point(pos):
					show_page(p, carousel.index + (-1 if arrow == carousel.arrow_left else 1))
					return


# Without index_changed: CoopEndRunPlayerContainer would move that player's cursor.
func show_page(p: int, page: int) -> void:
	var carousel = get_parent().player_containers[p].carousel
	page = int(clamp(page, 0, carousel._get_max_index()))
	if page == carousel.index:
		return
	carousel.index = page
	if _hovered_player == p and not _shows(_hovered):
		_unhover(false)
	var scene := get_parent()
	for popup in [scene.item_popups[p], scene.stat_popups[p]]:
		if popup.visible and not _shows(popup._attachment):
			popup.hide()
	_show_cursor_popup(p)


func _show_host_page(p: int) -> void:
	if p < 0 or menu_puppet == null or p >= get_parent().player_containers.size():
		return
	var page: int = menu_puppet.host_page(p)
	if page >= 0 and p < RunData.get_player_count():
		show_page(p, page)
