extends CanvasLayer
# brotato:together status overlay + dev hotkeys.
# F6 host lobby · F7 Steam invite dialog · F8 leave lobby · F9 toggle overlay

const REFRESH_SEC := 0.25

var transport: Node = null
var session: Node = null
var battle_host: Node = null
var battle_client: Node = null

var _label := Label.new()
var _last_error := ""
var _refresh_left := 0.0


func setup(
	steam_transport: Node, netplay_session: Node, host_battle: Node, client_battle: Node
) -> void:
	transport = steam_transport
	session = netplay_session
	battle_host = host_battle
	battle_client = client_battle
	transport.connect("lobby_failed", self, "_on_lobby_failed")


func _ready() -> void:
	layer = 128
	pause_mode = PAUSE_MODE_PROCESS
	_label.rect_position = Vector2(12, 12)
	_label.add_color_override("font_color", Color(1, 1, 1))
	_label.add_color_override("font_color_shadow", Color(0, 0, 0))
	_label.add_constant_override("shadow_as_outline", 1)
	add_child(_label)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.scancode:
		KEY_F6:
			_last_error = ""
			transport.host_lobby()
		KEY_F7:
			transport.open_invite_dialog()
		KEY_F8:
			transport.leave_lobby()
		KEY_F9:
			_label.visible = not _label.visible


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left > 0.0 or not _label.visible:
		return
	_refresh_left = REFRESH_SEC
	_label.text = _build_text()


func _build_text() -> String:
	var lines := ["[brotato:together]  F6 host · F7 invite · F8 leave · F9 hide"]
	if transport.steam == null:
		lines.append("Steam unavailable")
	elif not transport.is_active():
		lines.append("Not in a lobby")
	else:
		var role := "HOST" if transport.is_host() else "CLIENT"
		lines.append("%s  lobby %s" % [role, transport.lobby_id])
		for steam_id in session.peers:
			var peer: Dictionary = session.peers[steam_id]
			var state := "ready" if peer.ready else "handshake"
			if session.is_peer_stale(steam_id):
				state = "STALE"
			var rtt: String = ("%d ms" % peer.rtt_ms) if peer.rtt_ms >= 0 else "-"
			lines.append("  %s  %s  rtt %s" % [peer.name, state, rtt])
	if battle_host.is_in_battle():
		lines.append(
			(
				"  battle: snapshot %d B @ %d Hz"
				% [battle_host.snapshot_bytes, battle_host.SNAPSHOT_HZ]
			)
		)
	if battle_client.is_in_battle():
		lines.append("  battle: render lag %d ms" % battle_client.interp_lag_msec)
	if _last_error != "":
		lines.append("! " + _last_error)
	return PoolStringArray(lines).join("\n")


func _on_lobby_failed(reason: String) -> void:
	_last_error = reason
