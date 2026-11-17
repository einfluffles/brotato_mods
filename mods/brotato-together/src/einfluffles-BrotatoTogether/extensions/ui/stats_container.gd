extends "res://ui/menus/shop/stats_container.gd"
# A third tab for the damage meter's board next to Primary / Secondary, in the solo shop and the
# solo end of run (ui/damage_views.gd add_tab arms it). Every other stats panel (pause menu,
# level-up, the co-op stats pages) never calls bt_add_tab and stays as the game made it.
#
# The game's _input toggles between the two tabs on LB / RB (update_tab(the other one)). Godot 3
# runs this script's _input first, so it notes which trigger it was, and update_tab then steps
# through the three tabs instead: RB forward, LB back, around at the ends. The button is a copy
# of Secondary without its signals, an icon only (the row has no room for a third text tab).

const BT_TAB := 2
const BT_TITLE := "Damage"
# The tab row has 360 px inside the panel's 400; the game's tabs take 150 + 180 + 10. With the
# third tab they give up a little, so the panel keeps its width: 145 + 165 + 40 + 2 x 5 = 360.
const BT_WIDTHS := [145, 165, 40]
const BT_SEPARATION := 5

var _bt_button: Button = null
var _bt_page: Control = null
var _bt_enabled := false
var _bt_current := 0  # Tab.PRIMARY, Tab.SECONDARY or BT_TAB
var _bt_step := 0  # the trigger _input saw: -1 LB, 1 RB, 0 none
var _bt_game_layout := []  # Primary's and Secondary's widths and the row's separation


func bt_has_tab() -> bool:
	return _bt_button != null


func bt_add_tab(page: Control, icon: Texture) -> void:
	if _bt_button != null:
		return
	_bt_button = _secondary_tab.duplicate(DUPLICATE_SCRIPTS)
	_bt_button.name = "DamageTab"
	_bt_button.unique_name_in_owner = false
	_bt_button.text = ""
	_bt_button.icon = icon
	_bt_button.expand_icon = true
	_bt_button.hint_tooltip = BT_TITLE
	_buttons_container.add_child_below_node(_secondary_tab, _bt_button)
	_bt_button.connect("pressed", self, "update_tab", [BT_TAB])
	_bt_button.connect("focus_entered", self, "_bt_on_focus_entered")
	_bt_game_layout = [
		_primary_tab.rect_min_size.x,
		_secondary_tab.rect_min_size.x,
		_buttons_container.get_constant("separation"),
	]
	_bt_page = page
	_bt_page.visible = false
	_secondary_stats.get_parent().add_child_below_node(_secondary_stats, _bt_page)
	_bt_current = focused_tab
	_set_flat(_bt_button, false)
	_bt_enabled = false
	bt_set_tab_enabled(true)


# Off (the meter's switch): the tab is gone, an open one falls back to Primary, and the row has
# the game's widths again.
func bt_set_tab_enabled(on: bool) -> void:
	if _bt_button == null or on == _bt_enabled:
		return
	_bt_enabled = on
	if not on and _bt_current == BT_TAB:
		update_tab(Tab.PRIMARY)
	if not on and _bt_button.has_focus():
		_primary_tab.grab_focus()
	_bt_button.visible = on
	_primary_tab.rect_min_size.x = BT_WIDTHS[0] if on else _bt_game_layout[0]
	_secondary_tab.rect_min_size.x = BT_WIDTHS[1] if on else _bt_game_layout[1]
	_bt_button.rect_min_size.x = BT_WIDTHS[2]
	_buttons_container.add_constant_override(
		"separation", BT_SEPARATION if on else _bt_game_layout[2]
	)
	set_focus_neighbours()


# The hidden tab can still be handed the focus: the shop gives it back after a pause to whatever
# had it before, and the meter may have been switched off in that pause.
func _bt_on_focus_entered() -> void:
	if not _bt_enabled:
		_primary_tab.call_deferred("grab_focus")


func _input(event: InputEvent) -> void:
	_bt_step = 0
	if not _bt_enabled or not show_buttons or not event is InputEventJoypadButton:
		return
	if event.is_action_pressed("ltrigger"):
		_bt_step = -1
	elif event.is_action_pressed("rtrigger"):
		_bt_step = 1


func update_tab(tab: int) -> void:
	if _bt_step != 0:
		tab = posmod(_bt_current + _bt_step, 3 if _bt_enabled else 2)
		_bt_step = 0
	if _bt_button == null:
		.update_tab(tab)
		return
	if tab != BT_TAB or not _bt_enabled:
		_bt_current = tab if tab != BT_TAB else Tab.PRIMARY
		_bt_page.visible = false
		_set_flat(_bt_button, false)
		.update_tab(_bt_current)
		return
	_bt_current = BT_TAB
	var focused = get_focus_owner()
	if focused != null and focused.get_parent() in [_general_stats, _primary_stats, _secondary_stats]:
		_bt_button.grab_focus()
	focused_tab = Tab.SECONDARY  # no focus loops over the hidden primary stats
	_set_flat(_primary_tab, false)
	_set_flat(_secondary_tab, false)
	_set_flat(_bt_button, true)
	_general_stats.hide()
	_primary_stats.hide()
	_secondary_stats.hide()
	_bt_page.visible = true
	set_focus_neighbours()


func set_focus_neighbours() -> void:
	.set_focus_neighbours()
	if _bt_button == null:
		return
	for margin in [MARGIN_TOP, MARGIN_BOTTOM, MARGIN_LEFT, MARGIN_RIGHT]:
		_bt_button.set_focus_neighbour(margin, NodePath(""))
	if not _bt_enabled:
		return
	_secondary_tab.focus_neighbour_right = _secondary_tab.get_path_to(_bt_button)
	_bt_button.focus_neighbour_left = _bt_button.get_path_to(_secondary_tab)
	if focus_neighbour_right:
		_bt_button.focus_neighbour_right = _bt_button.get_path_to(get_node(focus_neighbour_right))
	if focus_neighbour_top:
		_bt_button.focus_neighbour_top = _bt_button.get_path_to(get_node(focus_neighbour_top))
	if focus_neighbour_bottom and _bt_current == BT_TAB:
		_bt_button.focus_neighbour_bottom = _bt_button.get_path_to(get_node(focus_neighbour_bottom))
