extends Node
# Where the damage meter (sync/damage_meter.gd) shows, on every machine, in the game's own
# screens:
# - In a wave: a block under each player's life bar (above it for the two lower players, in
#   reverse, so the total stays next to the bar). Main: the wave's total, in co-op the player's
#   share of the team's, and the damage per second. Below, one line per source (4, with 3 or 4
#   players 3: DamageMeter.live_sources), icon with the count in its corner, number; the
#   strongest first, the last line goes to the strongest of the other kind (weapon or not) when
#   it dealt 5% (DamageMeter.strongest). Last the biggest single hit, what dealt it tilted over
#   the crit icon. All icons in one 32 px column, so the numbers line up; on a dark rounded
#   backing as wide as the lines, against the battle's scenery; numbers short from 1,000
#   (7.01K). The right-hand players' lines are mirrored: the icons stay at the screen's edge.
# - In the co-op shop and the co-op end of run: a fourth page "Damage" in each player's carousel
#   (after Shop / Items and the two Stats pages), reached like the others with LB / RB or the
#   arrows. The panels build it in their own _ready (extensions/ui/coop_*_player_container.gd
#   call add_page), before any page from the network is applied. Online the page index travels
#   like the game's own pages (shop_sync, shop_intents, menu_sync).
# - In the solo shop and the solo end of run: a third tab "Damage" (an icon) in the stats panel
#   next to Primary / Secondary; LB / RB cycle through the three (extensions/ui/stats_container.gd).
# The board on a page or tab is the wave before: three tiles (the wave's total with, in co-op,
# the share of the team's; damage per second; biggest hit with its source), and the sources with
# icon, name over a bar against the strongest, number and share (56.83%, <0.01%).
# Numbers from 10,000 on are short (12.3K, 4.56M, 7.89B): late runs deal billions.
# All of it is gone while the meter is switched off on this machine (DamageMeter.shown): the
# page can no longer be reached (carousel.max_index) and a player on it goes back one page; the
# solo tab is hidden and an open one falls back to Primary.

const BATTLE_SCENE := "res://main.tscn"
const SOLO_END_RUN := "res://ui/menus/run/end_run.tscn"
const ROW_NAME := "DamageRow"
const PAGE_NAME := "DamagePage"
const HEADING_NAME := "DamageHeading"
const LIST_NAME := "DamageList"
const PAGE_TITLE := "Damage"
const ICON := "res://ui/icons/misc/weapon_icon.png"
const TOTAL_ICON := "res://items/stats/percent_damage.png"
const DPS_ICON := "res://items/stats/attack_speed.png"
const HIT_ICON := "res://items/stats/crit_chance.png"
const HUD_FONT := "res://resources/fonts/actual/base/font_26_outline.tres"
const BOARD_FONT := "res://resources/fonts/actual/base/font_26.tres"
const BOARD_SMALL_FONT := "res://resources/fonts/actual/base/font_smallest_text.tres"
# The HUD: one column of 32 px icons, so every number starts at the same x; the first line all
# at 22 (one baseline), amounts and the hit 20, 10 px between icon and number. A count sits in
# the icon's lower right corner, as in the game's inventory ("x3"); the biggest hit's source
# lies tilted over the crit icon.
const HUD_ICON := Vector2(32, 32)
const HUD_HIT_SOURCE := Vector2(26, 26)
const HUD_HIT_SOURCE_ANGLE := -20.0
const HUD_HIT_BURST := Color(1, 1, 1, 0.75)  # the crit icon under a source
const HUD_AMOUNT_SIZE := 20
const HUD_COUNT_SIZE := 16
const HUD_BADGE_OFFSET := Vector2(2, 4)  # past the icon's lower right corner, clear of the number
const HUD_OUTLINE := 2  # the smaller sizes' outline: they sit on the battle's scenery
const HUD_SEPARATION := 10
const HUD_MAIN_SIZE := 22
const HUD_GAP := 4  # between the total and the sources
const HUD_SHORT_FROM := 1000  # 7.01K, not 7,013, next to 41.7K
const HUD_AMOUNT_COLOR := Color(0.88, 0.88, 0.88)
const HUD_BACK := Color(0, 0, 0, 0.45)
const HUD_BACK_RADIUS := 6
const HUD_BACK_MARGIN := Vector2(8, 4)
const TILE_ICON := Vector2(22, 22)
const BOARD_ICON := Vector2(32, 32)
const BAR_HEIGHT := 6
const AMOUNT_WIDTH := 84
const SHARE_WIDTH := 80  # "100.00%"
const PAGE_MARGIN := 10
const SHORT_FROM := 10000
const UNITS := ["K", "M", "B", "T", "Q"]
const MUTED := Color(0.7, 0.7, 0.7)
const DPS_COLOR := Color(0.6, 0.85, 1.0)
const HIT_COLOR := Color(1.0, 0.8, 0.35)
const LINE_COLOR := Color(1, 1, 1, 0.12)
const BAR_BACK := Color(1, 1, 1, 0.1)
const PAGE_META := "brotato_together_damage_page"  # on a container: the page's carousel index

var meter: Node = null  # sync/damage_meter.gd (set by mod_main.gd)

var _scene_id := 0
var _rows := []  # per player: the HUD row, or null
var _views := []  # [holder, list]: a carousel container (page) or a StatsContainer (solo tab)
var _hud_fonts := {}  # size -> the HUD font at that size


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	meter.connect("changed", self, "_fill")


func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	var scene_id := scene.get_instance_id() if scene != null else 0
	if scene_id == _scene_id:
		return
	_scene_id = scene_id
	_rows = []
	if scene == null:
		return
	if scene.filename == BATTLE_SCENE:
		_build_rows(scene)
	elif _is_solo_shop(scene) or scene.filename == SOLO_END_RUN:
		add_tab(scene.get_node_or_null("%StatsContainer"))


# Told by what it can do: naming the shop's classes here would load base_shop.gd while the mods
# load, which breaks the game's shop scripts.
static func _is_solo_shop(scene: Node) -> bool:
	var shop: bool = scene.has_method("_get_reroll_button")
	return shop and not scene.has_method("_get_coop_player_container")


# A source's share of the player's total on the board, to two places: 56.83%, 0.04%; "<0.01%"
# for what dealt something but rounds to nothing (a few dozen next to millions).
static func percent(part: int, whole: int) -> String:
	if part <= 0 or whole <= 0:
		return "0.00%"
	var value := 100.0 * part / whole
	return "<0.01%" if value < 0.005 else "%.2f%%" % value


# 1,234 up to `from`, then three digits and a unit: 12.3K, 456K, 7.89M.
static func short(number: int, from := SHORT_FROM) -> String:
	if number < from:
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


# Damage per second over the wave's time, -1 before the wave has run a second.
static func per_second(total: int, time: float) -> int:
	return int(round(total / time)) if time >= 1.0 else -1


# --- HUD ---


func _build_rows(main: Node) -> void:
	for p in RunData.get_player_count():
		var container = main.get_node_or_null("UI/HUD/LifeContainerP%d" % (p + 1))
		if container == null or container.has_node(ROW_NAME):
			_rows.append(null)
			continue
		var right: bool = p % 2 == 1
		var lower: bool = p > 1  # their bars sit at the bottom: the block grows upwards
		var row := _hud_back(right)
		row.modulate.a = 0.8 if RunData.is_coop_run else 1.0
		var lines := VBoxContainer.new()
		lines.name = "Lines"
		lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lines.add_constant_override("separation", 2)
		row.add_child(lines)
		var main_line := _hud_line("Main", right, [
			_icon(HUD_ICON, "Icon", load(TOTAL_ICON)),
			_label(_hud_font(HUD_MAIN_SIZE), "Total"),
			_label(_hud_font(HUD_MAIN_SIZE), "Share", MUTED),
			_label(_hud_font(HUD_MAIN_SIZE), "Dps", DPS_COLOR),
		])
		var gap := Control.new()
		gap.name = "Gap"
		gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gap.rect_min_size.y = HUD_GAP
		var sources := VBoxContainer.new()
		sources.name = "Sources"
		sources.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sources.add_constant_override("separation", 2)
		var source_lines := []
		for k in meter.LIVE_SOURCES:
			source_lines.append(_hud_line("Source%d" % k, right, [
				_badged_icon(),
				_label(_hud_font(HUD_AMOUNT_SIZE), "Amount", HUD_AMOUNT_COLOR),
			]))
		var hit_line := _hud_line("Hit", right, [
			_hit_icon(),
			_label(_hud_font(HUD_AMOUNT_SIZE), "Value", HIT_COLOR),
		])
		# The strongest source next to the total, the hit farthest from the bar.
		for line in _ordered(source_lines, lower):
			sources.add_child(line)
		for part in _ordered([main_line, gap, sources, hit_line], lower):
			lines.add_child(part)
		container.add_child(row)
		if lower:
			container.move_child(row, 0)
		_rows.append(row)
	_fill()


# A HUD line of these parts, mirrored for a right-hand player: the first part (the icon) at the
# screen's edge.
static func _hud_line(line_name: String, right: bool, parts: Array) -> Node:
	var align := BoxContainer.ALIGN_END if right else BoxContainer.ALIGN_BEGIN
	var line := _line(line_name, align, HUD_SEPARATION)
	for part in _ordered(parts, right):
		line.add_child(part)
	return line


# A source's icon (Icon) with its count (Count) in the lower right corner, a little past it, as
# the game's inventory shows one.
func _badged_icon() -> TextureRect:
	var icon := _icon(HUD_ICON, "Icon")
	var count := _label(_hud_font(HUD_COUNT_SIZE), "Count")
	count.align = Label.ALIGN_RIGHT
	count.valign = Label.VALIGN_BOTTOM
	count.anchor_left = 1.0
	count.anchor_top = 1.0
	count.anchor_right = 1.0
	count.anchor_bottom = 1.0
	count.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	count.grow_vertical = Control.GROW_DIRECTION_BEGIN
	count.margin_left = HUD_BADGE_OFFSET.x
	count.margin_right = HUD_BADGE_OFFSET.x
	count.margin_top = HUD_BADGE_OFFSET.y
	count.margin_bottom = HUD_BADGE_OFFSET.y
	icon.add_child(count)
	return icon


# The crit icon (Icon) with the source of the biggest hit (Source) tilted over its middle.
static func _hit_icon() -> TextureRect:
	var burst := _icon(HUD_ICON, "Icon", load(HIT_ICON))
	var source := _icon(HUD_HIT_SOURCE, "Source")
	source.anchor_left = 0.5
	source.anchor_top = 0.5
	source.anchor_right = 0.5
	source.anchor_bottom = 0.5
	source.margin_left = -HUD_HIT_SOURCE.x / 2
	source.margin_right = HUD_HIT_SOURCE.x / 2
	source.margin_top = -HUD_HIT_SOURCE.y / 2
	source.margin_bottom = HUD_HIT_SOURCE.y / 2
	source.rect_pivot_offset = HUD_HIT_SOURCE / 2
	source.rect_rotation = HUD_HIT_SOURCE_ANGLE
	burst.add_child(source)
	return burst


# The HUD block's backing: a dark rounded panel as wide as its lines, at the screen's edge.
static func _hud_back(right: bool) -> PanelContainer:
	var back := PanelContainer.new()
	back.name = ROW_NAME
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.size_flags_horizontal = Control.SIZE_SHRINK_END if right else 0
	var style := StyleBoxFlat.new()
	style.bg_color = HUD_BACK
	style.set_corner_radius_all(HUD_BACK_RADIUS)
	style.content_margin_left = HUD_BACK_MARGIN.x
	style.content_margin_right = HUD_BACK_MARGIN.x
	style.content_margin_top = HUD_BACK_MARGIN.y
	style.content_margin_bottom = HUD_BACK_MARGIN.y
	back.add_stylebox_override("panel", style)
	return back


static func _ordered(parts: Array, reverse: bool) -> Array:
	var ordered := parts.duplicate()
	if reverse:
		ordered.invert()
	return ordered


func _fill_row(row: Control, entry: Array, share: int, hit: Array) -> void:
	row.visible = meter.shown and entry[0] > 0
	var lines: Node = row.get_node("Lines")
	var main_line: Node = lines.get_node("Main")
	main_line.get_node("Total").text = short(entry[0], HUD_SHORT_FROM)
	_set_text(main_line.get_node("Share"), "%d%%" % share if share >= 0 else "")
	var dps := per_second(entry[0], meter.board.get("time", 0.0))
	_set_text(main_line.get_node("Dps"), short(dps, HUD_SHORT_FROM) + "/s" if dps >= 0 else "")
	for k in meter.LIVE_SOURCES:
		var line: Node = lines.get_node("Sources/Source%d" % k)
		var source = entry[1][k] if k < entry[1].size() else null
		var data = meter.data_of(source[0]) if source != null else null
		line.visible = data != null
		if data != null:
			line.get_node("Icon").texture = data.icon
			_set_text(line.get_node("Icon/Count"), "x%d" % source[1] if source[1] > 1 else "")
			line.get_node("Amount").text = short(source[2], HUD_SHORT_FROM)
	var hit_line: Node = lines.get_node("Hit")
	hit_line.visible = hit[0] > 0
	hit_line.get_node("Value").text = short(hit[0], HUD_SHORT_FROM) if hit[0] > 0 else ""
	var hit_source = meter.data_of(hit[1]) if hit[1] != "" else null
	var source_icon: TextureRect = hit_line.get_node("Icon/Source")
	source_icon.visible = hit_source != null
	# Under a source the burst steps back, so the weapon reads.
	hit_line.get_node("Icon").self_modulate = HUD_HIT_BURST if hit_source != null else Color.white
	if hit_source != null:
		source_icon.texture = hit_source.icon


func _hud_font(size: int) -> DynamicFont:
	if not _hud_fonts.has(size):
		var font: DynamicFont = load(HUD_FONT).duplicate()
		font.size = size
		font.outline_size = HUD_OUTLINE
		font.extra_spacing_top = 0
		_hud_fonts[size] = font
	return _hud_fonts[size]


# --- the pages and the tab ---


# A co-op player container (shop or end of run): a heading and a page at the end of its
# carousel. Called from the container's own _ready.
func add_page(container: Control) -> void:
	var carousel = container.get("carousel")
	if carousel == null or container.has_meta(PAGE_META):
		return
	var headings: Node = carousel.get_node("%Headings")
	var content: Node = carousel.get_node("%Content")
	var heading: Label = headings.get_child(headings.get_child_count() - 1).duplicate()
	heading.name = HEADING_NAME
	heading.text = PAGE_TITLE
	heading.visible = false
	headings.add_child(heading)
	var page := MarginContainer.new()
	page.name = PAGE_NAME
	page.anchor_right = 1.0
	page.anchor_bottom = 1.0
	page.visible = false
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_right", "margin_top"]:
		page.add_constant_override(side, PAGE_MARGIN)
	var list := _board_list()
	list.size_flags_vertical = 0  # its own height, at the top
	page.add_child(list)
	content.add_child(page)
	container.set_meta(PAGE_META, headings.get_child_count() - 1)
	carousel.index = carousel.index  # the setter: arrows for the new last page
	_add_view(container, list)


# The solo stats panel (shop, end of run): a third tab. StatsContainer is extended
# (extensions/ui/stats_container.gd) and inert until this arms it.
func add_tab(stats: Node) -> void:
	if stats == null or not stats.has_method("bt_add_tab") or stats.bt_has_tab():
		return
	var page := MarginContainer.new()
	page.name = PAGE_NAME
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(_board_list())
	stats.bt_add_tab(page, load(ICON))
	_add_view(stats, page.get_child(0))


func _add_view(holder: Control, list: Control) -> void:
	_drop_view(holder)
	_views.append([holder, list])
	holder.connect("tree_exiting", self, "_drop_view", [holder], CONNECT_ONESHOT)
	_fill()


# A screen that goes takes its views along: no reference to a freed node stays here.
func _drop_view(holder: Control) -> void:
	var kept := []
	for view in _views:
		if is_instance_valid(view[0]) and view[0] != holder:
			kept.append(view)
	_views = kept


# The board: List > Tiles (Total: the wave over total and team share; Dps; Hit), a line,
# Sources (MAX_SOURCES rows of Icon, Text > Name over Bar, Amount, Share).
func _board_list() -> VBoxContainer:
	var font: Font = load(BOARD_FONT)
	var small: Font = load(BOARD_SMALL_FONT)
	var list := VBoxContainer.new()
	list.name = LIST_NAME
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.add_constant_override("separation", 8)
	var tiles := _line("Tiles", BoxContainer.ALIGN_BEGIN, 12)
	var total := _tile("Total", "", TOTAL_ICON, Color.white)
	total.get_node("Line").add_child(_label(small, "Share", MUTED))
	tiles.add_child(total)
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
		var text := VBoxContainer.new()
		text.name = "Text"
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text.add_constant_override("separation", 0)
		var name_label := _label(font, "Name")
		name_label.clip_text = true
		text.add_child(name_label)
		text.add_child(_bar())
		row.add_child(text)
		var amount := _label(font, "Amount")
		amount.align = Label.ALIGN_RIGHT
		amount.rect_min_size.x = AMOUNT_WIDTH
		row.add_child(amount)
		var share := _label(small, "Share", MUTED)
		share.align = Label.ALIGN_RIGHT
		share.rect_min_size.x = SHARE_WIDTH
		row.add_child(share)
		sources.add_child(row)
	return list


# A tile: a caption over icon and value (Caption, Line > Icon, Value). Narrow enough for three
# in a row in a four-player panel.
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
	bar.rect_min_size.y = BAR_HEIGHT
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for part in ["bg", "fg"]:
		var style := StyleBoxFlat.new()
		style.bg_color = BAR_BACK
		style.set_corner_radius_all(3)
		bar.add_stylebox_override(part, style)
	return bar


func _fill_board(list: Node, entry: Array, team_share: int, hit: Array) -> void:
	var wave: int = meter.board.get("wave", 0)
	var tiles: Node = list.get_node("Tiles")
	tiles.get_node("Total/Caption").text = Text.text("WAVE", [str(wave)])
	tiles.get_node("Total/Line/Value").text = short(entry[0])
	_set_text(tiles.get_node("Total/Line/Share"), "%d%%" % team_share if team_share >= 0 else "")
	var dps := per_second(entry[0], meter.board.get("time", 0.0))
	tiles.get_node("Dps/Line/Value").text = short(dps) if dps >= 0 else "-"
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
		var name_label: Label = row.get_node("Text/Name")
		name_label.text = tr(data.name) + (" x%d" % source[1] if source[1] > 1 else "")
		name_label.add_color_override("font_color", color)
		var bar: ProgressBar = row.get_node("Text/Bar")
		bar.value = 1000.0 * source[2] / max(1, top)
		bar.get_stylebox("fg").bg_color = Color(color.r, color.g, color.b, 0.85)
		row.get_node("Amount").text = short(source[2])
		row.get_node("Share").text = percent(source[2], entry[0])


# The switch: the page stays in the carousel but past its max_index; a player on it goes back
# one page, as if they had pressed LB. The solo tab is hidden.
func _apply_shown(holder: Control) -> void:
	if holder.has_method("bt_set_tab_enabled"):
		holder.bt_set_tab_enabled(meter.shown)
		return
	var carousel = holder.carousel
	var page: int = holder.get_meta(PAGE_META)
	var limit := -1 if meter.shown else page - 1
	if carousel.max_index == limit:
		return
	carousel.max_index = limit
	if not meter.shown and carousel.index >= page:
		carousel.index = page - 1
		holder._on_Carousel_index_changed(carousel.index)
	else:
		carousel.index = carousel.index  # the setter: arrows for the new last page
	# Without trigger glyphs the arrows take the cursor; one that is now the disabled end of the
	# row hands it to the other, as the carousel does itself after a page change.
	var emulator = Utils.get_focus_emulator(holder.player_index, get_tree().current_scene)
	var arrows: Array = [carousel.arrow_left, carousel.arrow_right]
	for k in 2:
		if emulator != null and emulator.focused_control == arrows[k] and arrows[k].disabled:
			if not arrows[1 - k].disabled:
				emulator.focused_control = arrows[1 - k]


# --- both ---


func _fill() -> void:
	var players: Array = meter.board.get("players", [])
	var hits: Array = meter.board.get("hits", [])
	var team := 0
	for entry in players:
		team += entry[0]
	for p in _rows.size():
		if _rows[p] != null and is_instance_valid(_rows[p]):
			_fill_row(_rows[p], _entry(players, p), _share(players, p, team), _hit(hits, p))
	for view in _views:
		if not is_instance_valid(view[0]):
			continue
		var holder: Control = view[0]
		var p: int = holder.get("player_index") if holder.get("player_index") != null else 0
		p = int(max(0, p))
		_fill_board(view[1], _entry(players, p), _share(players, p, team), _hit(hits, p))
		_apply_shown(holder)


static func _entry(players: Array, p: int) -> Array:
	return players[p] if p < players.size() else [0, []]


static func _hit(hits: Array, p: int) -> Array:
	return hits[p] if p < hits.size() else [0, ""]


# In co-op: the player's part of what the team dealt, else -1.
static func _share(players: Array, p: int, team: int) -> int:
	if players.size() < 2 or team <= 0:
		return -1
	return int(round(100.0 * _entry(players, p)[0] / team))


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
