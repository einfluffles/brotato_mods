extends Node
# One local-play instance's side of the launcher (tools\play-local.ps1): its settings, its status
# file and its control folder, under BT_LOCAL_DIR (the instance's folder; nothing without it).
#
# - Settings: the launcher seeds the instance's settings.json (windowed, no pause or mute on focus
#   loss). They are enforced again once ProgressData has loaded them: two windows on one screen
#   means one of them always lacks focus. BT_LOCAL_MUTE=1 mutes the Master bus.
# - <dir>/status.json, rewritten every STATUS_SEC: role, ids, wire, lobby, scene.
# - <dir>/control/: each file is one command, by its name, handled and deleted within CONTROL_SEC:
#   "screenshot-<name>" saves the window to <dir>/shots/<name>.png, "key-<Name>" presses and
#   releases a key as the keyboard would (Godot key names: Enter, Escape, Right, A, ...),
#   "key-<Name>-<msec>" holds it that long (co-op join: Enter for 0.7 s), "quit" ends the game.
#   The link of what this game sends: "profile-<name>" switches the link profile (lan, relay-good,
#   relay-typical, bad, stall), "fail-session[-<reason>]" fails every session here and at the peer
#   (Steam's end reason, default 5003), "fail-send[-<count>]" makes the next reliable send(s)
#   fail (the host's Session then runs a full resync), "stall-<msec>" stalls the line now.

const STATUS_SEC := 1.0
const CONTROL_SEC := 0.25
const SHOT_PREFIX := "screenshot-"
const KEY_PREFIX := "key-"
const LINK_COMMANDS := ["profile", "fail-session", "fail-send", "stall"]
const KEY_HOLD_FRAMES := 3
const KEY_MIN_MSEC := 150  # a tap: the client's input reaches the host's game in samples
const FOCUS_SETTINGS := {
	"fullscreen": false,
	"pause_on_focus_lost": false,
	"mute_on_focus_lost": false,
	"on_lost_focus": 0,
}

var local: Node = null  # mod_main.gd of the dev mod
var dir := ""
var shots := 0
var settings_note := ""

var _status_left := 0.0
var _control_left := 0.0
var _mute := false
var _busy := false  # a screenshot waits for the frame


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
	if dir != "":
		var folder := Directory.new()
		folder.make_dir_recursive(dir.plus_file("control"))
		folder.make_dir_recursive(dir.plus_file("shots"))


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
	_control_left -= delta
	if _control_left <= 0.0 and not _busy:
		_control_left = CONTROL_SEC
		_read_control()


func write_status() -> void:
	var file := File.new()
	var path := dir.plus_file("status.json")
	if file.open(path + ".tmp", File.WRITE) != OK:
		return
	file.store_string(JSON.print(local.status(), "  "))
	file.close()
	Directory.new().rename(path + ".tmp", path)


func _read_control() -> void:
	var folder := Directory.new()
	if folder.open(dir.plus_file("control")) != OK:
		return
	var names := []
	folder.list_dir_begin(true, true)
	var entry := folder.get_next()
	while entry != "":
		if not folder.current_is_dir():
			names.append(entry)
		entry = folder.get_next()
	folder.list_dir_end()
	names.sort()
	for command in names:
		folder.remove(command)
		if command.begins_with(SHOT_PREFIX):
			_busy = true
			yield(_screenshot(command.substr(SHOT_PREFIX.length()).get_basename()), "completed")
			_busy = false
		elif command.begins_with(KEY_PREFIX):
			_busy = true
			var parts: Array = command.substr(KEY_PREFIX.length()).split("-")
			var hold_msec := int(parts[1]) if parts.size() > 1 else 0
			yield(_press(parts[0], hold_msec), "completed")
			_busy = false
		elif command == "quit":
			local.log_info("Quit (control file)")
			get_tree().quit()
		elif not link_command_of(command).empty():
			var parsed := link_command_of(command)
			local.link_command(parsed[0], parsed[1])
			write_status()  # the launcher waits for the new profile there


# [kind, value] of a link command's file name ("profile-relay-good": ["profile", "relay-good"],
# "fail-send": ["fail-send", ""]), [] for none.
static func link_command_of(command: String) -> Array:
	for kind in LINK_COMMANDS:
		if command == kind:
			return [kind, ""]
		if command.begins_with(kind + "-"):
			return [kind, command.substr(kind.length() + 1)]
	return []


# The window as it is drawn, to <dir>/shots/<name>.png (written under another name first, so a
# reader never sees half a file).
func _screenshot(shot: String):
	yield(VisualServer, "frame_post_draw")
	var image := get_viewport().get_texture().get_data()
	image.flip_y()
	var path := dir.plus_file("shots").plus_file(shot.validate_node_name() + ".png")
	if image.save_png(path + ".tmp") == OK:
		Directory.new().rename(path + ".tmp", path)
		shots += 1


# A key down and, KEY_MIN_MSEC or hold_msec later, up again: through Input as the OS's key
# events come in.
func _press(key_name: String, hold_msec: int):
	var scancode := OS.find_scancode_from_string(key_name)
	if scancode == 0:
		local.log_info("Unknown key '%s' (control file)" % key_name)
		yield(get_tree(), "idle_frame")
		return
	var held := " for %s ms" % hold_msec if hold_msec > 0 else ""
	local.log_info("Key %s%s (control file)" % [key_name, held])
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.scancode = scancode
		event.physical_scancode = scancode
		event.pressed = pressed
		Input.parse_input_event(event)
		var until: int = OS.get_ticks_msec() + (max(hold_msec, KEY_MIN_MSEC) if pressed else 0)
		var frames := 0
		while frames < KEY_HOLD_FRAMES or OS.get_ticks_msec() < until:
			frames += 1
			yield(get_tree(), "idle_frame")
