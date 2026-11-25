extends "res://mods-unpacked/einfluffles-TogetherLocal/scenario_steps.gd"
# The scenarios of local play, one coroutine each (scenario_<name>), run by scenario_runner.gd in
# every game of a session at once: in game windows by tools\play-local.ps1 -Scenario <name> (with a
# screenshot after every step), headless by tools/check-pair.sh (PAIR-TESTS lines). One
# definition for both. Each step is director commands (director.gd) on named games; read the
# runner's header for the rules (branches only on answers, never on a game's own clock).
#
# The host's runs use the game's own test settings (debug: invulnerable, short waves), so nobody
# dies and a wave takes 10 to 20 s. Docs: docs/testing.md ("Director and scenarios", "Pair tests").
#
# The shared steps (lobby_step, character_join_step, ...) are in scenario_steps.gd. A new
# scenario: a function scenario_<name>(r) here, its name in NAMES (and in HEADLESS when it
# needs no screenshots to say something), its launch settings in LAUNCH when it needs any, its
# row in docs/testing.md.

const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")
const NAMES := [
	"join", "join_wave_shop", "resume_leave_rejoin", "host_quits", "client_quits", "kick",
	"version_mismatch", "bad_resync", "language", "three_players", "dlc_borrow",
	"version_mismatch_build"
]
# What tools/check-pair.sh runs by default: every scenario with checks (language has none).
const HEADLESS := [
	"join", "join_wave_shop", "resume_leave_rejoin", "host_quits", "client_quits", "kick",
	"version_mismatch", "bad_resync", "three_players", "dlc_borrow", "version_mismatch_build"
]
# What a scenario needs from the launcher, one line each, read as text by tools\play-local.ps1
# and tools/check-pair.sh (keep the form "<name>": "key=value ..."): clients (how many), host_dlcs
# and client_dlcs (BT_LOCAL_DLCS: all, none or ids), no_join=1 (nobody hosts or joins by itself),
# client_ref or host_ref (that side runs brotato:together of a git ref; last_release: the newest
# tag brotato-together/* of another protocol than this worktree's, and without one the launchers
# skip the scenario). A launcher option given by hand wins over the scenario's setting.
const LAUNCH := {
	"three_players": "clients=2",
	"dlc_borrow": "host_dlcs=all client_dlcs=none",
	"version_mismatch_build": "no_join=1 client_ref=last_release",
}
const LAUNCH_KEYS := ["clients", "host_dlcs", "client_dlcs", "no_join", "client_ref", "host_ref"]
const OTHER_VERSION := "0.0.0-pair"


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
	yield(clients_buy(r), "completed")


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


# Host and two or three clients (LAUNCH: clients=2; -Clients 3 in windows): all join, wave 1
# with its level-up, the shop, every client buys.
func scenario_three_players(r):
	var wave_sec := 12
	r.check(r.peers.size() >= 3, "a host and at least two clients (%s)" % [r.peers])
	yield(lobby_step(r, wave_sec), "completed")
	yield(character_join_step(r), "completed")
	yield(select_until(r, "main"), "completed")
	var host = yield(r.state(H), "completed")
	r.check(
		host.run.coop and host.run.count == r.peers.size(),
		"a co-op run with %d players (co-op %s, %s players)" % [
			r.peers.size(), host.run.coop, host.run.count
		]
	)
	yield(wave_to_shop(r, wave_sec), "completed")
	yield(r.step("clients_buy"), "completed")
	yield(clients_buy(r), "completed")


# The host owns every DLC, the clients none (LAUNCH: host_dlcs=all client_dlcs=none). In the
# lobby at the title screen a client's game is its own (the borrowed DLC is parked); from
# character selection on it uses the host's DLC it lacks (session/dlc_borrow.gd) and its lobby
# details say so (the lobby page, opened from the pause menu in the shop). Back on the title
# screen the DLC is parked again, and after leaving the lobby it is gone.
func scenario_dlc_borrow(r):
	var wave_sec := 10
	var host = yield(r.state(H), "completed")
	var host_dlcs: Array = host.dlcs.owned
	r.check(not host_dlcs.empty(), "the host owns DLC (%s)" % [host_dlcs])
	var missing := {}
	var lacking := 0
	for name in clients(r):
		var client = yield(r.state(name), "completed")
		missing[name] = []
		for dlc_id in host_dlcs:
			if not dlc_id in client.dlcs.owned:
				missing[name].append(dlc_id)
		lacking += missing[name].size()
		r.say("  %s owns %s, lacks %s" % [name, client.dlcs.owned, missing[name]])
	r.check(lacking > 0, "a client lacks a DLC the host owns")
	yield(lobby_step(r, wave_sec), "completed")
	yield(clients_own_only(r, "at the title screen in the lobby (parked)"), "completed")
	yield(character_join_step(r), "completed")
	yield(r.step("borrowed"), "completed")
	yield(clients_borrow(r, missing), "completed")
	yield(select_until(r, "main"), "completed")
	yield(wave_to_shop(r, wave_sec), "completed")
	yield(r.step("client_lobby_page"), "completed")
	yield(r.on(C, {"cmd": "press", "key": "Escape"}), "completed")
	yield(r.pause(1.0), "completed")
	yield(r.on(C, {"cmd": "button", "name": "BrotatoTogetherLobbyButton"}), "completed")
	yield(r.pause(1.5), "completed")
	yield(clients_borrow(r, missing), "completed")
	yield(r.step("back_to_title"), "completed")
	yield(r.on(C, {"cmd": "press", "key": "Escape", "times": 2}), "completed")
	yield(host_quits_run(r), "completed")
	yield(r.pause(1.0), "completed")
	yield(clients_own_only(r, "back at the title screen in the lobby (parked)"), "completed")
	yield(r.step("clients_leave"), "completed")
	yield(r.on(clients(r), {"cmd": "leave"}), "completed")
	yield(r.pause(1.0), "completed")
	yield(clients_own_only(r, "after leaving the lobby"), "completed")


# Every client's game has the DLC it owns, no borrowed one.
func clients_own_only(r, when: String):
	for name in clients(r):
		var state = yield(state_when_size(r, name, "dlcs.borrowed", 0, 10), "completed")
		r.check(
			state.dlcs.borrowed.empty() and state.dlcs.available.size() == state.dlcs.owned.size(),
			"%s has only its own DLC %s (available %s)" % [name, when, state.dlcs.available]
		)


# Every client uses the host's DLC it lacks (`missing`: client -> ids), and its lobby details
# say so (BT_DLC_BORROWED; every game is in English here).
func clients_borrow(r, missing: Dictionary):
	var note: String = Text.text("BT_DLC_BORROWED", [""]).strip_edges()
	for name in clients(r):
		var want: Array = missing[name]
		var state = yield(state_when_size(r, name, "dlcs.borrowed", want.size()), "completed")
		var borrowed: Array = state.dlcs.borrowed
		var all_in := borrowed.size() == want.size()
		for dlc_id in want:
			all_in = all_in and dlc_id in borrowed
		r.check(all_in, "%s uses the host's DLC it lacks (%s)" % [name, borrowed])
		if want.empty():
			continue
		var lines := []
		for line in str(state.lobby.details).split("\n"):
			if note in line:
				lines.append(line)
		r.check(lines.size() == 1, "%s's lobby details: '%s'" % [name, "; ".join(lines)])


# One side runs another build of brotato:together (LAUNCH: client_ref=last_release, the newest
# tag brotato-together/* of another protocol; -ClientRef or -HostRef name another). Nobody joins by
# itself: the host opens its lobby, the clients switch to German and accept an invite. The lobby's
# mod tag (brotato:together and its protocol) turns each client away: it shows why in its own
# build's words, naming both tags; a client of this worktree in German (BT_ERR_LOBBY_VERSION). The
# host keeps its lobby, alone, without an error. (version_mismatch: one protocol, another mod
# version, rejected on HELLO.)
func scenario_version_mismatch_build(r):
	var refs := {}
	var other := false
	for name in r.peers:
		var state = yield(r.state(name), "completed")
		refs[name] = str(state.get("ref", ""))
		other = other or refs[name] != refs[H]
	r.check(other, "host and clients run different builds (%s)" % [refs])
	yield(r.step("lobby"), "completed")
	yield(r.on(H, {"cmd": "host_lobby"}), "completed")
	yield(r.on(clients(r), {"cmd": "language", "locale": "de"}), "completed")
	yield(r.pause(1.0), "completed")
	var host = yield(r.state(H), "completed")
	var host_tag: String = host.lobby.tag
	yield(r.step("clients_refused"), "completed")
	yield(r.on(clients(r), {"cmd": "join", "wait": false}), "completed")
	for name in clients(r):
		var state = null
		for i in 20:
			if i > 0:
				yield(r.pause(1.0), "completed")
			state = yield(r.state(name), "completed")
			if state.session.error != "":
				break
		var error: String = state.session.error
		var tag: String = state.lobby.tag
		r.say("  %s (%s): '%s'" % [name, refs[name] if refs[name] != "" else "this worktree", error])
		r.check(not state.lobby.in and error != "", "%s is not in the lobby and shows why" % name)
		r.check(
			host_tag != tag and host_tag in error and tag in error,
			"%s's reason names both builds (host %s, own %s)" % [name, host_tag, tag]
		)
		if refs[name] == "":  # this worktree's build: the German text
			var command := {"cmd": "text", "key": "BT_ERR_LOBBY_VERSION", "args": [host_tag, tag]}
			var text = yield(r.on(name, command), "completed")
			r.check(
				str(text[0].result.locale).begins_with("de") and error == text[0].result.text,
				"%s's reason is its German text ('%s')" % [name, text[0].result.text]
			)
	yield(r.pause(2.0), "completed")  # the main menu's error line, for the screenshot
	yield(r.step("host_unharmed"), "completed")
	yield(r.pause(3.0), "completed")
	host = yield(r.state(H), "completed")
	r.check(
		host.lobby.in and host.lobby.is_host and host.lobby.members == 1 and host.session.error == "",
		"the host keeps its lobby, alone, no error (%s, %s members, '%s')" % [
			host.lobby.in, host.lobby.members, host.session.error
		]
	)
	r.check(host.scene == "title_screen", "the host is on the title screen (%s)" % host.scene)
