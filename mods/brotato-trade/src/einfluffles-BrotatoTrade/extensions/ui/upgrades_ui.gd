extends "res://ui/menus/ingame/upgrades_ui.gd"
# Trading on the co-op crate panels. The game's own Take runs with the receiver as the one who
# takes: the item enters the receiver as a taken crate item does (stat-gain effects, mutation, a
# weapon combined without a free slot), and the giver's panel goes on to its next option.

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")
const Together := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/together.gd")


func _ready() -> void:
	if not is_coop_ui or not RunData.is_coop_run:
		return
	for player_index in RunData.get_player_count():
		var container = _get_player_container(player_index)
		if container.has_signal("trade_requested"):
			container.trade_ui = self
			container.connect("trade_requested", self, "_on_trade_crate_requested", [player_index])


func trade_crate_offered(from: int) -> bool:
	return RunData.get_player_count() > 1 and Together.can_show_crate(self, from)


# [player, can take the item, combines it] for every other player.
func trade_crate_receivers(from: int) -> Array:
	var entries := []
	var item = _get_player_container(from)._item_data
	for to in RunData.get_player_count():
		if to == from:
			continue
		var ok: bool = Rules.can_take_crate(item, to)
		var combines: bool = ok and Rules.is_weapon(item)
		combines = combines and not RunData.has_weapon_slot_available(item, to)
		entries.append([to, ok, combines])
	return entries


func trade_crate(from: int, to: int) -> bool:
	if get_tree().paused or Together.is_puppet_ui(self):
		return false
	if from == to or not Rules.is_player(from) or not Rules.is_player(to):
		return false
	var container = _get_player_container(from)
	var item = container._item_data
	if item == null or not container._items_container.visible:
		return false
	if container._checkmark_group.visible or container._button_pressed:
		return false
	if item.is_meca and container._meca_effect_choice_selected == -1:
		return false
	if not Rules.can_take_crate(item, to):
		return false
	var cursor := _trade_park_cursor(to)
	# The container's Take press without its check of the giver's weapon slots.
	container._button_pressed = true
	container._button_delay_timer.start()
	if item.is_meca:
		item = DLC2Data.change_effect_option_to_modular_effect(
			item, container._meca_effect_choice_selected
		)
		container._item_data = item
	if container._things_to_process_container:
		container._things_to_process_container.consumables.remove_element(
			container._consumable_data
		)
	# The take handlers give the item to the option's player: the receiver, for this press.
	var option = _showing_option[from]
	var taker = ConsumableToProcess.new()
	taker.consumable_data = option.consumable_data if option != null else container._consumable_data
	taker.player_index = to
	_showing_option[from] = taker
	container.emit_signal("item_take_button_pressed", item)
	if _showing_option[from] == taker:
		_showing_option[from] = option  # more items from the same crate to come
	_trade_refresh_receiver(to, cursor)
	return true


# id: the crate item the request was made on. The panel can show another by now.
func trade_crate_apply_request(from: int, id: String, to: int) -> bool:
	if not Rules.is_player(from):
		return false
	var item = _get_player_container(from)._item_data
	return item != null and item.my_id == id and trade_crate(from, to)


func _on_trade_crate_requested(to: int, from: int) -> void:
	var container = _get_player_container(from)
	if Together.is_puppet_ui(self):
		var item = container._item_data
		if item != null:
			Together.send_crate(self, from, item.my_id, to)
		container.trade_back(true)
	elif not trade_crate(from, to):
		container.trade_back(true)


# What the game's _after_weapons_changed redoes, without moving the cursor.
func _trade_refresh_receiver(player_index: int, cursor: Array) -> void:
	var container = _get_player_container(player_index)
	LinkedStats.reset_player(player_index)
	_update_player_stats(player_index)
	container.update_inventory()
	container.refresh_take_button()
	_refresh_weapons_inventory(player_index)
	_trade_restore_cursor(player_index, cursor)


func _trade_rows(player_index: int) -> Array:
	var container = _get_player_container(player_index)
	var gear = container.player_gear_container
	return [
		gear.weapons_container._elements,
		gear.items_container._elements,
		container.crate_weapons_container._elements,
	]


# The receiver's cursor leaves the rows that are built again, and a popup opened from them
# closes. [row, index] of where it was, [-1] when it was in the popup with no element to come
# back to, [] when it stays where it is.
func _trade_park_cursor(player_index: int) -> Array:
	var emulator = _get_player_container(player_index).focus_emulator
	if emulator == null or emulator.player_index != player_index:
		return []
	var element = emulator.focused_control
	var in_popup: bool = _popup_manager._elements_pressed[player_index] != null
	if in_popup:
		element = _popup_manager._elements_pressed[player_index]
		_popup_manager.reset_focus(player_index)
	var rows := _trade_rows(player_index)
	var place := [-1] if in_popup else []
	if element != null and is_instance_valid(element):
		for i in rows.size():
			if element.get_parent() == rows[i]:
				place = [i, element.get_index()]
	if not place.empty():
		emulator.focused_control = null
	return place


func _trade_restore_cursor(player_index: int, place: Array) -> void:
	if place.empty():
		return
	var container = _get_player_container(player_index)
	var target: Control = null
	if place.size() == 2:
		var row: Node = _trade_rows(player_index)[place[0]]
		if row.get_child_count() > 0:
			target = row.get_child(int(min(place[1], row.get_child_count() - 1)))
	if target != null and target.is_visible_in_tree():
		container.focus_emulator.focused_control = target
	else:
		container.focus()
