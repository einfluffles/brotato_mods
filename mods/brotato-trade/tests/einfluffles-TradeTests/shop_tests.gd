extends Reference
# The co-op shop in plain local co-op. Three players: 0 gives, 1 already has the unique item, 2
# has nothing.

const Rules := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/rules.gd")

var _t: Node = null
var _shop: Node = null
var _plain = null  # an item without a limit
var _unique = null


func run(t: Node):
	_t = t
	t.coop_run(3)
	_plain = t.item_with_limit(-1)
	_unique = t.item_with_limit(1)
	RunData.add_item(_plain, 0)
	RunData.add_item(_plain, 0)
	RunData.add_item(_unique, 0)
	RunData.add_item(_unique.duplicate(), 1)
	for _i in 2:
		RunData.add_weapon(t.weapon(), 0)
	_shop = yield(t.open_shop(), "completed")
	t.check(not t.has_node(t.TOGETHER), "this shop runs without brotato:together")
	yield(_item_popup(), "completed")
	yield(_back(), "completed")
	yield(_give_item(), "completed")
	yield(_unique_item(), "completed")
	yield(_give_weapon(), "completed")
	yield(_receiver_popup(), "completed")
	_refusals()
	yield(_receiver_combine(), "completed")
	yield(_kept_popup_buttons(), "completed")
	yield(_other_popup(), "completed")
	yield(_four_players(), "completed")
	var buy = load(t.DIR + "buy_tests.gd").new()
	yield(buy.run(t), "completed")


# An item has no popup buttons in the game. Here it has Trade and Cancel.
func _item_popup():
	var popup = _popup(0)
	var emulator = _emulator(0)
	_t.check(popup.trade_shop == _shop, "the shop's item popups offer trading")
	var character = _element(0, RunData.get_player_character(0))
	emulator.focused_control = character
	yield(_t.tap("ui_accept", 0), "completed")
	_t.check(
		not popup._focused and emulator.focused_control == character,
		"an item nobody can take stays a plain card"
	)
	emulator.focused_control = _element(0, _plain)
	yield(_t.frames(1), "completed")
	_t.check(
		popup.visible and popup._coop_inventory_hint.visible and not popup._trade_button.visible,
		"an item that can be given shows the game's hint to open the popup"
	)
	yield(_t.tap("ui_accept", 0), "completed")
	_t.check(popup._focused, "accept on it opens the popup")
	_t.check(
		(
			popup._trade_button.visible
			and popup._cancel_button.visible
			and not popup._combine_button.visible
			and not popup._discard_button.visible
		),
		"with Trade and Cancel and none of the weapon buttons"
	)
	_t.check(emulator.focused_control == popup._cancel_button, "the cursor starts on Cancel")
	yield(_t.tap("ui_up", 0), "completed")
	_t.check(emulator.focused_control == popup._trade_button, "Trade is the button above it")
	yield(_t.tap("ui_accept", 0), "completed")
	var buttons: Array = popup._trade_players
	_t.check(
		buttons[0].visible and buttons[1].visible and not buttons[2].visible,
		"Trade lists the two other players"
	)
	_t.check(
		_to(buttons[0]) == 1 and _to(buttons[1]) == 2 and "2" in buttons[0].text,
		"in player order (%s, %s)" % [buttons[0].text, buttons[1].text]
	)
	_t.check(
		not popup._trade_button.visible and popup._cancel_button.visible,
		"in place of the Trade button, above Cancel"
	)
	_t.check(emulator.focused_control == buttons[0], "the cursor is on the first player")
	yield(_t.tap("ui_down", 0), "completed")
	_t.check(emulator.focused_control == buttons[1], "down: the next player")
	yield(_t.tap("ui_down", 0), "completed")
	_t.check(emulator.focused_control == popup._cancel_button, "then Cancel")


func _back():
	var popup = _popup(0)
	var emulator = _emulator(0)
	yield(_t.tap("ui_accept", 0), "completed")
	_t.check(
		popup._focused and popup._trade_button.visible and not popup._trade_players[0].visible,
		"the Cancel button closes the list, not the popup"
	)
	_t.check(emulator.focused_control == popup._trade_button, "the cursor is back on Trade")
	yield(_press_delay(), "completed")
	yield(_t.tap("ui_accept", 0), "completed")
	_t.check(popup._trade_players[0].visible, "Trade opens the list again")
	yield(_t.tap("ui_cancel", 0), "completed")
	_t.check(
		popup._focused and popup.visible and not popup._trade_players[0].visible,
		"the cancel key closes the list, not the popup"
	)
	_t.check(emulator.focused_control == popup._trade_button, "with the cursor on Trade again")
	yield(_t.tap("ui_cancel", 0), "completed")
	_t.check(not popup._focused, "a second cancel closes the popup")
	_t.check(emulator.focused_control == _element(0, _plain), "and the cursor is on the item again")


func _give_item():
	var popup = _popup(0)
	var emulator = _emulator(0)
	var other = _emulator(2)
	var theirs: Control = _shop._get_go_button(2)
	other.focused_control = theirs
	var before: String = _t.ledger()
	yield(_open_list(0, _plain), "completed")
	yield(_t.tap("ui_accept", 0), "completed")  # the first player in the list: player 1
	yield(_t.frames(2), "completed")
	_t.check(
		_count(0, _plain) == 1 and _count(1, _plain) == 1 and _count(2, _plain) == 0,
		"the item went to the player picked, one copy of two"
	)
	_t.check(_t.ledger() == before, "nothing appeared or vanished")
	_t.check(
		not popup._focused and not _panel(0)._popup_dim_screen.visible,
		"the giver's popup closed"
	)
	var given = _element(0, _plain)
	_t.check(
		given != null and given.current_number == 1 and emulator.focused_control == given,
		"the giver's row shows one copy left, the cursor on it"
	)
	var received = _element(1, _plain)
	_t.check(received != null and received.current_number == 1, "the receiver's row shows the item")
	_t.check(other.focused_control == theirs, "a player who was not part of it keeps its cursor")
	_cursors_valid("after giving an item")


# Player 1 has the unique item: only player 2 is offered. Once everybody has one, nobody is.
# A player whose shop offers it gets none either (Rules.can_receive).
func _unique_item():
	var popup = _popup(0)
	var offers: Array = _shop._get_shop_items_container(2)._shop_items
	for node in offers:
		if node.active and node.item_data == _unique:
			node.set_shop_item(_plain)  # rolled by chance: out of the way
	var slot = offers[0]
	var rolled = slot.item_data
	slot.set_shop_item(_unique)
	_t.check(_shop.trade_receivers(_unique, 0).empty(), "nor to a player whose shop offers it")
	_t.check(Rules.receivers(_unique, 0) == [2], "(the shop's offers make the difference)")
	slot.set_shop_item(rolled)
	yield(_open_list(0, _unique), "completed")
	var buttons: Array = popup._trade_players
	_t.check(
		buttons[0].visible and not buttons[1].visible and _to(buttons[0]) == 2,
		"a unique item is only offered to the player without it"
	)
	yield(_t.tap("ui_accept", 0), "completed")
	yield(_t.frames(2), "completed")
	_t.check(
		_count(0, _unique) == 0 and _count(1, _unique) == 1 and _count(2, _unique) == 1,
		"and goes there: one each now"
	)
	_t.check(_element(0, _unique) == null, "the giver's row no longer shows it")
	var theirs = _element(2, _unique)
	_t.check(_shop.trade_receivers(theirs.item, 2) == [0], "it could only go back to the giver")
	RunData.add_item(_unique.duplicate(), 0)
	_emulator(2).focused_control = theirs
	yield(_t.tap("ui_accept", 2), "completed")
	_t.check(not _popup(2)._focused, "everybody has one: no popup buttons for it")
	_cursors_valid("after giving the unique item")


func _give_weapon():
	var popup = _popup(0)
	var emulator = _emulator(0)
	var before: String = _t.ledger()
	var weapon = RunData.get_player_weapons_ref(0)[0]
	emulator.focused_control = _element(0, weapon)
	yield(_t.tap("ui_accept", 0), "completed")
	_t.check(
		popup._focused and popup._combine_button.visible and popup._discard_button.visible,
		"a weapon's popup keeps the game's buttons"
	)
	_t.check(popup._trade_button.visible, "and has Trade as well")
	yield(_t.tap("ui_up", 0), "completed")
	_t.check(emulator.focused_control == popup._trade_button, "between Recycle and Cancel")
	yield(_t.tap("ui_up", 0), "completed")
	_t.check(emulator.focused_control == popup._discard_button, "(Recycle is above it)")
	yield(_t.tap("ui_down", 0), "completed")
	yield(_t.tap("ui_accept", 0), "completed")
	_t.check(
		not popup._combine_button.visible and not popup._discard_button.visible,
		"the list of players replaces the weapon buttons too"
	)
	yield(_t.tap("ui_down", 0), "completed")
	_t.check(_to(emulator.focused_control) == 2, "the cursor is on player 3")
	yield(_t.tap("ui_accept", 0), "completed")
	yield(_t.frames(2), "completed")
	var theirs: Array = RunData.get_player_weapons_ref(2)
	_t.check(
		RunData.get_player_weapons_ref(0).size() == 1 and _t.ids(theirs) == [_t.PISTOL],
		"the weapon went to player 3"
	)
	_t.check(_t.ledger() == before, "no weapon appeared or vanished")
	_t.check(
		_row(0, true).get_child_count() == 1 and _element(2, theirs[0]) != null,
		"both weapon rows show it"
	)
	_t.check(
		"(1/" in _shop._get_gear_container(2).weapons_container.get_label().text,
		"and the receiver's row counts it"
	)
	_t.check(
		not popup._focused and emulator.focused_control.get_parent() == _row(0, true),
		"the giver's cursor is on its other weapon"
	)
	_cursors_valid("after giving a weapon")


# The receiver has its own popup open when it is given something.
func _receiver_popup():
	var theirs = _emulator(2)
	var their_popup = _popup(2)
	var element = _element(2, RunData.get_player_weapons_ref(2)[0])
	theirs.focused_control = element
	yield(_t.tap("ui_accept", 2), "completed")
	var cursor = theirs.focused_control
	_t.check(their_popup._focused, "the receiver looks at its own weapon")
	var weapon = RunData.get_player_weapons_ref(0)[0]
	_t.check(_shop.trade_give(weapon, 0, 2), "meanwhile it is given another weapon")
	_t.check(_shop.trade_give(_plain, 0, 2), "and an item")
	yield(_t.frames(2), "completed")
	_t.check(
		their_popup._focused and _panel(2)._popup_dim_screen.visible and theirs.focused_control == cursor,
		"its popup stays open, its cursor where it was"
	)
	_t.check(_shop._popup_manager._elements_pressed[2] == element, "on the same weapon")
	_t.check(
		_row(2, true).get_child_count() == 2 and _element(2, _plain) != null,
		"its rows show what came"
	)
	_t.check("(2/" in _shop._get_gear_container(2).weapons_container.get_label().text, "and count it")
	_cursors_valid("after a hand-over to a player with an open popup")
	yield(_t.tap("ui_cancel", 2), "completed")
	_t.check(not their_popup._focused and theirs.focused_control == element, "cancel closes it")
	_t.check(_shop.trade_give(_plain, 2, 0), "(the item given back)")


# A weapon given to a player without a free slot combines with one of its own: a popup on another
# weapon stays open, one on the weapon that went closes.
func _receiver_combine():
	var pistol = _t.weapon()
	for _i in 2:
		RunData.add_weapon(pistol, 0)
	_t.fill_weapons(2, pistol)
	for p in [0, 2]:
		_emulator(p).focused_control = null  # off the elements set_weapons_data frees
		_shop._get_gear_container(p).set_weapons_data(RunData.get_player_weapons(p))
	yield(_t.frames(1), "completed")
	var theirs = _emulator(2)
	var popup = _popup(2)
	var given = RunData.get_player_weapons_ref(0)[0]
	var partner = Rules.combine_partner(given, 2)
	var other = null
	for weapon in RunData.get_player_weapons_ref(2):
		other = weapon if other == null and weapon.my_id != pistol.my_id else other
	var element = _shop._get_weapon_element(_row(2, true), other)
	theirs.focused_control = element
	yield(_t.tap("ui_accept", 2), "completed")
	var cursor = theirs.focused_control
	_t.check(popup._focused and partner != null, "(player 3, its slots full, looks at a weapon)")
	_t.check(_shop.trade_give(given, 0, 2), "it is given a weapon it combines")
	yield(_t.frames(2), "completed")
	_t.check(
		popup._focused and theirs.focused_control == cursor and is_instance_valid(element),
		"its popup on another weapon stays open"
	)
	var shown := []
	for child in _row(2, true).get_children():
		if not child.is_queued_for_deletion():
			shown.append(child.item)
	var owned: Array = _t.ids(RunData.get_player_weapons_ref(2))
	_t.check(
		owned.has("weapon_pistol_2") and not partner in shown and _same(_t.ids(shown), owned),
		"the weapon it combined with left the row, the new tier came %s" % [_t.ids(shown)]
	)
	yield(_t.tap("ui_cancel", 2), "completed")

	given = RunData.get_player_weapons_ref(0)[0]
	partner = Rules.combine_partner(given, 2)
	theirs.focused_control = _shop._get_weapon_element(_row(2, true), partner)
	yield(_t.tap("ui_accept", 2), "completed")
	_t.check(popup._focused, "(player 3 looks at the weapon the next one combines with)")
	_t.check(_shop.trade_give(given, 0, 2), "it is given one more")
	yield(_t.frames(2), "completed")
	_t.check(
		not popup._focused and not _panel(2)._popup_dim_screen.visible,
		"the popup on the weapon that went closes"
	)
	_t.check(
		theirs.focused_control != null and theirs.focused_control.get_parent() == _row(2, true),
		"and its cursor is on the weapon row"
	)
	_cursors_valid("after combining under a popup")


# A popup the receiver keeps open shows the buttons of the gear it has now: Combine once a twin
# came, none once the twin was combined away (the cursor on it goes to Cancel). Another player's
# open give list marks again who would combine.
func _kept_popup_buttons():
	var pistol = _t.weapon()
	var theirs: Array = RunData.get_player_weapons_ref(2)
	theirs.clear()
	RunData.add_weapon(pistol, 2)
	_t.fill_weapons(2, pistol)
	theirs.pop_back()  # one slot free: the next pistol is added, not combined
	for p in [0, 1]:
		RunData.add_weapon(pistol, p)
	RunData.add_weapon(pistol, 0)
	for p in [0, 1, 2]:
		_emulator(p).focused_control = null  # off the elements set_weapons_data frees
		_shop._get_gear_container(p).set_weapons_data(RunData.get_player_weapons(p))
	yield(_t.frames(1), "completed")
	var popup = _popup(2)
	var first = theirs[0]
	_emulator(2).focused_control = _shop._get_weapon_element(_row(2, true), first)
	yield(_t.tap("ui_accept", 2), "completed")
	_t.check(popup._focused and not popup._combine_button.visible, "(player 3 looks at its pistol)")
	var list = _popup(1)
	yield(_open_list(1, RunData.get_player_weapons_ref(1).back()), "completed")
	var to_third = null
	for button in list._trade_players:
		to_third = button if button.visible and _to(button) == 2 else to_third
	var combine_text: String = tr("MENU_COMBINE")
	_t.check(
		to_third != null and not combine_text in to_third.text,
		"(player 2's give list: player 3 has a free slot, no Combine)"
	)
	var mine: Array = RunData.get_player_weapons_ref(0)
	_t.check(_shop.trade_give(mine[mine.size() - 1], 0, 2), "player 3 is given a twin")
	yield(_t.frames(2), "completed")
	_t.check(
		popup._focused and popup._item_data == first and popup._combine_button.visible,
		"its popup on the pistol stays open and offers Combine now"
	)
	_t.check(
		list._trade_choosing and to_third.visible and combine_text in to_third.text,
		"the open give list says player 3 combines it now (%s)" % to_third.text
	)
	yield(_t.tap("ui_cancel", 2), "completed")

	var given = mine[mine.size() - 1]
	var partner = Rules.combine_partner(given, 2)
	var kept = null
	for weapon in theirs:
		if weapon != partner and weapon.my_id == pistol.my_id:
			kept = weapon
	_emulator(2).focused_control = _shop._get_weapon_element(_row(2, true), kept)
	yield(_t.tap("ui_accept", 2), "completed")
	_emulator(2).focused_control = popup._combine_button
	_t.check(popup._focused and partner != null, "(player 3, its slots full, looks at one twin)")
	_t.check(_shop.trade_give(given, 0, 2), "it is given a pistol that combines with the other")
	yield(_t.frames(2), "completed")
	_t.check(
		(
			popup._focused
			and popup._item_data == kept
			and theirs.has(kept)
			and not popup._combine_button.visible
		),
		"its popup stays open on a weapon it owns, without Combine %s" % [_t.ids(theirs)]
	)
	_t.check(_emulator(2).focused_control == popup._cancel_button, "the cursor on it went to Cancel")
	_cursors_valid("after a kept popup's buttons changed")
	yield(_t.tap("ui_cancel", 2), "completed")
	for _i in 2:
		yield(_t.tap("ui_cancel", 1), "completed")


func _refusals() -> void:
	var before: String = _t.ledger()
	var weapon = RunData.get_player_weapons_ref(2)[0]
	_t.get_tree().paused = true
	_t.check(not _shop.trade_give(weapon, 2, 0), "nothing is given while the game is paused")
	_t.get_tree().paused = false
	_t.check(not _shop.trade_give(weapon, 1, 0), "nor by a player who does not own it")
	_t.check(not _shop.trade_apply_request(true, 2, 0, "weapon_smg_1", 0), "nor on a wrong name")
	_t.check(
		not _shop.trade_apply_request(true, 2, 5, "weapon_smg_1", 0),
		"nor from an empty place naming nothing the player owns"
	)
	_t.check(_t.ledger() == before, "refused hand-overs change nothing")
	_cursors_valid("at the end")


# The same popup scene outside the shop (the level-up screen has it per player): as in the game.
func _other_popup():
	var popup = load("res://ui/menus/shop/coop_item_popup.tscn").instance()
	popup.buttons_enabled = true
	_shop.add_child(popup)
	yield(_t.frames(1), "completed")
	var weapon = RunData.get_player_weapons_ref(2)[0]
	var item = RunData.get_player_items_ref(1).back()
	popup.display_item_data(weapon, _shop._get_go_button(0), true)
	popup.focus()
	_t.check(
		popup._discard_button.visible and popup._cancel_button.visible,
		"a popup outside the shop has the game's weapon buttons"
	)
	_t.check(not popup._trade_button.visible, "and no Trade")
	_t.check(not popup.will_show_buttons_when_focused(item), "an item has no buttons there")
	popup.hide()
	popup.queue_free()
	yield(_t.frames(1), "completed")


# A full lobby: the last player's list names the three others.
func _four_players():
	_t.coop_run(4)
	RunData.add_item(_plain, 3)
	_shop = yield(_t.open_shop(), "completed")
	var popup = _popup(3)
	yield(_open_list(3, _plain), "completed")
	var offered := []
	for button in popup._trade_players:
		if button.visible:
			offered.append(_to(button))
	_t.check(offered == [0, 1, 2], "with four players the list names the three others %s" % [offered])
	yield(_t.tap("ui_down", 3), "completed")
	yield(_t.tap("ui_down", 3), "completed")
	yield(_t.tap("ui_accept", 3), "completed")
	yield(_t.frames(2), "completed")
	_t.check(_count(2, _plain) == 1 and _count(3, _plain) == 0, "and the third one gets the item")
	_cursors_valid("in a four-player shop")


func _open_list(player: int, item):
	var popup = _popup(player)
	_emulator(player).focused_control = _element(player, item)
	yield(_t.tap("ui_accept", player), "completed")
	_emulator(player).focused_control = popup._trade_button
	yield(_t.tap("ui_accept", player), "completed")


# A button of the game ignores presses for 0.05 s after one.
func _press_delay():
	yield(_t.get_tree().create_timer(0.1), "timeout")


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


static func _same(a: Array, b: Array) -> bool:
	var x := a.duplicate()
	var y := b.duplicate()
	x.sort()
	y.sort()
	return x == y


func _to(button) -> int:
	return button.get_meta("trade_to") if button != null and button.has_meta("trade_to") else -1


func _count(player: int, item) -> int:
	return RunData.get_nb_item(item.my_id_hash, player, false)


func _popup(player: int):
	return _shop._get_item_popup(player)


func _panel(player: int):
	return _shop._get_coop_player_container(player)


func _emulator(player: int):
	return Utils.get_focus_emulator(player, _shop)


func _row(player: int, weapons: bool) -> Node:
	var gear = _shop._get_gear_container(player)
	return gear.weapons_container._elements if weapons else gear.items_container._elements


func _element(player: int, item):
	for element in _row(player, item is WeaponData).get_children():
		if element.is_queued_for_deletion() or element.item == null:
			continue
		if element.item == item or element.item.my_id == item.my_id:
			return element
	return null
