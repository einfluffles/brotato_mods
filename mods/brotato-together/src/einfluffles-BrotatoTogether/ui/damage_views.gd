extends Node
# Where the damage meter shows: a block at each player's life bar in a wave, a carousel page in
# the co-op shop / end of run, a third stats tab in the solo ones. The shop shows the wave before
# it, the end of run the whole run (the board's "run", else that wave too). All of it is gone
# while the meter is switched off on this machine (DamageMeter.shown), except the pages of players
# on other machines.

const BATTLE_SCENE := "res://main.tscn"
const SOLO_END_RUN := "res://ui/menus/run/end_run.tscn"
const ROW_NAME := "DamageRow"
const PAGE_NAME := "DamagePage"
const HEADING_NAME := "DamageHeading"
const LIST_NAME := "DamageList"
# Texts are translation keys (the game's or translations.csv's). A label translates a key in its
# text itself; built texts are built again when the language changes (_notification).
const PAGE_TITLE := "STAT_DAMAGE"
const RUN_TITLE := "BT_DMG_RUN"  # {0}: the waves
const OTHER_ROW := "Other"  # the node name of the row of what no shown source holds
const OTHER_TEXT := "BT_DMG_OTHER"  # its text
const INCLUDED := "BT_DMG_INCLUDED"  # an overlapping source's share (in another row's damage)
const KILLS := "BT_DMG_KILLS"  # {0}: the number
const TAKEN := "BT_DMG_TAKEN"
const ICON := "res://ui/icons/misc/weapon_icon.png"
const TOTAL_ICON := "res://items/stats/percent_damage.png"
const DPS_ICON := "res://items/stats/attack_speed.png"
const HIT_ICON := "res://items/stats/crit_chance.png"
const HUD_FONT := "res://resources/fonts/actual/base/font_26_outline.tres"
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
const STAT_ICON := Vector2(28, 28)
const STAT_HIT_SOURCE := Vector2(22, 22)
const STAT_GAP := 12  # between total, damage per second and hit, past the line's 6
const BOARD_ICON := Vector2(32, 32)
const ROW_HEIGHT := 40
const ROW_RADIUS := 6
const ROW_BORDER := 2
const ROW_BORDER_COLOR := Color(0, 0, 0, 0.5)
const ROW_BACK := Color(0, 0, 0, 0.25)
const ROW_FILL_ALPHA := 0.55
const INCLUDED_FILL_ALPHA := 0.25
const OTHER_FILL := Color(0.6, 0.6, 0.6, 0.4)
const ROW_MARGIN := Vector2(6, 10)  # left (before the icon), right (after the share)
const ROW_SEPARATION := 10
const ROW_SHARE_SIZE := 18
const ROW_SHARE_COLOR := Color(1, 1, 1, 0.75)
const AMOUNT_WIDTH := 84
const SHARE_WIDTH := 80  # "100.00%"
const PAGE_MARGIN := 10
const SHORT_FROM := 10000
const UNITS := ["K", "M", "B", "T", "Q"]
const MUTED := Color(0.7, 0.7, 0.7)
const DPS_COLOR := Color(0.6, 0.85, 1.0)
const HIT_COLOR := Color(1.0, 0.8, 0.35)
const LINE_COLOR := Color(1, 1, 1, 0.12)
const PAGE_META := "brotato_together_damage_page"  # on a container: the page's carousel index

var meter: Node = null

var _scene_id := 0
var _rows := []  # per player: the HUD row, or null
# [holder, list, run]: a carousel container (page) or a StatsContainer (solo tab); run: an end of
# run's, which shows the run.
var _views := []
var _hud_fonts := {}  # size -> the HUD font at that size


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	meter.connect("changed", self, "_fill")


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and meter != null:
		_fill()


func _process(_delta: float) -> void:
	for view in _views:  # who plays a panel here can change (slots, the client's own one)
		if is_instance_valid(view[0]):
			_apply_shown(view[0])
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
		add_tab(scene.get_node_or_null("%StatsContainer"), scene.filename == SOLO_END_RUN)


# Told by what it can do: naming the shop's classes here would load them at mod init.
static func _is_solo_shop(scene: Node) -> bool:
	var shop: bool = scene.has_method("_get_reroll_button")
	return shop and not scene.has_method("_get_coop_player_container")


# To two places; "<0.01%" for what dealt something but rounds to nothing.
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


static func per_second(total: int, time: float) -> int:
	return int(round(total / time)) if time >= 1.0 else -1


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


# Mirrored for a right-hand player: the first part (the icon) stays at the screen's edge.
static func _hud_line(line_name: String, right: bool, parts: Array) -> Node:
	var align := BoxContainer.ALIGN_END if right else BoxContainer.ALIGN_BEGIN
	var line := _line(line_name, align, HUD_SEPARATION)
	for part in _ordered(parts, right):
		line.add_child(part)
	return line


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


static func _hit_icon(
	size := HUD_ICON, source_size := HUD_HIT_SOURCE, icon_name := "Icon"
) -> TextureRect:
	var burst := _icon(size, icon_name, load(HIT_ICON))
	var source := _icon(source_size, "Source")
	source.anchor_left = 0.5
	source.anchor_top = 0.5
	source.anchor_right = 0.5
	source.anchor_bottom = 0.5
	source.margin_left = -source_size.x / 2
	source.margin_right = source_size.x / 2
	source.margin_top = -source_size.y / 2
	source.margin_bottom = source_size.y / 2
	source.rect_pivot_offset = source_size / 2
	source.rect_rotation = HUD_HIT_SOURCE_ANGLE
	burst.add_child(source)
	return burst


# id: what dealt the biggest hit, "" when unknown.
func _show_hit_source(burst: TextureRect, id: String) -> void:
	var data = meter.data_of(id) if id != "" else null
	var source: TextureRect = burst.get_node("Source")
	source.visible = data != null
	burst.self_modulate = HUD_HIT_BURST if data != null else Color.white
	if data != null:
		source.texture = data.icon


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
	_show_hit_source(hit_line.get_node("Icon"), hit[1])


func _hud_font(size: int) -> DynamicFont:
	if not _hud_fonts.has(size):
		var font: DynamicFont = load(HUD_FONT).duplicate()
		font.size = size
		font.outline_size = HUD_OUTLINE
		font.extra_spacing_top = 0
		_hud_fonts[size] = font
	return _hud_fonts[size]


# For a co-op player container (shop or end of run), from its own _ready: the page has to exist
# before a page index from the network is applied to the carousel.
func add_page(container: Control, run := false) -> void:
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
	_add_view(container, list, run)


# The solo stats panel's third tab. The StatsContainer extension is inert until this arms it.
func add_tab(stats: Node, run := false) -> void:
	if stats == null or not stats.has_method("bt_add_tab") or stats.bt_has_tab():
		return
	var page := MarginContainer.new()
	page.name = PAGE_NAME
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(_board_list())
	stats.bt_add_tab(page, load(ICON))
	_add_view(stats, page.get_child(0), run)


func _add_view(holder: Control, list: Control, run: bool) -> void:
	_drop_view(holder)
	_views.append([holder, list, run])
	holder.connect("tree_exiting", self, "_drop_view", [holder], CONNECT_ONESHOT)
	_fill()


# A screen that goes takes its views along: no reference to a freed node stays here.
func _drop_view(holder: Control) -> void:
	var kept := []
	for view in _views:
		if is_instance_valid(view[0]) and view[0] != holder:
			kept.append(view)
	_views = kept


# List > Head (Wave: the title; Stats: TotalIcon, Total, Share, DpsIcon, Dps, HitIcon > Source,
# Hit; Extra: Kills, Taken, the run's, side by side or one under the other), a line, Sources
# (MAX_SOURCES bars and Other, each with Content > Icon, Name, Amount, Share).
func _board_list() -> VBoxContainer:
	var font := _hud_font(HUD_MAIN_SIZE)
	var list := VBoxContainer.new()
	list.name = LIST_NAME
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.add_constant_override("separation", 8)
	var head := VBoxContainer.new()
	head.name = "Head"
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_constant_override("separation", 0)
	head.add_child(_label(font, "Wave", MUTED))
	var stats := _line("Stats", BoxContainer.ALIGN_BEGIN, 6)
	stats.add_child(_icon(STAT_ICON, "TotalIcon", load(TOTAL_ICON)))
	stats.add_child(_label(font, "Total"))
	stats.add_child(_label(font, "Share", MUTED))
	stats.add_child(_spacer(STAT_GAP))
	stats.add_child(_icon(STAT_ICON, "DpsIcon", load(DPS_ICON)))
	stats.add_child(_label(font, "Dps", DPS_COLOR))
	stats.add_child(_spacer(STAT_GAP))
	stats.add_child(_hit_icon(STAT_ICON, STAT_HIT_SOURCE, "HitIcon"))
	stats.add_child(_label(font, "Hit", HIT_COLOR))
	head.add_child(stats)
	var extra := GridContainer.new()
	extra.name = "Extra"
	extra.columns = 2
	extra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	extra.add_constant_override("hseparation", STAT_GAP)
	extra.add_constant_override("vseparation", 0)
	extra.visible = false
	extra.add_child(_label(load(HUD_FONT), "Kills", MUTED))
	extra.add_child(_label(load(HUD_FONT), "Taken", MUTED))
	head.add_child(extra)
	list.add_child(head)
	list.connect("resized", self, "_fit_extra", [list])
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
	for i in meter.MAX_SOURCES + 1:
		var row := _bar()
		if i == meter.MAX_SOURCES:
			row.name = OTHER_ROW
		var content := _line("Content", BoxContainer.ALIGN_BEGIN, ROW_SEPARATION)
		content.anchor_right = 1.0
		content.anchor_bottom = 1.0
		content.margin_left = ROW_MARGIN.x
		content.margin_right = -ROW_MARGIN.y
		content.add_child(_icon(BOARD_ICON, "Icon"))
		var name_label := _label(load(HUD_FONT), "Name")
		name_label.clip_text = true
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.add_child(name_label)
		var amount := _label(load(HUD_FONT), "Amount")
		amount.align = Label.ALIGN_RIGHT
		amount.rect_min_size.x = AMOUNT_WIDTH
		content.add_child(amount)
		var share := _label(_hud_font(ROW_SHARE_SIZE), "Share", ROW_SHARE_COLOR)
		share.align = Label.ALIGN_RIGHT
		share.rect_min_size.x = SHARE_WIDTH
		content.add_child(share)
		row.add_child(content)
		sources.add_child(row)
	return list


# Kills and Damage taken side by side while they fit in the board's width, else one under the
# other (a long translation): the board keeps its panel's width. Side by side they make the board
# just as wide when they do not fit; one under the other the board has its own width again.
func _fit_extra(list: Control) -> void:
	var extra: GridContainer = list.get_node("Head/Extra")
	if not extra.visible:
		return
	var both: float = STAT_GAP
	for label in extra.get_children():  # the font's width: the minimum size may be stale yet
		both += label.get_font("font").get_string_size(label.text).x
	var width := list.rect_size.x
	if extra.columns == 2 and width < both + 0.5:
		extra.columns = 1
	elif extra.columns == 1 and both + 1.0 <= width:
		extra.columns = 2


static func _spacer(width: int) -> Control:
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.rect_min_size.x = width
	return spacer


# The bar is the row's own background; its parts go on top (Content).
static func _bar() -> ProgressBar:
	var bar := ProgressBar.new()
	bar.percent_visible = false
	bar.max_value = 1000
	bar.rect_min_size.y = ROW_HEIGHT
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for part in ["bg", "fg"]:
		var style := StyleBoxFlat.new()
		style.bg_color = ROW_BACK
		style.set_corner_radius_all(ROW_RADIUS)
		style.set_border_width_all(ROW_BORDER)
		style.border_color = ROW_BORDER_COLOR
		bar.add_stylebox_override(part, style)
	return bar


# entry: [total, sources]; shown: {title, time, extra: [kills, damage taken] or []}.
func _fill_board(list: Node, entry: Array, team_share: int, hit: Array, shown: Dictionary) -> void:
	list.get_node("Head/Wave").text = shown.title
	var stats: Node = list.get_node("Head/Stats")
	stats.get_node("Total").text = short(entry[0])
	_set_text(stats.get_node("Share"), "%d%%" % team_share if team_share >= 0 else "")
	var dps := per_second(entry[0], shown.time)
	stats.get_node("Dps").text = short(dps) + "/s" if dps >= 0 else "-"
	stats.get_node("Hit").text = short(hit[0]) if hit[0] > 0 else "-"
	_show_hit_source(stats.get_node("HitIcon"), hit[1])
	var extra: Node = list.get_node("Head/Extra")
	extra.visible = not shown.extra.empty()
	if extra.visible:
		extra.get_node("Kills").text = Text.text(KILLS, [short(shown.extra[0])])
		extra.get_node("Taken").text = Text.text(TAKEN, [short(shown.extra[1])])
		_fit_extra(list)
	var sources: Node = list.get_node("Sources")
	var top: int = entry[1][0][2] if not entry[1].empty() else 1
	var listed := 0  # what the shown rows that hold no other row's damage dealt
	for k in meter.MAX_SOURCES:
		var row: Node = sources.get_child(k)
		var source = entry[1][k] if k < entry[1].size() else null
		var data = meter.data_of(source[0]) if source != null else null
		row.visible = data != null
		if data == null:
			continue
		var included: bool = meter.overlaps(source[0])
		if not included:
			listed += source[2]
		var color: Color = ItemService.get_color_from_tier(data.tier)
		var alpha := INCLUDED_FILL_ALPHA if included else ROW_FILL_ALPHA
		var content: Node = row.get_node("Content")
		content.get_node("Icon").texture = data.icon
		var name_text: String = tr(data.name) + (" x%d" % source[1] if source[1] > 1 else "")
		content.get_node("Name").text = name_text
		row.value = 1000.0 * source[2] / max(1, top)
		row.get_stylebox("fg").bg_color = Color(color.r, color.g, color.b, alpha)
		content.get_node("Amount").text = short(source[2])
		content.get_node("Share").text = INCLUDED if included else percent(source[2], entry[0])
	_fill_other(sources.get_node(OTHER_ROW), entry[0], entry[0] - listed, top)


# Sources past the shown ones and damage no counter holds: with it the shares add up to 100%.
func _fill_other(row: ProgressBar, total: int, other: int, top: int) -> void:
	row.visible = other > 0
	if other <= 0:
		return
	var content: Node = row.get_node("Content")
	content.get_node("Icon").texture = null
	content.get_node("Name").text = OTHER_TEXT
	row.value = 1000.0 * other / max(1, max(top, other))
	row.get_stylebox("fg").bg_color = OTHER_FILL
	content.get_node("Amount").text = short(other)
	content.get_node("Share").text = percent(other, total)


# Switched off, the page stays in the carousel but past its max_index, and a player on it goes
# back one page. The solo tab is hidden. Another machine's player keeps the page (shown_for).
func _apply_shown(holder: Control) -> void:
	if holder.has_method("bt_set_tab_enabled"):
		holder.bt_set_tab_enabled(meter.shown)
		return
	var carousel = holder.carousel
	var page: int = holder.get_meta(PAGE_META)
	var p = holder.get("player_index")
	var shown: bool = meter.shown_for(p if p != null else -1)
	var limit := -1 if shown else page - 1
	if carousel.max_index == limit:
		return
	carousel.max_index = limit
	if not shown and carousel.index >= page:
		carousel.index = page - 1
		holder._on_Carousel_index_changed(carousel.index)
	else:
		carousel.index = carousel.index  # the setter, as in add_page
	# Without trigger glyphs the arrows take the cursor; one that is now the disabled end of the
	# row hands it to the other, as the carousel does itself after a page change.
	var emulator = Utils.get_focus_emulator(holder.player_index, get_tree().current_scene)
	var arrows: Array = [carousel.arrow_left, carousel.arrow_right]
	for k in 2:
		if emulator != null and emulator.focused_control == arrows[k] and arrows[k].disabled:
			if not arrows[1 - k].disabled:
				emulator.focused_control = arrows[1 - k]


func _fill() -> void:
	var players: Array = meter.board.get("players", [])
	var hits: Array = meter.board.get("hits", [])
	var team := _team(players)
	for p in _rows.size():
		if _rows[p] != null and is_instance_valid(_rows[p]):
			_fill_row(_rows[p], _entry(players, p), _share(players, p, team), _hit(hits, p))
	var wave := {
		"title": Text.text("WAVE", [str(meter.board.get("wave", 0))]),
		"time": meter.board.get("time", 0.0),
		"extra": [],
	}
	var run: Dictionary = meter.board.get("run", {})
	var run_players: Array = run.get("players", [])
	var run_team := _team(run_players)
	var waves: int = run.get("waves", 0)
	var whole := {
		"title": Text.text(RUN_TITLE, [str(waves)]),
		"time": run.get("time", 0.0),
	}
	for view in _views:
		if not is_instance_valid(view[0]):
			continue
		var holder: Control = view[0]
		var p: int = holder.get("player_index") if holder.get("player_index") != null else 0
		p = int(max(0, p))
		if view[2] and not run.empty():
			var entry: Array = run_players[p] if p < run_players.size() else [0, [], [0, ""], 0, 0]
			whole["extra"] = [entry[3], entry[4]]
			var share := _share(run_players, p, run_team)
			_fill_board(view[1], [entry[0], entry[1]], share, entry[2], whole)
		else:
			_fill_board(view[1], _entry(players, p), _share(players, p, team), _hit(hits, p), wave)
		_apply_shown(holder)


static func _team(players: Array) -> int:
	var team := 0
	for entry in players:
		team += entry[0]
	return team


static func _entry(players: Array, p: int) -> Array:
	return players[p] if p < players.size() else [0, []]


static func _hit(hits: Array, p: int) -> Array:
	return hits[p] if p < hits.size() else [0, ""]


# -1 outside co-op.
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
