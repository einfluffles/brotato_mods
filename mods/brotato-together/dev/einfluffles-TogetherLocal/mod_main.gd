extends Node
# Local play (dev only, never packaged): brotato:together's transport on steam_emulator.gd instead
# of Steam, so game instances on one PC play together over TCP on 127.0.0.1 (wire_tcp.gd). Loads
# after brotato:together (manifest dependency). Inert unless every rule of refusal() passes:
# BT_LOCAL_ROLE is set, Steam is not logged on here, the game is not the Steam build (feature
# "steam") and its user folder is not the game's own. Otherwise one log line and nothing else.
# The launcher (tools\play-local.ps1) sets the environment:
#   BT_LOCAL_ROLE      host | client
#   BT_LOCAL_ID        the instance's number (default 1 for the host, 2 for a client)
#   BT_LOCAL_NAME      its persona name
#   BT_LOCAL_PORT      the host's port on 127.0.0.1 (none: no wire, only this game)
#   BT_LOCAL_TOKEN     the launcher's random token, checked in the wire's handshake
#   BT_LOCAL_DIR       the instance's folder: status.json, control/, shots/ (local_instance.gd)
#   BT_LOCAL_AUTOHOST  1: the host opens a lobby at the title screen
#   BT_LOCAL_MUTE      1: no sound
#   BT_LOCAL_PROFILE   the link profile of what this game sends (link_profiles.gd: lan, relay-good,
#                      relay-typical, bad, stall); none: no latency at all. Switched at run time
#                      by a control file (local_instance.gd).
# A client joins through the real launch option "+connect_lobby <lobby id>", which the transport
# acts on when it is first bound: a client binds once the host's game is online and owns that
# lobby. Docs: docs/implementation.md, "Local play (dev mod)".

const MOD_ID := "einfluffles-TogetherLocal"
const MOD_DIR := "res://mods-unpacked/einfluffles-TogetherLocal/"
const LOG_NAME := MOD_ID + ":Main"
const TOGETHER_PATH := "/root/ModLoader/einfluffles-BrotatoTogether"
const LinkProfiles := preload("res://mods-unpacked/einfluffles-TogetherLocal/link_profiles.gd")
const ROLES := ["host", "client"]
const GAME_USER_DIR := "Brotato"  # project.godot: config/name, use_custom_user_dir
const CONNECT_ARG := "+connect_lobby"
# The transport's lobby events, logged here (the mod itself does not log a peer that left)
const TRANSPORT_LOGS := [
	["peer_joined", "Peer joined: %s"],
	["peer_left", "Peer left: %s"],
	["lobby_failed", "Lobby failed: %s"],
]

var active := false
var role := ""
var note := ""  # the line logged at startup
var emulator = null
var wire = null  # wire_tcp.gd, null without BT_LOCAL_PORT
var transport: Node = null
var bound := false
var connect_lobby := 0  # the lobby of "+connect_lobby" (0: none)
var autohost := false
var instance: Node = null  # local_instance.gd

var _refused := ""
var _hosted := false
var _invites_sent := 0
var _profile_note := ""


# Before brotato:together's _ready: the transport's setup must find the emulator ready
# (local_transport.gd), so the decision and the objects come first.
func _init() -> void:
	role = OS.get_environment("BT_LOCAL_ROLE").strip_edges()
	_refused = refusal(
		role, _steam_id(), OS.has_feature("steam"), OS.get_user_data_dir(), own_user_dirs()
	)
	if _refused != "":
		return
	var number := int(OS.get_environment("BT_LOCAL_ID"))
	if number <= 0:
		number = 1 if role == "host" else 2
	var persona := OS.get_environment("BT_LOCAL_NAME")
	emulator = load(MOD_DIR + "steam_emulator.gd").new(number, persona)
	var profile := OS.get_environment("BT_LOCAL_PROFILE").strip_edges()
	if profile != "" and not emulator.set_profile(profile):
		_profile_note = "unknown BT_LOCAL_PROFILE '%s' (known: %s), no latency" % [
			profile, ", ".join(LinkProfiles.NAMES)
		]
	ModLoaderMod.install_script_extension(MOD_DIR + "local_transport.gd")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	set_process(false)
	if _refused != "":
		note = "Local play off: %s" % _refused
		ModLoaderLog.info(note, LOG_NAME)
		return
	if transport == null:  # the extension did not run: bind after the transport's own setup
		var together := get_node_or_null(TOGETHER_PATH)
		if together == null or together.get("transport") == null:
			note = "Local play off: brotato:together is not loaded"
			ModLoaderLog.warning(note, LOG_NAME)
			return
		transport = together.transport
	active = true
	connect_lobby = launch_lobby(Array(OS.get_cmdline_args()))
	autohost = role == "host" and OS.get_environment("BT_LOCAL_AUTOHOST") == "1"
	var dir := OS.get_environment("BT_LOCAL_DIR")
	instance = load(MOD_DIR + "local_instance.gd").new(
		self, dir, OS.get_environment("BT_LOCAL_MUTE") == "1"
	)
	add_child(instance)
	OS.set_window_title("Brotato (local %s: %s)" % [role, emulator.persona_name])
	for entry in TRANSPORT_LOGS:
		transport.connect(entry[0], self, "_on_transport_event", [entry[1]])
	_start_wire()
	if not bound and (role == "host" or wire == null):
		_bind()
	note = "Local play: %s, id %s (%s), %s, link %s" % [
		role, emulator.steam_id, emulator.persona_name, _wire_text(), _link_text()
	]
	ModLoaderLog.info(note, LOG_NAME)
	if _profile_note != "":
		ModLoaderLog.warning(_profile_note, LOG_NAME)
	if connect_lobby != 0:
		log_info("Joins lobby %s (%s) once the host's game has it" % [connect_lobby, CONNECT_ARG])
	set_process(true)


# Called by local_transport.gd from the transport's setup: true, as the engine's bind would be.
# The host binds now; a client once the host's game is reachable (_process).
func take_transport(steam_transport: Node) -> bool:
	transport = steam_transport
	if role == "host":
		return _bind()
	return true


# Why this game must not run local play ("": it may). Every rule is checked, in this order.
static func refusal(
	env_role: String, steam_id: int, steam_feature: bool, user_dir: String, own_dirs: Array
) -> String:
	if env_role == "":
		return "BT_LOCAL_ROLE is not set"
	if not env_role in ROLES:
		return "BT_LOCAL_ROLE '%s' is none of %s" % [env_role, ROLES]
	if steam_id != 0:
		return "Steam is logged on here (steam id %s)" % steam_id
	if steam_feature:
		return "this is the Steam build of the game (feature 'steam')"
	var dir := _normalized(user_dir)
	if dir == "":
		return "no user folder"
	for own in own_dirs:
		if dir == _normalized(own):
			return "the user folder is the game's own (%s)" % user_dir
	return ""


# Where the game keeps its real saves: on Windows under the profile's roaming AppData (the
# launcher gives each instance its own APPDATA, which does not move USERPROFILE), elsewhere under
# HOME's data folder (an instance gets XDG_DATA_HOME).
static func own_user_dirs() -> Array:
	var dirs := []
	var profile := OS.get_environment("USERPROFILE")
	if profile != "":
		dirs.append(profile.plus_file("AppData/Roaming").plus_file(GAME_USER_DIR))
	var home := OS.get_environment("HOME")
	if home != "":
		dirs.append(home.plus_file(".local/share").plus_file(GAME_USER_DIR))
	return dirs


# The lobby id after "+connect_lobby" (as the transport reads it), 0 without one.
static func launch_lobby(args: Array) -> int:
	for i in range(args.size() - 1):
		if args[i] == CONNECT_ARG:
			return int(args[i + 1])
	return 0


static func _normalized(path: String) -> String:
	var text := path.strip_edges().replace("\\", "/").to_lower()
	while text.ends_with("/") and text.length() > 1:
		text = text.substr(0, text.length() - 1)
	return text


static func _steam_id() -> int:
	if not Engine.has_singleton("Steam"):
		return 0
	return int(Engine.get_singleton("Steam").getSteamID())


func _start_wire() -> void:
	var port := int(OS.get_environment("BT_LOCAL_PORT"))
	if port <= 0:
		return
	var token := OS.get_environment("BT_LOCAL_TOKEN")
	if token.length() < 16:
		ModLoaderLog.warning("No wire: BT_LOCAL_TOKEN is missing or short", LOG_NAME)
		return
	wire = load(MOD_DIR + "wire_tcp.gd").new()
	wire.connect("note", self, "_on_wire_note")
	wire.connect("invited", self, "_on_wire_invited")
	if role == "host":
		if wire.listen(emulator, port, token) != OK:
			wire = null
	else:
		wire.join(emulator, port, token)


func _link_text() -> String:
	var profile: String = emulator.link.profile
	return "profile %s" % profile if profile != "" else "without latency"


# A link command (local_instance.gd's control files): "profile" <name>, "fail-session" <reason>,
# "fail-send" <count>, "stall" <msec>. The line it logs; "" for an unknown command.
func link_command(kind: String, value: String) -> String:
	var text := ""
	match kind:
		"profile":
			if emulator.set_profile(value):
				text = "Link profile %s (control file)" % value
			else:
				var known := ", ".join(LinkProfiles.NAMES)
				text = "Unknown link profile '%s' (known: %s)" % [value, known]
		"fail-session":
			var reason: int = int(value) if int(value) > 0 else emulator.END_MISC_TIMEOUT
			var failed: int = emulator.fail_sessions(reason, "failed on command (control file)")
			text = "Failed %d session(s), reason %d (control file)" % [failed, reason]
		"fail-send":
			var sends: int = int(value) if int(value) > 0 else 1
			emulator.fail_next_sends(sends)
			text = "The next %d reliable send(s) fail with LimitExceeded (control file)" % sends
		"stall":
			var msec := int(value)
			if msec > 0:
				emulator.stall(msec)
				text = "Link stalled for %d ms (control file)" % msec
	if text != "":
		log_info(text)
	return text


func _wire_text() -> String:
	if wire == null:
		return "no wire (only this game)"
	return "wire %s on 127.0.0.1:%s" % [role if role == "host" else "to the host", wire.port]


func _bind() -> bool:
	bound = transport.bind_steam(emulator)
	if bound:
		log_info("Transport bound to the emulator (id %s)" % emulator.steam_id)
	else:
		ModLoaderLog.warning("The transport did not take the emulator", LOG_NAME)
	return bound


func _process(_delta: float) -> void:
	if wire != null:
		wire.poll()
	emulator.poll()
	if not bound and role == "client" and wire != null and wire.state == "online":
		if connect_lobby == 0 or connect_lobby in wire.host_lobbies:
			_bind()
	if bound and role == "host":
		_host_tick()


func _host_tick() -> void:
	if autohost and not _hosted and _on_title_screen():
		var lobby_menu := get_node_or_null(TOGETHER_PATH + "/LobbyMenu")
		if lobby_menu != null and not transport.is_active():
			_hosted = true
			log_info("Hosts a lobby (BT_LOCAL_AUTOHOST)")
			lobby_menu.host()
	# The invite dialog (the lobby page's Invite) reaches every client's game as an accepted
	# invite: the stand-in for Steam's overlay and a friend clicking it.
	var dialogs: Array = emulator.invite_dialogs
	while _invites_sent < dialogs.size():
		var lobby_id: int = dialogs[_invites_sent]
		_invites_sent += 1
		if wire != null:
			var count: int = wire.send_invite(lobby_id)
			log_info("Invite to lobby %s sent to %s client(s)" % [lobby_id, count])


func _on_title_screen() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.filename == MenuData.title_screen_scene


func _on_transport_event(value, text: String) -> void:
	log_info(text % value)


func _on_wire_note(level: String, text: String) -> void:
	if level == "warning":
		ModLoaderLog.warning(text, LOG_NAME)
	else:
		log_info(text)


func _on_wire_invited(lobby_id: int, friend_id: int) -> void:
	log_info("Invite from the host to lobby %s" % lobby_id)
	emulator.fire_join_requested(lobby_id, friend_id)


func log_info(text: String) -> void:
	ModLoaderLog.info(text, LOG_NAME)


# What local_instance.gd writes to status.json.
func status() -> Dictionary:
	var scene := get_tree().current_scene
	var lobby := {}
	if transport != null and transport.is_active():
		lobby = {
			"id": transport.lobby_id,
			"host": transport.host_id,
			"is_host": transport.is_host(),
			"members": transport.members.duplicate(),
		}
	var link := {}
	if wire != null:
		link = {
			"state": wire.state,
			"port": wire.port,
			"peers": wire.peer_ids.duplicate(),
			"host_lobbies": wire.host_lobbies.duplicate(),
			"packets_out": wire.packets_out,
			"packets_in": wire.packets_in,
		}
	return {
		"role": role,
		"pid": OS.get_process_id(),
		"steam_id": emulator.steam_id,
		"name": emulator.persona_name,
		"bound": bound,
		"connect_lobby": connect_lobby,
		"wire": link,
		"lobby": lobby,
		"scene": scene.filename if scene != null else "",
		"msec": OS.get_ticks_msec(),
		"fps": Engine.get_frames_per_second(),
		"shots": instance.shots if instance != null else 0,
		"settings": instance.settings_note if instance != null else "",
		"link": emulator.link_status(),
	}


func _exit_tree() -> void:
	if wire != null:
		wire.close()  # what waits goes out, then the others hear it
