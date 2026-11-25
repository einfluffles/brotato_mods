extends Node
# One local-play instance's side of the launcher (tools\play-local.ps1): its settings and its status
# file, under BT_LOCAL_DIR (the instance's folder; nothing without it). Its control folder belongs
# to the director (director.gd).
#
# - Settings: the launcher seeds the instance's settings.json (windowed, no pause or mute on focus
#   loss). They are enforced again once ProgressData has loaded them: two windows on one screen
#   means one of them always lacks focus. BT_LOCAL_MUTE=1 mutes the Master bus.
# - <dir>/status.json, rewritten every STATUS_SEC: role, ids, wire, link, lobby, scene, director.

const STATUS_SEC := 1.0
const FOCUS_SETTINGS := {
	"fullscreen": false,
	"pause_on_focus_lost": false,
	"mute_on_focus_lost": false,
	"on_lost_focus": 0,
}

var local: Node = null  # mod_main.gd of the dev mod
var dir := ""
var settings_note := ""

var _status_left := 0.0
var _mute := false


func _init(local_mod: Node, instance_dir: String, mute: bool) -> void:
	local = local_mod
	dir = instance_dir.replace("\\", "/")
	_mute = mute
	name = "Instance"


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	# The autoloads enter the tree together and get _ready after that, in order: ProgressData (after
	# the Mod Loader) is there now but has not loaded the settings yet. Deferred runs after them all.
	call_deferred("enforce_settings")


func enforce_settings() -> void:
	var progress := get_node_or_null("/root/ProgressData")
	var settings = progress.get("settings") if progress != null else null
	var changed := []
	if settings is Dictionary:
		for key in FOCUS_SETTINGS:
			if settings.get(key) != FOCUS_SETTINGS[key]:
				settings[key] = FOCUS_SETTINGS[key]
				changed.append(key)
	OS.window_fullscreen = false
	if _mute:
		AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	settings_note = "settings: windowed, no pause or mute on focus loss%s%s" % [
		", muted" if _mute else "",
		" (changed: %s)" % ", ".join(changed) if not changed.empty() else ""
	]


func _process(delta: float) -> void:
	if dir == "":
		return
	_status_left -= delta
	if _status_left <= 0.0:
		_status_left = STATUS_SEC
		write_status()


func write_status() -> void:
	var file := File.new()
	var path := dir.plus_file("status.json")
	if file.open(path + ".tmp", File.WRITE) != OK:
		return
	file.store_string(JSON.print(local.status(), "  "))
	file.close()
	Directory.new().rename(path + ".tmp", path)
