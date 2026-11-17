extends Reference
# Character selection with the lobby (ui/coop_mode.gd, ui/slot_invite.gd), run by
# lobby_menu_tests.gd with its fake Steam and its key / pad / action / mouse helpers:
#  - the Co-op row (Off / Local / Online) in the place of the game's Co-op toggle; Online off
#    without Steam; reached like the toggle (keyboard, pad, the grid's way up);
#  - the values: Off = solo, Local = the game's co-op, Online = co-op and a lobby; leaving Online
#    leaves the lobby; chosen with keys in Godot's popup and with player 1's FocusEmulator;
#  - Invite friends and the status in the next free player slot while hosting, reached by player 1
#    left from the Co-op row, opening Steam's invite dialog; players 2 to 4 never reach it;
#  - a mouse over Invite friends and away again leaves it as it was (no stuck hover / focus look);
#  - a remote player holding slot 1 changes nothing; a client's copy shows Online, inert.
# The layout (vanilla rects, nothing over the slot's texts): online_layout_tests.gd.

const CoopMode := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_mode.gd")
const SlotInvite := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/slot_invite.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const HOST := 2  # lobby_menu_tests.gd's
const LOBBY := 99
const KEYBOARD := 7
const PRESS_DELAY_SEC := 0.1

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

	# Solo: Godot's focus, keyboard and pad, as the toggle.
	var above: Control = _row_above(coop)
	above.grab_focus()
	yield(s._tap_key(KEY_DOWN), "completed")
	t._check(scene.get_focus_owner() == mode, "selection: down from %s is Co-op" % above.name)
	yield(s._tap_key(KEY_UP), "completed")
	t._check(scene.get_focus_owner() == above, "selection: and up again")
	yield(s._tap_pad(JOY_DPAD_DOWN), "completed")
	t._check(scene.get_focus_owner() == mode, "selection: pad down reaches Co-op too")
	# Keys in Godot's popup: Local.
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

	# Co-op: player 1's FocusEmulator. The next free slot is now the second.
	CoopService._add_player(KEYBOARD, CoopService.PlayerType.KEYBOARD_AND_MOUSE)
	yield(s._frames(2), "completed")
	invite = panels[1].get_node(SlotInvite.NODE_NAME)
	t._check(_shown(panels) == [1], "selection: a player joined: the invite moves on a slot")
	var emulator = Utils.get_focus_emulator(0, scene)
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

	# The mouse over Invite friends and away: its normal look again, no focus left on it (after
	# the 0.05 s a MyMenuButton stays off after a press).
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

	# Player 1's FocusEmulator in the values: Online -> Local leaves the lobby, co-op stays.
	emulator.focused_control = mode
	yield(s._tap_action("ui_accept", KEYBOARD), "completed")
	yield(s._tap_action("ui_up", KEYBOARD), "completed")
	yield(s._tap_action("ui_accept", KEYBOARD), "completed")
	t._check(
		mode.selected == CoopMode.Mode.LOCAL and not s.transport.is_active() and coop.pressed
		and _shown(panels).empty(),
		"selection: player 1 picks Local: the lobby is left, co-op stays, no invite"
	)

	# A remote player who holds player 1's slot does not switch the host's lobby.
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

	# A client's copy of the screen: the host's value, inert, no invite.
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
