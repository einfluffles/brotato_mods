extends Control
# Client screen outside battle and shop: connection status, plus — while the host is in a menu —
# the host's selection grid with every player's cursor (ui/selection_grid.gd) and one card per
# player showing what that player's cursor is on (the game's own ItemPanelUI) and whether
# they're ready. Replaces the local game scene so the client's own menus don't react to
# its input (all input goes to the host).

const SelectionGrid := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/selection_grid.gd"
)
const ITEM_PANEL_SCENE := "res://ui/menus/ingame/item_panel_ui.tscn"
# Between two mirrored screens (battle -> shop) the view may show for a moment: stay neutral
# instead of flashing "Waiting for the host" unless nothing arrives for this long.
const WAITING_DELAY_SEC := 1.5
const KIND_TITLES := {
	"character_selection": "Character selection",
	"weapon_selection": "Weapon selection",
	"difficulty_selection": "Difficulty selection",
	"coop_end_run": "End of run",
	"title_screen": "The host is in the main menu",
}

var session: Node = null

var _status := Label.new()
var _title := Label.new()
var _grid := SelectionGrid.new()
var _cards := HBoxContainer.new()
var _panels := []  # per player: {label: Label, panel: ItemPanelUI}
var _age := 0.0


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	var background := ColorRect.new()
	background.color = Color(0.08, 0.08, 0.1)
	background.anchor_right = 1.0
	background.anchor_bottom = 1.0
	add_child(background)
	var column := VBoxContainer.new()
	column.anchor_right = 1.0
	column.anchor_bottom = 1.0
	column.alignment = BoxContainer.ALIGN_CENTER
	column.add_constant_override("separation", 24)
	add_child(column)
	for label in [_status, _title]:
		label.align = Label.ALIGN_CENTER
		column.add_child(label)
	_grid.alignment = BoxContainer.ALIGN_CENTER
	_grid.visible = false
	column.add_child(_grid)
	_cards.alignment = BoxContainer.ALIGN_CENTER
	_cards.add_constant_override("separation", 32)
	column.add_child(_cards)


func _process(delta: float) -> void:
	_age += delta
	if session == null:
		return
	var host_id: int = session.transport.host_id
	var host_name := "host"
	var rtt := "-"
	if session.peers.has(host_id):
		host_name = session.peers[host_id].name
		if session.peers[host_id].rtt_ms >= 0:
			rtt = "%d ms" % session.peers[host_id].rtt_ms
	_status.text = "brotato:together — connected to %s (rtt %s) — F9: menu" % [host_name, rtt]
	if _panels.empty() and _title.text == "" and _age >= WAITING_DELAY_SEC:
		_title.text = "Waiting for the host…"


func show_menu(state: Dictionary) -> void:
	_title.text = KIND_TITLES.get(state.kind, "The host is in a menu (%s)" % state.kind)
	var count: int = min(int(state.get("count", 0)), state.players.size())
	if RunData.get_player_count() < count:
		RunData.set_player_count(count)  # item descriptions read per-player stats
	while _panels.size() > count:
		var removed: Dictionary = _panels.pop_back()
		removed.box.queue_free()
	while _panels.size() < count:
		_panels.append(_new_card())
	for p in count:
		_update_card(_panels[p], p, state.players[p], p == int(state.get("you", -1)))
	_grid.set_grids(state.get("grids", {}))
	_grid.set_cursors(state.players)
	_grid.visible = _grid.inventory_count() > 0


func _new_card() -> Dictionary:
	var box := VBoxContainer.new()
	var label := Label.new()
	label.align = Label.ALIGN_CENTER
	box.add_child(label)
	var panel = load(ITEM_PANEL_SCENE).instance()
	box.add_child(panel)
	_cards.add_child(box)
	return {"box": box, "label": label, "panel": panel}


func _update_card(card: Dictionary, p: int, entry, is_you: bool) -> void:
	if typeof(entry) != TYPE_ARRAY or entry.size() < 4:
		return
	var id: String = str(entry[0])
	var ready: bool = bool(entry[3])
	card.label.text = "P%d%s%s" % [p + 1, " (you)" if is_you else "", "  ✓ ready" if ready else ""]
	var panel = card.panel
	panel.player_color_index = p
	panel.selected = ready
	if bool(entry[2]):
		panel._show_random()
		return
	var item = _find_any(id) if id != "" else null
	if item != null:
		panel.set_data(item, p)
	else:
		# Not available on this machine (e.g. DLC) or not an item (a button).
		panel.set_custom_data(id if id != "" else str(entry[1]), null)


static func _find_any(my_id: String):
	for list in [
		ItemService.characters, ItemService.weapons, ItemService.items, ItemService.difficulties
	]:
		for element in list:
			if element.my_id == my_id:
				return element
	return null
