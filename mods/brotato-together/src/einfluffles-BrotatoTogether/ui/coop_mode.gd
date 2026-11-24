extends OptionButton
# Character selection, run options box: the Co-op row as one option with three values (Off,
# Local, Online) in the place of the game's Co-op toggle. The game's CoopButton stays in the
# tree, hidden, and still switches co-op: this option sets its `pressed`. Online also hosts a
# lobby; on a client the option shows the host's value and takes no input.

enum Mode { OFF, LOCAL, ONLINE }

const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const SlotInvite := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/slot_invite.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const NODE_NAME := "BrotatoTogetherCoopMode"
# Whole items (translation keys), so a language can shorten "Co-op" here: the box clips its text.
# The popup and the box translate them themselves, also after a language switch.
const VALUES := ["BT_COOP_OFF", "BT_COOP_LOCAL", "BT_COOP_ONLINE"]
const NO_STEAM := "BT_NEEDS_STEAM"

var lobby: Node = null
var scene: Node = null
var coop_button: CheckButton = null
var zone_button: OptionButton = null

var _invites := []  # SlotInvite per CoopJoinPanel
var _grid: Control = null
var _shown: Control = null  # the invite button left of this option (null: none)
var _emulators := []


static func add_to(scene: Node, lobby_menu: Node) -> Node:
	var coop = scene.get_node_or_null("%CoopButton")
	var zone = scene.get_node_or_null("%ZoneSelectionButton")
	if not (coop is CheckButton) or not (zone is OptionButton):
		return null
	if coop.get_parent().has_node(NODE_NAME):
		return null
	var mode: OptionButton = load(
		"res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_mode.gd"
	).new()
	mode.name = NODE_NAME
	mode.lobby = lobby_menu
	mode.scene = scene
	mode.coop_button = coop
	mode.zone_button = zone
	coop.get_parent().add_child_below_node(coop, mode)
	return mode


func _ready() -> void:
	theme = zone_button.theme
	clip_text = true
	rect_min_size.y = coop_button.get_combined_minimum_size().y  # the Co-op toggle's row
	for i in VALUES.size():
		add_item(VALUES[i], i)
	coop_button.visible = false
	connect("item_selected", self, "_on_item_selected")
	connect("focus_entered", self, "_on_focus_entered")
	_emulators = ScenePaths.find_focus_emulators(scene)
	for button in [self, zone_button]:
		button.get_popup().connect(
			"focus_entered", self, "_keep_cursor_on", [button], CONNECT_DEFERRED
		)
	_grid = scene.get_node_or_null("%Inventory1")
	if _grid != null:
		_grid.focus_neighbour_top = _grid.get_path_to(self)
		if _grid.has_method("queue_set_focus_neighbours"):
			_grid.queue_set_focus_neighbours()
	if scene.has_method("_get_coop_join_panels"):
		var emulator = scene.get_node_or_null("FocusEmulator1")
		for panel in scene._get_coop_join_panels():
			if panel == null:
				continue
			var invite: Control = SlotInvite.add_to(panel)
			invite.button.connect("pressed", self, "_on_invite_pressed", [invite.button])
			invite.button.focus_neighbour_right = invite.button.get_path_to(self)
			for side in [MARGIN_LEFT, MARGIN_TOP]:  # nothing focusable on these sides: the cursor stays
				invite.button.set_focus_neighbour(side, NodePath("."))
			_invites.append(invite)
			_add_focus_base(emulator, invite)
	_update()


# Player 1's cursor moves within its emulator's focus bases: each slot's invite is one more.
static func _add_focus_base(emulator: Node, invite: Control) -> void:
	if emulator == null or not (emulator.get("focus_base_data") is Array):
		return
	var data := FocusEmulatorBaseData.new()
	data.path = emulator.get_path_to(invite)
	data.apply_player_color = true
	emulator.focus_base_data = emulator.focus_base_data + [data]  # not the scene's shared array
	emulator._focus_base_nodes.append(invite)


func _process(_delta: float) -> void:
	_update()


func current() -> int:
	if lobby.session.is_client() or lobby.transport.is_host() or lobby.creating:
		return Mode.ONLINE
	return Mode.LOCAL if coop_button.pressed else Mode.OFF


func _update() -> void:
	for button in [self, zone_button]:
		_keep_cursor_on(button)
	if coop_button.visible:
		coop_button.visible = false
	var client: bool = lobby.session.is_client()
	var steam: bool = lobby.steam_available()
	set_item_disabled(Mode.ONLINE, not client and not steam)
	hint_tooltip = NO_STEAM if not client and not steam else ""
	var mode := current()
	if selected != mode:
		select(mode)
	focus_mode = Control.FOCUS_NONE if client else Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_IGNORE if client else Control.MOUSE_FILTER_STOP
	_update_invites(client, steam)


# The slot the next player takes shows the invite while hosting (and the status line while the
# lobby is made or after it failed).
func _update_invites(client: bool, steam: bool) -> void:
	var hosting: bool = lobby.transport.is_host()
	var text: String = lobby.status_text()
	var target: Control = null
	if not client and steam and RunData.is_coop_run and (hosting or text != ""):
		var next: int = CoopService.connected_players.size() + CoopService.connection_progress.size()
		var panels: Array = scene._get_coop_join_panels()
		if next < _invites.size() and panels[next] != null and panels[next].visible:
			target = _invites[next]
	for invite in _invites:
		var shown: bool = invite == target
		if invite.button.visible and not (shown and hosting) and _has_cursor(invite.button):
			Utils.focus_player_control(self, 0)
		invite.visible = shown
		invite.button.visible = shown and hosting
		if shown:
			invite.set_status(text)
	var left: Control = target.button if target != null and hosting else null
	if left != _shown:
		_shown = left
		focus_neighbour_left = get_path_to(left) if left != null else NodePath()


func _has_cursor(control: Control) -> bool:
	if control.has_focus():
		return true
	var emulator = Utils.get_focus_emulator(0)
	return emulator != null and emulator.focused_control == control


# A remote player with player 1's cursor (or holding slot 1 while the host clicks) changes nothing.
func _is_ours(control: Control) -> bool:
	if lobby.session.is_client():
		return false
	var player: int = int(max(0, FocusEmulatorSignal.get_player_index(control)))
	if player >= CoopService.connected_players.size():
		return true
	return not VirtualDevices.is_virtual(CoopService.get_remapped_player_device(player))


func _on_item_selected(index: int) -> void:
	if not _is_ours(self):
		_update()
		return
	var online: bool = lobby.transport.is_host() or lobby.creating
	match index:
		Mode.OFF, Mode.LOCAL:
			if online:
				lobby.leave()
			coop_button.pressed = index == Mode.LOCAL  # the game's own switch
		Mode.ONLINE:
			if lobby.steam_available() and not online:
				lobby.host()
			if lobby.steam_available() and not coop_button.pressed:
				coop_button.pressed = true
	_update()


# As the game's CharacterSelection._on_CoopButton_focus_entered: player 1 goes back to the
# character it left the grid from.
func _on_focus_entered() -> void:
	if FocusEmulatorSignal.get_player_index(self) != 0:
		return
	var latest = scene.get("_latest_focused_element")
	if latest is Array and not latest.empty():
		scene.set("__restore_player0_element", latest[0])


func _on_invite_pressed(button: Control) -> void:
	if _is_ours(button) and lobby.transport.is_host():
		lobby.invite()


# A mouse press in a dropdown's open popup gives the popup Godot's focus. A FocusEmulator then
# takes it as its control and styles it with font_color_focus, which a PopupMenu lacks (black
# rows on black), so the cursor is put back on the dropdown.
func _keep_cursor_on(button: OptionButton) -> void:
	if not is_instance_valid(button):
		return
	var popup: PopupMenu = button.get_popup()
	for emulator in _emulators:
		if is_instance_valid(emulator) and emulator.focused_control == popup:
			emulator.focused_control = button  # clears the popup's focus style
