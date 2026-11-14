extends Node

const MOD_ID := "einfluffles-BrotatoTogether"
const MOD_DIR := "res://mods-unpacked/einfluffles-BrotatoTogether/"
const LOG_NAME := MOD_ID + ":Main"

const SteamTransport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/net/steam_transport.gd"
)
const Session := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/session.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const InputSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/input_sync.gd")
const BattleHost := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_host.gd")
const BattleClient := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_client.gd"
)
const FocusSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/focus_sync.gd")
const ShopSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_sync.gd")
const UpgradesSync := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/upgrades_sync.gd"
)
const MenuSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/menu_sync.gd")
const UiSounds := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/ui_sounds.gd")
const RetrySync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/retry_sync.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const TogetherMenu := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/together_menu.gd")
const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")

# Battle over: how long the frozen battle may stay on screen while the next screen loads.
const TRANSITION_GRACE_SEC := 2.0

const EXTENSIONS := [
	"extensions/singletons/input_service.gd",
	"extensions/singletons/coop_service.gd",
	"extensions/singletons/progress_data.gd",
	"extensions/singletons/challenge_service.gd",
	"extensions/singletons/sound_manager.gd",
	"extensions/singletons/sound_manager_2d.gd",
]

var transport: Node = null
var session: Node = null
var input_sync: Node = null
var battle_host: Node = null
var battle_client: Node = null
var focus_sync: Node = null
var shop_sync: Node = null
var upgrades_sync: Node = null
var menu_sync: Node = null
var ui_sounds: Node = null
var retry_sync: Node = null

var _client_active := false


func _init() -> void:
	for extension in EXTENSIONS:
		ModLoaderMod.install_script_extension(MOD_DIR + extension)
	ModLoaderLog.info("Init", LOG_NAME)


func _ready() -> void:
	# Keep networking alive while the tree is paused (pause menu).
	pause_mode = PAUSE_MODE_PROCESS

	transport = SteamTransport.new()
	transport.name = "Transport"
	add_child(transport)
	if not transport.setup("%s/p%s" % [MOD_ID, Protocol.VERSION]):
		ModLoaderLog.error("Steam transport unavailable; brotato:together disabled", LOG_NAME)

	session = Session.new()
	session.name = "Session"
	add_child(session)
	session.setup(transport)

	input_sync = InputSync.new()
	input_sync.name = "InputSync"
	add_child(input_sync)
	input_sync.setup(session)

	battle_host = BattleHost.new()
	battle_host.name = "BattleHost"
	add_child(battle_host)
	battle_host.setup(session, input_sync)

	battle_client = BattleClient.new()
	battle_client.name = "BattleClient"
	add_child(battle_client)
	battle_client.setup(session, input_sync)

	focus_sync = FocusSync.new()
	focus_sync.name = "FocusSync"
	add_child(focus_sync)
	focus_sync.setup(session)

	shop_sync = ShopSync.new()
	shop_sync.name = "ShopSync"
	add_child(shop_sync)
	shop_sync.setup(session)

	upgrades_sync = UpgradesSync.new()
	upgrades_sync.name = "UpgradesSync"
	add_child(upgrades_sync)
	upgrades_sync.setup(session, battle_host, battle_client)

	menu_sync = MenuSync.new()
	menu_sync.name = "MenuSync"
	add_child(menu_sync)
	menu_sync.setup(session, battle_host)
	menu_sync.connect("menu_state", self, "_on_menu_state")

	ui_sounds = UiSounds.new()
	ui_sounds.name = "UiSounds"
	add_child(ui_sounds)
	ui_sounds.setup(session)

	retry_sync = RetrySync.new()
	retry_sync.name = "RetrySync"
	add_child(retry_sync)
	retry_sync.setup(session, battle_host, battle_client)

	var menu := TogetherMenu.new()
	menu.name = "TogetherMenu"
	menu.setup(transport, session, battle_host, battle_client)
	add_child(menu)
	menu.connect("open_changed", self, "_on_menu_open_changed")

	session.connect("peer_ready", self, "_on_peer_ready")
	battle_client.connect("battle_left", self, "_on_client_battle_left")
	transport.connect("lobby_left", self, "_on_lobby_left")
	ModLoaderLog.info("Ready", LOG_NAME)


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
	SoundRelay.set_muted(true)
	var stale := get_tree().current_scene
	var stale_id := stale.get_instance_id() if stale != null else 0
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
	if current == null or current.get_script() != ClientView:
		_enter_client_view()
		current = get_tree().current_scene
	current.show_menu(state)


func _on_lobby_left() -> void:
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
	SoundRelay.set_muted(false)  # the view isn't mirrored: its own sounds are fine
	var previous := tree.current_scene
	var view := ClientView.new()
	view.name = "BrotatoTogetherClientView"
	view.session = session
	tree.root.add_child(view)
	tree.current_scene = view
	if previous != null:
		previous.queue_free()
