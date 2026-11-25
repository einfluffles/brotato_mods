extends Reference
# Runs one scenario of scenarios.gd in every game of a local session at once, in step. Each game
# runs the same scenario code. A step (on) names the games that act: each of them carries out its
# command through its own director (director.execute) and writes the answer to its out/ folder as
# scn-<run>-<NNNN>.json; every game then reads the answers of the others from their folders. So
# every step is a meeting point, every game sees the same answers (its own ones go through JSON
# too), takes the same branches and comes to the same checks. Branches and loops in a scenario
# may only depend on answers and counts, never on a game's own clock or state.
#
# The instances' folders are siblings (<run folder>/host, <run folder>/client1, ...), as
# tools\play-local.ps1 and tools/check-pair.sh lay them out; a game's name is its folder's name.
# A game that fails (a command that fails, a check that does not hold, no answer in time) writes
# scn-<run>-abort.json, so the others stop waiting for it. A game that quits in a scenario (the
# host closing) ends its part there with its verdict; the others go on without it.
#
# What a game prints (stdout, and the Mod Loader log), read by tools/check-pair.sh:
#   PAIR-TESTS: START <scenario> (<game> of <games>, run <id>)
#   step <NN>-<label>, the commands with their answers, "  ok   <check>", "  FAIL <check>"
#   PAIR-TESTS: PASS | PAIR-TESTS: FAIL <why>
# Docs: docs/testing.md, "Pair tests"; docs/implementation.md, "Local play (dev mod)".

signal never  # a scenario that failed or ended waits on this for good

const Scenarios := preload("res://mods-unpacked/einfluffles-TogetherLocal/scenarios.gd")
const DEFAULT_PEERS := ["host", "client1"]
const WAIT_SEC := 30.0  # the director's default timeout
const SLACK_SEC := 30.0  # another game's answer may come this long after its command's timeout

var director: Node = null  # director.gd
var scenario := ""
var run_id := ""
var me := ""  # this game's instance name
var peers := []  # the instance names that take part
var shots := false  # a screenshot of this game after every step: shots/<NN>-<label>.png
var limit_sec := 900.0  # the whole scenario's time limit
var echo := true  # print what is said (stdout), not only to the log
var lines := []  # what was said
var shot_paths := []
var failed := ""  # why this scenario failed ("" so far)
var ended := false  # this game quit in the scenario: its part is over
var quits := false  # ... and the game closes after the verdict
var gone := []  # the games that quit

var _seq := 0  # the steps so far: the same in every game
var _shots := 0
var _step := 0
var _tag := ""  # the open step's "<NN>-<label>", "" when none is open
var _completed := false
var _base := ""  # the folder with every instance's folder


func _init(scenario_director: Node, scenario_name: String, run: String, names: Array) -> void:
	director = scenario_director
	scenario = scenario_name
	run_id = run.validate_node_name()
	var dir: String = director.dir.rstrip("/")
	me = dir.get_file()
	_base = dir.get_base_dir()
	for name in names:
		peers.append(str(name))


# Yields; the result is "" (passed) or why the scenario failed.
func run():
	yield(_tree(), "idle_frame")
	if not scenario in Scenarios.NAMES:
		return _verdict("no scenario '%s' (one of %s)" % [scenario, Scenarios.NAMES])
	if not me in peers:
		return _verdict("this game (%s) is none of %s" % [me, peers])
	if run_id == "":
		return _verdict("no run id")
	say("PAIR-TESTS: START %s (%s of %s, run %s)" % [scenario, me, ", ".join(peers), run_id])
	var pending = Scenarios.new().call("scenario_" + scenario, self)
	if pending is GDScriptFunctionState:
		pending.connect("completed", self, "_on_completed")
	else:
		_completed = true
	# A scenario that stops on a script error never completes: the others' abort and the
	# scenario's own time limit end it then.
	var until := OS.get_ticks_msec() + int(limit_sec * 1000.0)
	var next_look := 0
	while not _completed and failed == "" and not ended:
		yield(_tree(), "idle_frame")
		if OS.get_ticks_msec() >= until:
			fail("the scenario took longer than %s s" % limit_sec)
		elif OS.get_ticks_msec() >= next_look:
			next_look = OS.get_ticks_msec() + 500
			for name in peers:
				if name != me and File.new().file_exists(_abort_path(name)):
					fail("%s stopped the scenario" % name)
					break
	if failed == "":
		yield(end_step(), "completed")
	elif shots:
		_step += 1
		yield(_shot("%02d-failed" % _step), "completed")
	return _verdict(failed)


func _on_completed(_result = null) -> void:
	_completed = true


func _verdict(why: String) -> String:
	failed = why
	say("PAIR-TESTS: PASS" if why == "" else "PAIR-TESTS: FAIL %s" % why)
	return why


func _tree() -> SceneTree:
	return director.get_tree()


func say(text: String) -> void:
	lines.append(text)
	if echo:
		print(text)
	director.local.log_info("Scenario: %s" % text.strip_edges())


func alive() -> bool:
	return failed == "" and not ended


# Ends the scenario as failed in this game and tells the others. Yields for good.
func fail(why: String):
	if failed == "":
		failed = why
		say("  FAIL %s" % why)
		_write(_abort_path(me), {"why": why})
	yield(self, "never")


func check(condition: bool, text: String) -> void:
	if not alive():
		return
	if condition:
		say("  ok   %s: %s" % [scenario, text])
	else:
		fail("%s: %s" % [scenario, text])


# A new step: the open one ends first (its screenshot). Yields.
func step(label: String):
	yield(end_step(), "completed")
	if not alive():
		yield(self, "never")
	_step += 1
	_tag = "%02d-%s" % [_step, label]
	say("step %s" % _tag)


# Ends the open step: a screenshot of this game with the step's name. Yields.
func end_step():
	yield(_tree(), "idle_frame")
	if _tag != "" and shots and alive():
		yield(_shot(_tag), "completed")
	_tag = ""


func tag() -> String:
	return _tag


func _shot(shot: String):
	_shots += 1  # a command of this game only: not one of the shared steps
	var command := {"id": "scn-%s-shot-%04d" % [run_id, _shots], "cmd": "screenshot", "name": shot}
	var answer = yield(director.execute(command), "completed")
	if answer.ok:
		shot_paths.append(answer.result.path)


# Waits sec seconds of this game's time (also while the game is paused). Yields.
func pause(sec: float):
	if not alive():
		yield(self, "never")
	yield(_tree().create_timer(sec, true), "timeout")
	if not alive():
		yield(self, "never")


# The screen state of one game (its director's query). Yields.
func state(name: String):
	var answers = yield(on(name, {"cmd": "query"}), "completed")
	return answers[0].state


# One step on the games `actors` ("all", a name or a list of names). `command` is one director
# command for all of them, or a Dictionary of name -> command (a command each). A command can
# have after_ms: the game waits that long before it. Yields; the answers in the order of the
# names. A failed answer fails the scenario unless may_fail (no answer at all always does).
func on(actors, command: Dictionary, may_fail := false):
	var names := _names(actors)
	_seq += 1
	var id := "scn-%s-%04d" % [run_id, _seq]
	if not alive():
		yield(self, "never")
	for name in names:
		if name in gone or not name in peers:
			yield(fail("%s is not in the scenario any more (%s)" % [name, _describe(command)]), "completed")
	var mine = null
	if me in names:
		var own: Dictionary = _command_for(command, me).duplicate()
		own["id"] = id
		var after := int(own.get("after_ms", 0))
		own.erase("after_ms")
		if after > 0:
			yield(_tree().create_timer(after / 1000.0, true), "timeout")
		var answer = yield(director.execute(own), "completed")
		mine = JSON.parse(JSON.print(answer)).result  # as the others read it
		_write(_answer_path(me, id), mine)
	else:
		yield(_tree(), "idle_frame")
	var answers := []
	for name in names:
		if name == me:
			answers.append(mine)
			continue
		var timeout := _timeout_sec(_command_for(command, name))
		var answer = yield(_read(name, id, timeout), "completed")
		if answer == null:
			yield(fail("%s: no answer to %s" % [name, _describe(_command_for(command, name))]), "completed")
		answers.append(answer)
	var bad := ""
	for i in names.size():
		var answer: Dictionary = answers[i]
		var text := "ok" if answer.ok else "FAILED: %s" % answer.error
		var what := _describe(_command_for(command, names[i]))
		say("  %s: %s: %s (%d ms)" % [names[i], what, text, answer.msec])
		if not answer.ok and bad == "":
			bad = "%s: %s failed: %s" % [names[i], answer.cmd, answer.error]
	if bad != "" and not may_fail:
		yield(fail(bad), "completed")
	for i in names.size():
		if answers[i].cmd == "quit" and answers[i].ok:
			gone.append(names[i])
			if names[i] == me:
				ended = true
				quits = true
				say("  %s quit: its part of the scenario ends here" % me)
				yield(self, "never")
	return answers


func _names(actors) -> Array:
	if typeof(actors) == TYPE_STRING:
		return peers.duplicate() if actors == "all" else [actors]
	var names := []
	for name in actors:
		names.append(str(name))
	return names


static func _command_for(command: Dictionary, name: String) -> Dictionary:
	if command.has("cmd"):
		return command
	return command.get(name, {"cmd": "query"})


static func _describe(command: Dictionary) -> String:
	var parts := [str(command.get("cmd", "?"))]
	var keys := command.keys()
	keys.sort()
	for key in keys:
		if not key in ["id", "cmd"]:
			parts.append("%s=%s" % [key, command[key]])
	return " ".join(parts)


static func _timeout_sec(command: Dictionary) -> float:
	var wait = command.get("timeout_sec", WAIT_SEC)
	var sec: float = float(wait) if typeof(wait) in [TYPE_INT, TYPE_REAL] else WAIT_SEC
	sec += (float(command.get("after_ms", 0)) + float(command.get("hold_ms", 0))) / 1000.0
	return sec + SLACK_SEC


func _answer_path(name: String, id: String) -> String:
	return _base.plus_file(name).plus_file("out").plus_file(id + ".json")


func _abort_path(name: String) -> String:
	return _base.plus_file(name).plus_file("out").plus_file("scn-%s-abort.json" % run_id)


# Another game's answer to step id, null when it aborted or none came in time. Yields.
func _read(name: String, id: String, timeout_sec: float):
	var path := _answer_path(name, id)
	var abort := _abort_path(name)
	var until := OS.get_ticks_msec() + int(timeout_sec * 1000.0)
	var file := File.new()
	yield(_tree(), "idle_frame")  # a coroutine yields at least once, also when the answer is in
	while true:
		if file.file_exists(path):
			var data = _load(path)
			if data is Dictionary:
				return data
		if file.file_exists(abort):
			var why = _load(abort)
			say("  %s stopped: %s" % [name, why.get("why", "?") if why is Dictionary else "?"])
			return null
		if OS.get_ticks_msec() >= until:
			say("  %s: no answer to %s after %s s" % [name, id, timeout_sec])
			return null
		yield(_tree(), "idle_frame")


static func _load(path: String):
	var file := File.new()
	if file.open(path, File.READ) != OK:
		return null
	var parsed := JSON.parse(file.get_as_text())
	file.close()
	return parsed.result if parsed.error == OK else null


# Written under another name first, then renamed: a reader never sees half a file.
static func _write(path: String, data: Dictionary) -> void:
	var file := File.new()
	if file.open(path + ".tmp", File.WRITE) != OK:
		return
	file.store_string(JSON.print(data))
	file.close()
	Directory.new().rename(path + ".tmp", path)
