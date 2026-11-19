extends Reference
# Character selection with the lobby (ui/coop_mode.gd, ui/slot_invite.gd): the Co-op row (Off /
# Local / Online) and Invite friends. Run by lobby_menu_tests.gd with its fake Steam and its
# input helpers.

const CoopMode := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_mode.gd")
const SlotInvite := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/slot_invite.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const HOST := 2  # lobby_menu_tests.gd's
const LOBBY := 99
const KEYBOARD := 7
const PRESS_DELAY_SEC := 0.1
const POPUP_STATES := ["opened", "row hovered", "after a mouse pick", "reopened"]
const POPUP_COLORS := ["font_color", "font_color_hover", "font_color_disabled", "font_color_accel"]
const POPUP_ICONS := ["radio_checked", "radio_unchecked", "checked", "unchecked"]

var s = null  # lobby_menu_tests.gd: t, transport, session, _steam and the input helpers


func run(suite):
	s = suite
	var t: Node = s.t
	s.transport.steam = null
	RunData.play_mode = RunData.PlayMode.SOLO
	yield(s._change_scene(MenuData.character_selection_scene), "completed")
	var scene: Node = s._tree().current_scene
	var coop: CheckButton = scene.get_node("%CoopButton")
	var zone: OptionButton = scene.get_node("%ZoneSelectionButton")
	var mode: OptionButton = coop.get_parent().get_node_or_null(CoopMode.NODE_NAME)
	t._check(
		mode != null and not coop.visible and mode.get_index() == coop.get_index() + 1
		and mode.theme == zone.theme,
		"selection: the Co-op row, in the zone dropdown's look, where the game's toggle was"
	)
	if mode == null:
		return
	var values := []
	for i in mode.get_item_count():
		values.append(mode.get_item_text(i).split(": ")[-1])
	t._check(values == ["Off", "Local", "Online"], "selection: Off / Local / Online %s" % [values])
	t._check(
		mode.selected == CoopMode.Mode.OFF and mode.is_item_disabled(CoopMode.Mode.ONLINE)
		and "Steam" in mode.hint_tooltip,
		"selection: solo is Off; without Steam Online is off, the tooltip says why"
	)
	s._fake_steam()
	yield(s._frames(1), "completed")
	t._check(not mode.is_item_disabled(CoopMode.Mode.ONLINE), "selection: with Steam it can be on")
	var grid: Control = scene.get_node("%Inventory1")
	t._check(
		grid.get_node_or_null(grid.focus_neighbour_top) == mode,
		"selection: the grid's way up leads to the Co-op row"
	)

	var above: Control = _row_above(coop)
	above.grab_focus()
	yield(s._tap_key(KEY_DOWN), "completed")
	t._check(scene.get_focus_owner() == mode, "selection: down from %s is Co-op" % above.name)
	yield(s._tap_key(KEY_UP), "completed")
	t._check(scene.get_focus_owner() == above, "selection: and up again")
	yield(s._tap_pad(JOY_DPAD_DOWN), "completed")
	t._check(scene.get_focus_owner() == mode, "selection: pad down reaches Co-op too")
	yield(s._tap_key(KEY_ENTER), "completed")
	t._check(mode.get_popup().visible, "selection: accept opens the values")
	yield(s._tap_key(KEY_DOWN), "completed")
	yield(s._tap_key(KEY_ENTER), "completed")
	t._check(
		mode.selected == CoopMode.Mode.LOCAL and coop.pressed and RunData.is_coop_run
		and not s.transport.is_active(),
		"selection: Local is the game's co-op, no lobby"
	)
	yield(_choose(mode, CoopMode.Mode.OFF), "completed")
	t._check(
		not coop.pressed and not RunData.is_coop_run and mode.selected == CoopMode.Mode.OFF,
		"selection: Off is solo"
	)
	yield(_choose(mode, CoopMode.Mode.ONLINE), "completed")
	t._check(
		s._steam.created == 1 and coop.pressed and RunData.is_coop_run,
		"selection: Online hosts a lobby and is the game's co-op"
	)
	var panels: Array = scene._get_coop_join_panels()
	var invite: Control = panels[0].get_node(SlotInvite.NODE_NAME)
	t._check(
		invite.visible and not invite.button.visible and "creating" in invite.status.text,
		"selection: the free slot says the lobby is being made (%s)" % invite.status.text
	)
	s.transport._on_lobby_created(s.transport.RESULT_OK, LOBBY)
	yield(s._frames(2), "completed")
	t._check(
		mode.selected == CoopMode.Mode.ONLINE and invite.visible and invite.button.visible
		and invite.status.text == "Online: 1 player" and _shown(panels) == [0],
		"selection: hosting -> Invite friends and the count in the next free slot (%s, %s)"
		% [invite.status.text, _shown(panels)]
	)

	CoopService._add_player(KEYBOARD, CoopService.PlayerType.KEYBOARD_AND_MOUSE)
	yield(s._frames(2), "completed")
	invite = panels[1].get_node(SlotInvite.NODE_NAME)
	t._check(_shown(panels) == [1], "selection: a player joined: the invite moves on a slot")
	var emulator = Utils.get_focus_emulator(0, scene)
	# The popups keep the zone dropdown theme's look (a fresh PopupMenu under the zone dropdown).
	var fresh := PopupMenu.new()
	zone.add_child(fresh)
	var theme_look := _popup_look(fresh)
	fresh.queue_free()
	for button in [zone, mode]:
		var looks: Array = yield(_popup_looks(button, emulator), "completed")
		var differ := []
		for i in looks.size():
			if looks[i] != theme_look:
				differ.append([POPUP_STATES[i], looks[i]])
		t._check(
			differ.empty() and emulator.focused_control == button,
			"selection: the %s popup in the zone theme's look %s in every state %s, the cursor on"
			% [button.name, theme_look, differ] + " its dropdown"
		)
	emulator.focused_control = mode
	yield(s._tap_action("ui_left", KEYBOARD), "completed")
	t._check(
		emulator.focused_control == invite.button,
		"selection: player 1, left from Co-op: Invite friends"
	)
	yield(s._tap_action("ui_right", KEYBOARD), "completed")
	t._check(emulator.focused_control == mode, "selection: right from it: Co-op")
	yield(s._tap_action("ui_left", KEYBOARD), "completed")
	yield(s._tap_action("ui_accept", KEYBOARD), "completed")
	t._check(s._steam.invited == [LOBBY], "selection: Invite friends opens Steam's invite dialog")
	for player in range(1, 4):
		var other = Utils.get_focus_emulator(player, scene)
		t._check(
			other._find_control_base_data(invite.button) == null
			and other._find_control_base_data(mode) == null,
			"selection: player %d's cursor reaches neither" % (player + 1)
		)
	s.session._add_peer(HOST)
	yield(s._frames(1), "completed")
	t._check(
		invite.status.text == "Online: 2 players", "selection: the status counts the lobby's players"
	)
	s.session.peers.clear()

	# A MyMenuButton stays off for 0.05 s after a press.
	yield(s._wait(PRESS_DELAY_SEC), "completed")
	emulator.focused_control = mode
	yield(s._frames(1), "completed")
	s._mouse_move(invite.button)
	yield(s._frames(2), "completed")
	var hovered: int = invite.button.get_draw_mode()
	s._mouse_move(scene.get_node("MarginContainer/VBoxContainer/Title"))
	yield(s._frames(2), "completed")
	t._check(
		hovered == BaseButton.DRAW_HOVER and invite.button.get_draw_mode() == BaseButton.DRAW_NORMAL
		and not invite.button.has_focus() and emulator.focused_control != invite.button
		and not invite.button.has_meta("original_stylebox_overrides"),
		"selection: hover on Invite friends ends with the mouse (%d -> %d, focus %s)"
		% [hovered, invite.button.get_draw_mode(), invite.button.has_focus()]
	)

	emulator.focused_control = mode
	yield(s._tap_action("ui_accept", KEYBOARD), "completed")
	yield(s._tap_action("ui_up", KEYBOARD), "completed")
	yield(s._tap_action("ui_accept", KEYBOARD), "completed")
	t._check(
		mode.selected == CoopMode.Mode.LOCAL and not s.transport.is_active() and coop.pressed
		and _shown(panels).empty(),
		"selection: player 1 picks Local: the lobby is left, co-op stays, no invite"
	)

	yield(_choose(mode, CoopMode.Mode.ONLINE), "completed")
	s.transport._on_lobby_created(s.transport.RESULT_OK, LOBBY)
	yield(s._frames(2), "completed")
	CoopService.connected_players[0][0] = VirtualDevices.FIRST
	emulator.player_index = -1
	emulator.player_index = 0
	yield(_choose(mode, CoopMode.Mode.OFF), "completed")
	t._check(
		s._steam.created == 2 and s.transport.is_host() and coop.pressed
		and mode.selected == CoopMode.Mode.ONLINE,
		"selection: a remote player 1 changes nothing"
	)
	CoopService.connected_players[0][0] = KEYBOARD
	yield(_choose(mode, CoopMode.Mode.OFF), "completed")
	t._check(
		not s.transport.is_active() and not coop.pressed and not RunData.is_coop_run,
		"selection: Online -> Off leaves the lobby, solo"
	)

	RunData.play_mode = RunData.PlayMode.COOP
	coop.pressed = true
	s._enter_lobby(HOST, [HOST])
	yield(s._frames(1), "completed")
	mode.emit_signal("item_selected", CoopMode.Mode.OFF)
	invite.button.emit_signal("pressed")
	yield(s._frames(1), "completed")
	t._check(
		mode.selected == CoopMode.Mode.ONLINE and mode.focus_mode == Control.FOCUS_NONE
		and _shown(panels).empty() and s._steam.created == 2 and s.transport.host_id == HOST
		and s._steam.invited == [LOBBY] and coop.pressed,
		"selection: a client's copy shows Online, changes nothing, has no invite"
	)
	s.transport.leave_lobby()
	CoopService.clear_coop_players()


func _choose(mode: OptionButton, index: int):
	mode.select(index)
	mode.emit_signal("item_selected", index)
	yield(s._frames(2), "completed")


# The slots showing the invite.
static func _shown(panels: Array) -> Array:
	var shown := []
	for i in panels.size():
		var invite = panels[i].get_node_or_null(SlotInvite.NODE_NAME)
		if invite != null and invite.is_visible_in_tree():
			shown.append(i)
	return shown


# The run option shown above the game's Co-op toggle (Ban, or Endless without it).
static func _row_above(coop: Control) -> Control:
	var above: Control = null
	for row in coop.get_parent().get_children():
		if row == coop:
			return above
		if row is BaseButton and row.visible:
			above = row
	return above


# What a PopupMenu draws with: its font, font colours (and which are overridden), panel and
# hover styles, check / radio icons.
static func _popup_look(popup: PopupMenu) -> Array:
	var overrides := []
	for name in POPUP_COLORS + ["font_color_focus", "font_color_pressed"]:
		if popup.has_color_override(name):
			overrides.append(name)
	var look := [["font", popup.get_font("font")], ["overrides", overrides]]
	for name in POPUP_COLORS:
		look.append([name, popup.get_color(name)])
	for name in ["panel", "hover"]:
		look.append([name, popup.get_stylebox(name)])
	for name in POPUP_ICONS:
		look.append([name, popup.get_icon(name)])
	return look  # an Array: Godot 3 compares Dictionaries by reference


# The popup's look opened with the mouse, with the mouse over the selected row, after picking that
# row with the mouse (nothing changes), and opened again. Player 1's cursor starts on the button.
func _popup_looks(button: OptionButton, emulator: Node):
	var popup: PopupMenu = button.get_popup()
	var row: int = button.selected
	var looks := []
	emulator.focused_control = button
	s._mouse_click(button)
	yield(s._frames(2), "completed")
	looks.append(_popup_look(popup))
	_mouse_on_row(popup, row, [])
	yield(s._frames(2), "completed")
	looks.append(_popup_look(popup))
	_mouse_on_row(popup, row, [true, false])
	yield(s._frames(3), "completed")
	looks.append(_popup_look(popup))
	s._mouse_click(button)
	yield(s._frames(2), "completed")
	looks.append(_popup_look(popup))
	popup.hide()
	yield(s._frames(2), "completed")
	return looks


# The mouse moved onto row `row` of an open popup, then pressed / released there (`presses`).
static func _mouse_on_row(popup: PopupMenu, row: int, presses: Array) -> void:
	var style: StyleBox = popup.get_stylebox("panel")
	var height: float = (popup.rect_size.y - style.get_minimum_size().y) / popup.get_item_count()
	var local := Vector2(popup.rect_size.x / 2.0, style.get_offset().y + height * (row + 0.5))
	var canvas: Vector2 = popup.get_global_transform_with_canvas().xform(local)
	var at: Vector2 = popup.get_viewport().get_final_transform().xform(canvas)
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)
	for pressed in presses:
		var click := InputEventMouseButton.new()
		click.button_index = BUTTON_LEFT
		click.pressed = pressed
		click.position = at
		click.global_position = at
		Input.parse_input_event(click)
