extends Reference
# The lobby in the game's own menus (ui/lobby_menu.gd), driven with key / pad / action events and
# a fake GodotSteam object (session_lifecycle_tests.gd) as the transport's Steam:
#  - title screen: the button among the game's that hosts a lobby behind the main menu, the
#    frame with the players, Kick, Start leading to co-op; a client in its own main menu while
#    the host is in its own; a failed lobby in the main menu's error label;
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
const LobbyFrame := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/lobby_frame.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const LOCAL := 1
const HOST := 2
const CLIENT := 5
const LOBBY := 99
const PRESS_DELAY_SEC := 0.1  # a MyMenuButton is off for 0.05 s after a press
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
	yield(_test_client_title(), "completed")
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
	transport.kicked.clear()
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


# A client the host has welcomed, in a lobby with another client.
func _join_as_client() -> void:
	_enter_lobby(HOST, [HOST, CLIENT])
	session._on_peer_joined(HOST)
	var welcome := {"version": Protocol.VERSION, "accepted": true, "reason": "", "dlcs": []}
	_deliver(HOST, Protocol.Msg.WELCOME, welcome)


func _deliver(sender: int, msg_type: int, body) -> void:
	session._on_message_received(sender, 0, Protocol.encode(msg_type, body))


# The message types sent to a peer.
func _sent_to(steam_id: int) -> Array:
	var types := []
	for entry in _steam.sent:
		if entry[0] == steam_id:
			types.append(Protocol.decode(entry[2])[0])
	return types


static func _row_texts(frame: Control) -> Array:
	var texts := []
	for row in frame.rows:
		texts.append([row.name.text, row.note.text])
	return texts


func _wait(seconds: float):
	yield(_tree().create_timer(seconds), "timeout")


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


# The middle of a control in window coordinates, like a real mouse event's position.
static func _window_pos(control: Control) -> Vector2:
	var canvas_pos: Vector2 = control.get_global_transform_with_canvas().xform(
		control.rect_size / 2.0
	)
	return control.get_viewport().get_final_transform().xform(canvas_pos)


func _mouse_move(control: Control) -> void:
	var event := InputEventMouseMotion.new()
	event.position = _window_pos(control)
	event.global_position = event.position
	Input.parse_input_event(event)


func _mouse_click(control: Control) -> void:
	_mouse_move(control)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = BUTTON_LEFT
		event.pressed = pressed
		event.position = _window_pos(control)
		event.global_position = event.position
		Input.parse_input_event(event)


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
	var left: Control = start.get_parent()
	var button: Button = left.get_node_or_null(lobby.ENTRY_NAME)
	var frame: Control = left.get_parent().get_node_or_null(LobbyFrame.NODE_NAME)
	t._check(button != null and frame != null, "title: Host lobby button and lobby frame added")
	if button == null or frame == null:
		return
	t._check(
		button.get_index() == start.get_index() + 1 and button.get_script() == start.get_script()
		and button.rect_min_size.y == start.rect_min_size.y and button.align == start.align
		and button.text == "Host lobby",
		"title: the button is one of the game's menu buttons, below Start"
	)
	t._check(
		menus.get_node_or_null(lobby.PAGE_NAME) == null and not frame.visible
		and lobby.open_page() == null,
		"title: no page of its own, and no frame without a lobby"
	)
	t._check(together.get_node_or_null("TogetherMenu") == null, "the overlay menu is gone")
	var left_rect := left.get_global_rect()
	var right_rect: Rect2 = main_menu.right_container.get_global_rect()

	# The game's own focus handling: arrows along the column.
	start.grab_focus()
	yield(_tap_key(KEY_DOWN), "completed")
	t._check(
		scene.get_focus_owner() == button, "title: down from Start is the button (focus chain)"
	)
	yield(_tap_key(KEY_UP), "completed")
	t._check(scene.get_focus_owner() == start, "title: and up again is Start")
	yield(_tap_key(KEY_F9), "completed")
	t._check(lobby.open_page() == null and not frame.visible, "F9 is nobody's key")

	# Without Steam: the reason, where the game reports its own errors.
	button.grab_focus()
	yield(_tap_key(KEY_ENTER), "completed")
	var label: Label = main_menu.error_label
	t._check(
		label.visible and "Steam is unavailable" in label.text and not frame.visible,
		"title: without Steam the button says why in the error label (%s)" % label.text
	)
	lobby.last_error = ""

	# Hosting: the lobby is made behind the main menu, which stays as it is.
	_fake_steam()
	yield(_wait(PRESS_DELAY_SEC), "completed")
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(
		_steam.created == 1 and lobby.creating and button.text == "Creating lobby…"
		and frame.visible and "Creating" in frame.hint.text,
		"title: accept hosts a lobby; the frame says it is being made (%s)" % button.text
	)
	yield(_wait(PRESS_DELAY_SEC), "completed")
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(_steam.created == 1, "title: asked once, however often the button is pressed")
	transport._on_lobby_created(transport.RESULT_OK, LOBBY)
	yield(_frames(2), "completed")
	t._check(
		main_menu.visible and menus._current_page == main_menu
		and not scene._attenuate_background.visible and scene.get_focus_owner() == button,
		"title: the main menu stays, the cursor where it was"
	)
	t._check(
		button.text == "Invite friends" and _row_texts(frame) == [["local", "host"]]
		and frame.rows[0].kick == null and frame.leave_button.visible,
		"frame: hosting -> this player as host, Leave lobby %s" % [_row_texts(frame)]
	)
	var panel: Rect2 = frame.get_child(0).get_global_rect()
	t._check(
		scene.get_viewport_rect().encloses(panel) and panel.position.x >= left_rect.end.x
		and panel.end.x <= right_rect.position.x and panel.size.x == frame.WIDTH
		and left.get_global_rect() == left_rect
		and main_menu.right_container.get_global_rect() == right_rect,
		"frame: between the button columns, which stay where they are (%s, left %s)"
		% [panel, left.get_global_rect()]
	)
	yield(_wait(PRESS_DELAY_SEC), "completed")
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(_steam.invited == [LOBBY], "title: the button now opens Steam's invite dialog")
	main_menu.options_button.emit_signal("pressed")
	yield(_frames(2), "completed")
	t._check(
		menus._current_page == menus._menu_choose_options and transport.is_host(),
		"title: the game's pages open while the lobby is up"
	)
	menus.on_options_back_button_pressed()
	yield(_frames(2), "completed")
	t._check(main_menu.visible and frame.is_visible_in_tree(), "title: and back, the frame is there")

	# A friend joins: a row with Kick, reached with the cursor from the button.
	_steam.lobby_members = [LOCAL, CLIENT]
	transport._on_lobby_chat_update(LOBBY, CLIENT, CLIENT, 1)
	yield(_frames(2), "completed")
	t._check(
		_row_texts(frame) == [["local", "host"], ["friend 5", "connecting"]]
		and frame.rows[1].kick != null and frame._count.text == "2 / 4",
		"frame: a joining player gets a row with Kick %s" % [_row_texts(frame)]
	)
	session.peers[CLIENT].rtt_ms = 34
	session.peers[CLIENT].ready = true
	yield(_frames(1), "completed")
	t._check(frame.rows[1].note.text == "34 ms", "frame: the ping of a connected player")
	t._check("comes along" in frame.hint.text, "frame: what Start does now (%s)" % frame.hint.text)
	var kick: Button = frame.rows[1].kick
	button.grab_focus()
	yield(_tap_key(KEY_RIGHT), "completed")
	t._check(scene.get_focus_owner() == kick, "frame: right of the button is Kick")
	yield(_tap_key(KEY_DOWN), "completed")
	t._check(scene.get_focus_owner() == frame.leave_button, "frame: below it Leave lobby")
	yield(_tap_key(KEY_DOWN), "completed")
	yield(_tap_key(KEY_LEFT), "completed")
	t._check(scene.get_focus_owner() == button, "frame: around, and left is the button again")

	# Kick: told to leave, gone here at once, and nothing of it is heard any more.
	yield(_tap_key(KEY_RIGHT), "completed")
	_steam.sent.clear()
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(
		_sent_to(CLIENT).has(Protocol.Msg.KICK) and not session.peers.has(CLIENT)
		and not transport.members.has(CLIENT) and _row_texts(frame) == [["local", "host"]],
		"kick: the player is told and is out of the lobby %s" % [_row_texts(frame)]
	)
	t._check(scene.get_focus_owner() == frame.leave_button, "kick: the cursor moves on")
	_steam.queue(CLIENT, 0, Protocol.encode(Protocol.Msg.HELLO, {}))
	yield(_frames(2), "completed")
	t._check(
		_steam.inbox.empty() and not session.peers.has(CLIENT) and frame.rows.size() == 1,
		"kick: a game that stays in Steam's lobby is not listened to"
	)
	transport.kicked[CLIENT] = OS.get_ticks_msec() - transport.KICK_CLOSE_MSEC
	yield(_frames(1), "completed")
	t._check(transport.kicked[CLIENT] == -1, "kick: its session is closed after the message")
	_steam.lobby_members = [LOCAL]
	transport._on_lobby_chat_update(LOBBY, CLIENT, CLIENT, 2)
	_steam.lobby_members = [LOCAL, CLIENT]
	transport._on_lobby_chat_update(LOBBY, CLIENT, CLIENT, 1)
	yield(_frames(2), "completed")
	t._check(
		transport.kicked.empty() and session.peers.has(CLIENT) and frame.rows.size() == 2,
		"kick: once it has left it can be invited again"
	)

	# Start with the lobby up: everybody comes along, so it is a co-op run.
	RunData.play_mode = RunData.PlayMode.SOLO
	start.emit_signal("pressed")
	yield(_frames(4), "completed")
	var selection := _tree().current_scene
	var coop = selection.get_node_or_null("%CoopButton")
	t._check(
		selection.filename == MenuData.character_selection_scene and coop != null
		and coop.pressed and RunData.is_coop_run and transport.is_host(),
		"title: Start with a lobby opens character selection in co-op"
	)

	# Back in the main menu the lobby is still there; Leave lobby ends it.
	yield(_change_scene(MenuData.title_screen_scene), "completed")
	scene = _tree().current_scene
	main_menu = scene._main_menu
	button = main_menu.start_button.get_parent().get_node(lobby.ENTRY_NAME)
	frame = button.get_parent().get_parent().get_node(LobbyFrame.NODE_NAME)
	t._check(
		frame.visible and frame.rows.size() == 2 and button.text == "Invite friends",
		"title: back from a screen the lobby is as it was"
	)
	frame.leave_button.grab_focus()
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(
		not transport.is_active() and not frame.visible and button.text == "Host lobby"
		and scene.get_focus_owner() == button,
		"frame: Leave lobby ends it; the cursor is on Host lobby"
	)
	t._check(
		button.focus_neighbour_right == main_menu.start_button.focus_neighbour_right,
		"title: without the frame the button's neighbours are the game's again"
	)
	CoopService.clear_coop_players()
	RunData.play_mode = RunData.PlayMode.SOLO


# A client of a host that is in its main menu: in its own, without Start and Continue.
func _test_client_title():
	yield(_change_scene(MenuData.title_screen_scene), "completed")
	var scene := _tree().current_scene
	var menus: Node = scene._menus
	var main_menu: Node = scene._main_menu
	var start: Button = main_menu.start_button
	var resume: Button = main_menu.continue_button
	var button: Button = start.get_parent().get_node(lobby.ENTRY_NAME)
	var frame: Control = button.get_parent().get_parent().get_node(LobbyFrame.NODE_NAME)
	var input_sync: Node = together.input_sync
	var stream: Node = together.state_stream
	var title_state := {"kind": "title_screen", "screen": 1, "count": 0, "selected": [], "grids": {}}
	var resume_state := {"kind": "coop_resume", "screen": 2, "count": 0, "selected": [], "grids": {}}

	# Joining from the main menu: no waiting screen, the lobby shows in the frame.
	_join_as_client()
	yield(_frames(2), "completed")
	t._check(
		together._client_active and _tree().current_scene == scene and main_menu.visible,
		"client: joining from the main menu stays in the main menu"
	)
	t._check(
		_row_texts(frame) == [["friend 2", "host"], ["local", "you"], ["friend 5", ""]]
		and frame.nav_buttons().empty() and not frame.leave_button.visible,
		"client: the frame lists the lobby, without Kick or its own Leave %s" % [_row_texts(frame)]
	)
	t._check(
		"Waiting for friend 2" in frame.hint.text, "client: who starts (%s)" % frame.hint.text
	)
	t._check(
		start.disabled and resume.disabled and button.text == "Leave lobby"
		and scene.get_focus_owner() == button,
		"client: Start and Continue are off, the cursor is on Leave lobby"
	)
	start.grab_focus()
	yield(_tap_key(KEY_ENTER), "completed")
	yield(_tap_key(KEY_ESCAPE), "completed")
	t._check(
		_tree().current_scene == scene and lobby.open_page() == null,
		"client: accept on Start starts nothing, pause opens no popup"
	)

	# The host's state says it is in its main menu: this game is its player's own meanwhile.
	Puppet.set_active(true)  # as left by a screen of the host
	together._on_menu_state(title_state)
	t._check(
		together._own_menus and _tree().current_scene == scene and not Puppet.is_active()
		and session.borrow_parked and together.ui_sounds.silent,
		"client: own menus -> no puppet mode, no borrowed DLC, none of the host's menu sounds"
	)
	Input.action_press("ui_accept")
	var body: Array = input_sync.sample_local()
	Input.action_release("ui_accept")
	t._check(
		input_sync.local_input_blocked and body[3] == 0, "client: the host gets neutral input"
	)
	main_menu.options_button.emit_signal("pressed")
	yield(_frames(2), "completed")
	t._check(menus._current_page == menus._menu_choose_options, "client: the game's pages open")
	menus.on_options_back_button_pressed()
	resume.show()
	resume.activate()  # as the game does on the way back when a run is saved
	yield(_frames(2), "completed")
	t._check(
		main_menu.visible and start.disabled and resume.disabled,
		"client: back on the main page Start and Continue are off again"
	)

	# What the host sends from its main menu changes nothing; its first screen ends it.
	session.emit_signal("host_message", Protocol.Msg.STATE, [stream.MENU, 2, title_state])
	session.emit_signal("host_message", Protocol.Msg.STATE, [stream.MENU_GRIDS, 2, {}])
	session.emit_signal("host_message", Protocol.Msg.STATE, [stream.RUN_SHOP, 2, null])
	session.emit_signal("host_message", Protocol.Msg.UI_SOUNDS, {})
	t._check(together._own_menus, "client: the host's main menu state keeps it there")
	session.emit_signal("host_message", Protocol.Msg.STATE, [stream.MENU, 3, resume_state])
	t._check(
		not together._own_menus and not input_sync.local_input_blocked
		and not session.borrow_parked and not together.ui_sounds.silent,
		"client: the host's next screen takes input, DLC and sounds back"
	)
	together._on_menu_state(resume_state)
	yield(_frames(2), "completed")
	var view := _tree().current_scene
	t._check(
		view.get_script() == ClientView and lobby.popup_on_pause(view),
		"client: a host screen without a copy is the waiting screen, as before"
	)

	# The host returns to its main menu (end of a run): the client's own title screen loads.
	Puppet.set_active(true)
	together._on_menu_state(title_state)
	yield(_frames(3), "completed")
	scene = _tree().current_scene
	t._check(
		scene.filename == MenuData.title_screen_scene and together._own_menus
		and not Puppet.is_active() and transport.is_active(),
		"client: the host back in its main menu -> this game's own, still in the lobby"
	)
	if scene.filename != MenuData.title_screen_scene:
		return
	main_menu = scene._main_menu
	start = main_menu.start_button
	button = start.get_parent().get_node(lobby.ENTRY_NAME)
	frame = button.get_parent().get_parent().get_node(LobbyFrame.NODE_NAME)
	t._check(
		start.disabled and frame.visible and button.text == "Leave lobby"
		and not lobby.popup_on_pause(scene),
		"client: with the frame and without Start there too"
	)
	session.emit_signal("host_message", Protocol.Msg.BATTLE_START, {})
	t._check(not together._own_menus, "client: a battle of the host ends it as well")
	together._on_menu_state(title_state)

	# Kicked: out of the lobby, with the reason; the main menu is the player's again.
	_deliver(HOST, Protocol.Msg.KICK, null)
	yield(_frames(2), "completed")
	var label: Label = main_menu.error_label
	t._check(
		not transport.is_active() and not together._client_active and not together._own_menus
		and not input_sync.local_input_blocked,
		"kicked: the client has left the lobby"
	)
	t._check(
		_tree().current_scene == scene and label.visible and "removed you" in label.text,
		"kicked: the main menu stays, with the reason in its error label (%s)" % label.text
	)
	t._check(
		not start.disabled and not frame.visible and button.text == "Host lobby",
		"kicked: Start is back, the frame gone"
	)
	lobby.last_error = ""

	# Leave lobby on the button.
	_join_as_client()
	yield(_frames(2), "completed")
	t._check(start.disabled and button.text == "Leave lobby", "(control) a client again")
	button.grab_focus()
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(
		not transport.is_active() and _tree().current_scene == scene and not start.disabled
		and button.text == "Host lobby" and not together._client_active,
		"client: Leave lobby leaves; the main menu is the player's again"
	)


# The error of a lobby that failed: in the main menu's error label (now, or after the return to
# the title screen) and in the page's details.
func _test_failed_lobby():
	yield(_change_scene(MenuData.title_screen_scene), "completed")
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

	# Mouse (a co-op screen's FocusEmulators would keep it from the GUI): pointing moves the
	# cursor, a click presses.
	yield(_tap_key(KEY_ESCAPE), "completed")
	_mouse_move(page._back_button)
	yield(_frames(1), "completed")
	t._check(page.get_focus_owner() == page._back_button, "mouse: pointing takes the cursor")
	_mouse_click(page._leave_button)
	yield(_frames(2), "completed")
	t._check(page.is_asking() and transport.is_active(), "mouse: a click presses Leave lobby")
	_mouse_click(page._confirm.get_node("Buttons/CancelButton"))
	yield(_frames(2), "completed")
	t._check(not page.is_asking() and lobby.open_page() == page, "mouse: No on the question")
	_mouse_click(page._back_button)
	yield(_frames(2), "completed")
	t._check(lobby.open_page() == null, "mouse: Back closes the popup")

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
