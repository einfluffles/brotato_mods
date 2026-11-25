extends Reference
# The local-play director (dev mod: director.gd, menu_driver.gd) in one process: command files
# in, answers out, keys and buttons through the game's input, the screen snapshot and its
# matching. The scenarios themselves need game windows (tools\play-local.ps1 -Scenario).

const Director := preload("res://mods-unpacked/einfluffles-TogetherLocal/director.gd")
const MenuDriver := preload("res://mods-unpacked/einfluffles-TogetherLocal/menu_driver.gd")
const SteamEmulator := preload(
	"res://mods-unpacked/einfluffles-TogetherLocal/steam_emulator.gd"
)
const TEST_DIR := "user://director_tests"
const ANSWER_MSEC := 3000

var t: Node = null
var _presses := 0


# Stands in for the dev mod's mod_main.gd: what the director reads of it.
class FakeLocal:
	extends Node
	const TOGETHER_PATH := "/root/ModLoader/einfluffles-BrotatoTogether"
	var role := "host"
	var transport: Node = null
	var wire = null
	var emulator = null
	var lines := []

	func log_info(text: String) -> void:
		lines.append(text)



func run(test_mod: Node):
	t = test_mod
	_test_parse()
	_test_keys()
	_test_matches()
	yield(_test_buttons(), "completed")
	yield(_test_commands(), "completed")


func _test_parse() -> void:
	var parsed: Array = Director.parse('{"cmd": "press", "key": "Enter"}', "0001-press")
	t._check(
		parsed[1] == "" and parsed[0].id == "0001-press" and parsed[0].key == "Enter",
		"director: a command's id is its file's name (%s)" % [parsed]
	)
	parsed = Director.parse('{"cmd": "press", "id": "mine"}', "0002")
	t._check(parsed[0].id == "mine", "director: ... unless it names one")
	t._check(Director.parse("[1, 2]", "x")[1] != "", "director: a command must be a JSON object")
	t._check(Director.parse("{", "x")[1] != "", "director: ... broken JSON is refused")
	t._check(
		Director.parse('{"cmd": "fly"}', "x")[1].begins_with("unknown cmd"),
		"director: an unknown command is refused"
	)


func _test_keys() -> void:
	t._check(MenuDriver.scancode_of("Enter") == KEY_ENTER, "director: key names are Godot's")
	t._check(MenuDriver.scancode_of("NoSuchKey") == 0, "director: ... an unknown one is 0")
	var accept := MenuDriver.action_scancode("ui_accept")
	t._check(
		accept != 0 and InputMap.event_is_action(MenuDriver.key_event(accept, true), "ui_accept"),
		"director: an action presses its first key (ui_accept: %s)" % OS.get_scancode_string(accept)
	)
	t._check(MenuDriver.action_scancode("no_such_action") == 0, "director: ... none without one")


func _test_matches() -> void:
	var state := {
		"scene": "coop_resume",
		"scene_path": "res://ui/menus/shop/coop_resume.tscn",
		"players": 1,
		"lobby": {"in": true, "members": 2},
	}
	t._check(
		MenuDriver.matches(state, {"scene": "coop_resume", "players": 1.0, "lobby.members": 2}),
		"director: wait_for matches the scene's name, JSON numbers and dotted keys"
	)
	t._check(
		MenuDriver.matches(state, {"scene": "res://ui/menus/shop/coop_resume.tscn"}),
		"director: ... and the scene's path"
	)
	t._check(
		(
			not MenuDriver.matches(state, {"players": 2})
			and not MenuDriver.matches(state, {"lobby.in": false})
			and not MenuDriver.matches(state, {"lobby.nothing": 1})
		),
		"director: ... and nothing that differs or is missing"
	)


# Buttons are found shown and enabled only, and pressed by focus and accept.
func _test_buttons():
	var driver = MenuDriver.new(t.get_tree())
	var box := VBoxContainer.new()
	# Siblings of one name would be renamed: one box each.
	var hidden := _button(_box(box), "DirectorTestGo", "Director test go")
	hidden.hide()
	var disabled := _button(_box(box), "DirectorTestGo", "Director test go")
	disabled.disabled = true
	var shown := _button(_box(box), "DirectorTestGo", "Director test go")
	var other := _button(box, "DirectorTestOther", "Director test other")
	t.get_tree().root.add_child(box)
	yield(t.get_tree(), "idle_frame")
	var found: Array = driver.find_buttons("DirectorTestGo")
	t._check(found == [shown], "director: only a shown, enabled button is found (%s)" % [found])
	t._check(
		(
			driver.find_buttons("", "DIRECTOR TEST other") == [other]
			and driver.find_buttons("", "Director test go") == [shown]
		),
		"director: ... by its text too, in any case"
	)
	_presses = 0
	shown.connect("pressed", self, "_on_test_pressed")
	var path = yield(driver.press_button("DirectorTestGo"), "completed")
	t._check(
		_presses == 1 and path == str(shown.get_path()),
		"director: a button is pressed by focus and accept (%s, %s)" % [_presses, path]
	)
	path = yield(driver.press_button("DirectorTestMissing"), "completed")
	t._check(path == "", "director: ... and a missing one says so")
	box.queue_free()
	yield(t.get_tree(), "idle_frame")


func _on_test_pressed() -> void:
	_presses += 1


func _box(parent: Node) -> Node:
	var box := HBoxContainer.new()
	parent.add_child(box)
	return box


func _button(parent: Node, button_name: String, text: String) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = text
	parent.add_child(button)
	return button


# Command files in control/ are answered in out/, one by one in name order.
func _test_commands():
	_clear()
	var local := FakeLocal.new()
	local.emulator = SteamEmulator.new(1, "Host")
	t.add_child(local)
	var director = Director.new(local, TEST_DIR)
	local.add_child(director)
	var scene: String = MenuDriver.new(t.get_tree()).snapshot().scene
	_command("0001-query", {"cmd": "query"})
	_command("0002-wait", {"cmd": "wait_for", "scene": scene, "timeout_sec": 1})
	_command("0003-wait", {"cmd": "wait_for", "players": 99, "timeout_sec": 0.2})
	_command("0004-fly", {"cmd": "fly"})
	_command("0005-press", {"cmd": "press", "key": "Shift"})
	var ids := ["0001-query", "0002-wait", "0003-wait", "0004-fly", "0005-press"]
	var answers := []
	for id in ids:
		var answer = yield(_answer(id), "completed")
		answers.append(answer)
	t._check(
		answers[0].get("ok") == true and answers[0].state.scene == scene,
		"director: query answers with the screen's state (%s)" % [answers[0].get("state")]
	)
	t._check(
		answers[1].get("ok") == true and answers[2].get("ok") == false
		and str(answers[2].get("error")).begins_with("timed out"),
		"director: wait_for ends when the state matches, or fails after its timeout"
	)
	t._check(
		answers[3].get("ok") == false and str(answers[3].get("error")).begins_with("unknown cmd"),
		"director: an unknown command fails with a reason"
	)
	t._check(
		answers[4].get("ok") == true and answers[4].result.held_msec >= MenuDriver.KEY_MIN_MSEC,
		"director: press holds a key at least a tap's time (%s)" % [answers[4].get("result")]
	)
	yield(_test_link_commands(local), "completed")
	t._check(director.done == 12, "director: every command was handled once (%d)" % director.done)
	local.queue_free()
	_clear()


# The link commands (tools\play-local.ps1 -Profile -On, -FailSession, -FailSend, -Stall) act on
# the emulator of the director's game.
func _test_link_commands(local: Node):
	var emulator = local.emulator
	var peer: int = SteamEmulator.make_id(2)
	_command("0006-profile", {"cmd": "set_profile", "name": "bad"})
	_command("0007-profile", {"cmd": "set_profile", "name": "dial-up"})
	_command("0008-send", {"cmd": "fail_send", "count": 2})
	_command("0009-stall", {"cmd": "stall", "msec": 60000})
	_command("0010-stall", {"cmd": "stall"})
	_command("0011-session", {"cmd": "fail_session"})
	_command("0012-session", {"cmd": "fail_session", "peer": peer, "reason": 5008})
	var answers := {}
	for id in [
		"0006-profile", "0007-profile", "0008-send", "0009-stall", "0010-stall", "0011-session",
		"0012-session"
	]:
		answers[id] = yield(_answer(id), "completed")
	var profile: Dictionary = answers["0006-profile"]
	t._check(
		(
			profile.get("ok") == true
			and profile.result.profile == "bad"
			and profile.result.link.profile == "bad"
			and emulator.link.profile == "bad"
		),
		"director: set_profile switches the emulator's link profile (%s)" % [profile.get("result")]
	)
	t._check(
		(
			answers["0007-profile"].get("ok") == false
			and "unknown link profile" in str(answers["0007-profile"].get("error"))
			and emulator.link.profile == "bad"
		),
		"director: ... an unknown one fails and changes nothing"
	)
	t._check(
		answers["0008-send"].get("ok") == true and emulator._fail_sends == 2,
		"director: fail_send makes the next reliable sends fail (%d)" % emulator._fail_sends
	)
	t._check(
		(
			answers["0009-stall"].get("ok") == true
			and emulator.link.stalled(emulator.now_usec())
			and answers["0010-stall"].get("ok") == false
		),
		"director: stall stalls the link, and needs its msec"
	)
	var info: Dictionary = emulator.getSessionConnectionInfo(peer, true, false)
	t._check(
		(
			answers["0011-session"].get("ok") == false
			and answers["0012-session"].get("ok") == true
			and info.get("end_reason") == 5008
		),
		"director: fail_session fails a peer's session, and says when there is none (%s, %s)"
		% [answers["0011-session"].get("error"), info]
	)


func _command(id: String, command: Dictionary) -> void:
	Directory.new().make_dir_recursive(TEST_DIR.plus_file("control"))
	var file := File.new()
	file.open(TEST_DIR.plus_file("control").plus_file(id + ".json"), File.WRITE)
	file.store_string(JSON.print(command))
	file.close()


# The answer to `id` (an empty dictionary when none came).
func _answer(id: String):
	var path := TEST_DIR.plus_file("out").plus_file(id + ".json")
	var until := OS.get_ticks_msec() + ANSWER_MSEC
	var file := File.new()
	yield(t.get_tree(), "idle_frame")
	while not file.file_exists(path) and OS.get_ticks_msec() < until:
		yield(t.get_tree(), "idle_frame")
	if not file.file_exists(path):
		return {}
	file.open(path, File.READ)
	var parsed := JSON.parse(file.get_as_text())
	file.close()
	return parsed.result if parsed.error == OK and parsed.result is Dictionary else {}


func _clear() -> void:
	var folder := Directory.new()
	for sub in ["control", "out", "shots"]:
		var path := TEST_DIR.plus_file(sub)
		if folder.open(path) != OK:
			continue
		folder.list_dir_begin(true, true)
		var entry := folder.get_next()
		while entry != "":
			folder.remove(path.plus_file(entry))
			entry = folder.get_next()
		folder.list_dir_end()
		folder.remove(path)
	folder.remove(TEST_DIR)
