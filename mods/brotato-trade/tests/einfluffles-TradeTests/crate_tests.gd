extends Reference
# The crate panels in plain local co-op, on the battle scene's own CoopUpgradesUI. Three players:
# 0 opens the crates, 1 has the unique item and no free slot for a pistol, 2 has room and looks
# at its gear meanwhile.

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")

var _t: Node = null
var _ui: Node = null
var _unique = null


func run(t: Node):
	_t = t
	t.coop_run(3)
	_unique = t.item_with_limit(1)
	RunData.add_item(_unique.duplicate(), 1)
	t.fill_weapons(0, t.weapon())
	t.fill_weapons(1, t.weapon())
	RunData.add_item(t.item_with_limit(-1), 2)
	var main = yield(t.open_battle(), "completed")
	_ui = main.get("_coop_upgrades_ui")
	t.check(not t.has_node(t.TOGETHER), "these panels run without brotato:together")
	t.show_crates(_ui, [2, 0, 0], [2])
	yield(t.frames(2), "completed")
	_panel(0).show_item(_unique)
	yield(t.frames(1), "completed")
	yield(_button(), "completed")
	yield(_back(), "completed")
	yield(_give_item(), "completed")
	yield(_nobody(), "completed")
	yield(_give_weapon(), "completed")
	_ui.hide()


func _button():
	var panel = _panel(0)
	var trade: Button = panel._trade_button
	_t.check(panel.trade_ui == _ui, "the crate panels offer trading")
	_t.check(
		trade.visible and not trade.disabled and trade.get_index() == panel._take_button.get_index() + 1,
		"the crate item has a Trade button below Take"
	)
	_emulator(0).focused_control = panel._take_button
	yield(_t.tap("ui_down", 0), "completed")
	_t.check(_emulator(0).focused_control == trade, "down from Take: Trade")
	yield(_t.tap("ui_accept", 0), "completed")
	var buttons: Array = panel._trade_players
	_t.check(
		buttons[0].visible and buttons[1].visible and not buttons[2].visible,
		"Trade lists the two other players"
	)
	_t.check(_to(buttons[0]) == 1 and _to(buttons[1]) == 2, "in player order")
	_t.check(
		buttons[0].disabled and not buttons[1].disabled,
		"the player who has the unique item is listed but cannot be picked"
	)
	_t.check(
		not panel._take_button.visible and not panel._discard_button.visible and not trade.visible,
		"the list replaces Take, Trade and Recycle"
	)
	_t.check(_emulator(0).focused_control == buttons[1], "the cursor is on the first one to pick")
	yield(_t.tap("ui_up", 0), "completed")
	_t.check(_emulator(0).focused_control == buttons[1], "up does not reach the one without room")
	yield(_t.tap("ui_down", 0), "completed")
	_t.check(_emulator(0).focused_control == panel._trade_cancel, "down: Cancel")


func _back():
	var panel = _panel(0)
	yield(_t.tap("ui_accept", 0), "completed")
	_t.check(
		not panel.trade_is_choosing() and panel._take_button.visible and panel._discard_button.visible,
		"Cancel leads back to the item's buttons"
	)
	var cursor = _emulator(0).focused_control
	_t.check(
		cursor == panel._trade_button,
		"the cursor is on Trade again (%s)" % [cursor.name if cursor != null else null]
	)
	yield(_press_delay(), "completed")
	yield(_t.tap("ui_accept", 0), "completed")
	_t.check(panel.trade_is_choosing(), "Trade opens the list again")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")
	_t.check(
		not panel.trade_is_choosing() and _emulator(0).focused_control == panel._trade_button,
		"so does the cancel key"
	)
	_t.check(_shown(0) == _unique, "and the crate item is still there")


func _give_item():
	var panel = _panel(0)
	var other = _panel(2)
	other.carousel.index = 1
	var element = other.player_gear_container.items_container._elements.get_child(0)
	_emulator(2).focused_control = element
	var before: Array = _counts()
	yield(_press_delay(), "completed")
	yield(_t.tap("ui_accept", 0), "completed")
	yield(_t.tap("ui_accept", 0), "completed")  # the cursor is on the only player with room
	yield(_t.frames(2), "completed")
	_t.check(
		_count(2, _unique) == 1 and _count(0, _unique) == 0 and _count(1, _unique) == 1,
		"the crate item went to player 3, not to the giver"
	)
	var after: Array = _counts()
	_t.check(
		after[0] == before[0] and after[1] == before[1] and after[2] == before[2] + 1,
		"one item more in the run, the receiver's (%s -> %s)" % [before, after]
	)
	_t.check(
		panel._items_container.visible and _shown(0) != null and not panel.trade_is_choosing(),
		"the giver's panel goes on to its next crate"
	)
	_t.check(
		other.carousel.index == 1 and _row_has(2, _unique),
		"the receiver's gear page shows the item"
	)
	var cursor = _emulator(2).focused_control
	_t.check(
		cursor != null and is_instance_valid(cursor) and cursor.is_visible_in_tree(),
		"and its cursor rests on a live element of it"
	)
	_cursors_valid("after a crate item was traded")


# Everybody has the unique item now: Trade cannot be pressed, Take still works.
func _nobody():
	var panel = _panel(0)
	panel.show_item(_unique)
	yield(_t.frames(2), "completed")
	_t.check(
		panel._trade_button.visible and panel._trade_button.disabled,
		"an item nobody can take: Trade is shown but cannot be pressed"
	)
	_t.check(not _ui.trade_crate(0, 1) and not _ui.trade_crate(0, 2), "and nothing is given")
	_t.check(_count(0, _unique) == 0, "(the giver has none)")


func _give_weapon():
	var panel = _panel(0)
	var pistol = _t.weapon()
	var weapons: Array = _t.ids(RunData.get_player_weapons_ref(0))
	panel.show_item(pistol)
	yield(_t.frames(2), "completed")
	_t.check(panel._take_button.disabled, "a giver without a free slot cannot take the pistol")
	_t.check(not panel._trade_button.disabled, "but can trade it")
	var entries: Array = _ui.trade_crate_receivers(0)
	_t.check(
		entries.size() == 2 and not entries[0][1] and entries[1][1],
		"player 2 has no room for it (%s)" % [entries]
	)
	_t.check(Rules.weapon_plan(pistol, 1) == Rules.NONE, "(by the rules of a trade)")
	_t.check(not _ui.trade_crate(0, 1), "a weapon is not given to a player without room")
	yield(_press_delay(), "completed")
	_emulator(0).focused_control = panel._trade_button
	yield(_t.tap("ui_accept", 0), "completed")
	yield(_t.tap("ui_accept", 0), "completed")
	yield(_t.frames(2), "completed")
	_t.check(
		_t.ids(RunData.get_player_weapons_ref(2)) == [_t.PISTOL],
		"the pistol went to player 3"
	)
	_t.check(
		_t.ids(RunData.get_player_weapons_ref(0)) == weapons,
		"the giver keeps all its weapons"
	)
	_t.check(panel._checkmark_group.visible, "and is done: both crates processed")
	_cursors_valid("after a crate weapon was traded")


func _press_delay():
	yield(_t.get_tree().create_timer(0.15), "timeout")


func _cursors_valid(label: String) -> void:
	var bad := []
	for p in RunData.get_player_count():
		var control = _emulator(p).focused_control
		if control == null:
			continue
		if not is_instance_valid(control) or control.is_queued_for_deletion():
			bad.append("player %d: freed" % (p + 1))
		elif not control.is_visible_in_tree():
			bad.append("player %d: hidden %s" % [p + 1, control.name])
	_t.check(bad.empty(), "every cursor rests on a live control %s %s" % [label, bad])


func _counts() -> Array:
	var counts := []
	for p in RunData.get_player_count():
		counts.append(RunData.get_player_items_ref(p).size())
	return counts


func _count(player: int, item) -> int:
	return RunData.get_nb_item(item.my_id_hash, player, false)


func _to(button) -> int:
	return button.get_meta("trade_to") if button != null and button.has_meta("trade_to") else -1


func _shown(player: int):
	return _panel(player)._item_data


func _panel(player: int):
	return _ui._get_player_container(player)


func _emulator(player: int):
	return _panel(player).focus_emulator


func _row_has(player: int, item) -> bool:
	var row: Node = _panel(player).player_gear_container.items_container._elements
	for element in row.get_children():
		if element.item != null and element.item.my_id == item.my_id:
			return true
	return false
