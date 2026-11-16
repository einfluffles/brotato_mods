extends Node
# Who may pause, who operates the pause menu, and when the menu does not pause at all.
# Wave of an online session (host with a peer, or client): the menu is live
#   (extensions/ui/pause_menu.gd), the game runs on behind it.
#   Host: opened by a local player's pause as always; that player's character stands still
#   meanwhile. Remote pause presses never arrive during a battle scene.
#   Client: its own pause opens the puppet scene's menu for its own slot; its buttons stay
#   here, the host gets neutral input. Restart / end run are the host's, Quit asks to leave
#   (on the menu's lobby page, ui/lobby_menu.gd).
#   The menu closes when the wave ends: the level-up panels need the same buttons.
# Everything else is a real pause. Level-up panels: the host's local players only. Shop: any
#   player; when that is a remote player, the menu goes to the host's first local player (the
#   game's own "change pause ownership" steps from PauseMenu.on_game_lost_focus), since the
#   remote player can't see it and must not quit or restart blind. The remote player who paused
#   resumes with pause again (while the menu shows its main page). Clients learn who paused
#   (section PAUSE_BATTLE via BattleHost; in the shop, section PAUSE_SHOP provided here and
#   handled by ShopSync).
# Client: puppet scenes never pause locally (focus loss, pad disconnect, pause button).

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:PauseControl"
const SHOP_SCENE := "res://ui/menus/shop/coop_shop.tscn"
const BATTLE_SCENE := "res://main.tscn"
const REMOTE_PRESS_WINDOW_MSEC := 1000  # a remote pause press this recent caused the pause
const BLOCK_KEY := "battle"  # InputSync.blocked_by
const CLIENT_MENU_META := "brotato_together_client_menu"
const BANNER_NAME := "BrotatoTogetherPauseBanner"
const HOST_ONLY_BUTTONS := ["%RestartButton", "%EndRunButton"]

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var input_sync: Node = null
var battle_client: Node = null
var lobby_menu: Node = null  # ui/lobby_menu.gd; client: Quit asks there

# host
var _menu: Node = null  # PauseMenu that is open
var _pauser_device := -1  # virtual device that paused (-1: the host or nobody)
var _paused_frame := -1  # the shop pauses on the release event that is still propagating
var _held_behavior: Node = null  # movement of the live menu's owner, parked on the idle device
var _held_device := -1
var _scene_id := 0  # instance id of the scene whose pause menu is watched

# client
var _pause_armed := false  # own pause went down while the buttons were the game's


func setup(netplay_session: Node, remote_input: Node) -> void:
	session = netplay_session
	input_sync = remote_input
	state_stream.register_provider(StateStream.PAUSE_SHOP, self)


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


# Client: called when a puppet battle / shop scene is ready.
static func disable_local_pause(scene: Node) -> void:
	var menu = scene.get("_pause_menu")
	if menu != null:
		menu.enabled = false
	if InputService.is_connected("game_lost_focus", scene, "_on_game_lost_focus"):
		InputService.disconnect("game_lost_focus", scene, "_on_game_lost_focus")


static func banner_text(by: String, by_id: int, local_id: int) -> String:
	if by_id != 0 and by_id == local_id:
		return "Paused by you · press pause to resume"
	return "Paused by %s" % (by if by != "" else "the host")


# The banner lives in the scene it covers and is found there by name: nothing to keep here.
static func show_banner(parent: Node, visible: bool, text: String) -> void:
	var banner = parent.get_node_or_null(BANNER_NAME)
	if banner == null:
		if not visible:
			return
		banner = make_banner(parent)
	banner.get_node("Label").text = text
	banner.visible = visible


static func make_banner(parent: Node) -> CanvasLayer:
	var banner := CanvasLayer.new()
	banner.name = BANNER_NAME
	banner.layer = 100
	var label := Label.new()
	label.name = "Label"
	label.align = Label.ALIGN_CENTER
	label.valign = Label.VALIGN_CENTER
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	banner.add_child(label)
	parent.add_child(banner)
	return banner


# --- host ---


# [name, steam id] of whoever paused; ["", 0] for the host.
func paused_by() -> Array:
	if _pauser_device < 0:
		return ["", 0]
	for steam_id in input_sync.devices:
		if input_sync.devices[steam_id] == _pauser_device:
			var peer = session.peers.get(steam_id)
			return [peer.name if peer != null else "a player", steam_id]
	return ["a player", 0]


# The battle scene and the shop each have one pause menu. Looked up when the scene changes:
# a node_added handler would run for every spawn of every wave, also in solo play.
func _watch_scene(scene: Node) -> void:
	var scene_id := scene.get_instance_id() if scene != null else 0
	if scene_id == _scene_id:
		return
	_scene_id = scene_id
	_menu = null
	_pauser_device = -1
	_held_behavior = null  # freed with its scene
	if session.is_host():
		release_stale_pause(scene)
	var menu = scene.get("_pause_menu") if scene != null else null
	if menu is PauseMenu and not menu.is_connected("paused", self, "_on_menu_paused"):
		menu.connect("paused", self, "_on_menu_paused", [menu])
		menu.connect("unpaused", self, "_on_menu_unpaused")


# Host: a shop that starts with the tree still paused while its own pause menu is closed (the
# battle's menu was open when the scene changed). Nobody could use it, and its pause state would
# keep every client's own panel off until the host paused and resumed. Returns whether it
# resumed. (UpgradesSync holds the level-up intents of a pause, the known way in.)
func release_stale_pause(scene: Node) -> bool:
	if scene == null or scene.filename != SHOP_SCENE or not get_tree().paused:
		return false
	var menu = scene.get("_pause_menu")
	if menu == null or menu.visible:
		return false
	ModLoaderLog.warning("The shop started paused with its pause menu closed: resumed", LOG_NAME)
	get_tree().paused = false
	return true


func _on_menu_paused(menu: Node) -> void:
	if session.is_host():
		handle_pause(menu)
	state_stream.flush(StateStream.PAUSE_SHOP)  # the banner in the next frame, not at the check


func _on_menu_unpaused() -> void:
	_menu = null
	_pauser_device = -1
	state_stream.flush(StateStream.PAUSE_SHOP)


# PauseMenu.pause() emits "paused" before it sets the menu up for the pausing player, so the
# hand-over runs deferred.
func handle_pause(menu: Node) -> void:
	_menu = menu
	_pauser_device = -1
	_paused_frame = Engine.get_idle_frames()
	var device: int = CoopService.get_remapped_player_device(menu._player_index)
	if not VirtualDevices.is_virtual(device):
		return
	# Player 0 can be remote: focus loss on the host always opens the menu for player 0.
	var pressed_at: int = input_sync.last_pause_msec(device)
	if pressed_at >= 0 and OS.get_ticks_msec() - pressed_at < REMOTE_PRESS_WINDOW_MSEC:
		_pauser_device = device
	var owner: int = local_player_index()
	if owner >= 0:
		call_deferred("_give_menu_to", menu, owner)


static func local_player_index() -> int:
	for i in CoopService.connected_players.size():
		if not VirtualDevices.is_virtual(CoopService.connected_players[i][0]):
			return i
	return -1


func _give_menu_to(menu: Node, owner: int) -> void:
	if not is_instance_valid(menu) or not get_tree().paused:
		return
	menu._player_index = owner
	menu._focus_emulator.player_index = owner
	menu._menus.reset()
	menu._main_menu.init(owner)


# The remote player who paused resumes with its pause button (released, like the game).
func _input(event: InputEvent) -> void:
	if _pauser_device < 0 or not (event is InputEventAction) or event.pressed:
		return
	if event.action != VirtualDevices.action("ui_pause", _pauser_device):
		return
	if _pauser_may_resume():
		get_tree().set_input_as_handled()
		_resume_for_pauser()


# The menu's FocusEmulator (the host's local player by now) eats the events of every other
# player's device before _input above runs, unless the game is listening for joining players
# (it is not in the shop). The release still reaches the action state, so it is polled too.
func _poll_pauser_release() -> void:
	if _pauser_device < 0 or not _pauser_may_resume():
		return
	if Input.is_action_just_released(VirtualDevices.action("ui_pause", _pauser_device)):
		_resume_for_pauser()


func _pauser_may_resume() -> bool:
	if not is_instance_valid(_menu) or not get_tree().paused:
		return false
	return Engine.get_idle_frames() != _paused_frame


func _resume_for_pauser() -> void:
	if _menu._main_menu.visible and not _menu.codex_is_opened:
		_menu.unpause()


func _process(_delta: float) -> void:
	_poll_pauser_release()
	_watch_scene(get_tree().current_scene)
	_update_live_menu()


# State stream provider, section PAUSE_SHOP: [paused, by (name), by_id (steam id, 0: the host)]
# while the host is in the shop (like PAUSE_BATTLE); inactive elsewhere. Handled by ShopSync.
func state_key(_section: int) -> String:
	var scene := get_tree().current_scene
	if scene == null or scene.filename != SHOP_SCENE:
		return ""
	return var2str(_shop_pause_state())


func state_body(_section: int) -> Array:
	return _shop_pause_state()


func _shop_pause_state() -> Array:
	var by := paused_by()
	return [get_tree().paused, by[0], by[1]]


# --- live menu ---


func _update_live_menu() -> void:
	var scene := get_tree().current_scene
	var main: Node = scene if scene != null and scene.filename == BATTLE_SCENE else null
	if main != null and session.is_host():
		host_update(main)
		return
	input_sync.blocked_by.erase(BLOCK_KEY)
	_hold_player(null)
	if main != null and is_client_battle(main):
		client_update(main, battle_client._you)
		return
	input_sync.set_local_menu(-1)
	_pause_armed = false
	# No session any more, or a client's battle that is over and still on screen.
	var menu = main.get("_pause_menu") if main != null else null
	if menu != null and menu.live:
		menu.live = false
		if menu.live_open:
			menu.unpause()


func is_client_battle(main: Node) -> bool:
	return (
		session.is_client()
		and battle_client != null
		and battle_client.is_in_battle()
		and battle_client._main == main
	)


# Host, every frame of a battle scene.
func host_update(main: Node) -> void:
	input_sync.blocked_by[BLOCK_KEY] = 1 << VirtualDevices.PAUSE_INDEX
	var menu = main.get("_pause_menu")
	if menu == null:
		return
	var wave_on: bool = not main._end_wave_timer_timedout
	menu.live = wave_on and not session.peers.empty()
	if menu.live_open and not wave_on:
		menu.unpause()
	_hold_player(main._players[menu._live_owner] if menu.live_open else null)


# The menu owner's buttons and stick move its cursor: its character reads a device nobody
# presses meanwhile. Weapons go on aiming and firing by themselves.
func _hold_player(player) -> void:
	var behavior = null
	if player != null and is_instance_valid(player):
		behavior = player._movement_behavior
	if behavior == _held_behavior:
		return
	if is_instance_valid(_held_behavior):
		_held_behavior.device = _held_device
	_held_behavior = behavior
	if behavior != null:
		_held_device = behavior.device
		behavior.device = VirtualDevices.IDLE


# Client, every frame of its puppet battle. you: its player slot (-1: spectator, no menu).
func client_update(main: Node, you: int) -> void:
	var menu = main.get("_pause_menu")
	if menu == null:
		return
	_prepare_client_menu(menu)
	var wave_on := you >= 0
	for ui_name in ["_coop_upgrades_ui", "_retry_wave"]:
		var ui = main.get(ui_name)
		wave_on = wave_on and not (ui != null and ui.visible)
	menu.live = wave_on
	if menu.live_open and not wave_on:
		menu.unpause()
	# Released like the game's own check, but only after a press that was the game's: the lobby
	# popup releases the actions of the keys it takes.
	var blocked: bool = input_sync.local_input_blocked
	if Input.is_action_just_pressed("ui_pause"):
		_pause_armed = not blocked
	elif Input.is_action_just_released("ui_pause"):
		if _pause_armed and not blocked:
			toggle_client_menu(menu, you)
		_pause_armed = false
	var device: int = CoopService.get_remapped_player_device(you) if menu.live_open else -1
	input_sync.set_local_menu(device)


func toggle_client_menu(menu: Node, you: int) -> void:
	if menu.live_open:
		menu.pause(you)
	elif menu.live:
		menu.open_live(you)


# Once per puppet battle: what only the host may decide is off, Quit means leaving the lobby.
func _prepare_client_menu(menu: Node) -> void:
	if menu.has_meta(CLIENT_MENU_META):
		return
	menu.set_meta(CLIENT_MENU_META, true)
	var main_menu = menu._main_menu
	for path in HOST_ONLY_BUTTONS:
		var button = main_menu.get_node_or_null(path)
		if button is BaseButton:
			button.disabled = true
	if main_menu.is_connected("quit_button_pressed", menu._menus, "on_quit_button_pressed"):
		main_menu.disconnect("quit_button_pressed", menu._menus, "on_quit_button_pressed")
	main_menu.connect("quit_button_pressed", self, "_on_client_quit", [menu])


# The lobby page of this menu, with its question.
func _on_client_quit(_menu: Node) -> void:
	if lobby_menu != null:
		lobby_menu.ask_leave()


# The current scene's pause menu, opened for this machine's player if it is closed (live during
# an online wave, a pause otherwise); null if there is none or it does not open.
func open_menu() -> Node:
	var scene := get_tree().current_scene
	var menu = scene.get("_pause_menu") if scene != null else null
	if not (menu is PauseMenu):
		return null
	if not menu.visible:
		if not session.is_client():
			menu.pause(int(max(local_player_index(), 0)))
		elif menu.live and is_client_battle(scene) and battle_client._you >= 0:
			menu.open_live(battle_client._you)
	return menu if menu.visible else null
