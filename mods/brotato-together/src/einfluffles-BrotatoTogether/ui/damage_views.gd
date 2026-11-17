extends Node
# Where the damage meter (sync/damage_meter.gd) shows, on every machine, in the game's own
# screens:
# - In a wave: two lines under each player's life bar (above it for the two lower players). The
#   first: the wave's total, in co-op the player's share of the team's, and the damage per
#   second. The second, smaller: the two strongest sources as icon and number, and the biggest
#   single hit.
# - In the shop: a button next to each player's reroll button. While a player's cursor rests on
#   it (or the mouse, or the focus in the solo shop), the board of the wave before is up over
#   that player's shop items: the wave and in co-op the share of the team's damage, three tiles
#   (total, damage per second, biggest hit with its source), and the sources with icon, name, a
#   bar against the strongest, number and share. Nothing is pressed and nothing pauses: the
#   board belongs to the panel of the player who looks at it, the others shop on, and because
#   cursors are mirrored (ui/focus_targets.gd: "shop_damage") every machine shows whose board
#   is up.
# Numbers from 10,000 on are short (12.3K, 4.56M, 7.89B): late runs deal billions.
# All of it is gone while the meter is switched off on this machine (DamageMeter.shown).

const BATTLE_SCENE := "res://main.tscn"
const ROW_NAME := "DamageRow"
const BUTTON_NAME := "DamageButton"
const BOARD_NAME := "DamageBoard"
const ICON := "res://ui/icons/misc/weapon_icon.png"
const TOTAL_ICON := "res://items/stats/percent_damage.png"
const DPS_ICON := "res://items/stats/attack_speed.png"
const HIT_ICON := "res://items/stats/crit_chance.png"
const HUD_FONT := "res://resources/fonts/actual/base/font_26_outline.tres"
const BOARD_FONT := "res://resources/fonts/actual/base/font_26.tres"
const BOARD_SMALL_FONT := "res://resources/fonts/actual/base/font_smallest_text.tres"
const HUD_SMALL_SIZE := 20
const HUD_SOURCES := 2
const HUD_ICON := Vector2(24, 24)
const HUD_SMALL_ICON := Vector2(20, 20)
const TILE_ICON := Vector2(26, 26)
const BOARD_ICON := Vector2(32, 32)
const BAR_SIZE := Vector2(72, 10)
const AMOUNT_WIDTH := 84
const SHARE_WIDTH := 56
const BUTTON_WIDTH := 60
const SHORT_FROM := 10000
const UNITS := ["K", "M", "B", "T", "Q"]
const MUTED := Color(0.7, 0.7, 0.7)
const DPS_COLOR := Color(0.6, 0.85, 1.0)
const HIT_COLOR := Color(1.0, 0.8, 0.35)
const PANEL_COLOR := Color(0.08, 0.08, 0.08, 0.96)
const LINE_COLOR := Color(1, 1, 1, 0.12)
const BAR_BACK := Color(1, 1, 1, 0.1)
const REROLL_RIGHT_META := "brotato_together_reroll_right"  # reroll's own neighbour, on the button

var meter: Node = null  # sync/damage_meter.gd (set by mod_main.gd)

var _scene_id := 0
var _rows := []  # per player: the HUD row, or null
var _boards := []  # per player: [button, board], or null
var _shop: Node = null
var _hud_small: DynamicFont = null


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
		elif scene != null and scene.has_method("_get_reroll_button"):
			# Told by what it can do: naming the shop's classes here would load base_shop.gd
			# while the mods load, which breaks the game's shop scripts.
			_shop = scene
			call_deferred("_build_boards", scene)  # after the shop's own _ready wiring
	if _shop != null:
		_show_boards()


# 1,234 up to SHORT_FROM, then three digits and a unit: 12.3K, 456K, 7.89M.
static func short(number: int) -> String:
	if number < SHORT_FROM:
		return Text.get_formatted_number(int(max(0, number)))
	var value := float(number)
	var unit := -1
	while value >= 1000.0 and unit < UNITS.size() - 1:
		value /= 1000.0
		unit += 1
	var digits := 2 if value < 10.0 else (1 if value < 100.0 else 0)
	var text: String = ("%." + str(digits) + "f") % value
	# Rounding up can reach the next digit (9.999K) or the next unit (999.9K).
	if float(text) >= pow(10, 3 - digits) and digits > 0:
		digits -= 1
		text = ("%." + str(digits) + "f") % value
	if float(text) >= 1000.0 and unit < UNITS.size() - 1:
		unit += 1
		text = "%.2f" % (value / 1000.0)
	return text + UNITS[unit]


# Damage per second over the wave's time, "" before the wave has run a second.
static func per_second(total: int, time: float) -> String:
	return short(int(round(total / time))) + "/s" if time >= 1.0 else ""


# --- HUD ---


func _build_rows(main: Node) -> void:
	for p in RunData.get_player_count():
		var container = main.get_node_or_null("UI/HUD/LifeContainerP%d" % (p + 1))
		if container == null or container.has_node(ROW_NAME):
			_rows.append(null)
			continue
		var align := BoxContainer.ALIGN_END if p % 2 == 1 else BoxContainer.ALIGN_BEGIN
		var row := VBoxContainer.new()
		row.name = ROW_NAME
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_constant_override("separation", 0)
		row.modulate.a = 0.8 if RunData.is_coop_run else 1.0
		var main_line := _line("Main", align, 6)
		main_line.add_child(_icon(HUD_ICON, "Icon", load(TOTAL_ICON)))
		main_line.add_child(_label(load(HUD_FONT), "Total"))
		main_line.add_child(_label(_small_font(), "Share", MUTED))
		main_line.add_child(_label(_small_font(), "Dps", DPS_COLOR))
		row.add_child(main_line)
		var detail := _line("Detail", align, 4)
		for k in HUD_SOURCES:
			detail.add_child(_icon(HUD_SMALL_ICON, "Source%dIcon" % k))
			detail.add_child(_label(_small_font(), "Source%d" % k))
		detail.add_child(_icon(HUD_SMALL_ICON, "HitIcon", load(HIT_ICON)))
		detail.add_child(_label(_small_font(), "Hit", HIT_COLOR))
		row.add_child(detail)
		container.add_child(row)
		if p > 1:
			container.move_child(row, 0)  # the lower players' bars grow upwards
		_rows.append(row)
	_fill()


func _fill_row(row: VBoxContainer, entry: Array, share: int, hit: Array) -> void:
	row.visible = meter.shown and entry[0] > 0
	var main_line: Node = row.get_node("Main")
	main_line.get_node("Total").text = short(entry[0])
	_set_text(main_line.get_node("Share"), "%d%%" % share if share >= 0 else "")
	_set_text(main_line.get_node("Dps"), per_second(entry[0], meter.board.get("time", 0.0)))
	var detail: Node = row.get_node("Detail")
	for k in HUD_SOURCES:
		var icon: TextureRect = detail.get_node("Source%dIcon" % k)
		var label: Label = detail.get_node("Source%d" % k)
		var data = meter.data_of(entry[1][k][0]) if k < entry[1].size() else null
		icon.visible = data != null
		label.visible = data != null
		if data != null:
			icon.texture = data.icon
			label.text = short(entry[1][k][2])
	detail.get_node("HitIcon").visible = hit[0] > 0
	_set_text(detail.get_node("Hit"), short(hit[0]) if hit[0] > 0 else "")


func _small_font() -> DynamicFont:
	if _hud_small == null:
		_hud_small = load(HUD_FONT).duplicate()
		_hud_small.size = HUD_SMALL_SIZE
		_hud_small.extra_spacing_top = 0
	return _hud_small


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
		button.set_meta(REROLL_RIGHT_META, reroll.focus_neighbour_right)
		var board := _board()
		if slots.get_parent() is PanelContainer:
			slots.get_parent().add_child(board)  # co-op: the board fills the slots' place
		else:
			board.set_as_toplevel(true)  # solo: laid over the slots when it comes up
			slots.add_child(board)
		_boards.append([button, board])
	_fill()
	_apply_shown()


# The switch: the buttons come and go, and reroll's way to the right with them. A cursor that
# rests on a button that goes moves to reroll.
func _apply_shown() -> void:
	if not is_instance_valid(_shop):
		return
	for p in _boards.size():
		if _boards[p] == null or not is_instance_valid(_boards[p][0]):
			continue
		var button: Button = _boards[p][0]
		var reroll: Control = _shop._get_reroll_button(p)
		button.visible = meter.shown
		if meter.shown:
			reroll.focus_neighbour_right = reroll.get_path_to(button)
			continue
		reroll.focus_neighbour_right = button.get_meta(REROLL_RIGHT_META)
		var emulator = Utils.get_focus_emulator(p, _shop)
		if emulator != null and emulator.focused_control == button:
			emulator.focused_control = reroll
		elif button.has_focus():
			reroll.grab_focus()


# The board: List > Header (Title, TeamShare), Tiles (Total, Dps, Hit), a line, Sources
# (MAX_SOURCES rows of Icon, Name, Bar, Amount, Share).
func _board() -> PanelContainer:
	var board := PanelContainer.new()
	board.name = BOARD_NAME
	board.visible = false
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.border_color = LINE_COLOR
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_default_margin(MARGIN_LEFT, 16)
	style.set_default_margin(MARGIN_RIGHT, 16)
	style.set_default_margin(MARGIN_TOP, 12)
	style.set_default_margin(MARGIN_BOTTOM, 12)
	board.add_stylebox_override("panel", style)
	var font: Font = load(BOARD_FONT)
	var small: Font = load(BOARD_SMALL_FONT)
	var list := VBoxContainer.new()
	list.name = "List"
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.add_constant_override("separation", 8)
	board.add_child(list)
	var header := _line("Header", BoxContainer.ALIGN_BEGIN, 8)
	var title := _label(font, "Title", MUTED)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_label(small, "TeamShare", MUTED))
	list.add_child(header)
	var tiles := _line("Tiles", BoxContainer.ALIGN_BEGIN, 18)
	tiles.add_child(_tile("Total", "Damage", TOTAL_ICON, Color.white))
	tiles.add_child(_tile("Dps", "DPS", DPS_ICON, DPS_COLOR))
	var hit := _tile("Hit", "Biggest hit", HIT_ICON, HIT_COLOR)
	hit.get_node("Line").add_child(_icon(TILE_ICON, "SourceIcon"))
	tiles.add_child(hit)
	list.add_child(tiles)
	var line := HSeparator.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var line_style := StyleBoxLine.new()
	line_style.color = LINE_COLOR
	line_style.thickness = 2
	line.add_stylebox_override("separator", line_style)
	list.add_child(line)
	var sources := VBoxContainer.new()
	sources.name = "Sources"
	sources.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sources.add_constant_override("separation", 4)
	list.add_child(sources)
	for _i in meter.MAX_SOURCES:
		var row := _line("", BoxContainer.ALIGN_BEGIN, 10)
		row.add_child(_icon(BOARD_ICON, "Icon"))
		var name_label := _label(font, "Name")
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		row.add_child(name_label)
		row.add_child(_bar())
		var amount := _label(font, "Amount")
		amount.align = Label.ALIGN_RIGHT
		amount.rect_min_size.x = AMOUNT_WIDTH
		row.add_child(amount)
		var share := _label(small, "Share", MUTED)
		share.align = Label.ALIGN_RIGHT
		share.rect_min_size.x = SHARE_WIDTH
		row.add_child(share)
		sources.add_child(row)
	return board


# A tile: a caption over icon and value (Caption, Line > Icon, Value). Narrow enough for three
# in a row in a four-player shop panel.
func _tile(tile_name: String, caption: String, icon_path: String, color: Color) -> VBoxContainer:
	var tile := VBoxContainer.new()
	tile.name = tile_name
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_constant_override("separation", 0)
	var caption_label := _label(load(BOARD_SMALL_FONT), "Caption", MUTED)
	caption_label.text = caption
	tile.add_child(caption_label)
	var line := _line("Line", BoxContainer.ALIGN_BEGIN, 6)
	line.add_child(_icon(TILE_ICON, "Icon", load(icon_path)))
	line.add_child(_label(load(BOARD_FONT), "Value", color))
	tile.add_child(line)
	return tile


func _bar() -> ProgressBar:
	var bar := ProgressBar.new()
	bar.name = "Bar"
	bar.percent_visible = false
	bar.max_value = 1000
	bar.rect_min_size = BAR_SIZE
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for part in ["bg", "fg"]:
		var style := StyleBoxFlat.new()
		style.bg_color = BAR_BACK
		style.set_corner_radius_all(3)
		bar.add_stylebox_override(part, style)
	return bar


func _fill_board(board: PanelContainer, entry: Array, team_share: int, hit: Array) -> void:
	var list: Node = board.get_node("List")
	var wave: int = meter.board.get("wave", 0)
	var header: Node = list.get_node("Header")
	header.get_node("Title").text = Text.text("WAVE", [str(wave)])
	var team_text := "%d%% of the team" % team_share if team_share >= 0 else ""
	_set_text(header.get_node("TeamShare"), team_text)
	var tiles: Node = list.get_node("Tiles")
	tiles.get_node("Total/Line/Value").text = short(entry[0])
	var time: float = meter.board.get("time", 0.0)
	var dps := short(int(round(entry[0] / time))) if time >= 1.0 else "-"
	tiles.get_node("Dps/Line/Value").text = dps
	tiles.get_node("Hit/Line/Value").text = short(hit[0]) if hit[0] > 0 else "-"
	var hit_source = meter.data_of(hit[1]) if hit[1] != "" else null
	var source_icon: TextureRect = tiles.get_node("Hit/Line/SourceIcon")
	source_icon.visible = hit_source != null
	if hit_source != null:
		source_icon.texture = hit_source.icon
	var sources: Node = list.get_node("Sources")
	var top: int = entry[1][0][2] if not entry[1].empty() else 1
	for k in meter.MAX_SOURCES:
		var row: Node = sources.get_child(k)
		var source = entry[1][k] if k < entry[1].size() else null
		var data = meter.data_of(source[0]) if source != null else null
		row.visible = data != null
		if data == null:
			continue
		var color: Color = ItemService.get_color_from_tier(data.tier)
		row.get_node("Icon").texture = data.icon
		var name_label: Label = row.get_node("Name")
		name_label.text = tr(data.name) + (" x%d" % source[1] if source[1] > 1 else "")
		name_label.add_color_override("font_color", color)
		var bar: ProgressBar = row.get_node("Bar")
		bar.value = 1000.0 * source[2] / max(1, top)
		bar.get_stylebox("fg").bg_color = Color(color.r, color.g, color.b, 0.85)
		row.get_node("Amount").text = short(source[2])
		var share := int(round(100.0 * source[2] / max(1, entry[0])))
		row.get_node("Share").text = "%d%%" % share


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
		var up: bool = cursor == button or button.has_focus() or button.is_hovered()
		var board: Control = _boards[p][1]
		up = up and meter.shown and button.is_visible_in_tree()
		if board.visible != up:
			if up and board.is_set_as_toplevel():
				var slots: Control = board.get_parent()
				board.rect_global_position = slots.rect_global_position
				board.rect_size = slots.rect_size
			board.visible = up


# --- both ---


func _fill() -> void:
	var players: Array = meter.board.get("players", [])
	var hits: Array = meter.board.get("hits", [])
	var team := 0
	for entry in players:
		team += entry[0]
	for p in int(max(_rows.size(), _boards.size())):
		var entry: Array = players[p] if p < players.size() else [0, []]
		var hit: Array = hits[p] if p < hits.size() else [0, ""]
		# In co-op: the player's part of what the team dealt, else -1.
		var share := -1
		if players.size() > 1 and team > 0:
			share = int(round(100.0 * entry[0] / team))
		if p < _rows.size() and _rows[p] != null and is_instance_valid(_rows[p]):
			_fill_row(_rows[p], entry, share, hit)
		if p < _boards.size() and _boards[p] != null and is_instance_valid(_boards[p][1]):
			_fill_board(_boards[p][1], entry, share, hit)
	_apply_shown()


static func _line(line_name: String, align: int, separation: int) -> HBoxContainer:
	var line := HBoxContainer.new()
	if line_name != "":
		line.name = line_name
	line.alignment = align
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_constant_override("separation", separation)
	return line


static func _icon(size: Vector2, icon_name := "", texture: Texture = null) -> TextureRect:
	var icon := TextureRect.new()
	if icon_name != "":
		icon.name = icon_name
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.rect_min_size = size
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.texture = texture
	return icon


static func _label(font: Font, label_name := "", color := Color.white) -> Label:
	var label := Label.new()
	if label_name != "":
		label.name = label_name
	label.add_font_override("font", font)
	if color != Color.white:
		label.add_color_override("font_color", color)
	label.valign = Label.VALIGN_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


# Empty text: the label is gone too, so the line keeps no gap for it.
static func _set_text(label: Label, text: String) -> void:
	label.text = text
	label.visible = text != ""
