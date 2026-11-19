extends MarginContainer
# The lobby on the title screen's main menu: a small frame beside the game's buttons while this
# game is in a lobby, with the players (the host can kick) and Leave lobby. The entry button
# ui/lobby_menu.gd added below Start does what is next: Host lobby, Invite friends, Leave lobby.

const NODE_NAME := "BrotatoTogetherLobbyFrame"
const PANEL_STYLE_PATH := "res://resources/themes/panel/panel_style.tres"
const BUTTON_SCRIPT_PATH := "res://ui/menus/global/my_menu_button.gd"
const NAME_FONT_PATH := "res://resources/fonts/actual/base/font_26.tres"
const SMALL_FONT_PATH := "res://resources/fonts/actual/base/font_22.tres"
const TITLE := "Online co-op"
const HOST_TEXT := "Host lobby"
const CREATING_TEXT := "Creating lobby…"
const INVITE_TEXT := "Invite friends"
const LEAVE_TEXT := "Leave lobby"
const KICK_TEXT := "Kick"
const WIDTH := 520
const GAP := 30  # to the button column

var lobby: Node = null
var title_screen: Node = null
var main_menu: Node = null
var entry_button: Button = null

var rows := []  # as shown: [{id, name: Label, note: Label, kick: Button or null}]
var leave_button: Button = null
var hint := Label.new()

var _count := Label.new()
var _list := VBoxContainer.new()
var _rows_hosting := false
var _entry_right := NodePath()  # the entry button's neighbour without the frame
var _locked := false  # Start / Continue switched off by us


# Null: the main menu's buttons are not laid out as expected.
static func add_to(scene: Node, menu: Node, entry: Button, lobby_menu: Node) -> Control:
	var column: Node = entry.get_parent()
	var row: Node = column.get_parent()
	if not (row is BoxContainer) or row.has_node(NODE_NAME):
		return null
	var frame: MarginContainer = load(
		"res://mods-unpacked/einfluffles-BrotatoTogether/ui/lobby_frame.gd"
	).new()
	frame.name = NODE_NAME
	frame.lobby = lobby_menu
	frame.title_screen = scene
	frame.main_menu = menu
	frame.entry_button = entry
	row.add_child_below_node(column, frame)
	return frame


func _ready() -> void:
	# All of the row's spare width, at its start: next to the left column, whose own share of
	# the spare width is then next to nothing.
	size_flags_horizontal = SIZE_EXPAND
	size_flags_stretch_ratio = 100.0
	size_flags_vertical = 0
	add_constant_override("margin_left", GAP)
	var panel := PanelContainer.new()
	panel.add_stylebox_override("panel", load(PANEL_STYLE_PATH))
	panel.rect_min_size = Vector2(WIDTH, 0)
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_constant_override("margin_" + side, 15)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_constant_override("separation", 10)
	margin.add_child(column)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = TITLE
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_count)
	column.add_child(header)
	_list.add_constant_override("separation", 6)
	column.add_child(_list)
	hint.autowrap = true
	column.add_child(hint)
	for label in [title, _count]:
		label.add_font_override("font", load(NAME_FONT_PATH))
	hint.add_font_override("font", load(SMALL_FONT_PATH))
	leave_button = _button(LEAVE_TEXT, "_on_leave_pressed")
	column.add_child(leave_button)

	_keep_entry_width()
	_entry_right = entry_button.focus_neighbour_right
	entry_button.connect("pressed", self, "_on_entry_pressed")
	refresh()


func _process(_delta: float) -> void:
	refresh()


# Wide enough for every text it gets: the button column keeps its width when the text changes.
func _keep_entry_width() -> void:
	var width := 0.0
	for text in [CREATING_TEXT, INVITE_TEXT, LEAVE_TEXT, HOST_TEXT]:
		entry_button.text = text
		width = max(width, entry_button.get_combined_minimum_size().x)
	entry_button.rect_min_size.x = width


func _button(text: String, method: String, binds := []) -> Button:
	var button := Button.new()
	button.set_script(load(BUTTON_SCRIPT_PATH))
	button.text = text
	button.add_font_override("font", load(SMALL_FONT_PATH))
	button.connect("pressed", self, method, binds)
	return button


func refresh() -> void:
	var transport: Node = lobby.transport
	var active: bool = transport.is_active()
	var hosting: bool = transport.is_host()
	var focused := get_focus_owner()
	var had_cursor: bool = focused != null and is_a_parent_of(focused)
	_set_text(entry_button, _entry_text(active, hosting))
	visible = active or lobby.creating
	_lock_run_buttons(active and not hosting)
	_show_players(lobby.players() if visible else [], hosting)
	_count.text = "%d / %d" % [rows.size(), transport.MAX_LOBBY_MEMBERS] if active else ""
	_set_text(hint, lobby.hint_text())
	leave_button.visible = hosting
	var buttons := nav_buttons()
	_link_cursor(buttons)
	# The button under the cursor went away (a kicked player's row, the frame with the lobby).
	if had_cursor and not focused in buttons and main_menu.is_visible_in_tree():
		(entry_button if buttons.empty() else buttons[0]).grab_focus()


func _entry_text(active: bool, hosting: bool) -> String:
	if lobby.creating:
		return CREATING_TEXT
	if not active:
		return HOST_TEXT
	return INVITE_TEXT if hosting else LEAVE_TEXT


static func _set_text(control: Control, text: String) -> void:
	if control.text != text:
		control.text = text


func nav_buttons() -> Array:
	var buttons := []
	if not visible:
		return buttons
	for row in rows:
		if row.kick != null:
			buttons.append(row.kick)
	if leave_button.visible:
		buttons.append(leave_button)
	return buttons


func _link_cursor(buttons: Array) -> void:
	var right := _entry_right
	if not buttons.empty():
		right = entry_button.get_path_to(buttons[0])
	if entry_button.focus_neighbour_right != right:
		entry_button.focus_neighbour_right = right
	for i in buttons.size():
		var button: Button = buttons[i]
		button.focus_neighbour_left = button.get_path_to(entry_button)
		button.focus_neighbour_top = button.get_path_to(buttons[i - 1])
		button.focus_neighbour_bottom = button.get_path_to(buttons[(i + 1) % buttons.size()])


# One row per player; built again only when the players or this game's role change.
func _show_players(players: Array, hosting: bool) -> void:
	var ids := []
	for player in players:
		ids.append(player.id)
	var shown := []
	for row in rows:
		shown.append(row.id)
	if ids != shown or hosting != _rows_hosting:
		_rows_hosting = hosting
		for child in _list.get_children():
			_list.remove_child(child)
			child.queue_free()
		rows = []
		for player in players:
			rows.append(_add_row(player, hosting and not player.local))
	for i in rows.size():
		_set_text(rows[i].name, players[i].name)
		_set_text(rows[i].note, players[i].note)


func _add_row(player: Dictionary, kickable: bool) -> Dictionary:
	var line := HBoxContainer.new()
	line.add_constant_override("separation", 15)
	var name_label := Label.new()
	name_label.clip_text = true
	name_label.size_flags_horizontal = SIZE_EXPAND_FILL
	name_label.add_font_override("font", load(NAME_FONT_PATH))
	var note := Label.new()
	note.add_font_override("font", load(SMALL_FONT_PATH))
	line.add_child(name_label)
	line.add_child(note)
	var kick: Button = null
	if kickable:
		kick = _button(KICK_TEXT, "_on_kick_pressed", [player.id])
		line.add_child(kick)
	_list.add_child(line)
	return {"id": player.id, "name": name_label, "note": note, "kick": kick}


# A client decides nothing about the run. The buttons stay where they are and keep the cursor's
# way through the column; the game switches Continue on again whenever its main page returns.
func _lock_run_buttons(locked: bool) -> void:
	var run_buttons := [main_menu.start_button, main_menu.continue_button]
	if locked:
		for button in run_buttons:
			if not button.disabled:
				button.disabled = true
		if not _locked and main_menu.is_visible_in_tree():
			var focused := get_focus_owner()
			if focused == null or focused in run_buttons:
				entry_button.grab_focus()
	elif _locked:
		main_menu.start_button.disabled = false
		title_screen.update_continue_button()
	_locked = locked


func _on_entry_pressed() -> void:
	var transport: Node = lobby.transport
	if lobby.creating:
		return
	if not transport.is_active():
		lobby.host()
	elif transport.is_host():
		lobby.invite()
	else:
		lobby.leave()
	refresh()


func _on_kick_pressed(steam_id: int) -> void:
	lobby.kick(steam_id)
	refresh()


func _on_leave_pressed() -> void:
	lobby.leave()
	refresh()
