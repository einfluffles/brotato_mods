extends Node

const MOD_ID := "einfluffles-BrotatoTogether"
const MOD_DIR := "res://mods-unpacked/einfluffles-BrotatoTogether/"
const LOG_NAME := MOD_ID + ":Main"

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")

# Battle over: how long the frozen battle may stay on screen while the next screen loads.
const TRANSITION_GRACE_SEC := 2.0

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
var ui_sounds: Node = null
var pause_control: Node = null
var absent_players: Node = null
var retry_sync: Node = null
var coop_selection: Node = null  # join hints + colour picking on the co-op selection screen

var _client_active := false
var _sound_relay: Script = null
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

	transport = _add("net/steam_transport.gd", "Transport")
	if not transport.setup("%s/p%s" % [MOD_ID, Protocol.VERSION]):
		ModLoaderLog.error("Steam transport unavailable; brotato:together disabled", LOG_NAME)

	session = _add("session/session.gd", "Session")
	session.setup(transport)

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

	ui_sounds = _add("sync/ui_sounds.gd", "UiSounds")
	ui_sounds.setup(session)

	retry_sync = _add("sync/retry_sync.gd", "RetrySync")
	retry_sync.state_stream = state_stream
	retry_sync.setup(session, battle_host, battle_client)

	coop_selection = _add("ui/coop_selection.gd", "CoopSelection")

	_add_player_control()

	var menu: Node = _load_script("ui/together_menu.gd").new()
	menu.name = "TogetherMenu"
	menu.setup(transport, session, battle_host, battle_client)
	menu.absent_players = absent_players
	add_child(menu)
	pause_control.together_menu = menu
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


func _on_peer_ready(steam_id: int) -> void:
	if session.is_client() and steam_id == transport.host_id and not _client_active:
		_client_active = true
		_enter_client_view()


# While the F9 panel owns the keyboard/pad, the host gets neutral input from us.
func _on_menu_open_changed(is_open: bool) -> void:
	input_sync.local_input_blocked = is_open


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


# Host is in a menu (selection screens, end of run, title): show it in the client view. Also
# covers leaving the shop/battle for a menu without a dedicated end message.
func _on_menu_state(state: Dictionary) -> void:
	if not _client_active:
		return
	var current := get_tree().current_scene
	if current == null or current.get_script() != _client_view:
		_enter_client_view()
		current = get_tree().current_scene
	current.show_menu(state)


func _on_lobby_left() -> void:
	CoopService.bt_clear_remote_colors()  # a client goes back to its own colours
	if _client_active:
		_client_active = false
		get_tree().paused = false
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
