extends CanvasLayer
# brotato:together menu. One hotkey (F9) so we never collide with the game's own keys
# (F8 = bug report; F2/F7 in dev builds) or Steam's (Shift+Tab, F12).
#  - status pill, bottom-centre: the only HUD spot the co-op player panels (corners) and the wave
#    timer (top-centre) leave free
#  - F9 panel, centred: connection details + Host / Invite / Leave buttons. Mouse, keyboard and
#    gamepad (hold Select/View to open: the only pad button the game binds to nothing, see
#    reference/project.godot [input]). While open, ui/menu_input_guard.gd takes every key/pad
#    event away from the game and hands it to handle_panel_input(); the cursor is forced visible
#    (the game hides it in co-op). Buttons never take Godot focus (FOCUS_NONE): the panel draws
#    its own selection, so the game's focus is untouched.
#  - sub-state: ask_confirm() swaps the button row for a question with Yes / No.
#  - leaving mid-run (also by accepting another Steam invite) asks first (ask_confirm, see
#    _confirm_text()); a pending invite shows a "Join invite" button.

signal open_changed(is_open)

const MenuInputGuard := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/menu_input_guard.gd"
)
const TOGGLE_KEY := KEY_F9
const PAD_TOGGLE_BUTTON := JOY_SELECT
const PAD_HOLD_SEC := 0.5
# Pads are matched by button on any device (the game's base ui_* actions only bind device 0).
const PAD_NAV := {JOY_DPAD_UP: -1, JOY_DPAD_LEFT: -1, JOY_DPAD_DOWN: 1, JOY_DPAD_RIGHT: 1}
const NAV_ACTIONS := {"ui_up": -1, "ui_left": -1, "ui_down": 1, "ui_right": 1}
const REFRESH_SEC := 0.25
const THEME_PATH := "res://resources/themes/base_theme.tres"
const PILL_FONT_PATH := "res://resources/fonts/actual/base/font_22.tres"
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const RUN_SCENE_PREFIXES := ["res://main.tscn", "res://ui/menus/shop/"]

var transport: Node = null
var session: Node = null
var battle_host: Node = null
var battle_client: Node = null

var _pill := PanelContainer.new()
var _pill_label := Label.new()
var _panel := PanelContainer.new()
var _details := Label.new()
var _host_button := Button.new()
var _invite_button := Button.new()
var _leave_button := Button.new()
var _join_button := Button.new()
var _buttons_row := HBoxContainer.new()
var _confirm_box := VBoxContainer.new()
var _confirm_label := Label.new()
var _confirm_method := ""
var _selected: Button = null
var _guard: Node = null
var _mouse_mode_before := Input.MOUSE_MODE_VISIBLE
var _pad_hold_device := -1
var _pad_hold_msec := 0
var _last_error := ""
var _refresh_left := 0.0


func setup(
	steam_transport: Node, netplay_session: Node, host_battle: Node, client_battle: Node
) -> void:
	transport = steam_transport
	session = netplay_session
	battle_host = host_battle
	battle_client = client_battle
	transport.connect("lobby_failed", self, "_on_lobby_failed")
	transport.connect("join_invite", self, "_on_join_invite")


func _ready() -> void:
	layer = 128
	pause_mode = PAUSE_MODE_PROCESS
	var root := Control.new()  # full-screen, click-through; carries the game's theme
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(THEME_PATH):
		root.theme = load(THEME_PATH)
	add_child(root)
	_build_pill(root)
	_build_panel(root)
	_panel.visible = false


func _build_pill(root: Control) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.55)
	style.set_corner_radius_all(14)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	_pill.add_stylebox_override("panel", style)
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pill.anchor_left = 0.5
	_pill.anchor_right = 0.5
	_pill.anchor_top = 1.0
	_pill.anchor_bottom = 1.0
	_pill.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_pill.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_pill.margin_bottom = -10
	if ResourceLoader.exists(PILL_FONT_PATH):
		_pill_label.add_font_override("font", load(PILL_FONT_PATH))
	_pill_label.add_color_override("font_color", Color(1, 1, 1, 0.9))
	_pill.add_child(_pill_label)
	root.add_child(_pill)


func _build_panel(root: Control) -> void:
	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.rect_min_size = Vector2(620, 0)
	center.add_child(_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_constant_override("margin_" + side, 24)
	_panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_constant_override("separation", 16)
	margin.add_child(column)

	var title := Label.new()
	title.text = "brotato:together"
	title.align = Label.ALIGN_CENTER
	column.add_child(title)
	_details.autowrap = true
	column.add_child(_details)

	var buttons := _buttons_row
	buttons.alignment = BoxContainer.ALIGN_CENTER
	buttons.add_constant_override("separation", 12)
	column.add_child(buttons)
	_add_button(buttons, _host_button, "Host lobby", "_on_host_pressed")
	_add_button(buttons, _invite_button, "Invite friends", "_on_invite_pressed")
	_add_button(buttons, _leave_button, "Leave lobby", "_on_leave_pressed")
	_add_button(buttons, _join_button, "Join invite", "_on_join_pressed")
	_add_button(buttons, Button.new(), "Close", "close")
	_build_confirm(column)

	var hint := Label.new()
	hint.text = "F9 / hold Select: open, close · arrows, d-pad, accept · Esc / B: back"
	hint.align = Label.ALIGN_CENTER
	hint.modulate = Color(1, 1, 1, 0.6)
	column.add_child(hint)


func _add_button(parent: Node, button: Button, text: String, method: String) -> void:
	button.text = text
	# No keyboard/gamepad focus: the game's own focus navigation must never land on these.
	button.focus_mode = Control.FOCUS_NONE
	button.connect("pressed", self, method)
	parent.add_child(button)


func _build_confirm(column: Node) -> void:
	_confirm_box.visible = false
	_confirm_box.add_constant_override("separation", 12)
	column.add_child(_confirm_box)
	_confirm_label.align = Label.ALIGN_CENTER
	_confirm_label.autowrap = true
	_confirm_box.add_child(_confirm_label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGN_CENTER
	row.add_constant_override("separation", 12)
	_confirm_box.add_child(row)
	_add_button(row, Button.new(), "Yes", "_on_confirm_yes")
	_add_button(row, Button.new(), "No", "cancel_confirm")


# Closed: only F9 and the Select hold are ours. Open: key/pad events never get here
# (MenuInputGuard), only mouse events — after the game's InputService hid the cursor again.
func _input(event: InputEvent) -> void:
	if _panel.visible:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.scancode == TOGGLE_KEY:
			get_tree().set_input_as_handled()
			open()
	elif event is InputEventJoypadButton and event.button_index == PAD_TOGGLE_BUTTON:
		if event.pressed:
			_pad_hold_device = event.device
			_pad_hold_msec = OS.get_ticks_msec()
		elif event.device == _pad_hold_device:
			_pad_hold_device = -1


func _notification(what: int) -> void:
	if what == MainLoop.NOTIFICATION_WM_FOCUS_OUT:
		_pad_hold_device = -1


# Keyboard / gamepad while open (from MenuInputGuard).
func handle_panel_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if not event.pressed:
			return
		if event.scancode == TOGGLE_KEY:
			if not event.echo:
				close()
		elif event.is_action_pressed("ui_cancel"):
			back()
		elif event.is_action_pressed("ui_accept"):
			press_selected()
		else:
			for action in NAV_ACTIONS:
				if event.is_action_pressed(action, true):
					move_selection(NAV_ACTIONS[action])
					return
	elif event is InputEventJoypadButton:
		if not event.pressed:
			return
		if event.button_index == JOY_BUTTON_0:
			press_selected()
		elif event.button_index == JOY_BUTTON_1:
			back()
		elif event.button_index == PAD_TOGGLE_BUTTON:
			close()
		elif PAD_NAV.has(event.button_index):
			move_selection(PAD_NAV[event.button_index])
	elif event is InputEventAction and event.pressed:
		# InputService's repeat for held d-pads / sticks: "ui_left" or "ui_left_<device>".
		var action: String = event.action
		for base in NAV_ACTIONS:
			if action == base or action.begins_with(base + "_"):
				move_selection(NAV_ACTIONS[base])
				return


func open() -> void:
	if _panel.visible:
		return
	_panel.visible = true
	_pad_hold_device = -1
	_mouse_mode_before = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_guard = MenuInputGuard.new()
	_guard.name = "BrotatoTogetherMenuInputGuard"
	_guard.handler = self
	get_tree().root.call_deferred("add_child", _guard)
	_refresh()
	_select(null)
	emit_signal("open_changed", true)


func close() -> void:
	if not _panel.visible:
		return
	_panel.visible = false
	cancel_confirm()
	transport.pending_join_id = 0  # closing the menu declines a pending invite
	Input.set_mouse_mode(_mouse_mode_before)
	if _guard != null and is_instance_valid(_guard):
		_guard.finish()  # also swallows the release of the key/button that closed us
	_guard = null
	_refresh()
	emit_signal("open_changed", false)


func is_open() -> bool:
	return _panel.visible


# Cancel: leaves a sub-state first, then closes.
func back() -> void:
	if _confirm_box.visible:
		cancel_confirm()
	else:
		close()


# Sub-state: the button row becomes "<question>  Yes / No"; Yes calls `method` on this node.
func ask_confirm(question: String, method: String) -> void:
	_confirm_label.text = question
	_confirm_method = method
	_buttons_row.visible = false
	_confirm_box.visible = true
	_select(null)


func cancel_confirm() -> void:
	var was_asking := _confirm_box.visible
	_confirm_box.visible = false
	_buttons_row.visible = true
	_confirm_method = ""
	if was_asking:
		_select(null)


func _on_confirm_yes() -> void:
	var method := _confirm_method
	cancel_confirm()
	if method != "":
		call(method)


func nav_buttons() -> Array:
	var found := []
	for row in [_buttons_row, _confirm_box]:
		if row.visible:
			_collect_buttons(row, found)
	return found


func _collect_buttons(node: Node, found: Array) -> void:
	for child in node.get_children():
		if child is Button:
			if child.visible and not child.disabled:
				found.append(child)
		else:
			_collect_buttons(child, found)


func selected_button() -> Button:
	return _selected


func move_selection(step: int) -> void:
	var buttons := nav_buttons()
	if buttons.empty():
		return
	var index := buttons.find(_selected)
	index = 0 if index < 0 else posmod(index + step, buttons.size())
	_select(buttons[index])


func press_selected() -> void:
	if _selected != null and _selected in nav_buttons():
		_selected.emit_signal("pressed")


# null: the first available button. The selection looks like the theme's hovered button.
func _select(button: Button) -> void:
	if button == null:
		var buttons := nav_buttons()
		button = buttons[0] if not buttons.empty() else null
	if _selected != null and is_instance_valid(_selected):
		_selected.add_stylebox_override("normal", null)
		_selected.add_color_override("font_color", _panel.get_color("font_color", "Button"))
	_selected = button
	if button != null:
		button.add_stylebox_override("normal", _panel.get_stylebox("hover", "Button"))
		button.add_color_override("font_color", _panel.get_color("font_color_hover", "Button"))


func _process(delta: float) -> void:
	if _panel.visible:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif _pad_hold_device >= 0 and OS.get_ticks_msec() - _pad_hold_msec >= PAD_HOLD_SEC * 1000:
		open()  # held (from the events: lost focus clears the hold, see _notification)
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh()


func _refresh() -> void:
	_refresh_left = REFRESH_SEC
	var active: bool = transport.steam != null and transport.is_active()
	_pill_label.text = pill_text()
	# Out of a lobby the pill is just a hint — keep it out of the way during a solo battle.
	_pill.visible = not _panel.visible and (active or not _in_battle())
	if not _panel.visible:
		return
	_details.text = details_text()
	_host_button.disabled = transport.steam == null or active
	_invite_button.disabled = not active
	_leave_button.disabled = not active
	_join_button.visible = transport.pending_join_id != 0
	if not (_selected in nav_buttons()):
		_select(null)  # e.g. "Host lobby" just got disabled


func pill_text() -> String:
	if transport.steam == null or not transport.is_active():
		return "brotato:together · F9"
	var role := "Host" if transport.is_host() else "Client"
	var players: int = session.peers.size() + 1
	var text := "brotato:together · %s · %d players" % [role, players]
	var worst_rtt := -1
	var stale := false
	for steam_id in session.peers:
		worst_rtt = int(max(worst_rtt, session.peers[steam_id].rtt_ms))
		stale = stale or session.is_peer_stale(steam_id)
	if stale:
		text += " · connection lost?"
	elif worst_rtt >= 0:
		text += " · %d ms" % worst_rtt
	return text + " · F9"


func details_text() -> String:
	var lines := []
	if transport.steam == null:
		lines.append("Steam is unavailable — online play needs the Steam version of the game.")
	elif not transport.is_active():
		lines.append("Not in a lobby. Host one, then invite friends via Steam.")
	else:
		var role := "Hosting" if transport.is_host() else "Connected as client"
		lines.append("%s · lobby %s" % [role, transport.lobby_id])
		for steam_id in session.peers:
			var peer: Dictionary = session.peers[steam_id]
			var state := "ready" if peer.ready else "connecting"
			if session.is_peer_stale(steam_id):
				state = "no response"
			var rtt: String = ("%d ms" % peer.rtt_ms) if peer.rtt_ms >= 0 else "-"
			lines.append("  %s — %s — %s" % [peer.name, state, rtt])
	if battle_host.is_in_battle():
		lines.append(
			"Battle: %d B snapshots at %d Hz" % [battle_host.snapshot_bytes, battle_host.SNAPSHOT_HZ]
		)
	if battle_client.is_in_battle():
		lines.append("Battle: render lag %d ms" % battle_client.interp_lag_msec)
	if _last_error != "":
		lines.append("! " + _last_error)
	if transport.pending_join_id != 0:
		lines.append(_confirm_text())
	return PoolStringArray(lines).join("\n")


func _confirm_text() -> String:
	var what: String = (
		"A friend's invite is waiting. Joining leaves this lobby."
		if transport.pending_join_id != 0
		else "Leave the lobby?"
	)
	if not is_mid_run():
		return what
	if transport.is_host():
		return (
			what
			+ " Your run goes on, but the remote players' characters stay idle (the shop and"
			+ " level-ups wait for them) until they rejoin a lobby you host."
		)
	return what + " You leave the host's run; your own saved run is kept."


# A run is in progress on this machine (host) or mirrored from the host (client).
func is_mid_run() -> bool:
	if not transport.is_active():
		return false
	if Puppet.is_active() or battle_host.is_in_battle() or battle_client.is_in_battle():
		return true
	var scene := get_tree().current_scene
	if scene == null:
		return false
	for prefix in RUN_SCENE_PREFIXES:
		if scene.filename.begins_with(prefix):
			return true
	return false


func _in_battle() -> bool:
	return battle_host.is_in_battle() or battle_client.is_in_battle() or _scene_is_main()


func _scene_is_main() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.filename == "res://main.tscn"


func _on_host_pressed() -> void:
	_last_error = ""
	transport.host_lobby()
	_refresh()


func _on_invite_pressed() -> void:
	transport.open_invite_dialog()


func _on_leave_pressed() -> void:
	if is_mid_run():
		ask_confirm(_confirm_text(), "_leave_now")
		return
	_leave_now()


func _leave_now() -> void:
	transport.leave_lobby()
	_refresh()


func _on_join_pressed() -> void:
	transport.accept_pending_join()
	_refresh()


# Steam invite accepted while in a lobby: join right away unless that would end a run here.
func _on_join_invite(_lobby_id: int) -> void:
	if not is_mid_run():
		transport.accept_pending_join()
		return
	open()


func _on_lobby_failed(reason: String) -> void:
	_last_error = reason
	open()  # errors (host left, connection lost) should be seen, not hidden in a closed panel
