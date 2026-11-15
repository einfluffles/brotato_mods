extends Node
# Menus outside battle and shop (character/weapon/difficulty selection, end of run, title...).
# Their grids depend on each machine's own unlocks/DLC, so instead of running them on the client
# we mirror *what* each player has under their cursor (by item id) and whether they're ready;
# the client shows the game's own item cards for that (ui/client_view.gd).
# Two sections of the state stream (sync/state_stream.gd), both inactive while the host is in a
# battle or the shop (their own messages take over there):
#  - menu: the cursors and the screen, see _state(); `you` (the peer's player slot, -1:
#    spectator) is the per-peer patch.
#  - menu_grids: the host's grids themselves (ordered element ids + flags per visible Inventory,
#    see grids_state()), sent only when they change. Cursors are [inventory, index] into them, so
#    the client draws the host's grid with every cursor (ui/selection_grid.gd) whatever it has
#    unlocked itself.
# Both carry `screen` (the host scene's instance id): the client shows a state only with the grids
# of the same screen, so a new screen never shows with the previous screen's grids. Its grids
# come right after it (menu is ordered before menu_grids).

signal menu_state(state)

const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const SelectionGrid := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/selection_grid.gd"
)
const MIRRORED_ELSEWHERE := ["res://main.tscn", "res://ui/menus/shop/coop_shop.tscn"]

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var battle_host: Node = null  # for the SteamID -> player slot mapping

var _scene: Node = null
var _emulators := []
var _client_state := {}  # client: latest menu body (without grids)
var _client_grids := {}  # client: latest menu_grids body


func setup(netplay_session: Node, host_battle: Node) -> void:
	session = netplay_session
	battle_host = host_battle
	for section in [StateStream.MENU, StateStream.MENU_GRIDS]:
		state_stream.register_provider(section, self)
		state_stream.register_handler(section, self)


# --- host ---


# The host's menu scene, its focus emulators looked up again when it changes; false: none (no
# scene, or one mirrored by its own messages).
func _track_scene() -> bool:
	var scene := get_tree().current_scene
	if scene == null or scene.filename in MIRRORED_ELSEWHERE:
		_scene = null
		return false
	if scene != _scene:
		_scene = scene
		_emulators = ScenePaths.find_focus_emulators(scene)
	return true


# Built every check (0.1 s) like before the stream: the text of the state is the cheap part.
# The menu key covers every ready peer's `you`.
func state_key(section: int) -> String:
	if not _track_scene():
		return ""
	if section == StateStream.MENU_GRIDS:
		return var2str(grids_state())
	var slots := []
	for steam_id in session.peers:
		if session.peers[steam_id].ready:
			slots.append([steam_id, battle_host._player_index_of(steam_id)])
	return var2str(_state()) + var2str(slots)


func state_body(section: int):
	return grids_state() if section == StateStream.MENU_GRIDS else _state()


func state_patch(section: int, steam_id: int) -> Dictionary:
	if section != StateStream.MENU:
		return {}
	return {"you": battle_host._player_index_of(steam_id)}


# kind, screen, count, players [[id, label, random, ready, inv, idx, locked text, locked by
# challenge]], colors (palette index per slot), max, reward, join (only while joining is open:
# hold progress of joining players); `you` comes with the per-peer patch.
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
		"screen": _scene.get_instance_id(),
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


# Visible selection grids in tree order: {screen, random_icon, inventories: [[columns, [[id,
# flags]]]]}.
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
		"screen": _scene.get_instance_id() if _scene != null else 0,
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


# --- client ---


# Either section shows the latest state with the latest grids once both are of one screen
# (mod_main.gd::_on_menu_state). Never pending: a state waits for its grids here, not in the
# stream, so that the grids section shows it the moment they arrive.
func apply_state(section: int, body, _revision: int) -> bool:
	if typeof(body) != TYPE_DICTIONARY:
		return true
	if section == StateStream.MENU_GRIDS:
		_client_grids = body
	else:
		if typeof(body.get("kind")) != TYPE_STRING or typeof(body.get("players")) != TYPE_ARRAY:
			return true
		CoopService.bt_apply_remote_colors(body.get("colors"))
		_client_state = body
	if _client_state.empty() or _client_grids.get("screen") != _client_state.get("screen"):
		return true
	var state := _client_state.duplicate()
	state["grids"] = _client_grids
	emit_signal("menu_state", state)
	return true


# The host left the menus for a battle or the shop: nothing to show, its own message takes over
# (as before the stream). Forgotten so that a later screen never pairs with them.
func clear_state(section: int) -> void:
	if section == StateStream.MENU_GRIDS:
		_client_grids = {}
	else:
		_client_state = {}
