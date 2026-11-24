extends Reference
# The trade key in plain local co-op: the give list on the own gear, nothing without a target,
# the hint's glyph per device, real key and pad events, the InputMap rebuilt by the game, a key
# rebound in the mod config and an invalid config. Three players: 0 on the keyboard, 1 on a
# PlayStation pad, 2 on a Switch pad.

const Hotkey := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/hotkey.gd")
const TRADE := "brotato_trade"
const MOD_ID := "einfluffles-BrotatoTrade"

var _t: Node = null
var _shop: Node = null
var _plain = null
var _unique = null


func run(t: Node):
	_t = t
	t.coop_run(3)
	var types = CoopService.PlayerType
	CoopService.connected_players[0] = [
		CoopService.KEYBOARD_REMAPPED_DEVICE_ID, types.KEYBOARD_AND_MOUSE
	]
	CoopService.connected_players[1][1] = types.GAMEPAD_PLAYSTATION
	CoopService.connected_players[2][1] = types.GAMEPAD_SWITCH
	_plain = t.item_with_limit(-1)
	_unique = t.item_with_limit(1, [_plain])
	for _i in 3:
		RunData.add_item(_plain, 0)
	RunData.add_weapon(t.weapon(), 0)
	_shop = yield(t.open_shop(), "completed")
	_config_defaults()
	yield(_give(), "completed")
	yield(_nothing(), "completed")
	yield(_hint(), "completed")
	yield(_real_events(), "completed")
	yield(_rebuilt(), "completed")
	yield(_rebind(), "completed")
	yield(_invalid(), "completed")


func _config_defaults() -> void:
	var config = ModLoaderConfig.get_default_config(MOD_ID)
	var data: Dictionary = config.data if config != null else {}
	_t.check(
		data.get("trade_key") == "T" and int(data.get("trade_joypad_button", -1)) == JOY_SELECT,
		"the mod's default config: T and button 10 (%s)" % [data]
	)
	_t.check(Hotkey.binding() == [KEY_T, JOY_SELECT], "and the key is bound to them")


func _give():
	var popup = _popup(0)
	var element = _element(0, _plain)
	_emulator(0).focused_control = element
	yield(_t.frames(1), "completed")
	_t.check(popup.visible and popup._trade_hint.visible, "the own item's popup shows the hint")
	yield(_t.tap(TRADE, 0), "completed")
	var players: Array = popup._trade_players
	_t.check(
		popup._focused and popup._trade_choosing and _panel(0)._popup_dim_screen.visible,
		"the trade key on the own item opens its popup on the player list"
	)
	_t.check(
		players[0].visible and players[1].visible and not popup._trade_button.visible,
		"with both other players, not the popup's Trade button"
	)
	_t.check(not popup._trade_hint.visible, "and no hint")
	_t.check(_emulator(0).focused_control == players[0], "the cursor is on the first player")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")
	_t.check(
		not popup._focused and not _panel(0)._popup_dim_screen.visible,
		"cancel closes the popup, not only the list"
	)
	_t.check(_emulator(0).focused_control == element, "the cursor is on the item again")
	yield(_press_delay(), "completed")
	yield(_t.tap(TRADE, 0), "completed")
	yield(_t.tap("ui_accept", 0), "completed")
	yield(_t.frames(2), "completed")
	_t.check(_count(0, _plain) == 2 and _count(1, _plain) == 1, "accept gives it to player 2")
	_t.check(not popup._focused, "and the popup closes")

	_emulator(0).focused_control = _element(0, RunData.get_player_weapons_ref(0)[0])
	yield(_press_delay(), "completed")
	yield(_t.tap(TRADE, 0), "completed")
	_t.check(
		popup._focused and players[0].visible and not popup._combine_button.visible,
		"a weapon: the list too, without the weapon buttons"
	)
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")
	_t.check(not popup._focused, "(closed)")


func _nothing():
	var popup = _popup(0)
	_emulator(0).focused_control = _shop._get_go_button(0)
	yield(_t.tap(TRADE, 0), "completed")
	_t.check(not popup._focused, "no item under the cursor: nothing opens")
	var character = _element(0, RunData.get_player_character(0))
	_emulator(0).focused_control = character
	yield(_t.frames(1), "completed")
	_t.check(not popup._trade_hint.visible, "an item nobody can take has no hint")
	yield(_t.tap(TRADE, 0), "completed")
	_t.check(not popup._focused, "and the trade key opens nothing")

	var element = _element(0, RunData.get_player_weapons_ref(0)[0])
	_emulator(0).focused_control = element
	yield(_t.tap("ui_accept", 0), "completed")
	yield(_t.tap(TRADE, 0), "completed")
	_t.check(
		popup._focused and not popup._trade_choosing and popup._trade_button.visible,
		"in an open popup the trade key does nothing"
	)
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")

	_emulator(1).focused_control = _shop._get_go_button(1)
	_emulator(0).focused_control = _element(0, _plain)
	yield(_t.tap(TRADE, 1), "completed")
	_t.check(not popup._focused, "another player's key does not open this player's list")

	_t.get_tree().paused = true
	yield(_t.tap(TRADE, 0), "completed")
	_t.get_tree().paused = false
	_t.check(not popup._focused, "paused: nothing opens")


func _hint():
	var node = _buyable(1)
	_t.check(node != null, "(player 2 is offered something the others can take)")
	if node == null:
		return
	var popup = _popup(1)
	_emulator(1).focused_control = node._button
	yield(_t.frames(1), "completed")
	_t.check(popup._trade_hint.visible, "an offered item's popup shows the hint")
	_t.check(_glyph(1) == Hotkey._icon("pad_ps_share.png"), "PlayStation: the Share glyph")
	var sizes := []
	for file in ["key_t.png", "pad_xbox_view.png", "pad_ps_share.png", "pad_switch_minus.png"]:
		sizes.append(Hotkey._icon(file).get_size())
	_t.check(sizes.count(Vector2(100, 100)) == 4, "the mod's four glyph images load (%s)" % [sizes])
	var parts := _hint_parts()
	_t.check(
		popup._trade_hint._label1.text == parts[0] and popup._trade_hint._label2.text == parts[1],
		"%s [glyph] %s" % parts
	)
	_emulator(0).focused_control = _element(0, _plain)
	yield(_t.frames(1), "completed")
	_t.check(_glyph(0) == Hotkey._icon("key_t.png"), "keyboard: the T glyph")
	var other = _buyable(2)
	_emulator(2).focused_control = other._button if other != null else null
	yield(_t.frames(1), "completed")
	_t.check(_glyph(2) == Hotkey._icon("pad_switch_minus.png"), "Switch: the Minus glyph")
	CoopService.connected_players[2][1] = CoopService.PlayerType.GAMEPAD_XBOX
	yield(_t.frames(1), "completed")
	_t.check(_glyph(2) == Hotkey._icon("pad_xbox_view.png"), "a new device type: the View glyph")
	CoopService.connected_players[2][1] = CoopService.PlayerType.GAMEPAD_SWITCH

	# Nobody can take a unique item the two others have.
	RunData.add_item(_unique, 0)
	RunData.add_item(_unique.duplicate(), 2)
	_offer(1, node, _unique)
	_emulator(1).focused_control = _shop._get_go_button(1)
	_emulator(1).focused_control = node._button
	yield(_t.frames(1), "completed")
	_t.check(popup.visible and not popup._trade_hint.visible, "nobody can take it: no hint")
	yield(_t.tap(TRADE, 1), "completed")
	_t.check(not popup._focused, "and nothing opens")


# Events as the devices send them: the keyboard's T, the pad's Back.
func _real_events():
	var node = _buyable(1)
	_emulator(1).focused_control = node._button
	_emulator(0).focused_control = _element(0, _plain)
	yield(_press_delay(), "completed")
	yield(_key(KEY_T), "completed")
	_t.check(_popup(0)._focused and _popup(0)._trade_choosing, "the T key opens player 1's list")
	_t.check(not _popup(1)._focused, "only player 1's")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_pad(_device(1), JOY_SELECT), "completed")
	_t.check(
		_popup(1)._focused and _popup(1).trade_buy_item() == node,
		"the pad's Back button opens player 2's buy-for list"
	)
	yield(_t.tap("ui_cancel", 1), "completed")
	yield(_t.frames(1), "completed")


# InputMap.load_from_globals wipes what was added at runtime; InputService copies again.
func _rebuilt():
	if ProgressData.settings.movement_with_gamepad:
		InputService.enable_gamepad_movement()
	else:
		InputService.disable_gamepad_movement()
	_t.check(
		InputMap.has_action(TRADE) and InputMap.has_action("%s_%d" % [TRADE, _device(1)]),
		"after the game rebuilt its InputMap the key is there again"
	)
	_emulator(0).focused_control = _element(0, _plain)
	yield(_press_delay(), "completed")
	yield(_key(KEY_T), "completed")
	_t.check(_popup(0)._focused, "and opens the list")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")


func _rebind():
	var data := {"trade_key": "Y", "trade_joypad_button": JOY_XBOX_X}
	var config = ModLoaderStore.mod_data[MOD_ID].configs.get("hotkey_test")  # from an earlier run
	if config == null:
		config = ModLoaderConfig.create_config(MOD_ID, "hotkey_test", data)
	else:
		config.data = data
	_t.check(config != null and config.is_valid, "(a config naming Y and the X button)")
	if config == null:
		return
	_choose(config)
	_t.check(Hotkey.binding() == [KEY_Y, JOY_XBOX_X], "a chosen config rebinds the key")
	_emulator(0).focused_control = _shop._get_go_button(0)
	_emulator(0).focused_control = _element(0, _plain)
	yield(_t.frames(1), "completed")
	var hint = _popup(0)._trade_hint
	_t.check(
		hint.visible and not hint._key_icon.visible
		and hint._label1.text == ("%s Y" % _hint_parts()[0]).strip_edges(),
		"the hint names the key (%s ... %s)" % [hint._label1.text, hint._label2.text]
	)
	yield(_press_delay(), "completed")
	yield(_key(KEY_T), "completed")
	_t.check(not _popup(0)._focused, "T no longer opens the list")
	yield(_key(KEY_Y), "completed")
	_t.check(_popup(0)._focused, "Y does")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")
	var node = _buyable(1)
	_emulator(1).focused_control = node._button
	yield(_pad(_device(1), JOY_SELECT), "completed")
	_t.check(not _popup(1)._focused, "Back no longer opens it")
	yield(_pad(_device(1), JOY_XBOX_X), "completed")
	_t.check(_popup(1)._focused, "the X button does")
	yield(_t.tap("ui_cancel", 1), "completed")
	yield(_t.frames(1), "completed")


func _invalid():
	_t.check(
		Hotkey.parse_binding({"trade_key": "NoSuchKey", "trade_joypad_button": 999})
		== [KEY_T, JOY_SELECT],
		"an unknown key and an out-of-range button fall back to T and Back"
	)
	_t.check(
		Hotkey.parse_binding({"trade_key": 5, "trade_joypad_button": "Back"}) == [KEY_T, JOY_SELECT],
		"so do values of the wrong type"
	)
	_t.check(
		Hotkey.parse_binding({"trade_key": "f2", "trade_joypad_button": 3.0}) == [KEY_F2, 3],
		"key names in any case, a button number from JSON"
	)
	var data := {"trade_key": "NoSuchKey", "trade_joypad_button": -2}
	var config := ModConfig.new(MOD_ID, data, "user://hotkey_invalid.json")
	_choose(config)
	_t.check(Hotkey.binding() == [KEY_T, JOY_SELECT], "a chosen invalid config: T and Back again")
	_emulator(0).focused_control = _element(0, _plain)
	yield(_press_delay(), "completed")
	yield(_key(KEY_T), "completed")
	_t.check(_popup(0)._focused, "and T opens the list")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")
	_choose(ModLoaderConfig.get_default_config(MOD_ID))


# What the Mod Loader does when a config is chosen, without the user profile.
func _choose(config) -> void:
	ModLoaderConfig.set_current_config(config)
	ModLoader.emit_signal("current_config_changed", config)


func _key(scancode: int):
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.scancode = scancode
		event.physical_scancode = scancode
		event.pressed = pressed
		Input.parse_input_event(event)
		yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")


func _pad(device: int, button: int):
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = device
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)
		yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")


func _device(player: int) -> int:
	return CoopService.get_remapped_player_device(player)


# The hint's text on both sides of the glyph, in the language the tests run in.
func _hint_parts() -> Array:
	var parts := tr("BTR_TRADE_HINT").split("{0}")
	return [parts[0].strip_edges(), parts[1].strip_edges()]


func _glyph(player: int):
	var hint = _popup(player)._trade_hint
	return hint._key_icon.texture if hint.visible and hint._key_icon.visible else null


func _buyable(player: int):
	for node in _shop._get_shop_items_container(player)._shop_items:
		if node.active and node.item_data != null and _shop.trade_buy_anyone(node, player):
			return node
	return null


func _offer(p: int, node, item) -> void:
	for entry in _shop._shop_items[p]:
		if entry[0] == node.item_data:
			entry[0] = item
			break
	node.set_shop_item(item, node.wave_value)
	node.activate()


func _press_delay():
	yield(_t.get_tree().create_timer(0.15), "timeout")


func _count(player: int, item) -> int:
	return RunData.get_nb_item(item.my_id_hash, player, false)


func _popup(player: int):
	return _shop._get_item_popup(player)


func _panel(player: int):
	return _shop._get_coop_player_container(player)


func _emulator(player: int):
	return Utils.get_focus_emulator(player, _shop)


func _element(player: int, item):
	var gear = _shop._get_gear_container(player)
	var container = gear.weapons_container if item is WeaponData else gear.items_container
	for element in container._elements.get_children():
		if element.is_queued_for_deletion() or element.item == null:
			continue
		if element.item == item or element.item.my_id == item.my_id:
			return element
	return null
