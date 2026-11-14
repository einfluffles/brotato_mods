extends Control
# Client screen outside battle and shop: connection status, plus — while the host is in a menu —
# the host's selection grid with every player's cursor (ui/selection_grid.gd) and one card per
# player showing what that player's cursor is on (the game's own ItemPanelUI) and whether
# they're ready. Replaces the local game scene so the client's own menus don't react to
# its input (all input goes to the host).

const TitleBackground := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/title_background.gd"
)
const SelectionGrid := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/selection_grid.gd"
)
const CoopSelection := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_selection.gd"
)
const ITEM_PANEL_SCENE := "res://ui/menus/ingame/item_panel_ui.tscn"
const LOCKED_PANEL_SCENE := "res://ui/menus/run/locked_panel.tscn"
const MAX_SLOTS := 4
const MAX_LOCK_TEXT := 600
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
var _panels := []  # per player: {box, label: Label, panel: ItemPanelUI, locked: LockedPanel}
var _open_slots := []  # free co-op slots while joining is open: {box, label, hint, progress}
var _color_hint := CoopSelection.color_hint_row()
var _age := 0.0


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	add_child(TitleBackground.new())
	var column := VBoxContainer.new()
	column.anchor_right = 1.0
	column.anchor_bottom = 1.0
	column.alignment = BoxContainer.ALIGN_CENTER
	column.add_constant_override("separation", 24)
	add_child(column)
	for label in [_status, _title]:
		label.align = Label.ALIGN_CENTER
		column.add_child(label)
	_color_hint.visible = false
	column.add_child(_color_hint)
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
	var you: int = int(state.get("you", -1)) if typeof(state.get("you")) == TYPE_INT else -1
	var reward: int = int(state.get("reward", -1)) if typeof(state.get("reward")) == TYPE_INT else -1
	for p in count:
		_update_card(_panels[p], p, state.players[p], p == you, reward)
	_update_open_slots(count, state.get("join"), state.get("max"), you < 0)
	_color_hint.visible = state.kind == "character_selection" and you >= 0
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
	return {"box": box, "label": label, "panel": panel, "locked": null}


func _update_card(card: Dictionary, p: int, entry, is_you: bool, reward: int) -> void:
	if typeof(entry) != TYPE_ARRAY or entry.size() < 4:
		return
	var id: String = str(entry[0])
	var ready: bool = bool(entry[3])
	card.label.text = "P%d%s%s" % [p + 1, " (you)" if is_you else "", "  ✓ ready" if ready else ""]
	card.label.add_color_override("font_color", CoopService.get_player_color(p))
	var panel = card.panel
	panel.player_color_index = p
	panel.selected = ready
	var item = _find_any(id) if id != "" else null
	var shown_locked := _show_locked(card, p, entry, item, reward)
	panel.visible = not shown_locked
	if shown_locked:
		return
	if bool(entry[2]):
		panel._show_random()
		return
	if item != null:
		panel.set_data(item, p)
	else:
		# Not available on this machine (e.g. DLC) or not an item (a button).
		panel.set_custom_data(id if id != "" else str(entry[1]), null)


# Locked element under the cursor: the game's LockedPanel with how to unlock it (the client's
# own challenge text, localised; else the text the host's LockedPanel shows, e.g. item set).
func _show_locked(card: Dictionary, p: int, entry: Array, item, reward: int) -> bool:
	var text := ""
	var by_challenge := false
	if entry.size() >= 8 and typeof(entry[6]) == TYPE_STRING and typeof(entry[7]) == TYPE_BOOL:
		text = entry[6].substr(0, MAX_LOCK_TEXT)
		by_challenge = entry[7]
	var challenge = null
	if by_challenge and item != null and reward >= 0:
		challenge = ChallengeService.find_challenge_from_reward(reward, item)
	if text == "" and not by_challenge:
		if card.locked != null:
			card.locked.visible = false
		return false
	if card.locked == null:
		card.locked = load(LOCKED_PANEL_SCENE).instance()
		card.box.add_child(card.locked)
	card.locked.visible = true
	card.locked.player_color_index = p
	if challenge != null:
		card.locked.set_element(item, reward)
	else:
		card.locked.set_description(text if text != "" else "Locked")
		card.locked.get_node("MarginContainer/VBoxContainer/Icon").visible = by_challenge
	return true


# Character selection while the host lets players join: the free slots, each with the game's
# "Hold {0} or {1} to join" (its accept glyphs) and the hold progress of anyone joining.
func _update_open_slots(count: int, join, max_players, highlight: bool) -> void:
	var open := 0
	if typeof(join) == TYPE_ARRAY and typeof(max_players) == TYPE_INT:
		open = int(clamp(max_players, 0, MAX_SLOTS)) - count
	while _open_slots.size() > max(open, 0):
		var removed: Dictionary = _open_slots.pop_back()
		removed.box.queue_free()
	while _open_slots.size() < open:
		_open_slots.append(_new_open_slot())
	for i in _open_slots.size():
		var slot: Dictionary = _open_slots[i]
		var p: int = count + i
		slot.label.text = Text.text("COOP_PLAYER", [str(p + 1)])
		slot.label.add_color_override("font_color", CoopService.get_player_color(p))
		var progress = join[i] if i < join.size() else null
		if typeof(progress) == TYPE_REAL or typeof(progress) == TYPE_INT:
			slot.progress.text = "%d%%" % int(clamp(progress, 0.0, 1.0) * 100.0)
		else:
			slot.progress.text = ""
		slot.hint.modulate.a = 1.0 if highlight else 0.6


func _new_open_slot() -> Dictionary:
	var box := VBoxContainer.new()
	box.rect_min_size = Vector2(300, 0)
	box.alignment = BoxContainer.ALIGN_CENTER
	var label := Label.new()
	label.align = Label.ALIGN_CENTER
	box.add_child(label)
	var hint := join_hint_row()
	box.add_child(hint)
	var progress := Label.new()
	progress.align = Label.ALIGN_CENTER
	box.add_child(progress)
	_cards.add_child(box)
	return {"box": box, "label": label, "hint": hint, "progress": progress}


# The game's COOP_HOLD_TO_JOIN ("Hold {0} or {1} to join"): {0} pad accept, {1} keyboard accept.
static func join_hint_row() -> HBoxContainer:
	var text := TranslationServer.translate("COOP_HOLD_TO_JOIN")
	if not ("{0}" in text and "{1}" in text):
		text = "Hold {0} or {1} to join"
	var icons := {
		"{0}": CoopService.get_input_type_key_texture(
			"ui_accept", CoopService.PlayerType.GAMEPAD_XBOX, 0
		),
		"{1}": CoopService.get_input_type_key_texture(
			"ui_accept", CoopService.PlayerType.KEYBOARD_AND_MOUSE, 0
		),
	}
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGN_CENTER
	row.add_constant_override("separation", 8)
	var rest := text
	while rest != "":
		var at0 := rest.find("{0}")
		var at1 := rest.find("{1}")
		var at: int = at0 if at1 < 0 or (at0 >= 0 and at0 < at1) else at1
		var words: String = rest if at < 0 else rest.substr(0, at)
		if words.strip_edges() != "":
			var label := Label.new()
			label.text = words.strip_edges()
			row.add_child(label)
		if at < 0:
			break
		CoopSelection.add_icon(row, icons[rest.substr(at, 3)])
		rest = rest.substr(at + 3)
	return row


static func _find_any(my_id: String):
	for list in [
		ItemService.characters, ItemService.weapons, ItemService.items, ItemService.difficulties
	]:
		for element in list:
			if element.my_id == my_id:
				return element
	return null
