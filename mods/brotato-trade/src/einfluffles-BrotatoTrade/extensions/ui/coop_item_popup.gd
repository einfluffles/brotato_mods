extends "res://ui/menus/shop/coop_item_popup.gd"
# Adds Trade to the co-op item popup. The game's popup has buttons for weapons only: an item gets
# Trade and Cancel here. Only where trade_shop is set (extensions/ui/coop_shop.gd): the level-up
# screen's popups are the same scene and stay as they are.

signal trade_requested(item_data, to_player)
signal trade_buy_requested(shop_item, to_player)
signal trade_buy_closed(shop_item)

const TRADE_TEXT := "Trade"
const TRADE_TO_META := "trade_to"
const TRADE_OK_META := "trade_ok"
const HINT_SCENE := "res://ui/menus/shop/coop_shop_hint.tscn"
# Loaded when needed: it extends a game script that names ShopItem, which other mods extend.
const TRADE_HINT := "res://mods-unpacked/einfluffles-BrotatoTrade/ui/trade_hint.gd"
const Hotkey := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/hotkey.gd")

var trade_shop: Node = null  # answers trade_receivers / trade_combines

var _trade_button: Button = null
var _trade_players := []  # a button per possible receiver, shown while choosing
var _trade_choosing := false
var _trade_buy: Node = null  # the ShopItem whose buy-for list is open
var _trade_direct := false  # the give list was opened by the trade key: cancel closes the popup
var _trade_hint: Control = null
var _trade_hint_for = null  # the hovered ShopItem or gear (ItemParentData)
var _trade_hint_type := -1  # the device type its glyph is for


func _ready() -> void:
	_trade_button = _trade_add_button("TradeButton")
	_trade_button.text = TRADE_TEXT
	_trade_button.connect("pressed", self, "_on_trade_button_pressed")
	for i in CoopService.UI_MAX_PLAYER_COUNT - 1:
		var button := _trade_add_button("TradePlayer%d" % (i + 1))
		button.expand_icon = true
		button.connect("pressed", self, "_on_trade_player_pressed", [i])
		_trade_players.append(button)
	_trade_hint = load(HINT_SCENE).instance()
	var script: Script = load(TRADE_HINT)
	_trade_hint.set_script(script)
	_trade_hint.name = "TradeHint"
	_trade_hint.text = script.TRADE_TEXT
	_trade_hint.visible = false
	_coop_lock_hint.get_parent().add_child(_trade_hint)


# Cancel while the players are listed leads back to the buttons. The base _input, which Godot
# runs right after this one, closes a focused popup on that press: not this time.
func _input(event: InputEvent) -> void:
	if _trade_choosing and _focused and Utils.is_player_cancel_pressed(event, player_index):
		_focused = false
		call_deferred("_trade_back", true)
		get_viewport().set_input_as_handled()


func should_show_buttons(item_data: ItemParentData, focused: bool) -> bool:
	if _trade_buy != null:
		return focused
	if .should_show_buttons(item_data, focused):
		return true
	if not buttons_enabled or not focused or item_data is WeaponData:
		return false
	return not _trade_receivers(item_data).empty()


func cancel() -> void:
	_trade_collapse()
	.cancel()


func hide(index := -1) -> void:
	_trade_buy = null
	_trade_direct = false
	.hide(index)


# entries: [player, can take it, combines] for every listed player.
func trade_open_buy(shop_item: Node, entries: Array) -> void:
	_trade_buy = shop_item
	display_item_data(shop_item.item_data, shop_item._button)
	focus()
	_trade_choosing = true
	var first: Button = null
	for i in _trade_players.size():
		var button: Button = _trade_players[i]
		button.visible = i < entries.size()
		if not button.visible:
			continue
		_trade_label(button, entries[i][0], entries[i][2])
		button.set_meta(TRADE_OK_META, entries[i][1])
		if entries[i][1]:
			button.activate()
			first = button if first == null else first
		else:
			button.disable()
	_update_button_focus_neighbours()
	if first != null:
		first.grab_focus()


func trade_buy_item() -> Node:
	return _trade_buy


# The trade key on the own gear, with the popup focused as after accept.
func trade_open_give() -> bool:
	if not _focused or _trade_receivers(_item_data).empty():
		return false
	_trade_direct = true
	_on_trade_button_pressed()
	return _trade_choosing


# An open give list marks again who would combine the item, after someone's gear changed.
func trade_relabel() -> void:
	if not _trade_choosing or _trade_buy != null or _item_data == null:
		return
	for button in _trade_players:
		if button.visible and button.has_meta(TRADE_TO_META):
			_trade_label(button, button.get_meta(TRADE_TO_META))


# brotato:together shows the list on the other machines' copies of this panel:
# ["give"] | ["buy", the shop item's slot] | null.
func together_menu():
	if not _trade_choosing or not _focused or not is_instance_valid(trade_shop):
		return null
	if _trade_buy == null:
		return ["give"]
	var nodes: Array = trade_shop._get_shop_items_container(player_index)._shop_items
	return ["buy", nodes.find(_trade_buy)]


func together_show_menu(menu) -> void:
	if menu == null:
		if _trade_choosing:
			_trade_back(false)
		return
	if not is_instance_valid(trade_shop) or _trade_choosing or typeof(menu[0]) != TYPE_STRING:
		return
	if menu[0] == "give" and _focused:
		_on_trade_button_pressed()
	elif menu[0] == "buy" and menu.size() == 2 and typeof(menu[1]) == TYPE_INT:
		trade_shop.trade_show_buy(player_index, menu[1])


func show_shop_hints(p_shop_item: ShopItem) -> void:
	.show_shop_hints(p_shop_item)
	_trade_hint_for = p_shop_item
	trade_hint_refresh()


func show_inventory_hint(item_data: ItemParentData) -> void:
	.show_inventory_hint(item_data)
	_trade_hint_for = item_data
	trade_hint_refresh()


func hide_hints() -> void:
	.hide_hints()
	_trade_hint_for = null
	trade_hint_refresh()


# Shown while someone can take the hovered item.
func trade_hint_refresh() -> void:
	if _trade_hint == null:
		return
	var shown := false
	var target = _trade_hint_for
	if visible and not _focused and is_instance_valid(trade_shop) and is_instance_valid(target):
		if target is Node:
			shown = trade_shop.trade_buy_anyone(target, player_index)
		else:
			shown = not _trade_receivers(target).empty()
	var device_type := Hotkey.player_type(player_index)
	if shown and (not _trade_hint.visible or device_type != _trade_hint_type):
		_trade_hint_type = device_type
		_trade_hint.player_index = player_index  # the setter: the glyph of the device used now
	if _trade_hint.visible != shown:
		_trade_hint.visible = shown


func _update_button_visibilities() -> void:
	_trade_collapse()
	var shown: bool = _item_data != null and should_show_buttons(_item_data, _focused)
	if shown and (_trade_buy != null or not _item_data is WeaponData):
		# The base goes on to ask RunData about combining and recycling a weapon.
		_cancel_pending_upgrade()
		for button in [_combine_button, _discard_button, _upgrade_button]:
			if button != null:
				button.hide()
				button.focus_mode = FOCUS_NONE
		_cancel_button.show()
		_cancel_button.focus_mode = FOCUS_ALL if _focused else FOCUS_NONE
	else:
		._update_button_visibilities()
	if _trade_button == null:
		return
	_trade_button.visible = shown and not _trade_receivers(_item_data).empty()
	_trade_button.focus_mode = FOCUS_ALL if _trade_button.visible and _focused else FOCUS_NONE
	_update_button_focus_neighbours()


func _update_button_focus_neighbours() -> void:
	var buttons := []
	var all := [_combine_button, _upgrade_button, _discard_button, _trade_button, _cancel_button]
	for button in all + _trade_players:
		if button != null and button.visible:
			buttons.push_back(button)
	buttons.sort_custom(self, "_is_above_in_container")
	for i in buttons.size():
		var button: Control = buttons[i]
		var above: Control = buttons[i - 1] if i > 0 else button
		var below: Control = buttons[i + 1] if i < buttons.size() - 1 else button
		button.focus_neighbour_top = button.get_path_to(above)
		button.focus_neighbour_bottom = button.get_path_to(below)


func _on_CancelButton_pressed() -> void:
	if _trade_choosing:
		_trade_back(false)
		return
	._on_CancelButton_pressed()


func _on_trade_button_pressed() -> void:
	var players := _trade_receivers(_item_data)
	if players.empty():
		_update_button_visibilities()
		return
	_trade_choosing = true
	for button in [_combine_button, _upgrade_button, _discard_button, _trade_button]:
		if button != null:
			button.hide()
			button.focus_mode = FOCUS_NONE
	for i in _trade_players.size():
		var button: Button = _trade_players[i]
		button.visible = i < players.size()
		button.focus_mode = FOCUS_ALL if button.visible and _focused else FOCUS_NONE
		if button.visible:
			_trade_label(button, players[i])
	_update_button_focus_neighbours()
	if _focused:
		_trade_players[0].grab_focus()


func _on_trade_player_pressed(index: int) -> void:
	var button: Button = _trade_players[index]
	if not _trade_choosing or _item_data == null or not button.has_meta(TRADE_TO_META):
		return
	var item = _item_data
	var to: int = button.get_meta(TRADE_TO_META)
	if _trade_buy != null:
		if button.has_meta(TRADE_OK_META) and not button.get_meta(TRADE_OK_META):
			return
		item = _trade_buy
		_trade_collapse()
		_trade_direct = false
		_focused = false
		emit_signal("trade_buy_requested", item, to)
		return
	_trade_direct = false
	_trade_collapse()
	_focused = false
	emit_signal("trade_requested", item, to)


func _trade_receivers(item) -> Array:
	if trade_shop == null or item == null or not is_instance_valid(trade_shop):
		return []
	if _trade_buy != null:
		return []
	return trade_shop.trade_receivers(item, player_index)


func _trade_add_button(node_name: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.set_script(_cancel_button.get_script())  # the game's press and focus sounds
	button.theme = _cancel_button.theme
	button.add_font_override("font", _cancel_button.get_font("font"))
	button.focus_neighbour_left = NodePath(".")
	button.focus_neighbour_right = NodePath(".")
	button.focus_mode = FOCUS_NONE
	button.visible = false
	var parent: Node = _cancel_button.get_parent()
	parent.add_child(button)
	parent.move_child(button, _cancel_button.get_index())
	return button


# combines: null asks the shop.
func _trade_label(button: Button, to: int, combines = null) -> void:
	button.set_meta(TRADE_TO_META, to)
	button.text = Text.text("COOP_PLAYER", [str(to + 1)])
	if combines == null:
		combines = trade_shop.trade_combines(_item_data, to)
	if combines:
		button.text += " (%s)" % tr("MENU_COMBINE")
	var character = RunData.get_player_character(to)
	button.icon = character.get_icon() if character != null else null
	button.add_color_override("font_color", CoopService.get_player_color(to))


func _trade_collapse() -> void:
	_trade_choosing = false
	for button in _trade_players:
		if not button.active:
			button.activate()  # a player without room in a buy-for list
		if button.has_meta(TRADE_OK_META):
			button.remove_meta(TRADE_OK_META)
		button.hide()
		button.focus_mode = FOCUS_NONE


func _trade_back(refocus: bool) -> void:
	if _trade_buy != null:
		var shop_item := _trade_buy
		_trade_collapse()
		_focused = false
		emit_signal("trade_buy_closed", shop_item)
		return
	if _trade_direct:
		_trade_direct = false
		_trade_collapse()
		_focused = false
		emit_signal("item_cancel_button_pressed", _item_data)
		return
	if refocus:
		if not is_visible_in_tree() or _item_data == null:
			return
		_focused = true
	_update_button_visibilities()
	if not _focused:
		return
	if _trade_button.visible:
		_trade_button.grab_focus()
	else:
		_cancel_button.grab_focus()
