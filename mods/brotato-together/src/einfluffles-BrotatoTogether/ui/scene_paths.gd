extends Reference


static func find_focus_emulators(root: Node) -> Array:
	var found := []
	_collect(root, found)
	return found


static func _collect(node: Node, found: Array) -> void:
	if node is FocusEmulator:
		found.append(node)
	for child in node.get_children():
		_collect(child, found)
