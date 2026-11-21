extends Node
# The device each player really uses, for the key hints of that player's panels on every machine
# (CoopService.get_player_input_type). A remote player's slot stays a gamepad on the host for its
# aim; its client sends the type with every INPUT (sync/local_aim.gd). Section input_types takes
# every slot's type to the clients, and a change redraws that player's panels where they are open.

const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const LocalPanel := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/local_panel.gd")

var session: Node = null
var state_stream: Node = null
var input_sync: Node = null


func setup(netplay_session: Node, remote_input: Node) -> void:
	session = netplay_session
	input_sync = remote_input
	state_stream.register_provider(StateStream.INPUT_TYPES, self)
	state_stream.register_handler(StateStream.INPUT_TYPES, self)
	session.transport.connect("lobby_left", self, "_on_lobby_left")
	CoopService.connect("bt_input_types_changed", self, "_on_types_changed")


# A player's panel was built (its _ready): its key hints are that player's.
func adopt(panel: Node) -> void:
	LocalPanel.adopt_hints(panel, panel.player_index)


# Covers the per-peer part too: a peer's slot follows from the slots and the peers' devices.
func state_key(_section: int) -> String:
	if CoopService.connected_players.empty():
		return ""
	return var2str([CoopService.connected_players, CoopService.bt_device_types, input_sync.devices])


# types: the PlayerType of each slot's key hints
func state_body(_section: int):
	var types := []
	for p in CoopService.connected_players.size():
		types.append(CoopService.get_player_input_type(p))
	return {"types": types}


# you: the peer's own slot (-1: none), which it types itself
func state_patch(_section: int, steam_id: int) -> Dictionary:
	var device: int = input_sync.devices.get(steam_id, -1)
	var you := -1
	for p in CoopService.connected_players.size():
		if CoopService.connected_players[p][0] == device:
			you = p
	return {"you": you}


func apply_state(_section: int, body, _revision: int) -> bool:
	if typeof(body) != TYPE_DICTIONARY:
		return true
	var types = body.get("types")
	var you = body.get("you", -1)
	if typeof(types) != TYPE_ARRAY or typeof(you) != TYPE_INT:
		return true
	var slots := {}
	for p in types.size():
		var player_type = types[p]
		if typeof(player_type) != TYPE_INT or player_type < 0:
			return true
		if player_type >= CoopService.PlayerType.size():
			return true
		if p != you:
			slots[p] = player_type
	CoopService.bt_set_slot_types(slots, you)
	return true


func clear_state(_section: int) -> void:
	CoopService.bt_set_slot_types({}, -1)


func _on_lobby_left() -> void:
	CoopService.bt_clear_input_types()


func _on_types_changed(player_index: int) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var panels := []
	for child in scene.get_children():
		_find_panels(child, player_index, panels)
	for panel in panels:
		var emulator = panel.get("focus_emulator")
		if emulator == null:
			emulator = Utils.get_focus_emulator(player_index, scene)
		LocalPanel.refresh_player_type(panel, player_index, emulator)
		if panel.has_method("_set_focus_neighbours"):
			panel._set_focus_neighbours()  # the page arrows can take the cursor now, or not


# Not into the world (Node2D): entities hold no panels.
static func _find_panels(node: Node, player_index: int, found: Array) -> void:
	if node is Node2D:
		return
	if (
		node is CoopShopPlayerContainer
		or node is CoopUpgradesUIPlayerContainer
		or node is EndRunPlayerContainer
	):
		if node.player_index == player_index:
			found.append(node)
		return
	for child in node.get_children():
		_find_panels(child, player_index, found)
