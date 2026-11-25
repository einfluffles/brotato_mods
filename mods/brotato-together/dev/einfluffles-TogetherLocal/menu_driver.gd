extends Reference
# Driving the game's menus as a player does, for the local-play director (director.gd) and the
# test mod (suite director): key presses through Input as the OS's key events come in, a button
# pressed by giving it the focus and pressing accept, the window's picture from its own viewport,
# and what the screen shows (snapshot) for waiting and checking. No game state is changed here.

const KEY_HOLD_FRAMES := 3
const KEY_MIN_MSEC := 150  # a tap: a client's input reaches the host's game in samples
const RELEASE_MSEC := 100  # after a hold: the key-up is through (3 frames)
const ACCEPT_KEY := "Enter"
const RESUME_SCENE := "res://ui/menus/shop/coop_resume.tscn"
const MAIN_SCENE := "res://main.tscn"

var tree: SceneTree = null


func _init(scene_tree: SceneTree) -> void:
	tree = scene_tree


# The scancode of a Godot key name (Enter, Escape, Right, A, F1, ...), 0 when unknown.
static func scancode_of(key_name: String) -> int:
	if key_name == "":
		return 0
	return OS.find_scancode_from_string(key_name)


# The first key the game binds to an action (ui_accept: Enter), 0 without one.
static func action_scancode(action: String) -> int:
	if not InputMap.has_action(action):
		return 0
	for event in InputMap.get_action_list(action):
		if event is InputEventKey:
			var code: int = event.scancode if event.scancode != 0 else event.physical_scancode
			if code != 0:
				return code
	return 0


static func key_event(scancode: int, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.scancode = scancode
	event.physical_scancode = scancode
	event.pressed = pressed
	return event


# A key down and, KEY_MIN_MSEC or hold_msec later, up again. Yields; the result is the msec held.
func press(scancode: int, hold_msec := 0):
	var started := OS.get_ticks_msec()
	for pressed in [true, false]:
		Input.parse_input_event(key_event(scancode, pressed))
		var until: int = OS.get_ticks_msec() + (max(hold_msec, KEY_MIN_MSEC) if pressed else 0)
		var frames := 0
		while frames < KEY_HOLD_FRAMES or OS.get_ticks_msec() < until:
			frames += 1
			yield(tree, "idle_frame")
	return OS.get_ticks_msec() - started


# Every button that is shown, enabled and named `button_name` (node name) or showing
# `button_text` (its text, or the translation key its text came from). The last one in tree
# order first: popups and later layers are drawn over the scene.
func find_buttons(button_name: String, button_text := "") -> Array:
	var found := []
	_collect(tree.root, button_name, button_text, found)
	found.invert()
	return found


func _collect(node: Node, button_name: String, button_text: String, found: Array) -> void:
	if node is CanvasItem and not node.is_visible_in_tree():
		return
	if node is BaseButton and not node.disabled and _matches(node, button_name, button_text):
		found.append(node)
	for child in node.get_children():
		_collect(child, button_name, button_text, found)


static func _matches(button: BaseButton, button_name: String, button_text: String) -> bool:
	if button_name != "" and button.name != button_name:
		return false
	if button_text != "":
		var text = button.get("text")
		if typeof(text) != TYPE_STRING:
			return false
		var wanted := button_text.to_lower()
		if text.to_lower() != wanted and text.to_lower() != button.tr(button_text).to_lower():
			return false
	return true


# Focuses the button and presses accept on it, as a keyboard player does. Yields; the result is
# the button's path, or "" when no such button is shown.
func press_button(button_name: String, button_text := ""):
	var buttons := find_buttons(button_name, button_text)
	yield(tree, "idle_frame")
	if buttons.empty():
		return ""
	var button: BaseButton = buttons[0]
	var path := str(button.get_path())
	if button.focus_mode == Control.FOCUS_NONE:
		button.emit_signal("pressed")  # nothing a key can reach: as a click
		return path
	button.grab_focus()
	yield(tree, "idle_frame")
	yield(press(scancode_of(ACCEPT_KEY)), "completed")
	return path


# The window as it is drawn, saved as PNG to `path` (written under another name first, so a reader
# never sees half a file). A minimised window is not drawn by the engine: it is drawn once here.
# Yields; the result is the error code.
func screenshot(path: String):
	if OS.window_minimized:
		yield(tree, "idle_frame")
		VisualServer.force_draw(false)
	else:
		yield(VisualServer, "frame_post_draw")
	var image: Image = tree.root.get_texture().get_data()
	if image == null or image.is_empty():
		return ERR_UNAVAILABLE
	image.flip_y()
	var error := image.save_png(path + ".tmp")
	if error == OK:
		error = Directory.new().rename(path + ".tmp", path)
	return error


# What the screen shows: the scene (its file's name, as the mod names a menu kind), players, the
# run, the co-op resume screen and the wave. `lobby` is filled by the caller (the transport).
func snapshot() -> Dictionary:
	var scene := tree.current_scene
	var path: String = scene.filename if scene != null else ""
	var focus = _focus_owner(tree.root)
	var state := {
		"scene": path.get_file().get_basename(),
		"scene_path": path,
		"paused": tree.paused,
		"locale": TranslationServer.get_locale(),
		"focus": str(focus.name) if focus != null else "",
		"players": CoopService.connected_players.size(),
		"listening": CoopService.listening_for_inputs,
		"run": _run_state(),
	}
	if path == RESUME_SCENE:
		state["resume_shown"] = scene._player_label.player_index
		state["resume_gold"] = scene._gold_label.text
		state["resume_progress"] = scene._progress_bar.value
	elif path == MAIN_SCENE:
		var timer = scene.get("_wave_timer")
		state["wave_left"] = timer.time_left if timer != null else -1.0
		state["upgrades"] = _shown(scene.get("_upgrades_ui")) or _shown(scene.get("_coop_upgrades_ui"))
	return state


# The control with the keyboard focus: Godot 3 asks any control of the viewport for it, so the
# first one found answers.
static func _focus_owner(node: Node) -> Control:
	for child in node.get_children():
		if child is Control:
			return child.get_focus_owner()
		if child is Viewport:
			continue
		var focused = _focus_owner(child)
		if focused != null:
			return focused
	return null


static func _shown(node) -> bool:
	return node is CanvasItem and node.is_visible_in_tree()


static func _run_state() -> Dictionary:
	var count: int = RunData.get_player_count()
	var gold := []
	var levels := []
	var items := []
	var weapons := []
	for p in count:
		gold.append(RunData.get_player_gold(p))
		levels.append(RunData.get_player_level(p))
		items.append(RunData.get_player_items(p).size())
		weapons.append(RunData.get_player_weapons(p).size())
	return {
		"coop": RunData.is_coop_run,
		"count": count,
		"wave": RunData.current_wave,
		"gold": gold,
		"levels": levels,
		"items": items,
		"weapons": weapons,
		"saved": ProgressData.saved_run_state.get("has_run_state", false),
	}


# Whether `state` has every value of `wanted`. "scene" matches the file's name or its path.
static func matches(state: Dictionary, wanted: Dictionary) -> bool:
	for key in wanted:
		var want = wanted[key]
		var have = _lookup(state, key)
		if key == "scene" and typeof(want) == TYPE_STRING:
			if want != have and want != state.get("scene_path"):
				return false
		elif not _same(have, want):
			return false
	return true


# A dotted key looks into nested dictionaries ("run.wave", "lobby.members").
static func _lookup(state: Dictionary, key: String):
	var value = state
	for part in key.split("."):
		if typeof(value) != TYPE_DICTIONARY or not value.has(part):
			return null
		value = value[part]
	return value


# JSON numbers are floats: 1 and 1.0 are the same here.
static func _same(have, want) -> bool:
	var numbers := [TYPE_INT, TYPE_REAL]
	if typeof(have) in numbers and typeof(want) in numbers:
		return is_equal_approx(float(have), float(want))
	if typeof(have) != typeof(want):
		return false
	return have == want
