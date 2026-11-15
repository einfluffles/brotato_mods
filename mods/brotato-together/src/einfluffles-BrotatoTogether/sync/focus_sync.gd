extends Node
# Mirrors every player's cursor (FocusEmulator.focused_control) from host to clients in scenes
# that both sides build from the same run state (shop, level-up/crate panels, end of run).
# Setting focused_control on the client goes through the game's own setter, so highlights, info
# panels and item popups follow.
# A cursor is [player, menu, control]: the emulator by its player_index among the FocusEmulators
# of its menu (the node they are children of: the scene root in the shop, UpgradesUI, PauseMenu,
# RetryWave, ...; a menu with a single emulator needs no match), menu and control as
# ui/focus_targets.gd targets (by meaning, so another mod's extra node on one side moves nothing).

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const CHECK_INTERVAL := 0.05
const PENDING_TIMEOUT_MSEC := 10000
const MAX_CURSORS := 16
const MAX_PLAYERS := 4

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
# client: FocusEmulators this client drives itself (its own level-up panel, see
# sync/upgrades_sync.gd). The host's cursor for them is never applied here.
var local_emulators := []

var _scene: Node = null
var _emulators := []
var _last_sent := ""
var _check_left := 0.0
# scene path -> {body, msec}: the latest FOCUS body per scene with cursors that could not be
# applied yet (scene not loaded, controls not built or still hidden); retried every frame.
var _pending := {}


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
		_retry_pending()


func _cursors() -> Array:
	var cursors := []
	for emulator in _emulators:
		if not is_instance_valid(emulator):
			continue
		var control = emulator.focused_control
		if control == null or not is_instance_valid(control):
			continue
		var cursor := cursor_of(emulator, control, _scene)
		if not cursor.empty():
			cursors.append(cursor)
	return cursors


# [player, menu, control], or [] when either is not below scene.
static func cursor_of(emulator: Node, control: Node, scene: Node) -> Array:
	var menu: Array = FocusTargets.describe(emulator.get_parent(), scene)
	var target: Array = FocusTargets.describe(control, scene)
	if menu.empty() or target.empty():
		return []
	return [emulator.player_index, menu, target]


# The FocusEmulator a cursor names, or null (network data).
static func find_emulator(scene: Node, player, menu) -> Node:
	if typeof(player) != TYPE_INT or player < -1 or player >= MAX_PLAYERS:
		return null
	var parent: Node = FocusTargets.resolve(menu, scene)
	if parent == null:
		return null
	var found := []
	for child in parent.get_children():
		if child is FocusEmulator and not child.is_queued_for_deletion():
			found.append(child)
	if found.size() == 1:
		return found[0]  # pause menu, retry prompt: who holds it is mirrored elsewhere
	for emulator in found:
		if player >= 0 and emulator.player_index == player:
			return emulator
	return null


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
	if steam_id == session.transport.host_id:
		receive(body)


func receive(body) -> void:
	if typeof(body) != TYPE_DICTIONARY:
		return
	if typeof(body.get("scene")) != TYPE_STRING or typeof(body.get("cursors")) != TYPE_ARRAY:
		return
	if body.cursors.size() > MAX_CURSORS:
		return
	_pending[body.scene] = {"body": body, "msec": OS.get_ticks_msec()}
	_retry_pending()


func is_pending(scene_path: String) -> bool:
	return _pending.has(scene_path)


func _retry_pending() -> void:
	var now := OS.get_ticks_msec()
	for scene_path in _pending.keys():
		if now - _pending[scene_path].msec > PENDING_TIMEOUT_MSEC:
			_pending.erase(scene_path)
	if is_instance_valid(_scene) and _pending.has(_scene.filename):
		if _apply(_pending[_scene.filename].body):
			_pending.erase(_scene.filename)


# Only while mirroring. Returns true once every cursor is where the host has it; until then
# the body stays pending (a cursor on a control that isn't built / visible yet is retried, one
# on a control only the host has until the body times out).
func _apply(body: Dictionary) -> bool:
	if not Puppet.is_active() or not is_instance_valid(_scene) or _scene.filename != body.scene:
		return false
	var done := true
	for cursor in body.cursors:
		if typeof(cursor) != TYPE_ARRAY or cursor.size() != 3:
			continue
		var emulator = find_emulator(_scene, cursor[0], cursor[1])
		if emulator != null and emulator in local_emulators:
			continue
		var control = FocusTargets.resolve(cursor[2], _scene)
		if not (emulator is FocusEmulator) or not (control is Control):
			done = false
		elif not control.is_visible_in_tree():
			done = false
		elif emulator.focused_control != control:
			emulator.focused_control = control
	return done
