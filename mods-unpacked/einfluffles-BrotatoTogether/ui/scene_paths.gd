extends Reference
# Child-index paths from the scene root. Host and client run the same scene built from the same
# run state, so the same path points at the same control — even for dynamically created nodes
# whose generated names differ between machines.


static func path_of(node: Node, root: Node) -> PoolIntArray:
	var path := PoolIntArray()
	var current := node
	while current != null and current != root:
		path.insert(0, current.get_index())
		current = current.get_parent()
	return path if current == root else PoolIntArray()


static func resolve(root: Node, path: PoolIntArray) -> Node:
	var current := root
	for index in path:
		if index < 0 or index >= current.get_child_count():
			return null
		current = current.get_child(index)
	return current


static func find_focus_emulators(root: Node) -> Array:
	var found := []
	_collect(root, found)
	return found


static func _collect(node: Node, found: Array) -> void:
	if node is FocusEmulator:
		found.append(node)
	for child in node.get_children():
		_collect(child, found)
