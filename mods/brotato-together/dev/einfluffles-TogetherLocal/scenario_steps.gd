extends Reference
# The shared steps of the local-play scenarios (scenarios.gd extends this): the parts several
# scenarios play through, for a host and any number of clients (the scenario's peers, r.peers).
# Each takes the runner (scenario_runner.gd) and yields; the rules of the runner's header hold
# here too (branches only on answers and counts, never on a game's own clock).

const H := "host"
const C := "client1"
const BOTH := ["host", "client1"]
const BOOT_SEC := 150  # the first wait: a first boot after fresh files took up to 46 s
const JOIN_HOLD_MSEC := 1500  # holding accept joins a co-op slot after about 0.7 s


# The clients of the scenario (client1, client2, ...).
static func clients(r) -> Array:
	var names := []
	for name in r.peers:
		if name != H:
			names.append(name)
	return names


# Every game in the host's lobby at the title screen with the handshakes done; the host's runs
# are short and nobody dies (the game's DebugService: the director's debug command).
func lobby_step(r, wave_sec: int):
	yield(r.step("lobby"), "completed")
	var settings := {"cmd": "debug", "invulnerable": true, "wave_sec": wave_sec}
	yield(r.on(H, settings), "completed")
	var lobby := {"cmd": "wait_for", "scene": "title_screen", "timeout_sec": BOOT_SEC}
	var others := clients(r)
	var each := {H: _with(lobby, {"lobby.members": r.peers.size(), "session.ready": others.size()})}
	for name in others:
		each[name] = _with(lobby, {"lobby.in": true, "session.ready": 1})
	yield(r.on("all", each), "completed")
	yield(texts_check(r), "completed")


# Every game of this worktree's build shows the mod's texts in its lobby frame, not their keys
# (BT_...): the mod's translations loaded. With tools/check-pair.sh's zips (the default) this
# reads the mod's files as the Workshop delivers them. Another build's game (state.ref) is left
# out: a release before the zip fix shows keys there.
func texts_check(r):
	var answers = yield(r.on("all", {"cmd": "query"}), "completed")
	for i in r.peers.size():
		var state: Dictionary = answers[i].state
		if str(state.get("ref", "")) != "":
			continue
		var shown: Array = state.get("frame_texts", [])
		var keys := []
		for text in shown:
			if str(text).begins_with("BT_"):
				keys.append(text)
		r.check(
			not shown.empty() and keys.empty(),
			"%s's lobby frame shows the mod's texts, no key (%s)" % [r.peers[i], shown]
		)


static func _with(command: Dictionary, more: Dictionary) -> Dictionary:
	var merged := command.duplicate()
	for key in more:
		merged[key] = more[key]
	return merged


# Start on the host, then every player holds accept to join, one after another: the host's
# player first, then client1, client2, ... (so player index = place in that order). Players who
# are still in from a run before do not hold again.
func character_join_step(r, suffix := ""):
	yield(r.step("character_selection" + suffix), "completed")
	yield(r.on(H, {"cmd": "button", "name": "StartButton"}), "completed")
	yield(r.on("all", {"cmd": "wait_for", "scene": "character_selection"}), "completed")
	yield(r.pause(1.0), "completed")
	var count := 0
	for name in r.peers:
		count += 1
		var state = yield(r.state(H), "completed")
		if state.players < count:
			yield(r.on(name, _hold()), "completed")
		yield(r.on(H, {"cmd": "wait_for", "players": count, "timeout_sec": 10}), "completed")
	yield(r.pause(1.0), "completed")


static func _hold() -> Dictionary:
	return {"cmd": "press", "key": "Enter", "hold_ms": JOIN_HOLD_MSEC}


# Accept on every game, screen by screen (character, weapon, difficulty), until the host's scene
# is `target`. Each new screen is a step of its own.
func select_until(r, target: String, suffix := "", max_presses := 12):
	var seen := "character_selection"
	for _i in max_presses:
		var state = yield(r.state(H), "completed")
		if state.scene == target:
			break
		if state.scene != seen:
			seen = state.scene
			yield(r.step(seen + suffix), "completed")
			yield(r.on(clients(r), {"cmd": "wait_for", "scene": seen}), "completed")
		yield(r.on("all", {"cmd": "press", "key": "Enter"}), "completed")
		yield(r.pause(1.5), "completed")
	yield(r.on("all", {"cmd": "wait_for", "scene": target}), "completed")


# From the start of the wave to the shop: XP and gold for every player (a level-up at the end
# of the wave, gold to buy with), the level-up panels chosen with accept on every game.
func wave_to_shop(r, wave_sec: int, suffix := ""):
	yield(r.step("wave" + suffix), "completed")
	yield(r.on(H, {"cmd": "debug", "xp": 20, "gold": 100}), "completed")
	yield(r.pause(4.0), "completed")
	var level_up := false
	for _i in wave_sec + 60:  # a count, not a clock: the same in every game
		var state = yield(r.state(H), "completed")
		if state.scene == "coop_shop":
			break
		if state.scene == "main" and state.get("upgrades", false):
			if not level_up:
				level_up = true
				yield(r.step("level_up" + suffix), "completed")
				yield(r.pause(1.0), "completed")
				yield(r.end_step(), "completed")
			yield(r.on("all", {"cmd": "press", "key": "Enter"}), "completed")
		yield(r.pause(1.0), "completed")
	r.check(level_up, "the wave ended with level-up panels")
	yield(r.step("shop" + suffix), "completed")
	yield(r.on("all", {"cmd": "wait_for", "scene": "coop_shop"}), "completed")
	yield(r.pause(2.0), "completed")


# Each client presses accept on the item under its cursor in the shop; checked on the host: that
# player's gold went down and it has one more item or weapon (player index = join order).
func clients_buy(r):
	var before = yield(r.state(H), "completed")
	var others := clients(r)
	yield(r.on(others, {"cmd": "press", "key": "Enter"}), "completed")
	yield(r.pause(2.0), "completed")
	var after = yield(r.state(H), "completed")
	for p in range(1, others.size() + 1):
		var gear_before := int(before.run.items[p] + before.run.weapons[p])
		var gear_after := int(after.run.items[p] + after.run.weapons[p])
		r.check(
			after.run.gold[p] < before.run.gold[p] and gear_after > gear_before,
			"%s's player bought something on the host (gold %s -> %s, gear %s -> %s)" % [
				others[p - 1], before.run.gold[p], after.run.gold[p], gear_before, gear_after
			]
		)


# The host quits the run to the title screen (Pause, Quit, Confirm); the clients follow.
func host_quits_run(r):
	yield(r.on(H, {"cmd": "press", "key": "Escape"}), "completed")
	yield(r.on(H, {"cmd": "button", "name": "QuitButton"}), "completed")
	yield(r.on(H, {"cmd": "button", "name": "ConfirmButton"}), "completed")
	yield(r.on("all", {"cmd": "wait_for", "scene": "title_screen"}), "completed")


# Holds accept in `name`'s game to join a slot. With screenshots, every game takes one while it
# is held (<NN>-<step>-holding: the join's progress, before it takes the slot).
func join_hold(r, name: String):
	if not r.shots:
		yield(r.on(name, _hold()), "completed")
		return
	var holding: String = r.tag() + "-holding"
	var commands := {}
	for other in r.peers:
		commands[other] = {"cmd": "screenshot", "name": holding, "after_ms": 450}
	commands[name] = _with(_hold(), {"shot": holding, "shot_ms": 400})
	yield(r.on(r.peers, commands), "completed")


# The state of `name`'s game once `key` (a dotted key of the state) has `size` entries, or the
# last one after `tries` looks a second apart. A count, not a clock. Yields.
func state_when_size(r, name: String, key: String, size: int, tries := 20):
	var state = null
	for i in tries:
		if i > 0:
			yield(r.pause(1.0), "completed")
		state = yield(r.state(name), "completed")
		var value = _lookup(state, key)
		if value is Array and value.size() == size:
			break
	return state


static func _lookup(state: Dictionary, key: String):
	var value = state
	for part in key.split("."):
		value = value.get(part) if value is Dictionary else null
	return value
