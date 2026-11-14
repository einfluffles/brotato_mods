extends Node
# Mirrors every player's cursor (FocusEmulator.focused_control) from host to clients in scenes
# that both sides build from the same run state (shop, level-up/crate panels, end of run).
# Setting focused_control on the client goes through the game's own setter, so highlights, info
# panels and item popups follow.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const CHECK_INTERVAL := 0.05

var session: Node = null

var _scene: Node = null
var _emulators := []
var _last_sent := ""
var _check_left := 0.0
var _pending := {}  # latest FOCUS body, applied once the client's scene matches


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	var scene := get_tree().current_scene
	if scene != _scene:
		_scene = scene
		_emulators = ScenePaths.find_focus_emulators(scene) if scene != null else []
		_last_sent = ""
	if session.is_host():
		_check_left -= delta
		if _check_left <= 0.0:
			_check_left = CHECK_INTERVAL
			_send_if_changed(false)
	elif session.is_client() and not _pending.empty():
		_apply(_pending)


func _cursors() -> Array:
	var cursors := []
	for emulator in _emulators:
		if not is_instance_valid(emulator):
			continue
		var control = emulator.focused_control
		if control == null or not is_instance_valid(control):
			continue
		var control_path := ScenePaths.path_of(control, _scene)
		if control_path.empty():
			continue
		cursors.append([ScenePaths.path_of(emulator, _scene), emulator.player_index, control_path])
	return cursors


func _send_if_changed(force: bool) -> void:
	if _scene == null:
		return
	var body := {"scene": _scene.filename, "cursors": _cursors()}
	var key := var2str(body)
	if force or key != _last_sent:
		_last_sent = key
		session.broadcast_reliable(Protocol.Msg.FOCUS, body)


func _on_peer_ready(_steam_id: int) -> void:
	if session.is_host():
		_send_if_changed(true)


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.FOCUS or not session.is_client():
		return
	if steam_id != session.transport.host_id or typeof(body) != TYPE_DICTIONARY:
		return
	if typeof(body.get("scene")) != TYPE_STRING or typeof(body.get("cursors")) != TYPE_ARRAY:
		return
	_pending = body
	_apply(body)


# Only while mirroring; keeps the latest body until the matching scene is loaded.
func _apply(body: Dictionary) -> void:
	if not Puppet.is_active() or _scene == null or _scene.filename != body.scene:
		return
	for cursor in body.cursors:
		if typeof(cursor) != TYPE_ARRAY or cursor.size() != 3:
			continue
		var emulator = ScenePaths.resolve(_scene, PoolIntArray(cursor[0]))
		var control = ScenePaths.resolve(_scene, PoolIntArray(cursor[2]))
		if not (emulator is FocusEmulator) or not (control is Control):
			continue
		if not control.is_visible_in_tree():
			continue
		if emulator.focused_control != control:
			emulator.focused_control = control
	_pending = {}
