extends Node
# Co-op character selection on the machine that runs it (host, or local co-op without a lobby):
# - every empty player slot shows "Player N" and the game's own hold-to-join hint (the game only
#   shows it in the next free slot, and not at all before the first player joined);
# - players pick their colour with ui_info (F / Y), which the game doesn't use on this screen;
#   colours are applied by the CoopService extension, this node refreshes what is on screen.
# Solo play is untouched (nothing here runs outside a co-op run).

const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const SLOT_LABEL := "BrotatoTogetherSlotLabel"
const COLOR_HINT := "BrotatoTogetherColorHint"
const COLOR_ACTION := "ui_info"
const ICON_SIZE := 40

var _scene: Node = null
var _color_hint: Control = null


func _ready() -> void:
	CoopService.connect("bt_player_colors_changed", self, "_on_colors_changed")


static func is_character_selection(scene: Node) -> bool:
	return scene != null and scene.filename == MenuData.character_selection_scene


func _current() -> Node:
	var scene := get_tree().current_scene
	if not is_character_selection(scene) or not scene.is_inside_tree():
		_scene = null
		_color_hint = null
		return null
	if scene != _scene:
		_scene = scene
		_color_hint = null
	return scene


func _process(_delta: float) -> void:
	var scene := _current()
	if scene == null or not scene.has_method("_get_coop_join_panels"):
		return
	var count: int = CoopService.connected_players.size()
	var connecting: int = CoopService.connection_progress.size()
	# On a client's copy the host listens: its join progress says so (sync/menu_puppet.gd).
	var listening: bool = CoopService.listening_for_inputs or CoopService.bt_remote_progress != null
	var open: bool = RunData.is_coop_run and listening
	var panels: Array = scene._get_coop_join_panels()
	for i in panels.size():
		var panel = panels[i]
		if panel == null:
			continue
		var hint: bool = open and i >= count + connecting
		if panel.instructions_visible != hint:
			panel.instructions_visible = hint
		_slot_label(panel, i)
	_update_color_hint(scene, count)


# "Player N" at the top of an empty slot, in that slot's colour.
func _slot_label(panel: Control, i: int) -> void:
	var label: Label = panel.get_node_or_null(SLOT_LABEL)
	if label == null:
		label = Label.new()
		label.name = SLOT_LABEL
		label.align = Label.ALIGN_CENTER
		label.valign = Label.VALIGN_TOP
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(label)
	var text: String = Text.text("COOP_PLAYER", [str(i + 1)])
	if label.text != text:
		label.text = text
	label.add_color_override("font_color", CoopService.get_player_color(i))


func _update_color_hint(scene: Node, count: int) -> void:
	if _color_hint == null or not is_instance_valid(_color_hint):
		_color_hint = _add_color_hint(scene)
	if _color_hint != null:
		_color_hint.visible = RunData.is_coop_run and count > 0


# Below the title: "[F] / [Y]  Change colour" with the game's own key glyphs.
func _add_color_hint(scene: Node) -> Control:
	var title: Node = scene.get_node_or_null("MarginContainer/VBoxContainer/Title")
	if title == null:
		return null
	var row := color_hint_row()
	row.name = COLOR_HINT
	title.get_parent().add_child_below_node(title, row)
	return row


static func color_hint_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGN_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_constant_override("separation", 10)
	add_icon(row, CoopService.get_input_type_key_texture(
		COLOR_ACTION, CoopService.PlayerType.KEYBOARD_AND_MOUSE, 0
	))
	var slash := Label.new()
	slash.text = "/"
	row.add_child(slash)
	add_icon(row, CoopService.get_input_type_key_texture(
		COLOR_ACTION, CoopService.PlayerType.GAMEPAD_XBOX, 0
	))
	var label := Label.new()
	label.text = "Change colour"
	row.add_child(label)
	return row


static func add_icon(row: Control, texture: Texture) -> void:
	var icon := TextureRect.new()
	icon.texture = texture
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.rect_min_size = Vector2(ICON_SIZE, ICON_SIZE)
	row.add_child(icon)


# Runs after the scene's own nodes (reverse tree order); nothing on this screen uses ui_info.
func _input(event: InputEvent) -> void:
	if not RunData.is_coop_run or _current() == null:
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventAction):
		return
	for p in CoopService.connected_players.size():
		if Utils.is_player_action_pressed(event, p, COLOR_ACTION):
			CoopService.bt_cycle_color(p, 1)
			return


# The game reads player colours when it builds/styles things: restyle what is on screen now.
func _on_colors_changed() -> void:
	var scene := _current()
	if scene == null:
		return
	for emulator in ScenePaths.find_focus_emulators(scene):
		var control = emulator.focused_control
		if control != null and is_instance_valid(control) and emulator.has_method(
			"_update_focus_style_for_players"
		):
			emulator._update_focus_style_for_players(control)
		emulator.update()
	var panels: Array = scene._get_panels() if scene.has_method("_get_panels") else []
	for i in panels.size():
		_restyle_panel(panels[i], i)
	var locked: Array = scene._get_locked_panels() if scene.has_method("_get_locked_panels") else []
	for panel in locked:
		if panel != null and panel.player_color_index >= 0:
			panel.player_color_index = panel.player_color_index
	if scene.has_method("_get_coop_join_panels"):
		for panel in scene._get_coop_join_panels():
			if panel != null:
				panel._reset_join_progress()
				panel.update_indicators(
					CoopService.connected_players, CoopService.connection_progress
				)


# CharacterPanelUI colours the name and its left panel in set_data (co-op only).
func _restyle_panel(panel, i: int) -> void:
	if panel == null or panel.player_color_index < 0:
		return
	panel._update_stylebox()
	var name_label = panel.get("_characterName")
	var left = panel.get("_left_panel_color")
	if RunData.is_coop_run and name_label is Control and left is Control and panel.item_data != null:
		name_label.modulate = CoopService.player_colors[i]
		var tint: Color = CoopService.player_colors[i]
		tint.v = 0.5
		tint.a = 0.35
		left.self_modulate = tint
