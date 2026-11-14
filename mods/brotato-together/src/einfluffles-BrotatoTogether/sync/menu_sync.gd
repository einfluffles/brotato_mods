extends Node
# Menus outside battle and shop (character/weapon/difficulty selection, end of run, title...).
# Their grids depend on each machine's own unlocks/DLC, so instead of running them on the client
# we mirror *what* each player has under their cursor (by item id) and whether they're ready;
# the client shows the game's own item cards for that (ui/client_view.gd).
# The host's grids themselves (ordered element ids + flags per visible Inventory) travel as
# "grids", only when they change; cursors are [inventory, index] into them, so the client draws
# the host's grid with every cursor (ui/selection_grid.gd) whatever it has unlocked itself.

signal menu_state(state)

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const SelectionGrid := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/selection_grid.gd"
)
const MIRRORED_ELSEWHERE := ["res://main.tscn", "res://ui/menus/shop/coop_shop.tscn"]
const CHECK_INTERVAL := 0.1

var session: Node = null
var battle_host: Node = null  # for the SteamID -> player slot mapping

var _scene: Node = null
var _emulators := []
var _last_sent := {}  # steam id -> key
var _last_grids := {}  # steam id -> grids key
var _check_left := 0.0
var _client_grids := {}  # client: last grids received (MENU_STATE carries them on change only)


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
		_last_grids.clear()
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = CHECK_INTERVAL
	var base := _state()
	var grids := grids_state()
	var grids_key := var2str(grids)
	for steam_id in session.peers:
		if not session.peers[steam_id].ready:
			continue
		var body := base.duplicate()
		body["you"] = battle_host._player_index_of(steam_id)
		var key := var2str(body)
		var new_grids: bool = _last_grids.get(steam_id) != grids_key
		if new_grids or _last_sent.get(steam_id) != key:
			_last_sent[steam_id] = key
			_last_grids[steam_id] = grids_key
			if new_grids:
				body["grids"] = grids
			session.send_reliable(steam_id, Protocol.Msg.MENU_STATE, body)


func _on_peer_ready(steam_id: int) -> void:
	_last_sent.erase(steam_id)
	_last_grids.erase(steam_id)


func _state() -> Dictionary:
	var count: int = CoopService.connected_players.size()
	var players := []
	var selected = _scene.get("_has_player_selected")
	var inventories := _inventories()
	var locked_panels: Array = (
		_scene._get_locked_panels() if _scene.has_method("_get_locked_panels") else []
	)
	for p in count:
		var control = _focused_control(p)
		var id := ""
		var label := ""
		var is_random := false
		var position := [-1, -1]  # [inventory, index] in grids_state()
		var lock_text := ""  # what the host's LockedPanel shows instead of the item
		var locked := false  # locked by a challenge: the client localises the text itself
		if control is InventoryElement:
			is_random = control.is_random
			if control.item != null:
				id = control.item.my_id
				locked = (
					control.is_special
					and not is_random
					and control.item.get("is_locked") == true
				)
			if control.is_special and not is_random and p < locked_panels.size():
				lock_text = _locked_text(locked_panels[p])
			var inventory: int = inventories.find(control.get_parent())
			if inventory >= 0:
				position = [inventory, _elements_of(inventories[inventory]).find(control)]
		elif control is Button:
			label = control.text
		var ready: bool = selected is Array and p < selected.size() and selected[p]
		players.append(
			[id, label, is_random, ready, position[0], position[1], lock_text, locked]
		)
	var state := {
		"kind": _scene.filename.get_file().get_basename(),
		"count": count,
		"players": players,
		"colors": CoopService.bt_slot_colors.duplicate(),
		"max": CoopService.get_max_players(),
		"reward": _scene._get_reward_type() if _scene.has_method("_get_reward_type") else -1,
	}
	# Character selection while players can join: hold progress of those joining right now.
	if (
		_scene.has_method("_get_coop_join_panels")
		and RunData.is_coop_run
		and CoopService.listening_for_inputs
	):
		var joining := []
		for progress in CoopService.connection_progress:
			joining.append(stepify(progress, 0.1))
		state["join"] = joining
	return state


static func _locked_text(panel) -> String:
	if panel == null or not panel.visible:
		return ""
	var description = panel.get("_description")
	return description.text if description is Label else ""


# Visible selection grids in tree order: {random_icon, inventories: [[columns, [[id, flags]]]]}.
func grids_state() -> Dictionary:
	var inventories := []
	for inventory in _inventories():
		var elements := []
		for element in _elements_of(inventory):
			var flags := 0
			if element.is_random:
				flags |= SelectionGrid.FLAG_RANDOM
			if element.is_special:
				flags |= SelectionGrid.FLAG_SPECIAL
			var locked = element.item.get("is_locked") if element.item != null else null
			if locked is bool and locked:
				flags |= SelectionGrid.FLAG_LOCKED
			elements.append([element.item.my_id if element.item != null else "", flags])
		inventories.append([inventory.columns, elements])
	var random_icon = _scene.get("random_icon") if _scene != null else null
	return {
		"random_icon": random_icon.resource_path if random_icon is Texture else "",
		"inventories": inventories,
	}


# The selection screens' own grids (BaseSelection._get_inventories), visible ones only.
func _inventories() -> Array:
	var found := []
	if _scene == null or not _scene.has_method("_get_inventories"):
		return found
	for inventory in _scene._get_inventories():
		if inventory is Inventory and inventory.is_visible_in_tree():
			found.append(inventory)
	return found


static func _elements_of(inventory: Node) -> Array:
	var elements := []
	for child in inventory.get_children():
		if child is InventoryElement and not child.is_queued_for_deletion():
			elements.append(child)
	return elements


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
	if steam_id == session.transport.host_id:
		receive_state(body)


func receive_state(body) -> void:
	if typeof(body) != TYPE_DICTIONARY:
		return
	if typeof(body.get("kind")) != TYPE_STRING or typeof(body.get("players")) != TYPE_ARRAY:
		return
	CoopService.bt_apply_remote_colors(body.get("colors"))
	if body.has("grids"):
		_client_grids = body.grids if typeof(body.grids) == TYPE_DICTIONARY else {}
	body["grids"] = _client_grids
	emit_signal("menu_state", body)
