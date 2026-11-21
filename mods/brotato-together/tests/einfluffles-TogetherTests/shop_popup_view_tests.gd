extends Reference
# Every player's open item popup on every machine (sync/popup_view.gd): a remote player's popup
# and its meca upgrade choice on the host's copy, and from the host's state on a client's copy
# of another player's panel. Part of the local shop suite (local_shop_tests.gd; s: that suite).

const PopupView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/popup_view.gd")
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const FocusSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/focus_sync.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const MECA_DLC := "primal_dread"
const REMOTE := 1

var _view := []  # the remote player's popup open on its first weapon, as its client reports it
var _meca_view := []
var _roll := []  # the host's meca roll for that weapon (MecaChoice entry)


# After the weapon intents: the remote player has one weapon.
func host(s):
	yield(s._frames(1), "completed")
	var t: Node = s._t
	var shop: Node = s._shop
	var shop_sync: Node = s._sync
	var popup = shop._get_item_popup(REMOTE)
	var panel = shop._get_coop_player_container(REMOTE)
	var emulator = Utils.get_focus_emulator(REMOTE, shop)
	# _meca.host replaced the weapon in RunData only
	var gear = shop._get_gear_container(REMOTE)
	gear.set_weapons_data(RunData.get_player_weapons(REMOTE))
	yield(s._frames(1), "completed")
	var element = gear.weapons_container._elements.get_child(0)
	var weapon = element.item
	_view = [FocusTargets.describe(element, shop, REMOTE), weapon.my_id, 0, [null, null]]
	var cancel := FocusTargets.describe(popup._cancel_button, shop, REMOTE)
	t._check(_describe(shop, REMOTE).empty(), "host: nothing open on the remote panel")
	shop_sync.host_apply_focus(shop, REMOTE, 0, cancel, _wire(_view))
	t._check(
		(
			popup._focused
			and popup._item_data == weapon
			and shop._popup_manager._elements_pressed[REMOTE] == element
			and panel._popup_dim_screen.visible
		),
		"host: a remote player's open popup opens on its copy, on that weapon, panel dimmed"
	)
	t._check(emulator.focused_control == popup._cancel_button, "and the cursor goes into it")
	var body: Dictionary = shop_sync.state_body(StateStream.RUN_SHOP)
	t._check(
		var2str(body.popups[REMOTE]) == var2str(_view) and body.popups[0].empty(),
		"the shop state carries it for the other clients (%s)" % [body.popups]
	)
	s._capture("popup_open")

	# The game closes it on the host (a gear rebuild): opened again while the client has it.
	shop._popup_manager.reset_focus(REMOTE)
	panel.on_hide_focused_inventory_popup()
	shop_sync._keep_reported_popups()
	t._check(
		popup._focused and emulator.focused_control == popup._cancel_button,
		"host: a copy the game closed opens again, cursor where the client has it"
	)
	t._check(s._apply("go", -1, "", 1, -9), "an intent of that player")
	shop._popup_manager.reset_focus(REMOTE)
	panel.on_hide_focused_inventory_popup()
	shop_sync._keep_reported_popups()
	t._check(not popup._focused, "after its intent the copy stays as the game leaves it")
	s._apply("go", -1, "", 0)

	var wrong := _view.duplicate(true)
	wrong[1] = "weapon_does_not_exist"
	shop_sync.host_apply_focus(shop, REMOTE, 0, cancel, _wire(wrong))
	t._check(not popup._focused, "a popup on another weapon than the element shows does not open")
	shop_sync.host_apply_focus(shop, REMOTE, 0, cancel, _wire(_view))
	shop_sync.host_apply_focus(shop, REMOTE, 0, [], ["junk"])
	t._check(
		not popup._focused and not panel._popup_dim_screen.visible,
		"a malformed report counts as nothing open: the copy closes"
	)
	yield(_host_meca(s, element, cancel), "completed")
	_host_stray(s, element, cancel)
	_host_left(s, cancel)
	_capture_gear(s)


# A copy left dimmed with no popup open (the game hid the popup but not the dim screen) is
# cleared by a report that has nothing open.
func _host_stray(s, element: Control, cancel: Array) -> void:
	var shop: Node = s._shop
	var shop_sync: Node = s._sync
	var popup = shop._get_item_popup(REMOTE)
	var panel = shop._get_coop_player_container(REMOTE)
	shop_sync.host_apply_focus(shop, REMOTE, 0, cancel, _wire(_view))
	popup.hide()
	var target := FocusTargets.describe(element, shop, REMOTE)
	shop_sync.host_apply_focus(shop, REMOTE, 0, target, [])
	s._t._check(
		not popup._focused and not panel._popup_dim_screen.visible,
		"host: a copy left dimmed without its popup is cleared by the next report"
	)


# A client that leaves with its popup open keeps nothing open on the host's copy.
func _host_left(s, cancel: Array) -> void:
	var shop: Node = s._shop
	var shop_sync: Node = s._sync
	var popup = shop._get_item_popup(REMOTE)
	var panel = shop._get_coop_player_container(REMOTE)
	shop_sync.host_apply_focus(shop, REMOTE, 0, cancel, _wire(_view), s._t.FAKE_PEER)
	s._t._check(popup._focused, "(the remote popup is open on the host's copy)")
	shop_sync._on_peer_removed(s._t.FAKE_PEER)
	shop_sync._keep_reported_popups()
	s._t._check(
		(
			not popup._focused
			and not panel._popup_dim_screen.visible
			and not shop_sync._reported_popups.has(REMOTE)
		),
		"host: a client that leaves takes its open popup off the host's copy"
	)


# The remote player with its weapon, with another one, and with none (client gear checks).
func _capture_gear(s) -> void:
	var weapons: Array = RunData.players_data[REMOTE].weapons
	var kept: Array = weapons.duplicate()
	s._capture("remote_armed")
	weapons.clear()
	RunData.add_weapon(s._t._find_by_id(ItemService.weapons, "weapon_smg_1"), REMOTE)
	s._capture("remote_rearmed")
	weapons.clear()
	s._capture("remote_unarmed")
	weapons.clear()
	weapons.append_array(kept)


# The meca choice shows the roll the host's copy keeps, and never makes one.
func _host_meca(s, element: Control, cancel: Array):
	yield(s._frames(1), "completed")
	var t: Node = s._t
	var shop: Node = s._shop
	var shop_sync: Node = s._sync
	var popup = shop._get_item_popup(REMOTE)
	var weapon = element.item
	var dlc = MecaChoice.dlc_data()
	if dlc == null:
		print("  info: no %s data, meca choice on a copy not tested" % MECA_DLC)
		return
	var was_active: bool = MECA_DLC in ProgressData.active_update_data
	if not was_active:
		ProgressData.active_update_data.push_back(MECA_DLC)
	var parts: int = RunData.get_player_meca_parts(REMOTE)
	RunData.players_data[REMOTE].meca_parts = dlc.get_meca_upgrade_cost(weapon)
	_meca_view = _view.duplicate(true)
	_meca_view[2] = 1
	shop_sync.host_apply_focus(shop, REMOTE, 0, cancel, _wire(_meca_view))
	t._check(
		(
			popup._focused
			and not popup.is_choosing_meca_upgrade()
			and MecaChoice.entries(popup, REMOTE).empty()
		),
		"host: a meca choice without a roll of the host's opens the popup and rolls nothing"
	)
	if not s._apply("meca_roll", 0, weapon.my_id):
		print("  info: %s cannot be mechanized, meca choice on a copy not tested" % weapon.my_id)
	else:
		var rolls: Array = MecaChoice.entries(popup, REMOTE)
		_roll = rolls[0] if rolls.size() == 1 else []
		var effect := FocusTargets.describe(popup._effect_button_0, shop, REMOTE)
		shop_sync.host_apply_focus(shop, REMOTE, 0, effect, _wire(_meca_view))
		t._check(
			(
				popup.is_choosing_meca_upgrade()
				and _shown(popup) == [[_roll[2], _roll[3]], [_roll[4], _roll[5]]]
				and MecaChoice.entries(popup, REMOTE) == rolls
			),
			"host: once rolled, the copy shows the client's choice with the host's roll"
		)
		var emulator = Utils.get_focus_emulator(REMOTE, shop)
		t._check(emulator.focused_control == popup._effect_button_0, "cursor on the first option")
		t._check(
			shop_sync.state_body(StateStream.RUN_SHOP).popups[REMOTE][2] == 1,
			"the shop state says the choice is open"
		)
		s._capture("popup_meca")
		shop_sync.host_apply_focus(shop, REMOTE, 0, cancel, _wire(_view))
		t._check(
			popup._focused and not popup.is_choosing_meca_upgrade(),
			"host: back to the popup's buttons"
		)
	shop_sync.host_apply_focus(shop, REMOTE, 0, FocusTargets.describe(element, shop, REMOTE), [])
	t._check(not popup._focused, "host: the copy closes with the client's popup")
	popup._upgrade_preview_cache.clear()
	RunData.players_data[REMOTE].meca_parts = parts
	if not was_active:
		ProgressData.active_update_data.erase(MECA_DLC)
	yield(s._frames(1), "completed")


# At the end of the client part: this client is player 0, the remote player is another one.
func client(s, shop: Node, focus_sync: Node):
	yield(s._frames(1), "completed")
	var t: Node = s._t
	if not s._states.has("popup_open"):
		return
	var popup = shop._get_item_popup(REMOTE)
	var own = shop._get_item_popup(0)
	var emulator = Utils.get_focus_emulator(REMOTE, shop)
	# The host's cursor already went to Recycle: a target hidden here until the popup opens.
	var cursors := {
		"scene": shop.filename,
		"cursors": [FocusSync.cursor_of(emulator, popup._discard_button, shop)],
	}
	focus_sync.apply_state(StateStream.CURSORS, cursors, 0)
	s._receive(s._states.popup_open)
	var element = shop._popup_manager._elements_pressed[REMOTE]
	t._check(
		(
			popup._focused
			and popup._item_data != null
			and popup._item_data.my_id == _view[1]
			and element != null
			and element.get_index() == 0
			and shop._get_coop_player_container(REMOTE)._popup_dim_screen.visible
		),
		"client: another player's open popup opens on its panel here"
	)
	t._check(not own._focused, "the own popup stays as it is")
	t._check(
		emulator.focused_control == popup._discard_button,
		"that player's cursor goes back where the host has it, into the popup"
	)
	yield(_client_meca(s, shop), "completed")

	var body: Dictionary = s._states.popup_open.duplicate(true)
	var own_element = shop._get_gear_container(0).weapons_container._elements.get_child(0)
	var own_target := FocusTargets.describe(own_element, shop, 0)
	body.popups[0] = [own_target, own_element.item.my_id, 0, [null, null]]
	s._receive(body)
	t._check(not own._focused, "the host's view of the own panel is never applied")

	Utils.get_focus_emulator(0, shop).focused_control = own_element
	FocusEmulatorSignal.emit(own_element, "pressed", 0)  # what accept there does
	var local = s._sync.local
	local._sent_focus = ""
	local.process()
	var reported := _describe(shop, 0)
	t._check(
		own._focused and not reported.empty() and var2str(reported) in local._sent_focus,
		"the own open popup goes to the host with the cursor (%s)" % [reported]
	)
	own.emit_signal("item_cancel_button_pressed", own._item_data)
	var reroll = shop._get_reroll_button(REMOTE)
	cursors.cursors = [FocusSync.cursor_of(emulator, reroll, shop)]
	focus_sync.apply_state(StateStream.CURSORS, cursors, 0)
	s._receive(s._states.own_gear_changed)
	t._check(not popup._focused, "client: the copy closes with the host's state")
	yield(s._frames(2), "completed")
	t._check(
		emulator.focused_control == reroll,
		"and that player's cursor stays where the host has it (%s)" % [emulator.focused_control]
	)
	yield(_client_gear(s, shop), "completed")


# Another player's gear changes under its cursor on this client's copy.
func _client_gear(s, shop: Node):
	yield(s._frames(1), "completed")
	if not s._states.has("remote_armed"):
		return
	var t: Node = s._t
	var popup = shop._get_item_popup(REMOTE)
	var emulator = Utils.get_focus_emulator(REMOTE, shop)
	var row: Node = shop._get_gear_container(REMOTE).weapons_container._elements
	s._receive(s._states.remote_armed)
	emulator.focused_control = row.get_child(0)
	t._check(popup.visible and popup._item_data == row.get_child(0).item, "(its weapon's details)")
	s._receive(s._states.remote_rearmed)
	var cursor = emulator.focused_control
	t._check(
		(
			is_instance_valid(cursor)
			and not cursor.is_queued_for_deletion()
			and popup.visible
			and popup._item_data == cursor.item
			and cursor.item.my_id == "weapon_smg_1"
		),
		"client: another weapon at the cursor's place shows its own details"
	)
	s._receive(s._states.remote_unarmed)
	cursor = emulator.focused_control
	t._check(
		cursor == null or (is_instance_valid(cursor) and not cursor.is_queued_for_deletion()),
		"client: with the gear empty the cursor leaves the freed weapon (%s)" % [cursor]
	)
	s._receive(s._states.remote_armed)
	yield(s._frames(1), "completed")


func _client_meca(s, shop: Node):
	yield(s._frames(1), "completed")
	var t: Node = s._t
	var popup = shop._get_item_popup(REMOTE)
	if not s._states.has("popup_meca"):
		return
	s._receive(s._states.popup_meca)
	# The run state brought the host's DLC list as it was when the shop opened.
	var was_active: bool = MECA_DLC in ProgressData.active_update_data
	if not was_active:
		ProgressData.active_update_data.push_back(MECA_DLC)
	s._sync._popup_memo.clear()
	s._receive(s._states.popup_meca)
	t._check(
		(
			popup.is_choosing_meca_upgrade()
			and _shown(popup) == [[_roll[2], _roll[3]], [_roll[4], _roll[5]]]
		),
		"client: another player's meca choice shows the host's two options (%s)" % [_shown(popup)]
	)
	s._receive(s._states.popup_open)
	t._check(
		popup._focused and not popup.is_choosing_meca_upgrade(),
		"client: and goes back to the buttons with it"
	)
	if not was_active:
		ProgressData.active_update_data.erase(MECA_DLC)
	yield(s._frames(1), "completed")


static func _describe(shop: Node, p: int) -> Array:
	var popup = shop._get_item_popup(p)
	var panel = shop._get_coop_player_container(p)
	return PopupView.describe(shop, shop._popup_manager, popup, panel, p)


static func _shown(popup: Node) -> Array:
	var shown := []
	if popup._pending_upgrade != null:
		for option in MecaChoice.options(popup._pending_upgrade):
			shown.append([option.key_hash, option.value])
	return shown


static func _wire(value):
	return bytes2var(var2bytes(value), false)
