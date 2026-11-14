extends Reference
# Level-up / crate panels that run on the client itself (sync/upgrades_sync.gd): the host only
# applies a decision that matches what the sender's panel shows, a client's own panel takes
# local input and sends intents instead of deciding, and the other panels stay mirrored.
# Called from mod_main.gd's battle loopback (host part while the host battle exists, client
# part on the puppet); checks go through its _check.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const BIT_ACCEPT := 1

var _t: Node = null


# host_panels: player 0 has a level-up, player 1 a crate item (see _test_battle_loopback).
# Runs after the state message for the client was captured, so the host may move on.
func host_part(t: Node, together: Node, ui: Node, host_panels: Array, msg: Dictionary):
	_t = t
	var panels: Node = together.upgrades_sync
	var input_sync: Node = together.input_sync
	var container = ui._get_player_container(0)
	var upgrade_id: String = host_panels[0][1][0]
	t._check(
		msg.seqs.size() == 2 and msg.seqs[0] > 0 and msg.pages == [0, 0],
		"state carries a revision and page per player (%s, %s)" % [msg.seqs, msg.pages]
	)

	# While the panels run on the clients, a remote button never presses the host's copy.
	var saved_devices: Dictionary = input_sync.devices.duplicate()
	input_sync._remote.erase(t.FAKE_PEER)
	input_sync.devices[t.FAKE_PEER] = t.DEVICE
	t._send(input_sync, Vector2.ZERO, Vector2.ZERO, 0)  # first packet: nothing held
	panels._block_remote_buttons(true)
	t._send(input_sync, Vector2.ZERO, Vector2.ZERO, 0)
	t._send(input_sync, Vector2.ZERO, Vector2.ZERO, BIT_ACCEPT)
	yield(t.get_tree(), "idle_frame")
	t._check(
		not Input.is_action_pressed("ui_accept_%s" % t.DEVICE), "remote accept blocked on the host"
	)
	t._send(input_sync, Vector2.ZERO, Vector2.ZERO, 0)
	panels._block_remote_buttons(false)
	t._send(input_sync, Vector2.ZERO, Vector2.ZERO, BIT_ACCEPT)
	yield(t.get_tree(), "idle_frame")
	t._check(Input.is_action_pressed("ui_accept_%s" % t.DEVICE), "remote accept back afterwards")
	t._send(input_sync, Vector2.ZERO, Vector2.ZERO, 0)
	yield(t.get_tree(), "idle_frame")
	input_sync._remote.erase(t.FAKE_PEER)
	input_sync.devices = saved_devices

	# A remote player's own cursor and page, shown on the host.
	var second_button: Control = container._get_upgrade_uis()[1].button
	panels.host_apply_focus(ui, 0, 0, ScenePaths.path_of(second_button, container))
	t._check(container.focus_emulator.focused_control == second_button, "host shows a remote cursor")
	panels.host_apply_focus(ui, 0, 1, PoolIntArray())
	t._check(container.carousel.index == 1, "host shows a remote player's page")
	panels.host_apply_focus(ui, 0, 0, ["junk"])
	t._check(container.carousel.index == 0, "page back, junk path ignored")

	# Decisions: only for what the sender's panel shows right now.
	var intent := {"battle_id": msg.battle_id, "seq": msg.seqs[0], "kind": "choose", "id": upgrade_id}
	var stale := intent.duplicate()
	stale.seq -= 1
	t._check(not panels.host_apply_intent(ui, 0, stale), "stale revision dropped")
	var unknown := intent.duplicate()
	unknown.id = "upgrade_does_not_exist"
	t._check(not panels.host_apply_intent(ui, 0, unknown), "option the panel doesn't show dropped")
	t._check(not panels.host_apply_intent(ui, 1, intent), "another player's panel untouched")
	t._check(panels.capture(ui)[0] == host_panels[0], "rejected intents changed nothing")
	t._check(panels.host_apply_intent(ui, 0, intent), "matching choice applied")
	t._check(panels.capture(ui)[0][0] == "done", "host panel moved on (%s)" % [panels.capture(ui)[0]])
	t._check(not panels.host_apply_intent(ui, 0, intent), "the same press twice applies once")
	var discard := {
		"battle_id": msg.battle_id, "seq": msg.seqs[1], "kind": "discard", "id": host_panels[1][2]
	}
	t._check(panels.host_apply_intent(ui, 1, discard), "crate item discarded by intent")
	t._check(panels.capture(ui)[1][0] != "item", "crate panel moved on")


# The puppet shows msg (player 0: level-up, player 1: crate). This client becomes player 0.
func client_part(t: Node, together: Node, main: Node, msg: Dictionary):
	_t = t
	var panels: Node = together.upgrades_sync
	var client: Node = together.battle_client
	var focus_sync: Node = together.focus_sync
	var input_sync: Node = together.input_sync
	var ui = main.get("_coop_upgrades_ui")
	var own = ui._get_player_container(0)
	var other = ui._get_player_container(1)
	client._you = 0
	panels._guarded_ui = null  # the pending state was applied as a spectator: guard again
	panels.apply(main, msg)
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")

	t._check(panels._local_active, "own panel runs locally")
	t._check(
		input_sync._local_buttons != null and input_sync._local_buttons.device == t.DEVICE,
		"local buttons drive the own slot's device"
	)
	t._check(
		input_sync._local_buttons != null
		and input_sync._local_buttons.blocked == 1 << VirtualDevices.PAUSE_INDEX,
		"pause still goes to the host only"
	)
	var emulator = own.focus_emulator
	t._check(emulator.is_processing_input(), "own cursor takes input on the puppet")
	var uis: Array = own._get_upgrade_uis()
	t._check(
		emulator.focused_control == uis[1].button or emulator.focused_control == uis[0].button,
		"own cursor starts on an upgrade"
	)

	# Decisions leave as intents; nothing is decided or rolled here.
	var upgrades: Array = own._old_upgrades.duplicate()
	own._on_choose_button_pressed(upgrades[0])
	t._check(
		panels.last_intent.get("kind") == "choose" and panels.last_intent.get("id") == upgrades[0].my_id,
		"choosing sends an intent (%s)" % [panels.last_intent]
	)
	t._check(panels.last_intent.get("seq") == msg.seqs[0], "intent names the panel revision")
	t._check(panels.capture(ui)[0] == msg.players[0], "own panel unchanged until the host answers")
	own._reroll_button.emit_signal("pressed")
	t._check(panels.last_intent.get("kind") == "reroll", "reroll sends an intent")
	t._check(own._reroll_count == 0 and own._old_upgrades == upgrades, "no local reroll")
	panels.last_intent = {}
	other._on_DiscardButton_pressed()
	t._check(
		panels.last_intent.empty() and panels.capture(ui)[1][0] == "item",
		"another player's panel decides nothing here"
	)

	# The own page flips locally, with the trigger of the own slot's device.
	for pressed in [true, false]:
		VirtualDevices.press_button("rtrigger_%s" % t.DEVICE, t.DEVICE, pressed)
		yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	t._check(own.carousel.index == 1, "own page flips locally (page %s)" % own.carousel.index)
	panels._sent_focus = ""
	panels._report_own_focus()
	t._check('"page":1' in panels._sent_focus.replace(" ", ""), "own page reported to the host")

	# The host's cursor for the own panel is not applied; the others' pages are mirrored.
	var own_cursor = emulator.focused_control
	focus_sync._scene = main
	var reroll_path := ScenePaths.path_of(own._reroll_button, main)
	focus_sync._apply(
		{"scene": main.filename, "cursors": [[ScenePaths.path_of(emulator, main), 0, reroll_path]]}
	)
	t._check(emulator.focused_control == own_cursor, "host cursor never moves the own cursor")
	var paged := msg.duplicate()
	paged.pages = [0, 2]
	own._level = 99  # marker: an unchanged panel is not rebuilt
	panels.apply(main, paged)
	t._check(other.carousel.index == 2, "another player's page mirrored")
	t._check(own.carousel.index == 1, "own page stays local")
	t._check(own._level == 99, "unchanged panel not rebuilt")

	# Done: local control ends.
	var finished := msg.duplicate(true)
	finished.players[0] = ["done"]
	finished.seqs[0] += 1
	panels.apply(main, finished)
	t._check(
		not panels._local_active and input_sync._local_buttons == null,
		"local control ends when the own panel is done"
	)
	t._check(focus_sync.local_emulators.empty(), "own emulator mirrored again")
	# Back to a spectator, with no prediction state left over for the tests that follow.
	client._you = -1
	client._own_base_t = -1
	client._own_error = Vector2.ZERO
