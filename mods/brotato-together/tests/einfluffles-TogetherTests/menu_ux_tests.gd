extends Reference
# The wave-failed retry prompt and its cursor on clients (incl. cursors that arrive before their
# controls are visible, and the cursors' key on the prompt), the battle -> next screen
# transition, and the client's copy of the selection grid.

const ClientView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/client_view.gd")
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const FocusSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/focus_sync.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const CursorTargetTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/cursor_target_tests.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const PauseControl := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/pause_control.gd"
)
const CursorKeyTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/cursor_key_tests.gd"
)
const HOST := 2  # fake steam ids of the streams of its own
const P1 := 11
const P2 := 12


var t: Node = null  # the test mod: _check()


# Calls BattleHost's peer_ready handler from a newer object (see _test_join_order).
class PeerReadyRelay:
	extends Reference
	var target: Node = null

	func _on_peer_ready(steam_id: int) -> void:
		target._on_peer_ready(steam_id)


# In a battle-capable state (run from the battle tests); leaves no scene of its own behind.
func run_battle_tests(test_mod: Node, together: Node):
	t = test_mod
	yield(_test_retry_prompt(together), "completed")


# Needs the character selection scene with two co-op players (after the menu mirror test).
func run_menu_tests(test_mod: Node, together: Node):
	t = test_mod
	yield(_test_selection_grid(together), "completed")
	_test_menu_sections(together)


func _tree() -> SceneTree:
	return t.get_tree()


# A state stream of its own on state_stream_tests.gd's fake session: stepped by hand, keeps what
# it sends, and leaves the mod's stream (and its revisions) alone. Free it with _free_stream.
func _stream(host: bool, ready_peers: Array) -> Node:
	var session = StateStreamTests.FakeSession.new()
	session.transport = StateStreamTests.FakeTransport.new()
	session.transport.host_id = HOST
	session.host = host
	for peer in ready_peers:
		session.peers[peer] = {"ready": true}
	var stream: Node = StateStream.new()
	stream.setup(session)
	return stream


func _free_stream(stream: Node) -> void:
	stream.session.free()
	stream.free()


# STATE messages the stream sent since the last call: [steam_id, [section, revision, body]].
static func _take(stream: Node) -> Array:
	var messages := []
	for sent in stream.session.sent:
		if sent[1] == Protocol.Msg.STATE:
			messages.append([sent[0], sent[2]])
	stream.session.sent.clear()
	return messages


static func _sections(messages: Array) -> Array:
	var sections := []
	for message in messages:
		sections.append([message[0], message[1][0]])
	return sections


func _frames(count: int):
	for _i in count:
		yield(_tree(), "idle_frame")


# Host fails a wave: the retry prompt and its cursor reach the client's puppet battle; clicking
# the client's copy changes nothing locally. The prompt and a pause (sections retry and
# pause_battle) arrive while the puppet battle loads, as for a peer joining then: kept pending
# and applied once it is ready. Then the battle -> next screen transition.
func _test_retry_prompt(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var retry_sync: Node = together.retry_sync
	var stream: Node = together.state_stream
	host.set_process(false)
	_tree().change_scene("res://main.tscn")
	yield(_frames(2), "completed")
	var main := _tree().current_scene
	var scene_path: String = main.filename
	host._start_battle(main)
	var pause_message := _test_pause_host(together)
	var host_retry = main.get("_retry_wave")
	t._check(
		stream.message_for(StateStream.RETRY, P1)[2] == null, "retry: inactive while hidden"
	)
	host_retry.show()
	yield(_frames(2), "completed")
	# What the host sends (and resends on peer_ready), off the wire.
	var message: Array = bytes2var(var2bytes(stream.message_for(StateStream.RETRY, P1)), false)
	var body = message[2]
	t._check(body is Dictionary and body.player == 0, "retry: host reports the prompt")
	var host_emulator = host_retry.get_node("FocusEmulator")
	var host_focus = host_emulator.focused_control
	t._check(host_focus != null, "retry: host cursor on a button")
	var focus_body := {
		"scene": main.filename, "cursors": [FocusSync.cursor_of(host_emulator, host_focus, main)]
	}
	focus_body = bytes2var(var2bytes(focus_body), false)
	CursorKeyTests.new(t, together).run_retry(host_retry)
	# The same button on the client, found by its scene path (the retry prompt is all named).
	var focus_path: NodePath = main.get_path_to(host_focus) if host_focus != null else NodePath()
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	_test_join_order(together)
	host._end_battle()

	# The other order, kept as a robustness check (a join gets BATTLE_START first, see
	# _test_join_order): the sections arrive before their battle is known.
	stream.receive(message)
	stream.receive(pause_message)
	yield(_frames(2), "completed")  # retried every frame meanwhile
	t._check(
		stream.is_pending(StateStream.RETRY) and stream.is_pending(StateStream.PAUSE_BATTLE),
		"retry + pause: kept while their battle is unknown (before BATTLE_START)"
	)
	client._on_battle_start(start)
	t._check(
		stream.is_pending(StateStream.RETRY) and stream.is_pending(StateStream.PAUSE_BATTLE),
		"retry + pause: kept while the puppet battle loads"
	)
	yield(client, "battle_entered")
	var puppet: Node = client._main
	var client_retry = puppet.get("_retry_wave")
	var banner = puppet.get_node_or_null(PauseControl.BANNER_NAME)
	t._check(
		client_retry.visible and not stream.is_pending(StateStream.RETRY),
		"retry: applied once the puppet battle is ready"
	)
	t._check(
		banner != null and banner.visible
		and PauseControl.banner_label(banner).text.begins_with("Paused by")
		and not stream.is_pending(StateStream.PAUSE_BATTLE),
		"pause: applied once the puppet battle is ready"
	)
	stream.receive([StateStream.PAUSE_BATTLE, pause_message[1] + 1, null])
	t._check(banner != null and not banner.visible and not client._paused, "pause: resumed")
	stream.receive([StateStream.RETRY, message[1], null])
	t._check(not client_retry.visible, "retry: hidden when the host's is (section inactive)")
	yield(_frames(1), "completed")  # FocusSync picks up the new scene
	# The cursor arrives first: its button is hidden until the prompt shows -> kept and retried.
	# As STATE section cursors, with the revision the host's stream would send now.
	var focus_message: Array = stream.message_for(StateStream.CURSORS, 0)
	focus_message[2] = focus_body
	stream.receive(focus_message)
	t._check(
		stream.is_pending(StateStream.CURSORS) and puppet.filename == scene_path,
		"focus: unresolvable cursor kept"
	)
	stream.receive(message)  # the prompt again, same revision (a resync)
	t._check(client_retry.visible, "retry: client shows the prompt")
	var label = client_retry.get_node_or_null(retry_sync.WAITING_LABEL)
	t._check(label != null and "P1" in label.text, "retry: says whose choice it is")
	# Nodes another mod added on the client only: first in the scene and next to the button.
	var expected = puppet.get_node_or_null(focus_path) if not focus_path.is_empty() else null
	var next_to := [expected] if expected != null else []
	var extras := CursorTargetTests.add_mod_nodes(client._main, next_to)
	stream.retry()  # what the stream does every frame while a section is pending
	var client_focus = client_retry.get_node("FocusEmulator").focused_control
	t._check(
		client_focus != null and client_focus == expected,
		"focus: cursor applied once the prompt is visible, extra nodes on the client"
	)
	CursorTargetTests.remove_nodes(extras)
	t._check(not stream.is_pending(StateStream.CURSORS), "focus: resolved message cleared")
	client_retry.get_node("%ConfirmButton").emit_signal("pressed")
	client_retry.get_node("%OkButton").emit_signal("pressed")
	yield(_frames(3), "completed")
	t._check(_tree().current_scene == puppet, "retry: client's copy doesn't change scenes")

	# Battle over: the frozen battle stays (muted) until the next screen replaces it, and the
	# fallback view shows up neutral before saying it's waiting.
	together._client_active = true
	client._leave_battle()
	yield(_frames(3), "completed")
	t._check(_tree().current_scene == puppet, "transition: battle kept while the next loads")
	t._check(SoundRelay.is_muted(), "transition: kept battle muted")
	together._on_transition_grace_over(-1)  # a newer scene already replaced it: no-op
	t._check(_tree().current_scene == puppet, "transition: newer scene left alone")
	yield(_tree().create_timer(together.TRANSITION_GRACE_SEC + 0.2), "timeout")
	var view := _tree().current_scene
	t._check(view != null and view.get_script() == ClientView, "transition: view as fallback")
	if view != null and view.get_script() == ClientView:
		t._check(view._title.text == "", "transition: no 'waiting' flash")
		t._check(not SoundRelay.is_muted(), "transition: view not muted")
		yield(_tree().create_timer(view.WAITING_DELAY_SEC + 0.2), "timeout")
		t._check("Waiting" in view._title.text, "transition: 'waiting' after a delay")
	together._client_active = false
	Puppet.set_active(false)
	host.set_process(true)


# A peer becomes ready while the host's battle shows the retry prompt, paused: the first message
# it gets is BattleHost's BATTLE_START (which battle the sections are for), then retry and
# pause_battle in section order. A stream of its own with the real providers on a fake session;
# BattleHost answers its peer_ready through a relay connected after the stream (and newer), so
# Godot calls the stream's handler first. Synchronous: the tree is paused only for this check.
func _test_join_order(together: Node) -> void:
	var host: Node = together.battle_host
	var joins := _stream(true, [P1])
	joins.register_provider(StateStream.RETRY, together.retry_sync)
	joins.register_provider(StateStream.PAUSE_BATTLE, host)
	var relay := PeerReadyRelay.new()
	relay.target = host
	joins.session.connect("peer_ready", relay, "_on_peer_ready")
	var session: Node = host.session
	host.session = joins.session  # BATTLE_START goes out on the fake session too
	_tree().paused = true
	joins.step(0.0)
	joins.session.sent.clear()
	joins.session.peers[P2] = {"ready": true}
	joins.session.emit_signal("peer_ready", P2)
	joins.step(0.0)
	_tree().paused = false
	host.session = session
	var to_p2 := []
	for sent in joins.session.sent:
		if sent[0] == P2:
			to_p2.append([sent[1], sent[2][0] if sent[1] == Protocol.Msg.STATE else -1])
	var expected := [
		[Protocol.Msg.BATTLE_START, -1],
		[Protocol.Msg.STATE, StateStream.RETRY],
		[Protocol.Msg.STATE, StateStream.PAUSE_BATTLE],
	]
	t._check(
		var2str(to_p2) == var2str(expected),
		"join mid-battle: BATTLE_START first, then retry and pause in order: %s" % [to_p2]
	)
	_free_stream(joins)


# Section pause_battle on the host (a battle running): BattleHost as the provider of a stream of
# its own. Nothing while it runs; a pause flushes the section (no waiting for the interval), a
# peer joining while paused gets it, resuming sends null. Returns the pause as a peer gets it.
func _test_pause_host(together: Node) -> Array:
	var host: Node = together.battle_host
	var pauses := _stream(true, [P1])
	pauses.register_provider(StateStream.PAUSE_BATTLE, host)
	pauses.step(0.0)
	t._check(_take(pauses).empty(), "pause: section inactive while the battle runs")
	# The host's physics frame sees the pause (no frame runs in between: the tree stays paused
	# only for this check).
	host.state_stream = pauses
	_tree().paused = true
	host._physics_process(0.0)
	var flushed: bool = pauses._providers[StateStream.PAUSE_BATTLE].flush_frame >= 0
	t._check(flushed, "pause: the host flushes the section, it goes out the next frame")
	pauses.step(1.0)
	var sent := _take(pauses)
	var body = sent[0][1][2] if sent.size() == 1 else null
	t._check(
		_sections(sent) == [[P1, StateStream.PAUSE_BATTLE]]
		and body is Dictionary and body.battle_id == host._battle_id and body.has("by_id"),
		"pause: sent with battle_id and who paused: %s" % [sent]
	)
	pauses.session.peers[P2] = {"ready": true}
	pauses.session.emit_signal("peer_ready", P2)
	pauses.step(0.0)  # the resync goes out in the stream's next step
	sent = _take(pauses)
	t._check(
		_sections(sent) == [[P2, StateStream.PAUSE_BATTLE]] and sent[0][1][1] == 1,
		"pause: a peer joining while paused learns it (only that peer, same revision)"
	)
	var message: Array = sent[0][1] if sent.size() == 1 else [StateStream.PAUSE_BATTLE, 0, null]
	_tree().paused = false
	host._physics_process(0.0)
	host.state_stream = together.state_stream
	pauses.step(1.0)
	sent = _take(pauses)
	t._check(
		sent.size() == 2 and sent[0][1][2] == null and sent[1][1][2] == null,
		"pause: resuming sends null to every peer"
	)
	_free_stream(pauses)
	return message


# The host's grids (every element in order, with flags and tier) and who selected; the client
# pairs a state with the grids of its screen.
func _test_selection_grid(together: Node):
	var menu_sync: Node = together.menu_sync
	menu_sync.set_process(false)
	var scene := _tree().current_scene
	menu_sync._scene = scene
	var grids: Dictionary = menu_sync.grids_state()
	var inventory = scene.get_node("%Inventory1")
	t._check(
		grids.inventories.size() == 1,
		(
			"grid: one shared character grid (%d, Inventory1 visible: %s)"
			% [grids.inventories.size(), inventory.is_visible_in_tree()]
		)
	)
	if grids.inventories.size() != 1:
		menu_sync.set_process(true)
		yield(_frames(1), "completed")
		return
	var elements := []
	for child in inventory.get_children():
		if child is InventoryElement:
			elements.append(child)
	var entries: Array = grids.inventories[0]
	t._check(entries.size() == elements.size(), "grid: every host element")
	var same := true
	for i in min(entries.size(), elements.size()):
		var element: InventoryElement = elements[i]
		var id: String = element.item.my_id if element.item != null else ""
		var random: bool = entries[i][1] & menu_sync.FLAG_RANDOM != 0
		same = same and entries[i][0] == id and random == element.is_random
		if element.item != null:
			same = same and entries[i][2] == element.item.tier
	t._check(same, "grid: ids, random flag and tier in the host's order")
	t._check(not grids.has("run"), "grid: no run state for the character selection")
	scene._has_player_selected[1] = true
	var state: Dictionary = menu_sync._state()
	t._check(state.selected == [false, true], "state: who selected %s" % [state.selected])
	t._check(
		state.zone == [RunData.current_zone, ProgressData.settings.zone_is_random]
		and state.endless == RunData.is_endless_run,
		"state: zone and endless of the run options"
	)
	state["you"] = 1
	# Client side (the handler of both sections): grids come once, later states reuse them.
	var received := []
	menu_sync.clear_state(StateStream.MENU)
	menu_sync.clear_state(StateStream.MENU_GRIDS)
	menu_sync.connect("menu_state", self, "_on_received", [received])
	menu_sync.apply_state(StateStream.MENU, bytes2var(var2bytes(state), false), 1)
	menu_sync.apply_state(StateStream.MENU_GRIDS, bytes2var(var2bytes(grids), false), 1)
	menu_sync.apply_state(StateStream.MENU, bytes2var(var2bytes(state), false), 2)
	menu_sync.apply_state(StateStream.MENU, {"kind": "x", "screen": "junk"}, 3)
	menu_sync.disconnect("menu_state", self, "_on_received")
	t._check(
		received.size() == 2 and received[1].grids.inventories.size() == 1,
		"grid: client keeps the last grids, junk is ignored"
	)
	scene._has_player_selected[1] = false
	menu_sync.set_process(true)
	yield(_frames(1), "completed")


# Sections menu and menu_grids from a host stream to client streams (MenuSync on both ends):
# the state, then its grids; a selection sends no grids; a peer joining mid-menu gets both;
# a state of another screen waits for that screen's grids; null forgets them.
func _test_menu_sections(together: Node) -> void:
	var menu_sync: Node = together.menu_sync
	var scene := _tree().current_scene
	var host := _stream(true, [P1])
	var one := _stream(false, [])
	var two := _stream(false, [])
	for section in [StateStream.MENU, StateStream.MENU_GRIDS]:
		host.register_provider(section, menu_sync)
		one.register_handler(section, menu_sync)
		two.register_handler(section, menu_sync)
		menu_sync.clear_state(section)
	var received := []
	menu_sync.connect("menu_state", self, "_on_received", [received])
	host.step(0.0)
	var sent := _take(host)
	t._check(
		_sections(sent) == [[P1, StateStream.MENU], [P1, StateStream.MENU_GRIDS]],
		"menu: the state, then its grids: %s" % [_sections(sent)]
	)
	_deliver(one, sent)
	var shown = received[-1] if received.size() == 1 else {}
	t._check(
		shown.get("kind") == "character_selection" and shown.get("you") == -1
		and shown.get("grids", {}).get("screen") == scene.get_instance_id(),
		"menu: the client shows the state with its grids once both arrived"
	)
	# A player selects: the state goes out again, the grids do not. (The cursors are FocusSync's.)
	scene._has_player_selected[0] = true
	host.step(0.1)
	sent = _take(host)
	t._check(_sections(sent) == [[P1, StateStream.MENU]], "menu: a selection sends no grids")
	_deliver(one, sent)
	t._check(
		received.size() == 2 and received[1].grids.get("screen") == scene.get_instance_id(),
		"menu: the new state shown with the grids kept"
	)
	host.session.peers[P2] = {"ready": true}
	host.session.emit_signal("peer_ready", P2)
	host.step(0.0)  # the resync goes out in the stream's next step
	sent = _take(host)
	t._check(
		_sections(sent) == [[P2, StateStream.MENU], [P2, StateStream.MENU_GRIDS]],
		"menu: a peer joining mid-menu gets both sections (only it)"
	)
	# (one MenuSync stands for both clients: it shows on each section, the screens matching)
	received.clear()
	_deliver(two, sent)
	var grids = received[-1].get("grids", {}) if not received.empty() else {}
	t._check(grids.get("screen") == scene.get_instance_id(), "menu: the joining peer's view")
	# Another screen's state does not show with this screen's grids; its own grids show it.
	var next: Dictionary = bytes2var(var2bytes(received[-1]), false)
	next.erase("grids")
	next["screen"] = -1
	received.clear()
	one.receive([StateStream.MENU, 10, next])
	t._check(received.empty(), "menu: a new screen's state waits for its grids")
	one.receive([StateStream.MENU_GRIDS, 10, {"screen": -1, "inventories": []}])
	t._check(
		received.size() == 1 and received[0].screen == -1 and received[0].grids.inventories.empty(),
		"menu: shown with its own grids"
	)
	one.receive([StateStream.MENU, 11, null])
	one.receive([StateStream.MENU_GRIDS, 11, null])
	one.receive([StateStream.MENU_GRIDS, 12, {"screen": -1, "inventories": []}])
	t._check(received.size() == 1, "menu: inactive (battle, shop) forgets the state")
	menu_sync.disconnect("menu_state", self, "_on_received")
	scene._has_player_selected[0] = false
	for stream in [host, one, two]:
		_free_stream(stream)


static func _deliver(stream: Node, messages: Array) -> void:
	for message in messages:
		stream.receive(message[1])


func _on_received(state: Dictionary, received: Array) -> void:
	received.append(state)
