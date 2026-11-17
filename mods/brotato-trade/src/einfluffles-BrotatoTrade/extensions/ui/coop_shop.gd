extends "res://ui/menus/shop/coop_shop.gd"
# Trading in the co-op shop: every player's item popup asks here who can take an item
# (trade_receivers) and reports the player picked (extensions/ui/coop_item_popup.gd).
# On the game that owns the run the item changes hands at once (trade/transfer.gd) and both
# players' panels show it. In a brotato:together client's copy of the shop nothing changes:
# the request goes to the host (trade/together.gd), which answers with its next state.

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")
const Transfer := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/transfer.gd")
const Together := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/together.gd")


func _ready() -> void:
	for player_index in RunData.get_player_count():
		var popup = _get_item_popup(player_index)
		if popup.has_signal("trade_requested"):
			popup.trade_shop = self
			popup.connect("trade_requested", self, "_on_trade_requested", [player_index])


# The players `from` can give the item to right now ([]: nobody, or no trading here).
func trade_receivers(item, from: int) -> Array:
	if not Together.can_request(self, from):
		return []
	return Rules.receivers(_trade_own(item, from), from, self)


# A weapon that finds no free slot there is combined with one of the receiver's.
func trade_combines(item, to: int) -> bool:
	return Rules.is_weapon(item) and Rules.weapon_plan(item, to) == Rules.COMBINE


# Gives the item and shows it on both panels. False: nothing changed.
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


# brotato:together, host: a remote player's request. slot is the object's place in the giver's
# weapons / items and id its my_id. When the slot holds something else the first object with
# that id is given (Rules.find_named, like brotato:together's own weapon intents); a request
# naming nothing the giver owns is dropped.
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


func _on_trade_requested(item, to: int, from: int) -> void:
	if Together.is_puppet(self):
		Together.send(self, from, _trade_own(item, from), to)
		# The view half of a decision, as after combine / recycle: the popup closes.
		_on_item_cancel_button_pressed(item, from)
	elif not trade_give(item, from, to):
		_on_item_cancel_button_pressed(item, from)


# The giver's object for the item an element or popup shows. A brotato:together client's run
# gets fresh objects whenever a player's data changes (a reroll's gold), but its gear rows are
# only built again when the gear itself changed: their elements may still show the objects of
# an older state, which the player owns no more. Here they stand for the player's own.
func _trade_own(item, from: int):
	if item == null or not Together.is_puppet(self):
		return item
	var own = Rules.own_object(item, from)
	return own if own != null else item


# What the shop redoes for a player whose gear changed (the per-player part of a buy).
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
# element. The player's cursor may rest on an element or in the popup opened from one: it
# leaves first and comes back to the same place (a FocusEmulator must never keep a freed
# control), or to the shop's default when the row is empty now.
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
