extends Reference
# A cursor's control named by what it is, not by its place in the tree, so a node another mod
# adds on one machine only moves no cursor on the other.
#
# Target (wire format): [anchor, player, index, steps]
#   anchor  one of SHOP_ANCHORS / UPGRADE_ANCHORS: a control the game hands out per player
#           through its own accessors (BaseShop._get_reroll_button(p), ...), or
#           "scene": the root the target is relative to (player and index -1).
#   index   the element of a list both machines build from the same run state: the slot in
#           ShopItemsContainer._shop_items ("shop_item"), the option in
#           UpgradesUIPlayerContainer._get_upgrade_uis() ("up_option"); else -1.
#   steps   from the anchor down to the control. A node that comes from a scene file (it has an
#           owner) is its name. A node added by code has no owner and a generated name that
#           differs between machines ("@Button@123"):
#           - an inventory element that shows an item below a KEYED anchor (a gear row's weapon
#             or item, a crate weapon) is [type, key, copy]: key what it shows (item_key: id,
#             tier and the cursed / meca / mutant marks), copy its place among its siblings of
#             that type that show the same. These rows differ between machines while a run state
#             is on its way (an item one side has already shifts the others), and what both
#             sides find this way is the same item, or nothing.
#           - any other is [type, k], the k-th of its siblings without an owner that have the
#             same script (else class). The grids of the selection screens and the end of run
#             are built in the host's order from the host's entries (sync/menu_sync.gd), which
#             can show an item otherwise than this machine would (locked, another tier): their
#             place is what both machines share there.
#           Nodes queued for deletion are not counted.
# The nearest anchor above the control is used. A target that does not resolve on the receiver
# is null: cosmetic, the caller ignores it (FocusSync keeps its body pending: an item can come
# with the next run state).

const SCENE := "scene"
const INDEXED := ["shop_item", "up_option"]
const SHOP_ANCHORS := [
	"shop_item", "shop_reroll", "shop_go", "shop_popup", "shop_gear", "shop_panel"
]
const UPGRADE_ANCHORS := [
	"up_option", "up_reroll", "up_popup", "up_weapons", "up_gear", "up_panel"
]
const KEYED := ["shop_gear", "up_gear", "up_weapons"]  # their elements are named by item
const MAX_PLAYERS := 4
const MAX_INDEX := 4096
const MAX_STEPS := 32
const MAX_NAME := 128
const MAX_TYPE := 256
const MAX_KEY := 192


# [] when control is not below root. player >= 0: only that player's anchors count and there
# is no "scene" fallback (a player's own panel reports only what is inside it).
static func describe(control: Node, root: Node, player := -1) -> Array:
	if control == null or root == null or not is_instance_valid(control):
		return []
	var anchors := _anchors(root, player)
	var path := []  # the nodes below the anchor, down to control
	var node := control
	while node != null:
		var anchor = anchors.get(node.get_instance_id())
		if anchor != null:
			return [anchor[0], anchor[1], anchor[2], _steps(path, anchor[0] in KEYED)]
		if node == root:
			return [SCENE, -1, -1, _steps(path, false)] if player < 0 else []
		var parent := node.get_parent()
		if parent == null or path.size() >= MAX_STEPS:
			return []
		path.push_front(node)
		node = parent
	return []


static func _steps(path: Array, keyed: bool) -> Array:
	var steps := []
	for node in path:
		steps.append(_step(node, node.get_parent(), keyed))
	return steps


# Network data: anything malformed is null. player >= 0: only that player's anchors (what the
# sender's own panel may name).
static func resolve(target, root: Node, player := -1) -> Node:
	if root == null or not is_valid(target):
		return null
	var node: Node = null
	if target[0] == SCENE:
		if player >= 0:
			return null
		node = root
	elif player >= 0 and target[1] != player:
		return null
	else:
		node = _anchor(root, target[0], target[1], target[2])
	for step in target[3]:
		if node == null:
			return null
		node = _child(node, step)
	return node


static func is_valid(target) -> bool:
	if typeof(target) != TYPE_ARRAY or target.size() != 4:
		return false
	var anchor = target[0]
	if typeof(anchor) != TYPE_STRING:
		return false
	if typeof(target[1]) != TYPE_INT or typeof(target[2]) != TYPE_INT:
		return false
	if typeof(target[3]) != TYPE_ARRAY or target[3].size() > MAX_STEPS:
		return false
	var p: int = target[1]
	var k: int = target[2]
	if anchor == SCENE:
		if p != -1 or k != -1:
			return false
	elif not (anchor in SHOP_ANCHORS or anchor in UPGRADE_ANCHORS):
		return false
	elif p < 0 or p >= MAX_PLAYERS:
		return false
	elif (anchor in INDEXED) != (k >= 0) or k < -1 or k >= MAX_INDEX:
		return false
	for step in target[3]:
		if not _is_valid_step(step):
			return false
	return true


static func _is_valid_step(step) -> bool:
	if typeof(step) == TYPE_STRING:
		return not step.empty() and step.length() <= MAX_NAME
	if typeof(step) != TYPE_ARRAY or step.size() < 2 or step.size() > 3:
		return false
	if typeof(step[0]) != TYPE_STRING or step[0].empty() or step[0].length() > MAX_TYPE:
		return false
	var k = step[step.size() - 1]
	if typeof(k) != TYPE_INT or k < 0 or k >= MAX_INDEX:
		return false
	if step.size() == 3:
		var key = step[1]
		return typeof(key) == TYPE_STRING and not key.empty() and key.length() <= MAX_KEY
	return true


# instance id -> [anchor, player, index] for every anchor below root (player >= 0: its only).
static func _anchors(root: Node, player: int) -> Dictionary:
	var anchors := {}
	var players: Array = [player] if player >= 0 else range(RunData.get_player_count())
	for p in players:
		for anchor in SHOP_ANCHORS + UPGRADE_ANCHORS:
			var count := 1
			if anchor in INDEXED:
				count = _list_size(root, anchor, p)
			for i in count:
				var k: int = i if anchor in INDEXED else -1
				var node = _anchor(root, anchor, p, k)
				if node != null and not anchors.has(node.get_instance_id()):
					anchors[node.get_instance_id()] = [anchor, p, k]
	return anchors


static func _list_size(root: Node, anchor: String, p: int) -> int:
	var list = _list(root, anchor, p)
	return list.size() if list is Array else 0


static func _list(root: Node, anchor: String, p: int):
	if anchor == "shop_item":
		var items = _shop_call(root, "_get_shop_items_container", p)
		return items.get("_shop_items") if items != null else null
	var container = _upgrade_container(root, p)
	if container != null and container.has_method("_get_upgrade_uis"):
		return container._get_upgrade_uis()
	return null


# The game's own accessors for player p's parts of the coop shop (CoopShop) and of the coop
# level-up / crate panels (UpgradesUI, also reached from main through _coop_upgrades_ui).
static func _anchor(root: Node, anchor: String, p: int, k: int) -> Node:
	if p < 0 or p >= RunData.get_player_count():
		return null
	var node = null
	match anchor:
		"shop_item", "up_option":
			var list = _list(root, anchor, p)
			if list is Array and k >= 0 and k < list.size():
				node = list[k]
		"shop_reroll":
			node = _shop_call(root, "_get_reroll_button", p)
		"shop_go":
			node = _shop_call(root, "_get_go_button", p)
		"shop_popup":
			node = _shop_call(root, "_get_item_popup", p)
		"shop_gear":
			node = _shop_call(root, "_get_gear_container", p)
		"shop_panel":
			node = _shop_call(root, "_get_coop_player_container", p)
		_:
			var container = _upgrade_container(root, p)
			if container != null:
				match anchor:
					"up_reroll":
						node = container.get("_reroll_button")
					"up_popup":
						node = container.get("item_popup")
					"up_weapons":
						node = container.get("crate_weapons_container")
					"up_gear":
						node = container.get("player_gear_container")
					"up_panel":
						node = container
	if node is Node and is_instance_valid(node) and root.is_a_parent_of(node):
		return node
	return null


static func _shop_call(root: Node, method: String, p: int):
	if not root.has_method("_get_coop_player_container") or not root.has_method(method):
		return null
	return root.call(method, p)


static func _upgrade_container(root: Node, p: int):
	var ui = root if root.has_method("_get_player_container") else root.get("_coop_upgrades_ui")
	if not (ui is Node) or not is_instance_valid(ui) or not ui.has_method("_get_player_container"):
		return null
	var container = ui._get_player_container(p)
	return container if container is Node and is_instance_valid(container) else null


static func _step(node: Node, parent: Node, keyed: bool):
	if _is_named(node):
		return String(node.name)
	var type := _type(node)
	var key := item_key(node) if keyed else ""
	var k := 0
	for sibling in parent.get_children():
		if sibling == node:
			break
		if _is_listed(sibling, type) and (key == "" or item_key(sibling) == key):
			k += 1
	return [type, k] if key == "" else [type, key, k]


# A [type, key, copy] step finds only an element that shows that item, never one at its place.
static func _child(parent: Node, step) -> Node:
	if typeof(step) == TYPE_STRING:
		for child in parent.get_children():
			if _is_named(child) and String(child.name) == step:
				return child
		return null
	var key: String = step[1] if step.size() == 3 else ""
	var wanted: int = step[step.size() - 1]
	var k := 0
	for child in parent.get_children():
		if _is_listed(child, step[0]) and (key == "" or item_key(child) == key):
			if k == wanted:
				return child
			k += 1
	return null


# What an inventory element shows of its item, the same on every machine (unlike
# UpgradesGear.shows, which has the icon's instance id). "" for any other node and for a special
# element (a locked or random one): those are named by their place.
static func item_key(node: Node) -> String:
	if not node is InventoryElement or node.is_special:
		return ""
	var item = node.item
	if not item is ItemParentData:
		return ""
	return "%s %d %d%d%d" % [
		item.my_id, item.tier, int(item.is_cursed), int(item.is_meca), int(item.is_mutant)
	]


# From a scene file: its name is the same on every machine.
static func _is_named(node: Node) -> bool:
	return node.owner != null and not String(node.name).begins_with("@")


static func _is_listed(node: Node, type: String) -> bool:
	return not _is_named(node) and not node.is_queued_for_deletion() and _type(node) == type


static func _type(node: Node) -> String:
	var script = node.get_script()
	if script is Script and script.resource_path != "":
		return script.resource_path
	return node.get_class()
