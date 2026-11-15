extends Reference
# Cursors by meaning (ui/focus_targets.gd): a target described on one tree resolves to the same
# control on a tree that has extra nodes another mod added on one side only, and the other way
# round. The two machines are simulated on one tree: described, extras inserted (or removed),
# resolved. Extras: a node at index 0 of the root (shifts every child index of the old paths),
# a Damage-Meter-like button right before the given sibling (the shop's reroll button) and a
# button right before every named target. Called from the suites that have the screens; checks
# go through t._check.

const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)


# controls: the controls to name; player: as FocusTargets.describe; next_to: a control whose
# parent gets the Damage-Meter-like button right before it (null: none).
static func check_robust(
	t: Node, label: String, root: Node, controls: Array, player := -1, next_to: Node = null
) -> void:
	var targets := []
	for control in controls:
		# Through the wire format, as a peer receives it.
		targets.append(bytes2var(var2bytes(FocusTargets.describe(control, root, player)), false))
	var described_ok := true
	for i in controls.size():
		described_ok = described_ok and FocusTargets.is_valid(targets[i])
	t._check(described_ok, "%s: every cursor target described (%s)" % [label, targets])
	var extras := add_mod_nodes(root, controls, next_to)
	var resolved := _resolved(targets, root, player)
	t._check(
		resolved == controls,
		"%s: targets land on the same controls with extra nodes on the receiver" % label
	)
	var with_extras := []
	for control in controls:
		with_extras.append(FocusTargets.describe(control, root, player))
	remove_nodes(extras)
	t._check(
		_resolved(with_extras, root, player) == controls,
		"%s: and with extra nodes on the sender only" % label
	)


static func _resolved(targets: Array, root: Node, player: int) -> Array:
	var found := []
	for target in targets:
		found.append(FocusTargets.resolve(target, root, player))
	return found


# What another mod would add on one machine only: a node first below root, a button right
# before every control from a scene file and before next_to. Undo with remove_nodes.
static func add_mod_nodes(root: Node, controls: Array, next_to: Node = null) -> Array:
	var extras := []
	var first := Control.new()
	root.add_child(first)
	root.move_child(first, 0)
	extras.append(first)
	var before := controls.duplicate()
	if next_to != null:
		before.append(next_to)
	for control in before:
		if control.owner == null or control.get_parent() == null:
			continue  # an element of a list built by code: its own kind is what counts there
		var button := Button.new()  # the kind of node Damage Meter adds next to reroll
		var parent: Node = control.get_parent()
		parent.add_child(button)
		parent.move_child(button, control.get_index())
		extras.append(button)
	return extras


static func remove_nodes(extras: Array) -> void:
	for extra in extras:
		if extra.get_parent() != null:
			extra.get_parent().remove_child(extra)
		extra.free()


# The first visible-or-not BaseButton below node in tree order, or null (for screens whose
# button names the tests do not hard-code).
static func first_button(node: Node) -> Node:
	for child in node.get_children():
		if child is BaseButton:
			return child
		var found = first_button(child)
		if found != null:
			return found
	return null


# Junk from the network is null, never an error.
static func check_junk(t: Node, root: Node) -> void:
	var junk := [
		null,
		"scene",
		[],
		["scene", -1, -1],
		["scene", 0, -1, []],
		["shop_item", 0, -1, []],
		["shop_reroll", 0, 3, []],
		["shop_reroll", 9, -1, []],
		["nope", 0, -1, []],
		["scene", -1, -1, [""]],
		["scene", -1, -1, [["Button", -1]]],
		["scene", -1, -1, [["", 0]]],
		["scene", -1, -1, [7]],
		["scene", -1, -1, ["../.."]],
	]
	var deep := []
	var long_name := ""
	for _i in FocusTargets.MAX_STEPS + 1:
		deep.append("A")
	for _i in FocusTargets.MAX_NAME + 1:
		long_name += "x"
	junk.append(["scene", -1, -1, deep])
	junk.append(["scene", -1, -1, [long_name]])
	var all_null := true
	for target in junk:
		all_null = all_null and FocusTargets.resolve(target, root) == null
	t._check(all_null, "focus targets: malformed targets from the network resolve to nothing")
	t._check(
		FocusTargets.resolve(["scene", -1, -1, []], root, 0) == null,
		"focus targets: a player's own report never names the whole scene"
	)
