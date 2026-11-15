extends Node
# Mirrors every player's cursor (FocusEmulator.focused_control) from host to clients in scenes
# that both sides build from the same run state (shop, level-up/crate panels, end of run).
# Setting focused_control on the client goes through the game's own setter, so highlights, info
# panels and item popups follow.
# A cursor is [player, menu, control]: the emulator by its player_index among the FocusEmulators
# of its menu (the node they are children of: the scene root in the shop, UpgradesUI, PauseMenu,
# RetryWave, ...; a menu with a single emulator needs no match), menu and control as
# ui/focus_targets.gd targets (by meaning, so another mod's extra node on one side moves nothing).
#
# Section CURSORS of sync/state_stream.gd, last in section order: the sections that build the
# controls (shop, level-up panels, retry prompt) are applied before the cursors that point at
# them. Body: {scene: the host's scene path, cursors: [[player, menu, control]]}. Inactive (null)
# while the host's scene has no emulators; nothing is undone then (no clear_state): the cursors
# live on the client's scene nodes and go with its scene. The stream keeps one pending body: a
# body for the next scene replaces one still waiting for the previous scene, which only drops
# cursors on a screen the host has already left.

const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const CHECK_INTERVAL := 0.05
# The key's safety net (see state_key): one full description per second while the key stays the
# same, about 0.4 ms in a two-player shop.
const SAFETY_NET_MSEC := 1000
const LOG_NAME := "einfluffles-BrotatoTogether:FocusSync"
# A body stays pending this long until every cursor resolves to a visible control (scene still
# loading, retry prompt not shown yet); a cursor on a control only the host has times it out.
const PENDING_TIMEOUT_SEC := 10.0
const MAX_CURSORS := 16
const MAX_PLAYERS := 4

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
# client: FocusEmulators this client drives itself (its own level-up panel, see
# sync/upgrades_sync.gd). The host's cursor for them is never applied here.
var local_emulators := []
var missed := 0  # host: changes only the key's safety net found (tests)

# host: the scene the emulators were collected from (once per scene, like before the stream)
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


# --- host (provider) ---


# Who points where by identity and tree position, not described: describing (cursor_of) builds
# FocusTargets' anchor table for every player twice per cursor, about 0.4 ms per check in a
# two-player shop, 20 checks a second. Per cursor: the emulator's player_index, the control's
# instance id, the child indices of emulator and control up to the scene; plus the player count
# (which anchors exist) and the scene instance (a scene reloaded under the same path, retry wave,
# sends its cursors again). Covered (cursor_key_tests.gd): every change the game makes on these
# screens. A cursor moving or dropped, a sibling added or removed before the control or one of
# its parents, the control leaving the scene, an emulator freed: the key changes in the same
# check. A sibling queued for deletion: the description stops counting it at once, the key's
# child index when it is freed at the end of that frame, so that change goes out one check late
# (BaseShop._combine_weapon queues the combined weapons). The anchors are the game's fixed nodes
# (onready vars; the shop's slots from ShopItemsContainer._shop_items_node_paths at _ready).
# Not seen by the key, caught by the safety net within SAFETY_NET_MSEC (never done by the game
# here, possible for another mod): a node on the path renamed, an owner or script changed on it
# or on a sibling before it, a sibling replaced by a node of another kind at the same index (also
# a queued one whose index another kind takes once it is freed), the control moved under another
# node at the same child indices, an accessor or list handing out other anchor nodes. The net describes the
# cursors once per SAFETY_NET_MSEC while the key stays the same and bumps _drift (part of the
# key) when they differ from the last body.
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


# False when there is nothing to send: no scene, or a scene without emulators.
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


# Child indices from node up to the scene ("-" when it is not below the scene: no cursor).
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


# --- client (handler) ---


# Only while mirroring and only on the scene the body names. True once every cursor is where the
# host has it (or the body is malformed: nothing to wait for); until then the stream keeps it
# pending and calls again every frame (a cursor on a control that isn't built / visible yet is
# retried, one on a control only the host has until the body times out). Idempotent: setting an
# emulator to the control it already has does nothing.
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
