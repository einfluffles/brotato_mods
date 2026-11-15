extends Reference
# Every FocusEmulator below a scene root. Cursors travel by meaning (ui/focus_targets.gd), not by
# tree position: another mod's extra node on one machine would shift any child index.


static func find_focus_emulators(root: Node) -> Array:
	var found := []
	_collect(root, found)
	return found


static func _collect(node: Node, found: Array) -> void:
	if node is FocusEmulator:
		found.append(node)
	for child in node.get_children():
		_collect(child, found)
