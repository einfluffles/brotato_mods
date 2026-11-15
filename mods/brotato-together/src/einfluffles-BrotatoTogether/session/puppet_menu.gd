extends Reference
# Client: what the host's selection screen offers, for the client's copy of that screen
# (extensions/ui/*_selection.gd ask here instead of this machine's own unlocks, so every grid
# has the host's elements in the host's order). Filled by sync/menu_puppet.gd before the scene
# loads. Names no game classes: script extensions preload it at mod init.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const META_KEY := "brotato_together_menu_grids"


# inventories: per inventory {elements: [ItemParentData], unlocked: [my_id_hash]}.
static func set_inventories(inventories: Array) -> void:
	Engine.set_meta(META_KEY, inventories)


static func clear() -> void:
	if Engine.has_meta(META_KEY):
		Engine.remove_meta(META_KEY)


# null: not a client's copy, the game's own list applies.
static func elements(index: int):
	var inventory = _inventory(index)
	return inventory.elements if inventory != null else null


static func unlocked(index: int):
	var inventory = _inventory(index)
	return inventory.unlocked if inventory != null else null


static func _inventory(index: int):
	if not Puppet.is_active():
		return null
	var inventories = Engine.get_meta(META_KEY) if Engine.has_meta(META_KEY) else []
	if index >= 0 and index < inventories.size():
		return inventories[index]
	return {"elements": [], "unlocked": []}  # nothing of this machine's own
