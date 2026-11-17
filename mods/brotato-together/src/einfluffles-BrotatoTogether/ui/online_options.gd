extends HBoxContainer
# Character selection, a row at the top of the screen: level with the Back button, the DLC bar
# and the colour hint ("[F] / [Y]  Change colour", ui/coop_selection.gd), left of that hint and
# above the title (y 75 in the game's 1920x1080 layout):
#  - "Online": on hosts a lobby (and switches co-op on), off leaves it;
#  - "Invite friends" (Steam overlay) while hosting;
#  - one status line: players in the lobby, why it is off (no Steam), the last error.
# A child of the scene root, anchored to its top right corner: it takes no space in the game's
# containers. Under Co-op in the run options box it made the box taller than its 500 px minimum
# (by 23 px with a one-line status, 104 px with a long one), the row of player panels with it,
# and the character grid below lost that height and scrolled. The row and its controls have fixed
# sizes (texts clipped), so a longer status or more players move nothing either.
# Player 1 reaches it like the run options: it is a focus base of FocusEmulator1 too, up from the
# zone button (the top of the run options box) is Online, down from the row is that button again;
# other players' cursors never enter it. Solo, Godot's own focus takes the same ways.
# Hidden and inert on a client: its copy of this screen shows the host's run options.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const NODE_NAME := "BrotatoTogetherOnlineOptions"
const BUTTON_SCRIPT_PATH := "res://ui/menus/global/my_menu_button.gd"
const SMALL_FONT_PATH := "res://resources/fonts/actual/base/font_22.tres"
const STYLES := ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]
# Measured in the game's 1920x1080 layout: the colour hint is 407 px wide, 32 px from the right
# edge; the DLC bar (co-op, all DLCs) ends at x 608. The row: x 795..1457, 24 px left of the hint.
const RIGHT := 32 + 407 + 24
const TOP := 22  # the colour hint is at 26..72, the title starts at 75
const HEIGHT := 50  # the game's toggle switch icon (100x50); the row's styles add nothing to it
const TOGGLE_WIDTH := 220
const INVITE_WIDTH := 190
const STATUS_WIDTH := 220
const SEPARATION := 16
const WIDTH := TOGGLE_WIDTH + INVITE_WIDTH + STATUS_WIDTH + 2 * SEPARATION

var lobby: Node = null  # ui/lobby_menu.gd
var coop_button: CheckButton = null  # the game's
var zone_button: Control = null  # the game's, at the top of the run options box

var _toggle := CheckButton.new()
var _invite := Button.new()
var _status := Label.new()
var _zone_top := NodePath()  # zone_button's own focus_neighbour_top
var _zone_linked := false


# At the top of a character selection scene with a run options box. Null if it has none.
static func add_to(scene: Node, lobby_menu: Node) -> Node:
	var coop = scene.get_node_or_null("%CoopButton")
	var zone = scene.get_node_or_null("%ZoneSelectionButton")
	if not (coop is CheckButton) or not (zone is Control) or scene.has_node(NODE_NAME):
		return null
	var options: HBoxContainer = load(
		"res://mods-unpacked/einfluffles-BrotatoTogether/ui/online_options.gd"
	).new()
	options.name = NODE_NAME
	options.lobby = lobby_menu
	options.coop_button = coop
	options.zone_button = zone
	# Drawn right after the Back button, like the colour hint: under the cursors and popups.
	var back: Node = scene.get_node_or_null("BackButton")
	if back != null:
		scene.add_child_below_node(back, options)
	else:
		scene.add_child(options)
	return options


func _ready() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	margin_left = -RIGHT - WIDTH
	margin_right = -RIGHT
	margin_top = TOP
	margin_bottom = TOP + HEIGHT
	add_constant_override("separation", SEPARATION)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toggle.text = "Online"
	_toggle.clip_text = true
	_toggle.rect_min_size.x = TOGGLE_WIDTH
	if coop_button.has_stylebox_override("hover_pressed"):
		_toggle.add_stylebox_override("hover_pressed", coop_button.get_stylebox("hover_pressed"))
	if coop_button.has_font_override("font"):
		_toggle.add_font_override("font", coop_button.get_font("font"))
	for state in ["on", "off"]:  # the game's theme has no icons for a disabled toggle
		_toggle.add_icon_override(state + "_disabled", coop_button.get_icon(state))
	add_child(_toggle)
	_invite.set_script(load(BUTTON_SCRIPT_PATH))
	_invite.text = "Invite friends"
	_invite.clip_text = true
	_invite.rect_min_size.x = INVITE_WIDTH
	_status.clip_text = true
	_status.valign = Label.VALIGN_CENTER
	_status.rect_min_size.x = STATUS_WIDTH
	_status.mouse_filter = Control.MOUSE_FILTER_PASS  # its tooltip has the whole text
	for control in [_invite, _status]:
		control.add_font_override("font", load(SMALL_FONT_PATH))
		add_child(control)
	for control in [_toggle, _invite]:
		_fit_height(control)
		control.focus_neighbour_bottom = control.get_path_to(zone_button)
	_toggle.connect("toggled", self, "_on_toggled")
	_invite.connect("pressed", self, "_on_invite_pressed")
	_add_focus_base()
	_update()


func _exit_tree() -> void:
	_link_zone(false)


# The game's styles pad the toggle and the button to 70 / 52 px; the strip above the title has 50.
# Every style the FocusEmulator may put on them (it copies "focus" into all) keeps that height.
static func _fit_height(control: Control) -> void:
	for name in STYLES:
		if not control.has_stylebox(name):
			continue
		var style: StyleBox = control.get_stylebox(name).duplicate()
		style.content_margin_top = 0
		style.content_margin_bottom = 0
		control.add_stylebox_override(name, style)


# Player 1's cursor moves within its emulator's focus bases: this row is one more.
func _add_focus_base() -> void:
	var emulator = get_parent().get_node_or_null("FocusEmulator1")
	if emulator == null or not (emulator.get("focus_base_data") is Array):
		return
	var data := FocusEmulatorBaseData.new()
	data.path = emulator.get_path_to(self)
	data.apply_player_color = true
	emulator.focus_base_data = emulator.focus_base_data + [data]  # not the scene's shared array
	emulator._focus_base_nodes.append(self)


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	visible = not lobby.session.is_client()
	if not visible:
		_link_zone(false)
		return
	_toggle.disabled = not lobby.steam_available()
	_link_zone(not _toggle.disabled)
	var on: bool = lobby.transport.is_host() or lobby.creating
	if _toggle.pressed != on:
		_toggle.set_pressed_no_signal(on)
	var hosting: bool = lobby.transport.is_host()
	if _invite.visible and not hosting and _has_cursor(_invite):
		Utils.focus_player_control(_toggle, 0)
	_invite.visible = hosting
	var text: String = lobby.status_text()
	_status.visible = text != ""
	if _status.text != text:
		_status.text = text
		_status.hint_tooltip = text


# Up from the zone button is Online while it can be used; otherwise the game's own way up.
func _link_zone(linked: bool) -> void:
	if linked == _zone_linked or zone_button == null or not is_instance_valid(zone_button):
		return
	if linked:
		_zone_top = zone_button.focus_neighbour_top
		zone_button.focus_neighbour_top = zone_button.get_path_to(_toggle)
	else:
		zone_button.focus_neighbour_top = _zone_top
	_zone_linked = linked


func _has_cursor(control: Control) -> bool:
	if control.has_focus():
		return true
	var emulator = Utils.get_focus_emulator(0)
	return emulator != null and emulator.focused_control == control


# A remote player with player 1's cursor does not switch the host's lobby.
func _is_ours(control: Control) -> bool:
	if lobby.session.is_client():
		return false
	var device: int = CoopService.get_remapped_player_device(
		FocusEmulatorSignal.get_player_index(control)
	)
	return not VirtualDevices.is_virtual(device)


func _on_toggled(on: bool) -> void:
	if not _is_ours(_toggle) or not lobby.steam_available():
		_update()
		return
	if on:
		lobby.host()
		if not coop_button.pressed:
			coop_button.pressed = true  # the game's own switch to co-op
	else:
		lobby.leave()
	_update()


func _on_invite_pressed() -> void:
	if _is_ours(_invite):
		lobby.invite()
