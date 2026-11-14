extends Node
# Menus outside battle and shop (character/weapon/difficulty selection, end of run, title...).
# Their grids depend on each machine's own unlocks/DLC, so instead of running them on the client
# we mirror *what* each player has under their cursor (by item id) and whether they're ready;
# the client shows the game's own item cards for that (ui/client_view.gd).

signal menu_state(state)

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const MIRRORED_ELSEWHERE := ["res://main.tscn", "res://ui/menus/shop/coop_shop.tscn"]
const CHECK_INTERVAL := 0.1

var session: Node = null
var battle_host: Node = null  # for the SteamID -> player slot mapping

var _scene: Node = null
var _emulators := []
var _last_sent := {}  # steam id -> key
var _check_left := 0.0


func setup(netplay_session: Node, host_battle: Node) -> void:
	session = netplay_session
	battle_host = host_battle
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	if not session.is_host():
		return
	var scene := get_tree().current_scene
	if scene == null or scene.filename in MIRRORED_ELSEWHERE:
		_scene = null
		return
	if scene != _scene:
		_scene = scene
		_emulators = ScenePaths.find_focus_emulators(scene)
		_last_sent.clear()
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = CHECK_INTERVAL
	var base := _state()
	for steam_id in session.peers:
		if not session.peers[steam_id].ready:
			continue
		var body := base.duplicate()
		body["you"] = battle_host._player_index_of(steam_id)
		var key := var2str(body)
		if _last_sent.get(steam_id) != key:
			_last_sent[steam_id] = key
			session.send_reliable(steam_id, Protocol.Msg.MENU_STATE, body)


func _on_peer_ready(steam_id: int) -> void:
	_last_sent.erase(steam_id)


func _state() -> Dictionary:
	var count: int = CoopService.connected_players.size()
	var players := []
	var selected = _scene.get("_has_player_selected")
	for p in count:
		var control = _focused_control(p)
		var id := ""
		var label := ""
		var is_random := false
		if control is InventoryElement:
			is_random = control.is_random
			if control.item != null:
				id = control.item.my_id
		elif control is Button:
			label = control.text
		var ready: bool = selected is Array and p < selected.size() and selected[p]
		players.append([id, label, is_random, ready])
	return {
		"kind": _scene.filename.get_file().get_basename(),
		"count": count,
		"players": players,
	}


func _focused_control(player_index: int):
	for emulator in _emulators:
		if is_instance_valid(emulator) and emulator.player_index == player_index:
			var control = emulator.focused_control
			if control != null and is_instance_valid(control) and control.is_visible_in_tree():
				return control
	return null


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.MENU_STATE or not session.is_client():
		return
	if steam_id != session.transport.host_id or typeof(body) != TYPE_DICTIONARY:
		return
	if typeof(body.get("kind")) != TYPE_STRING or typeof(body.get("players")) != TYPE_ARRAY:
		return
	emit_signal("menu_state", body)
