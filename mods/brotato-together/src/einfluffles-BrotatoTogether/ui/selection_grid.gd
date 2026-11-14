extends HBoxContainer
# Client copy of the host's selection grid(s) (character / weapon / difficulty selection): built
# from the host's ordered element list, not from local unlocks/DLC, so every icon sits where it
# does on the host. Each player's cursor is a border in their co-op colour (thicker once ready).
# Ids this machine doesn't know (a DLC it lacks) show as "?".

const LOCKED_ICON_PATH := "res://items/global/locked_icon.png"
const MAX_ELEMENTS := 400
const MAX_WIDTH := 1760.0
const CELL_GAP := 4
const FLAG_RANDOM := 1
const FLAG_SPECIAL := 2  # shown greyed out / with a lock (locked, needs an item set)
const FLAG_LOCKED := 4

var _key := ""
var _cells := []  # per inventory: Array of {style: StyleBoxFlat, label: Label}
var _items := {}  # my_id -> ItemParentData, built lazily


func set_grids(grids) -> void:
	var key := var2str(grids)
	if key == _key:
		return
	_key = key
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cells.clear()
	if typeof(grids) != TYPE_DICTIONARY or typeof(grids.get("inventories")) != TYPE_ARRAY:
		return
	var inventories: Array = grids.inventories
	var random_icon = _load_texture(grids.get("random_icon"))
	var total_columns := 0
	for inventory in inventories:
		total_columns += _columns_of(inventory)
	var cell := int(clamp(MAX_WIDTH / max(total_columns, 1) - CELL_GAP, 28, 64))
	add_constant_override("separation", 32)
	for inventory in inventories:
		var cells := []
		if _columns_of(inventory) > 0:
			var grid := GridContainer.new()
			grid.columns = _columns_of(inventory)
			grid.add_constant_override("hseparation", CELL_GAP)
			grid.add_constant_override("vseparation", CELL_GAP)
			add_child(grid)
			for i in min(inventory[1].size(), MAX_ELEMENTS):
				cells.append(_new_cell(grid, inventory[1][i], random_icon, cell))
		_cells.append(cells)  # one slot per host inventory: cursor indices stay aligned


# players: MENU_STATE entries [id, label, is_random, ready, inventory, index].
func set_cursors(players: Array) -> void:
	var marks := {}  # "inventory:index" -> [player indices]
	var ready := {}
	for p in players.size():
		var entry = players[p]
		if typeof(entry) != TYPE_ARRAY or entry.size() < 6:
			continue
		if cell_at(int(entry[4]), int(entry[5])) == null:
			continue
		var key := "%d:%d" % [int(entry[4]), int(entry[5])]
		if not marks.has(key):
			marks[key] = []
		marks[key].append(p)
		ready[p] = bool(entry[3])
	for inventory in _cells.size():
		for index in _cells[inventory].size():
			var cell: Dictionary = _cells[inventory][index]
			var on: Array = marks.get("%d:%d" % [inventory, index], [])
			cell.style.set_border_width_all(0)
			cell.label.text = ""
			if on.empty():
				continue
			cell.style.border_color = CoopService.get_player_color(on[0])
			cell.style.set_border_width_all(6 if ready.get(on[0], false) else 3)
			var names := []
			for p in on:
				names.append("P%d%s" % [p + 1, "✓" if ready.get(p, false) else ""])
			cell.label.text = PoolStringArray(names).join(" ")


func cell_at(inventory: int, index: int):
	if inventory < 0 or inventory >= _cells.size():
		return null
	if index < 0 or index >= _cells[inventory].size():
		return null
	return _cells[inventory][index]


func inventory_count() -> int:
	return _cells.size()


func cell_count(inventory: int) -> int:
	return _cells[inventory].size() if inventory >= 0 and inventory < _cells.size() else 0


func cell_item(inventory: int, index: int):
	var cell = cell_at(inventory, index)
	return cell.item if cell != null else null


static func _columns_of(inventory) -> int:
	if typeof(inventory) != TYPE_ARRAY or inventory.size() != 2:
		return 0
	if typeof(inventory[1]) != TYPE_ARRAY:
		return 0
	return int(clamp(int(inventory[0]), 1, 40))


func _new_cell(grid: GridContainer, entry, random_icon, size: int) -> Dictionary:
	var panel := Panel.new()
	panel.rect_min_size = Vector2(size, size)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.35)
	style.set_corner_radius_all(6)
	panel.add_stylebox_override("panel", style)
	grid.add_child(panel)
	var icon := TextureRect.new()
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.anchor_right = 1.0
	icon.anchor_bottom = 1.0
	for side in ["left", "top"]:
		icon.set("margin_" + side, 4)
	for side in ["right", "bottom"]:
		icon.set("margin_" + side, -4)
	panel.add_child(icon)
	var label := Label.new()
	label.anchor_top = 1.0
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.align = Label.ALIGN_CENTER
	label.add_color_override("font_color", Color.white)
	label.add_color_override("font_color_shadow", Color.black)
	panel.add_child(label)

	var id := ""
	var flags := 0
	if typeof(entry) == TYPE_ARRAY and entry.size() == 2:
		id = str(entry[0])
		flags = int(entry[1])
	var item = find_item(id) if id != "" else null
	if flags & FLAG_RANDOM:
		icon.texture = random_icon
	elif flags & FLAG_LOCKED and flags & FLAG_SPECIAL:
		icon.texture = load(LOCKED_ICON_PATH) if ResourceLoader.exists(LOCKED_ICON_PATH) else null
		icon.modulate.a = 0.5
	elif item != null:
		icon.texture = item.get_icon()
		if flags & FLAG_SPECIAL:
			icon.modulate = Color(0.5, 0.5, 0.5, 0.5)
	if icon.texture == null:
		var unknown := Label.new()
		unknown.text = "?"
		unknown.align = Label.ALIGN_CENTER
		unknown.valign = Label.VALIGN_CENTER
		unknown.anchor_right = 1.0
		unknown.anchor_bottom = 1.0
		panel.add_child(unknown)
	return {"style": style, "label": label, "item": item}


func find_item(my_id: String):
	if _items.empty():
		for list in [
			ItemService.characters, ItemService.weapons, ItemService.items, ItemService.difficulties
		]:
			for element in list:
				_items[element.my_id] = element
	return _items.get(my_id)


# Paths come from the network: only game textures.
static func _load_texture(path):
	if typeof(path) != TYPE_STRING or not path.begins_with("res://") or ".." in path:
		return null
	if not ResourceLoader.exists(path):
		return null
	var texture = load(path)
	return texture if texture is Texture else null
