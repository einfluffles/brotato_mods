extends CanvasLayer
# brotato:together menu. One hotkey (F9) so we never collide with the game's own keys
# (F8 = bug report; F2/F7 in dev builds) or Steam's (Shift+Tab, F12).
#  - status pill, bottom-centre: the only HUD spot the co-op player panels (corners) and the wave
#    timer (top-centre) leave free
#  - F9 panel, centred: connection details + Host / Invite / Leave buttons (mouse)

const TOGGLE_KEY := KEY_F9
const REFRESH_SEC := 0.25
const THEME_PATH := "res://resources/themes/base_theme.tres"
const PILL_FONT_PATH := "res://resources/fonts/actual/base/font_22.tres"

var transport: Node = null
var session: Node = null
var battle_host: Node = null
var battle_client: Node = null
var absent_players: Node = null  # host: players away mid-run (sync/absent_players.gd)

var _pill := PanelContainer.new()
var _pill_label := Label.new()
var _panel := PanelContainer.new()
var _details := Label.new()
var _host_button := Button.new()
var _invite_button := Button.new()
var _leave_button := Button.new()
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
	var root := Control.new()  # full-screen, click-through; carries the game's theme
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(THEME_PATH):
		root.theme = load(THEME_PATH)
	add_child(root)
	_build_pill(root)
	_build_panel(root)
	_panel.visible = false


func _build_pill(root: Control) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.55)
	style.set_corner_radius_all(14)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	_pill.add_stylebox_override("panel", style)
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pill.anchor_left = 0.5
	_pill.anchor_right = 0.5
	_pill.anchor_top = 1.0
	_pill.anchor_bottom = 1.0
	_pill.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_pill.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_pill.margin_bottom = -10
	if ResourceLoader.exists(PILL_FONT_PATH):
		_pill_label.add_font_override("font", load(PILL_FONT_PATH))
	_pill_label.add_color_override("font_color", Color(1, 1, 1, 0.9))
	_pill.add_child(_pill_label)
	root.add_child(_pill)


func _build_panel(root: Control) -> void:
	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.rect_min_size = Vector2(620, 0)
	center.add_child(_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_constant_override("margin_" + side, 24)
	_panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_constant_override("separation", 16)
	margin.add_child(column)

	var title := Label.new()
	title.text = "brotato:together"
	title.align = Label.ALIGN_CENTER
	column.add_child(title)
	_details.autowrap = true
	column.add_child(_details)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGN_CENTER
	buttons.add_constant_override("separation", 12)
	column.add_child(buttons)
	_add_button(buttons, _host_button, "Host lobby", "_on_host_pressed")
	_add_button(buttons, _invite_button, "Invite friends", "_on_invite_pressed")
	_add_button(buttons, _leave_button, "Leave lobby", "_on_leave_pressed")
	_add_button(buttons, Button.new(), "Close", "close")

	var hint := Label.new()
	hint.text = "F9 opens / closes this menu"
	hint.align = Label.ALIGN_CENTER
	hint.modulate = Color(1, 1, 1, 0.6)
	column.add_child(hint)


func _add_button(parent: Node, button: Button, text: String, method: String) -> void:
	button.text = text
	# No keyboard/gamepad focus: the game's own focus navigation must never land on these.
	button.focus_mode = Control.FOCUS_NONE
	button.connect("pressed", self, method)
	parent.add_child(button)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.scancode == TOGGLE_KEY:
		get_tree().set_input_as_handled()
		if _panel.visible:
			close()
		else:
			open()


func open() -> void:
	_panel.visible = true
	_refresh()


func close() -> void:
	_panel.visible = false
	_refresh()


func is_open() -> bool:
	return _panel.visible


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh()


func _refresh() -> void:
	_refresh_left = REFRESH_SEC
	var active: bool = transport.steam != null and transport.is_active()
	_pill_label.text = pill_text()
	# Out of a lobby the pill is just a hint — keep it out of the way during a solo battle.
	_pill.visible = not _panel.visible and (active or not _in_battle())
	if not _panel.visible:
		return
	_details.text = details_text()
	_host_button.disabled = transport.steam == null or active
	_invite_button.disabled = not active
	_leave_button.disabled = not active


func pill_text() -> String:
	if transport.steam == null or not transport.is_active():
		return "brotato:together · F9"
	var role := "Host" if transport.is_host() else "Client"
	var players: int = session.peers.size() + 1
	var text := "brotato:together · %s · %d players" % [role, players]
	var worst_rtt := -1
	var stale := false
	for steam_id in session.peers:
		worst_rtt = int(max(worst_rtt, session.peers[steam_id].rtt_ms))
		stale = stale or session.is_peer_stale(steam_id)
	if absent_players != null and not absent_players.absent.empty():
		text += " · %d away" % absent_players.absent.size()
	elif stale:
		text += " · connection lost?"
	elif worst_rtt >= 0:
		text += " · %d ms" % worst_rtt
	return text + " · F9"


func details_text() -> String:
	var lines := []
	if transport.steam == null:
		lines.append("Steam is unavailable — online play needs the Steam version of the game.")
	elif not transport.is_active():
		lines.append("Not in a lobby. Host one, then invite friends via Steam.")
	else:
		var role := "Hosting" if transport.is_host() else "Connected as client"
		lines.append("%s · lobby %s" % [role, transport.lobby_id])
		for steam_id in session.peers:
			var peer: Dictionary = session.peers[steam_id]
			var state := "ready" if peer.ready else "connecting"
			if session.is_peer_stale(steam_id):
				state = "no response"
			var rtt: String = ("%d ms" % peer.rtt_ms) if peer.rtt_ms >= 0 else "-"
			lines.append("  %s — %s — %s" % [peer.name, state, rtt])
	if absent_players != null:
		lines += absent_players.describe()
	if battle_host.is_in_battle():
		lines.append(
			"Battle: %d B snapshots at %d Hz" % [battle_host.snapshot_bytes, battle_host.SNAPSHOT_HZ]
		)
	if battle_client.is_in_battle():
		lines.append("Battle: render lag %d ms" % battle_client.interp_lag_msec)
	if _last_error != "":
		lines.append("! " + _last_error)
	return PoolStringArray(lines).join("\n")


func _in_battle() -> bool:
	return battle_host.is_in_battle() or battle_client.is_in_battle() or _scene_is_main()


func _scene_is_main() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.filename == "res://main.tscn"


func _on_host_pressed() -> void:
	_last_error = ""
	transport.host_lobby()
	_refresh()


func _on_invite_pressed() -> void:
	transport.open_invite_dialog()


func _on_leave_pressed() -> void:
	transport.leave_lobby()
	_refresh()


func _on_lobby_failed(reason: String) -> void:
	_last_error = reason
	open()  # errors (host left, connection lost) should be seen, not hidden in a closed panel
