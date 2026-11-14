extends Reference
# Host: a remote player's shop decisions (SHOP_INTENT) and cursor (SHOP_FOCUS), applied to the
# host's own shop. An intent names its target by place and by identity (slot + my_id) and the
# game's own code decides: the button is pressed the way a FocusEmulator presses it, or the
# control's own signal / the shop's own method runs, so the game's checks (gold, weapon slots,
# ban tokens, ...) and other mods' handlers see it like a local player's press.
#
# kind         slot                 id            arg
# "buy"        shop item node       item my_id    meca effect choice (0 / 1), else -1
# "steal"      shop item node       item my_id    -
# "lock"       shop item node       item my_id    1: lock, 0: unlock
# "ban"        shop item node       item my_id    -
# "dismantle"  shop item node       item my_id    -
# "reroll"     -                    ""            -
# "go"         -                    ""            1: ready, 0: not ready
# "endless"    -                    ""            1: on, 0: off
# "combine"    index in the weapons weapon my_id  -
# "discard"    index in the weapons weapon my_id  -
# "go", "endless" and "lock" say what the player wants to be true: applying them twice changes
# nothing, so "go" and "endless" need no revision. Everything else is a press on what the
# sender's panel showed (the revision) and makes that revision stale once applied.

enum { DROPPED, APPLIED, CHANGED }

const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const SLOT_KINDS := ["buy", "steal", "lock", "ban", "dismantle"]
const WEAPON_KINDS := ["combine", "discard"]
const PATH_TYPES := [TYPE_INT_ARRAY, TYPE_ARRAY]


# seq: the current revision of player p's panel. Returns DROPPED, APPLIED (nothing a press
# could go stale on changed) or CHANGED (the caller bumps the revision).
static func apply(shop: Node, p: int, msg: Dictionary, seq: int) -> int:
	var kind = msg.get("kind")
	var slot = msg.get("slot")
	var id = msg.get("id")
	var arg = msg.get("arg")
	if typeof(kind) != TYPE_STRING or typeof(id) != TYPE_STRING:
		return DROPPED
	if typeof(slot) != TYPE_INT or typeof(arg) != TYPE_INT:
		return DROPPED
	if kind == "go":
		return _go(shop, p, arg != 0)
	if kind == "endless":
		return _endless(shop, p, arg != 0)
	if typeof(msg.get("seq")) != TYPE_INT or msg.seq != seq:
		return DROPPED
	if kind == "reroll":
		return CHANGED if _press(shop._get_reroll_button(p), p) else DROPPED
	if kind in SLOT_KINDS:
		var node = find_slot(shop._get_shop_items_container(p), slot, id)
		return DROPPED if node == null else _slot(shop, p, node, kind, arg)
	if kind in WEAPON_KINDS:
		var weapon = find_weapon(RunData.get_player_weapons(p), slot, id)
		if weapon == null:
			return DROPPED
		# The popup's own signal: the shop's handler checks what may be combined / recycled.
		shop._get_item_popup(p).emit_signal("item_%s_button_pressed" % kind, weapon)
		return CHANGED
	return DROPPED


# What player p's panel offers, as far as a press can go stale on it: the offered items (the
# slot nodes), the rerolls and the weapons. Locks and gold are not part of it.
static func revision_key(shop: Node, p: int) -> String:
	var offered := []
	for node in shop._get_shop_items_container(p)._shop_items:
		var shown: bool = node.active and node.item_data != null
		offered.append(node.item_data.get_instance_id() if shown else 0)
	var weapons := []
	for weapon in RunData.get_player_weapons(p):
		weapons.append(weapon.get_instance_id())
	return var2str([offered, shop._reroll_count[p], weapons])


# A remote player's own cursor and page, for the host's screen and (through FocusSync and
# SHOP_STATE) the other clients'. Cosmetic: decisions never depend on it.
static func apply_focus(shop: Node, p: int, page, path) -> void:
	var emulator = Utils.get_focus_emulator(p, shop)
	if emulator == null:
		return
	var panel = shop._get_coop_player_container(p)
	if typeof(page) == TYPE_INT and page >= 0 and page != panel.carousel.index:
		panel.carousel.index = page  # the setter clamps and shows that page
	var indices := int_path(path)
	if indices.empty():
		return
	var control = ScenePaths.resolve(panel, indices)
	if control is Control and control.is_visible_in_tree() and emulator.focused_control != control:
		emulator.focused_control = control


# Identity over index: the node at the slot when it holds that item, else any node that does
# (the panel changed shape), else nothing.
static func find_slot(container: Node, slot: int, id: String):
	var nodes: Array = container._shop_items
	if slot >= 0 and slot < nodes.size() and _offers(nodes[slot], id):
		return nodes[slot]
	for node in nodes:
		if _offers(node, id):
			return node
	return null


static func find_weapon(weapons: Array, slot: int, id: String):
	if slot >= 0 and slot < weapons.size() and weapons[slot].my_id == id:
		return weapons[slot]
	for weapon in weapons:
		if weapon.my_id == id:
			return weapon
	return null


# A child-index path from the network: empty unless it is a list of ints.
static func int_path(value) -> PoolIntArray:
	var path := PoolIntArray()
	if not (typeof(value) in PATH_TYPES):
		return path
	for index in value:
		if typeof(index) != TYPE_INT:
			return PoolIntArray()
		path.append(index)
	return path


static func _offers(node: Node, id: String) -> bool:
	return node.active and node.item_data != null and node.item_data.my_id == id


static func _slot(shop: Node, p: int, node: Node, kind: String, arg: int) -> int:
	match kind:
		"buy":
			if node.item_data.is_meca and (arg == 0 or arg == 1):
				node.effect_choice_selected = arg
				node.update_effect_choice_buttons_visuals()
			return CHANGED if _press(node._button, p) else DROPPED
		"steal":
			if shop._item_steals[p] <= 0:
				return DROPPED
			node.steal_item()
			return CHANGED
		"lock":
			# BaseShop._input's condition for the lock shortcut; change_lock_status checks the rest.
			if node.locked == (arg != 0) or not node.item_data.is_lockable:
				return DROPPED
			node.change_lock_status(arg != 0)
			return APPLIED
		"ban":
			if node._ban_button.disabled:
				return DROPPED
			# Where both the hold and the plain press end; the container checks the tokens.
			node.emit_signal("ban_item_pressed", node)
			return CHANGED
		"dismantle":
			if not shop._can_dismantle_with_shortcut(node, p):
				return DROPPED
			node._on_DismantleButton_pressed()
			return CHANGED
	return DROPPED


static func _go(shop: Node, p: int, ready: bool) -> int:
	if shop._player_pressed_go_button[p] == ready:
		return DROPPED
	if not ready:
		shop._clear_go_button_pressed(p)
		return APPLIED
	return APPLIED if _press(shop._get_go_button(p), p) else DROPPED


# Player 1's "endless" toggle (wave 20 only). The button's own toggled signal sets the run.
static func _endless(shop: Node, p: int, on: bool) -> int:
	var button = shop._get_coop_player_container(p).get("_endless_button")
	if button == null or not button.visible or button.pressed == on:
		return DROPPED
	button.pressed = on
	return APPLIED


# What FocusEmulator._press_button does for a local co-op player: every handler connected to
# the button runs (the game's, its press sound, other mods').
static func _press(button: BaseButton, p: int) -> bool:
	if button == null or button.disabled:
		return false
	FocusEmulatorSignal.emit(button, "pressed", p)
	return true
