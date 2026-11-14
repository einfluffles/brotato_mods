extends Node

const MOD_ID := "einfluffles-BrotatoTogether"
const LOG_NAME := MOD_ID + ":Main"

const SteamTransport := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/steam_transport.gd")
const Session := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/session.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const DebugOverlay := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/debug_overlay.gd")

var transport: Node = null
var session: Node = null


func _init() -> void:
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

	var overlay := DebugOverlay.new()
	overlay.name = "DebugOverlay"
	overlay.setup(transport, session)
	add_child(overlay)

	ModLoaderLog.info("Ready", LOG_NAME)
