extends Node
# Client: the host's menus outside battle and shop as the game's own scenes (character / weapon
# / difficulty selection, end of run), built from the host's state (sync/menu_sync.gd) and
# deciding nothing:
# - the grids come from the host's element lists (session/puppet_menu.gd, read by the script
#   extensions of the three selection scenes), not from this machine's unlocks;
# - whatever would select, go back, start the run or write this machine's settings is cut in
#   those extensions; the end-of-run buttons are spent (BaseEndRun._button_pressed);
# - nobody joins here (CoopService.listening_for_inputs stays off), the mouse is kept off the
#   scene's controls and no control keeps the keyboard focus;
# - who selected, the zone, the run options, the join progress, the picks and the end-of-run
#   pages are set from the host's state; the cursors arrive with FocusSync, through the game's
#   own focus code, so the panels show what each cursor is on.
# All input still goes to the host (the players are virtual devices nobody presses here).

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const PuppetMenu := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet_menu.gd"
)
const MenuSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/menu_sync.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const LOG_NAME := "einfluffles-BrotatoTogether:MenuPuppet"
const CHARACTERS := "character_selection"
const WEAPONS := "weapon_selection"
const END_RUN := "coop_end_run"
# The host names its screen by kind only; the scene is this machine's own.
const SCENES := {
	CHARACTERS: "res://ui/menus/run/character_selection.tscn",
	WEAPONS: "res://ui/menus/run/weapon_selection.tscn",
	"difficulty_selection": "res://ui/menus/run/difficulty_selection/difficulty_selection.tscn",
	END_RUN: "res://ui/menus/run/coop_end_run.tscn",
}
const GLASS := "BrotatoTogetherGlass"
const LOADING_TIMEOUT_MSEC := 10000
const MAX_PLAYERS := 4
const MAX_ELEMENTS := 400
const MAX_ID_LENGTH := 96

var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)

var _screen := 0  # the host screen the copy stands for
var _kind := ""
var _scene_id := 0  # the copy, once it is ready
var _loading_msec := -LOADING_TIMEOUT_MSEC
var _state := {}  # the latest state of _screen
var _grids_key := 0  # hash of the inventories the copy was built from
var _items := {}  # my_id -> item of this machine


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func setup(session: Node) -> void:
	session.transport.connect("lobby_left", self, "_on_lobby_left", [session.transport])


# A menu state with its grids (MenuSync.menu_state). False: not a screen with a copy (title
# screen, a page of it): the caller shows the waiting screen.
func show(state: Dictionary) -> bool:
	var kind = state.get("kind")
	var grids = state.get("grids")
	# A host choosing for a solo run has no co-op screen to copy.
	if not SCENES.has(kind) or typeof(grids) != TYPE_DICTIONARY or state.get("coop") == false:
		forget()
		return false
	var scene := current()
	if state.screen != _screen or (scene == null and not _is_loading()):
		return _enter(kind, state)
	_state = state
	if scene != null:
		_apply(scene, state)
	return true  # else: applied when the copy is ready


# The copy of the host's screen, null while there is none (or it still loads).
func current() -> Node:
	var scene := get_tree().current_scene
	if scene == null or _scene_id == 0 or scene.get_instance_id() != _scene_id:
		return null
	return scene


func forget() -> void:
	_stop_watching_scenes()
	_screen = 0
	_kind = ""
	_scene_id = 0
	_loading_msec = -LOADING_TIMEOUT_MSEC
	_state = {}
	CoopService.bt_remote_progress = null


func _is_loading() -> bool:
	return _scene_id == 0 and OS.get_ticks_msec() - _loading_msec < LOADING_TIMEOUT_MSEC


func _enter(kind: String, state: Dictionary) -> bool:
	var grids: Dictionary = state.grids
	var run := {}
	if kind in MenuSync.RUN_KINDS:
		run = RunStateCodec.decode(grids.get("run"))
		if run.empty():
			ModLoaderLog.error("No run state for the host's %s" % kind, LOG_NAME)
			forget()
			return false
	forget()
	_screen = state.screen
	_kind = kind
	_state = state
	Puppet.set_active(true)
	var count := _count(state)
	VirtualDevices.fill_puppet_slots(count)
	if run.empty():
		RunData.reset()
		RunData.set_player_count(count)
	else:
		RunStateCodec.apply(run)
		RunData.run_won = grids.get("won") == true
	RunData.set_coop_run(true)
	RunData.play_mode = RunData.PlayMode.COOP
	# CharacterSelection keeps the slots only on this path (init_coop_service).
	RunData.menu_selection_back = kind == CHARACTERS
	Utils.reset_last_elt_selected()
	_items = {}  # the item lists may have changed (the host's DLC)
	_grids_key = hash(grids.get("inventories"))
	PuppetMenu.set_inventories(_inventories(grids.get("inventories")))
	get_tree().paused = false
	# Only while the copy loads: no node_added handler for every node otherwise.
	if not get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().connect("node_added", self, "_on_node_added")
	_loading_msec = OS.get_ticks_msec()
	if get_tree().change_scene(SCENES[kind]) != OK:
		ModLoaderLog.error("Could not load %s" % SCENES[kind], LOG_NAME)
		forget()
		return false
	return true


# The copy reacts to mirrored cursors with its own sounds; the host's replace them (UI_SOUNDS).
func _on_node_added(node: Node) -> void:
	if _kind != "" and node.filename == SCENES[_kind] and node.get_parent() == get_tree().root:
		node.connect("ready", self, "_on_scene_ready", [node], CONNECT_ONESHOT)
		node.connect("tree_exited", self, "_on_scene_exited", [], CONNECT_ONESHOT)
		SoundRelay.set_muted(true)


func _on_scene_exited() -> void:
	SoundRelay.set_muted(false)


func _stop_watching_scenes() -> void:
	if get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().disconnect("node_added", self, "_on_node_added")


func _on_scene_ready(scene: Node) -> void:
	_stop_watching_scenes()
	_scene_id = scene.get_instance_id()
	CoopService.listening_for_inputs = false
	# The mouse never reaches the copy's controls (Back, the run options, the end-of-run buttons).
	var glass := Control.new()
	glass.name = GLASS
	glass.anchor_right = 1.0
	glass.anchor_bottom = 1.0
	glass.mouse_filter = Control.MOUSE_FILTER_STOP
	scene.add_child(glass)
	if scene.get("_button_pressed") == false:
		scene._button_pressed = true  # BaseEndRun: restart / new run / exit are the host's
	_apply(scene, _state)
	if state_stream != null:
		state_stream.retry()  # the cursors that waited for this scene


func _process(_delta: float) -> void:
	var scene := current()
	if scene == null or _state.empty():
		return
	# The scene's own handlers (a cursor arriving, its deferred first focus) clear selections
	# and turn the join listening back on; the host's state stands.
	CoopService.listening_for_inputs = false
	_apply_selected(scene, _state)
	var focused: Control = scene.get_focus_owner()
	if focused != null and scene.is_a_parent_of(focused):
		focused.release_focus()  # the keyboard presses nothing here


func _apply(scene: Node, state: Dictionary) -> void:
	var inventories = state.grids.get("inventories")
	var grids_changed: bool = hash(inventories) != _grids_key
	if grids_changed:
		_grids_key = hash(inventories)
		PuppetMenu.set_inventories(_inventories(inventories))
	var count := _count(state)
	if count != CoopService.connected_players.size():
		# CharacterSelection builds a joining player's grid from this (the host's list above).
		VirtualDevices.fill_puppet_slots(count)
		CoopService.emit_signal("connected_players_updated", CoopService.connected_players)
	if grids_changed:
		_apply_grids(scene, inventories)
	_apply_selected(scene, state)
	if _kind == CHARACTERS:
		_apply_run_options(scene, state)
		_apply_join(scene, state.get("join"))
		_apply_tiers(scene, inventories)
	elif _kind == WEAPONS:
		_apply_picks(scene, state.get("picks"))
	elif _kind == END_RUN:
		_apply_pages(scene, state.get("pages"))


static func _count(state: Dictionary) -> int:
	return int(clamp(state.get("count", 0), 0, MAX_PLAYERS))


# --- grids ---


# The host's element lists as this machine's items, for session/puppet_menu.gd. An id this
# machine does not know (content only the host has) is left out, and logged: the cursors
# behind it are then one off.
func _inventories(inventories) -> Array:
	var built := []
	if typeof(inventories) != TYPE_ARRAY:
		return built
	for inventory in inventories.slice(0, MAX_PLAYERS - 1):
		var elements := []
		var unlocked := []
		for entry in _entries(inventory):
			if entry[1] & MenuSync.FLAG_RANDOM:
				continue
			var item = _find_item(entry[0])
			if item == null:
				ModLoaderLog.warning("The host offers %s, unknown here" % entry[0], LOG_NAME)
				continue
			item = item.duplicate()
			item.tier = entry[2]
			elements.append(item)
			if not entry[1] & MenuSync.FLAG_LOCKED:
				unlocked.append(item.my_id_hash)
		built.append({"elements": elements, "unlocked": unlocked})
	return built


# One inventory of the grids as [[id, flags, tier]], whatever arrived (network data).
static func _entries(inventory) -> Array:
	var entries := []
	if typeof(inventory) != TYPE_ARRAY:
		return entries
	for entry in inventory.slice(0, MAX_ELEMENTS - 1):
		if typeof(entry) != TYPE_ARRAY or entry.size() != 3:
			continue
		if typeof(entry[0]) != TYPE_STRING or entry[0].length() > MAX_ID_LENGTH:
			continue
		if typeof(entry[1]) != TYPE_INT or typeof(entry[2]) != TYPE_INT:
			continue
		entries.append(entry)
	return entries


func _find_item(my_id: String):
	if _items.empty():
		for list in [
			ItemService.characters, ItemService.weapons, ItemService.items, ItemService.difficulties
		]:
			for item in list:
				_items[item.my_id] = item
	return _items.get(my_id)


# What a grid of the copy shows, like MenuSync._grids describes the host's (without tiers).
static func _shown(inventory: Node) -> Array:
	var shown := []
	for element in MenuSync._elements_of(inventory):
		var locked: bool = element.item != null and element.item.get("is_locked") == true
		shown.append(
			[element.item.my_id if element.item != null else "", element.is_random, locked]
		)
	return shown


# The grids changed while the screen is up (a zone's colours, the first player joining): a
# grid that shows other elements than the host's is built again the way
# BaseSelection._set_base_ui_player_count builds it, with every cursor on it put back on the
# element at the same place.
func _apply_grids(scene: Node, inventories) -> void:
	if typeof(inventories) != TYPE_ARRAY or not scene.has_method("_get_inventories"):
		return
	var own: Array = scene._get_inventories()
	for i in min(own.size(), inventories.size()):
		var wanted := []
		for entry in _entries(inventories[i]):
			if entry[1] & MenuSync.FLAG_RANDOM or _find_item(entry[0]) != null:
				wanted.append(
					[
						entry[0],
						entry[1] & MenuSync.FLAG_RANDOM != 0,
						entry[1] & MenuSync.FLAG_LOCKED != 0,
					]
				)
		if _shown(own[i]) != wanted and own[i].is_visible_in_tree():
			_rebuild(scene, own[i], i)


func _rebuild(scene: Node, inventory: Node, index: int) -> void:
	var cursors := {}  # emulator -> element index
	for p in MAX_PLAYERS:
		var emulator = Utils.get_focus_emulator(p, scene)
		var control = emulator.focused_control if emulator != null else null
		if control != null and is_instance_valid(control) and control.get_parent() == inventory:
			cursors[emulator] = control.get_index()
			emulator.focused_control = null  # never a cursor on a freed element
	var possible: Array = scene._get_all_possible_elements(index)
	scene.displayed_elements[index] = scene._get_displayed_elements(
		possible, scene._get_unlocked_elements(index)
	)
	inventory.clear_elements()
	if possible.size() > 1 and scene.add_random_element:
		inventory.add_special_element(scene.random_icon, true)
	inventory.set_elements(scene.displayed_elements[index], false, false)
	scene._refresh_item_set_requirements()
	for emulator in cursors:
		var last: int = inventory.get_child_count() - 1
		if last >= 0:
			emulator.focused_control = inventory.get_child(int(min(cursors[emulator], last)))


# Character grid: the colour of a cell is the highest danger level beaten with that character,
# from the host's progress. CharacterSelectionInventory.update_elements_color would take it
# from this machine's.
func _apply_tiers(scene: Node, inventories) -> void:
	if typeof(inventories) != TYPE_ARRAY or inventories.empty():
		return
	var entries := _entries(inventories[0])
	var elements := MenuSync._elements_of(scene._get_inventories()[0])
	for i in min(entries.size(), elements.size()):
		var element = elements[i]
		if element.item == null or element.item.my_id != entries[i][0]:
			continue
		if element.item.tier != entries[i][2]:
			var item = element.item.duplicate()
			item.tier = entries[i][2]
			element.item = item
			element.update_background_color()


# --- what changes while the screen is up ---


# BaseSelection._has_player_selected and the panel's "selected" look, without the game's
# _set_selected_element (it ends the screen once everybody selected).
func _apply_selected(scene: Node, state: Dictionary) -> void:
	var has_selected = scene.get("_has_player_selected")
	var selected = state.get("selected")
	if not (has_selected is Array) or typeof(selected) != TYPE_ARRAY:
		return
	var panels: Array = scene._get_panels()
	var characters = scene.get("_player_characters")
	for p in min(RunData.get_player_count(), has_selected.size()):
		var wanted: bool = p < selected.size() and selected[p] == true
		has_selected[p] = wanted
		if panels[p].selected != wanted:
			panels[p].selected = wanted
		if characters is Array:
			# CharacterSelection: a chosen character keeps its panel while the cursor moves on.
			if wanted and characters[p] == null:
				var element = scene._latest_focused_element[p]
				characters[p] = element.item if is_instance_valid(element) else null
			elif not wanted:
				characters[p] = null


# Zone, its background, and the endless toggle, without the scene's own handlers (they write
# ProgressData.settings).
func _apply_run_options(scene: Node, state: Dictionary) -> void:
	var endless = state.get("endless")
	if typeof(endless) == TYPE_BOOL:
		RunData.is_endless_run = endless
		if scene._endless_button.pressed != endless:
			scene._endless_button.set_pressed_no_signal(endless)
	if not scene._coop_button.pressed:
		scene._coop_button.set_pressed_no_signal(true)
	var zone = state.get("zone")
	if typeof(zone) != TYPE_ARRAY or zone.size() != 2:
		return
	if typeof(zone[0]) != TYPE_INT or typeof(zone[1]) != TYPE_BOOL:
		return
	if scene.get_meta("bt_zone", null) == zone:
		return
	var button: OptionButton = scene._zone_selection_button
	var index: int = scene._random_zone_index
	var background: Texture = scene._ui_random_zone_background.texture
	if not zone[1]:
		var data = null
		for known in ZoneService.zones:
			if known.my_id == zone[0]:
				data = known
		if data == null:
			return  # a zone this machine does not have
		RunData.current_zone = zone[0]
		background = data.ui_background
		index = -1  # stays as it is when this machine's button does not offer the zone
		for i in scene._random_zone_index:
			if button.get_item_id(i) == zone[0]:
				index = i
	scene.set_meta("bt_zone", zone)
	if index >= 0:
		button.selected = index
	RunData.reset_background()
	scene._background.texture = background
	for panel in scene._get_panels():
		panel._update_bg()


# The host's hold-to-join progress in the free slots (CoopService extension;
# ui/coop_selection.gd adds its hints from it). null: the host lets nobody join right now.
func _apply_join(_scene: Node, join) -> void:
	var progress = null
	if typeof(join) == TYPE_ARRAY:
		progress = []
		for value in join.slice(0, MAX_PLAYERS - 1):
			if typeof(value) == TYPE_REAL or typeof(value) == TYPE_INT:
				progress.append(clamp(value, 0.0, 1.0))
	if progress == CoopService.bt_remote_progress:
		return
	CoopService.bt_remote_progress = progress
	CoopService._update_connection_progress()


# WeaponSelection: the "x2" on an element a player picked more than once.
func _apply_picks(scene: Node, picks) -> void:
	if typeof(picks) != TYPE_ARRAY:
		return
	var inventories: Array = scene._get_inventories()
	for p in min(RunData.get_player_count(), min(picks.size(), inventories.size())):
		if typeof(picks[p]) != TYPE_ARRAY or scene._get_required_pick_count(p) <= 1:
			continue
		var elements := MenuSync._elements_of(inventories[p])
		var picked := []
		for index in picks[p]:
			if typeof(index) == TYPE_INT and index >= 0 and index < elements.size():
				picked.append(elements[index])
		if picked == scene._picked_elements[p]:
			continue
		scene._picked_elements[p] = picked
		for element in elements:
			scene._update_pick_count_label(element, p)


# End of run: each player's carousel page (items / stats).
func _apply_pages(scene: Node, pages) -> void:
	if typeof(pages) != TYPE_ARRAY:
		return
	var containers: Array = scene.player_containers
	for p in min(RunData.get_player_count(), min(pages.size(), containers.size())):
		var carousel = containers[p].carousel
		if typeof(pages[p]) == TYPE_INT and pages[p] >= 0 and carousel.index != pages[p]:
			carousel.index = pages[p]


func _on_lobby_left(transport: Node) -> void:
	var mirrored := _screen != 0
	forget()
	PuppetMenu.clear()
	if mirrored and not transport.was_host:
		# What _enter set for the copies; this machine's own character selection starts solo.
		RunData.play_mode = RunData.PlayMode.SOLO
		RunData.menu_selection_back = false
