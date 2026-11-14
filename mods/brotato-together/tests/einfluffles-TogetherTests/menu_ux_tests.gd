extends Reference
# F9 panel input (keyboard/pad navigation, input kept away from the game), the wave-failed retry
# prompt and its cursor on clients (incl. focus messages that arrive before their controls are
# visible), the battle -> next screen transition, and the client's copy of the selection grid.

const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const GUARD_NAME := "BrotatoTogetherMenuInputGuard"


var t: Node = null  # the test mod: _check()


class Probe:
	extends Node
	# Stands in for the game: records every key/pad event that reaches a normal node.
	var events := []

	func _ready() -> void:
		pause_mode = PAUSE_MODE_PROCESS

	func _input(event: InputEvent) -> void:
		if not (event is InputEventMouse):
			events.append(event)


# In a battle-capable state (run from the battle tests); leaves no scene of its own behind.
func run_battle_tests(test_mod: Node, together: Node):
	t = test_mod
	yield(_test_panel_input(together), "completed")
	yield(_test_retry_prompt(together), "completed")


# Needs the character selection scene with two co-op players (after the menu mirror test).
func run_menu_tests(test_mod: Node, together: Node):
	t = test_mod
	yield(_test_selection_grid(together), "completed")


func _tree() -> SceneTree:
	return t.get_tree()


func _frames(count: int):
	for _i in count:
		yield(_tree(), "idle_frame")


func _key(scancode: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.scancode = scancode
	event.physical_scancode = scancode  # the game binds arrows/WASD by physical key
	event.pressed = pressed
	Input.parse_input_event(event)


func _pad(button: int, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)


func _tap_key(scancode: int):
	_key(scancode, true)
	yield(_frames(1), "completed")
	_key(scancode, false)
	yield(_frames(2), "completed")


func _tap_pad(button: int):
	_pad(button, true)
	yield(_frames(1), "completed")
	_pad(button, false)
	yield(_frames(2), "completed")


func _test_panel_input(together: Node):
	var menu: CanvasLayer = together.get_node("TogetherMenu")
	var root := _tree().root
	var probe := Probe.new()
	root.add_child(probe)
	yield(_tap_key(KEY_F9), "completed")
	t._check(menu.is_open(), "panel: F9 opens")
	var guard := root.get_node_or_null(GUARD_NAME)
	t._check(guard != null and guard.get_index() == root.get_child_count() - 1, "panel: guard last")
	t._check(together.input_sync.local_input_blocked, "panel: client input to host neutral")
	t._check(menu.selected_button() != null, "panel: a button is selected")
	probe.events.clear()

	# Held arrow: the game neither gets the event nor sees the action pressed when polling.
	_key(KEY_RIGHT, true)
	yield(_frames(1), "completed")
	t._check(probe.events.empty(), "panel: game gets no key events")
	t._check(not Input.is_action_pressed("ui_right"), "panel: polled action released")
	_key(KEY_RIGHT, false)
	yield(_frames(1), "completed")

	# Confirm sub-state: keyboard to No, accept -> back to the main row.
	menu.ask_confirm("Really?", "close")
	t._check(_texts(menu.nav_buttons()) == ["Yes", "No"], "confirm: Yes / No")
	yield(_tap_key(KEY_RIGHT), "completed")
	t._check(menu.selected_button().text == "No", "confirm: arrow moves the selection")
	yield(_tap_key(KEY_ENTER), "completed")
	t._check(menu.is_open() and not menu._confirm_box.visible, "confirm: No returns")
	t._check("Close" in _texts(menu.nav_buttons()), "confirm: main row back")
	# Gamepad: B leaves the sub-state, A on Yes runs the action (here: close).
	menu.ask_confirm("Really?", "close")
	yield(_tap_pad(JOY_BUTTON_1), "completed")
	t._check(menu.is_open() and not menu._confirm_box.visible, "confirm: B backs out")
	menu.ask_confirm("Really?", "close")
	yield(_tap_pad(JOY_BUTTON_0), "completed")
	t._check(not menu.is_open(), "confirm: A on Yes runs it")
	t._check(probe.events.empty(), "panel: game got none of it (incl. A release)")
	t._check(not together.input_sync.local_input_blocked, "panel: client input back")

	# Esc closes; its release (the game pauses / goes back on release) is swallowed too.
	yield(_tap_key(KEY_F9), "completed")
	probe.events.clear()  # the F9 press itself is seen: the panel was closed
	_key(KEY_ESCAPE, true)
	yield(_frames(1), "completed")
	t._check(not menu.is_open(), "panel: Esc closes")
	_key(KEY_ESCAPE, false)
	yield(_frames(2), "completed")
	t._check(probe.events.empty(), "panel: Esc release swallowed %s" % [probe.events])
	t._check(root.get_node_or_null(GUARD_NAME) == null, "panel: guard gone after close")
	yield(_tap_key(KEY_RIGHT), "completed")
	t._check(probe.events.size() == 2, "panel: game gets keys again (%d)" % probe.events.size())

	# Gamepad: hold Select to open (a short press does nothing), B closes.
	_pad(JOY_SELECT, true)
	yield(_tree().create_timer(0.25), "timeout")
	t._check(not menu.is_open(), "pad: short Select press does nothing")
	yield(_tree().create_timer(0.4), "timeout")
	t._check(menu.is_open(), "pad: holding Select opens")
	_pad(JOY_SELECT, false)
	yield(_frames(2), "completed")
	t._check(menu.is_open(), "pad: releasing Select keeps it open")
	yield(_tap_pad(JOY_BUTTON_1), "completed")
	t._check(not menu.is_open(), "pad: B closes")
	probe.queue_free()


static func _texts(buttons: Array) -> Array:
	var texts := []
	for button in buttons:
		texts.append(button.text)
	return texts


# Host fails a wave: the retry prompt and its cursor reach the client's puppet battle; clicking
# the client's copy changes nothing locally. Then the battle -> next screen transition.
func _test_retry_prompt(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var focus_sync: Node = together.focus_sync
	var retry_sync: Node = together.retry_sync
	host.set_process(false)
	_tree().change_scene("res://main.tscn")
	yield(_frames(2), "completed")
	var main := _tree().current_scene
	var scene_path: String = main.filename
	host._start_battle(main)
	var host_retry = main.get("_retry_wave")
	host_retry.show()
	yield(_frames(2), "completed")
	var body: Dictionary = bytes2var(var2bytes(retry_sync.host_body()), false)
	t._check(body.visible and body.player == 0, "retry: host reports the prompt")
	var host_emulator = host_retry.get_node("FocusEmulator")
	var host_focus = host_emulator.focused_control
	t._check(host_focus != null, "retry: host cursor on a button")
	var focus_body := {
		"scene": main.filename,
		"cursors": [
			[
				ScenePaths.path_of(host_emulator, main),
				0,
				ScenePaths.path_of(host_focus, main) if host_focus != null else PoolIntArray()
			]
		]
	}
	focus_body = bytes2var(var2bytes(focus_body), false)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	host._end_battle()

	client._on_battle_start(start)
	yield(client, "battle_entered")
	yield(_frames(1), "completed")  # FocusSync picks up the new scene
	var puppet: Node = client._main
	var client_retry = puppet.get("_retry_wave")
	# The cursor arrives first: its button is hidden until the prompt shows -> kept and retried.
	focus_sync.receive(focus_body)
	t._check(focus_sync.is_pending(scene_path), "focus: unresolvable cursor kept")
	retry_sync.receive(body)
	t._check(client_retry.visible, "retry: client shows the prompt")
	var label = client_retry.get_node_or_null(retry_sync.WAITING_LABEL)
	t._check(label != null and "P1" in label.text, "retry: says whose choice it is")
	focus_sync._retry_pending()  # what FocusSync._process does every frame on a client
	var client_emulator = ScenePaths.resolve(puppet, focus_body.cursors[0][0])
	var client_focus = client_emulator.focused_control if client_emulator != null else null
	t._check(
		client_focus != null and client_focus == ScenePaths.resolve(puppet, focus_body.cursors[0][2]),
		"focus: cursor applied once the prompt is visible"
	)
	t._check(not focus_sync.is_pending(scene_path), "focus: resolved message cleared")
	client_retry.get_node("%ConfirmButton").emit_signal("pressed")
	client_retry.get_node("%OkButton").emit_signal("pressed")
	yield(_frames(3), "completed")
	t._check(_tree().current_scene == puppet, "retry: client's copy doesn't change scenes")

	# Battle over: the frozen battle stays (muted) until the next screen replaces it, and the
	# fallback view shows up neutral before saying it's waiting.
	together._client_active = true
	client._leave_battle()
	yield(_frames(3), "completed")
	t._check(_tree().current_scene == puppet, "transition: battle kept while the next loads")
	t._check(SoundRelay.is_muted(), "transition: kept battle muted")
	together._on_transition_grace_over(-1)  # a newer scene already replaced it: no-op
	t._check(_tree().current_scene == puppet, "transition: newer scene left alone")
	yield(_tree().create_timer(together.TRANSITION_GRACE_SEC + 0.2), "timeout")
	var view := _tree().current_scene
	t._check(view != null and view.get_script() == ClientView, "transition: view as fallback")
	if view != null and view.get_script() == ClientView:
		t._check(view._title.text == "", "transition: no 'waiting' flash")
		t._check(not SoundRelay.is_muted(), "transition: view not muted")
		yield(_tree().create_timer(view.WAITING_DELAY_SEC + 0.2), "timeout")
		t._check("Waiting" in view._title.text, "transition: 'waiting' after a delay")
	together._client_active = false
	Puppet.set_active(false)
	host.set_process(true)


# The host's grid (order + flags) and both cursors, drawn on the client from ids alone.
func _test_selection_grid(together: Node):
	var menu_sync: Node = together.menu_sync
	menu_sync.set_process(false)
	var scene := _tree().current_scene
	menu_sync._scene = scene
	menu_sync._emulators = ScenePaths.find_focus_emulators(scene)
	var grids: Dictionary = menu_sync.grids_state()
	var inventory = scene.get_node("%Inventory1")
	t._check(
		grids.inventories.size() == 1,
		(
			"grid: one shared character grid (%d, Inventory1 visible: %s)"
			% [grids.inventories.size(), inventory.is_visible_in_tree()]
		)
	)
	if grids.inventories.size() != 1:
		menu_sync.set_process(true)
		yield(_frames(1), "completed")
		return
	t._check(grids.inventories[0][0] == inventory.columns, "grid: host columns")
	var elements := []
	var picks := []
	for child in inventory.get_children():
		if child is InventoryElement:
			elements.append(child)
			if not child.is_random and child.item != null:
				picks.append(child)
	t._check(grids.inventories[0][1].size() == elements.size(), "grid: every host element")
	var first: InventoryElement = picks[0]
	var second: InventoryElement = picks[min(3, picks.size() - 1)]
	Utils.get_focus_emulator(0, scene).focused_control = first
	Utils.get_focus_emulator(1, scene).focused_control = second
	scene._has_player_selected[1] = true
	var state: Dictionary = menu_sync._state()
	t._check(
		state.players[0][4] == 0 and state.players[0][5] == elements.find(first),
		"grid: host cursor position %s" % [state.players[0].slice(4, 5)]
	)
	state["you"] = 1
	state["grids"] = grids
	# Client side: grids come once, later states reuse them.
	var received := []
	menu_sync.connect("menu_state", self, "_on_received", [received])
	menu_sync.receive_state(bytes2var(var2bytes(state), false))
	var without: Dictionary = state.duplicate()
	without.erase("grids")
	menu_sync.receive_state(bytes2var(var2bytes(without), false))
	menu_sync.disconnect("menu_state", self, "_on_received")
	t._check(
		received.size() == 2 and received[1].grids.inventories.size() == 1,
		"grid: client keeps the last grids"
	)
	var view = ClientView.new()
	_tree().root.add_child(view)
	view.show_menu(received[1])
	var grid = view._grid
	t._check(grid.visible and grid.cell_count(0) == elements.size(), "grid: drawn")
	var item = grid.cell_item(0, elements.find(first))
	t._check(item != null and item.my_id == first.item.my_id, "grid: same element at same index")
	var cell0: Dictionary = grid.cell_at(0, elements.find(first))
	var cell1: Dictionary = grid.cell_at(0, elements.find(second))
	t._check(
		cell0.style.border_width_top > 0
		and cell0.style.border_color == CoopService.get_player_color(0),
		"grid: P1 cursor in P1 colour"
	)
	t._check(
		cell1.style.border_width_top > cell0.style.border_width_top and "P2" in cell1.label.text,
		"grid: P2 cursor, marked ready"
	)
	# A host-only id (DLC this machine lacks) and junk don't break the view.
	var odd := {"random_icon": "res://../x", "inventories": [[4, [["not_a_real_id", 0]]], "junk"]}
	view.show_menu({"kind": "weapon_selection", "count": 0, "players": [], "grids": odd})
	t._check(grid.cell_count(0) == 1 and grid.cell_item(0, 0) == null, "grid: unknown id shown")
	t._check(grid.inventory_count() == 2 and grid.cell_count(1) == 0, "grid: junk ignored")
	view.queue_free()
	scene._has_player_selected[1] = false
	menu_sync.set_process(true)
	yield(_frames(1), "completed")


func _on_received(state: Dictionary, received: Array) -> void:
	received.append(state)
