extends Node

const MOD_ID := "einfluffles-BrotatoTogether"
const MOD_DIR := "res://mods-unpacked/einfluffles-BrotatoTogether/"
const LOG_NAME := MOD_ID + ":Main"

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")

# Battle over: how long the frozen battle may stay on screen while the next screen loads.
const TRANSITION_GRACE_SEC := 2.0
const TITLE_KIND := "title_screen"  # MenuSync.kind_of the title screen and its pages

const EXTENSIONS := [
	"extensions/singletons/input_service.gd",
	"extensions/singletons/coop_service.gd",
	"extensions/singletons/progress_data.gd",
	"extensions/singletons/challenge_service.gd",
	"extensions/singletons/sound_manager.gd",
	"extensions/singletons/sound_manager_2d.gd",
	"extensions/singletons/utils.gd",
	"extensions/entities/brachiosaurus_foot.gd",
	"extensions/entities/stay_edges_of_map_movement_behavior.gd",
	"extensions/ui/shop_item.gd",
	"extensions/ui/pause_menu.gd",
	"extensions/ui/menu_options.gd",
	"extensions/ui/focus_emulator.gd",
	"extensions/ui/character_selection.gd",
	"extensions/ui/weapon_selection.gd",
	"extensions/ui/difficulty_selection.gd",
]

var transport: Node = null
var session: Node = null
var state_stream: Node = null  # host state to clients in ordered sections (sync/state_stream.gd)
var input_sync: Node = null
var battle_host: Node = null
var battle_client: Node = null
var focus_sync: Node = null
var shop_sync: Node = null
var upgrades_sync: Node = null
var menu_sync: Node = null
var menu_puppet: Node = null  # client: the host's menus as the game's own scenes
var ui_sounds: Node = null
var pause_control: Node = null
var absent_players: Node = null
var retry_sync: Node = null
var pickup_list: Node = null  # the HUD's picked-up crates on clients (sync/pickup_list.gd)
var progress_share: Node = null  # what the host's run earns for the clients' own saves
var damage_meter: Node = null  # what each player's weapons and items dealt (sync/damage_meter.gd)
var coop_selection: Node = null  # join hints + colour picking on the co-op selection screen

var _client_active := false
# Client: the host is in its main menu, so this game is in its own, as itself (see
# _enter_own_menus).
var _own_menus := false
var _popup_open := false
var _sound_relay: Script = null
var _puppet: Script = null
var _client_view: Script = null


func _init() -> void:
	for extension in EXTENSIONS:
		ModLoaderMod.install_script_extension(MOD_DIR + extension)
	ModLoaderLog.info("Init", LOG_NAME)


# The mod's scripts are loaded here, never preloaded by this file. A preload compiles them when
# the mod is initialised, before any mod's script extensions are installed, and compiling them
# loads the game classes they name (Unit, BrachiosaurusFoot, ...). When another mod then extends
# such a class (Damage Meter extends enemy.gd), the Mod Loader reloads its child classes, and
# the game's own scripts no longer parse against the copies loaded early ('A value of type
# "Unit" will never be an instance of "boss.gd"'): four autoloads fail and the game crashes on
# the loading screen. _ready runs after all extensions are installed.
func _ready() -> void:
	# Keep networking alive while the tree is paused (pause menu).
	pause_mode = PAUSE_MODE_PROCESS
	_sound_relay = _load_script("session/sound_relay.gd")
	_client_view = _load_script("ui/client_view.gd")
	_puppet = _load_script("session/puppet.gd")

	transport = _add("net/steam_transport.gd", "Transport")
	if not transport.setup("%s/p%s" % [MOD_ID, Protocol.VERSION]):
		ModLoaderLog.error("Steam transport unavailable; brotato:together disabled", LOG_NAME)

	session = _add("session/session.gd", "Session")
	session.setup(transport)
	session.connect("host_message", self, "_on_host_message")

	# Before the sync modules, which get it ahead of their setup() (they register sections there)
	# and process after it in a frame. Its peer_ready resync waits for its next step, so whatever
	# the modules send from their own peer_ready goes out first (state_stream.gd header).
	state_stream = _add("sync/state_stream.gd", "StateStream")
	state_stream.setup(session)

	input_sync = _add("sync/input_sync.gd", "InputSync")
	input_sync.setup(session)

	battle_host = _add("sync/battle_host.gd", "BattleHost")
	battle_host.state_stream = state_stream
	battle_host.setup(session, input_sync)

	battle_client = _add("sync/battle_client.gd", "BattleClient")
	battle_client.state_stream = state_stream
	battle_client.setup(session, input_sync)

	focus_sync = _add("sync/focus_sync.gd", "FocusSync")
	focus_sync.state_stream = state_stream
	focus_sync.setup(session)

	shop_sync = _add("sync/shop_sync.gd", "ShopSync")
	shop_sync.state_stream = state_stream
	shop_sync.setup(session)
	shop_sync.input_sync = input_sync
	shop_sync.focus_sync = focus_sync

	upgrades_sync = _add("sync/upgrades_sync.gd", "UpgradesSync")
	upgrades_sync.state_stream = state_stream
	upgrades_sync.setup(session, battle_host, battle_client)
	upgrades_sync.focus_sync = focus_sync
	upgrades_sync.input_sync = input_sync

	menu_sync = _add("sync/menu_sync.gd", "MenuSync")
	menu_sync.state_stream = state_stream
	menu_sync.setup(session, battle_host)
	menu_sync.connect("menu_state", self, "_on_menu_state")
	menu_puppet = _add("sync/menu_puppet.gd", "MenuPuppet")
	menu_puppet.state_stream = state_stream
	menu_puppet.setup(session)
	input_sync.menu_puppet = menu_puppet

	ui_sounds = _add("sync/ui_sounds.gd", "UiSounds")
	ui_sounds.setup(session)

	retry_sync = _add("sync/retry_sync.gd", "RetrySync")
	retry_sync.state_stream = state_stream
	retry_sync.setup(session, battle_host, battle_client)

	pickup_list = _add("sync/pickup_list.gd", "PickupList")
	pickup_list.state_stream = state_stream
	pickup_list.setup(battle_host, battle_client)

	progress_share = _add("session/progress_share.gd", "ProgressShare")
	progress_share.setup(session)

	damage_meter = _add("sync/damage_meter.gd", "DamageMeter")
	damage_meter.state_stream = state_stream
	damage_meter.setup(session)
	var damage_views: Node = _load_script("ui/damage_views.gd").new()
	damage_views.name = "DamageViews"
	damage_views.meter = damage_meter
	add_child(damage_views)

	coop_selection = _add("ui/coop_selection.gd", "CoopSelection")

	_add_player_control()

	var menu: Node = _load_script("ui/lobby_menu.gd").new()
	menu.name = "LobbyMenu"
	menu.setup(transport, session, battle_host, battle_client)
	menu.absent_players = absent_players
	menu.pause_control = pause_control
	add_child(menu)
	pause_control.lobby_menu = menu
	menu.connect("open_changed", self, "_on_menu_open_changed")

	session.connect("peer_ready", self, "_on_peer_ready")
	battle_client.connect("battle_left", self, "_on_client_battle_left")
	transport.connect("lobby_left", self, "_on_lobby_left")
	ModLoaderLog.info("Ready", LOG_NAME)


func _load_script(path: String) -> Script:
	return load(MOD_DIR + path) as Script


func _add(path: String, node_name: String) -> Node:
	var node: Node = _load_script(path).new()
	node.name = node_name
	add_child(node)
	return node


# Pause ownership, absent players, client aim (needs the client's own player).
func _add_player_control() -> void:
	input_sync.battle_client = battle_client
	pause_control = _add("sync/pause_control.gd", "PauseControl")
	pause_control.state_stream = state_stream
	pause_control.setup(session, input_sync)
	pause_control.battle_client = battle_client
	battle_host.pause_control = pause_control
	absent_players = _add("sync/absent_players.gd", "AbsentPlayers")
	absent_players.setup(session, input_sync, battle_host)


# A client that joins from its main menu stays there until the host's state says where the host
# is (its own main menu: _enter_own_menus; a screen: that screen).
func _on_peer_ready(steam_id: int) -> void:
	if session.is_client() and steam_id == transport.host_id and not _client_active:
		_client_active = true
		if not _on_title_screen():
			_enter_client_view()


func _on_title_screen() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.filename == MenuData.title_screen_scene


func _on_menu_open_changed(is_open: bool) -> void:
	_popup_open = is_open
	_apply_own_input()


# While the lobby popup or the client's own menus have the keyboard/pad, the host gets neutral
# input from us (and the game's own input handling is the solo one: InputSync's client mode).
# The host's menu sounds are not ours to hear in our own menus.
func _apply_own_input() -> void:
	input_sync.local_input_blocked = _popup_open or _own_menus
	ui_sounds.silent = _own_menus


# The host is in its main menu: nothing to mirror and nothing to wait in front of, so the client
# is in its own main menu and can use it (ui/lobby_menu.gd keeps Start and Continue off). It is
# this machine's game meanwhile: its own run data and saves (puppet mode off) and its own DLC
# only (the host's is handed back until the host's next screen, _on_host_message).
func _enter_own_menus() -> void:
	if not _own_menus:
		_own_menus = true
		_apply_own_input()
		menu_puppet.release(true)
		_puppet.set_active(false)
		session.set_borrow_parked(true)
	if _on_title_screen():
		return
	get_tree().paused = false
	_sound_relay.set_muted(false)
	if get_tree().change_scene(MenuData.title_screen_scene) != OK:
		ModLoaderLog.error("Could not load the title screen", LOG_NAME)


# Before anybody reads a message of the host (Session.host_message): the first one from a
# screen of the host ends the client's time in its own menus, and the host's DLC is back
# before that message's run state or grids are decoded.
func _on_host_message(msg_type: int, body) -> void:
	if not _own_menus or not _is_host_screen(msg_type, body):
		return
	_own_menus = false
	_apply_own_input()
	session.set_borrow_parked(false)


# Anything but the state of the host's main menu and the sections that name no content.
func _is_host_screen(msg_type: int, body) -> bool:
	if msg_type == Protocol.Msg.BATTLE_START:
		return true
	if msg_type != Protocol.Msg.STATE or typeof(body) != TYPE_ARRAY or body.size() != 3:
		return false
	var state = body[2]
	if state == null:
		return false
	if body[0] == state_stream.MENU:
		return typeof(state) != TYPE_DICTIONARY or state.get("kind") != TITLE_KIND
	return not body[0] in [state_stream.MENU_GRIDS, state_stream.CURSORS]


# The next screen (shop, next battle, end-of-run menu) follows BATTLE_END closely and replaces
# the scene itself: keep the frozen battle (muted) until then instead of flashing the client
# view; fall back to the view if nothing replaces it in time.
func _on_client_battle_left() -> void:
	if not _client_active:
		return
	var stale := get_tree().current_scene
	if stale == null or not stale.is_inside_tree():
		return  # the next screen is replacing the battle right now
	_sound_relay.set_muted(true)
	var stale_id := stale.get_instance_id()
	get_tree().create_timer(TRANSITION_GRACE_SEC, true).connect(
		"timeout", self, "_on_transition_grace_over", [stale_id]
	)


func _on_transition_grace_over(stale_id: int) -> void:
	var current := get_tree().current_scene
	if _client_active and (current == null or current.get_instance_id() == stale_id):
		_enter_client_view()


# Host is in a menu: in its main menu (and its pages) the client is in its own; its selection
# screens and the end of run are the game's own scenes here too (sync/menu_puppet.gd); anything
# else is the waiting screen.
# Also covers leaving the shop/battle for a menu without a dedicated end message.
func _on_menu_state(state: Dictionary) -> void:
	if not _client_active:
		return
	if state.kind == TITLE_KIND:
		_enter_own_menus()
		return
	if menu_puppet.show(state):
		return
	var current := get_tree().current_scene
	if current == null or current.get_script() != _client_view:
		_enter_client_view()
		current = get_tree().current_scene
	current.show_menu(state)


func _on_lobby_left() -> void:
	CoopService.bt_clear_remote_colors()  # a client goes back to its own colours
	_own_menus = false
	_apply_own_input()
	if _client_active:
		_client_active = false
		get_tree().paused = false
		if _on_title_screen():
			return  # already in its own main menu
		if get_tree().change_scene(MenuData.title_screen_scene) != OK:
			ModLoaderLog.error("Could not return to the title screen", LOG_NAME)


# Manual scene swap (no PackedScene needed): the view becomes current_scene, so the game's own
# change_scene() calls later free it normally.
func _enter_client_view() -> void:
	var tree := get_tree()
	tree.paused = false
	_sound_relay.set_muted(false)  # the view isn't mirrored: its own sounds are fine
	var previous := tree.current_scene
	var view: Node = _client_view.new()
	view.name = "BrotatoTogetherClientView"
	view.session = session
	# Out of the tree first, like change_scene does: what is left of a battle (a death animation
	# returning its puppet to the pool) must not run with the view as the current scene.
	if previous != null:
		previous.get_parent().remove_child(previous)
		previous.queue_free()
	tree.root.add_child(view)
	tree.current_scene = view
