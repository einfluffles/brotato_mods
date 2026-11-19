extends Node
# Online co-op in the game's own menus, found when the scene changes (no script extension of the
# menus): the title screen's host button and frame, the "Online co-op" page in every pause menu,
# the Co-op option in character selection, and the page as a popup where a client has no pause
# menu. This node is what those talk to: the lobby actions, the texts, the last error.

signal open_changed(is_open)  # the popup: it takes keyboard and pad while open

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const DlcBorrow := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/dlc_borrow.gd")
const LobbyPage := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/lobby_page.gd")
const LobbyFrame := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/lobby_frame.gd")
const LobbyPopup := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/lobby_popup.gd")
const CoopMode := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_mode.gd"
)
const RUN_SCENE_PREFIXES := ["res://main.tscn", "res://ui/menus/shop/"]
const PAGE_NAME := "BrotatoTogetherLobbyPage"
const ENTRY_NAME := "BrotatoTogetherLobbyButton"
const NOTICE_MAX_AGE_MSEC := 15000  # an error older than this is no news on the title screen
const NO_STEAM_TEXT := "Steam is unavailable: online play needs the Steam version of the game."

var transport: Node = null
var session: Node = null
var battle_host: Node = null
var battle_client: Node = null
var absent_players: Node = null
var pause_control: Node = null

var last_error := ""
var creating := false  # Host lobby asked, Steam has not answered yet

var _scene_id := 0
var _scene_file := ""
var _page: Control = null  # the page in the current scene's Menus
var _popup: CanvasLayer = null
var _pause_armed := false  # own pause went down while the buttons were the game's
var _pause_down := false
var _notice := ""  # error not yet shown on the title screen
var _notice_msec := 0


func setup(
	steam_transport: Node, netplay_session: Node, host_battle: Node, client_battle: Node
) -> void:
	transport = steam_transport
	session = netplay_session
	battle_host = host_battle
	battle_client = client_battle
	transport.connect("lobby_failed", self, "_on_lobby_failed")
	transport.connect("lobby_ready", self, "_on_lobby_ready")
	transport.connect("lobby_left", self, "_on_lobby_left")
	transport.connect("join_invite", self, "_on_join_invite")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	var page: Control = LobbyPage.new()
	page.lobby = self
	page.framed = true
	_popup = LobbyPopup.new()
	_popup.name = "Popup"
	_popup.page = page
	_popup.connect("open_changed", self, "_on_popup_open_changed")
	add_child(_popup)


func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	var scene_id := scene.get_instance_id() if scene != null and scene.is_inside_tree() else 0
	if scene_id != _scene_id:
		_scene_id = scene_id
		_page = null
		if scene_id != 0:
			_enter_scene(scene, _scene_file)
			_scene_file = scene.filename
	_poll_pause(scene)


func steam_available() -> bool:
	return transport.steam != null


func host() -> void:
	if not steam_available():
		_on_lobby_failed(NO_STEAM_TEXT)
		return
	last_error = ""
	creating = true
	transport.host_lobby()


func invite() -> void:
	transport.open_invite_dialog()


func leave() -> void:
	transport.leave_lobby()


func kick(steam_id: int) -> void:
	session.kick(steam_id)


func join_invite() -> void:
	transport.accept_pending_join()


func decline_invite() -> void:
	transport.pending_join_id = 0


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


# [{id, name, note, local}]: this game first when it hosts, else the host first. A client knows
# the other clients by name only.
func players() -> Array:
	var list := []
	if not transport.is_active():
		return list
	var own_name: String = transport.get_persona_name(transport.local_id)
	var hosting: bool = transport.is_host()
	list.append(
		{"id": transport.local_id, "name": own_name, "note": "host" if hosting else "you", "local": true}
	)
	var ids: Array = transport.members.duplicate()
	for steam_id in session.peers:
		if not steam_id in ids:
			ids.append(steam_id)
	for steam_id in ids:
		var peer = session.peers.get(steam_id)
		var player := {
			"id": steam_id,
			"name": peer.name if peer != null else transport.get_persona_name(steam_id),
			"note": _peer_note(steam_id),
			"local": false,
		}
		if steam_id == transport.host_id:
			player.note = "host" if player.note == "" else "host · " + player.note
			list.insert(0, player)
		else:
			list.append(player)
	return list


func _peer_note(steam_id: int) -> String:
	if not session.peers.has(steam_id):
		return ""
	var peer: Dictionary = session.peers[steam_id]
	if not peer.ready:
		return "connecting"
	if session.is_peer_stale(steam_id):
		return "no response"
	return "%d ms" % peer.rtt_ms if peer.rtt_ms >= 0 else ""


# What happens next, for the title screen's frame ("": nothing to say).
func hint_text() -> String:
	if creating:
		return "Creating the lobby…"
	if not transport.is_active():
		return ""
	if transport.is_host():
		if session.peers.empty():
			return "Invite friends, then start or continue a run."
		return "Start or continue a run: everybody in the lobby comes along."
	if not session.is_ready_client():
		return "Connecting to the host…"
	return "Waiting for %s to start or continue a run." % session.peers[transport.host_id].name


func details_text() -> String:
	var lines := []
	if not steam_available():
		lines.append(NO_STEAM_TEXT)
	elif not transport.is_active():
		lines.append("Not in a lobby. Host one, then invite friends via Steam.")
	else:
		var role := "Hosting" if transport.is_host() else "Connected as client"
		lines.append("%s · lobby %s" % [role, transport.lobby_id])
		if DlcBorrow.is_active():
			lines.append(DlcBorrow.note())
		for steam_id in session.peers:
			var peer: Dictionary = session.peers[steam_id]
			var state := "ready" if peer.ready else "connecting"
			if session.is_peer_stale(steam_id):
				state = "no response"
			var rtt: String = ("%d ms" % peer.rtt_ms) if peer.rtt_ms >= 0 else "-"
			var answer: int = peer.get("answer_ms", -1)
			if peer.rtt_ms >= 0 and answer > peer.rtt_ms:  # what the games' frames added
				rtt += " (%d ms with frame time)" % answer
			lines.append("  %s - %s - %s" % [peer.name, state, rtt])
	if absent_players != null:
		lines += absent_players.describe()
	if battle_host.is_in_battle():
		lines.append(
			"Battle: %d B snapshots at %d Hz" % [battle_host.snapshot_bytes, battle_host.SNAPSHOT_HZ]
		)
	if battle_client.is_in_battle():
		lines.append("Battle: render lag %d ms" % battle_client.interp_lag_msec)
	if last_error != "":
		lines.append("! " + last_error)
	if transport.pending_join_id != 0:
		lines.append(leave_question())
	return PoolStringArray(lines).join("\n")


# One line for the player slot of character selection ("": nothing to say).
func status_text() -> String:
	if not steam_available():
		return "Online: needs Steam"
	if creating:
		return "Online: creating the lobby…"
	if transport.is_host():
		var players: int = session.peers.size() + 1
		return "Online: %d player%s" % [players, "" if players == 1 else "s"]
	return "! " + last_error if last_error != "" else ""


func leave_question() -> String:
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


func open_page() -> Control:
	if _popup.is_open():
		return _popup.page
	if is_instance_valid(_page) and _page.is_visible_in_tree():
		return _page
	return null


# In the scene's menu (the pause menu opens for it) or, without one, as the popup.
func open() -> Control:
	if open_page() != null:
		return open_page()
	if is_instance_valid(_page) and _menus_on_screen(_page.menus):
		if _page.menus._current_page != _page:
			_page.menus.switch(_page.menus._current_page, _page)
		return _page
	_popup.open()
	return _popup.page


# From outside the page (a client's Quit in its own Esc menu).
func ask_leave() -> void:
	if transport.is_active():
		open().ask_leave()


func close_popup() -> void:
	_popup.close()


func _menus_on_screen(menus: Node) -> bool:
	if not menus.is_visible_in_tree() and pause_control != null:
		pause_control.open_menu()
	return menus.is_visible_in_tree()


# Client without a pause menu in the scene: its pause (released, like the game's own check)
# opens the popup. Only after a press that was the game's: the guard releases what it takes.
# Polled: a co-op screen's FocusEmulators keep the event of a key that is nobody's from _input.
func _poll_pause(scene: Node) -> void:
	var down := Input.is_action_pressed("ui_pause")
	if _popup.is_open():
		_pause_armed = false
	elif down and not _pause_down:
		_pause_armed = true
	elif _pause_down and not down:
		if _pause_armed and popup_on_pause(scene):
			_popup.open()
		_pause_armed = false
	_pause_down = down


# Not on its own title screen: that is this game's menu, with the lobby in its frame.
func popup_on_pause(scene: Node) -> bool:
	if not session.is_client() or scene == null or scene.get("_pause_menu") != null:
		return false
	return scene.filename != MenuData.title_screen_scene


func _on_popup_open_changed(is_open: bool) -> void:
	emit_signal("open_changed", is_open)


func _enter_scene(scene: Node, previous_file: String) -> void:
	if scene.filename == MenuData.title_screen_scene:
		var main_menu = scene.get("_main_menu")
		var entry := _add_entry(main_menu.get("start_button") if main_menu != null else null)
		if entry != null:
			entry.text = LobbyFrame.HOST_TEXT
			LobbyFrame.add_to(scene, main_menu, entry, self)
			_show_notice()
	elif scene.filename == MenuData.character_selection_scene:
		var options = CoopMode.add_to(scene, self)
		# Start with a lobby open in the main menu: a co-op run, as with Co-op: Online.
		if options != null and previous_file == MenuData.title_screen_scene and transport.is_host():
			if not options.coop_button.pressed:
				options.coop_button.pressed = true
	else:
		var pause_menu = scene.get("_pause_menu")
		var menus = pause_menu.get("_menus") if pause_menu != null else null
		var main_menu = menus.get("_main_menu") if menus != null else null
		if main_menu != null:
			_page = _add_page(menus, main_menu.get_node_or_null("%OptionsButton"))
			var listed = main_menu.get("_buttons_array")  # which buttons keep the cursor on init
			if _page != null and listed is Array:
				listed.append(_page.entry_button)


func _add_page(menus: Node, neighbour) -> Control:
	var button := _add_entry(neighbour)
	if button == null:
		return null
	var page: Control = LobbyPage.new()
	page.name = PAGE_NAME
	page.lobby = self
	page.menus = menus
	page.visible = false
	menus.add_child(page)
	button.connect("pressed", self, "_on_entry_pressed", [page])
	page.connect("back_button_pressed", self, "_on_page_back", [page])
	page.entry_button = button
	return page


func _add_entry(neighbour) -> Button:
	if not (neighbour is Button):
		return null
	var button := Button.new()
	button.set_script(neighbour.get_script())
	button.name = ENTRY_NAME
	button.text = LobbyPage.TITLE
	for property in [
		"align", "expand_icon", "rect_min_size", "size_flags_horizontal", "theme",
		"focus_neighbour_left", "focus_neighbour_right",
	]:
		button.set(property, neighbour.get(property))
	if neighbour.has_font_override("font"):
		button.add_font_override("font", neighbour.get_font("font"))
	neighbour.get_parent().add_child_below_node(neighbour, button)
	return button


func _on_entry_pressed(page: Control) -> void:
	page.menus.switch(page.menus._main_menu, page)


func _on_page_back(page: Control) -> void:
	page.menus.switch(page, page.menus._main_menu)
	if page.entry_button.is_visible_in_tree():
		page.entry_button.grab_focus()


func _on_lobby_ready(_lobby_id: int, _is_host: bool) -> void:
	creating = false


func _on_lobby_left() -> void:
	creating = false
	_popup.close()


# Lobby not created, join refused (with the host's reason), host gone, connection lost.
func _on_lobby_failed(reason: String) -> void:
	creating = false
	last_error = reason
	_notice = reason
	_notice_msec = OS.get_ticks_msec()
	_show_notice()


# In the main menu's error label, where the game reports a broken save: now if the title screen
# is up, else when it loads (a client drops back to it when its lobby ends).
func _show_notice() -> void:
	if _notice == "":
		return
	var scene := get_tree().current_scene
	if scene == null or scene.filename != MenuData.title_screen_scene:
		return
	var main_menu = scene.get("_main_menu")
	var label = main_menu.get("error_label") if main_menu != null else null
	if label is Label and OS.get_ticks_msec() - _notice_msec <= NOTICE_MAX_AGE_MSEC:
		var text := "(!) " + _notice
		label.text = label.text + "\n" + text if label.visible and label.text != "" else text
		label.show()
	_notice = ""


func _on_join_invite(_lobby_id: int) -> void:
	if not is_mid_run():
		transport.accept_pending_join()
		return
	open()
