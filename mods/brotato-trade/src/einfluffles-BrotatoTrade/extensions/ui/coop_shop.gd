extends "res://ui/menus/shop/coop_shop.gd"
# Trading in the co-op shop: giving owned gear (trade_give) and buying an offered item for another
# player (trade_buy). In a brotato:together client's copy of the shop nothing changes: the request
# goes to the host (trade/together.gd).

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")
const Transfer := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/transfer.gd")
const Together := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/together.gd")
const TRADE_BUY_TEXT := "Trade"
const TRADE_OK_META := "trade_ok"

var _trade_buy_to := -1  # while a buy goes to another player: that player
var _trade_buy_buttons := {}  # ShopItem -> [its Trade button, its player]


func _ready() -> void:
	for player_index in RunData.get_player_count():
		var popup = _get_item_popup(player_index)
		if popup.has_signal("trade_requested"):
			popup.trade_shop = self
			popup.connect("trade_requested", self, "_on_trade_requested", [player_index])
			popup.connect("trade_buy_requested", self, "_on_trade_buy_requested", [player_index])
			popup.connect("trade_buy_closed", self, "_on_trade_buy_closed", [player_index])
			for node in _get_shop_items_container(player_index)._shop_items:
				_trade_buy_add_button(node, player_index)


func _process(_delta: float) -> void:
	for node in _trade_buy_buttons:
		var entry: Array = _trade_buy_buttons[node]
		var shown := trade_buy_offered(node, entry[1])
		var ok := false
		if shown:
			for receiver in trade_buy_receivers(node, entry[1]):
				ok = ok or receiver[1]
		_trade_buy_set(entry[0], shown, ok)
		var right: NodePath = node._button.get_path_to(entry[0]) if ok else NodePath(".")
		if node._button.focus_neighbour_right != right:
			node._button.focus_neighbour_right = right


func trade_buy_offered(shop_item: Node, from: int) -> bool:
	if RunData.get_player_count() < 2 or not Together.can_request_buy(self, from):
		return false
	var item = shop_item.item_data
	return shop_item.active and item != null and not item.is_meca


# [player, has room for it, combines it] for every other player.
func trade_buy_receivers(shop_item: Node, from: int) -> Array:
	var entries := []
	for to in RunData.get_player_count():
		if to != from:
			var ok := trade_buy_room(shop_item, to)
			var combines: bool = ok and Rules.is_weapon(shop_item.item_data)
			combines = combines and not RunData.has_weapon_slot_available(shop_item.item_data, to)
			entries.append([to, ok, combines])
	return entries


func trade_buy_room(shop_item: Node, to: int) -> bool:
	var item = shop_item.item_data
	if item == null or not Rules.is_player(to):
		return false
	if Rules.is_weapon(item):
		return _get_shop_items_container(to)._can_weapon_be_bought(shop_item)
	return Rules.can_receive(item, to, self)


# The steps of ShopItemsContainer's buy press: the delay, the giver's gold (else the game's shake),
# then the container's signal, which runs BaseShop.on_shop_item_bought for the giver.
func trade_buy(shop_item: Node, from: int, to: int) -> bool:
	if get_tree().paused or Together.is_puppet(self):
		return false
	if from == to or not Rules.is_player(from) or not Rules.is_player(to):
		return false
	var container = _get_shop_items_container(from)
	if not shop_item in container._shop_items or not trade_buy_offered(shop_item, from):
		return false
	if container._is_delay_active:
		return false
	if RunData.get_player_currency(from) < shop_item.value:
		container.emit_signal("shop_item_insufficient_currency", shop_item)
		return false
	if not trade_buy_room(shop_item, to):
		return false
	var cursor := _trade_buy_park(to)
	var reroll_price: int = RunData.get_player_effect(Keys.reroll_price_hash, to)
	_trade_buy_to = to
	container.emit_signal("shop_item_bought", shop_item)
	_trade_buy_to = -1
	shop_item.deactivate()
	container.update_buttons_color()
	container._is_delay_active = true
	container._buy_delay_timer.start()
	_trade_buy_after(to, reroll_price)
	# After the game's own deferred cursor moves (a combine moves the buyer's).
	call_deferred("_trade_buy_unpark", to, cursor)
	return true


func trade_buy_apply_request(from: int, slot: int, id: String, to: int) -> bool:
	if not Rules.is_player(from):
		return false
	var nodes: Array = _get_shop_items_container(from)._shop_items
	var found = null
	if slot >= 0 and slot < nodes.size() and _trade_offers(nodes[slot], id):
		found = nodes[slot]
	for node in nodes:
		if found == null and _trade_offers(node, id):
			found = node
	return found != null and trade_buy(found, from, to)


# While a buy goes to another player, BaseShop.buy_item / buy_weapon run for the receiver: the
# item enters the receiver as a bought one does.
func buy_item(item_data: ItemData, player_index: int) -> void:
	.buy_item(item_data, _trade_buy_to if _trade_buy_to >= 0 else player_index)


func buy_weapon(item_data: WeaponData, player_index: int) -> void:
	.buy_weapon(item_data, _trade_buy_to if _trade_buy_to >= 0 else player_index)


func trade_receivers(item, from: int) -> Array:
	if not Together.can_request(self, from):
		return []
	return Rules.receivers(_trade_own(item, from), from, self)


func trade_combines(item, to: int) -> bool:
	return Rules.is_weapon(item) and Rules.weapon_plan(item, to) == Rules.COMBINE


func trade_give(item, from: int, to: int) -> bool:
	if get_tree().paused or Together.is_puppet(self):
		return false
	var result: Dictionary = Transfer.give(item, from, to, self)
	if result.empty():
		return false
	_trade_refresh_player(from)
	_trade_refresh_player(to)
	if result.combined:
		SoundManager.play(Utils.get_rand_element(combine_sounds), 0, 0.1, true)
	return true


func trade_apply_request(weapon: bool, from: int, slot: int, id: String, to: int) -> bool:
	if not Rules.is_player(from):
		return false
	var owned: Array = (
		RunData.get_player_weapons_ref(from)
		if weapon
		else RunData.get_player_items_ref(from)
	)
	var item = Rules.find_named(owned, slot, id)
	return item != null and trade_give(item, from, to)


func _on_trade_buy_pressed(shop_item: Node, from: int) -> void:
	if not trade_buy_offered(shop_item, from):
		return
	var entries := trade_buy_receivers(shop_item, from)
	var anyone := false
	for entry in entries:
		anyone = anyone or entry[1]
	if not anyone:
		return
	_get_coop_player_container(from).on_show_focused_inventory_popup()  # the dim screen
	_get_item_popup(from).trade_open_buy(shop_item, entries)


func _on_trade_buy_requested(shop_item: Node, to: int, from: int) -> void:
	_trade_buy_close(from)
	if Together.is_puppet(self):
		Together.send_buy(self, from, shop_item, to)
		_trade_buy_refocus(shop_item, from)
	elif not trade_buy(shop_item, from, to):
		_trade_buy_refocus(shop_item, from)


func _on_trade_buy_closed(shop_item: Node, from: int) -> void:
	_trade_buy_close(from)
	_trade_buy_refocus(shop_item, from)


func _trade_buy_close(player_index: int) -> void:
	_popup_manager.reset_focus(player_index)
	_get_coop_player_container(player_index).on_hide_focused_inventory_popup()


func _trade_buy_refocus(shop_item: Node, player_index: int) -> void:
	var emulator = Utils.get_focus_emulator(player_index, self)
	if emulator == null:
		return
	var target: Control = _get_default_focus_control(player_index)
	if is_instance_valid(shop_item) and shop_item.active:
		target = shop_item._button
		var button: Button = _trade_buy_buttons[shop_item][0]
		if button.visible and button.get_meta(TRADE_OK_META):
			target = button
	if target != null and target.is_visible_in_tree():
		emulator.focused_control = target


# The receiver's part of BaseShop.on_shop_item_bought, which ran for the giver.
func _trade_buy_after(to: int, reroll_price_before: int) -> void:
	_update_stats(to)
	_get_shop_items_container(to).reload_shop_items()
	var reroll_price_after: int = RunData.get_player_effect(Keys.reroll_price_hash, to)
	if _reroll_price[to] > 0 and reroll_price_after < reroll_price_before:
		var price: Array = ItemService.get_reroll_price(
			RunData.current_wave, _paid_reroll_count[to], to
		)
		_reroll_price[to] = price[0]
		_reroll_discount[to] = price[1]
	var free_rerolls: int = RunData.get_player_effect(Keys.free_rerolls_hash, to)
	if free_rerolls > _initial_free_rerolls[to]:
		_free_rerolls[to] += free_rerolls - _initial_free_rerolls[to]
		_initial_free_rerolls[to] = free_rerolls
	_refresh_bonus_free_reroll(to)
	_refresh_currency_dependent_buttons(to)


# The receiver's rows change under its cursor: a cursor in them, or in a popup opened from
# them, leaves first ([row, index], or [-1]); a cursor elsewhere is remembered ([control]).
func _trade_buy_park(player_index: int) -> Array:
	var emulator = Utils.get_focus_emulator(player_index, self)
	if emulator == null:
		return []
	var gear = _get_gear_container(player_index)
	var rows := [gear.weapons_container._elements, gear.items_container._elements]
	var element = emulator.focused_control
	var in_popup: bool = _popup_manager._elements_pressed[player_index] != null
	if in_popup:
		element = _popup_manager._elements_pressed[player_index]
		_trade_buy_close(player_index)
	for i in rows.size():
		if element != null and is_instance_valid(element) and element.get_parent() == rows[i]:
			emulator.focused_control = null
			return [i, element.get_index()]
	if in_popup:
		emulator.focused_control = null
		return [-1]
	return [element] if element != null else []


func _trade_buy_unpark(player_index: int, cursor: Array) -> void:
	var emulator = Utils.get_focus_emulator(player_index, self)
	if emulator == null or cursor.empty() or not is_inside_tree():
		return
	var target = null
	if cursor.size() == 2:
		var gear = _get_gear_container(player_index)
		var row: Node = [gear.weapons_container._elements, gear.items_container._elements][cursor[0]]
		var live := []
		for child in row.get_children():
			if not child.is_queued_for_deletion():
				live.append(child)
		if not live.empty():
			target = live[int(min(cursor[1], live.size() - 1))]
	elif cursor[0] is Control and is_instance_valid(cursor[0]):
		target = cursor[0]
	if target == null or target.is_queued_for_deletion() or not target.is_visible_in_tree():
		target = _get_default_focus_control(player_index)
	if target != null and target.is_visible_in_tree() and emulator.focused_control != target:
		emulator.focused_control = target


static func _trade_offers(node: Node, id: String) -> bool:
	return node.active and node.item_data != null and node.item_data.my_id == id


# Right of the price, where the single-player shop has its Lock / Steal buttons.
func _trade_buy_add_button(node: Node, player_index: int) -> void:
	var template: Button = node._steal_button
	var button := Button.new()
	button.name = "TradeBuyButton"
	button.set_script(template.get_script())
	button.add_font_override("font", template.get_font("font"))
	button.text = TRADE_BUY_TEXT
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.focus_mode = FOCUS_NONE
	button.visible = false
	template.get_parent().add_child(button)
	button.focus_neighbour_left = button.get_path_to(node._button)
	button.focus_neighbour_right = NodePath(".")
	button.connect("pressed", self, "_on_trade_buy_pressed", [node, player_index])
	_trade_buy_buttons[node] = [button, player_index]


# ok: can be pressed. The game's own disable / activate: a disabled button takes no focus and no
# mouse.
static func _trade_buy_set(button: Button, shown: bool, ok: bool) -> void:
	if button.visible != shown:
		button.visible = shown
	ok = ok and shown
	if button.has_meta(TRADE_OK_META) and button.get_meta(TRADE_OK_META) == ok:
		return
	button.set_meta(TRADE_OK_META, ok)
	if ok:
		button.activate()
	else:
		button.disable()


func _on_trade_requested(item, to: int, from: int) -> void:
	if Together.is_puppet(self):
		Together.send(self, from, _trade_own(item, from), to)
		# The view half of a decision, as after combine / recycle: the popup closes.
		_on_item_cancel_button_pressed(item, from)
	elif not trade_give(item, from, to):
		_on_item_cancel_button_pressed(item, from)


# A brotato:together client's run gets fresh objects whenever a player's data changes (a reroll's
# gold), but its gear rows are only built again when the gear changed: an element can show an
# object the player owns no more.
func _trade_own(item, from: int):
	if item == null or not Together.is_puppet(self):
		return item
	var own = Rules.own_object(item, from)
	return own if own != null else item


# The per-player part of what the shop redoes after a buy.
func _trade_refresh_player(player_index: int) -> void:
	_trade_refresh_gear(player_index)
	_update_stats(player_index)
	# Prices and what can be bought follow the items and the free weapon slots.
	_get_shop_items_container(player_index).reload_shop_items()
	var price: Array = ItemService.get_reroll_price(
		RunData.current_wave, _paid_reroll_count[player_index], player_index
	)
	_reroll_price[player_index] = price[0]
	_reroll_discount[player_index] = price[1]
	set_reroll_button_price(player_index)
	_refresh_currency_dependent_buttons(player_index)


# Both gear rows are built again, as the game does after a buy that changed more than one
# element. The cursor leaves them first: a FocusEmulator must never keep a freed control.
func _trade_refresh_gear(player_index: int) -> void:
	var gear = _get_gear_container(player_index)
	var rows := [gear.weapons_container._elements, gear.items_container._elements]
	var emulator = Utils.get_focus_emulator(player_index, self)
	var element = emulator.focused_control if emulator != null else null
	var in_popup: bool = _popup_manager._elements_pressed[player_index] != null
	if in_popup:
		element = _popup_manager._elements_pressed[player_index]
		_popup_manager.reset_focus(player_index)
		_get_coop_player_container(player_index).on_hide_focused_inventory_popup()
	var place := []
	if element != null and is_instance_valid(element):
		for i in rows.size():
			if element.get_parent() == rows[i]:
				place = [i, element.get_index()]
	if emulator != null and (in_popup or not place.empty()):
		emulator.focused_control = null

	gear.set_weapons_data(RunData.get_player_weapons(player_index))
	gear.set_items_data(RunData.get_player_items(player_index))

	if emulator == null or not (in_popup or not place.empty()):
		return
	var target: Control = null
	if not place.empty() and rows[place[0]].get_child_count() > 0:
		var row: Node = rows[place[0]]
		target = row.get_child(int(min(place[1], row.get_child_count() - 1)))
	if target == null or not target.is_visible_in_tree():
		target = _get_default_focus_control(player_index)
	if target != null and target.is_visible_in_tree():
		emulator.focused_control = target
