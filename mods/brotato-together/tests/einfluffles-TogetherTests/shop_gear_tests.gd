extends Reference
# The shop's weapons row (ui/shop_gear.gd, extensions/ui/coop_shop.gd and shop.gd): the Anvil's
# upgrade at shop entry, the "WEAPONS (n/m)" label after a new weapon slot and a client's open
# popup while its weapons row changes. entry() runs in the shop loopback suite and leaves a solo
# shop behind; the rest runs in the local shop suite.

const PISTOL := "weapon_pistol_1"
const SMG := "weapon_smg_1"
const ARM := "item_cybernetic_arm"
const REMOTE := 1
const DMG := 321  # last wave's damage of the weapons the Anvil may upgrade

var _t: Node = null
var _added := {}  # instance id -> [element, its first inventory] as weakrefs, while a shop loads


# The Cybernetic Arm, as mod_main.coop_run finds it.
static func arm_item(t: Node):
	var arm = t._find_by_id(ItemService.items, ARM)
	if arm == null:
		arm = load("res://items/all/04_primal_dread/cybernetic_arm/cybernetic_arm.tres")
	return arm


static func label_of(shop: Node, p: int) -> String:
	return shop._get_gear_container(p).weapons_container._label.text


func entry(t: Node):
	_t = t
	yield(_entry_shop(true), "completed")
	yield(_entry_shop(false), "completed")


func _entry_shop(coop: bool):
	var what := "co-op shop" if coop else "solo shop"
	var tree := _t.get_tree()
	tree.paused = false
	CoopService.clear_coop_players()
	RunData.reset()
	if coop:
		RunData.set_coop_run(true)
		RunData.set_player_count(2)
		for i in 2:
			CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	for p in RunData.get_player_count():
		RunData.add_character(ItemService.characters[p], p)
	RunData.current_wave = 2
	var pistol = _t._find_by_id(ItemService.weapons, PISTOL)
	for _i in 2:
		var weapon = RunData.add_weapon(pistol, 0)
		weapon.dmg_dealt_last_wave = DMG
	RunData.add_gold(1000, 0)
	var anvil: Array = RunData.get_player_effects(0)[Keys.upgrade_random_weapon_hash]
	anvil.append([Keys.stat_armor_hash, 2])
	RunData.shop_effects_checked = false
	_added = {}
	tree.connect("node_added", self, "_on_node_added")
	tree.change_scene(RunData.get_shop_scene_path())
	for _i in 3:
		yield(tree, "idle_frame")
	tree.disconnect("node_added", self, "_on_node_added")
	var shop: Node = tree.current_scene
	var ids := _weapon_ids(0)
	var upgraded = null
	for weapon in RunData.get_player_weapons(0):
		upgraded = weapon if weapon.my_id == "weapon_pistol_2" else upgraded
	_t._check(
		ids.size() == 2 and PISTOL in ids and upgraded != null,
		"%s: the Anvil upgraded a weapon at entry %s" % [what, ids]
	)
	_t._check(
		upgraded != null and upgraded.dmg_dealt_last_wave == DMG and RunData.shop_effects_checked,
		"%s: the upgrade keeps last wave's damage, the shop's effects are done" % what
	)
	var dropped := _dropped(shop)
	_t._check(
		dropped == 0,
		"%s: no weapon element made and freed before the rows were filled (%d)" % [what, dropped]
	)
	var shown := []
	for element in shop._get_gear_container(0).weapons_container._elements.get_children():
		if not element.is_queued_for_deletion():
			shown.append(element.item.my_id)
	shown.sort()
	ids.sort()
	_t._check(shown == ids, "%s: the weapons row shows the run's weapons %s" % [what, shown])
	yield(_buy_arm(shop, what), "completed")
	anvil.clear()


func _buy_arm(shop: Node, what: String):
	var slots: int = RunData.get_player_effect(Keys.weapon_slot_hash, 0)
	var count: int = RunData.get_player_weapons(0).size()
	var before := label_of(shop, 0)
	var node = offer(shop, 0, 0, arm_item(_t))
	node._button.emit_signal("pressed")  # the buy itself is a deferred connection
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var now: int = RunData.get_player_effect(Keys.weapon_slot_hash, 0)
	_t._check(
		now == slots + 1 and before.ends_with("(%d/%d)" % [count, slots]),
		"%s: the Arm bought, %d weapon slots (label before: %s)" % [what, now, before]
	)
	_t._check(
		label_of(shop, 0).ends_with("(%d/%d)" % [count, now]),
		"%s: the weapons label shows the new slot at once (%s)" % [what, label_of(shop, 0)]
	)


func _on_node_added(node: Node) -> void:
	if node is InventoryElement and not _added.has(node.get_instance_id()):
		_added[node.get_instance_id()] = [weakref(node), weakref(node.get_parent())]


# Inventory elements a weapons row of the shop got while it loaded and no longer has.
func _dropped(shop: Node) -> int:
	var rows := []
	for p in RunData.get_player_count():
		rows.append(shop._get_gear_container(p).weapons_container._elements)
	var dropped := 0
	for entry in _added.values():
		var element = entry[0].get_ref()
		var parent = entry[1].get_ref()
		if parent == null or not parent in rows:
			continue
		if element == null or element.is_queued_for_deletion() or element.get_parent() != parent:
			dropped += 1
	return dropped


# Host, after the remote player's other decisions: without the Arm its slots are full and a
# weapon it has no copy of is refused; the Arm, then the same weapon right away.
func host(s):
	_t = s._t
	var shop: Node = s._shop
	var arm = arm_item(_t)
	RunData.remove_item(arm, REMOTE, true)  # mod_main.coop_run gave it one
	var fill = null
	var wanted = null
	var owned := {}
	for weapon in RunData.get_player_weapons(REMOTE):
		owned[weapon.weapon_id] = true
	for weapon in ItemService.weapons:
		if weapon.tier != 0 or owned.has(weapon.weapon_id):
			continue
		if fill == null:
			fill = weapon
		elif wanted == null and weapon.weapon_id != fill.weapon_id:
			wanted = weapon
	var slots: int = RunData.get_player_effect(Keys.weapon_slot_hash, REMOTE)
	while RunData.get_player_weapons(REMOTE).size() < slots:
		RunData.add_weapon(fill, REMOTE)
	shop._get_gear_container(REMOTE).set_weapons_data(RunData.get_player_weapons(REMOTE))
	yield(s._buy_delay(), "completed")
	var weapon_node = offer(shop, REMOTE, 0, wanted)
	offer(shop, REMOTE, 1, arm)
	s._apply("buy", 0, wanted.my_id)
	yield(s._frames(2), "completed")
	_t._check(
		RunData.get_player_weapons(REMOTE).size() == slots and weapon_node.active,
		"host: a remote player's weapon without a free slot is refused (%d slots)" % slots
	)
	_t._check(s._apply("buy", 1, ARM), "host applies the remote player's Arm")
	yield(s._frames(2), "completed")
	var now: int = RunData.get_player_effect(Keys.weapon_slot_hash, REMOTE)
	_t._check(
		now == slots + 1 and label_of(shop, REMOTE).ends_with("(%d/%d)" % [slots, now]),
		"host: the remote panel's label shows the new slot at once (%s)" % label_of(shop, REMOTE)
	)
	yield(s._buy_delay(), "completed")
	_t._check(s._apply("buy", 0, wanted.my_id), "the remote player buys the weapon right away")
	yield(s._frames(2), "completed")
	_t._check(
		RunData.get_player_weapons(REMOTE).size() == now and wanted.my_id in s._weapon_ids(REMOTE),
		"host: the weapon went into the new slot %s" % [s._weapon_ids(REMOTE)]
	)
	_t._check(
		label_of(shop, REMOTE).ends_with("(%d/%d)" % [now, now]),
		"host: the label counts it (%s)" % label_of(shop, REMOTE)
	)
	yield(s._buy_delay(), "completed")


func client(s, shop: Node) -> void:
	var slots: int = RunData.get_player_effect(Keys.weapon_slot_hash, REMOTE)
	var count: int = RunData.get_player_weapons(REMOTE).size()
	s._t._check(
		count == slots and label_of(shop, REMOTE).ends_with("(%d/%d)" % [count, slots]),
		"client: the remote panel's label shows the host's slots (%s)" % label_of(shop, REMOTE)
	)


# Host, before its first state: the client's own player has an Anvil the host's shop already
# applied (or found nothing to upgrade for). The client's copy must not upgrade a weapon itself.
static func host_anvil(s) -> void:
	RunData.get_player_effects(0)[Keys.upgrade_random_weapon_hash].append([Keys.stat_armor_hash, 2])
	s._sync.run_cache.force()


static func client_anvil(s, host_weapons: Array) -> void:
	s._t._check(
		RunData.shop_effects_checked and s._weapon_ids(0) == host_weapons,
		"client: the host's Anvil is not applied again in its copy %s" % [s._weapon_ids(0)]
	)


# Host, at the end: the own player (0) with one SMG ("own_single"), then with two ("own_pair"),
# for client_popup. Its weapons are put back after.
static func host_popup(s) -> void:
	var weapons: Array = RunData.players_data[0].weapons
	var kept: Array = weapons.duplicate()
	var smg = s._t._find_by_id(ItemService.weapons, SMG)
	weapons.clear()
	RunData.add_weapon(smg, 0)
	s._capture("own_single")
	RunData.add_weapon(smg, 0)
	s._capture("own_pair")
	weapons.clear()
	weapons.append_array(kept)


# Client: the own popup stays open on its SMG while the host's state brings a second one (a trade,
# a purchase) and takes it again. Its buttons follow, as the game's own popup shows them when it
# opens: Combine appears and goes, and a cursor on Combine when it goes lands on Cancel.
func client_popup(s, shop: Node):
	yield(s._frames(1), "completed")
	if not s._states.has("own_pair"):
		return
	var t: Node = s._t
	var popup = shop._get_item_popup(0)
	var emulator = Utils.get_focus_emulator(0, shop)
	var row: Node = shop._get_gear_container(0).weapons_container._elements
	s._receive(s._states.own_single)
	yield(s._frames(2), "completed")
	var element = row.get_child(0)
	emulator.focused_control = element
	yield(s._tap("ui_accept"), "completed")
	t._check(
		(
			popup._focused
			and popup._item_data != null
			and popup._item_data.my_id == SMG
			and not popup._combine_button.visible
		),
		"(the own popup is open on a single SMG, without Combine)"
	)
	s._receive(s._states.own_pair)
	t._check(
		(
			popup._focused
			and shop._popup_manager._elements_pressed[0] == element
			and RunData.get_player_weapons(0).has(popup._item_data)
			and popup._combine_button.visible
		),
		"client: a second SMG from outside shows Combine in the own open popup"
	)
	emulator.focused_control = popup._combine_button
	s._receive(s._states.own_single)
	t._check(
		(
			popup._focused
			and not popup._combine_button.visible
			and emulator.focused_control == popup._cancel_button
		),
		"client: and when it goes again, Combine goes, the cursor on it moves to Cancel"
	)
	yield(s._tap("ui_cancel"), "completed")
	t._check(not popup._focused, "(Cancel closes the own popup)")
	s._receive(s._states.remote_armed if s._states.has("remote_armed") else s._states.start)
	yield(s._frames(2), "completed")


# Player p's shop slot shows item (activated if it was not), and the offered list has it.
static func offer(shop: Node, p: int, slot: int, item) -> Node:
	var node = shop._get_shop_items_container(p).get_shop_item_node(slot)
	node.set_shop_item(item, RunData.current_wave)
	if not node.active:
		node.activate()
	shop._shop_items[p].append([item, RunData.current_wave])
	return node


static func _weapon_ids(p: int) -> Array:
	var ids := []
	for weapon in RunData.get_player_weapons(p):
		ids.append(weapon.my_id)
	return ids
