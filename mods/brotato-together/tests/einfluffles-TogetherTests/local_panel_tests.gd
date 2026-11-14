extends Reference
# Level-up / crate panels that run on the client itself (sync/upgrades_sync.gd): the host only
# applies a decision that matches what the sender's panel shows, a client's own panel takes
# local input and sends intents instead of deciding, and the other panels stay mirrored.
# Called from mod_main.gd's battle loopback (host part while the host battle exists, client
# part on the puppet); checks go through its _check.
# Player 1's crates give weapons (give_crate_weapons), so its crate panel has the weapons list
# whose popup combines / recycles / meca-upgrades: those are intents too.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const MECA_DLC := "primal_dread"
const PISTOL := "weapon_pistol_1"
const BIT_ACCEPT := 1

var _t: Node = null


# Before the host's battle scene loads (UpgradesUI reads the effect in _ready): player p's
# crates give weapons, and it owns three pistols (two combine, one is left to recycle).
func give_crate_weapons(t: Node, p: int) -> void:
	RunData.get_player_effects(p)[Keys.effect_crate_give_weapon_hash] = 1
	for _i in 3:
		RunData.add_weapon(t._find_by_id(ItemService.weapons, PISTOL), p)


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

	_host_weapons(t, panels, ui, msg.battle_id)

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
		"battle_id": msg.battle_id, "seq": panels._seqs[1], "kind": "discard", "id": host_panels[1][2]
	}
	t._check(panels.host_apply_intent(ui, 1, discard), "crate item discarded by intent")
	t._check(panels.capture(ui)[1][0] != "item", "crate panel moved on")


# Crate weapon popup intents (player 1, whose crate panel shows an item): the host applies
# them to the weapon the intent names, by the game's own rules.
func _host_weapons(t: Node, panels: Node, ui: Node, battle_id: int) -> void:
	var list = ui._get_player_container(1).crate_weapons_container
	t._check(
		ui._weapons_inventory_enabled[1] and not ui._weapons_inventory_enabled[0],
		"weapons list only for the player whose crates give weapons"
	)
	t._check(list.get_element_count() == 3, "host lists its weapons (%d)" % list.get_element_count())
	var seq: int = panels._seqs[1]
	var gold: int = RunData.get_player_gold(1)
	var combine := {
		"battle_id": battle_id, "seq": seq, "kind": "weapon_combine", "id": PISTOL, "weapon": 0
	}
	var stale := combine.duplicate()
	stale.seq -= 1
	t._check(not panels.host_apply_intent(ui, 1, stale), "weapon intent: stale revision dropped")
	var other_id := combine.duplicate()
	other_id.id = "weapon_smg_1"
	t._check(not panels.host_apply_intent(ui, 1, other_id), "weapon intent: wrong id dropped")
	for slot in [3, -1, "0", null]:
		var other_slot := combine.duplicate()
		other_slot.weapon = slot
		t._check(
			not panels.host_apply_intent(ui, 1, other_slot), "weapon intent: slot %s dropped" % [slot]
		)
	# Player 0 owns a pistol too, but its crates don't give weapons: no popup actions for it.
	var not_enabled := combine.duplicate()
	not_enabled.seq = panels._seqs[0]
	not_enabled.kind = "weapon_discard"
	t._check(not panels.host_apply_intent(ui, 0, not_enabled), "weapon intent: feature off dropped")
	t._check(
		_weapon_ids(0) == [PISTOL] and _weapon_ids(1) == [PISTOL, PISTOL, PISTOL],
		"rejected weapon intents changed nothing (%s)" % [_weapon_ids(1)]
	)
	t._check(panels._seqs[1] == seq and RunData.get_player_gold(1) == gold, "nor revision or gold")

	t._check(panels.host_apply_intent(ui, 1, combine), "combine applied")
	t._check(
		_weapon_ids(1) == [PISTOL, "weapon_pistol_2"], "two pistols combined (%s)" % [_weapon_ids(1)]
	)
	t._check(panels._seqs[1] == seq + 1, "weapons changed: new panel revision")
	t._check(list.get_element_count() == 2, "host list follows")
	t._check(not panels.host_apply_intent(ui, 1, combine), "the same combine twice applies once")
	t._check(_weapon_ids(1).size() == 2, "double press changed nothing")
	var alone := combine.duplicate()
	alone.seq = panels._seqs[1]
	t._check(not panels.host_apply_intent(ui, 1, alone), "combine without a partner: game says no")
	t._check(panels._seqs[1] == seq + 1, "revision unchanged by a refused action")

	var recycle := {
		"battle_id": battle_id, "seq": seq + 1, "kind": "weapon_discard", "id": PISTOL, "weapon": 0
	}
	t._check(panels.host_apply_intent(ui, 1, recycle), "recycle applied")
	t._check(_weapon_ids(1) == ["weapon_pistol_2"], "pistol recycled (%s)" % [_weapon_ids(1)])
	t._check(RunData.get_player_gold(1) > gold, "recycling paid out")
	t._check(panels._seqs[1] == seq + 2 and list.get_element_count() == 1, "revision and list follow")
	t._check(panels.capture(ui)[1][0] == "item", "the crate item is still on offer")
	_host_meca(t, panels, ui, battle_id)


# Meca upgrade (primal_dread): the client names the stat, the host builds the upgrade.
# Headless the game owns no DLC, so it is switched on for these checks only (the upgrade
# itself needs none of the DLC content), and the meca weapon is gone again afterwards.
func _host_meca(t: Node, panels: Node, ui: Node, battle_id: int) -> void:
	var dlc = ItemService.get_dlc_data_by_id(MECA_DLC)
	if dlc == null:
		print("  info: no %s data, meca upgrade intent not tested" % MECA_DLC)
		return
	var weapon = RunData.get_player_weapons(1)[0]
	var cost: int = dlc.get_meca_upgrade_cost(weapon)
	var stat: int = dlc._get_allowed_meca_stats(1).values()[0][0]
	var meca := {
		"battle_id": battle_id,
		"seq": panels._seqs[1],
		"kind": "weapon_meca",
		"id": weapon.my_id,
		"weapon": 0,
		"stat": stat,
	}
	RunData.players_data[1].meca_parts = cost + 1
	var was_active: bool = MECA_DLC in ProgressData.active_update_data
	if not was_active:
		t._check(not panels.host_apply_intent(ui, 1, meca), "meca upgrade without the DLC dropped")
		ProgressData.active_update_data.push_back(MECA_DLC)
	RunData.players_data[1].meca_parts = 0
	t._check(not panels.host_apply_intent(ui, 1, meca), "meca upgrade without parts dropped")
	RunData.players_data[1].meca_parts = cost + 1
	var junk := meca.duplicate()
	junk.stat = 12345
	t._check(not panels.host_apply_intent(ui, 1, junk), "meca upgrade with an unknown stat dropped")
	t._check(_weapon_ids(1) == [weapon.my_id] and not weapon.is_meca, "nothing upgraded so far")
	t._check(panels.host_apply_intent(ui, 1, meca), "meca upgrade applied")
	var upgraded = RunData.get_player_weapons(1)[0]
	var has_stat := false
	for effect in upgraded.effects:
		has_stat = has_stat or effect.key_hash == stat
	t._check(upgraded != weapon and upgraded.is_meca and has_stat, "weapon is meca with the stat")
	t._check(RunData.get_player_meca_parts(1) == 1, "meca parts paid")
	t._check(not panels.host_apply_intent(ui, 1, meca), "the same upgrade twice applies once")
	if not was_active:
		ProgressData.active_update_data.erase(MECA_DLC)
	RunData.players_data[1].meca_parts = 0
	t._check(RunData.remove_weapon_by_index(0, 1) >= 0, "meca weapon removed again")


static func _weapon_ids(p: int) -> Array:
	var ids := []
	for weapon in RunData.get_player_weapons(p):
		ids.append(weapon.my_id)
	return ids


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
	yield(_client_weapons(t, together, main, msg), "completed")


# This client as player 1: its crate panel lists its weapons, and the popup's actions leave
# as intents. msg is the host's state from before it applied any (three pistols).
func _client_weapons(t: Node, together: Node, main: Node, msg: Dictionary):
	var panels: Node = together.upgrades_sync
	var client: Node = together.battle_client
	var ui = main.get("_coop_upgrades_ui")
	var own = ui._get_player_container(1)
	var list = own.crate_weapons_container
	var popup = own.item_popup
	t._check(
		(
			list.get_element_count() == 3
			and ui._get_player_container(0).crate_weapons_container.get_element_count() == 0
		),
		"a mirrored panel lists the weapons (%d)" % list.get_element_count()
	)
	client._you = 1
	panels._guarded_ui = null
	own.carousel.index = 0  # mirrored to another page while this client was player 0
	panels.apply(main, msg)
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	t._check(panels._local_active and list.get_element_count() == 3, "own crate panel lists them")
	var connected := false
	for signal_name in panels.WEAPON_POPUP_HANDLERS:
		var handler: String = panels.WEAPON_POPUP_HANDLERS[signal_name]
		for p in 2:
			var any_popup = ui._get_player_container(p).item_popup
			connected = connected or any_popup.is_connected(signal_name, ui, handler)
	t._check(not connected, "no popup keeps the game's weapon handlers on a client")

	var weapons: Array = RunData.get_player_weapons(1)
	var gold: int = RunData.get_player_gold(1)
	popup.emit_signal("item_combine_button_pressed", weapons[1])
	var sent: Dictionary = panels.last_intent
	t._check(
		sent.get("kind") == "weapon_combine" and sent.get("weapon") == 1 and sent.get("id") == PISTOL,
		"combine sends an intent (%s)" % [sent]
	)
	t._check(sent.get("seq") == msg.seqs[1], "weapon intent names the panel revision")
	popup.emit_signal("item_discard_button_pressed", weapons[2])
	sent = panels.last_intent
	t._check(
		sent.get("kind") == "weapon_discard" and sent.get("weapon") == 2, "recycle sends an intent"
	)
	# Meca upgrade: the stat comes from the options the popup showed, by the button pressed.
	panels._meca_stats = [111, 222]
	popup.emit_signal("item_meca_upgrade_selected", weapons[0], weapons[0])
	t._check(panels.last_intent.get("kind") == "weapon_discard", "no meca intent before the choice")
	panels._on_own_meca_choice(1)
	sent = panels.last_intent
	t._check(
		sent.get("kind") == "weapon_meca" and sent.get("weapon") == 0 and sent.get("stat") == 222,
		"meca upgrade sends the stat picked (%s)" % [sent]
	)
	t._check(
		RunData.get_player_weapons(1) == weapons and RunData.get_player_gold(1) == gold,
		"weapon intents change nothing locally"
	)
	panels.last_intent = {}
	popup.emit_signal("item_combine_button_pressed", weapons[0].duplicate())
	t._check(panels.last_intent.empty(), "a weapon the player doesn't own sends nothing")
	var other_popup = ui._get_player_container(0).item_popup
	other_popup.emit_signal("item_discard_button_pressed", RunData.get_player_weapons(0)[0])
	t._check(
		panels.last_intent.empty() and RunData.get_player_weapons(0).size() == 1,
		"another player's popup decides nothing here"
	)

	# The host's answer (a recycled pistol): the list follows and the cursor keeps its slot.
	own.focus_emulator.focused_control = list.get_element(2)
	RunData.players_data[1].weapons.remove(2)
	var answer: Dictionary = msg.duplicate(true)
	answer.run = bytes2var(var2bytes(RunStateCodec.encode()), false)
	answer.seqs[1] += 1
	panels.apply(main, answer)
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	t._check(list.get_element_count() == 2, "own list follows the host's answer")
	t._check(
		own.focus_emulator.focused_control == list.get_element(1),
		"own cursor stays in the weapons list"
	)
	t._check(panels._own_seq == answer.seqs[1], "next intent names the new revision")
	answer = answer.duplicate(true)
	answer.players[1] = ["done"]
	answer.seqs[1] += 1
	panels.apply(main, answer)
	t._check(not panels._local_active, "local control ends when the crate panel is done")
	# Back to a spectator, with no prediction state left over for the tests that follow.
	client._you = -1
	client._own_base_t = -1
	client._own_error = Vector2.ZERO
