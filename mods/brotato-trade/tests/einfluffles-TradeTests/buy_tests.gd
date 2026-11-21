extends Reference
# Buying an offered item for another player in plain local co-op, run by the shop suite
# (shop_tests.gd). Three players: 0 buys and has no free weapon slot, 1 has the unique item and
# no room for a pistol either, 2 has room and looks at its own gear meanwhile.

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")
const GOLD := 500
const TRADE := "brotato_trade"

var _t: Node = null
var _shop: Node = null
var _unique = null
var _plain = null


func run(t: Node):
	_t = t
	t.coop_run(3)
	_unique = t.item_with_limit(1)
	_plain = t.item_with_limit(-1, [_unique])
	_fill_weapons(0, t.weapon())
	_fill_weapons(1, t.weapon())
	RunData.add_item(_unique.duplicate(), 1)
	RunData.add_item(_plain, 2)
	RunData.add_weapon(t.weapon("weapon_smg_1"), 2)
	for p in 3:
		RunData.add_gold(GOLD, p)
	_shop = yield(t.open_shop(), "completed")
	_offer(0, 0, t.weapon())
	_offer(0, 1, _unique)
	_offer(0, 2, _plain)
	yield(t.frames(2), "completed")
	yield(_hotkey(), "completed")
	yield(_cancel(), "completed")
	yield(_buy_weapon(), "completed")
	yield(_buy_unique(), "completed")
	_gold()


func _hotkey():
	var node = _node(0, 0)
	var popup = _popup(0)
	_emulator(0).focused_control = node._button
	yield(_t.frames(1), "completed")
	_t.check(
		popup.visible and popup._trade_hint.visible and not popup._focused,
		"the hovered item's popup shows the trade hint"
	)
	_t.check(
		node._steal_button.get_parent().get_node_or_null("TradeBuyButton") == null,
		"and the item has no Trade button of its own"
	)
	yield(_t.tap(TRADE, 0), "completed")
	var players: Array = popup._trade_players
	_t.check(
		popup._focused and popup.visible and popup.trade_buy_item() == node,
		"the trade key opens the item's popup"
	)
	_t.check(not popup._trade_hint.visible, "without the hint")
	_t.check(_panel(0)._popup_dim_screen.visible, "over the dimmed panel, as for the inventory")
	_t.check(
		players[0].visible and players[1].visible and not players[2].visible,
		"it lists the two other players"
	)
	_t.check(
		players[0].disabled and not players[1].disabled,
		"player 2 has no free slot for the weapon: listed but cannot be picked"
	)
	_t.check(
		not popup._combine_button.visible and not popup._discard_button.visible,
		"none of the inventory's weapon buttons"
	)
	_t.check(_emulator(0).focused_control == players[1], "the cursor is on player 3")
	yield(_t.tap("ui_up", 0), "completed")
	_t.check(_emulator(0).focused_control == players[1], "up does not reach player 2")
	yield(_t.tap(TRADE, 0), "completed")
	_t.check(popup._focused and players[1].visible, "the trade key does nothing in the open list")
	yield(_t.tap("ui_down", 0), "completed")
	_t.check(_emulator(0).focused_control == popup._cancel_button, "down: Cancel")


func _cancel():
	var node = _node(0, 0)
	var popup = _popup(0)
	yield(_t.tap("ui_accept", 0), "completed")
	yield(_t.frames(1), "completed")
	_t.check(
		not popup._focused and not _panel(0)._popup_dim_screen.visible,
		"Cancel closes the popup"
	)
	_t.check(_emulator(0).focused_control == node._button, "the cursor is on the item again")
	yield(_press_delay(), "completed")
	yield(_t.tap(TRADE, 0), "completed")
	_t.check(popup._focused and popup.trade_buy_item() == node, "the trade key opens it again")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")
	_t.check(
		not popup._focused and _emulator(0).focused_control == node._button,
		"so does the cancel key"
	)
	_t.check(node.active and _t.ids(RunData.get_player_weapons_ref(2)).size() == 1, "nothing bought")


func _buy_weapon():
	var node = _node(0, 0)
	node.change_lock_status(true)
	var price: int = node.value
	var gold := _golds()
	var mine: Array = _t.ids(RunData.get_player_weapons_ref(0))
	var offers := _offered(0, _t.PISTOL)
	var other = _emulator(2)
	var element = _row(2, true).get_child(0)
	other.focused_control = element
	yield(_t.tap("ui_accept", 2), "completed")
	_t.check(_popup(2)._focused, "(player 3 looks at its own weapon)")
	yield(_press_delay(), "completed")
	yield(_t.tap(TRADE, 0), "completed")
	yield(_t.tap("ui_accept", 0), "completed")  # the cursor is on the only player with room
	yield(_t.frames(2), "completed")
	_t.check(
		_t.ids(RunData.get_player_weapons_ref(2)).has(_t.PISTOL),
		"the pistol went to player 3"
	)
	_t.check(
		_t.ids(RunData.get_player_weapons_ref(0)) == mine,
		"the giver, its slots full, keeps every weapon (%d)" % mine.size()
	)
	_t.check(
		_golds() == [gold[0] - price, gold[1], gold[2]],
		"the giver paid the price, nobody else (%s -> %s, %d)" % [gold, _golds(), price]
	)
	_t.check(not node.active and not node.locked, "the slot is bought and unlocked, as by a buy")
	_t.check(_offered(0, _t.PISTOL) == offers - 1, "and gone from the giver's offers")
	_t.check(
		_has_element(2, true, _t.PISTOL) and "(2/" in _weapons_label(2),
		"the receiver's row shows it"
	)
	_t.check(not _popup(2)._focused, "the receiver's popup on its old row closed")
	var cursor = other.focused_control
	_t.check(
		cursor != null and is_instance_valid(cursor) and cursor.get_parent() == _row(2, true),
		"and its cursor is on its weapons again"
	)
	_t.check(not _shop.trade_buy(node, 0, 2), "a bought slot cannot be bought again")
	_cursors_valid("after a buy for another player")


# Player 1 has the unique item: only player 2 can get it. Then nobody can.
func _buy_unique():
	var node = _node(0, 1)
	var entries: Array = _shop.trade_buy_receivers(node, 0)
	_t.check(
		entries.size() == 2 and not entries[0][1] and entries[1][1],
		"a unique item: not for the player who has it (%s)" % [entries]
	)
	_t.check(not _shop.trade_buy(node, 0, 1), "and not bought for it")
	_t.check(not _shop.trade_buy(node, 0, 2), "(not inside the buy delay of the last buy)")
	yield(_press_delay(), "completed")
	_t.check(_shop.trade_buy(node, 0, 2), "bought for the other")
	_t.check(
		_count(2, _unique) == 1 and _count(0, _unique) == 0 and _count(1, _unique) == 1,
		"which has it now, and the giver has none"
	)
	_offer(0, 3, _unique)
	yield(_t.frames(2), "completed")
	yield(_press_delay(), "completed")
	_emulator(0).focused_control = _node(0, 3)._button
	yield(_t.frames(1), "completed")
	_t.check(not _popup(0)._trade_hint.visible, "nobody to buy it for: no trade hint")
	yield(_t.tap(TRADE, 0), "completed")
	_t.check(not _popup(0)._focused, "and the trade key opens nothing")


func _gold() -> void:
	var node = _node(0, 2)
	RunData.remove_gold(RunData.get_player_gold(0), 0)
	var before: String = _t.ledger()
	_t.check(node.value > 0 and not _shop.trade_buy(node, 0, 2), "without the gold nothing is bought")
	_t.check(node.active and _t.ledger() == before, "the slot stays, nobody got anything")


func _fill_weapons(p: int, weapon) -> void:
	for other in ItemService.weapons:
		if not RunData.has_weapon_slot_available(weapon, p):
			return
		if other.my_id != weapon.my_id and other.tier == 0 and other.type == weapon.type:
			RunData.add_weapon(other, p)


# Player p's shop slot i offers the item, in the shop's list too (BaseShop._shop_items).
func _offer(p: int, i: int, item) -> void:
	var node = _node(p, i)
	for entry in _shop._shop_items[p]:
		if entry[0] == node.item_data:
			entry[0] = item
			break
	node.set_shop_item(item, node.wave_value)
	node.activate()


func _offered(p: int, my_id: String) -> int:
	var count := 0
	for entry in _shop._shop_items[p]:
		count += 1 if entry[0].my_id == my_id else 0
	return count


func _golds() -> Array:
	var golds := []
	for p in RunData.get_player_count():
		golds.append(RunData.get_player_gold(p))
	return golds


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


func _count(player: int, item) -> int:
	return RunData.get_nb_item(item.my_id_hash, player, false)


func _node(p: int, i: int):
	return _shop._get_shop_items_container(p)._shop_items[i]


func _popup(player: int):
	return _shop._get_item_popup(player)


func _panel(player: int):
	return _shop._get_coop_player_container(player)


func _emulator(player: int):
	return Utils.get_focus_emulator(player, _shop)


func _row(player: int, weapons: bool) -> Node:
	var gear = _shop._get_gear_container(player)
	return gear.weapons_container._elements if weapons else gear.items_container._elements


func _weapons_label(player: int) -> String:
	return _shop._get_gear_container(player).weapons_container.get_label().text


func _has_element(player: int, weapons: bool, my_id: String) -> bool:
	for element in _row(player, weapons).get_children():
		if not element.is_queued_for_deletion() and element.item != null:
			if element.item.my_id == my_id:
				return true
	return false
