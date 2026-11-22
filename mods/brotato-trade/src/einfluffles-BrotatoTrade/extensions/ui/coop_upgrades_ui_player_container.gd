extends "res://ui/menus/ingame/coop_upgrades_ui_player_container.gd"
# Adds Trade below Take to a co-op crate panel: it lists the other players in place of Take /
# Recycle / Ban. Only where trade_ui is set (extensions/ui/upgrades_ui.gd).

signal trade_requested(to_player)

const TRADE_TEXT := "Trade"
const TRADE_TO_META := "trade_to"
const TRADE_OK_META := "trade_ok"

var trade_ui: Node = null  # answers trade_crate_offered / trade_crate_receivers

var _trade_button: Button = null
var _trade_cancel: Button = null
var _trade_players := []  # a button per other player, shown while choosing
var _trade_choosing := false
var _trade_hidden := []  # the game's buttons the list hides


func _ready() -> void:
	var at: int = _take_button.get_index() + 1
	_trade_button = _trade_add_button("TradeButton", at)
	_trade_button.text = TRADE_TEXT
	_trade_button.connect("pressed", self, "_on_trade_button_pressed")
	for i in CoopService.UI_MAX_PLAYER_COUNT - 1:
		var button := _trade_add_button("TradePlayer%d" % (i + 1), at + 1 + i)
		button.expand_icon = true
		button.connect("pressed", self, "_on_trade_player_pressed", [i])
		_trade_players.append(button)
	_trade_cancel = _trade_add_button("TradeCancel", at + _trade_players.size() + 1)
	_trade_cancel.text = "MENU_CANCEL"
	_trade_cancel.connect("pressed", self, "trade_back", [true])


# Polled: who can take the item changes with every decision of every player.
func _process(_delta: float) -> void:
	if _trade_button == null:
		return
	var shown := _trade_offered()
	if not shown:
		if _trade_choosing:
			trade_back(false)
		_trade_set(_trade_button, false, false)
		return
	var entries: Array = trade_ui.trade_crate_receivers(player_index)
	var anyone := false
	for entry in entries:
		anyone = anyone or entry[1]
	if not _trade_choosing:
		_trade_set(_trade_button, true, anyone and _trade_item_ready())
		return
	if not anyone:
		trade_back(true)
		return
	for i in _trade_players.size():
		if i < entries.size():
			_trade_set(_trade_players[i], true, entries[i][1])


func _input(event: InputEvent) -> void:
	if _trade_choosing and Utils.is_player_cancel_pressed(event, player_index):
		call_deferred("trade_back", true)
		get_viewport().set_input_as_handled()


func show_item(item_data: ItemParentData) -> void:
	_trade_collapse()
	.show_item(item_data)


func show_upgrades_for_level(level: int) -> void:
	_trade_collapse()
	.show_upgrades_for_level(level)


func finish() -> void:
	_trade_collapse()
	.finish()


func get_item_focus_button() -> Button:
	if _trade_choosing:
		for button in _trade_players:
			if button.visible and button.get_meta(TRADE_OK_META):
				return button
		return _trade_cancel
	return .get_item_focus_button()


func trade_is_choosing() -> bool:
	return _trade_choosing


# brotato:together shows the list on the other machines' copies of this panel.
func together_menu():
	return ["trade"] if _trade_choosing else null


# A copy opens the list without the meca effect choice, which only the player's own panel has.
func together_show_menu(menu) -> void:
	if menu == null:
		trade_back(false)
	elif not _trade_choosing and _trade_offered():
		_trade_open()


func trade_back(refocus: bool) -> void:
	if not _trade_choosing:
		return
	_trade_collapse()
	if not refocus or focus_emulator == null or not is_visible_in_tree():
		return
	if _trade_button.visible and _trade_button.get_meta(TRADE_OK_META):
		focus_emulator.focused_control = _trade_button  # maybe still in its press delay
	else:
		focus_emulator.focused_control = get_item_focus_button()


func _on_trade_button_pressed() -> void:
	if _trade_choosing or not _trade_offered() or not _trade_item_ready():
		return
	_trade_open()


func _trade_open() -> void:
	var entries: Array = trade_ui.trade_crate_receivers(player_index)
	var first: Button = null
	for i in _trade_players.size():
		var button: Button = _trade_players[i]
		var listed: bool = i < entries.size()
		_trade_set(button, listed, listed and entries[i][1])
		if listed:
			_trade_label(button, entries[i])
			if first == null and entries[i][1]:
				first = button
	if first == null:
		return
	_trade_choosing = true
	for button in [_take_button, _discard_button, _ban_button]:
		if button.visible:
			_trade_hidden.append(button)
			button.hide()
	_trade_button.hide()
	_trade_cancel.show()
	_trade_cancel.focus_mode = FOCUS_ALL
	_trade_set_neighbours()
	if focus_emulator != null:
		focus_emulator.focused_control = first


func _on_trade_player_pressed(index: int) -> void:
	var button: Button = _trade_players[index]
	if not _trade_choosing or not button.has_meta(TRADE_TO_META):
		return
	if not button.get_meta(TRADE_OK_META):
		return
	emit_signal("trade_requested", button.get_meta(TRADE_TO_META))


func _trade_offered() -> bool:
	if trade_ui == null or not is_instance_valid(trade_ui) or _item_data == null:
		return false
	if not _items_container.visible or _checkmark_group.visible:
		return false
	return trade_ui.trade_crate_offered(player_index)


# As for Take: a meca item waits for its effect choice.
func _trade_item_ready() -> bool:
	if _item_data.is_meca:
		return _meca_effect_choice_selected != -1
	return true


func _trade_set(button: Button, shown: bool, ok: bool) -> void:
	button.visible = shown
	ok = ok and shown
	if button.has_meta(TRADE_OK_META) and button.get_meta(TRADE_OK_META) == ok:
		return
	button.set_meta(TRADE_OK_META, ok)
	if ok:
		button.activate()
	else:
		button.disable()


func _trade_set_neighbours() -> void:
	var buttons := []
	for button in _trade_players + [_trade_cancel]:
		if button.visible:
			buttons.append(button)
	for i in buttons.size():
		var button: Control = buttons[i]
		var above: Control = buttons[i - 1] if i > 0 else button
		var below: Control = buttons[i + 1] if i < buttons.size() - 1 else button
		button.focus_neighbour_top = button.get_path_to(above)
		button.focus_neighbour_bottom = button.get_path_to(below)


func _trade_collapse() -> void:
	if _trade_button == null:
		return
	if _trade_choosing:
		_trade_button.show()
	_trade_choosing = false
	for button in _trade_players:
		_trade_set(button, false, false)
	_trade_cancel.hide()
	_trade_cancel.focus_mode = FOCUS_NONE
	for button in _trade_hidden:
		button.show()
	_trade_hidden = []


func _trade_add_button(node_name: String, at: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.set_script(_take_button.get_script())
	button.theme = _take_button.theme
	button.add_font_override("font", _take_button.get_font("font"))
	button.focus_neighbour_left = NodePath(".")
	button.focus_neighbour_right = NodePath(".")
	button.focus_mode = FOCUS_NONE
	button.visible = false
	var parent: Node = _take_button.get_parent()
	parent.add_child(button)
	parent.move_child(button, at)
	return button


# entry: [to, ok, combines].
func _trade_label(button: Button, entry: Array) -> void:
	var to: int = entry[0]
	button.set_meta(TRADE_TO_META, to)
	button.text = Text.text("COOP_PLAYER", [str(to + 1)])
	if entry[2]:
		button.text += " (%s)" % tr("MENU_COMBINE")
	var character = RunData.get_player_character(to)
	button.icon = character.get_icon() if character != null else null
	button.add_color_override("font_color", CoopService.get_player_color(to))
