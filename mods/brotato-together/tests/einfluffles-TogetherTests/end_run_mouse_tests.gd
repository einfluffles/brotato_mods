extends Reference
# The mouse on a client's end-of-run copy (sync/end_run_mouse.gd): popups on hover, pages turned
# here, the wheel on the own panel, and no press of the copy's buttons. Part of the menu copies
# (menu_puppet_tests.gd; `you` is P2 there).

const WheelScrollTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/wheel_scroll_tests.gd"
)
const InputSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/input_sync.gd")
const OWN := 1

var _t: Node = null
var _menus: Node = null
var _scene: Node = null


func run(test_mod: Node, menus: Node, scene: Node):
	_t = test_mod
	_menus = menus
	_scene = scene
	var mouse: Node = scene.get_node_or_null(menus.END_RUN_MOUSE)
	_t._check(
		mouse != null and mouse.get_index() == scene.get_child_count() - 1
		and scene.get_node_or_null(menus.GLASS) == null,
		"end of run: the mouse node is the emulators' last sibling, no glass"
	)
	if mouse == null:
		yield(_frames(1), "completed")
		return
	yield(_hover(), "completed")
	yield(_pages(), "completed")
	var containers: Array = scene.player_containers
	var wheel := WheelScrollTests.new(_t)
	yield(wheel.check_wheel("end of run, client", containers[OWN], containers[0]), "completed")
	yield(_buttons(), "completed")
	yield(_mouse_at(Vector2(2, 2), "move"), "completed")


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")


func _cursors() -> Array:
	var cursors := []
	for p in 4:
		var emulator = Utils.get_focus_emulator(p, _scene)
		cursors.append(emulator.focused_control if emulator != null else null)
	return cursors


func _hover():
	var containers: Array = _scene.player_containers
	var element: Control = containers[0].weapons_container.get_element(0)
	var stat: Control = _stat_of(containers[OWN])
	if element == null or not element.is_visible_in_tree() or stat == null:
		_t._check(false, "end of run: P1 shows a weapon, P2 a stat that is not its cursor")
		yield(_frames(1), "completed")
		return
	var cursors := _cursors()
	var item_popup: Control = _scene.item_popups[0]
	yield(_mouse(element, "move"), "completed")
	_t._check(
		item_popup.visible and item_popup._attachment == element and _cursors() == cursors,
		"end of run: hovering another player's weapon shows its popup, no cursor moves"
	)
	var stat_popup: Control = _scene.stat_popups[OWN]
	yield(_mouse(stat, "move"), "completed")
	_t._check(
		stat_popup.visible and stat_popup._attachment == stat and _cursors() == cursors,
		"end of run: hovering a stat of the own panel shows its popup"
	)
	_t._check(
		not (item_popup.visible and item_popup._attachment == element) or element == cursors[0],
		"end of run: the weapon's popup went with the mouse"
	)
	yield(_mouse_at(Vector2(2, 2), "move"), "completed")
	_t._check(
		not (stat_popup.visible and stat_popup._attachment == stat) and _cursors() == cursors,
		"end of run: the mouse off the panels closes the stat's popup"
	)


# A StatContainer showing in root that is not the own cursor.
func _stat_of(root: Node) -> Control:
	var cursor = _cursors()[OWN]
	for node in _all(root):
		if node is StatContainer and node != cursor and node.is_visible_in_tree():
			if node.focus_mode == Control.FOCUS_ALL:
				return node
	return null


static func _all(node: Node) -> Array:
	var nodes := [node]
	for child in node.get_children():
		nodes += _all(child)
	return nodes


func _pages():
	var containers: Array = _scene.player_containers
	var carousel = containers[0].carousel
	var own = containers[OWN].carousel
	var cursors := _cursors()
	if carousel.index != 0 or own.index != 1:
		_t._check(false, "end of run: the host's pages [0, 1] before the clicks")
		yield(_frames(1), "completed")
		return
	yield(_click(carousel.arrow_left), "completed")
	_t._check(carousel.index == 0, "end of run: no page before the first")
	yield(_click(carousel.arrow_right), "completed")
	_t._check(
		carousel.index == 1 and _cursors() == cursors,
		"end of run: a click on another player's page arrow turns the page here, no cursor moves"
	)
	var item_popup: Control = _scene.item_popups[0]
	_t._check(
		not item_popup.visible or item_popup._attachment.is_visible_in_tree(),
		"end of run: a popup whose item the page took away is closed"
	)
	_menus._apply_pages(_scene, [0, 1])
	_t._check(carousel.index == 1, "end of run: the page turned here stays while the host's stays")
	_menus._apply_pages(_scene, [2, 1])
	_t._check(carousel.index == 2, "end of run: the host's page change wins")
	_menus._apply_pages(_scene, [0, 1])

	yield(_click(own.arrow_left), "completed")
	_t._check(own.index == 0, "end of run: a click turns the own panel's page too")
	var key := InputEventKey.new()
	key.scancode = KEY_SHIFT
	for pressed in [true, false]:
		key.pressed = pressed
		Input.parse_input_event(key)
		yield(_frames(2), "completed")
	_t._check(own.index == 1, "end of run: a key brings the own panel back to the host's page")
	yield(_click(own.arrow_left), "completed")  # the wheel checks the own items page


# Restart, new run and exit: a click presses nothing here and holds no button for the host.
func _buttons():
	var pressed := []
	var buttons := [_scene._restart_button, _scene._new_run_button, _scene._exit_button]
	for button in buttons:
		button.connect("pressed", self, "_on_pressed", [pressed, button.name])
	var cursors := _cursors()
	var held := 0
	for button in buttons:
		if not button.is_visible_in_tree():
			print("  info: %s not shown, not clicked" % button.name)
			continue
		yield(_mouse(button, "move"), "completed")
		yield(_mouse(button, "down"), "completed")
		held |= InputSync.local_buttons()
		yield(_mouse(button, "up"), "completed")
	for button in buttons:
		button.disconnect("pressed", self, "_on_pressed")
	yield(_frames(2), "completed")
	_t._check(
		pressed.empty() and held == 0 and _cursors() == cursors
		and _t.get_tree().current_scene == _scene and _scene._button_pressed,
		"end of run: clicks on restart, new run and exit press nothing (%s, buttons %d)" % [
			pressed, held
		]
	)


func _on_pressed(pressed: Array, button_name: String) -> void:
	pressed.append(button_name)


func _click(control: Control):
	yield(_mouse(control, "down"), "completed")
	yield(_mouse(control, "up"), "completed")


# A mouse event at the middle of a control, in window coordinates like a real one.
func _mouse(control: Control, kind: String):
	var canvas_pos: Vector2 = control.get_global_transform_with_canvas().xform(
		control.rect_size / 2.0
	)
	yield(_mouse_at(canvas_pos, kind), "completed")


func _mouse_at(canvas_pos: Vector2, kind: String):
	var pos: Vector2 = _t.get_viewport().get_final_transform().xform(canvas_pos)
	var event = null
	if kind == "move":
		event = InputEventMouseMotion.new()
	else:
		event = InputEventMouseButton.new()
		event.button_index = BUTTON_LEFT
		event.pressed = kind == "down"
	event.position = pos
	event.global_position = pos
	Input.parse_input_event(event)
	yield(_frames(3), "completed")  # flushed by the test mod, then resolved in _process
