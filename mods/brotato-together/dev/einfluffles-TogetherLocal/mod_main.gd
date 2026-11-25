extends Node
# Local play (dev only, never packaged): brotato:together's transport on steam_emulator.gd instead
# of Steam, so two game instances on one PC can play together. Loads after brotato:together
# (manifest dependency). Inert unless every rule of refusal() passes: BT_LOCAL_ROLE is set, Steam
# is not logged on here, the game is not the Steam build (feature "steam") and its user folder is
# not the game's own. Otherwise one log line and nothing else.
# The wire between the instances and the launcher come later (tools\play-local.ps1): for now an
# active instance hosts or joins only inside itself. Docs: docs/implementation.md, "Local play".

const MOD_ID := "einfluffles-TogetherLocal"
const MOD_DIR := "res://mods-unpacked/einfluffles-TogetherLocal/"
const LOG_NAME := MOD_ID + ":Main"
const TOGETHER_PATH := "/root/ModLoader/einfluffles-BrotatoTogether"
const ROLES := ["host", "client"]
const GAME_USER_DIR := "Brotato"  # project.godot: config/name, use_custom_user_dir

var active := false
var role := ""
var note := ""  # the line logged at startup
var emulator = null


func _ready() -> void:
	role = OS.get_environment("BT_LOCAL_ROLE").strip_edges()
	var why := refusal(
		role, _steam_id(), OS.has_feature("steam"), OS.get_user_data_dir(), own_user_dirs()
	)
	set_process(false)
	if why != "":
		note = "Local play off: %s" % why
		ModLoaderLog.info(note, LOG_NAME)
		return
	_start()


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


static func _normalized(path: String) -> String:
	var text := path.strip_edges().replace("\\", "/").to_lower()
	while text.ends_with("/") and text.length() > 1:
		text = text.substr(0, text.length() - 1)
	return text


static func _steam_id() -> int:
	if not Engine.has_singleton("Steam"):
		return 0
	return int(Engine.get_singleton("Steam").getSteamID())


# BT_LOCAL_ID: the instance's number (default 1 for the host, 2 for a client), BT_LOCAL_NAME its
# persona name. No wire yet: lobby and messages stay in this game.
func _start() -> void:
	var together := get_node_or_null(TOGETHER_PATH)
	if together == null or together.transport == null:
		note = "Local play off: brotato:together is not loaded"
		ModLoaderLog.warning(note, LOG_NAME)
		return
	var number := int(OS.get_environment("BT_LOCAL_ID"))
	if number <= 0:
		number = 1 if role == "host" else 2
	emulator = load(MOD_DIR + "steam_emulator.gd").new(number, OS.get_environment("BT_LOCAL_NAME"))
	active = together.transport.bind_steam(emulator)
	note = "Local play: %s, id %s (%s); no wire yet" % [role, emulator.steam_id, emulator.persona_name]
	ModLoaderLog.info(note, LOG_NAME)
	set_process(active)


func _process(_delta: float) -> void:
	emulator.poll()
