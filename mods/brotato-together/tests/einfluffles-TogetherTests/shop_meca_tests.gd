extends Reference
# The shop item popup's meca upgrade (sync/meca_choice.gd), host and client side. Part of the
# local shop suite (local_shop_tests.gd; s: that suite).

const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const MECA_DLC := "primal_dread"
const REMOTE := 1


# primal_dread is switched on for these checks. The host rolls the two options into its copy of
# the player's popup and sends them with the state; a pick by index applies exactly that roll.
func host(s):
	yield(s._frames(1), "completed")
	var dlc = ItemService.get_dlc_data_by_id(MECA_DLC)
	if dlc == null:
		print("  info: no %s data, shop meca upgrade not tested" % MECA_DLC)
		return
	var weapon = RunData.get_player_weapons(REMOTE)[0]
	var id: String = weapon.my_id
	var cost: int = dlc.get_meca_upgrade_cost(weapon)
	var was_active: bool = MECA_DLC in ProgressData.active_update_data
	RunData.players_data[REMOTE].meca_parts = cost
	if not was_active:
		s._t._check(not s._apply("meca_roll", 0, id), "shop meca roll without the DLC dropped")
		ProgressData.active_update_data.push_back(MECA_DLC)
	RunData.players_data[REMOTE].meca_parts = 0
	s._t._check(not s._apply("meca_roll", 0, id), "shop meca roll without parts dropped")
	RunData.players_data[REMOTE].meca_parts = cost
	s._t._check(not s._apply("meca_roll", 0, id, -1, -1), "shop meca roll: stale revision dropped")
	s._t._check(not s._apply("meca", 0, id, 0), "shop meca pick without a roll dropped")
	var seq: int = s._seq()
	s._t._check(s._apply("meca_roll", 0, id), "shop meca roll applied")
	var rolls: Array = s._sync._shop_parts().mecas[REMOTE]
	var entry: Array = rolls[0] if rolls.size() == 1 else [0, "", 0, 0, 0, 0]
	s._t._check(
		rolls.size() == 1 and entry[0] == 0 and entry[1] == id and entry[2] != entry[4],
		"the host remembers two options for that weapon (%s)" % [rolls]
	)
	var body: Dictionary = s._sync.state_body(StateStream.RUN_SHOP)
	s._t._check(body.mecas[REMOTE] == rolls, "and sends them with the shop state")
	s._t._check(s._seq() == seq, "a roll leaves the revision alone")
	s._t._check(s._apply("meca_roll", 7, id), "asking again (found by identity)")
	s._t._check(s._sync._shop_parts().mecas[REMOTE] == rolls, "the same roll: no reroll by asking")
	for index in [2, -1]:
		s._t._check(not s._apply("meca", 0, id, index), "shop meca pick %d dropped" % index)
	s._t._check(not s._apply("meca", 0, "weapon_smg_1", 0), "shop meca pick: another weapon dropped")
	s._t._check(not s._apply("meca", 0, id, 0, -1), "shop meca pick: stale revision dropped")
	s._t._check(
		(
			s._weapon_ids(REMOTE) == [id]
			and not weapon.is_meca
			and RunData.get_player_meca_parts(REMOTE) == cost
		),
		"nothing upgraded or paid so far"
	)
	s._t._check(s._apply("meca", 0, id, 0), "shop meca pick applied")
	yield(s._frames(1), "completed")
	var upgraded = RunData.get_player_weapons(REMOTE)[0]
	var picked_value := 0
	for effect in upgraded.effects:
		if effect.key_hash == entry[2] and not effect is EffectOption:
			picked_value = effect.value
	s._t._check(
		upgraded != weapon and upgraded.is_meca and picked_value == entry[3],
		"the weapon got the first option the host rolled (%s)" % [picked_value]
	)
	s._t._check(RunData.get_player_meca_parts(REMOTE) == 0, "meca parts paid on the host")
	s._t._check(s._sync._shop_parts().mecas[REMOTE].empty(), "the roll is forgotten once picked")
	s._t._check(not s._apply("meca", 0, id, 0), "a pick without a remembered roll dropped")
	# The later checks expect plain pistols: the upgraded one goes, a plain one comes back.
	RunData.remove_weapon_by_index(0, REMOTE)
	RunData.add_weapon(s._t._find_by_id(ItemService.weapons, "weapon_pistol_2"), REMOTE)
	if not was_active:
		ProgressData.active_update_data.erase(MECA_DLC)


func client(s, shop: Node, emulator: Node, before: String):
	var local = s._sync.local
	yield(s._frames(1), "completed")
	if ItemService.get_dlc_data_by_id(MECA_DLC) == null:
		print("  info: no %s data, client shop meca upgrade not tested" % MECA_DLC)
		return
	var was_active: bool = MECA_DLC in ProgressData.active_update_data
	if not was_active:
		ProgressData.active_update_data.push_back(MECA_DLC)
	var parts: int = RunData.get_player_meca_parts(0)
	RunData.players_data[0].meca_parts = 5
	var popup = shop._get_item_popup(0)
	var element = shop._get_gear_container(0).weapons_container._elements.get_child(0)
	shop._popup_manager._on_element_pressed(element)  # what a press on a gear weapon does
	var weapon = popup._item_data
	var slot: int = RunData.get_player_weapons(0).find(weapon)
	var id: String = weapon.my_id if weapon != null else ""
	s._t._check(
		popup._focused and slot >= 0 and popup._upgrade_button.visible,
		"the own shop popup offers the meca upgrade"
	)
	local.last_intent = {}
	FocusEmulatorSignal.emit(popup._upgrade_button, "pressed", 0)
	var sent: Dictionary = local.last_intent
	s._t._check(
		sent.get("kind") == "meca_roll" and sent.get("slot") == slot and sent.get("id") == id,
		"the shop's upgrade button asks the host (%s)" % [sent]
	)
	s._t._check(popup._focused and not popup.is_choosing_meca_upgrade(), "nothing rolled here")
	var damage: int = Keys.stat_damage_hash
	var armor: int = Keys.stat_armor_hash
	local.on_mecas([[slot, id, damage, 7, armor, 3], [slot, id, 12345, 1, armor, 1]])
	var shown := []
	if popup._pending_upgrade != null:
		for option in MecaChoice.options(popup._pending_upgrade):
			shown.append([option.key_hash, option.value])
	s._t._check(
		shown == [[damage, 7], [armor, 3]] and local.meca.rolls.size() == 1,
		"the shop popup shows the host's two options, a malformed roll is ignored (%s)" % [shown]
	)
	local.last_intent = {}
	s._t._check(
		emulator.focused_control == popup._effect_button_0, "the own cursor is on the first option"
	)
	FocusEmulatorSignal.emit(popup._effect_button_0, "pressed", 0)  # what accept there does
	sent = local.last_intent
	s._t._check(
		sent.get("kind") == "meca" and sent.get("arg") == 0 and sent.get("slot") == slot,
		"the shop pick leaves as the option's index (%s)" % [sent]
	)
	s._t._check(not popup._focused and not popup.is_choosing_meca_upgrade(), "the shop popup closed")
	s._t._check(
		s._run_view(shop) == before and RunData.get_player_meca_parts(0) == 5,
		"nothing upgraded or paid in the client's shop"
	)
	if not was_active:
		ProgressData.active_update_data.erase(MECA_DLC)
	RunData.players_data[0].meca_parts = parts
