extends VBoxContainer
# Character selection, run options box, under the game's Co-op toggle and looking like it:
#  - "Online": on hosts a lobby (and switches co-op on), off leaves it;
#  - "Invite friends" (Steam overlay) while hosting;
#  - one status line: players in the lobby, why it is off (no Steam), the last error.
# Player 1 reaches them like Endless / Co-op: the box is a focus base of its FocusEmulator, so the
# cursor finds them below Co-op; other players' cursors never enter the box.
# Hidden and inert on a client: its copy of this screen shows the host's run options.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const NODE_NAME := "BrotatoTogetherOnlineOptions"
const BUTTON_SCRIPT_PATH := "res://ui/menus/global/my_menu_button.gd"
const SMALL_FONT_PATH := "res://resources/fonts/actual/base/font_22.tres"

var lobby: Node = null  # ui/lobby_menu.gd
var coop_button: CheckButton = null  # the game's

var _toggle := CheckButton.new()
var _invite := Button.new()
var _status := Label.new()


# Below the Co-op toggle of a character selection scene. Null if the scene has no such box.
static func add_to(scene: Node, lobby_menu: Node) -> Node:
	var coop = scene.get_node_or_null("%CoopButton")
	if not (coop is CheckButton) or coop.get_parent().has_node(NODE_NAME):
		return null
	var options: VBoxContainer = load(
		"res://mods-unpacked/einfluffles-BrotatoTogether/ui/online_options.gd"
	).new()
	options.name = NODE_NAME
	options.lobby = lobby_menu
	options.coop_button = coop
	coop.get_parent().add_child_below_node(coop, options)
	return options


func _ready() -> void:
	add_constant_override("separation", coop_button.get_parent().get_constant("separation"))
	_toggle.text = "Online"
	_toggle.clip_text = true
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
	_status.align = Label.ALIGN_CENTER
	_status.autowrap = true
	for control in [_invite, _status]:
		control.add_font_override("font", load(SMALL_FONT_PATH))
		add_child(control)
	_toggle.connect("toggled", self, "_on_toggled")
	_invite.connect("pressed", self, "_on_invite_pressed")
	_update()


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	visible = not lobby.session.is_client()
	if not visible:
		return
	_toggle.disabled = not lobby.steam_available()
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
