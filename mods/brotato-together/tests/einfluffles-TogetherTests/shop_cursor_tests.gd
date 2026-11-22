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
	var place: int = pistol.get_index()
	target = FocusTargets.describe(pistol, shop, REMOTE)
	yield(_press(s, "combine", pistol, target), "completed")
	# Where the client's own cursor goes when the host's state takes its pistol (_refresh_gear).
	var shown = s._sync._live_at(inventory, place)
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
	yield(_stale_rows(s), "completed")


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


# The client describes its cursor on its own rows, which lag the host's: an item that came in
# before the reported one on the host first (a buy, a trade) must not move the host's copy of
# that cursor to another item, neither when the report arrives nor when the host puts the cursor
# back after an intent (_settle_host_cursor).
func _stale_rows(s):
	var t: Node = s._t
	var shop: Node = s._shop
	var emulator = Utils.get_focus_emulator(REMOTE, shop)
	var kept: Array = RunData.players_data[REMOTE].items.duplicate()
	var picks := _by_tier()
	if picks.size() < 4:
		t._check(false, "host: items of four tiers for the stale rows checks")
		return
	var row: Node = yield(_fill_items(s, picks.slice(1, 3)), "completed")
	var reported: Control = row.get_child(row.get_child_count() - 1)
	var item = reported.item
	var target := FocusTargets.describe(reported, shop, REMOTE)  # on the client's rows
	RunData.add_item(picks[0], REMOTE)
	row.add_element(picks[0], true)  # on the host's rows first, before the reported one
	s._sync.host_apply_focus(shop, REMOTE, 0, target)
	var control = emulator.focused_control
	t._check(
		is_instance_valid(control) and control.get("item") == item,
		"host: a report described on the client's older rows lands on its item (%s, host %s)"
		% [item.my_id, _name(control)]
	)

	row = yield(_fill_items(s, picks.slice(1, 3)), "completed")
	reported = row.get_child(row.get_child_count() - 1)
	item = reported.item
	s._sync.host_apply_focus(shop, REMOTE, 0, FocusTargets.describe(reported, shop, REMOTE))
	RunData.add_item(picks[0], REMOTE)
	row.add_element(picks[0], true)  # a gift from another player (brotato:trade)
	var slot: int = s._pick(REMOTE)
	var id: String = s._node(REMOTE, slot).item_data.my_id
	t._check(s._apply("lock", slot, id, 1), "host applies the remote lock")
	yield(s._frames(2), "completed")  # _settle_host_cursor ran
	control = emulator.focused_control
	t._check(
		is_instance_valid(control) and control.get("item") == item,
		(
			"host: after an intent, with an item come in before the reported one, the cursor"
			+ " goes back to the reported item (%s, host %s)"
		)
		% [item.my_id, _name(control)]
	)
	s._apply("lock", slot, id, 0)
	emulator.focused_control = null
	RunData.players_data[REMOTE].items = kept
	shop._get_gear_container(REMOTE).set_items_data(kept)
	yield(s._frames(1), "completed")


# The remote player's items (as is), shown in its row.
func _fill_items(s, items: Array):
	Utils.get_focus_emulator(REMOTE, s._shop).focused_control = null  # off the elements freed here
	RunData.players_data[REMOTE].items.clear()
	for item in items:
		RunData.add_item(item, REMOTE)
	var gear = s._shop._get_gear_container(REMOTE)
	gear.set_items_data(RunData.get_player_items(REMOTE))
	yield(s._frames(1), "completed")
	return gear.items_container._elements


# One plain item of each tier, lowest first.
static func _by_tier() -> Array:
	var found := {}
	for item in ItemService.items:
		if not found.has(item.tier) and not item.is_cursed and item.max_nb == -1:
			found[item.tier] = item
	var tiers := found.keys()
	tiers.sort()
	var picks := []
	for tier in tiers:
		picks.append(found[tier])
	return picks
