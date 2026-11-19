extends Node
# Menus outside battle and shop: the host runs them, a client shows a copy that decides nothing
# (sync/menu_puppet.gd). Sections MENU (see _state()) and MENU_GRIDS (see grids_state()) both
# carry `screen`: the client shows a state only with the grids of the same screen.

signal menu_state(state)

const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const FLAG_RANDOM := 1
const FLAG_SPECIAL := 2  # shown greyed out / with a lock (locked, needs an item set)
const FLAG_LOCKED := 4
# Screens built from the run (the players' characters, weapons, items): it travels with the grids.
const RUN_KINDS := ["weapon_selection", "difficulty_selection", "coop_end_run"]
const MIRRORED_ELSEWHERE := ["res://main.tscn", "res://ui/menus/shop/coop_shop.tscn"]

var session: Node = null
var state_stream: Node = null
var battle_host: Node = null  # for the SteamID -> player slot mapping

var _scene: Node = null
var _run_screen := 0  # the screen _run was packed for
var _run = null
var _client_state := {}  # client: latest menu body (without grids)
var _client_grids := {}  # client: latest menu_grids body


func setup(netplay_session: Node, host_battle: Node) -> void:
	session = netplay_session
	battle_host = host_battle
	for section in [StateStream.MENU, StateStream.MENU_GRIDS]:
		state_stream.register_provider(section, self)
		state_stream.register_handler(section, self)


func _track_scene() -> bool:
	var scene := get_tree().current_scene
	if scene == null or scene.filename in MIRRORED_ELSEWHERE:
		_scene = null
		return false
	_scene = scene
	return true


# The menu key covers every ready peer's `you`.
func state_key(section: int) -> String:
	if not _track_scene():
		return ""
	if section == StateStream.MENU_GRIDS:
		return var2str(_grids())
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


# kind, screen, count, coop, selected (per player), colors (palette index per slot), max; character
# selection: zone [id, random], endless, and while joining is open join (hold progress of the
# joining players); weapon selection: picks (per player the indices of its picked elements),
# character_shown (per player: its panel shows the player's character, ui_info held); end of
# run: pages (per player its carousel page). `you` comes with the per-peer patch.
func _state() -> Dictionary:
	var count: int = CoopService.connected_players.size()
	var chosen = _scene.get("_has_player_selected")
	var selected := []
	for p in count:
		selected.append(chosen is Array and p < chosen.size() and bool(chosen[p]))
	var state := {
		"kind": kind_of(_scene),
		"screen": _scene.get_instance_id(),
		"count": count,
		"coop": RunData.is_coop_run,
		"selected": selected,
		"colors": CoopService.bt_slot_colors.duplicate(),
		"max": CoopService.get_max_players(),
	}
	if _scene.has_method("_get_coop_join_panels"):
		state["zone"] = [RunData.current_zone, bool(ProgressData.settings.zone_is_random)]
		state["endless"] = RunData.is_endless_run
		# While players can join: hold progress of those joining right now.
		if RunData.is_coop_run and CoopService.listening_for_inputs:
			var joining := []
			for progress in CoopService.connection_progress:
				joining.append(stepify(progress, 0.1))
			state["join"] = joining
	var picked = _scene.get("_picked_elements")
	if picked is Array:
		state["picks"] = _picks(picked)
		state["character_shown"] = _character_shown(count)
	var containers = _scene.get("player_containers")
	if containers is Array:
		var pages := []
		for p in min(count, containers.size()):
			pages.append(containers[p].carousel.index)
		state["pages"] = pages
	return state


static func kind_of(scene: Node) -> String:
	return scene.filename.get_file().get_basename()


# WeaponSelection: per player whether its panel shows the player's character (ui_info held,
# WeaponSelection._input) instead of the element under its cursor.
func _character_shown(count: int) -> Array:
	var shown := []
	var panels: Array = _scene._get_panels()
	for p in min(count, panels.size()):
		var character = RunData.get_player_character(p) if p < RunData.get_player_count() else null
		shown.append(shows_character(panels[p], character))
	return shown


static func shows_character(panel: Node, character) -> bool:
	var item = panel.get("item_data")
	return character != null and item != null and item.my_id == character.my_id


# WeaponSelection._picked_elements as indices into each player's grid.
func _picks(picked: Array) -> Array:
	var inventories: Array = _scene._get_inventories()
	var picks := []
	for p in picked.size():
		var indices := []
		if picked[p] is Array and p < inventories.size():
			var elements := _elements_of(inventories[p])
			for element in picked[p]:
				indices.append(elements.find(element))
		picks.append(indices)
	return picks


# What the screen is built from: screen, inventories [[[id, flags, tier]]] (the visible
# selection grids in tree order), and for RUN_KINDS run (RunStateCodec) + won.
func grids_state() -> Dictionary:
	var state := _grids()
	if _scene == null or not (kind_of(_scene) in RUN_KINDS):
		return state
	# The run does not change while one of these screens is up: packed when it appears.
	if _run_screen != _scene.get_instance_id():
		_run_screen = _scene.get_instance_id()
		_run = RunStateCodec.encode()
	state["run"] = _run
	state["won"] = RunData.run_won
	return state


# The grids alone (also the section's key: no run in it). The elements travel in the host's
# order because they depend on each machine's own unlocks and DLC.
func _grids() -> Dictionary:
	var inventories := []
	for inventory in _inventories():
		var elements := []
		for element in _elements_of(inventory):
			var flags := 0
			if element.is_random:
				flags |= FLAG_RANDOM
			if element.is_special:
				flags |= FLAG_SPECIAL
			var item = element.item
			if item != null and item.get("is_locked") == true:
				flags |= FLAG_LOCKED
			var tier = item.get("tier") if item != null else null
			elements.append(
				[item.my_id if item != null else "", flags, tier if tier is int else 0]
			)
		inventories.append(elements)
	return {"screen": _scene.get_instance_id() if _scene != null else 0, "inventories": inventories}


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


# Never pending: a state waits for its grids here, not in the stream, so that the grids section
# shows it the moment they arrive.
func apply_state(section: int, body, _revision: int) -> bool:
	if typeof(body) != TYPE_DICTIONARY:
		return true
	if section == StateStream.MENU_GRIDS:
		_client_grids = body
	else:
		if typeof(body.get("kind")) != TYPE_STRING or typeof(body.get("selected")) != TYPE_ARRAY:
			return true
		if typeof(body.get("screen")) != TYPE_INT or typeof(body.get("count")) != TYPE_INT:
			return true
		CoopService.bt_apply_remote_colors(body.get("colors"))
		_client_state = body
	if _client_state.empty() or _client_grids.get("screen") != _client_state.get("screen"):
		return true
	var state := _client_state.duplicate()
	state["grids"] = _client_grids
	emit_signal("menu_state", state)
	return true


# Forgotten so that a later screen never pairs with them.
func clear_state(section: int) -> void:
	if section == StateStream.MENU_GRIDS:
		_client_grids = {}
	else:
		_client_state = {}
