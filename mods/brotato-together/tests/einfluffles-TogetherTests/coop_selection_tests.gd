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
const OnlineLayoutTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/online_layout_tests.gd"
)
const KEYBOARD := 7  # CoopService.KEYBOARD_REMAPPED_DEVICE_ID
# Viewport sizes the colour hint is checked at (16:9 and 16:10).
const SIZES := [Vector2(1920, 1080), Vector2(2560, 1440), Vector2(1280, 720), Vector2(1920, 1200)]

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
	yield(check_hint_layout(t, together.coop_selection, scene, "host"), "completed")
	yield(OnlineLayoutTests.new().run(t, scene), "completed")
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
	var hint: Control = scene.find_node(CoopSelection.COLOR_HINT, true, false)
	t._check(hint != null and hint.is_visible_in_tree(), "colour hint shown")


# The colour hint (in the mod's top bar, ui/top_bar.gd) takes no space in the game's layout and
# covers nothing, at several viewport sizes. The game stretches a 1920x1080 layout to any window
# (2d / keep), so 1920x1080 is what it lays out on every resolution; the stretch's base size is
# set to each resolution here so that the layout itself is checked at those sizes too. `where`:
# host / client, for the messages.
# the layout itself is checked at those sizes too. `where`: host / client, for the messages.
func check_hint_layout(test_mod: Node, coop_selection: Node, scene: Node, where: String):
	t = test_mod
	var hint: Control = scene.find_node(CoopSelection.COLOR_HINT, true, false)
	var layout: Control = scene.get_node("MarginContainer")
	t._check(
		hint != null and hint.is_visible_in_tree() and not layout.is_a_parent_of(hint),
		"colour hint (%s): shown, outside the game's layout containers" % where
	)
	if hint == null:
		yield(_frames(1), "completed")
		return
	coop_selection.set_process(false)  # it shows the hint every frame
	# The DLC bar as co-op lays it out (in a row next to the Back button): the tests set the co-op
	# run directly, so the game did not switch it.
	var bar: Node = scene.get_node_or_null("%ItemSetBar")
	var vertical: bool = bar != null and not bar._horizontal
	if vertical:
		bar.set_horizontal(true)
	if bar == null or not bar.visible:
		print("  info: no DLC bar here; the colour hint's check against it skipped")
	var base := Vector2(
		ProjectSettings.get_setting("display/window/size/width"),
		ProjectSettings.get_setting("display/window/size/height")
	)
	var failures := []
	for size in SIZES:
		_stretch(size)
		hint.visible = false
		yield(_frames(3), "completed")
		var vanilla := _layout_rects(scene)
		hint.visible = true
		yield(_frames(3), "completed")
		var shown := _layout_rects(scene)
		var at := "%dx%d" % [size.x, size.y]
		if shown.rects != vanilla.rects:
			failures.append("%s: layout moved (%s vs %s)" % [at, shown.rects, vanilla.rects])
		if shown.scroll > vanilla.scroll:
			failures.append("%s: grid scrolls %d instead of %d" % [at, shown.scroll, vanilla.scroll])
		# Narrower than 1920 (1280x720) the game's own row of panels runs off screen and the top
		# bar with the online controls (online_layout_tests.gd) reaches the DLC bar: layout only.
		if size.x < base.x:
			continue
		var rect := hint.get_global_rect()
		if not scene.get_viewport().get_visible_rect().encloses(rect):
			failures.append("%s: hint %s off screen" % [at, rect])
		for other in _neighbours(scene):
			if other.is_visible_in_tree() and rect.intersects(other.get_global_rect()):
				var over: Rect2 = other.get_global_rect()
				failures.append("%s: hint %s over %s %s" % [at, rect, other.name, over])
	_stretch(base)
	if vertical:
		bar.set_horizontal(false)
	coop_selection.set_process(true)
	yield(_frames(3), "completed")
	t._check(
		failures.empty(),
		"colour hint (%s): same layout, no extra grid scrolling, covers nothing at %s %s"
		% [where, SIZES, failures]
	)


func _stretch(size: Vector2) -> void:
	_stretch_tree(_tree(), size)


static func _stretch_tree(tree: SceneTree, size: Vector2) -> void:
	tree.set_screen_stretch(SceneTree.STRETCH_MODE_2D, SceneTree.STRETCH_ASPECT_KEEP, size)


# Rects of the layout's children and the character grid; how far the grid scrolls.
static func _layout_rects(scene: Node) -> Dictionary:
	var rects := []
	for child in scene.get_node("MarginContainer/VBoxContainer").get_children():
		if child is Control and child.visible:
			rects.append([child.name, child.get_global_rect()])
	var grid: Control = scene.get_node("%Inventory1")
	rects.append([grid.name, grid.get_global_rect()])
	var scroll: ScrollContainer = scene.get_node("%Inventories")
	var bar := scroll.get_v_scrollbar()
	return {rects = rects, scroll = max(0.0, bar.max_value - bar.page)}


# What the hint must not cover: title, Back button, DLC bar, Run Options box, player panels.
static func _neighbours(scene: Node) -> Array:
	var nodes := [
		scene.get_node("MarginContainer/VBoxContainer/Title"),
		scene.get_node("BackButton"),
		scene.get_node("%RunOptionsPanel"),
	]
	var bar: Node = scene.get_node_or_null("%ItemSetBar")
	if bar != null:
		nodes.append(bar.get_node("Panel"))
	var row := "MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer"
	for panel in scene.get_node(row).get_children():
		if panel is Control:
			nodes.append(panel)
	return nodes


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
