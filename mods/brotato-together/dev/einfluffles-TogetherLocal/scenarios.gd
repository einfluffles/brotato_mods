extends Reference
# The scenarios of local play, one coroutine each (scenario_<name>), run by scenario_runner.gd in
# every game of a session at once: in game windows by tools\play-local.ps1 -Scenario <name> (with a
# screenshot after every step), headless by tools/check-pair.sh (PAIR-TESTS lines). One
# definition for both. Each step is director commands (director.gd) on named games; read the
# runner's header for the rules (branches only on answers, never on a game's own clock).
#
# The host's runs use the game's own test settings (debug: invulnerable, short waves), so nobody
# dies and a wave takes 10 to 20 s. Docs: docs/testing.md ("Director and scenarios", "Pair tests").
#
# A new scenario: a function scenario_<name>(r) here, its name in NAMES (and in HEADLESS when it
# needs no screenshots to say something), its row in docs/testing.md.

const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")
const NAMES := [
	"join", "join_wave_shop", "resume_leave_rejoin", "host_quits", "client_quits", "kick",
	"version_mismatch", "bad_resync", "language"
]
# What tools/check-pair.sh runs by default: every scenario with checks (language has none).
const HEADLESS := [
	"join", "join_wave_shop", "resume_leave_rejoin", "host_quits", "client_quits", "kick",
	"version_mismatch", "bad_resync"
]
const H := "host"
const C := "client1"
const BOTH := ["host", "client1"]
const BOOT_SEC := 150  # the first wait: a first boot after fresh files took up to 46 s
const JOIN_HOLD_MSEC := 1500  # holding accept joins a co-op slot after about 0.7 s
const OTHER_VERSION := "0.0.0-pair"


# --- Shared parts ---


# Both games in the host's lobby at the title screen with the handshake done; the host's runs are
# short and nobody dies (the game's DebugService: the director's debug command).
func lobby_step(r, wave_sec: int):
	yield(r.step("lobby"), "completed")
	var settings := {"cmd": "debug", "invulnerable": true, "wave_sec": wave_sec}
	yield(r.on(H, settings), "completed")
	var lobby := {"cmd": "wait_for", "scene": "title_screen", "session.ready": 1}
	lobby["timeout_sec"] = BOOT_SEC
	var each := {H: _with(lobby, {"lobby.members": 2}), C: _with(lobby, {"lobby.in": true})}
	yield(r.on(BOTH, each), "completed")


static func _with(command: Dictionary, more: Dictionary) -> Dictionary:
	var merged := command.duplicate()
	for key in more:
		merged[key] = more[key]
	return merged


# Start on the host, then both players hold accept to join: the host's player first. Players
# who are still in from a run before do not hold again.
func character_join_step(r, suffix := ""):
	yield(r.step("character_selection" + suffix), "completed")
	yield(r.on(H, {"cmd": "button", "name": "StartButton"}), "completed")
	yield(r.on(BOTH, {"cmd": "wait_for", "scene": "character_selection"}), "completed")
	yield(r.pause(1.0), "completed")
	var state = yield(r.state(H), "completed")
	if state.players < 1:
		yield(r.on(H, _hold()), "completed")
	yield(r.on(H, {"cmd": "wait_for", "players": 1, "timeout_sec": 10}), "completed")
	state = yield(r.state(H), "completed")
	if state.players < 2:
		yield(r.on(C, _hold()), "completed")
	yield(r.on(H, {"cmd": "wait_for", "players": 2, "timeout_sec": 10}), "completed")
	yield(r.pause(1.0), "completed")


static func _hold() -> Dictionary:
	return {"cmd": "press", "key": "Enter", "hold_ms": JOIN_HOLD_MSEC}


# Accept on both games, screen by screen (character, weapon, difficulty), until the host's scene
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
			yield(r.on(C, {"cmd": "wait_for", "scene": seen}), "completed")
		yield(r.on(BOTH, {"cmd": "press", "key": "Enter"}), "completed")
		yield(r.pause(1.5), "completed")
	yield(r.on(BOTH, {"cmd": "wait_for", "scene": target}), "completed")


# From the start of the wave to the shop: XP and gold for every player (a level-up at the end
# of the wave, gold to buy with), the level-up panels chosen with accept on both games.
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
			yield(r.on(BOTH, {"cmd": "press", "key": "Enter"}), "completed")
		yield(r.pause(1.0), "completed")
	r.check(level_up, "the wave ended with level-up panels")
	yield(r.step("shop" + suffix), "completed")
	yield(r.on(BOTH, {"cmd": "wait_for", "scene": "coop_shop"}), "completed")
	yield(r.pause(2.0), "completed")


# The host quits the run to the title screen (Pause, Quit, Confirm); the client follows.
func host_quits_run(r):
	yield(r.on(H, {"cmd": "press", "key": "Escape"}), "completed")
	yield(r.on(H, {"cmd": "button", "name": "QuitButton"}), "completed")
	yield(r.on(H, {"cmd": "button", "name": "ConfirmButton"}), "completed")
	yield(r.on(BOTH, {"cmd": "wait_for", "scene": "title_screen"}), "completed")


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


# --- Scenarios ---


# The client joins through +connect_lobby: both in one lobby, the mod's HELLO / WELCOME done.
func scenario_join(r):
	yield(lobby_step(r, 12), "completed")
	yield(r.step("handshake"), "completed")
	var host = yield(r.state(H), "completed")
	var client = yield(r.state(C), "completed")
	r.check(
		host.lobby.members == 2 and host.lobby.is_host and host.session.ready == 1,
		"the host has the client in its lobby, handshake done (%s members, %s ready)" % [
			host.lobby.members, host.session.ready
		]
	)
	r.check(
		client.lobby.id == host.lobby.id and not client.lobby.is_host and client.session.ready == 1,
		"the client is in the host's lobby with the host's WELCOME (%s ready)" % client.session.ready
	)
	r.check(
		host.session.peer_ready >= 1 and client.session.peer_ready >= 1,
		"both sides saw peer_ready (host %s, client %s)" % [
			host.session.peer_ready, client.session.peer_ready
		]
	)
	r.check(
		host.session.error == "" and client.session.error == "",
		"no lobby error on either side ('%s', '%s')" % [host.session.error, client.session.error]
	)


func scenario_join_wave_shop(r):
	var wave_sec := 12
	yield(lobby_step(r, wave_sec), "completed")
	yield(character_join_step(r), "completed")
	yield(select_until(r, "main"), "completed")
	yield(wave_to_shop(r, wave_sec), "completed")
	yield(r.step("client_buys"), "completed")
	var before = yield(r.state(H), "completed")
	yield(r.on(C, {"cmd": "press", "key": "Enter"}), "completed")
	yield(r.pause(2.0), "completed")
	var after = yield(r.state(H), "completed")
	var gear_before := int(before.run.items[1] + before.run.weapons[1])
	var gear_after := int(after.run.items[1] + after.run.weapons[1])
	r.check(
		after.run.gold[1] < before.run.gold[1] and gear_after > gear_before,
		"the client's player bought something on the host (gold %s -> %s, gear %s -> %s)" % [
			before.run.gold[1], after.run.gold[1], gear_before, gear_after
		]
	)


# Host and client play wave 1 into the shop; the host quits to the title screen and continues
# the saved run. The client takes saved player 1 on the co-op resume screen, leaves (the host
# gets saved player 1 back and does not load the shop), joins again, takes saved player 1
# again; the host takes saved player 2 and the shop loads with both.
func scenario_resume_leave_rejoin(r):
	var wave_sec := 10
	yield(lobby_step(r, wave_sec), "completed")
	yield(character_join_step(r), "completed")
	yield(select_until(r, "main"), "completed")
	yield(wave_to_shop(r, wave_sec), "completed")
	yield(r.step("host_quits_to_title"), "completed")
	yield(host_quits_run(r), "completed")
	var state = yield(r.state(H), "completed")
	r.check(
		state.run.saved and state.lobby.members == 2,
		"the host has a saved run and both are still in the lobby (%s, %s)" % [
			state.run.saved, state.lobby.members
		]
	)
	yield(r.step("host_continues"), "completed")
	yield(r.on(H, {"cmd": "button", "name": "ContinueButton"}), "completed")
	yield(r.on(BOTH, {"cmd": "wait_for", "scene": "coop_resume"}), "completed")
	yield(r.pause(1.5), "completed")
	var host = yield(r.state(H), "completed")
	var client = yield(r.state(C), "completed")
	r.check(
		host.run.count == 2 and host.resume_shown == 0 and host.players == 0,
		"the host's resume screen shows saved player 1 of 2, nobody in (%s, %s)" % [
			host.resume_shown, host.players
		]
	)
	r.check(
		client.resume_shown == 0 and client.resume_gold == host.resume_gold,
		"the client's copy shows the same saved player and gold (%s, %s)" % [
			client.resume_shown, client.resume_gold
		]
	)
	yield(r.step("client_takes_saved_player_1"), "completed")
	yield(take_saved_player_1(r), "completed")
	yield(r.step("client_leaves"), "completed")
	yield(r.on(C, {"cmd": "leave"}), "completed")
	var back := {"cmd": "wait_for", "lobby.members": 1, "players": 0, "resume_shown": 0}
	yield(r.on(H, _with(back, {"timeout_sec": 10})), "completed")
	yield(r.pause(3.0), "completed")
	state = yield(r.state(H), "completed")
	r.check(
		state.scene == "coop_resume" and state.resume_shown == 0 and state.players == 0,
		"the host gives saved player 1 back and stays on the resume screen (%s, %s)" % [
			state.scene, state.resume_shown
		]
	)
	yield(r.step("client_rejoins"), "completed")
	yield(r.on(C, {"cmd": "join"}), "completed")
	yield(r.on(C, {"cmd": "wait_for", "scene": "coop_resume", "resume_shown": 0}), "completed")
	yield(r.on(H, {"cmd": "wait_for", "lobby.members": 2}), "completed")
	yield(r.pause(1.0), "completed")
	yield(r.step("client_takes_saved_player_1_again"), "completed")
	yield(take_saved_player_1(r), "completed")
	yield(r.step("host_takes_saved_player_2"), "completed")
	yield(join_hold(r, H), "completed")
	yield(r.on(BOTH, {"cmd": "wait_for", "scene": "coop_shop"}), "completed")
	yield(r.pause(2.0), "completed")
	state = yield(r.state(H), "completed")
	r.check(
		state.players == 2 and state.run.count == 2,
		"the shop loads with both players (%s connected, %s in the run)" % [
			state.players, state.run.count
		]
	)


func take_saved_player_1(r):
	yield(join_hold(r, C), "completed")
	var taken := {"cmd": "wait_for", "resume_shown": 1, "timeout_sec": 10}
	yield(r.on(H, _with(taken, {"players": 1})), "completed")
	yield(r.on(C, taken), "completed")


# The host's game closes mid-wave (its window's close): the client drops back to its own title
# screen with "The host left the lobby".
func scenario_host_quits(r):
	yield(lobby_step(r, 30), "completed")
	yield(character_join_step(r), "completed")
	yield(select_until(r, "main"), "completed")
	yield(r.step("host_closes"), "completed")
	yield(r.pause(3.0), "completed")
	yield(r.on(H, {"cmd": "quit"}), "completed")  # the host's part ends here
	var out := {"cmd": "wait_for", "scene": "title_screen", "lobby.in": false}
	yield(r.on(C, out), "completed")
	var client = yield(r.state(C), "completed")
	var left: String = tr("BT_ERR_HOST_LEFT")
	r.check(
		client.session.error == left,
		"the client was told the host left ('%s')" % client.session.error
	)
	r.check(
		client.session.ready == 0 and not client.run.coop,
		"the client is on its own again (%s ready, co-op run %s)" % [
			client.session.ready, client.run.coop
		]
	)


# The client's game closes mid-wave (its window's close): the host plays on with the client's
# slot kept for a rejoin. tools/check-pair.sh also fails on a script error the closing game logs.
func scenario_client_quits(r):
	yield(lobby_step(r, 30), "completed")
	yield(character_join_step(r), "completed")
	yield(select_until(r, "main"), "completed")
	yield(r.step("client_closes"), "completed")
	yield(r.pause(3.0), "completed")
	yield(r.on(C, {"cmd": "quit"}), "completed")  # the client's part ends here
	yield(r.on(H, {"cmd": "wait_for", "lobby.members": 1, "session.ready": 0}), "completed")
	yield(r.pause(2.0), "completed")
	var host = yield(r.state(H), "completed")
	r.check(
		host.scene == "main" and host.run.count == 2 and host.lobby.in,
		"the host plays on in its lobby with the client's slot kept (%s, %s in the run)" % [
			host.scene, host.run.count
		]
	)
	r.check(host.session.error == "", "the host shows no lobby error ('%s')" % host.session.error)


# The host kicks the client (Session.kick); the kicked client can join again.
func scenario_kick(r):
	yield(lobby_step(r, 12), "completed")
	yield(r.step("host_kicks"), "completed")
	yield(r.on(H, {"cmd": "kick"}), "completed")
	yield(r.on(C, {"cmd": "wait_for", "scene": "title_screen", "lobby.in": false}), "completed")
	yield(r.on(H, {"cmd": "wait_for", "lobby.members": 1, "session.ready": 0}), "completed")
	var client = yield(r.state(C), "completed")
	var kicked: String = tr("BT_ERR_KICKED")
	r.check(
		client.session.error == kicked,
		"the client was told it was removed ('%s')" % client.session.error
	)
	yield(r.step("client_joins_again"), "completed")
	yield(r.on(C, {"cmd": "join"}), "completed")
	yield(r.on(H, {"cmd": "wait_for", "lobby.members": 2, "session.ready": 1}), "completed")
	yield(r.on(C, {"cmd": "wait_for", "session.ready": 1}), "completed")


# A client with another brotato:together version is turned away with the code "mod" and both
# versions (Compat), shown in its language; with its own version again it joins.
func scenario_version_mismatch(r):
	yield(lobby_step(r, 12), "completed")
	yield(r.step("client_leaves"), "completed")
	yield(r.on(C, {"cmd": "leave"}), "completed")
	yield(r.on(H, {"cmd": "wait_for", "lobby.members": 1}), "completed")
	yield(r.step("client_with_another_version"), "completed")
	yield(r.on(C, {"cmd": "mod_version", "version": OTHER_VERSION}), "completed")
	yield(r.on(C, {"cmd": "join"}, true), "completed")  # in, then out again: may miss "in"
	yield(r.on(C, {"cmd": "wait_for", "lobby.in": false}), "completed")
	yield(r.on(H, {"cmd": "wait_for", "lobby.members": 1, "session.ready": 0}), "completed")
	var host = yield(r.state(H), "completed")
	var client = yield(r.state(C), "completed")
	var expected := rejected_text("mod", OTHER_VERSION, host.session.mod_version)
	r.check(
		client.session.error == expected,
		"the client was rejected with the code mod ('%s')" % client.session.error
	)
	r.check(
		client.session.ready == 0 and host.lobby.members == 1,
		"the client is not in the host's lobby (%s ready, the host has %s)" % [
			client.session.ready, host.lobby.members
		]
	)
	yield(r.step("client_with_its_version"), "completed")
	yield(r.on(C, {"cmd": "mod_version", "version": ""}), "completed")
	yield(r.on(C, {"cmd": "join"}), "completed")
	yield(r.on(H, {"cmd": "wait_for", "lobby.members": 2, "session.ready": 1}), "completed")
	yield(r.on(C, {"cmd": "wait_for", "session.ready": 1}), "completed")


# What a rejected client shows (session.gd, _handle_welcome).
static func rejected_text(code: String, mine: String, hosts: String) -> String:
	var reason: String = Compat.describe({"code": code, "args": [mine, hosts]})
	return Text.text("BT_ERR_REJECTED", [reason])


# Both games on the bad link profile; the host's next reliable send fails (LimitExceeded), the
# host runs a full resync for the client, and the run goes on: character selection, a wave.
func scenario_bad_resync(r):
	yield(lobby_step(r, 20), "completed")
	yield(r.step("bad_link"), "completed")
	yield(r.on(BOTH, {"cmd": "set_profile", "name": "bad"}), "completed")
	var before = yield(r.state(H), "completed")
	yield(r.on(H, {"cmd": "fail_send", "count": 1}), "completed")
	yield(character_join_step(r), "completed")
	var host = yield(r.state(H), "completed")
	r.check(
		host.session.peer_ready > before.session.peer_ready,
		"the host ran a full resync for the client (peer_ready %s -> %s)" % [
			before.session.peer_ready, host.session.peer_ready
		]
	)
	yield(select_until(r, "main"), "completed")
	yield(r.step("wave_on_a_bad_link"), "completed")
	yield(r.pause(4.0), "completed")
	host = yield(r.state(H), "completed")
	var client = yield(r.state(C), "completed")
	r.check(
		host.scene == "main" and client.scene == "main" and host.players == 2,
		"both play the wave after the resync (%s, %s, %s players)" % [
			host.scene, client.scene, host.players
		]
	)
	r.check(
		client.session.ready == 1 and host.session.ready == 1,
		"the session is still up on both sides"
	)


# Both games switch to German and Russian (the options' call) at the title screen with the
# lobby, in character selection and in the wave (the damage meter at each life bar). Screenshots
# only, no checks of the text.
func scenario_language(r):
	var wave_sec := 12
	yield(lobby_step(r, wave_sec), "completed")
	for locale in ["de", "ru"]:
		yield(r.step("lobby-" + locale), "completed")
		yield(r.on("all", {"cmd": "language", "locale": locale}), "completed")
		yield(r.pause(1.0), "completed")
		yield(character_join_step(r, "-" + locale), "completed")
		yield(select_until(r, "main", "-" + locale), "completed")
		yield(wave_to_shop(r, wave_sec, "-" + locale), "completed")
		yield(r.step("title-" + locale), "completed")
		yield(host_quits_run(r), "completed")
