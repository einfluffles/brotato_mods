extends Node
# Which gamepads drive this local-play instance (BT_LOCAL_JOYPAD, set by tools\play-local.ps1's
# -Joypad). Windows gives every game process the pads' input, whatever window has the focus (the
# engine polls XInput and DirectInput itself), so without this one pad moves a player in every
# window. Keyboard and mouse need nothing: Windows sends them to the focused window only.
#   unset or "all"    every pad: the game as it is
#   "none"            no pad
#   "<i>[,<j> ...]"   only the pads with these device numbers (Input.get_connected_joypads())
#
# How a pad is blocked: the engine reads a pad's raw buttons, axes and hat through the SDL mapping
# of its GUID and drops what the mapping does not name, before Input's state, the actions or any
# event see it. A blocked pad gets a GUID of its own (Input.joy_connection_changed, as the engine
# reports a pad) with a mapping that names no button and no axis; its hat goes to the button
# misc1, which the game binds to nothing (an empty mapping would leave the hat as the d-pad). The
# pad stays connected for the game (its name, its slot), it only does nothing. A pad that
# connects later is blocked when the engine reports it. Input that comes from a script
# (Input.parse_input_event, the director) is past the mapping and is not filtered.

const BLOCKED_GUID := "btlocalblocked%02d"
const HAT_TO_NOTHING := "misc1:h0.1,misc1:h0.2,misc1:h0.4,misc1:h0.8"

var mode := "all"  # all | none | list
var allowed := []  # device numbers that pass (mode list)
var note := ""  # what parse() made of the setting
var blocked := {}  # device -> {name, guid: the pad's own GUID}
var blocks := 0  # pads blocked so far (a pad that reconnects counts again)

var _own_reports := {}  # device -> our reports to the engine whose signal is still to come


func _init(setting: String) -> void:
	name = "JoypadFilter"
	var parsed := parse(setting)
	mode = parsed.mode
	allowed = parsed.allowed
	note = parsed.note


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	if mode == "all":
		return
	Input.connect("joy_connection_changed", self, "_on_joy_connection_changed")
	for device in Input.get_connected_joypads():
		block_if_filtered(device)


# BT_LOCAL_JOYPAD's text: {mode, allowed, note}. Anything unreadable blocks every pad.
static func parse(setting: String) -> Dictionary:
	var text := setting.strip_edges().to_lower()
	if text == "" or text == "all":
		return {"mode": "all", "allowed": [], "note": "every pad"}
	if text == "none":
		return {"mode": "none", "allowed": [], "note": "no pad"}
	var devices := []
	for part in text.split(",", false):
		var item: String = part.strip_edges()
		if not item.is_valid_integer() or int(item) < 0:
			return {"mode": "none", "allowed": [], "note": "no pad ('%s' is unreadable)" % setting}
		if not int(item) in devices:
			devices.append(int(item))
	var names := []
	for device in devices:
		names.append(str(device))
	return {"mode": "list", "allowed": devices, "note": "pad %s only" % ", ".join(names)}


func passes(device: int) -> bool:
	return mode == "all" or (mode == "list" and device in allowed)


# Blocks the pad when this instance must not see it and it is not blocked yet. True when blocked.
# The engine's Input.get_joy_guid answers the GUID of the mapping on Windows but a fixed text on
# other platforms, so what is blocked is kept here; the engine forgets it when the driver reports
# the pad again (it gets its own mapping back), and the handler below blocks it once more.
func block_if_filtered(device: int) -> bool:
	if passes(device):
		return false
	if blocked.has(device):
		return true
	var pad_name := Input.get_joy_name(device)
	var own_guid := BLOCKED_GUID % device
	# The engine names a pad after its mapping: the pad's own name keeps it (the game reads it).
	var mapping_name := pad_name.replace(",", " ")
	Input.add_joy_mapping("%s,%s,%s" % [own_guid, mapping_name, HAT_TO_NOTHING], false)
	blocked[device] = {"name": pad_name, "guid": Input.get_joy_guid(device)}
	blocks += 1
	# The engine emits joy_connection_changed deferred: the handler skips the one this causes.
	_own_reports[device] = _own_reports.get(device, 0) + 1
	Input.joy_connection_changed(device, true, pad_name, own_guid)
	return true


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if _own_reports.get(device, 0) > 0:
		_own_reports[device] -= 1
		return
	blocked.erase(device)  # a driver's report: the engine has the pad's own mapping again
	if connected and not passes(device):
		call_deferred("block_if_filtered", device)  # not from inside the engine's own report


# For status.json: every connected pad and whether this instance sees it (guid: the pad's own;
# mapped_guid: what the engine has now, on Windows the blocked one).
func status() -> Dictionary:
	var pads := []
	for device in Input.get_connected_joypads():
		var entry := {
			"device": device,
			"name": Input.get_joy_name(device),
			"blocked": blocked.has(device),
			"guid": blocked[device].guid if blocked.has(device) else Input.get_joy_guid(device),
			"mapped_guid": Input.get_joy_guid(device),
			"known": Input.is_joy_known(device),
		}
		pads.append(entry)
	return {"setting": note, "blocks": blocks, "pads": pads}
