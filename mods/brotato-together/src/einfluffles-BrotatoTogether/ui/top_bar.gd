extends PanelContainer
# Character selection: the mod's panel at the top right, the counterpart of the game's DLC bar at
# the top left (ItemSetBar: the theme's PanelContainer style, panel_style.tres, its content 10 px
# apart, white 35 % separators between groups). One row, left to right:
#  - the colour hint "[F] / [Y]  Change colour" (ui/coop_selection.gd; co-op, host and client);
#  - a separator while both are shown;
#  - the online controls: Online, Invite friends, the lobby status (ui/online_options.gd; host).
# Every part uses the same font (22 px) and control height, centred on one line.
# A child of the scene root anchored to its top right corner, outside the game's layout
# containers: the game lays the screen out as without the mod. The row is wider than the free
# space right of the title's text (about 560 px), so it runs above the title and stays clear of
# it: its top is the DLC bar's (y 26), its bottom 7 px above the title label (y 75; the title's
# letters start at about y 84). The DLC bar and the Back button reach lower (y 101 / 83), but only
# left of the title's text. Hidden while none of its parts is shown.

const NODE_NAME := "BrotatoTogetherTopBar"
const FONT_PATH := "res://resources/fonts/actual/base/font_22.tres"
const MARGIN := 32  # from the right edge, as the Back button from the left one
const TOP := 26  # the DLC bar's top in co-op (ItemSetBar.horizontal_position)
const CONTROL_HEIGHT := 32  # the 22 px font (24 px high), the button style 4 px above and below
const BUTTON_MARGIN := 4  # the game's button style has 10 above and below; this row has no room
const SEPARATION := 10  # ItemSetBar's Content
const SEPARATOR_COLOR := Color(1, 1, 1, 0.35)  # ItemSetBar._add_separator
const SEPARATOR_WIDTH := 2
# Order of the parts in the row.
const HINT := 0
const ONLINE := 1

var _row := HBoxContainer.new()
var _parts := {}  # order -> Control
var _separator := ColorRect.new()


# The panel of a character selection scene, made on first use.
static func get_or_add(scene: Node) -> Control:
	var bar: Control = scene.get_node_or_null(NODE_NAME)
	if bar != null:
		return bar
	bar = load("res://mods-unpacked/einfluffles-BrotatoTogether/ui/top_bar.gd").new()
	bar.name = NODE_NAME
	# Drawn right after the Back button: under the cursors (focus emulators) and popups.
	var back: Node = scene.get_node_or_null("BackButton")
	if back != null:
		scene.add_child_below_node(back, bar)
	else:
		scene.add_child(bar)
	return bar


static func font() -> Font:
	return load(FONT_PATH) as Font


# The game's button style with less padding above and below, for one of the row's buttons.
static func fit_button(button: Button, names: Array) -> void:
	button.add_font_override("font", font())
	button.rect_min_size.y = CONTROL_HEIGHT
	for name in names:
		if not button.has_stylebox(name):
			continue
		var style: StyleBox = button.get_stylebox(name).duplicate()
		style.content_margin_top = BUTTON_MARGIN
		style.content_margin_bottom = BUTTON_MARGIN
		button.add_stylebox_override(name, style)


func _init() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN  # the right edge stays where it is
	margin_left = -MARGIN
	margin_right = -MARGIN
	margin_top = TOP
	margin_bottom = TOP
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_constant_override("separation", SEPARATION)
	add_child(_row)
	_separator.color = SEPARATOR_COLOR
	_separator.rect_min_size = Vector2(SEPARATOR_WIDTH, CONTROL_HEIGHT)
	_separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_separator)
	visible = false


# `part` into the row at its place (HINT / ONLINE), centred on the row's line.
func add_part(part: Control, order: int) -> void:
	_parts[order] = part
	part.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_row.add_child(part)
	var at := 0
	for key in [HINT, ONLINE]:
		if _parts.has(key) and is_instance_valid(_parts[key]):
			_row.move_child(_parts[key], at)
			at += 1
			if key == HINT:
				_row.move_child(_separator, at)
				at += 1
	_update()


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	var hint := _shown(HINT)
	var online := _shown(ONLINE)
	_separator.visible = hint and online
	if visible != (hint or online):
		visible = hint or online


func _shown(order: int) -> bool:
	var part = _parts.get(order)
	return part != null and is_instance_valid(part) and part.visible
