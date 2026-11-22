extends Reference
# Suite focus_targets: ui/focus_targets.gd names an inventory element of a gear row by what it
# shows ([type, key, copy]), so a target described on one machine's row finds the same item on
# another machine's row that is ordered otherwise or has an element more or less, and nothing
# when that row lacks the item. One row stands for both machines: described, changed, resolved.
# The root is a stand-in shop whose _get_gear_container(p) is the row's parent ("shop_gear").

const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const ELEMENT_SCENE := "res://items/global/inventory_element.tscn"
const ELEMENT_SCRIPT := "res://items/global/inventory_element.gd"
const SHOP_SOURCE := """extends Control
var gear = null
func _get_coop_player_container(_p):
	return null
func _get_gear_container(_p):
	return gear
"""

var t: Node
var _root: Control = null
var _row: Control = null


func run(test_mod: Node, _together: Node):
	t = test_mod
	var script := GDScript.new()
	script.source_code = SHOP_SOURCE
	script.reload()
	_root = Control.new()
	_root.set_script(script)
	t.add_child(_root)
	var gear := Control.new()
	gear.name = "Gear"
	_root.add_child(gear)
	_root.set("gear", gear)
	_row = Control.new()
	_row.name = "Row"
	gear.add_child(_row)
	_row.owner = _root  # a named step, as a row from a scene file
	var items := _items()
	if items.size() < 4:
		t._check(false, "focus targets: four items of different ids and tiers in ItemService")
	else:
		_test_steps(items)
		_test_reordered(items)
		_test_inserted(items)
		_test_absent(items)
		_test_cursed(items)
		_test_copies()
		_test_special(items)
		_test_unkeyed(items)
		_test_malformed(items)
	yield(t.get_tree(), "idle_frame")
	_root.free()


# Four items, the first three of different tiers.
static func _items() -> Array:
	var found := []
	var tiers := {}
	for item in ItemService.items:
		if found.size() < 3 and not tiers.has(item.tier):
			tiers[item.tier] = true
			found.append(item)
	for item in ItemService.items:
		if found.size() == 3 and not item in found:
			found.append(item)
	return found


func _element(item: Resource, index := -1, parent: Node = null) -> Node:
	var element: Node = load(ELEMENT_SCENE).instance()
	# The game's theme gives it a flat box (set_element colours it); this root has no theme.
	element.add_stylebox_override("normal", StyleBoxFlat.new())
	var row: Node = parent if parent != null else _row
	row.add_child(element)
	if index >= 0:
		row.move_child(element, index)
	element.set_element(item)
	return element


func _clear() -> void:
	for child in _row.get_children():
		_row.remove_child(child)
		child.free()


# As a peer receives it.
func _describe(control: Node) -> Array:
	return bytes2var(var2bytes(FocusTargets.describe(control, _root)), false)


func _resolve(target) -> Node:
	return FocusTargets.resolve(target, _root)


static func _last_step(target: Array):
	if target.size() != 4 or typeof(target[3]) != TYPE_ARRAY or target[3].empty():
		return null
	return target[3][target[3].size() - 1]


func _test_steps(items: Array) -> void:
	_clear()
	for item in items.slice(0, 1):
		_element(item)
	var second: Node = _row.get_child(1)
	var target := _describe(second)
	var item = items[1]
	var key := "%s %d 000" % [item.my_id, item.tier]
	t._check(
		(
			FocusTargets.is_valid(target)
			and target[0] == "shop_gear"
			and target[3].size() == 2
			and target[3][0] == "Row"
			and var2str(_last_step(target)) == var2str([ELEMENT_SCRIPT, key, 0])
		),
		"focus targets: a gear element is [type, its item's key, copy] (%s)" % [target]
	)
	second.set_element(item.duplicate())  # another object of the item, as a run state brings
	t._check(
		var2str(_describe(second)) == var2str(target),
		"focus targets: the key is what it shows, not the object (no instance ids)"
	)


func _test_reordered(items: Array) -> void:
	_clear()
	var elements := []
	for item in items.slice(0, 2):
		elements.append(_element(item))
	var targets := []
	for element in elements:
		targets.append(_describe(element))
	_row.move_child(elements[2], 0)
	_row.move_child(elements[1], 2)
	var found := []
	for target in targets:
		found.append(_resolve(target))
	t._check(found == elements, "focus targets: each finds its item in a row ordered otherwise")


# The race of a gift: an element comes in before the cursor's one on one machine first.
func _test_inserted(items: Array) -> void:
	_clear()
	var elements := []
	for item in items.slice(0, 2):
		elements.append(_element(item))
	var before := _describe(elements[2])
	var inserted: Node = _element(items[3], 0)
	var after := _describe(elements[2])
	t._check(
		var2str(after) == var2str(before),
		"focus targets: an element inserted before it leaves its description as it was"
	)
	t._check(
		_resolve(before) == elements[2],
		"focus targets: a target described before the insert finds its item after it"
	)
	_row.remove_child(inserted)
	inserted.free()
	t._check(
		_resolve(after) == elements[2],
		"focus targets: a target described after the insert finds its item without it"
	)


func _test_absent(items: Array) -> void:
	_clear()
	for item in items.slice(0, 2):
		_element(item)
	var middle: Node = _row.get_child(1)
	var target := _describe(middle)
	middle.set_element(items[3])  # the same node, another item at the place
	t._check(
		_resolve(target) == null,
		"focus targets: an item the row lacks is nothing, not the element at its place"
	)
	middle.set_element(items[1])
	middle.queue_free()
	t._check(_resolve(target) == null, "focus targets: an element queued for deletion is nothing")
	_row.remove_child(middle)  # freed at the end of the frame


# A plain stack and a cursed copy of the same item: same tier and name, so their order on the two
# machines may differ (the game's sort is not stable).
func _test_cursed(items: Array) -> void:
	_clear()
	var item = items[1]
	var cursed: Resource = item.duplicate()
	cursed.is_cursed = true
	var plain_element: Node = _element(item)
	var cursed_element: Node = _element(cursed)
	var plain_target := _describe(plain_element)
	var cursed_target := _describe(cursed_element)
	_row.move_child(cursed_element, 0)
	t._check(
		_resolve(plain_target) == plain_element and _resolve(cursed_target) == cursed_element,
		"focus targets: a cursed copy and the plain item swapped find each their own (%s, %s)"
		% [_last_step(plain_target), _last_step(cursed_target)]
	)


# Two weapons alike: the copy counts the live elements that show the same.
func _test_copies() -> void:
	_clear()
	var weapon = ItemService.weapons[0]
	var other = null
	for candidate in ItemService.weapons:
		if other == null and candidate.my_id != weapon.my_id:
			other = candidate
	var first: Node = _element(weapon)
	var second: Node = _element(weapon.duplicate())
	_element(other)
	var target := _describe(second)
	var step = _last_step(target)
	t._check(
		step[2] == 1 and _resolve(target) == second,
		"focus targets: the second of two alike is copy 1 (%s)" % [step]
	)
	_row.move_child(_row.get_child(2), 0)
	t._check(_resolve(target) == second, "focus targets: another item moved before them: copy 1")
	first.queue_free()
	t._check(
		_last_step(_describe(second))[2] == 0 and _resolve(target) == null,
		"focus targets: the first alike queued for deletion: the second is copy 0, copy 1 is none"
	)
	_row.remove_child(first)  # freed at the end of the frame


# A locked or random element (add_special_element) is named by its place.
func _test_special(items: Array) -> void:
	_clear()
	_element(items[0])
	var special: Node = _element(items[1])
	special.is_special = true
	var target := _describe(special)
	var step = _last_step(target)
	t._check(
		typeof(step) == TYPE_ARRAY and step.size() == 2 and step[1] == 1,
		"focus targets: a special element is [type, k] (%s)" % [step]
	)
	t._check(_resolve(target) == special, "focus targets: and found at its place")


# Outside the gear (a selection screen's grid, under "scene"): by place, as the host built it.
func _test_unkeyed(items: Array) -> void:
	var grid := Control.new()
	_root.add_child(grid)
	_element(items[0], -1, grid)
	var element: Node = _element(items[1], -1, grid)
	var target := _describe(element)
	var step = _last_step(target)
	t._check(
		target[0] == FocusTargets.SCENE and typeof(step) == TYPE_ARRAY and step.size() == 2,
		"focus targets: an element outside the gear is [type, k] (%s)" % [step]
	)
	_root.remove_child(grid)
	grid.free()


func _test_malformed(items: Array) -> void:
	_clear()
	var element: Node = _element(items[0])
	var target := _describe(element)
	var good: Array = _last_step(target)
	var long_key := ""
	for _i in FocusTargets.MAX_KEY + 1:
		long_key += "x"
	var bad_steps := [
		[good[0], good[1], -1],
		[good[0], good[1], FocusTargets.MAX_INDEX],
		[good[0], good[1], 0.0],
		[good[0], "", 0],
		[good[0], 7, 0],
		[good[0], long_key, 0],
		[good[0], good[1], 0, 0],
		["", good[1], 0],
		[good[0]],
	]
	var all_bad := true
	for step in bad_steps:
		var bad: Array = target.duplicate(true)
		bad[3][bad[3].size() - 1] = step
		all_bad = all_bad and not FocusTargets.is_valid(bad) and _resolve(bad) == null
	t._check(all_bad, "focus targets: malformed item steps from the network are rejected")
	t._check(
		FocusTargets.is_valid(target) and _resolve(target) == element,
		"focus targets: (the well-formed one resolves)"
	)
