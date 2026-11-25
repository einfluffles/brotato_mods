extends Node
# The scenario director of one local-play instance: commands as JSON files in <dir>/control/,
# handled one at a time in the order of their file names, each answered in <dir>/out/<id>.json.
# tools\play-local.ps1 writes them (-Screenshot, -Key, -Do, -Scenario, and the link's -Profile,
# -FailSession, -FailSend, -Stall): the one control mechanism of an instance. A scenario
# (scenario_runner.gd, scenarios.gd) runs its commands through execute(), from the command
# "scenario" or, in tools/check-pair.sh's headless games, from the start. Docs:
# docs/implementation.md, "Local play (dev mod)", director.
#
# A command: {"cmd": "<name>", ...}; its id is the file's name without .json. The answer:
# {"id", "cmd", "ok", "error", "msec", "result", "state"} (state: menu_driver.gd's snapshot with the
# lobby). Menus are driven as a player drives them (menu_driver.gd): keys through Input, buttons by
# focus and accept. The link commands (set_profile, fail_session, fail_send, stall) act on what
# this game sends, through the emulator (steam_emulator.gd, link.gd).

const MenuDriver := preload("res://mods-unpacked/einfluffles-TogetherLocal/menu_driver.gd")
const LinkProfiles := preload("res://mods-unpacked/einfluffles-TogetherLocal/link_profiles.gd")
const ScenarioRunner := preload(
	"res://mods-unpacked/einfluffles-TogetherLocal/scenario_runner.gd"
)
const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")
const POLL_SEC := 0.1
const WAIT_SEC := 30.0  # default timeout of the commands that wait
const RESERVED := ["id", "cmd", "timeout_sec"]
const COMMANDS := [
	"screenshot", "press", "button", "wait_for", "query", "host_lobby", "join", "invite", "leave",
	"kick", "quit", "set_profile", "fail_session", "fail_send", "stall", "debug", "language",
	"mod_version", "scenario", "joypad"
]

var local: Node = null  # mod_main.gd of the dev mod
var dir := ""
var driver = null  # menu_driver.gd
var done := 0
var last := ""  # "<id> <cmd> ok|failed"
var shots := 0
var peer_ready_count := 0  # the session's peer_ready signals so far
var runner = null  # scenario_runner.gd while a scenario runs
var headless := OS.get_name() == "Server"  # Godot's headless build (tools/check-pair.sh)

var _left := 0.0
var _busy := false
var _real_mod_version := ""  # the manifest's, before mod_version changed it


func _init(local_mod: Node, instance_dir: String) -> void:
	local = local_mod
	dir = instance_dir.replace("\\", "/")
	name = "Director"


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	driver = MenuDriver.new(get_tree())
	var folder := Directory.new()
	for sub in ["control", "out", "shots"]:
		folder.make_dir_recursive(dir.plus_file(sub))
	var together := get_node_or_null(local.TOGETHER_PATH)
	var session = together.get("session") if together != null else null
	if session != null:
		session.connect("peer_ready", self, "_on_peer_ready")


func _process(delta: float) -> void:
	if headless:  # desktop platforms flush parsed input events every frame, the headless one never
		Input.flush_buffered_events()
	if _busy or dir == "":
		return
	_left -= delta
	if _left > 0.0:
		return
	_left = POLL_SEC
	var file := next_command()
	if file != "":
		_busy = true
		_handle(file)


# The first command file in name order ("" when none waits).
func next_command() -> String:
	var folder := Directory.new()
	if folder.open(dir.plus_file("control")) != OK:
		return ""
	var names := []
	folder.list_dir_begin(true, true)
	var entry := folder.get_next()
	while entry != "":
		if not folder.current_is_dir() and entry.ends_with(".json"):
			names.append(entry)
		entry = folder.get_next()
	folder.list_dir_end()
	if names.empty():
		return ""
	names.sort()
	return names[0]


# Parses a command file's text: [command dictionary, error text].
static func parse(text: String, id: String) -> Array:
	var parsed := JSON.parse(text)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return [{"id": id}, "not a JSON object"]
	var command: Dictionary = parsed.result
	command["id"] = str(command.get("id", id))
	if typeof(command.get("cmd")) != TYPE_STRING or not command.cmd in COMMANDS:
		return [command, "unknown cmd '%s' (one of %s)" % [command.get("cmd"), COMMANDS]]
	return [command, ""]


func _handle(file: String) -> void:
	var path := dir.plus_file("control").plus_file(file)
	var text := ""
	var reader := File.new()
	if reader.open(path, File.READ) == OK:
		text = reader.get_as_text()
		reader.close()
	Directory.new().remove(path)
	var parsed := parse(text, file.get_basename())
	var command: Dictionary = parsed[0]
	var answer := {}
	if parsed[1] == "":
		answer = yield(execute(command), "completed")
	else:
		yield(get_tree(), "idle_frame")
		answer = {"id": command.id, "cmd": command.get("cmd", ""), "ok": false, "error": parsed[1]}
		answer["msec"] = 0
		answer["state"] = state()
		_count(answer)
	write_answer(answer)
	_busy = false
	var result = answer.get("result")
	if answer.ok and (answer.cmd == "quit" or result is Dictionary and result.get("quit", false)):
		quit_game()


# Runs one parsed command: the command files' way in and the scenario runner's. Yields; the
# result is the answer (id, cmd, ok, error, msec, result, state).
func execute(command: Dictionary):
	var started := OS.get_ticks_msec()
	local.log_info("Director: %s %s" % [command.id, _describe(command)])
	var outcome = yield(call("_cmd_" + command.cmd, command), "completed")
	var answer := {"id": command.id, "cmd": command.cmd, "ok": outcome[0] == ""}
	answer["error"] = outcome[0]
	answer["result"] = outcome[1]
	answer["msec"] = OS.get_ticks_msec() - started
	answer["state"] = state()
	_count(answer)
	return answer


func _count(answer: Dictionary) -> void:
	done += 1
	last = "%s %s %s" % [answer.id, answer.cmd, "ok" if answer.ok else "failed"]
	if not answer.ok:
		local.log_info("Director: %s failed: %s" % [answer.id, answer.error])


# A scenario from the start (BT_LOCAL_SCENARIO, tools/check-pair.sh): no command files meanwhile;
# afterwards the game closes. peers empty: the default ones.
func run_scenario_and_quit(scenario: String, run: String, peers: Array) -> void:
	_busy = true
	var command := {"id": "scenario-%s" % run.validate_node_name(), "cmd": "scenario"}
	command["name"] = scenario
	command["run"] = run
	if not peers.empty():
		command["peers"] = peers
	var answer = yield(execute(command), "completed")
	write_answer(answer)
	quit_game()


# Closes the game as its window's close button does: the others see it leave.
func quit_game() -> void:
	get_tree().notification(MainLoop.NOTIFICATION_WM_QUIT_REQUEST)


static func _describe(command: Dictionary) -> String:
	var parts := [command.cmd]
	for key in command:
		if not key in ["id", "cmd"]:
			parts.append("%s=%s" % [key, command[key]])
	return " ".join(parts)


func write_answer(answer: Dictionary) -> void:
	var path := dir.plus_file("out").plus_file(str(answer.id).validate_node_name() + ".json")
	var file := File.new()
	if file.open(path + ".tmp", File.WRITE) != OK:
		return
	file.store_string(JSON.print(answer, "  "))
	file.close()
	Directory.new().rename(path + ".tmp", path)


# The snapshot of the screen with the lobby as the transport has it.
func state() -> Dictionary:
	var snapshot: Dictionary = driver.snapshot()
	var transport: Node = local.transport
	var lobby := {"in": false, "is_host": false, "members": 0, "id": 0}
	if transport != null and transport.is_active():
		lobby = {
			"in": true,
			"is_host": transport.is_host(),
			"members": transport.members.size() + 1,  # the transport lists the others only
			"id": transport.lobby_id,
		}
	var lobby_menu := _lobby_menu()
	lobby["details"] = lobby_menu.details_text() if lobby_menu != null else ""
	lobby["tag"] = str(transport.get("_lobby_tag")) if transport != null else ""
	snapshot["lobby"] = lobby
	snapshot["session"] = _session_state()
	snapshot["role"] = local.role
	snapshot["dlcs"] = dlc_state()
	return snapshot


# The mod's session as the scenarios check it: ready peers (the handshake done), peer_ready
# signals so far (a handshake each, then one per full resync), the lobby error the player was
# shown last (a rejection, a kick, the host gone), this game's mod version (Compat).
func _session_state() -> Dictionary:
	var together := get_node_or_null(local.TOGETHER_PATH)
	var session = together.get("session") if together != null else null
	var ready := 0
	if session != null:
		for steam_id in session.peers:
			if session.peers[steam_id].ready:
				ready += 1
	return {
		"ready": ready,
		"peer_ready": peer_ready_count,
		"error": local.lobby_error(),
		"mod_version": Compat.mod_version(),
	}


func _on_peer_ready(_steam_id: int) -> void:
	peer_ready_count += 1


# The DLCs of this game: owned (DebugService.owned_dlc_ids, which the local build asks), available
# (ProgressData.available_dlc_ids: owned plus what the host lends, session/dlc_borrow.gd), borrowed.
static func dlc_state() -> Dictionary:
	var owned: Array = DebugService.owned_dlc_ids.duplicate()
	var available: Array = ProgressData.available_dlc_ids.duplicate()
	var borrowed := []
	for dlc_id in available:
		if not dlc_id in owned:
			borrowed.append(dlc_id)
	return {"owned": owned, "available": available, "borrowed": borrowed}


func _lobby_menu() -> Node:
	return get_node_or_null(local.TOGETHER_PATH + "/LobbyMenu")


func _timeout(command: Dictionary) -> float:
	var value = command.get("timeout_sec", WAIT_SEC)
	return float(value) if typeof(value) in [TYPE_INT, TYPE_REAL] else WAIT_SEC


# Yields until state() has every value of `wanted` or the time is up: [error, state].
func _wait(wanted: Dictionary, timeout_sec: float):
	yield(get_tree(), "idle_frame")  # a caller yields on it: it must yield once
	var until := OS.get_ticks_msec() + int(timeout_sec * 1000.0)
	while true:
		var now := state()
		if MenuDriver.matches(now, wanted):
			return ["", now]
		if OS.get_ticks_msec() >= until:
			return ["timed out after %s s waiting for %s" % [timeout_sec, wanted], now]
		yield(get_tree(), "idle_frame")


# --- Commands: each yields at least once and gives [error ("" when done), result] ---


func _cmd_screenshot(command: Dictionary):
	var path := _shot_path(str(command.get("name", "shot-%d" % (shots + 1))))
	var error = yield(driver.screenshot(path), "completed")
	if error != OK:
		return ["screenshot failed (error %s)" % error, {}]
	shots += 1
	return ["", {"path": path}]


func _cmd_press(command: Dictionary):
	var code := 0
	var what := ""
	if command.has("action"):
		what = str(command.action)
		code = MenuDriver.action_scancode(what)
	else:
		what = str(command.get("key", ""))
		code = MenuDriver.scancode_of(what)
	if code == 0:
		yield(get_tree(), "idle_frame")
		return ["no key for '%s'" % what, {}]
	var times := int(command.get("times", 1))
	var hold := int(command.get("hold_ms", 0))
	var result := {"key": OS.get_scancode_string(code), "held_msec": 0}
	if command.has("shot"):  # a screenshot while the key is held (a join's progress)
		var started := OS.get_ticks_msec()
		driver.press(code, hold)  # runs on by itself
		var until := OS.get_ticks_msec() + int(command.get("shot_ms", hold * 0.5))
		while OS.get_ticks_msec() < until:
			yield(get_tree(), "idle_frame")
		var path := _shot_path(str(command.shot))
		var error = yield(driver.screenshot(path), "completed")
		if error == OK:
			shots += 1
			result["path"] = path
		# Each yield of a coroutine makes a new state object: wait for its time instead.
		var ends: int = started + max(hold, MenuDriver.KEY_MIN_MSEC) + MenuDriver.RELEASE_MSEC
		while OS.get_ticks_msec() < ends:
			yield(get_tree(), "idle_frame")
		result.held_msec = OS.get_ticks_msec() - started
		return ["" if result.has("path") else "the screenshot failed", result]
	for _i in max(1, times):
		result.held_msec = yield(driver.press(code, hold), "completed")
	return ["", result]


func _shot_path(shot: String) -> String:
	return dir.plus_file("shots").plus_file(shot.validate_node_name() + ".png")


func _cmd_button(command: Dictionary):
	var path = yield(
		driver.press_button(str(command.get("name", "")), str(command.get("text", ""))), "completed"
	)
	if path == "":
		return ["no such button shown: %s" % _describe(command), {}]
	return ["", {"path": path}]


func _cmd_wait_for(command: Dictionary):
	var wanted := {}
	for key in command:
		if not key in RESERVED:
			wanted[key] = command[key]
	var outcome = yield(_wait(wanted, _timeout(command)), "completed")
	return [outcome[0], {}]


func _cmd_query(_command: Dictionary):
	yield(get_tree(), "idle_frame")
	return ["", {}]


func _cmd_host_lobby(command: Dictionary):
	var lobby_menu := _lobby_menu()
	if lobby_menu == null or local.role != "host":
		yield(get_tree(), "idle_frame")
		return ["only the host's game hosts", {}]
	if not local.transport.is_active():
		lobby_menu.host()  # what the title screen's Host lobby and the lobby page do
	var wanted := {"lobby.in": true, "lobby.is_host": true}
	var outcome = yield(_wait(wanted, _timeout(command)), "completed")
	return [outcome[0], {"lobby": outcome[1].lobby.id}]


# A client accepts the host's invite (Steam's overlay or Join game): join_requested.
func _cmd_join(command: Dictionary):
	var wire = local.wire
	var lobby_id := int(command.get("lobby", 0))
	if lobby_id == 0 and wire != null and not wire.host_lobbies.empty():
		lobby_id = int(wire.host_lobbies[0])
	if local.role != "client" or lobby_id == 0:
		yield(get_tree(), "idle_frame")
		return ["no lobby to join (role %s)" % local.role, {}]
	local.emulator.fire_join_requested(lobby_id, local.emulator.lobby_owner(lobby_id))
	if command.get("wait", true) == false:  # a join that may be refused: the caller looks
		yield(get_tree(), "idle_frame")
		return ["", {"lobby": lobby_id}]
	var wanted := {"lobby.in": true, "lobby.id": lobby_id}
	var outcome = yield(_wait(wanted, _timeout(command)), "completed")
	return [outcome[0], {"lobby": lobby_id}]


func _cmd_invite(_command: Dictionary):
	var lobby_menu := _lobby_menu()
	yield(get_tree(), "idle_frame")
	if lobby_menu == null or not local.transport.is_active():
		return ["no lobby to invite to", {}]
	lobby_menu.invite()  # every client's game gets an accepted invite (mod_main.gd)
	return ["", {}]


func _cmd_leave(command: Dictionary):
	var lobby_menu := _lobby_menu()
	if lobby_menu == null or not local.transport.is_active():
		yield(get_tree(), "idle_frame")
		return ["not in a lobby", {}]
	lobby_menu.leave()  # Leave lobby, on the title screen's frame and the lobby page
	var outcome = yield(_wait({"lobby.in": false}, _timeout(command)), "completed")
	return [outcome[0], {}]


# Host: removes the player `peer` (a steam id; default: every other member) as the lobby page's
# kick button does (Session.kick), then waits until the transport no longer lists it.
func _cmd_kick(command: Dictionary):
	var lobby_menu := _lobby_menu()
	var transport: Node = local.transport
	if lobby_menu == null or transport == null or not transport.is_active() or not transport.is_host():
		yield(get_tree(), "idle_frame")
		return ["only the host's game in a lobby kicks", {}]
	var ids := [int(command.peer)] if command.has("peer") else transport.members.duplicate()
	if ids.empty():
		yield(get_tree(), "idle_frame")
		return ["nobody to kick", {}]
	for steam_id in ids:
		lobby_menu.kick(steam_id)
	var until := OS.get_ticks_msec() + int(_timeout(command) * 1000.0)
	while true:
		yield(get_tree(), "idle_frame")
		var left := []
		for steam_id in ids:
			if steam_id in transport.members:
				left.append(steam_id)
		if left.empty():
			return ["", {"kicked": ids}]
		if OS.get_ticks_msec() >= until:
			return ["still members after %s s: %s" % [_timeout(command), left], {"kicked": ids}]


# This game's brotato:together version (the manifest's version_number, which HELLO carries) is
# `version` from now on, as a game with another build would have it; "" gives back the real one.
func _cmd_mod_version(command: Dictionary):
	yield(get_tree(), "idle_frame")
	var mod_data = ModLoaderMod.get_mod_data(Compat.MOD_ID)
	if mod_data == null or mod_data.manifest == null:
		return ["brotato:together is not loaded", {}]
	if _real_mod_version == "":
		_real_mod_version = str(mod_data.manifest.version_number)
	var version := str(command.get("version", ""))
	mod_data.manifest.version_number = version if version != "" else _real_mod_version
	local.log_info("brotato:together version now %s (director)" % Compat.mod_version())
	return ["", {"mod_version": Compat.mod_version(), "real": _real_mod_version}]


# A scenario (scenarios.gd) with the other games of the session, each running its own part in
# step with them (scenario_runner.gd): `name`, `run` (the exchange's id, the same for every game),
# `peers` (the instances, default host and client1), `shots` (a screenshot after each step).
# Fails when the scenario does; the result has its lines.
func _cmd_scenario(command: Dictionary):
	var scenario_name := str(command.get("name", ""))
	var peers: Array = command.get("peers", ScenarioRunner.DEFAULT_PEERS)
	runner = ScenarioRunner.new(self, scenario_name, str(command.get("run", "")), peers)
	runner.shots = bool(command.get("shots", false))
	if command.has("timeout_sec"):
		runner.limit_sec = _timeout(command)
	var error = yield(runner.run(), "completed")
	var result := {"passed": error == "", "lines": runner.lines, "shots": runner.shot_paths}
	result["quit"] = runner.quits
	runner = null
	return [error, result]


func _cmd_quit(_command: Dictionary):
	yield(get_tree(), "idle_frame")
	return ["", {}]


# The link profile from now on (link_profiles.gd: lan, relay-good, relay-typical, bad, stall;
# none: no latency at all); what is on its way keeps its time. The result has the link's status.
func _cmd_set_profile(command: Dictionary):
	yield(get_tree(), "idle_frame")
	var profile := str(command.get("name", ""))
	if not local.emulator.set_profile(profile):
		var known := ", ".join(LinkProfiles.NAMES + ["none"])
		return ["unknown link profile '%s' (known: %s)" % [profile, known], {}]
	local.log_info("Link profile %s (director)" % profile)
	return ["", {"profile": profile, "link": local.emulator.link_status()}]


# Steam reports the session with a peer as failed: with the one `peer` names, or every live one
# (Steam's end `reason`, default 5003; at both ends unless `both` is false). The next send opens
# a new session.
func _cmd_fail_session(command: Dictionary):
	yield(get_tree(), "idle_frame")
	var emulator = local.emulator
	var reason := int(command.get("reason", 0))
	if reason <= 0:
		reason = emulator.END_MISC_TIMEOUT
	var debug := str(command.get("debug", "failed on command (director)"))
	var both := bool(command.get("both", true))
	var peers := []
	if command.has("peer"):
		peers.append(int(command.peer))
		emulator.fail_session(peers[0], reason, debug, both)
	elif emulator.fail_sessions(reason, debug, both) == 0:
		return ["no session to fail", {}]
	local.log_info("Sessions failed, reason %d (director)" % reason)
	return ["", {"peers": peers, "reason": reason}]


# The next `count` (default 1) reliable sends fail with LimitExceeded, as when Steam's send buffer
# is full: on the host, the mod's Session then runs a full resync.
func _cmd_fail_send(command: Dictionary):
	yield(get_tree(), "idle_frame")
	var count := int(command.get("count", 0))
	if count <= 0:
		count = 1
	local.emulator.fail_next_sends(count)
	local.log_info("The next %d reliable send(s) fail with LimitExceeded (director)" % count)
	return ["", {"count": count}]


# Nothing this game sends moves for `msec` (a stall of the line or of Steam); the queues keep it.
func _cmd_stall(command: Dictionary):
	yield(get_tree(), "idle_frame")
	var msec := int(command.get("msec", 0))
	if msec <= 0:
		return ["stall needs msec > 0", {}]
	local.emulator.stall(msec)
	local.log_info("Link stalled for %d ms (director)" % msec)
	return ["", {"msec": msec}]


# Test settings of the game's own DebugService (host): invulnerable, wave_sec (the next waves'
# length), and in a run xp and gold for every player.
func _cmd_debug(command: Dictionary):
	yield(get_tree(), "idle_frame")
	var applied := {}
	if command.has("invulnerable"):
		DebugService.invulnerable = bool(command.invulnerable)
		RunData.invulnerable = DebugService.invulnerable
		applied["invulnerable"] = DebugService.invulnerable
	if command.has("wave_sec"):
		DebugService.custom_wave_duration = int(command.wave_sec)
		applied["wave_sec"] = DebugService.custom_wave_duration
	for key in ["xp", "gold"]:
		if command.has(key) and RunData.get_player_count() > 0:
			for p in RunData.get_player_count():
				if key == "xp":
					RunData.add_xp(int(command[key]), p)
				else:
					RunData.add_gold(int(command[key]), p)
			applied[key] = int(command[key])
	if applied.empty():
		return ["nothing to set (invulnerable, wave_sec, xp, gold)", {}]
	return ["", applied]


# The options' language choice (menu_options.gd calls the same).
func _cmd_language(command: Dictionary):
	yield(get_tree(), "idle_frame")
	var locale := str(command.get("locale", ""))
	if not locale in ProgressData.languages:
		return ["no language '%s' (one of %s)" % [locale, ProgressData.languages], {}]
	ProgressData.change_language(locale)
	return ["", {"locale": TranslationServer.get_locale()}]


# The gamepads as this game sees them (joypad_filter.gd). With `connect` (true / false) first a pad
# reported to the engine as a driver reports one: `device` (0), `name`, `guid` (XInput's by
# default). No input comes from such a pad; it shows what the filter does with a connection.
func _cmd_joypad(command: Dictionary):
	if command.has("connect"):
		var device := int(command.get("device", 0))
		var pad_name := str(command.get("name", "Director pad"))
		var guid := str(command.get("guid", "__XINPUT_DEVICE__"))
		var connected := bool(command.connect)
		if not connected:
			pad_name = ""
			guid = ""
		Input.joy_connection_changed(device, connected, pad_name, guid)
		local.log_info("Pad %d %s (director)" % [device, "connected" if connected else "disconnected"])
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")  # a pad the filter blocks is blocked one frame later
	if local.joypads == null:
		return ["no gamepad filter", {}]
	return ["", local.joypads.status()]
