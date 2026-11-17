extends HBoxContainer
# Character selection, in the mod's panel at the top right (ui/top_bar.gd), after the colour hint:
#  - "Online": on hosts a lobby (and switches co-op on), off leaves it. A toggle button with the
#    game's switch icons (the Co-op toggle's), scaled to the panel's row; the game's CheckButton
#    draws them at 100x50 and the row has 32 px;
#  - "Invite friends" (Steam overlay), usable while hosting, shown off otherwise;
#  - a quiet status line (the game's secondary text colour): players in the lobby, why it is off
#    (no Steam), the last error, "Online: off".
# All three have fixed widths and are always in the row, so hosting, more players or a longer
# status move nothing; a status too long for its place is clipped, its tooltip has all of it.
# The panel is outside the game's layout containers. Under Co-op in the run options box these
# controls made the box taller than its 500 px minimum (by 23 px with a one-line status, 104 px
# with a long one), the row of player panels with it, and the character grid below lost that
# height and scrolled.
# Player 1 reaches them like the run options: this row is a focus base of FocusEmulator1 too, up
# from the zone button (the top of the run options box) is Online, left / right move along the
# row, down from it is the zone button again; other players' cursors never enter it. Solo, Godot's
# own focus takes the same ways.
# Hidden and inert on a client: its copy of this screen shows the host's run options.

const TopBar := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/top_bar.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const NODE_NAME := "BrotatoTogetherOnlineOptions"
const BUTTON_SCRIPT_PATH := "res://ui/menus/global/my_menu_button.gd"
const STYLES := ["normal", "hover", "pressed", "focus", "disabled"]
const OFF_TEXT := "Online: off"
# Widths: the texts in the 22 px font plus the game's button padding (15 px left and right):
# "Online" 61.5 + the switch 48 (24 px high), "Invite friends" 145.5, "Online: needs Steam" 213.
const TOGGLE_WIDTH := 150
const INVITE_WIDTH := 180
const STATUS_WIDTH := 220

var lobby: Node = null  # ui/lobby_menu.gd
var coop_button: CheckButton = null  # the game's
var zone_button: Control = null  # the game's, at the top of the run options box
var scene: Node = null

var _toggle := Button.new()
var _invite := Button.new()
var _status := Label.new()
var _zone_top := NodePath()  # zone_button's own focus_neighbour_top
var _zone_linked := false


# Into the top bar of a character selection scene with a run options box. Null if it has none.
static func add_to(scene: Node, lobby_menu: Node) -> Node:
	var coop = scene.get_node_or_null("%CoopButton")
	var zone = scene.get_node_or_null("%ZoneSelectionButton")
	if not (coop is CheckButton) or not (zone is Control):
		return null
	if scene.find_node(NODE_NAME, true, false) != null:
		return null
	var options: HBoxContainer = load(
		"res://mods-unpacked/einfluffles-BrotatoTogether/ui/online_options.gd"
	).new()
	options.name = NODE_NAME
	options.lobby = lobby_menu
	options.coop_button = coop
	options.zone_button = zone
	options.scene = scene
	TopBar.get_or_add(scene).add_part(options, TopBar.ONLINE)
	return options


func _ready() -> void:
	add_constant_override("separation", TopBar.SEPARATION)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toggle.toggle_mode = true
	_toggle.text = "Online"
	_toggle.align = Button.ALIGN_LEFT
	_toggle.expand_icon = true
	_toggle.icon_align = Button.ALIGN_RIGHT
	_toggle.rect_min_size.x = TOGGLE_WIDTH
	TopBar.fit_button(_toggle, STYLES)
	# On is the switch, not a white button (the game's CheckButton: pressed = its normal style).
	_toggle.add_stylebox_override("pressed", _toggle.get_stylebox("normal"))
	_toggle.add_stylebox_override("hover_pressed", _toggle.get_stylebox("hover"))
	_toggle.add_color_override("font_color_pressed", coop_button.get_color("font_color_pressed"))
	_toggle.add_color_override("font_color_hover_pressed", _toggle.get_color("font_color_hover"))
	add_child(_toggle)
	_invite.set_script(load(BUTTON_SCRIPT_PATH))
	_invite.text = "Invite friends"
	_invite.clip_text = true
	_invite.rect_min_size.x = INVITE_WIDTH
	TopBar.fit_button(_invite, STYLES)
	# Off: its text faded (the theme's disabled colour) on the normal style, not a grey block.
	_invite.add_stylebox_override("disabled", _invite.get_stylebox("normal"))
	add_child(_invite)
	_status.clip_text = true
	_status.rect_min_size.x = STATUS_WIDTH
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_status.add_font_override("font", TopBar.font())
	_status.add_color_override("font_color", Utils.SECONDARY_FONT_COLOR)
	_status.mouse_filter = Control.MOUSE_FILTER_PASS  # its tooltip has the whole text
	add_child(_status)
	for control in [_toggle, _invite]:
		control.focus_neighbour_bottom = control.get_path_to(zone_button)
	_toggle.connect("toggled", self, "_on_toggled")
	_invite.connect("pressed", self, "_on_invite_pressed")
	_add_focus_base()
	_update()


func _exit_tree() -> void:
	_link_zone(false)


# Player 1's cursor moves within its emulator's focus bases: this row is one more.
func _add_focus_base() -> void:
	var emulator = scene.get_node_or_null("FocusEmulator1") if scene != null else null
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
	var icon: Texture = coop_button.get_icon("on" if on else "off")
	if _toggle.icon != icon:
		_toggle.icon = icon
	var hosting: bool = lobby.transport.is_host()
	if not _invite.disabled and not hosting and _has_cursor(_invite):
		Utils.focus_player_control(_toggle, 0)
	_invite.disabled = not hosting
	var text: String = lobby.status_text()
	if text == "":
		text = OFF_TEXT
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
	if _is_ours(_invite) and not _invite.disabled:
		lobby.invite()
