extends Reference
# Remote input edges (press counters, timeouts, pause), menu echo, the client's own aim
# preference, pause-menu ownership and absent players. Called from mod_main.gd's flow.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const LocalAim := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/local_aim.gd")
const PauseControl := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/pause_control.gd"
)
const AbsentPlayers := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/absent_players.gd"
)
const FAKE_PEER := 4242
const DEVICE := VirtualDevices.FIRST
const ACCEPT := 1  # bit of ui_accept; its counter is bits 0..3
const PAUSE := 1 << VirtualDevices.PAUSE_INDEX
const PAUSE_ONE := 1 << (4 * VirtualDevices.PAUSE_INDEX)  # one press on the pause counter
const LEFT_INDEX := 6

var t: Node  # the test mod (checks, tree)
var together: Node
var input_sync: Node
var _probe: Node = null
var _seq := 1000


# Records the virtual device's action events.
class Probe:
	extends Node
	var suffix := ""
	var events := []

	func _input(event: InputEvent) -> void:
		if event is InputEventAction and event.action.ends_with(suffix):
			events.append([event.action.trim_suffix(suffix), event.pressed])


func _init(test_mod: Node, mod: Node) -> void:
	t = test_mod
	together = mod
	input_sync = mod.input_sync


func run():
	yield(t.get_tree(), "idle_frame")
	_probe = Probe.new()
	_probe.suffix = "_%s" % DEVICE
	t.get_tree().root.add_child(_probe)  # last child: sees input events first
	_test_edges()
	_test_pause_edges()
	_test_echo()
	_probe.queue_free()
	yield(_test_aim(), "completed")
	yield(_test_pause_menu(), "completed")
	yield(_test_absent_panels(), "completed")
	yield(_test_absent_shop(), "completed")


func _send(held: int, counts: int, flags := 0) -> void:
	_seq += 1
	input_sync._apply_input(
		FAKE_PEER, [_seq, Vector2.ZERO, Vector2.ZERO, held, counts, flags, PoolVector2Array(), 0]
	)
	Input.flush_buffered_events()


func _restart_peer() -> void:
	input_sync._remote.erase(FAKE_PEER)
	input_sync.devices[FAKE_PEER] = DEVICE
	VirtualDevices.release_all(DEVICE)
	Input.flush_buffered_events()


func _take_events() -> Array:
	var events: Array = _probe.events
	_probe.events = []
	return events


func _accept_down() -> bool:
	return Input.is_action_pressed("ui_accept_%s" % DEVICE)


func _time_out() -> void:
	input_sync._remote[FAKE_PEER].last_msec = 0
	input_sync._release_timed_out()
	Input.flush_buffered_events()


func _test_edges() -> void:
	_restart_peer()
	_send(ACCEPT, 4)
	t._check(not _accept_down(), "held at (re)join: no press without a counted edge")
	_send(0, 4)
	_send(ACCEPT, 5)
	t._check(_accept_down(), "counted press")
	_take_events()
	_time_out()
	t._check(not _accept_down(), "timeout releases a held button")
	_send(ACCEPT, 5)
	t._check(
		not _accept_down() and _take_events() == [["ui_accept", false]],
		"still held after timeout: no second press"
	)
	_send(0, 5)
	_send(ACCEPT, 6)
	t._check(_accept_down(), "press after release counts again")
	_send(0, 6)
	_take_events()
	_send(0, 7)  # press and release both fell into a loss burst
	var events := _take_events()
	t._check(
		events == [["ui_accept", true], ["ui_accept", false]] and not _accept_down(),
		"lost tap replayed once %s" % [events]
	)


func _test_pause_edges() -> void:
	_restart_peer()
	_send(0, 0)
	_take_events()
	_send(PAUSE, PAUSE_ONE)
	t._check(not Input.is_action_pressed("ui_pause_%s" % DEVICE), "pause never held on host")
	_time_out()
	t._check(_take_events().empty(), "timeout doesn't synthesize a pause")
	_send(0, PAUSE_ONE)
	var events := _take_events()
	t._check(
		events == [["ui_pause", true], ["ui_pause", false]],
		"pause delivered on the client's release %s" % [events]
	)
	_send(0, 2 * PAUSE_ONE)
	t._check(_take_events().size() == 2, "lost pause tap delivered")
	_send(0, 2 * PAUSE_ONE)
	t._check(_take_events().empty(), "no repeat without a new press")


func _test_echo() -> void:
	_restart_peer()
	_send(0, 0)
	var left := 1 << LEFT_INDEX
	_send(left, 1 << (4 * LEFT_INDEX))
	_take_events()
	var buttons = input_sync._remote[FAKE_PEER].buttons
	var echoes := []
	for step in [[0.0, true], [0.2, true], [0.15, true], [0.1, true], [0.1, false], [0.35, true]]:
		buttons.process_echo(step[0], step[1])
		Input.flush_buffered_events()
		echoes.append(_take_events().size())
	t._check(echoes == [0, 0, 1, 1, 0, 0], "held direction repeats like pad echo %s" % [echoes])
	_send(0, 1 << (4 * LEFT_INDEX))
	buttons.process_echo(1.0, true)
	Input.flush_buffered_events()
	t._check(_take_events() == [["ui_left", false]], "released direction stops repeating")


func _test_aim():
	var saved: Dictionary = ProgressData.settings.duplicate()
	_restart_peer()
	CoopService.connected_players.clear()
	CoopService.connected_players.push_back([6, CoopService.PlayerType.GAMEPAD_XBOX])
	CoopService.connected_players.push_back([DEVICE, CoopService.PlayerType.GAMEPAD_XBOX])
	ProgressData.settings.manual_aim = true
	ProgressData.settings.manual_aim_on_mouse_press = false
	yield(t.get_tree(), "idle_frame")  # Utils caches is_manual_aim per frame
	_send(0, 0, 0)
	t._check(Utils.is_manual_aim(0), "local pad player follows the host's manual aim")
	t._check(not Utils.is_manual_aim(1), "remote auto-aim player stays auto with host manual")
	ProgressData.settings.manual_aim = false
	_send(0, 0, LocalAim.FLAG_MANUAL)
	t._check(Utils.is_manual_aim(1), "remote manual-aim player is manual with host auto")

	# Client side: the client's own settings and device decide.
	var own := Node2D.new()
	t.get_tree().root.add_child(own)
	own.global_position = Vector2(5000, 5000)
	ProgressData.settings.manual_aim = true
	var mouse: Array = LocalAim.sample(own, false)
	t._check(
		mouse[0] == LocalAim.FLAG_MANUAL and abs(mouse[1].length() - 1.0) < 0.01,
		"mouse manual aim: direction to the mouse %s" % [mouse]
	)
	var pad: Array = LocalAim.sample(own, true)
	t._check(pad[0] == LocalAim.FLAG_MANUAL and pad[1] == Vector2.ZERO, "pad aims with its stick")
	t._check(LocalAim.sample(null, false)[1] == Vector2.ZERO, "no mouse aim outside the fight")
	ProgressData.settings.manual_aim = false
	t._check(LocalAim.sample(own, false) == [0, Vector2.ZERO], "auto aim sends no aim")
	ProgressData.settings.manual_aim_on_mouse_press = true
	t._check(LocalAim.sample(own, true)[0] == 0, "aim on press: idle stick is auto")
	own.queue_free()
	ProgressData.settings = saved
	_send(0, 0, 0)


# Remote player 0 pauses; the host's local player 1 gets the menu; only the pauser resumes.
func _test_pause_menu():
	var pause_control: Node = together.pause_control
	var session: Node = together.session
	CoopService.connected_players.clear()
	CoopService.connected_players.push_back([DEVICE, CoopService.PlayerType.GAMEPAD_XBOX])
	CoopService.connected_players.push_back([6, CoopService.PlayerType.GAMEPAD_XBOX])
	session.peers[FAKE_PEER] = {
		"name": "Remote", "ready": false, "rtt_ms": -1, "last_seen_msec": OS.get_ticks_msec()
	}
	t.get_tree().change_scene("res://main.tscn")
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var main: Node = t.get_tree().current_scene
	var menu: Node = main._pause_menu
	var buttons = input_sync._remote[FAKE_PEER].buttons
	ProgressData.settings.pause_on_focus_lost = true

	buttons.last_pause_msec = OS.get_ticks_msec()
	menu.pause(0)
	pause_control.handle_pause(menu)
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	t._check(
		t.get_tree().paused and menu._player_index == 1 and menu._focus_emulator.player_index == 1,
		"remote pause: menu goes to the host's local player"
	)
	t._check(pause_control.paused_by() == ["Remote", FAKE_PEER], "pauser known")
	yield(_tap_remote_pause(), "completed")
	t._check(not t.get_tree().paused, "the remote player who paused resumes")

	menu.pause(1)
	pause_control.handle_pause(menu)
	yield(t.get_tree(), "idle_frame")
	t._check(pause_control.paused_by() == ["", 0], "host pause: paused by the host")
	yield(_tap_remote_pause(), "completed")
	t._check(t.get_tree().paused, "a remote player can't resume the host's pause")
	menu.unpause()

	buttons.last_pause_msec = -1  # focus loss on the host: the game pauses for player 0
	menu.on_game_lost_focus()
	pause_control.handle_pause(menu)
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	t._check(
		menu._player_index == 1 and pause_control.paused_by() == ["", 0],
		"host focus loss with remote player 0: host owns the menu"
	)
	menu.unpause()
	yield(t.get_tree(), "idle_frame")
	_test_client_pause(main)


func _tap_remote_pause():
	VirtualDevices.press_button("ui_pause_%s" % DEVICE, DEVICE, true)
	VirtualDevices.press_button("ui_pause_%s" % DEVICE, DEVICE, false)
	Input.flush_buffered_events()
	yield(t.get_tree(), "idle_frame")


# Client: focus loss / pad disconnect / pause never open the puppet scene's pause menu.
func _test_client_pause(main: Node) -> void:
	ProgressData.settings.pause_on_focus_lost = true
	InputService.emit_signal("game_lost_focus")
	t._check(t.get_tree().paused, "unpatched battle pauses on focus loss (the bug)")
	main._pause_menu.unpause()
	PauseControl.disable_local_pause(main)
	InputService.emit_signal("game_lost_focus")
	InputService.on_joy_connection_changed(0, false)
	main._pause_menu.pause(0)
	t._check(not t.get_tree().paused, "puppet battle never pauses locally")
	t._check(
		PauseControl.banner_text("Remote", FAKE_PEER, FAKE_PEER).begins_with("Paused by you"),
		"pauser sees their own pause"
	)
	t._check(PauseControl.banner_text("", 0, FAKE_PEER) == "Paused by the host", "host pause text")


# Absent players: their level-up / crate choices are made the game's way.
func _test_absent_panels():
	var main: Node = t.get_tree().current_scene
	var ui = main.get("_coop_upgrades_ui")
	var level_up = UpgradesUI.UpgradeToProcess.new()
	level_up.level = 2
	level_up.player_index = 0
	var crate_open = UpgradesUI.ConsumableToProcess.new()
	crate_open.consumable_data = t._find_by_id(ItemService.consumables, "consumable_item_box")
	crate_open.player_index = 1
	var items_before: int = RunData.get_player_items(1).size() + RunData.get_player_weapons(1).size()
	var gold_before: int = RunData.get_player_gold(1)
	ui.show_options([[], [crate_open], [], []], [[level_up], [], [], []])
	yield(t.get_tree(), "idle_frame")
	for p in 2:
		AbsentPlayers.resolve_panel(ui._get_player_container(p))
	yield(t.get_tree(), "idle_frame")
	var level_done: bool = (
		not ui.visible
		or ui._get_player_container(0)._checkmark_group.visible
	)
	t._check(level_done, "absent player's level-up picked")
	var items_after: int = RunData.get_player_items(1).size() + RunData.get_player_weapons(1).size()
	t._check(
		items_after > items_before or RunData.get_player_gold(1) > gold_before,
		"absent player's crate taken or recycled"
	)


func _test_absent_shop():
	var session: Node = together.session
	var absent: Node = together.absent_players
	CoopService.connected_players.clear()
	CoopService.connected_players.push_back([6, CoopService.PlayerType.GAMEPAD_XBOX])
	CoopService.connected_players.push_back([DEVICE, CoopService.PlayerType.GAMEPAD_XBOX])
	t.get_tree().change_scene(RunData.get_shop_scene_path())
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var shop: Node = t.get_tree().current_scene
	var now := OS.get_ticks_msec()
	session.peers[FAKE_PEER] = {
		"name": "Remote", "ready": true, "rtt_ms": 1, "last_seen_msec": now - 2000
	}
	absent.check(now)
	t._check(absent.absent.empty(), "a lagging player is not absent")
	session.peers[FAKE_PEER].last_seen_msec = now - 10000
	absent.check(now)
	t._check(
		absent.absent.has(FAKE_PEER) and not shop._player_pressed_go_button[1],
		"absent player shown, not skipped yet %s" % [absent.describe()]
	)
	session.peers[FAKE_PEER].last_seen_msec = now - absent.ABSENT_MSEC - 1000
	absent.check(now)
	t._check(
		shop._player_pressed_go_button[1] and not shop._player_pressed_go_button[0],
		"Go pressed for the absent player only"
	)
	session.peers[FAKE_PEER].last_seen_msec = now
	absent.check(now)
	t._check(absent.absent.empty(), "back: no longer absent")
	session.peers.erase(FAKE_PEER)
