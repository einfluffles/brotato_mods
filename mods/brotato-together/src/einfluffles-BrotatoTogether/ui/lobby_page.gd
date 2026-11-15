extends Control
# The "Online co-op" page: host / invite / leave / join an invite, and the connection details.
# Built like the game's own menu pages (title, a panel, MyMenuButtons, Back; init() and
# back_button_pressed as Menus.switch and its pages use them), so it sits in the title screen's
# and the pause menu's page stack (ui/lobby_menu.gd) with the game's focus handling: Godot focus
# in solo play, the pause menu's FocusEmulator in co-op.
# Leaving mid-run asks on the game's confirm page (menu_confirm.tscn with our question; its Yes
# leaves the lobby instead of the run).
# framed: the same page as a popup (ui/lobby_popup.gd), a panel on the dimmed screen. There the
# keys come from MenuInputGuard through move_focus / press_focused / back.

signal back_button_pressed

const THEME_PATH := "res://resources/themes/base_theme.tres"
const TITLE_FONT_PATH := "res://resources/fonts/actual/base/font_60_outline.tres"
const DETAILS_FONT_PATH := "res://resources/fonts/actual/base/font_26.tres"
const PANEL_STYLE_PATH := "res://resources/themes/panel/panel_style.tres"
const BUTTON_SCRIPT_PATH := "res://ui/menus/global/my_menu_button.gd"
const CONFIRM_SCENE_PATH := "res://ui/menus/pages/menu_confirm.tscn"
const TITLE := "Online co-op"
const REFRESH_SEC := 0.25
const DIM := Color(0, 0, 0, 0.6)

var lobby: Node = null  # ui/lobby_menu.gd
var framed := false
var menus: Node = null  # the game's Menus this page is in (null: the popup)
var entry_button: Button = null  # opens the page from the Menus' main page

var _center := CenterContainer.new()
var _details := Label.new()
var _buttons := VBoxContainer.new()
var _join_button: Button = null
var _host_button = null  # MyMenuButton: disable() / activate()
var _invite_button: Button = null
var _leave_button: Button = null
var _back_button: Button = null
var _confirm = null  # the game's MenuConfirm
var _focused: Button = null  # the button of ours that got the cursor last
var _shown := false
var _refresh_left := 0.0


func _ready() -> void:
	_fill(self)
	theme = load(THEME_PATH)
	if framed:
		var dim := ColorRect.new()
		dim.color = DIM
		_fill(dim)
		add_child(dim)
	_fill(_center)
	add_child(_center)
	var column := VBoxContainer.new()
	column.add_constant_override("separation", 40)
	if framed:
		var margin := MarginContainer.new()
		for side in ["left", "right", "top", "bottom"]:
			margin.add_constant_override("margin_" + side, 30)
		var panel := PanelContainer.new()
		panel.add_child(margin)
		margin.add_child(column)
		_center.add_child(panel)
	else:
		_center.add_child(column)
	_build_column(column)
	_build_confirm()


static func _fill(control: Control) -> void:
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0


func _build_column(column: Container) -> void:
	var title := Label.new()
	title.text = TITLE
	title.align = Label.ALIGN_CENTER
	title.add_font_override("font", load(TITLE_FONT_PATH))
	column.add_child(title)

	var panel := PanelContainer.new()
	panel.add_stylebox_override("panel", load(PANEL_STYLE_PATH))
	panel.rect_min_size = Vector2(900, 0)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_constant_override("margin_" + side, 15)
	panel.add_child(margin)
	_details.autowrap = true
	_details.add_font_override("font", load(DETAILS_FONT_PATH))
	margin.add_child(_details)
	column.add_child(panel)

	_buttons.rect_min_size = Vector2(600, 0)
	_buttons.size_flags_horizontal = SIZE_SHRINK_CENTER
	_buttons.add_constant_override("separation", 15)
	column.add_child(_buttons)
	_join_button = _add_button("Join invite", "_on_join_pressed")
	_host_button = _add_button("Host lobby", "_on_host_pressed")
	_invite_button = _add_button("Invite friends", "_on_invite_pressed")
	_leave_button = _add_button("Leave lobby", "_on_leave_pressed")
	_back_button = _add_button("MENU_BACK", "_on_back_pressed")


func _add_button(text: String, method: String) -> Button:
	var button := Button.new()
	button.set_script(load(BUTTON_SCRIPT_PATH))
	button.text = text
	button.connect("pressed", self, method)
	button.connect("focus_entered", self, "_on_button_focused", [button])
	_buttons.add_child(button)
	return button


# The game's page asks "Return to Main Menu?" and its Yes ends the run: same page, our question,
# and Yes comes to us.
func _build_confirm() -> void:
	_confirm = load(CONFIRM_SCENE_PATH).instance()
	_confirm.visible = false
	add_child(_confirm)
	var yes: Button = _confirm.get_node("Buttons/ConfirmButton")
	yes.disconnect("pressed", _confirm, "_on_ConfirmButton_pressed")
	yes.connect("pressed", self, "_on_confirm_yes")
	_confirm.connect("cancel_button_pressed", self, "_on_confirm_cancel")
	_confirm.get_node("Buttons/Label").autowrap = true


# Called by Menus.switch when the page shows (and by the popup when it opens).
func init() -> void:
	_show_confirm(false)
	_focused = null
	_shown = true
	refresh()


func refresh() -> void:
	_refresh_left = REFRESH_SEC
	_details.text = lobby.details_text()
	var active: bool = lobby.transport.is_active()
	_join_button.visible = lobby.transport.pending_join_id != 0
	_host_button.visible = not active
	_invite_button.visible = active
	_leave_button.visible = active
	if _host_button.active != lobby.steam_available():
		if lobby.steam_available():
			_host_button.activate()
		else:
			_host_button.disable()
	# Also when the button under the cursor went away (Host lobby once the lobby exists).
	var buttons := nav_buttons()
	if is_asking() or not is_visible_in_tree() or buttons.empty():
		return
	if _focused == null or not _focused in buttons:
		buttons[0].grab_focus()


func is_asking() -> bool:
	return _confirm != null and _confirm.visible


# Leave, with the question first when a run is on.
func ask_leave() -> void:
	if not lobby.transport.is_active():
		return
	if not lobby.is_mid_run():
		lobby.leave()
		refresh()
		return
	_confirm.get_node("Buttons/Label").text = lobby.leave_question()
	_show_confirm(true)


func _show_confirm(asking: bool) -> void:
	if _confirm == null or asking == _confirm.visible:
		return
	_center.visible = not asking
	_confirm.visible = asking
	if asking:
		_confirm.init()
		_confirm.focus_before_created = _leave_button  # null with a FocusEmulator's cursor


func _on_confirm_yes() -> void:
	_show_confirm(false)
	lobby.leave()
	refresh()


func _on_confirm_cancel() -> void:
	_show_confirm(false)
	refresh()


# The buttons the cursor can be on: the question's, or the page's.
func nav_buttons() -> Array:
	var found := []
	var row: Node = _confirm.get_node("Buttons") if is_asking() else _buttons
	for child in row.get_children():
		# MyMenuButton disables itself for a moment after a press.
		if child is Button and child.visible:
			if not child.disabled or child.get("_is_delay_active") == true:
				found.append(child)
	return found


# --- the popup's keys (MenuInputGuard keeps them from the GUI) ---


func move_focus(step: int) -> void:
	var buttons := nav_buttons()
	if buttons.empty():
		return
	var index := buttons.find(get_focus_owner())
	buttons[0 if index < 0 else posmod(index + step, buttons.size())].grab_focus()


func press_focused() -> void:
	var button := get_focus_owner()
	if button in nav_buttons() and not button.disabled:
		button.emit_signal("pressed")


func back() -> void:
	if is_asking():
		_confirm._on_CancelButton_pressed()
	else:
		_on_back_pressed()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		refresh()


# In a Menus: back like the game's pages. The question takes its own cancel first.
func _input(event: InputEvent) -> void:
	if menus == null or not is_visible_in_tree() or is_asking():
		return
	if event.is_action_released("ui_cancel"):
		_on_back_pressed()
		get_tree().set_input_as_handled()


# Hidden (back, the pause menu closed, the wave ended): no question left open, whose _input
# would take every cancel, and a pending invite is declined.
func _notification(what: int) -> void:
	if what != NOTIFICATION_VISIBILITY_CHANGED or not _shown or is_visible_in_tree():
		return
	_shown = false
	_show_confirm(false)
	lobby.decline_invite()


func _on_button_focused(button: Button) -> void:
	_focused = button


func _on_host_pressed() -> void:
	lobby.host()
	refresh()


func _on_invite_pressed() -> void:
	lobby.invite()


func _on_leave_pressed() -> void:
	ask_leave()


func _on_join_pressed() -> void:
	lobby.join_invite()
	refresh()


func _on_back_pressed() -> void:
	emit_signal("back_button_pressed")
