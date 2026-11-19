extends Node
# How far every player's panel is scrolled, the same on every screen of the lobby. Cosmetic.
# - Client -> host, PANEL_SCROLL (on change): its own panel, {scene, scrolls: [[target, value]]}.
# - Host -> clients, section SCROLLS: {scene, players: [[player, [[target, value]]]]}.
# A target is the ScrollContainer as a ui/focus_targets.gd target; the value is scroll_vertical.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const SharedScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/shared_scroll.gd")
const WheelScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/wheel_scroll.gd")
const CHECK_INTERVAL := 0.1
const MAX_PLAYERS := 4
const MAX_SCROLLS := 16  # per player (network data)
const MAX_VALUE := 1 << 20
const FOLLOW_SPEED := 600.0  # px per second at least: CharacterPanelUI.SCROLL_SPEED
const CATCH_UP := 12.0  # share of the remaining way per second, for long ways
const FOLLOW_MSEC := 2000  # how long a value is followed (or waits for its container)

var session: Node = null
var state_stream: Node = null
var focus_sync: Node = null  # client: its local_emulators name the own panel
var input_sync: Node = null  # host: which player a peer is
var last_sent := {}  # client: the last PANEL_SCROLL body

var _since := 0.0
var _sent := ""  # client: the last PANEL_SCROLL body as text
# "player target" -> {scene_id, player, target, value, node_id, since}
var _follow := {}


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	state_stream.register_provider(StateStream.SCROLLS, self, CHECK_INTERVAL)
	state_stream.register_handler(StateStream.SCROLLS, self)


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	_since += delta
	if _since >= CHECK_INTERVAL:
		_since = 0.0
		if session != null and session.is_client():
			send_own()
	step_follow(delta)


func _on_lobby_left() -> void:
	_sent = ""
	last_sent = {}
	_follow = {}


# Player p's panels on scene: the co-op shop's player container, the level-up / crate panel
# while it shows, the selection screens' panel. [] elsewhere.
static func panel_roots(scene: Node, p: int) -> Array:
	if scene == null or not is_instance_valid(scene) or not RunData.is_coop_run:
		return []
	if p < 0 or p >= MAX_PLAYERS:
		return []
	var root = null
	if scene.has_method("_get_coop_player_container"):
		if p < RunData.get_player_count():
			root = scene._get_coop_player_container(p)
	elif is_selection(scene):
		var panels: Array = scene._get_panels()
		if p < panels.size() and p < CoopService.connected_players.size():
			root = panels[p]
	elif p < RunData.get_player_count():
		root = FocusTargets._upgrade_container(scene, p)
	if root is Control and is_instance_valid(root) and root.is_visible_in_tree():
		return [root]
	return []


static func is_selection(scene: Node) -> bool:
	return scene.has_method("_get_panels") and scene.has_method("_get_inventory_containers")


# The ScrollContainers below roots that show and can scroll, in tree order. Buttons hold none
# (an inventory element is one): the gear lists are not walked element by element.
static func scrolls_in(roots: Array) -> Array:
	var found := []
	for root in roots:
		_collect(root, found)
	return found


static func _collect(node: Node, found: Array) -> void:
	if node is CanvasItem and not node.visible:
		return
	if node is BaseButton:
		return
	if node is ScrollContainer and WheelScroll.can_scroll(node):
		found.append(node)
	for child in node.get_children():
		_collect(child, found)


# [[target, value]] of player p's panel on scene.
static func describe_player(scene: Node, p: int) -> Array:
	var roots := panel_roots(scene, p)
	var list := []
	for scroll in scrolls_in(roots):
		var target := _describe(scroll, scene, p, roots[0])
		if not target.empty():
			list.append([target, scroll.scroll_vertical])
		if list.size() >= MAX_SCROLLS:
			break
	return list


static func _describe(scroll: Node, scene: Node, p: int, root: Node) -> Array:
	if is_selection(scene):
		return FocusTargets.describe(scroll, root)
	return FocusTargets.describe(scroll, scene, p)


# The ScrollContainer target names in player p's panel on scene, or null (network data).
static func resolve(scene: Node, p: int, target) -> ScrollContainer:
	var roots := panel_roots(scene, p)
	if roots.empty():
		return null
	var node = null
	if is_selection(scene):
		if typeof(target) == TYPE_ARRAY and not target.empty() and target[0] == FocusTargets.SCENE:
			node = FocusTargets.resolve(target, roots[0])
	else:
		node = FocusTargets.resolve(target, scene, p)
	if not (node is ScrollContainer) or not (node == roots[0] or roots[0].is_a_parent_of(node)):
		return null
	return node


# Cheap: instance ids and values, no description.
func state_key(_section: int) -> String:
	var scene := get_tree().current_scene
	if scene == null:
		return ""
	var key := PoolStringArray([str(scene.get_instance_id())])
	var any := false
	for p in MAX_PLAYERS:
		var roots := panel_roots(scene, p)
		if roots.empty():
			continue
		any = true
		for scroll in scrolls_in(roots):
			key.append("%d %d %d" % [p, scroll.get_instance_id(), scroll.scroll_vertical])
	return key.join("|") if any else ""


func state_body(_section: int) -> Dictionary:
	var scene := get_tree().current_scene
	var players := []
	for p in MAX_PLAYERS:
		if not panel_roots(scene, p).empty():
			players.append([p, describe_player(scene, p)])
	return {"scene": scene.filename, "players": players}


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.PANEL_SCROLL or not session.is_host():
		return
	host_apply(_player_index_of(steam_id), body)


# A client's own panel (player p) on the host's copy. False: not applied.
func host_apply(p: int, body) -> bool:
	if p < 0 or typeof(body) != TYPE_DICTIONARY:
		return false
	var scene := get_tree().current_scene
	if scene == null or typeof(body.get("scene")) != TYPE_STRING or body.scene != scene.filename:
		return false
	return follow(scene, p, body.get("scrolls"))


func _player_index_of(steam_id: int) -> int:
	var device = input_sync.devices.get(steam_id) if input_sync != null else null
	if device == null:
		return -1
	for i in CoopService.connected_players.size():
		if CoopService.connected_players[i][0] == device:
			return i
	return -1


func send_own() -> void:
	var body := own_body()
	if body.empty():
		_sent = ""
		return
	var text := var2str(body)
	if text == _sent:
		return
	_sent = text
	last_sent = body
	session.send_reliable(session.transport.host_id, Protocol.Msg.PANEL_SCROLL, body)


# PANEL_SCROLL's body for the current scene, {} while this client drives no panel there.
func own_body() -> Dictionary:
	var scene := get_tree().current_scene
	var own := own_player(scene)
	if own < 0 or not Puppet.is_active():
		return {}
	return {"scene": scene.filename, "scrolls": describe_player(scene, own)}


# The player whose panel this client drives on scene (-1: none, the host drives them all).
func own_player(scene: Node) -> int:
	if scene == null or not is_instance_valid(scene):
		return -1
	if focus_sync != null:
		for emulator in focus_sync.local_emulators:
			if is_instance_valid(emulator) and scene.is_a_parent_of(emulator):
				return emulator.player_index
	if Puppet.is_active() and is_selection(scene):
		return SharedScroll.own_player()
	return -1


# Every panel but the own one follows the host's. Waits (false) while the host's scene is not
# the current one here yet.
func apply_state(_section: int, body, _revision: int) -> bool:
	if typeof(body) != TYPE_DICTIONARY:
		return true
	if typeof(body.get("scene")) != TYPE_STRING or typeof(body.get("players")) != TYPE_ARRAY:
		return true
	var scene := get_tree().current_scene
	if not Puppet.is_active() or scene == null or scene.filename != body.scene:
		return false
	var own := own_player(scene)
	for i in min(body.players.size(), MAX_PLAYERS):
		var entry = body.players[i]
		if typeof(entry) != TYPE_ARRAY or entry.size() != 2 or typeof(entry[0]) != TYPE_INT:
			continue
		if entry[0] != own:
			follow(scene, entry[0], entry[1])
	return true


# Player p's panel on scene moves to the positions in scrolls ([[target, value]], network
# data). False: nothing valid in it.
func follow(scene: Node, p: int, scrolls) -> bool:
	if typeof(scrolls) != TYPE_ARRAY or scrolls.size() > MAX_SCROLLS:
		return false
	if p < 0 or p >= MAX_PLAYERS or panel_roots(scene, p).empty():
		return false
	var now := OS.get_ticks_msec()
	var any := false
	for scroll in scrolls:
		if typeof(scroll) != TYPE_ARRAY or scroll.size() != 2:
			continue
		var target = scroll[0]
		var value = scroll[1]
		if not FocusTargets.is_valid(target) or typeof(value) != TYPE_INT:
			continue
		if value < 0 or value > MAX_VALUE:
			continue
		_follow["%d %s" % [p, var2str(target)]] = {
			"scene_id": scene.get_instance_id(),
			"player": p,
			"target": target,
			"value": value,
			"node_id": 0,
			"since": now,
		}
		any = true
	return any


# Lets go of a container once it is there, so the receiver's own game (a popup that opens at the
# top) is not held back by an old value.
func step_follow(delta: float) -> void:
	if _follow.empty():
		return
	var scene := get_tree().current_scene
	var scene_id := scene.get_instance_id() if scene != null else 0
	var now := OS.get_ticks_msec()
	for key in _follow.keys():
		var entry: Dictionary = _follow[key]
		if entry.scene_id != scene_id or now - entry.since > FOLLOW_MSEC:
			_follow.erase(key)
			continue
		var scroll := _scroll_of(entry, scene)
		if scroll == null or not scroll.is_visible_in_tree():
			continue  # not built or not showing yet
		var diff: int = entry.value - scroll.scroll_vertical
		if diff == 0:
			_follow.erase(key)
			continue
		var most := int(max(FOLLOW_SPEED * delta, abs(diff) * min(1.0, CATCH_UP * delta)))
		scroll.scroll_vertical += int(clamp(diff, -max(most, 1), max(most, 1)))


func _scroll_of(entry: Dictionary, scene: Node) -> ScrollContainer:
	if entry.node_id != 0:
		var node = instance_from_id(entry.node_id)
		if node is ScrollContainer and is_instance_valid(node) and node.is_inside_tree():
			return node
		entry.node_id = 0
	var scroll := resolve(scene, entry.player, entry.target)
	if scroll != null:
		entry.node_id = scroll.get_instance_id()
	return scroll


# Followed values that have not arrived yet.
func following() -> int:
	return _follow.size()
