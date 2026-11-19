extends Node
# Mirrors every player's cursor (FocusEmulator.focused_control) from host to clients in scenes
# that both sides build from the same run state. Section CURSORS of the state stream, after the
# sections that build the controls.
# Body: {scene: the host's scene path, cursors: [[player, menu, control]]}, menu and control as
# ui/focus_targets.gd targets. No clear_state: the cursors go with the client's scene nodes.

const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const CHECK_INTERVAL := 0.05
# The key's safety net (see state_key): one full description per interval while the key stays
# the same.
const SAFETY_NET_MSEC := 1000
const LOG_NAME := "einfluffles-BrotatoTogether:FocusSync"
# A body stays pending this long until every cursor resolves to a visible control (scene still
# loading, retry prompt not shown yet); a cursor on a control only the host has times it out.
const PENDING_TIMEOUT_SEC := 10.0
const MAX_CURSORS := 16
const MAX_PLAYERS := 4

var session: Node = null
var state_stream: Node = null
# client: FocusEmulators this client drives itself; the host's cursor for them is never applied.
# Read only: set_local_emulator keeps it.
var local_emulators := []
var missed := 0  # host: changes only the key's safety net found

var _local_by := {}  # client: screen ("shop", "upgrades") -> the FocusEmulator it drives

# host: the scene the emulators were collected from (once per scene)
var _scene: Node = null
var _scene_id := 0
var _emulators := []
var _key := ""  # the key returned last
var _described_key := ""  # the key the last body was described under
var _described := ""  # that body's cursors (var2str)
var _drift := 0  # bumped when the description changed under an unchanged key
var _net_msec := 0  # when the cursors were last described


func setup(netplay_session: Node) -> void:
	session = netplay_session
	state_stream.register_provider(StateStream.CURSORS, self, CHECK_INTERVAL)
	state_stream.register_handler(StateStream.CURSORS, self, PENDING_TIMEOUT_SEC)


func set_local_emulator(owner: String, emulator) -> void:
	if emulator == null:
		_local_by.erase(owner)
	else:
		_local_by[owner] = emulator
	local_emulators = _local_by.values()


# Identity and tree position: describing costs too much for every check. What the key cannot
# see is caught by the safety net, which describes once per SAFETY_NET_MSEC and bumps _drift.
func state_key(_section: int) -> String:
	if not _scan_scene():
		_key = ""
		return ""
	var key := PoolStringArray([str(_scene_id), str(RunData.get_player_count()), str(_drift)])
	for emulator in _emulators:
		if not is_instance_valid(emulator):
			continue
		var control = emulator.focused_control
		if control == null or not is_instance_valid(control):
			continue
		key.append(
			"%d %d %s %s" % [
				emulator.player_index,
				control.get_instance_id(),
				_tree_position(emulator),
				_tree_position(control),
			]
		)
	_key = key.join("|")
	var now := OS.get_ticks_msec()
	if _key == _described_key and now - _net_msec >= SAFETY_NET_MSEC:
		_net_msec = now
		if var2str(_cursors()) != _described:
			_missed()
			key[2] = str(_drift)
			_key = key.join("|")
	return _key


# Also when the stream resends under the same key (peer_ready): a description that changed
# meanwhile is a miss of the key, so the next check sends it to every peer.
func state_body(_section: int) -> Dictionary:
	var cursors := _cursors()
	var text := var2str(cursors)
	if _key == _described_key and text != _described:
		_missed()
	_described_key = _key
	_described = text
	_net_msec = OS.get_ticks_msec()
	return {"scene": _scene.filename, "cursors": cursors}


func _missed() -> void:
	_drift += 1
	missed += 1
	ModLoaderLog.warning("cursors changed without a change of their key; sent", LOG_NAME)


# By instance id: a new scene can reuse the freed one's address.
func _scan_scene() -> bool:
	var scene := get_tree().current_scene
	var scene_id := scene.get_instance_id() if scene != null else 0
	if scene_id != _scene_id:
		_scene_id = scene_id
		_scene = scene
		_emulators = ScenePaths.find_focus_emulators(scene) if scene != null else []
		if scene != null and not scene.is_connected("tree_exiting", self, "_forget_scene"):
			scene.connect("tree_exiting", self, "_forget_scene", [scene_id], CONNECT_ONESHOT)
	return scene != null and not _emulators.empty()


# The key is only checked while there are ready peers: without this, a scene and its emulators
# would stay referenced after the game freed them.
func _forget_scene(scene_id: int) -> void:
	if scene_id == _scene_id:
		_scene_id = 0
		_scene = null
		_emulators = []


func _tree_position(node: Node) -> String:
	var indices := PoolIntArray()
	while node != _scene:
		if node == null:
			return "-"
		indices.append(node.get_index())
		node = node.get_parent()
	return str(indices)


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


static func cursor_of(emulator: Node, control: Node, scene: Node) -> Array:
	var menu: Array = FocusTargets.describe(emulator.get_parent(), scene)
	var target: Array = FocusTargets.describe(control, scene)
	if menu.empty() or target.empty():
		return []
	return [emulator.player_index, menu, target]


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


# False keeps the body pending: the stream calls again every frame until every cursor is where
# the host has it, or the body times out (a cursor on a control only the host has).
func apply_state(_section: int, body, _revision: int) -> bool:
	if typeof(body) != TYPE_DICTIONARY:
		return true
	if typeof(body.get("scene")) != TYPE_STRING or typeof(body.get("cursors")) != TYPE_ARRAY:
		return true
	if body.cursors.size() > MAX_CURSORS:
		return true
	var scene := get_tree().current_scene
	if not Puppet.is_active() or not is_instance_valid(scene) or scene.filename != body.scene:
		return false
	var done := true
	for cursor in body.cursors:
		if typeof(cursor) != TYPE_ARRAY or cursor.size() != 3:
			continue
		var emulator = find_emulator(scene, cursor[0], cursor[1])
		if emulator != null and emulator in local_emulators:
			continue
		var control = FocusTargets.resolve(cursor[2], scene)
		if not (emulator is FocusEmulator) or not (control is Control):
			done = false
		elif not control.is_visible_in_tree():
			done = false
		elif emulator.focused_control != control:
			emulator.focused_control = control
	return done
