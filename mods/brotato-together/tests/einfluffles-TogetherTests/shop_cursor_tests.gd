extends Reference
# A remote player's cursor on the host's copy of its panel after its recycle / combine
# (ShopSync._settle_host_cursor). The client reports its cursor only when it moves and keeps its
# place after a recycle; the game's handler on the host moves its copy to the row's first weapon.

const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const REMOTE := 1


func host(s):
	var t: Node = s._t
	var shop: Node = s._shop
	var emulator = Utils.get_focus_emulator(REMOTE, shop)
	var kept: Array = RunData.players_data[REMOTE].weapons.duplicate()
	var inventory: Node = yield(_fill(s, [_tier0(3), []]), "completed")
	var element: Control = inventory.get_child(1)
	var next: Control = inventory.get_child(2)
	var target := FocusTargets.describe(element, shop, REMOTE)
	yield(_press(s, "discard", element, target), "completed")
	t._check(
		emulator.focused_control == next,
		"host: after a remote recycle the cursor is where its client has it (client %s, host %s)"
		% [_name(next), _name(emulator.focused_control)]
	)

	inventory = yield(_fill(s, [_tier0(2), ["weapon_pistol_1"]]), "completed")
	var pistol: Control = null
	for child in inventory.get_children():
		if pistol == null and child.item.my_id == "weapon_pistol_1":
			pistol = child
	target = FocusTargets.describe(pistol, shop, REMOTE)
	yield(_press(s, "combine", pistol, target), "completed")
	var shown = FocusTargets.resolve(target, shop, REMOTE)
	t._check(
		shown != null and emulator.focused_control == shown,
		"host: after a remote combine the cursor is where its client has it (client %s, host %s)"
		% [_name(shown), _name(emulator.focused_control)]
	)

	inventory = yield(_fill(s, [_tier0(3), []]), "completed")
	var drops: int = emulator.freed_drops
	var last: Control = inventory.get_child(2)
	yield(_press(s, "discard", last, FocusTargets.describe(last, shop, REMOTE)), "completed")
	var control = emulator.focused_control
	var kept_place: bool = is_instance_valid(control) and inventory.is_a_parent_of(control)
	t._check(
		kept_place and emulator.freed_drops == drops,
		"host: a reported cursor on the recycled last weapon leaves the game's place"
	)
	emulator.focused_control = null
	RunData.players_data[REMOTE].weapons = kept
	shop._get_gear_container(REMOTE).set_weapons_data(kept)
	yield(s._frames(1), "completed")


# The client's cursor on element (reported), its decision, and in the same frame the report of
# its cursor back on the weapon (BaseShop._on_item_cancel_button_pressed on the client).
func _press(s, kind: String, element: Control, target: Array):
	var shop: Node = s._shop
	s._sync.host_apply_focus(shop, REMOTE, 0, target)
	var weapon = element.item
	var slot: int = RunData.get_player_weapons(REMOTE).find(weapon)
	s._t._check(s._apply(kind, slot, weapon.my_id), "host applies the remote %s" % kind)
	s._sync.host_apply_focus(shop, REMOTE, 0, target)
	yield(s._frames(2), "completed")


# The remote player's weapons: lists of weapons and of ids (twice each), shown in its row.
func _fill(s, parts: Array):
	Utils.get_focus_emulator(REMOTE, s._shop).focused_control = null  # off the elements freed here
	RunData.players_data[REMOTE].weapons.clear()
	for weapon in parts[0]:
		RunData.add_weapon(weapon, REMOTE)
	for id in parts[1]:
		var weapon = s._t._find_by_id(ItemService.weapons, id)
		for _i in 2:
			RunData.add_weapon(weapon, REMOTE)
	var gear = s._shop._get_gear_container(REMOTE)
	gear.set_weapons_data(RunData.get_player_weapons(REMOTE))
	yield(s._frames(1), "completed")
	return gear.weapons_container._elements


# count tier 1 weapons of different kinds, no pistol.
static func _tier0(count: int) -> Array:
	var found := []
	var ids := {"weapon_pistol": true}
	for weapon in ItemService.weapons:
		if found.size() < count and weapon.tier == 0 and not ids.has(weapon.weapon_id):
			ids[weapon.weapon_id] = true
			found.append(weapon)
	return found


static func _name(control) -> String:
	if not is_instance_valid(control):
		return "none"
	return control.item.my_id if "item" in control and control.item != null else control.name
