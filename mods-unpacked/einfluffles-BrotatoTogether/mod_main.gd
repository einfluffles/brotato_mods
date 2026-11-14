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
const DebugOverlay := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/debug_overlay.gd")
const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")

const EXTENSIONS := [
	"extensions/singletons/input_service.gd",
	"extensions/singletons/coop_service.gd",
	"extensions/singletons/progress_data.gd",
	"extensions/singletons/challenge_service.gd",
]

var transport: Node = null
var session: Node = null
var input_sync: Node = null

var _in_client_view := false


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

	var overlay := DebugOverlay.new()
	overlay.name = "DebugOverlay"
	overlay.setup(transport, session)
	add_child(overlay)

	session.connect("peer_ready", self, "_on_peer_ready")
	transport.connect("lobby_left", self, "_on_lobby_left")
	ModLoaderLog.info("Ready", LOG_NAME)


func _on_peer_ready(steam_id: int) -> void:
	if session.is_client() and steam_id == transport.host_id and not _in_client_view:
		_enter_client_view()


func _on_lobby_left() -> void:
	if _in_client_view:
		_in_client_view = false
		get_tree().paused = false
		if get_tree().change_scene(MenuData.title_screen_scene) != OK:
			ModLoaderLog.error("Could not return to the title screen", LOG_NAME)


# Manual scene swap (no PackedScene needed): the view becomes current_scene, so the game's own
# change_scene() calls later free it normally.
func _enter_client_view() -> void:
	_in_client_view = true
	var tree := get_tree()
	tree.paused = false
	var previous := tree.current_scene
	var view := ClientView.new()
	view.name = "BrotatoTogetherClientView"
	view.session = session
	tree.root.add_child(view)
	tree.current_scene = view
	if previous != null:
		previous.queue_free()
