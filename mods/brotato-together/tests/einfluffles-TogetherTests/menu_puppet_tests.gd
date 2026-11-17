extends Reference
# The host's menus on a client as the game's own scenes (sync/menu_puppet.gd, the selection
# scenes' script extensions, session/puppet_menu.gd). Host part: this process walks through
# character selection -> weapon selection -> difficulty selection -> end of run like a host
# and keeps what MenuSync and FocusSync would send for each. Client part: the same process
# shows them: the real scene loads, its grids are the host's (not this machine's unlocks), the
# cursors, selections, run options, join progress and pages follow the host, and nothing can
# be decided here (no selection, no way back, no run started, no settings written).
# Last in the selection suite: needs its character selection with two virtual co-op players,
# and leaves no run behind.

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const MenuSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/menu_sync.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const PuppetMenu := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet_menu.gd"
)
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const OnlineLayoutTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/online_layout_tests.gd"
)
const CoopSelectionTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/coop_selection_tests.gd"
)
const CHARACTERS := "character_selection"
const WEAPONS := "weapon_selection"
const DIFFICULTY := "difficulty_selection"
const END_RUN := "coop_end_run"
const END_RUN_SCENE := "res://ui/menus/run/coop_end_run.tscn"

var t: Node = null  # the test mod: _check()
var _menus: Node = null  # MenuPuppet
var _menu_sync: Node = null
var _focus_sync: Node = null
var _coop_selection: Node = null
var _sent := {}  # kind -> {state (with its grids), cursors}
var _host := {}  # what the host's screens showed, to compare with


func run(test_mod: Node, together: Node):
	t = test_mod
	_menus = together.menu_puppet
	_menu_sync = together.menu_sync
	_focus_sync = together.focus_sync
	_coop_selection = together.coop_selection
	_menu_sync.set_process(false)
	var settings := _settings()
	var players: Array = CoopService.connected_players.duplicate(true)
	if _tree().current_scene.filename != MenuData.character_selection_scene:
		t._check(false, "menu copies: character selection scene present")
		yield(_frames(1), "completed")
		return
	yield(_host_part(), "completed")
	yield(_client_characters(), "completed")
	yield(_client_weapons(), "completed")
	yield(_client_difficulty(), "completed")
	yield(_client_end_run(), "completed")
	t._check(_settings() == settings, "no setting of this machine was written (%s)" % [_settings()])
	_menus.forget()
	PuppetMenu.clear()
	Puppet.set_active(false)
	SoundRelay.set_muted(false)
	CoopService.bt_clear_remote_colors()
	CoopService.connected_players = players
	RunData.reset()
	_menu_sync.set_process(true)
	yield(_frames(1), "completed")


func _tree() -> SceneTree:
	return t.get_tree()


func _frames(count: int):
	for _i in count:
		yield(_tree(), "idle_frame")


static func _settings() -> Array:
	var settings: Dictionary = ProgressData.settings
	return [settings.zone_selected, settings.zone_is_random, settings.endless_mode_toggled]


# --- host ---


func _host_part():
	var scene := _tree().current_scene
	var elements := MenuSync._elements_of(scene._get_inventories()[0])
	var free := []
	var locked: InventoryElement = null
	for element in elements:
		if element.is_random or element.item == null:
			continue
		if element.is_special and element.item.is_locked:
			locked = element if locked == null else locked
		elif not element.is_special:
			free.append(element)
	if free.size() < 2:
		t._check(false, "menu copies: two unlocked characters on the host")
		yield(_frames(1), "completed")
		return
	_host["first"] = free[0].item.my_id
	_host["second"] = free[1].item.my_id
	_host["locked"] = locked.item.my_id if locked != null else ""
	Utils.get_focus_emulator(0, scene).focused_control = free[0]
	Utils.get_focus_emulator(1, scene).focused_control = free[1]
	# The press the client part repeats on its copy: on the host it selects.
	FocusEmulatorSignal.emit(free[0], "pressed", 0)
	t._check(
		scene._has_player_selected[0] and scene._player_characters[0] != null,
		"host: a press selects the character"
	)
	scene._clear_selected_element(0)
	scene._has_player_selected[1] = true
	CoopService.listening_for_inputs = true
	CoopService.connection_progress = [0.5]
	_capture(CHARACTERS)
	t._check(_sent[CHARACTERS].state.get("join") == [0.5], "host: join progress in the state")
	CoopService.connection_progress = []
	CoopService.listening_for_inputs = false

	# Both pick the first character; the game's own way on from here.
	var character = free[0].item
	for p in 2:
		RunData.add_character(character, p)
	_tree().change_scene(MenuData.weapon_selection_scene)
	yield(_frames(3), "completed")
	scene = _tree().current_scene
	var grids: Array = scene._get_inventories()
	var weapon = MenuSync._elements_of(grids[0])[-1]
	Utils.get_focus_emulator(0, scene).focused_control = weapon
	FocusEmulatorSignal.emit(MenuSync._elements_of(grids[1])[-1], "pressed", 1)
	t._check(
		scene._has_player_selected[1] and not scene._player_weapons[1].empty(),
		"host: a press picks the weapon"
	)
	scene._clear_selected_element(1)
	scene._has_player_selected[0] = true
	_host["weapon"] = weapon.item.my_id
	_capture(WEAPONS)
	var weapons_sent: Dictionary = _sent[WEAPONS].state
	t._check(
		weapons_sent.grids.inventories.size() == 2 and weapons_sent.selected == [true, false],
		"host: a weapon grid per player, who selected (%s)" % [weapons_sent.selected]
	)
	t._check(
		typeof(weapons_sent.grids.get("run")) == TYPE_DICTIONARY and weapons_sent.has("picks"),
		"host: the weapon selection comes with the run and the picks"
	)
	var packed: Dictionary = _menu_sync.grids_state().run
	t._check(
		_menu_sync.grids_state().run == packed and _menu_sync._run_screen == scene.get_instance_id(),
		"host: the run is packed once per screen"
	)

	for p in 2:
		t._check(RunData.add_weapon(weapon.item, p, true) != null, "host: P%d's weapon" % (p + 1))
	RunData.add_starting_items_and_weapons()
	_tree().change_scene(MenuData.difficulty_selection_scene)
	yield(_frames(3), "completed")
	_capture(DIFFICULTY)

	RunData.current_wave = 7
	RunData.run_won = true
	_tree().change_scene(END_RUN_SCENE)
	yield(_frames(3), "completed")
	scene = _tree().current_scene
	scene.player_containers[1].carousel.index = 1
	yield(_frames(1), "completed")
	scene.player_containers[1].focus()  # what the game does after a page change
	yield(_frames(1), "completed")
	_host["items"] = RunData.get_player_items(0).size()
	_capture(END_RUN)
	t._check(_sent[END_RUN].state.get("pages") == [0, 1], "host: end-of-run pages in the state")
	RunData.run_won = false


# What a client gets for the host's current screen: the menu state with its grids, and the
# cursors (through var2bytes like the wire).
func _capture(kind: String) -> void:
	var scene := _tree().current_scene
	t._check(_menu_sync._track_scene(), "host: %s is mirrored" % kind)
	var state: Dictionary = _menu_sync._state()
	t._check(state.kind == kind, "host: screen kind %s" % state.kind)
	state["you"] = 1
	state["grids"] = _menu_sync.grids_state()
	var cursors = null
	if _focus_sync.state_key(StateStream.CURSORS) != "":
		cursors = _focus_sync.state_body(StateStream.CURSORS)
	_sent[kind] = bytes2var(var2bytes({"state": state, "cursors": cursors}), false)
	_host[kind] = scene.get_instance_id()


# --- client ---


# Shows what the host sent for a screen and waits for the copy. Returns it (null: none).
func _show(kind: String, state: Dictionary):
	var before := _tree().current_scene
	t._check(_menus.show(state), "%s: the host's screen has a copy here" % kind)
	for _i in 30:
		yield(_tree(), "idle_frame")
		if _menus.current() != null:
			break
	yield(_frames(3), "completed")  # the scene's deferred first focus
	var scene: Node = _menus.current()
	t._check(
		scene != null and scene != before and scene.filename == _menus.SCENES[kind],
		"%s: it is the game's own scene" % kind
	)
	if scene != null:
		var glass: Node = scene.get_node_or_null(_menus.GLASS)
		t._check(
			glass != null and glass.get_index() == scene.get_child_count() - 1
			and glass.mouse_filter == Control.MOUSE_FILTER_STOP,
			"%s: the mouse does not reach its controls" % kind
		)
	return scene


func _cursors(kind: String, scene: Node) -> void:
	var body = _sent[kind].cursors
	var landed: bool = (
		typeof(body) == TYPE_DICTIONARY and _focus_sync.apply_state(StateStream.CURSORS, body, 1)
	)
	t._check(landed, "%s: the host's cursors land on the copy" % kind)
	if landed or typeof(body) != TYPE_DICTIONARY:
		return
	for cursor in body.cursors:
		var control = _focus_sync.FocusTargets.resolve(cursor[2], scene)
		var shown: bool = control is Control and control.is_visible_in_tree()
		print("  info: cursor %s -> %s (visible: %s)" % [cursor, control, shown])


static func _ids(inventory: Node) -> Array:
	var ids := []
	for element in MenuSync._elements_of(inventory):
		ids.append(element.item.my_id if element.item != null else "")
	return ids


static func _sent_ids(entries: Array) -> Array:
	var ids := []
	for entry in entries:
		ids.append(entry[0])
	return ids


func _element(inventory: Node, my_id: String) -> InventoryElement:
	for element in MenuSync._elements_of(inventory):
		if element.item != null and element.item.my_id == my_id and not element.is_random:
			return element
	return null


func _client_characters():
	var state: Dictionary = _sent[CHARACTERS].state.duplicate(true)
	var entries: Array = state.grids.inventories[0]
	# The host's grid, not this machine's: one unlocked character is locked there, a locked one
	# unlocked, the last element missing, and another zone and tier.
	var dropped: String = entries.pop_back()[0]
	var zones := []
	for zone in ZoneService.zones:
		zones.append(zone.my_id)
	var zone: int = zones[-1]
	state["zone"] = [zone, false]
	state["endless"] = not ProgressData.settings.endless_mode_toggled
	for entry in entries:
		if entry[0] == _host.second:
			entry[1] |= MenuSync.FLAG_LOCKED | MenuSync.FLAG_SPECIAL
		elif entry[0] == _host.locked and _host.locked != "":
			entry[1] = 0
		elif entry[0] == _host.first:
			entry[2] = 3
	var scene: Node = yield(_show(CHARACTERS, state), "completed")
	if scene == null:
		return
	t._check(Puppet.is_active() and SoundRelay.is_muted(), "characters: mirroring, own sounds off")
	t._check(
		CoopService.connected_players.size() == 2 and RunData.get_player_count() == 2
		and RunData.is_coop_run and not CoopService.listening_for_inputs,
		"characters: the host's two players, nobody joins here"
	)
	var grid: Node = scene._get_inventories()[0]
	t._check(
		_ids(grid) == _sent_ids(entries) and not (dropped in _ids(grid).slice(1, 999)),
		"characters: the host's elements in the host's order"
	)
	var first := _element(grid, _host.first)
	var second := _element(grid, _host.second)
	t._check(
		second != null and second.is_special and second.item.is_locked
		and first != null and not first.is_special,
		"characters: locked where the host has it locked"
	)
	if _host.locked != "":
		var unlocked := _element(grid, _host.locked)
		t._check(
			unlocked != null and not unlocked.is_special,
			"characters: unlocked where the host has it, whatever is unlocked here"
		)
	else:
		print("  info: every character unlocked here; host-unlocked check skipped")
	t._check(first != null and first.item.tier == 3, "characters: the host's danger colours")
	var button: OptionButton = scene._zone_selection_button
	var offered := false
	for i in scene._random_zone_index:
		offered = offered or button.get_item_id(i) == zone
	t._check(
		RunData.current_zone == zone
		and scene._background.texture == ZoneService.get_zone_data(zone).ui_background
		and (not offered or button.get_selected_id() == zone),
		"characters: the host's zone (%d of %s)" % [zone, zones]
	)
	t._check(
		scene._endless_button.pressed == state.endless and RunData.is_endless_run == state.endless,
		"characters: the host's endless toggle"
	)

	_cursors(CHARACTERS, scene)
	yield(_frames(2), "completed")
	var panels: Array = scene._get_panels()
	t._check(
		Utils.get_focus_emulator(0, scene).focused_control == first
		and panels[0].visible and panels[0].item_data != null
		and panels[0].item_data.my_id == _host.first,
		"characters: P1's panel shows what its cursor is on"
	)
	t._check(
		scene._get_locked_panels()[1].visible and not panels[1].visible,
		"characters: P2's cursor is on a locked character: the game's locked panel"
	)
	t._check(
		scene._has_player_selected[1] and panels[1].selected and not scene._has_player_selected[0],
		"characters: who selected"
	)
	var join: Array = scene._get_coop_join_panels()
	t._check(
		join[2].visible and join[2]._coop_join_progress.visible
		and join[2]._coop_join_progress.progress >= 50.0,
		"characters: a joining player's hold progress in the next free slot"
	)
	t._check(join[3].instructions_visible, "characters: the last slot offers to join")
	yield(_check_join_fill(state, join[2]._coop_join_progress), "completed")
	var hint := CoopSelectionTests.new()  # kept by this function while it waits
	yield(hint.check_hint_layout(t, _coop_selection, scene, "client"), "completed")
	var layout := OnlineLayoutTests.new()  # kept by this function while it waits
	yield(layout.run(t, scene, "client"), "completed")

	# Nothing is decided here.
	FocusEmulatorSignal.emit(first, "pressed", 0)
	t._check(
		not scene._has_player_selected[0] and scene._player_characters[0] == null,
		"characters: a press selects nothing"
	)
	scene._on_BackButton_pressed()
	scene._go_back()
	scene._on_coop_initialized(false, false)
	scene._on_ZoneSelectionButton_item_selected(0)
	scene._back_button.grab_focus()
	var everybody: Dictionary = state.duplicate(true)
	everybody["selected"] = [true, true]
	everybody["zone"] = [zones[0], true]
	t._check(_menus.show(everybody), "characters: a later state")
	yield(_frames(3), "completed")
	t._check(
		_tree().current_scene == scene and RunData.is_coop_run
		and scene._selections_completed_timer.is_stopped()
		and RunData.get_player_character(0) == null,
		"characters: no way back, no solo mode, and everybody selected ends nothing here"
	)
	t._check(
		scene._has_player_selected[0] and panels[0].selected,
		"characters: the new selection shows"
	)
	t._check(
		scene._background.texture == scene._ui_random_zone_background.texture
		and button.selected == scene._random_zone_index,
		"characters: the host's random zone"
	)
	t._check(scene.get_focus_owner() == null, "characters: no control keeps the keyboard focus")
	t._check(not CoopService.listening_for_inputs, "characters: still nobody joins here")

	# A third player joins on the host, and leaves again.
	var three: Dictionary = state.duplicate(true)
	three["count"] = 3
	three["selected"] = [false, true, false]
	three.erase("join")
	t._check(_menus.show(three), "characters: a third player")
	yield(_frames(2), "completed")
	t._check(
		CoopService.connected_players.size() == 3 and RunData.get_player_count() == 3
		and panels[2].player_color_index == 2 and not join[2].visible,
		"characters: the third slot is a player"
	)
	t._check(not join[3].instructions_visible, "characters: joining closed, no hint")
	t._check(_menus.show(state), "characters: back to two")
	yield(_frames(2), "completed")
	t._check(
		CoopService.connected_players.size() == 2 and _menus.current() == scene,
		"characters: two players again, on the same copy"
	)


# The host's join progress comes ten times a second: the wheel fills here in between, a late
# state does not turn it back, a lower one is a new hold.
func _check_join_fill(state: Dictionary, wheel: Node):
	var restart: Dictionary = state.duplicate(true)
	restart["join"] = [0.1]
	t._check(_menus.show(restart), "characters: a new hold")
	t._check(is_equal_approx(wheel.progress, 10.0), "characters: a new hold starts the wheel over")
	for _i in 60:
		yield(_tree(), "idle_frame")
		if wheel.progress > 10.0:
			break
	var filled: float = wheel.progress
	t._check(filled > 10.0, "characters: the wheel fills between the host's states (%s)" % filled)
	var late: Dictionary = state.duplicate(true)
	late["join"] = [0.1 + (filled - 10.0) / 200.0]
	t._check(_menus.show(late), "characters: a state behind the wheel")
	t._check(wheel.progress >= filled, "characters: the wheel does not run back")
	t._check(_menus.show(state), "characters: the hold progress as before")


func _client_weapons():
	var state: Dictionary = _sent[WEAPONS].state.duplicate(true)
	var scene: Node = yield(_show(WEAPONS, state), "completed")
	if scene == null:
		return
	t._check(CoopService.bt_remote_progress == null, "weapons: no join progress any more")
	t._check(
		RunData.get_player_count() == 2 and RunData.get_player_character(1) != null
		and RunData.get_player_character(1).my_id == _host.first,
		"weapons: the players' characters are the host's"
	)
	var grids: Array = scene._get_inventories()
	var same := true
	for p in 2:
		same = same and _ids(grids[p]) == _sent_ids(state.grids.inventories[p])
	t._check(same, "weapons: each player's grid is the host's")
	_cursors(WEAPONS, scene)
	yield(_frames(2), "completed")
	var weapon := _element(grids[0], _host.weapon)
	t._check(
		weapon != null and Utils.get_focus_emulator(0, scene).focused_control == weapon,
		"weapons: P1's cursor is on the host's weapon"
	)
	t._check(
		scene._has_player_selected[0] and scene._get_panels()[0].selected
		and not scene._has_player_selected[1],
		"weapons: who selected, also after the cursor arrived"
	)
	var other: InventoryElement = MenuSync._elements_of(grids[1])[-1]
	FocusEmulatorSignal.emit(other, "pressed", 1)
	scene._on_BackButton_pressed()
	yield(_frames(2), "completed")
	t._check(
		scene._player_weapons[1].empty() and not scene._has_player_selected[1]
		and _tree().current_scene == scene and RunData.get_player_weapons(1).empty(),
		"weapons: a press picks nothing, no way back"
	)


func _client_difficulty():
	var state: Dictionary = _sent[DIFFICULTY].state.duplicate(true)
	var entries: Array = state.grids.inventories[0]
	entries[-1][1] |= MenuSync.FLAG_LOCKED | MenuSync.FLAG_SPECIAL
	entries[0][1] = 0
	var scene: Node = yield(_show(DIFFICULTY, state), "completed")
	if scene == null:
		return
	var grid: Node = scene._get_inventories()[0]
	var elements := MenuSync._elements_of(grid)
	t._check(
		_ids(grid) == _sent_ids(entries) and elements[-1].is_special
		and not elements[0].is_special,
		"difficulty: the host's levels, locked where the host has them locked"
	)
	t._check(
		not RunData.get_player_weapons(0).empty()
		and RunData.get_player_weapons(0)[0].my_id == _host.weapon,
		"difficulty: the run is the host's (the picked weapons)"
	)
	_cursors(DIFFICULTY, scene)
	var difficulty: int = RunData.current_difficulty
	FocusEmulatorSignal.emit(elements[0], "pressed", 0)
	yield(_frames(2), "completed")
	t._check(
		_tree().current_scene == scene and not scene.difficulty_selected
		and RunData.current_difficulty == difficulty,
		"difficulty: a press starts no run"
	)


func _client_end_run():
	var state: Dictionary = _sent[END_RUN].state.duplicate(true)
	var scene: Node = yield(_show(END_RUN, state), "completed")
	if scene == null:
		return
	t._check(
		RunData.run_won and RunData.current_wave == 7
		and scene._title.text.begins_with(scene.tr("RUN_WON")),
		"end of run: the host's result (%s)" % scene._title.text
	)
	var containers: Array = scene.player_containers
	t._check(
		containers[0].visible and containers[1].visible and not containers[2].visible
		and RunData.get_player_items(0).size() == _host.items,
		"end of run: the host's players and their items"
	)
	t._check(containers[1].carousel.index == 1, "end of run: P2 looks at its stats page")
	_menus._apply_pages(scene, [0, 3])
	var page = containers[1].carousel.get_node("%Content").get_node_or_null("DamagePage")
	t._check(
		containers[1].carousel.index == 3 and page != null and page.visible,
		"end of run: the host's page 3 shows P2's damage page on the client"
	)
	_menus._apply_pages(scene, [0, 1])
	_cursors(END_RUN, scene)
	scene._on_NewRunButton_pressed()
	scene._on_RestartButton_pressed()
	scene._on_ExitButton_pressed()
	yield(_frames(2), "completed")
	t._check(_tree().current_scene == scene, "end of run: its buttons are the host's")

	# A screen without a copy (the title screen), junk, and a run screen without its run.
	t._check(
		not _menus.show({"kind": "title_screen", "screen": 1, "count": 0, "grids": {}})
		and _menus.current() == null,
		"no copy of the title screen: the waiting screen's turn"
	)
	var broken: Dictionary = _sent[WEAPONS].state.duplicate(true)
	broken.grids.erase("run")
	t._check(not _menus.show(broken), "a run screen without its run is not entered")
	var junk: Dictionary = _sent[CHARACTERS].state.duplicate(true)
	junk.grids["inventories"] = [[["x", 0], "junk", [1, 2, 3], ["not_a_real_id", 0, 0]], "junk"]
	junk["screen"] = -5
	junk["selected"] = "junk"
	junk["zone"] = ["a", 1]
	junk["join"] = ["x", 7.0]
	scene = yield(_show(CHARACTERS, junk), "completed")
	if scene != null:
		t._check(
			_ids(scene._get_inventories()[0]).empty(),
			"junk grids and ids this machine does not know show nothing"
		)
