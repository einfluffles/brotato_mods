extends Node
# Where the damage meter (sync/damage_meter.gd) shows, on every machine, in the game's own
# screens:
# - In a wave: a row under each player's life bar (above it for the two lower players): the
#   wave's total and the two strongest sources as icon and number.
# - In the co-op shop: a button next to each player's reroll button. While a player's cursor
#   rests on it, the board of the wave before is up over that player's shop items: the total and
#   the sources with icon, name, number and share. Nothing is pressed and nothing pauses: the
#   board belongs to the panel of the player who looks at it, the others shop on, and because
#   cursors are mirrored (ui/focus_targets.gd: "shop_damage") every machine shows whose board
#   is up.

const BATTLE_SCENE := "res://main.tscn"
const ROW_NAME := "DamageRow"
const BUTTON_NAME := "DamageButton"
const BOARD_NAME := "DamageBoard"
const ICON := "res://ui/icons/misc/weapon_icon.png"
const HUD_FONT := "res://resources/fonts/actual/base/font_26_outline.tres"
const BOARD_FONT := "res://resources/fonts/actual/base/font_26.tres"
const HUD_SOURCES := 2
const HUD_ICON := Vector2(26, 26)
const BOARD_ICON := Vector2(36, 36)
const BUTTON_WIDTH := 60

var meter: Node = null  # sync/damage_meter.gd (set by mod_main.gd)

var _scene_id := 0
var _rows := []  # per player: the HUD row, or null
var _boards := []  # per player: [button, board], or null
var _shop: Node = null


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	meter.connect("changed", self, "_fill")


func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	var scene_id := scene.get_instance_id() if scene != null else 0
	if scene_id != _scene_id:
		_scene_id = scene_id
		_rows = []
		_boards = []
		_shop = null
		if scene != null and scene.filename == BATTLE_SCENE:
			_build_rows(scene)
		elif scene is CoopShop:
			_shop = scene
			call_deferred("_build_boards", scene)  # after the shop's own _ready wiring
	if _shop != null:
		_show_boards()


# --- HUD ---


func _build_rows(main: Node) -> void:
	for p in RunData.get_player_count():
		var container = main.get_node_or_null("UI/HUD/LifeContainerP%d" % (p + 1))
		if container == null or container.has_node(ROW_NAME):
			_rows.append(null)
			continue
		var row := HBoxContainer.new()
		row.name = ROW_NAME
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.alignment = BoxContainer.ALIGN_END if p % 2 == 1 else BoxContainer.ALIGN_BEGIN
		row.modulate.a = 0.75 if RunData.is_coop_run else 1.0
		for _i in HUD_SOURCES + 1:
			row.add_child(_icon(HUD_ICON))
			row.add_child(_label(HUD_FONT))
		row.get_child(0).texture = load(ICON)
		container.add_child(row)
		if p > 1:
			container.move_child(row, 0)  # the lower players' bars grow upwards
		_rows.append(row)
	_fill()


func _fill_row(row: HBoxContainer, entry: Array) -> void:
	row.visible = entry[0] > 0
	row.get_child(1).text = Text.get_formatted_number(entry[0])
	for k in HUD_SOURCES:
		var icon: TextureRect = row.get_child(2 + 2 * k)
		var label: Label = row.get_child(3 + 2 * k)
		var data = meter.data_of(entry[1][k][0]) if k < entry[1].size() else null
		icon.visible = data != null
		label.visible = data != null
		if data != null:
			icon.texture = data.icon
			label.text = Text.get_formatted_number(entry[1][k][2])


# --- shop ---


func _build_boards(shop: Node) -> void:
	if not is_instance_valid(shop) or shop != _shop:
		return
	for p in RunData.get_player_count():
		var reroll: Control = shop._get_reroll_button(p)
		var slots: Control = shop._get_shop_items_container(p)
		if reroll.get_parent().has_node(BUTTON_NAME):
			_boards.append(null)
			continue
		var button := Button.new()
		button.name = BUTTON_NAME
		button.icon = load(ICON)
		button.expand_icon = true
		button.focus_mode = Control.FOCUS_ALL
		button.rect_min_size = Vector2(BUTTON_WIDTH, reroll.rect_size.y)
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		reroll.get_parent().add_child_below_node(reroll, button)
		# Reached from the reroll button; up and down lead where they do from there.
		button.focus_neighbour_left = button.get_path_to(reroll)
		button.focus_neighbour_right = button.get_path_to(button)
		for side in ["focus_neighbour_top", "focus_neighbour_bottom"]:
			var path: NodePath = reroll.get(side)
			var target = null if path.is_empty() else reroll.get_node_or_null(path)
			if target != null:
				button.set(side, button.get_path_to(target))
		reroll.focus_neighbour_right = reroll.get_path_to(button)
		var board := _board()
		slots.get_parent().add_child(board)  # a PanelContainer: the board fills the slots' place
		_boards.append([button, board])
	_fill()


# The board: a title and MAX_SOURCES rows of icon, name, number, share.
func _board() -> PanelContainer:
	var board := PanelContainer.new()
	board.name = BOARD_NAME
	board.visible = false
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.08, 1.0)
	style.set_corner_radius_all(8)
	style.set_default_margin(MARGIN_LEFT, 14)
	style.set_default_margin(MARGIN_RIGHT, 14)
	style.set_default_margin(MARGIN_TOP, 10)
	style.set_default_margin(MARGIN_BOTTOM, 10)
	board.add_stylebox_override("panel", style)
	var list := VBoxContainer.new()
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board.add_child(list)
	list.add_child(_label(BOARD_FONT))
	for _i in meter.MAX_SOURCES:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(_icon(BOARD_ICON))
		var name_label := _label(BOARD_FONT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		row.add_child(name_label)
		row.add_child(_label(BOARD_FONT))
		list.add_child(row)
	return board


func _fill_board(board: PanelContainer, entry: Array) -> void:
	var list: Node = board.get_child(0)
	list.get_child(0).text = Text.text("DAMAGE_DEALT", [Text.get_formatted_number(entry[0])])
	for k in meter.MAX_SOURCES:
		var row: Node = list.get_child(1 + k)
		var source = entry[1][k] if k < entry[1].size() else null
		var data = meter.data_of(source[0]) if source != null else null
		row.visible = data != null
		if data == null:
			continue
		row.get_child(0).texture = data.icon
		var name_label: Label = row.get_child(1)
		name_label.text = tr(data.name) + (" x%d" % source[1] if source[1] > 1 else "")
		name_label.add_color_override("font_color", ItemService.get_color_from_tier(data.tier))
		var share := int(round(100.0 * source[2] / max(1, entry[0])))
		row.get_child(2).text = "%s  %d%%" % [Text.get_formatted_number(source[2]), share]


# A board is up while its player's cursor rests on the button (solo: while it has the focus).
func _show_boards() -> void:
	if not is_instance_valid(_shop):
		_shop = null
		return
	for p in _boards.size():
		if _boards[p] == null:
			continue
		var button: Button = _boards[p][0]
		var emulator = Utils.get_focus_emulator(p, _shop)
		var cursor = emulator.focused_control if emulator != null else null
		var up: bool = cursor == button or button.has_focus()
		if _boards[p][1].visible != up:
			_boards[p][1].visible = up


# --- both ---


func _fill() -> void:
	var players: Array = meter.board.get("players", [])
	for p in _rows.size():
		if _rows[p] != null and is_instance_valid(_rows[p]):
			_fill_row(_rows[p], players[p] if p < players.size() else [0, []])
	for p in _boards.size():
		if _boards[p] != null and is_instance_valid(_boards[p][1]):
			_fill_board(_boards[p][1], players[p] if p < players.size() else [0, []])


static func _icon(size: Vector2) -> TextureRect:
	var icon := TextureRect.new()
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.rect_min_size = size
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon


static func _label(font_path: String) -> Label:
	var label := Label.new()
	label.add_font_override("font", load(font_path))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
