extends Node
# The HUD's list of what each player picked up for the end of the wave: crates (the green one,
# the red legendary one) and the mutation fruit / meca parts icons. The game adds them in
# main.on_consumable_picked_up, which never runs on a client's puppet battle, so a client saw the
# level-up icons (BattleClient._show_level_up) and none of these.
# Section PICKUPS of sync/state_stream.gd: {battle_id, players: [[consumable my_id, ...]]} while
# the host is in a battle, sent when a list changes (and on a resync: a player joining mid-wave
# gets the lists as they are). The client makes its lists the same with the lists' own
# add_element / remove_element; pending until the puppet battle of that battle_id is ready.

const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const MAX_PLAYERS := 4
const MAX_ENTRIES := 64  # per player (network data)
const MAX_ID_LENGTH := 96

var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var battle_host: Node = null
var battle_client: Node = null


func setup(host_battle: Node, client_battle: Node) -> void:
	battle_host = host_battle
	battle_client = client_battle
	state_stream.register_provider(StateStream.PICKUPS, self)
	state_stream.register_handler(StateStream.PICKUPS, self, 30.0)


# --- host ---


func state_key(_section: int) -> String:
	var body = state_body(_section)
	return "" if body == null else var2str(body)


func state_body(_section: int):
	if not battle_host.is_in_battle():
		return null
	var players := []
	for list in _lists(battle_host._main):
		var ids := []
		for data in list._elements:
			ids.append(data.my_id)
		players.append(ids)
	return {"battle_id": battle_host._battle_id, "players": players}


# Each player's UIConsumableToProcessList of a battle scene.
static func _lists(main: Node) -> Array:
	var lists := []
	var containers = main.get("_things_to_process_player_containers")
	if containers is Array:
		for container in containers:
			lists.append(container.consumables)
	return lists


# --- client ---


func apply_state(_section: int, body, _revision: int) -> bool:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("battle_id")) != TYPE_INT:
		return true
	if typeof(body.get("players")) != TYPE_ARRAY or body.battle_id < battle_client._battle_id:
		return true
	if body.battle_id != battle_client._battle_id or not battle_client.is_in_battle():
		return false
	var lists := _lists(battle_client._main)
	for i in min(lists.size(), min(body.players.size(), MAX_PLAYERS)):
		_show(lists[i], _ids(body.players[i]))
	return true


static func _ids(entries) -> Array:
	var ids := []
	if typeof(entries) == TYPE_ARRAY:
		for id in entries.slice(0, MAX_ENTRIES - 1):
			if typeof(id) == TYPE_STRING and id.length() <= MAX_ID_LENGTH:
				ids.append(id)
	return ids


# Takes out what the host's list no longer has, adds what it has more of.
func _show(list: Node, ids: Array) -> void:
	var missing := ids.duplicate()
	for data in list._elements.duplicate():
		var at := missing.find(data.my_id)
		if at >= 0:
			missing.remove(at)
		else:
			list.remove_element(data)
	for id in missing:
		var data = battle_client._find_consumable(id)
		if data != null:
			list.add_element(_zone_copy(data))


# Its own object per entry (the list takes entries out by object), with the zone's sprite like
# the host's (ItemService.get_consumable_for_tier).
static func _zone_copy(data: Resource) -> Resource:
	var copy: Resource = data.duplicate()
	if RunData.current_background != null:
		copy.icon = RunData.current_background.get_zone_consumable_sprite(copy)
	return copy
