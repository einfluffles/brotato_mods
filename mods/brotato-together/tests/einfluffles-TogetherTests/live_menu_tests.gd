extends Reference
# The Esc menu during a wave of an online session: it opens over the running game, on the host
# and on a client (sync/pause_control.gd, extensions/ui/pause_menu.gd). No lobby in the headless
# suite: PauseControl's per-frame steps are called directly.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const PauseControl := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/pause_control.gd"
)
const Lifecycle := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/session_lifecycle_tests.gd"
)
const FAKE_PEER := 4242
const DEVICE := VirtualDevices.FIRST
const KEYBOARD := 7
const ACCEPT := 1
const PAUSE := 1 << VirtualDevices.PAUSE_INDEX
const PAUSE_ONE := 1 << (4 * VirtualDevices.PAUSE_INDEX)
const GUARD_SEC := 0.25  # longer than the menu's back guard

var t: Node
var together: Node
var input_sync: Node
var pause_control: Node
var _seq := 5000


func run(test_mod: Node, mod: Node):
	t = test_mod
	together = mod
	input_sync = mod.input_sync
	pause_control = mod.pause_control
	var session: Node = mod.session
	var saved_settings: Dictionary = ProgressData.settings.duplicate(true)
	pause_control.set_process(false)
	CoopService.connected_players.clear()
	CoopService.connected_players.push_back([KEYBOARD, CoopService.PlayerType.KEYBOARD_AND_MOUSE])
	CoopService.connected_players.push_back([DEVICE, CoopService.PlayerType.GAMEPAD_XBOX])
	session.peers[FAKE_PEER] = {
		"name": "Remote", "ready": true, "rtt_ms": 1, "last_seen_msec": OS.get_ticks_msec()
	}
	input_sync.devices[FAKE_PEER] = DEVICE
	input_sync._remote.erase(FAKE_PEER)
	t.get_tree().paused = false
	t.get_tree().change_scene("res://main.tscn")
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var main: Node = t.get_tree().current_scene
	yield(_test_host(main, session), "completed")
	yield(_test_client(main), "completed")
	input_sync.set_local_menu(-1)
	input_sync.blocked_by.erase(PauseControl.BLOCK_KEY)
	session.peers.erase(FAKE_PEER)
	ProgressData.settings = saved_settings
	t.get_tree().paused = false
	pause_control.set_process(true)


func _wait(seconds: float):
	yield(t.get_tree().create_timer(seconds), "timeout")


func _remote_pause_tap() -> void:
	for packet in [[0, 0], [PAUSE, PAUSE_ONE], [0, PAUSE_ONE]]:
		_seq += 1
		var no_move := Vector2.ZERO
		var body := [_seq, no_move, no_move, packet[0], packet[1], 0, PoolVector2Array(), 0]
		input_sync._apply_input(FAKE_PEER, body)
	Input.flush_buffered_events()


func _test_host(main: Node, session: Node):
	var tree: SceneTree = t.get_tree()
	var menu: Node = main._pause_menu
	var behavior: Node = main._players[0]._movement_behavior
	pause_control.host_update(main)
	t._check(menu.live, "host with a peer: the wave's menu is live")
	t._check(input_sync.blocked_mask() & PAUSE != 0, "remote pause is kept off the battle")
	t._check(InputMap.has_action("analog_move_left_%s" % VirtualDevices.IDLE), "idle device exists")

	# The game's own path: main polls the pause release.
	yield(t._tap_key(KEY_ESCAPE), "completed")
	t._check(
		menu.live_open and menu.visible and not tree.paused and menu._player_index == 0,
		"host Esc opens the menu without pausing"
	)
	pause_control.host_update(main)
	t._check(behavior.device == VirtualDevices.IDLE, "the menu owner's character stands still")
	t._check(main._players[1]._movement_behavior.device == DEVICE, "the others move on")
	var time_left: float = main._wave_timer.time_left
	yield(_wait(GUARD_SEC), "completed")
	t._check(main._wave_timer.time_left < time_left, "the wave runs on behind the menu")

	_remote_pause_tap()
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	t._check(
		menu.live_open and menu._player_index == 0 and input_sync.last_pause_msec(DEVICE) < 0,
		"a remote pause does not touch the host's menu"
	)

	# Esc is pause and cancel in one key: one step per press.
	menu._menus.on_restart_button_pressed()
	# No GUI focus owner headless; the page goes back to it.
	menu._menus._menu_restart.focus_before_created = menu._main_menu._resume_button
	yield(_wait(GUARD_SEC), "completed")
	yield(t._tap_key(KEY_ESCAPE), "completed")
	t._check(
		menu.live_open and menu._main_menu.visible, "Esc on a sub page goes one step back"
	)
	yield(_wait(GUARD_SEC), "completed")
	yield(t._tap_key(KEY_ESCAPE), "completed")
	t._check(not menu.live_open and not menu.visible and not tree.paused, "Esc again closes it")
	for _i in 3:
		yield(tree, "idle_frame")
		pause_control.host_update(main)
	t._check(not menu.live_open, "and it stays closed")
	t._check(behavior.device == KEYBOARD, "the character moves again")

	_remote_pause_tap()
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	t._check(not menu.live_open and not tree.paused, "a remote pause opens nothing on the host")

	ProgressData.settings.pause_on_focus_lost = true
	menu.on_game_lost_focus()
	t._check(not tree.paused and not menu.live_open, "focus loss does not pause a live wave")

	# The level-up panels need the buttons: the menu closes, and a pause there is a real one.
	menu.back_guard_msec = 0
	menu.pause(0)
	main._end_wave_timer_timedout = true
	pause_control.host_update(main)
	t._check(not menu.live_open and not menu.live, "the menu closes when the wave ends")
	menu.pause(0)
	t._check(tree.paused, "after the wave the pause is the game's own")
	menu.unpause()
	main._end_wave_timer_timedout = false

	session.peers.erase(FAKE_PEER)
	pause_control.host_update(main)
	menu.pause(0)
	t._check(tree.paused and not menu.live_open, "nobody connected: the game pauses as always")
	menu.unpause()
	t._check(not tree.paused, "and resumes")
	session.peers[FAKE_PEER] = {
		"name": "Remote", "ready": true, "rtt_ms": 1, "last_seen_msec": OS.get_ticks_msec()
	}
	menu.back_guard_msec = 200
	pause_control._hold_player(null)


# The same scene as a client's puppet battle; this client is player 1.
func _test_client(main: Node):
	var tree: SceneTree = t.get_tree()
	var menu: Node = main._pause_menu
	var main_menu: Node = menu._main_menu
	var you := 1
	main.set_process(false)
	PauseControl.disable_local_pause(main)
	input_sync.blocked_by.erase(PauseControl.BLOCK_KEY)
	yield(_wait(GUARD_SEC), "completed")
	pause_control.client_update(main, you)
	t._check(menu.live and not menu.live_open, "client: the wave's menu is live")
	t._check(
		main_menu.get_node("%RestartButton").disabled and main_menu.get_node("%EndRunButton").disabled,
		"restart and end run are the host's"
	)

	# A pause press the lobby popup took opens nothing.
	input_sync.local_input_blocked = true
	Input.action_press("ui_pause")
	pause_control.client_update(main, you)
	yield(tree, "idle_frame")
	input_sync.local_input_blocked = false
	Input.action_release("ui_pause")
	pause_control.client_update(main, you)
	t._check(not menu.live_open, "a pause press that went to the lobby popup opens nothing")

	yield(_client_pause_tap(main, you), "completed")
	t._check(
		menu.live_open and menu.visible and menu._player_index == you and not tree.paused,
		"client's pause opens its own menu, nothing pauses"
	)
	t._check(input_sync.menu_device() == DEVICE, "its buttons drive its own slot")

	# The host sees a player who lets go of everything.
	input_sync.sample_local()
	var counts: int = input_sync._presses.counts
	menu._focus_emulator.focused_control = main_menu._resume_button
	Input.action_press("ui_accept")
	Input.action_press("analog_move_right")
	var body: Array = input_sync.sample_local()
	t._check(
		body[1] == Vector2.ZERO and body[3] == 0 and body[4] == counts,
		"the host gets neutral input while the menu is open %s" % [body]
	)
	Input.flush_buffered_events()
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	t._check(not menu.live_open, "accept on Resume closes the client's menu")
	pause_control.client_update(main, you)
	t._check(input_sync.menu_device() == -1, "the buttons are the game's again")
	body = input_sync.sample_local()
	t._check(
		body[3] & ACCEPT != 0 and body[4] == counts and body[1].x > 0.5,
		"what was held for the menu is no press for the host %s" % [body]
	)
	Input.action_release("ui_accept")
	Input.action_release("analog_move_right")
	input_sync.sample_local()

	yield(_wait(GUARD_SEC), "completed")
	yield(_client_pause_tap(main, you), "completed")
	yield(_wait(GUARD_SEC), "completed")
	yield(_client_pause_tap(main, you), "completed")
	t._check(not menu.live_open, "pause again closes it")

	# The panels close it, and there is none for a spectator.
	menu.back_guard_msec = 0
	pause_control.toggle_client_menu(menu, you)
	main._coop_upgrades_ui.show()
	pause_control.client_update(main, you)
	t._check(not menu.live_open and not menu.live, "the level-up panels close the client's menu")
	main._coop_upgrades_ui.hide()
	pause_control.client_update(main, -1)
	pause_control.toggle_client_menu(menu, -1)
	t._check(not menu.live_open, "no menu for a spectator")

	# Quit asks to leave the lobby instead of dropping to the title screen: on the menu's lobby
	# page. In the host's lobby for that (no frame passes meanwhile).
	pause_control.client_update(main, you)
	pause_control.toggle_client_menu(menu, you)
	var lobby: Node = together.get_node("LobbyMenu")
	var transport: Node = together.transport
	var steam = transport.steam
	transport.steam = Lifecycle.FakeSteam.new()
	transport.lobby_id = 99
	transport.host_id = FAKE_PEER
	main_menu.emit_signal("quit_button_pressed")
	var page = lobby.open_page()
	t._check(
		menu.live_open and tree.current_scene == main and page != null
		and page.get_parent() == menu._menus and not main_menu.visible,
		"client's Quit opens the lobby page of its menu"
	)
	if page != null:
		var question: String = page._confirm.get_node("Buttons/Label").text
		t._check(
			page.is_asking() and "You leave the host's run" in question,
			"and asks before leaving the lobby (%s)" % question
		)
		t._check(
			menu._focus_emulator.focused_control == page._confirm.get_node("Buttons/ConfirmButton"),
			"the client's cursor is on the question"
		)
		page.back()
		t._check(not page.is_asking() and page.visible, "No goes back to the page")
	transport.lobby_id = 0
	transport.host_id = 0
	transport.steam = steam
	menu.unpause()
	t._check(not menu.live_open and (page == null or not page.visible), "the menu closes as before")
	yield(tree, "idle_frame")
	pause_control.client_update(main, you)
	t._check(not tree.paused, "the client never paused")


func _client_pause_tap(main: Node, you: int):
	Input.action_press("ui_pause")
	pause_control.client_update(main, you)
	yield(t.get_tree(), "idle_frame")
	Input.action_release("ui_pause")
	pause_control.client_update(main, you)
	yield(t.get_tree(), "idle_frame")
