extends Reference
# Co-op character selection UX (ui/coop_selection.gd, CoopService extension, client view):
#  - every empty slot shows "Player N" (above it) + the game's hold-to-join hint;
#  - players cycle their colour with ui_info (virtual device = remote player, keyboard F), never
#    onto another player's colour; the colours travel in the menu state, BATTLE_START and the
#    shop state
#    and the game's own colour code (cursors, labels, highlight) reads them;
#  - a locked character under a cursor shows how to unlock it (the client's copy of the screen:
#    menu_puppet_tests.gd).
# Needs the character selection scene with two virtual co-op players (after the menu tests).

const CoopSelection := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_selection.gd"
)
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const KEYBOARD := 7  # CoopService.KEYBOARD_REMAPPED_DEVICE_ID

var t: Node = null  # the test mod: _check()


func run(test_mod: Node, together: Node):
	t = test_mod
	t.set_meta("coop_selection_tests", self)  # kept alive across its yields
	var scene := _tree().current_scene
	if not CoopSelection.is_character_selection(scene):
		t._check(false, "coop selection: character selection scene present")
		yield(_frames(1), "completed")
		return
	together.menu_sync.set_process(false)
	CoopService.listening_for_inputs = true
	# The loopback tests ran this process as a client too (BATTLE_START and shop state colours).
	CoopService.bt_clear_remote_colors()
	yield(_frames(2), "completed")
	_test_join_hints(scene)
	yield(_test_color_picks(scene), "completed")
	_test_color_mirror(together, scene)
	yield(_test_locked(scene), "completed")
	CoopService.listening_for_inputs = false
	together.menu_sync.set_process(true)
	yield(_frames(1), "completed")
	t.remove_meta("coop_selection_tests")


func _tree() -> SceneTree:
	return t.get_tree()


func _frames(count: int):
	for _i in count:
		yield(_tree(), "idle_frame")


func _test_join_hints(scene: Node) -> void:
	var count: int = CoopService.connected_players.size()
	var panels: Array = scene._get_coop_join_panels()
	t._check(panels.size() == 4 and count == 2, "join hints: 4 slots, 2 players (%d)" % count)
	var ok := true
	for i in panels.size():
		var empty: bool = i >= count
		var label: Label = panels[i].get_node_or_null(CoopSelection.SLOT_LABEL)
		ok = ok and panels[i].visible == empty and panels[i].instructions_visible == empty
		ok = ok and label != null and label.text != ""
	t._check(ok, "join hints: every empty slot (3 and 4) shows the hold-to-join hint")
	var apart := true
	for i in range(count, panels.size()):
		var label: Control = panels[i].get_node_or_null(CoopSelection.SLOT_LABEL)
		var hint: Rect2 = panels[i]._coop_join_instructions.get_global_rect()
		apart = apart and label != null and not label.get_global_rect().intersects(hint)
		apart = apart and label.get_global_rect().end.y <= hint.position.y
	t._check(apart, "join hints: \"Player N\" sits above the hint, not over it")
	var hint: Control = scene.get_node_or_null(
		"MarginContainer/VBoxContainer/" + CoopSelection.COLOR_HINT
	)
	t._check(hint != null and hint.is_visible_in_tree(), "colour hint shown under the title")


func _press_virtual(device: int):
	VirtualDevices.press_button("ui_info_%d" % device, device, true)
	yield(_frames(2), "completed")
	VirtualDevices.press_button("ui_info_%d" % device, device, false)
	yield(_frames(2), "completed")


func _press_key(scancode: int):
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.scancode = scancode
		event.physical_scancode = scancode
		event.pressed = pressed
		Input.parse_input_event(event)
		yield(_frames(2), "completed")


static func _distinct(slots: Array) -> bool:
	for i in slots.size():
		if slots.find(slots[i]) != i:
			return false
	return true


func _test_color_picks(scene: Node):
	var before: Array = CoopService.bt_slot_colors.duplicate()
	t._check(before == [0, 1, 2, 3], "colours: game defaults before any pick (%s)" % [before])
	yield(_press_virtual(VirtualDevices.FIRST + 1), "completed")
	var slots: Array = CoopService.bt_slot_colors
	t._check(
		slots[1] != before[1] and slots[1] != slots[0] and _distinct(slots),
		"colours: remote P2 picks the next free colour (%s)" % [slots]
	)
	t._check(
		CoopService.player_colors[1] == CoopService.bt_palette[slots[1]],
		"colours: CoopService.player_colors follows the pick"
	)
	var label: Label = scene._get_coop_join_panels()[3].get_node(CoopSelection.SLOT_LABEL)
	t._check(
		label.get_color("font_color") == CoopService.get_player_color(3),
		"colours: empty slot label restyled"
	)
	var all_distinct := true
	for _i in CoopService.bt_palette.size() + 1:
		yield(_press_virtual(VirtualDevices.FIRST + 1), "completed")
		all_distinct = all_distinct and _distinct(CoopService.bt_slot_colors)
		all_distinct = all_distinct and CoopService.bt_slot_colors[1] != CoopService.bt_slot_colors[0]
	t._check(all_distinct, "colours: cycling never takes another player's colour")
	# A local keyboard player joins (3rd slot) and picks with F.
	CoopService._add_player(KEYBOARD, CoopService.PlayerType.KEYBOARD_AND_MOUSE)
	yield(_frames(2), "completed")
	var joined: int = CoopService.bt_slot_colors[2]
	yield(_press_key(KEY_F), "completed")
	slots = CoopService.bt_slot_colors
	t._check(
		CoopService.connected_players.size() == 3 and slots[2] != joined and _distinct(slots),
		"colours: keyboard player picks with F (%d -> %d, %s)" % [joined, slots[2], slots]
	)
	CoopService._remove_player(KEYBOARD)
	yield(_frames(2), "completed")
	t._check(
		CoopService.connected_players.size() == 2 and _distinct(CoopService.bt_slot_colors),
		"colours: still distinct after a player left (%s)" % [CoopService.bt_slot_colors]
	)


func _test_color_mirror(together: Node, scene: Node) -> void:
	var host: Array = CoopService.bt_slot_colors.duplicate()
	var menu_sync: Node = together.menu_sync
	menu_sync._scene = scene
	var state: Dictionary = bytes2var(var2bytes(menu_sync._state()), false)
	t._check(state.get("colors") == host, "colours: in the menu state (%s)" % [state.get("colors")])
	t._check(
		together.battle_host._battle_start_body().get("colors") == host,
		"colours: in BATTLE_START"
	)
	# Client side (same process): the host's colours replace the local ones.
	var remote := [5, 4, 1, 0]
	state["colors"] = remote
	state["you"] = 1
	state["join"] = [0.5]
	menu_sync.apply_state(StateStream.MENU, state, 1)  # the menu section's handler
	t._check(
		CoopService.bt_slot_colors == remote
		and CoopService.player_colors[0] == CoopService.bt_palette[5],
		"colours: client applies the host's colours"
	)
	t._check(not CoopService.bt_cycle_color(0, 1), "colours: no local picks while mirroring")
	for junk in [[0, 0, 1, 2], [0, 1, 2], ["a", 1, 2, 3], [0, 1, 2, 99], "x", null]:
		CoopService.bt_apply_remote_colors(junk)
	t._check(CoopService.bt_slot_colors == remote, "colours: invalid colour lists ignored")
	var label := CoopPlayerLabel.new()
	label.player_index = 1
	t._check(
		label.get_color("font_color") == CoopService.get_player_color(1)
		and CoopService.get_player_color(1).to_html() != CoopService.get_player_color(0).to_html(),
		"colours: the game's own colour code (CoopPlayerLabel) uses them"
	)
	label.free()
	CoopService.bt_clear_remote_colors()
	t._check(CoopService.bt_slot_colors == host, "colours: own colours back after leaving")


func _test_locked(scene: Node):
	var locked: InventoryElement = null
	var free: InventoryElement = null
	for child in scene.get_node("%Inventory1").get_children():
		if not child is InventoryElement or child.is_random or child.item == null:
			continue
		if child.is_special and child.item.is_locked and locked == null:
			locked = child
		elif not child.is_special and free == null:
			free = child
	if locked == null:
		print("  info: every character unlocked; locked-character checks skipped")
		yield(_frames(1), "completed")
		return
	var challenge = ChallengeService.find_challenge_from_reward(RewardType.CHARACTER, locked.item)
	var expected: String = challenge.get_description_text() if challenge != null else "NOT_SET"
	Utils.get_focus_emulator(0, scene).focused_control = free
	Utils.get_focus_emulator(1, scene).focused_control = locked
	yield(_frames(2), "completed")
	var host_locked = scene._get_locked_panels()[1]
	t._check(
		host_locked.visible and not scene._get_panels()[1].visible,
		"locked: host shows the locked panel instead of the description"
	)
	t._check(
		host_locked._description.text == expected,
		"locked: host panel text is the unlock condition (%s)" % expected
	)
	Utils.get_focus_emulator(1, scene).focused_control = free
	yield(_frames(1), "completed")
