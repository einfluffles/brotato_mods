extends Reference
# Selection screens, one screen per machine (ui/shared_scroll.gd, sync/menu_puppet.gd,
# ui/coop_selection.gd): the grid scrolls after this machine's own players only. Last in the
# selection suite: sets up its own scenes and leaves no run behind.

const MenuSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/menu_sync.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const PuppetMenu := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet_menu.gd"
)
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const SharedScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/shared_scroll.gd")
const CoopSelection := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_selection.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const WheelScrollTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/wheel_scroll_tests.gd"
)
const KEYBOARD := 7  # CoopService.KEYBOARD_REMAPPED_DEVICE_ID
const INFO := "ui_info"  # CoopShowCharacterHint.UI_ACTION

var t: Node = null
var _menus: Node = null
var _menu_sync: Node = null
var _input_sync: Node = null
var _scroll_sync: Node = null
var _wheel = null  # kept alive across its yields
# [players, elements the copy builds its grid from] at each connected_players_updated. Not the
# grid itself: Godot 3 calls the handlers of a signal in no fixed order.
var _updates := []


func run(test_mod: Node, together: Node):
	t = test_mod
	_menus = together.menu_puppet
	_menu_sync = together.menu_sync
	_input_sync = together.input_sync
	_scroll_sync = together.scroll_sync
	_wheel = WheelScrollTests.new(t)
	_menu_sync.set_process(false)
	var players: Array = CoopService.connected_players.duplicate(true)
	var host: Dictionary = yield(_host_characters(), "completed")
	if not host.empty():
		yield(_client_characters(host), "completed")
		yield(_client_first_player(host), "completed")
	_forget()
	var weapons: Dictionary = yield(_host_weapons(), "completed")
	if not weapons.empty():
		yield(_client_weapons(weapons), "completed")
	_forget()
	CoopService.connected_players = players
	RunData.reset()
	_menu_sync.set_process(true)
	yield(_frames(1), "completed")


func _tree() -> SceneTree:
	return t.get_tree()


func _frames(count: int):
	for _i in count:
		yield(_tree(), "idle_frame")


func _forget() -> void:
	_menus.forget()
	PuppetMenu.clear()
	Puppet.set_active(false)
	SoundRelay.set_muted(false)
	CoopService.bt_clear_remote_colors()
	CoopService.bt_remote_progress = null


# The host's screen with two remote players (virtual devices), and its state as a client gets it.
func _host_screen(path: String, run_ready: bool):
	_tree().change_scene(path)
	yield(_frames(2), "completed")
	if not run_ready:
		RunData.set_coop_run(true)
		CoopService.clear_coop_players()
		for i in 2:
			CoopService._add_player(VirtualDevices.FIRST + i, CoopService.PlayerType.GAMEPAD_XBOX)
	yield(_frames(3), "completed")
	return _tree().current_scene


func _capture(scene: Node, you: int) -> Dictionary:
	_menu_sync._scene = scene
	var state: Dictionary = _menu_sync._state()
	state["you"] = you
	state["grids"] = _menu_sync.grids_state()
	return bytes2var(var2bytes(state), false)


# Shows a state and waits for its copy (null: none).
func _show(state: Dictionary):
	t._check(_menus.show(state), "%s: the host's screen has a copy here" % state.kind)
	for _i in 30:
		yield(_tree(), "idle_frame")
		if _menus.current() != null:
			break
	yield(_frames(3), "completed")  # the scene's deferred first focus
	return _menus.current()


static func _last(grid: Node) -> Control:
	var elements := MenuSync._elements_of(grid)
	return elements[-1] if not elements.empty() else null


static func _first(grid: Node) -> Control:
	var elements := MenuSync._elements_of(grid)
	return elements[0] if not elements.empty() else null


# Whether moving player's cursor to the last element scrolls the grid (from the top).
func _scrolls(scene: Node, player: int) -> bool:
	var scroll: ScrollContainer = scene._get_wheel_grid()
	var grid: Node = scene._get_inventories()[0]
	var emulator = Utils.get_focus_emulator(player, scene)
	emulator.focused_control = _first(grid)
	scroll.scroll_vertical = 0
	emulator.focused_control = _last(grid)
	var moved := scroll.scroll_vertical != 0
	emulator.focused_control = _first(grid)
	scroll.scroll_vertical = 0
	return moved


func _scrollable(scene: Node) -> bool:
	var scroll: ScrollContainer = scene._get_wheel_grid()
	var room: float = scroll.get_v_scrollbar().max_value - scroll.rect_size.y
	if room <= 0.0:
		t._check(false, "scroll: the character grid is taller than its box (%s)" % room)
	return room > 0.0


# The whole grid fits its box at 1920x1080: a spacer under the title shortens the box, so the
# grid scrolls as a longer character list would.
func _shorten_grid_box(scene: Node):
	var spacer := Control.new()
	spacer.name = "TestsGridSpacer"
	spacer.rect_min_size = Vector2(0, 80)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title: Node = scene.get_node("MarginContainer/VBoxContainer/Title")
	title.get_parent().add_child_below_node(title, spacer)
	yield(_frames(2), "completed")


func _host_characters():
	var scene: Node = yield(_host_screen(MenuData.character_selection_scene, false), "completed")
	if not CoopSelection.is_character_selection(scene):
		return {}
	yield(_shorten_grid_box(scene), "completed")
	if not _scrollable(scene):
		return {}
	t._check(_scrolls(scene, 0), "scroll: host without own players follows the remote cursors")
	CoopService._add_player(KEYBOARD, CoopService.PlayerType.KEYBOARD_AND_MOUSE)
	yield(_frames(2), "completed")
	t._check(
		not _scrolls(scene, 0) and not _scrolls(scene, 1),
		"scroll: a remote player's cursor deep in the grid does not scroll the host's screen"
	)
	t._check(_scrolls(scene, 2), "scroll: the host's own player's cursor does")
	yield(_wheel.host_selection(scene, _scroll_sync), "completed")
	var online: Array = CoopService.connected_players.duplicate(true)
	CoopService.connected_players = [
		[0, CoopService.PlayerType.GAMEPAD_XBOX], [1, CoopService.PlayerType.GAMEPAD_XBOX]
	]
	t._check(_scrolls(scene, 0) and _scrolls(scene, 1), "scroll: local co-op scrolls for everybody")
	CoopService.connected_players = online
	CoopService._remove_player(KEYBOARD)
	yield(_frames(2), "completed")
	yield(_locked_cursor(scene), "completed")
	yield(_pick_leaves(scene), "completed")
	var state := _capture(scene, 1)
	state["join"] = []  # the host lets players join: the empty slots show the hint
	return {"state": state, "screen": scene.get_instance_id()}


# A locked-in player's cursor stays on the pick until cancel (extensions/ui/focus_emulator.gd).
func _locked_cursor(scene: Node):
	var grid: Node = scene._get_inventories()[0]
	var emulator = Utils.get_focus_emulator(0, scene)
	var pick := _first(grid)
	emulator.focused_control = pick
	scene._set_selected_element(0)
	yield(_nav(VirtualDevices.FIRST, "ui_right"), "completed")
	t._check(emulator.focused_control == pick, "locked in: the cursor stays on the pick")
	scene._clear_selected_element(0)
	yield(_nav(VirtualDevices.FIRST, "ui_right"), "completed")
	t._check(emulator.focused_control != pick, "after cancel: the cursor moves again")
	emulator.focused_control = pick


# A player who leaves after locking in takes the pick along (extensions/ui/character_selection.gd):
# whoever has the slot next starts free, not locked in on the old character.
func _pick_leaves(scene: Node):
	var pick: Control = MenuSync._elements_of(scene._get_inventories()[0])[1]
	var first: int = VirtualDevices.FIRST
	var last: int = VirtualDevices.FIRST + 1
	_lock_in(scene, 1, pick)
	CoopService._remove_player(last)
	yield(_frames(2), "completed")
	CoopService._add_player(last, CoopService.PlayerType.GAMEPAD_XBOX)
	yield(_frames(3), "completed")  # the new player's deferred first focus
	t._check(_free(scene, 1), "left after locking in: the player back in that slot is free")
	var emulator = Utils.get_focus_emulator(1, scene)
	var before = emulator.focused_control
	yield(_nav(last, "ui_right"), "completed")
	t._check(emulator.focused_control != before, "and its cursor moves")
	_lock_in(scene, 1, pick)
	CoopService._remove_player(first)
	yield(_frames(2), "completed")
	t._check(
		_free(scene, 0) and _free(scene, 1),
		"the slot before leaves: the player moving up is free, and so is the slot it left"
	)
	CoopService._remove_player(last)
	CoopService._add_player(first, CoopService.PlayerType.GAMEPAD_XBOX)
	CoopService._add_player(last, CoopService.PlayerType.GAMEPAD_XBOX)
	yield(_frames(3), "completed")


static func _lock_in(scene: Node, player: int, pick: Control) -> void:
	Utils.get_focus_emulator(player, scene).focused_control = pick
	scene._player_characters[player] = pick.item
	scene._set_selected_element(player)


static func _free(scene: Node, player: int) -> bool:
	return not scene._has_player_selected[player] and scene._player_characters[player] == null


func _nav(device: int, action: String):
	for pressed in [true, false]:
		VirtualDevices.press_button(VirtualDevices.action(action, device), device, pressed)
		yield(_frames(2), "completed")


func _client_characters(host: Dictionary):
	var scene: Node = yield(_show(host.state.duplicate(true)), "completed")
	if scene == null:
		return
	yield(_shorten_grid_box(scene), "completed")
	if not _scrollable(scene):
		return
	t._check(
		CoopService.connected_players.size() == 2 and SharedScroll.own_player() == 1,
		"scroll: the copy knows this machine's player (2 of 2)"
	)
	t._check(
		not _scrolls(scene, 0),
		"scroll: a mirrored cursor deep in the grid does not scroll the client's screen"
	)
	t._check(_scrolls(scene, 1), "scroll: the client's own player's cursor does")
	yield(_wheel.client_selection(scene, _input_sync, _scroll_sync), "completed")
	yield(_frames(2), "completed")
	var apart := true
	var shown := true
	for panel in scene._get_coop_join_panels().slice(2, 3):
		var label: Control = panel.get_node_or_null(CoopSelection.SLOT_LABEL)
		var hint: Control = panel._coop_join_instructions
		shown = shown and label != null and hint.is_visible_in_tree()
		apart = apart and label != null and not label.get_global_rect().intersects(
			hint.get_global_rect()
		) and label.get_global_rect().end.y <= hint.get_global_rect().position.y
	t._check(shown, "slot label: the copy's empty slots show the label and the join hint")
	t._check(apart, "slot label: above the hint on the client's copy, not over it")


# The client joins while nobody has joined on the host: its copy starts without players and
# without a grid; the host's player 1 then joins, its state ahead of the grids that carry the grid.
func _client_first_player(host: Dictionary):
	var empty: Dictionary = host.state.duplicate(true)
	empty["screen"] = host.screen + 1  # another screen of the host
	empty["count"] = 0
	empty["selected"] = []
	empty.grids["inventories"] = []
	var scene: Node = yield(_show(empty), "completed")
	if scene == null:
		return
	var grid: Node = scene._get_inventories()[0]
	CoopService.connect("connected_players_updated", self, "_on_players_updated")
	var one: Dictionary = empty.duplicate(true)
	one["count"] = 1
	one["selected"] = [false]
	t._check(_menus.show(one), "first player: the host's state names player 1")
	yield(_frames(2), "completed")
	var grids: Dictionary = one.duplicate(true)
	grids.grids["inventories"] = host.state.grids.inventories
	t._check(_menus.show(grids), "first player: then the grid arrives")
	yield(_frames(3), "completed")
	CoopService.disconnect("connected_players_updated", self, "_on_players_updated")
	var on_empty := []
	for update in _updates:
		if update[0] > 0 and update[1] == 0:
			on_empty.append(update)
	t._check(
		on_empty.empty() and not _updates.empty(),
		"first player: never added while the grid is empty (players, elements: %s)" % [_updates]
	)
	var cursor = Utils.get_focus_emulator(0, scene).focused_control
	t._check(
		CoopService.connected_players.size() == 1 and cursor != null and cursor.get_parent() == grid,
		"first player: has a cursor in the grid"
	)


func _on_players_updated(players: Array) -> void:
	_updates.append([players.size(), PuppetMenu.elements(0).size()])


func _host_weapons():
	RunData.reset()
	RunData.set_coop_run(true)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService._add_player(VirtualDevices.FIRST + i, CoopService.PlayerType.GAMEPAD_XBOX)
	RunData.set_player_count(2)
	for i in 2:
		RunData.add_character(ItemService.characters[i], i)
	var scene: Node = yield(_host_screen(MenuData.weapon_selection_scene, true), "completed")
	for p in 2:
		if not RunData.player_has_weapon_slots(p):
			t._check(false, "show character: P%d has weapon slots" % (p + 1))
			return {}
	# The first element is the random one (no item in the panel): P2 goes to a weapon.
	Utils.get_focus_emulator(1, scene).focused_control = _last(scene._get_inventories()[1])
	yield(_frames(1), "completed")
	var panel = scene._get_panels()[1]
	var character = RunData.get_player_character(1)
	var weapon = panel.item_data
	t._check(
		weapon != null and not MenuSync.shows_character(panel, character),
		"show character: the host's P2 panel shows the weapon under the cursor (%s)"
		% (weapon.my_id if weapon != null else "nothing")
	)
	var device: int = VirtualDevices.FIRST + 1
	VirtualDevices.press_button(VirtualDevices.action(INFO, device), device, true)
	yield(_frames(2), "completed")
	t._check(
		MenuSync.shows_character(panel, character) and not panel.selected,
		"show character: P2 holds ui_info on the host: its panel shows the character"
	)
	var held := _capture(scene, 1)
	t._check(
		held.get("character_shown") == [false, true],
		"show character: in the host's state (%s)" % [held.get("character_shown")]
	)
	VirtualDevices.press_button(VirtualDevices.action(INFO, device), device, false)
	yield(_frames(2), "completed")
	var released := _capture(scene, 1)
	t._check(
		released.get("character_shown") == [false, false] and panel.item_data == weapon,
		"show character: released, the host's panel shows the weapon again"
	)
	return {"held": held, "released": released, "weapon": weapon.my_id}


func _client_weapons(host: Dictionary):
	var scene: Node = yield(_show(host.released.duplicate(true)), "completed")
	if scene == null:
		return
	var panels: Array = scene._get_panels()
	var characters := [RunData.get_player_character(0), RunData.get_player_character(1)]
	# P2's cursor where the host has it (FocusSync sets it like this).
	Utils.get_focus_emulator(1, scene).focused_control = _last(scene._get_inventories()[1])
	yield(_frames(1), "completed")
	t._check(
		panels[1].item_data != null and panels[1].item_data.my_id == host.weapon,
		"show character: the copy's P2 panel shows the weapon under the cursor"
	)
	t._check(_menus.show(host.held.duplicate(true)), "show character: the held state")
	yield(_frames(2), "completed")
	t._check(
		MenuSync.shows_character(panels[1], characters[1])
		and not MenuSync.shows_character(panels[0], characters[0]),
		"show character: the client's own player (P2) sees its character on the copy"
	)
	t._check(_menus.show(host.released.duplicate(true)), "show character: the released state")
	yield(_frames(2), "completed")
	t._check(
		panels[1].item_data != null and panels[1].item_data.my_id == host.weapon,
		"show character: released, the copy shows the focused weapon again"
	)
	var other: Dictionary = host.held.duplicate(true)
	other["character_shown"] = [true, false]
	other["selected"] = [true, false]
	t._check(_menus.show(other), "show character: P1 selected holds ui_info")
	yield(_frames(2), "completed")
	t._check(
		MenuSync.shows_character(panels[0], characters[0]) and not panels[0].selected
		and scene._has_player_selected[0],
		"show character: another player's character on the copy, its panel not selected"
	)
	other["character_shown"] = [false, false]
	t._check(_menus.show(other), "show character: P1 releases")
	yield(_frames(2), "completed")
	t._check(
		not MenuSync.shows_character(panels[0], characters[0]) and panels[0].selected,
		"show character: released, P1's weapon again and still selected"
	)
