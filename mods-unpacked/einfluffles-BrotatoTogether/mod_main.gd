extends Node

const MOD_ID := "einfluffles-BrotatoTogether"
const MOD_DIR := "res://mods-unpacked/" + MOD_ID + "/"
const LOG_NAME := MOD_ID + ":Main"

const SteamTransport := preload(MOD_DIR + "net/steam_transport.gd")
const Session := preload(MOD_DIR + "session/session.gd")
const Protocol := preload(MOD_DIR + "net/protocol.gd")
const DebugOverlay := preload(MOD_DIR + "ui/debug_overlay.gd")

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
