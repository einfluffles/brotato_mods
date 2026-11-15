extends Reference
# The lobby in the game's own menus (ui/lobby_menu.gd), driven with key / pad / action events and
# a fake GodotSteam object (session_lifecycle_tests.gd) as the transport's Steam:
#  - title screen: the button among the game's, the page in its page stack, its buttons calling
#    the transport, a failed lobby in the main menu's error label;
#  - character selection: the Online toggle and Invite in the run options box, reached by
#    player 1's FocusEmulator, inert on a client;
#  - a client on a screen without a pause menu: pause opens the page as a popup, the game and
#    the host get nothing meanwhile;
#  - pause menu: the page in its stack (the menu's FocusEmulator), the question before leaving
#    mid-run, an invite accepted mid-run.

const Lifecycle := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/session_lifecycle_tests.gd"
)
const OnlineOptions := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/online_options.gd"
)
const LobbyPopup := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/lobby_popup.gd")
const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const LOCAL := 1
const HOST := 2
const LOBBY := 99
const KEYBOARD := 7  # the game's remapped device of the keyboard
const PAD := 0

var t: Node = null  # the test mod: _check()
var together: Node = null
var lobby: Node = null
var transport: Node = null
var session: Node = null
var _steam = null  # FakeSteam


class Probe:
	extends Node
	# Stands in for the game: records every key/pad event that reaches a normal node.
	var events := []

	func _ready() -> void:
		pause_mode = PAUSE_MODE_PROCESS

	func _input(event: InputEvent) -> void:
		if not (event is InputEventMouse):
			events.append(event)


func run(test_mod: Node, mod: Node):
	t = test_mod
	together = mod
	lobby = mod.get_node("LobbyMenu")
	transport = mod.transport
	session = mod.session
	var saved := {
		"steam": transport.steam,
		"local_id": transport.local_id,
		"players": CoopService.connected_players.duplicate(true),
		"listening": CoopService.listening_for_inputs,
		"play_mode": RunData.play_mode,
	}
	transport.steam = null
	yield(_test_title_screen(), "completed")
	yield(_test_failed_lobby(), "completed")
	yield(_test_character_selection(), "completed")
	yield(_test_client_popup(), "completed")
	yield(_test_pause_menu(), "completed")
	transport.leave_lobby()
	_tree().paused = false
	Puppet.set_active(false)
	transport.steam = saved.steam
	transport.local_id = saved.local_id
	transport.pending_join_id = 0
	session.peers.clear()
	together._client_active = false
	lobby.last_error = ""
	lobby.creating = false
	CoopService.connected_players = saved.players
	CoopService.listening_for_inputs = saved.listening
	RunData.play_mode = saved.play_mode
	yield(_frames(2), "completed")


func _tree() -> SceneTree:
	return t.get_tree()


func _frames(count: int):
	for _i in count:
		yield(_tree(), "idle_frame")


func _change_scene(path: String):
	_tree().paused = false
	_tree().change_scene(path)
	yield(_frames(3), "completed")  # loaded, and seen by LobbyMenu


func _fake_steam() -> void:
	_steam = Lifecycle.FakeSteam.new()
	transport.steam = _steam
	transport.local_id = LOCAL


# As session_lifecycle_tests.gd: in a lobby without Steam's callbacks.
func _enter_lobby(host_id: int, members: Array) -> void:
	transport.lobby_id = LOBBY
	transport.host_id = host_id
	transport.members = members.duplicate()
	_steam.lobby_members = [LOCAL] + members
	session._on_lobby_ready(LOBBY, host_id == LOCAL)


func _key(scancode: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.scancode = scancode
	event.physical_scancode = scancode  # the game binds arrows/WASD by physical key
	event.pressed = pressed
	Input.parse_input_event(event)


func _pad(button: int, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)


func _tap_key(scancode: int):
	_key(scancode, true)
	yield(_frames(1), "completed")
	_key(scancode, false)
	yield(_frames(2), "completed")


func _tap_pad(button: int):
	_pad(button, true)
	yield(_frames(1), "completed")
	_pad(button, false)
	yield(_frames(2), "completed")


# A player's device action, as a FocusEmulator reads it.
func _tap_action(action: String, device: int):
	var name := "%s_%s" % [action, device]
	VirtualDevices.press_button(name, device, true)
	yield(_frames(2), "completed")
	VirtualDevices.press_button(name, device, false)
	yield(_frames(2), "completed")


static func _texts(buttons: Array) -> Array:
	var texts := []
	for button in buttons:
		texts.append(button.text)
	return texts


func _test_title_screen():
	yield(_change_scene(MenuData.title_screen_scene), "completed")
	var scene := _tree().current_scene
	var menus: Node = scene._menus
	var main_menu: Node = scene._main_menu
	var start: Button = main_menu.start_button
	var button: Button = start.get_parent().get_node_or_null(lobby.ENTRY_NAME)
	var page: Control = menus.get_node_or_null(lobby.PAGE_NAME)
	t._check(button != null and page != null, "title: Online co-op button and page added")
	if button == null or page == null:
		return
	t._check(
		button.get_index() == start.get_index() + 1 and button.get_script() == start.get_script()
		and button.rect_min_size == start.rect_min_size and button.align == start.align,
		"title: the button is one of the game's menu buttons, below Start"
	)
	t._check(not page.visible and lobby.open_page() == null, "title: the page starts hidden")
	t._check(together.get_node_or_null("TogetherMenu") == null, "the overlay menu is gone")

	# The game's own focus handling: arrows along the column, accept opens the page.
	start.grab_focus()
	yield(_tap_key(KEY_DOWN), "completed")
	t._check(
		scene.get_focus_owner() == button, "title: down from Start is the button (focus chain)"
	)
	yield(_tap_key(KEY_UP), "completed")
	t._check(scene.get_focus_owner() == start, "title: and up again is Start")
	yield(_tap_key(KEY_F9), "completed")
	t._check(lobby.open_page() == null, "F9 is nobody's key")
	button.grab_focus()
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(
		page.visible and not main_menu.visible and menus._current_page == page
		and lobby.open_page() == page,
		"title: accept opens the page in the title screen's page stack"
	)
	t._check(scene._attenuate_background.visible, "title: dimmed like the game's other pages")
	t._check(
		page._host_button.disabled and "Steam is unavailable" in page._details.text
		and scene.get_focus_owner() == page._back_button,
		"page: without Steam Host lobby is off, with the reason; the cursor is on Back"
	)
	t._check(page._back_button.get_script() == start.get_script(), "page: the game's buttons")

	_fake_steam()
	page.refresh()
	t._check(
		_texts(page.nav_buttons()) == ["Host lobby", "MENU_BACK"],
		"page: not in a lobby -> Host lobby, Back %s" % [_texts(page.nav_buttons())]
	)
	yield(_tap_key(KEY_UP), "completed")
	t._check(scene.get_focus_owner() == page._host_button, "page: arrows move along its buttons")
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(_steam.created == 1 and lobby.creating, "page: Host lobby creates a Steam lobby")
	transport._on_lobby_created(transport.RESULT_OK, LOBBY)
	page.refresh()
	yield(_frames(1), "completed")
	t._check(
		_texts(page.nav_buttons()) == ["Invite friends", "Leave lobby", "MENU_BACK"]
		and scene.get_focus_owner() == page._invite_button and not lobby.creating,
		"page: hosting -> Invite, Leave, Back; the cursor moves on to Invite"
	)
	t._check(
		"Hosting · lobby %s" % LOBBY in page._details.text, "page: details say who hosts what"
	)
	var column: Rect2 = page._center.get_child(0).get_global_rect()
	var screen: Rect2 = scene.get_viewport_rect()
	t._check(
		screen.encloses(column) and abs(column.get_center().x - screen.get_center().x) < 2.0
		and page._invite_button.rect_size.x == 600.0,
		"page: centred on the screen, buttons as wide as the game's (%s in %s)" % [column, screen]
	)
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(_steam.invited == [LOBBY], "page: Invite friends opens Steam's invite dialog")
	yield(_tap_key(KEY_DOWN), "completed")
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(
		not transport.is_active() and not page.is_asking(),
		"page: outside a run Leave lobby leaves at once"
	)
	yield(_tap_key(KEY_ESCAPE), "completed")
	t._check(
		not page.visible and main_menu.visible and scene.get_focus_owner() == button,
		"title: cancel goes back to the main menu, the cursor on the button"
	)
	t._check(not scene._attenuate_background.visible, "title: background clear again")


# The error of a lobby that failed: in the main menu's error label (now, or after the return to
# the title screen) and in the page's details.
func _test_failed_lobby():
	var main_menu: Node = _tree().current_scene._main_menu
	var label: Label = main_menu.error_label
	t._check(not label.visible, "(control) no error on the title screen")
	lobby.host()
	transport._on_lobby_created(2, 0)
	t._check(
		label.visible and "createLobby failed" in label.text and not lobby.creating,
		"failed lobby: in the main menu's error label (%s)" % label.text
	)
	t._check("! createLobby failed" in lobby.details_text(), "failed lobby: in the page's details")

	yield(_change_scene(MenuData.character_selection_scene), "completed")
	_enter_lobby(HOST, [HOST])
	transport._on_lobby_chat_update(LOBBY, HOST, HOST, 2)  # the host left
	t._check(not transport.is_active(), "(control) host gone: lobby left")
	yield(_change_scene(MenuData.title_screen_scene), "completed")
	label = _tree().current_scene._main_menu.error_label
	t._check(
		label.visible and "The host left the lobby" in label.text,
		"host left: shown after the return to the title screen (%s)" % label.text
	)
	lobby.last_error = ""


func _test_character_selection():
	transport.steam = null
	RunData.play_mode = RunData.PlayMode.SOLO
	yield(_change_scene(MenuData.character_selection_scene), "completed")
	var scene := _tree().current_scene
	var coop: CheckButton = scene.get_node("%CoopButton")
	var options: Control = coop.get_parent().get_node_or_null(OnlineOptions.NODE_NAME)
	t._check(
		options != null and options.get_index() == coop.get_index() + 1,
		"selection: Online options below the Co-op toggle of the run options box"
	)
	if options == null:
		return
	var toggle: CheckButton = options._toggle
	var invite: Button = options._invite
	var status: Label = options._status
	t._check(
		toggle.disabled and status.visible and "Steam" in status.text and not invite.visible,
		"selection: without Steam the toggle is off, with the reason (%s)" % status.text
	)
	t._check(
		toggle.rect_size == coop.rect_size and toggle.get_icon("off_disabled") == coop.get_icon("off"),
		"selection: and still looks like the game's (%s / %s)" % [toggle.rect_size, coop.rect_size]
	)
	_fake_steam()
	yield(_frames(1), "completed")
	t._check(not toggle.disabled and not status.visible, "selection: with Steam it can be used")
	t._check(
		toggle.get_class() == coop.get_class() and toggle.get_font("font") == coop.get_font("font")
		and toggle.rect_size == coop.rect_size,
		"selection: the toggle looks like Co-op (%s / %s)" % [toggle.rect_size, coop.rect_size]
	)
	var panel: Control = scene.get_node("%RunOptionsPanel")
	print("  info: run options box %s with the Online toggle" % [panel.rect_size])

	# Solo: Godot's focus, down from Co-op.
	coop.grab_focus()
	yield(_tap_key(KEY_DOWN), "completed")
	t._check(scene.get_focus_owner() == toggle, "selection: down from Co-op is Online")
	t._check(not coop.pressed and not RunData.is_coop_run, "(control) solo so far")
	toggle.pressed = true
	yield(_frames(1), "completed")
	t._check(_steam.created == 1 and toggle.pressed, "selection: Online on hosts a lobby")
	t._check(coop.pressed and RunData.is_coop_run, "selection: and switches co-op on")
	t._check("creating" in status.text and status.visible, "selection: status while it is made")
	transport._on_lobby_created(transport.RESULT_OK, LOBBY)
	yield(_frames(2), "completed")
	t._check(
		invite.visible and status.text == "Online: 1 player" and toggle.pressed,
		"selection: hosting -> Invite friends and the player count (%s)" % status.text
	)
	print("  info: run options box %s while hosting" % [panel.rect_size])

	# Co-op: player 1's FocusEmulator, as for Endless / Co-op.
	CoopService._add_player(KEYBOARD, CoopService.PlayerType.KEYBOARD_AND_MOUSE)
	yield(_frames(2), "completed")
	var emulator = Utils.get_focus_emulator(0, scene)
	emulator.focused_control = coop
	yield(_tap_action("ui_down", KEYBOARD), "completed")
	t._check(emulator.focused_control == toggle, "selection: player 1's cursor reaches Online")
	yield(_tap_action("ui_down", KEYBOARD), "completed")
	t._check(emulator.focused_control == invite, "selection: and Invite friends below it")
	yield(_tap_action("ui_accept", KEYBOARD), "completed")
	t._check(_steam.invited == [LOBBY], "selection: Invite friends opens Steam's invite dialog")
	session._add_peer(HOST)
	yield(_frames(1), "completed")
	t._check(status.text == "Online: 2 players", "selection: status counts the lobby's players")
	session.peers.clear()
	yield(_tap_action("ui_up", KEYBOARD), "completed")
	yield(_tap_action("ui_accept", KEYBOARD), "completed")
	t._check(
		not transport.is_active() and not toggle.pressed and not invite.visible,
		"selection: Online off leaves the lobby"
	)
	t._check(coop.pressed, "selection: co-op stays as it is")

	# A remote player who holds player 1's slot does not switch the host's lobby.
	CoopService.connected_players[0][0] = VirtualDevices.FIRST
	emulator.player_index = -1
	emulator.player_index = 0
	emulator.focused_control = toggle
	yield(_tap_action("ui_accept", VirtualDevices.FIRST), "completed")
	t._check(
		_steam.created == 1 and not toggle.pressed, "selection: a remote player 1 changes nothing"
	)

	# A client's copy of the screen: hidden and inert.
	_enter_lobby(HOST, [HOST])
	yield(_frames(1), "completed")
	t._check(not options.visible, "selection: hidden on a client")
	toggle.emit_signal("toggled", true)
	invite.emit_signal("pressed")
	t._check(
		_steam.created == 1 and transport.host_id == HOST and _steam.invited == [LOBBY],
		"selection: inert on a client"
	)
	transport.leave_lobby()
	CoopService.clear_coop_players()


# A client on a screen without a pause menu (here the mod's waiting screen).
func _test_client_popup():
	var root := _tree().root
	var input_sync: Node = together.input_sync
	yield(_tap_pad(JOY_START), "completed")
	t._check(lobby.open_page() == null, "popup: pause opens nothing without a lobby")
	transport._on_lobby_created(transport.RESULT_OK, LOBBY)
	yield(_tap_pad(JOY_START), "completed")
	t._check(lobby.open_page() == null, "popup: nor for the host (it has the game's menus)")
	transport.leave_lobby()

	_enter_lobby(HOST, [HOST])
	session._add_peer(HOST).ready = true
	Puppet.set_active(true)
	together._client_active = true
	together._enter_client_view()
	yield(_frames(2), "completed")
	var view := _tree().current_scene
	t._check(
		view.get_script() == ClientView and lobby.popup_on_pause(view),
		"(control) client on the waiting screen: no pause menu"
	)
	var probe := Probe.new()
	root.add_child(probe)
	yield(_tap_key(KEY_ESCAPE), "completed")
	var page: Control = lobby.open_page()
	t._check(page != null and page.framed, "popup: releasing pause opens the page as a popup")
	if page == null:
		probe.queue_free()
		return
	var guard := root.get_node_or_null(LobbyPopup.GUARD_NAME)
	t._check(guard != null and guard.get_index() == root.get_child_count() - 1, "popup: guard last")
	t._check(input_sync.local_input_blocked, "popup: client input to the host neutral")
	t._check(
		_texts(page.nav_buttons()) == ["Invite friends", "Leave lobby", "MENU_BACK"]
		and page.get_focus_owner() == page._invite_button,
		"popup: a client's buttons, the cursor on the first %s" % [_texts(page.nav_buttons())]
	)
	t._check("Connected as client" in page._details.text, "popup: the same details")
	var panel: Rect2 = page._center.get_child(0).get_global_rect()
	var screen: Rect2 = page.get_viewport_rect()
	t._check(
		screen.encloses(panel) and (panel.get_center() - screen.get_center()).length() < 2.0,
		"popup: a panel in the middle of the screen (%s in %s)" % [panel, screen]
	)
	probe.events.clear()

	# Held keys: the game neither gets the events nor sees the actions, the host gets nothing.
	_key(KEY_DOWN, true)
	yield(_frames(1), "completed")
	t._check(probe.events.empty(), "popup: game gets no key events")
	t._check(not Input.is_action_pressed("ui_down"), "popup: polled action released")
	t._check(page.get_focus_owner() == page._leave_button, "popup: arrows move the cursor")
	_key(KEY_DOWN, false)
	yield(_frames(1), "completed")
	Input.action_press("ui_accept")
	Input.action_press("analog_move_right")
	var body: Array = input_sync.sample_local()
	t._check(
		body[1] == Vector2.ZERO and body[3] == 0, "popup: the host gets neutral input %s" % [body]
	)
	Input.action_release("ui_accept")
	Input.action_release("analog_move_right")

	# Mid-run: Leave asks on the game's confirm page; cancel goes back one step at a time.
	yield(_tap_key(KEY_ENTER), "completed")
	var question: String = page._confirm.get_node("Buttons/Label").text
	t._check(
		page.is_asking() and transport.is_active() and page._confirm is MenuConfirm
		and "Leave the lobby? You leave the host's run" in question,
		"popup: Leave lobby mid-run asks first, on the game's confirm page (%s)" % question
	)
	t._check(_texts(page.nav_buttons()) == ["MENU_YES", "MENU_NO"], "popup: Yes / No")
	yield(_tap_key(KEY_ESCAPE), "completed")
	t._check(
		not page.is_asking() and lobby.open_page() == page and transport.is_active()
		and page.get_focus_owner() == page._leave_button,
		"popup: cancel leaves the question, not the lobby"
	)
	_key(KEY_ESCAPE, true)
	yield(_frames(1), "completed")
	t._check(lobby.open_page() == null, "popup: cancel closes it")
	_key(KEY_ESCAPE, false)
	yield(_frames(2), "completed")
	t._check(probe.events.empty(), "popup: game got none of it (incl. the Esc release)")
	t._check(root.get_node_or_null(LobbyPopup.GUARD_NAME) == null, "popup: guard gone after close")
	t._check(not input_sync.local_input_blocked, "popup: client input back")
	yield(_tap_key(KEY_RIGHT), "completed")
	t._check(probe.events.size() == 2, "popup: game gets keys again (%d)" % probe.events.size())

	# Gamepad: Start opens and closes, B goes back.
	yield(_tap_pad(JOY_START), "completed")
	t._check(lobby.open_page() == page, "pad: Start opens the popup")
	yield(_tap_pad(JOY_DPAD_DOWN), "completed")
	yield(_tap_pad(JOY_BUTTON_0), "completed")
	t._check(page.is_asking(), "pad: d-pad and A reach Leave lobby")
	yield(_tap_pad(JOY_BUTTON_1), "completed")
	t._check(not page.is_asking() and lobby.open_page() == page, "pad: B backs out of the question")
	yield(_tap_pad(JOY_START), "completed")
	t._check(lobby.open_page() == null, "pad: Start closes it")
	probe.queue_free()

	# Yes leaves: the client is back on its title screen.
	yield(_tap_key(KEY_ESCAPE), "completed")
	lobby.open_page().ask_leave()
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(not transport.is_active() and lobby.open_page() == null, "popup: Yes leaves the lobby")
	yield(_frames(3), "completed")
	t._check(
		_tree().current_scene.filename == MenuData.title_screen_scene and not Puppet.is_active(),
		"popup: left -> the client's own title screen"
	)


# The pause menu of a run: a real pause here (nobody connected while frames pass).
func _test_pause_menu():
	t.coop_run(2)
	yield(_change_scene("res://main.tscn"), "completed")
	var tree := _tree()
	var main := tree.current_scene
	var menu: Node = main._pause_menu
	var main_menu: Node = menu._main_menu
	var options: Button = main_menu.get_node("%OptionsButton")
	var button: Button = options.get_parent().get_node_or_null(lobby.ENTRY_NAME)
	var page: Control = menu._menus.get_node_or_null(lobby.PAGE_NAME)
	t._check(button != null and page != null, "pause menu: Online co-op button and page added")
	if button == null or page == null:
		return
	t._check(
		button.get_index() == options.get_index() + 1 and button.get_script() == options.get_script()
		and button in main_menu._buttons_array,
		"pause menu: the button is one of the game's, between Options and Quit"
	)
	t._check(not lobby.popup_on_pause(main), "pause menu: no popup on a screen that has one")

	# Player 1 paused: the menu's FocusEmulator moves its cursor.
	menu.pause(0)
	yield(_frames(2), "completed")
	var emulator = menu._focus_emulator
	emulator.focused_control = options
	yield(_tap_action("ui_down", PAD), "completed")
	t._check(emulator.focused_control == button, "pause menu: the cursor reaches the button")
	yield(_tap_action("ui_accept", PAD), "completed")
	t._check(
		page.visible and not main_menu.visible and menu._menus._current_page == page
		and tree.paused and lobby.open_page() == page,
		"pause menu: accept opens the page in the menu's page stack"
	)
	t._check(
		emulator.focused_control == page._host_button, "pause menu: the cursor is on the page"
	)

	# Hosting mid-run (no frame passes meanwhile): Leave asks, No stays, Yes leaves the lobby only.
	transport._on_lobby_created(transport.RESULT_OK, LOBBY)
	page.refresh()
	t._check(lobby.is_mid_run(), "(control) a hosted battle is mid-run")
	page._leave_button.emit_signal("pressed")
	var confirm: Node = page._confirm
	var question: String = confirm.get_node("Buttons/Label").text
	t._check(
		page.is_asking() and transport.is_active() and "Your run goes on" in question,
		"pause menu: Leave lobby mid-run asks first (%s)" % question
	)
	confirm.get_node("Buttons/CancelButton").emit_signal("pressed")
	t._check(not page.is_asking() and transport.is_active() and page.visible, "No: still hosting")
	page._leave_button.emit_signal("pressed")
	confirm.get_node("Buttons/ConfirmButton").emit_signal("pressed")
	t._check(
		not transport.is_active() and tree.current_scene == main and tree.paused and page.visible,
		"Yes: the lobby is left, the run and its pause menu stay"
	)
	yield(_tap_action("ui_cancel", PAD), "completed")
	t._check(
		main_menu.visible and not page.visible and tree.paused,
		"pause menu: cancel goes back to its main page"
	)
	menu.unpause()
	yield(_frames(1), "completed")

	# A Steam invite accepted mid-run opens the pause menu on the page, with Join invite.
	transport._on_lobby_created(transport.RESULT_OK, LOBBY)
	transport._on_join_requested(555, 9)
	t._check(
		tree.paused and lobby.open_page() == page and page._join_button.visible
		and transport.is_active() and _steam.joined.empty(),
		"invite mid-run: the pause menu opens on the page, nothing joined yet"
	)
	t._check("A friend's invite is waiting" in page._details.text, "invite mid-run: explained")
	menu.unpause()
	t._check(transport.pending_join_id == 0, "invite mid-run: closing the menu declines it")
	transport._on_join_requested(555, 9)
	page._join_button.emit_signal("pressed")
	t._check(not transport.is_active() and _steam.joined == [555], "invite mid-run: Join joins")
	menu.unpause()
	yield(_frames(1), "completed")
