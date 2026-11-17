extends Reference
# What the mod adds to the host's co-op character selection takes no space from the game's
# layout (ui/coop_mode.gd, ui/slot_invite.gd):
#  - the Co-op row (Off / Local / Online) takes the place and the rect of the game's Co-op toggle:
#    the run options box, its other rows, the player panels and the grid get their vanilla rects,
#    the grid scrolls no further;
#  - Invite friends and the lobby status in the next free player slot: every slot keeps its rect,
#    nothing of it is over "Player N", the join hint or the join progress, and it stays inside
#    its slot and on screen, also with a long status line;
#  - their texts are shown whole (the row's three values, the button; the usual status lines).
# Checked at the viewport sizes of the colour hint's check (coop_selection_tests.gd). How the
# cursor reaches them and what the values do: lobby_menu_tests.gd.
# Run from coop_selection_tests.gd on the host's co-op character selection (no Steam).

# coop_selection_tests.gd preloads this file: loaded when used (no cyclic preload).
const HELPERS_PATH := "res://mods-unpacked/einfluffles-TogetherTests/coop_selection_tests.gd"
const CoopSelection := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_selection.gd"
)
const CoopMode := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/coop_mode.gd")
const SlotInvite := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/slot_invite.gd")
# Status lines the slot must hold without growing: the longest count, an error, and a long text
# like a translation or Steam's error message would be.
const STATUSES := [
	"Online: 4 players",
	"! createLobby failed",
	"Online: a much longer status line than any of the mod's own, as a translation could be",
]

var t: Node = null  # the test mod: _check()
var helpers = null  # coop_selection_tests.gd: SIZES, _layout_rects(), _stretch_tree()


func run(test_mod: Node, scene: Node, where := "host"):
	t = test_mod
	helpers = load(HELPERS_PATH)
	var coop: Control = scene.get_node("%CoopButton")
	var mode: OptionButton = coop.get_parent().get_node_or_null(CoopMode.NODE_NAME)
	t._check(
		mode != null and mode.visible and not coop.visible
		and mode.get_index() == coop.get_index() + 1,
		"co-op row (%s): in the place of the game's Co-op toggle, which is hidden" % where
	)
	if mode == null:
		yield(_frames(1), "completed")
		return
	var panels: Array = scene._get_coop_join_panels()
	var slot: int = CoopService.connected_players.size()
	var invite: Control = panels[slot].get_node_or_null(SlotInvite.NODE_NAME)
	t._check(
		invite != null and panels[slot].visible and not invite.visible,
		"slot invite (%s): in slot %d, hidden without a lobby" % [where, slot + 1]
	)
	if invite == null:
		yield(_frames(1), "completed")
		return
	mode.set_process(false)  # it sets what is shown every frame
	invite.button.visible = true  # hosting
	var dlc: Node = scene.get_node_or_null("%ItemSetBar")  # as co-op lays it out
	var vertical: bool = dlc != null and not dlc._horizontal
	if vertical:
		dlc.set_horizontal(true)
	var base := Vector2(
		ProjectSettings.get_setting("display/window/size/width"),
		ProjectSettings.get_setting("display/window/size/height")
	)
	var failures := []
	for size in helpers.SIZES:
		for status in STATUSES:
			invite.set_status(status)
			helpers._stretch_tree(t.get_tree(), size)
			_vanilla(mode, coop, invite, true)
			yield(_frames(3), "completed")
			var vanilla := _rects(scene)
			var toggle: Rect2 = coop.get_global_rect()
			_vanilla(mode, coop, invite, false)
			yield(_frames(3), "completed")
			var shown := _rects(scene)
			var at := "%dx%d, %s" % [size.x, size.y, status]
			if shown.rects != vanilla.rects:
				failures.append("%s: layout moved (%s vs %s)" % [at, shown.rects, vanilla.rects])
			if shown.scroll > vanilla.scroll:
				failures.append(
					"%s: grid scrolls %d instead of %d" % [at, shown.scroll, vanilla.scroll]
				)
			if mode.get_global_rect() != toggle:
				failures.append("%s: co-op row %s, toggle %s" % [at, mode.get_global_rect(), toggle])
			failures += _slot_overlaps(scene, panels[slot], invite, at, _wide_enough(size))
	helpers._stretch_tree(t.get_tree(), base)
	invite.set_status(STATUSES[0])
	yield(_frames(3), "completed")
	var cut := []
	for i in mode.get_item_count():
		cut += _cut(mode, mode.get_item_text(i), _option_room(mode))
	cut += _cut(invite.button, invite.button.text, text_room(invite.button))
	cut += _cut(invite.status, invite.status.text, text_room(invite.status))
	t._check(cut.empty(), "co-op row, slot invite (%s): texts shown whole %s" % [where, cut])
	print(
		"  info: at %s: co-op row %s (zone %s), slot %d %s: invite %s, button %s, status %s"
		% [base, mode.get_global_rect(), scene.get_node("%ZoneSelectionButton").get_global_rect(),
		slot + 1, panels[slot].get_global_rect(), invite.get_global_rect(),
		invite.button.get_global_rect(), invite.status.get_global_rect()]
	)
	if vertical:
		dlc.set_horizontal(false)
	invite.visible = false
	mode.set_process(true)
	yield(_frames(3), "completed")
	t._check(
		failures.empty(),
		"co-op row, slot invite (%s): vanilla rects for the box, its rows, the slots and the grid,"
		% where
		+ " no extra grid scrolling, the invite inside its slot over nothing, at %s %s"
		% [helpers.SIZES, failures]
	)


func _frames(count: int):
	for _i in count:
		yield(t.get_tree(), "idle_frame")


# vanilla: the game's Co-op toggle instead of the row, no invite.
static func _vanilla(mode: Control, coop: Control, invite: Control, vanilla: bool) -> void:
	mode.visible = not vanilla
	coop.visible = vanilla
	invite.visible = not vanilla


# The layout's rects (coop_selection_tests.gd) plus the run options box, its rows but the Co-op
# one, and the player slots.
static func _rects(scene: Node) -> Dictionary:
	var layout: Dictionary = load(
		"res://mods-unpacked/einfluffles-TogetherTests/coop_selection_tests.gd"
	)._layout_rects(scene)
	var coop: Control = scene.get_node("%CoopButton")
	var box: Control = scene.get_node("%RunOptionsPanel")
	layout.rects.append([box.name, box.get_global_rect()])
	for row in coop.get_parent().get_children():
		if row is Control and row.visible and row != coop and row.name != CoopMode.NODE_NAME:
			layout.rects.append([row.name, row.get_global_rect()])
	var slots := "MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer"
	for panel in scene.get_node(slots).get_children():
		if panel is Control and panel.visible:
			layout.rects.append([panel.name, panel.get_global_rect()])
	return layout


# The invite inside its slot, on screen (where the game's layout fits it), over none of the
# slot's own parts ("Player N", the join hint, the join progress).
static func _slot_overlaps(
	scene: Node, panel: Control, invite: Control, at: String, on_screen: bool
) -> Array:
	var failures := []
	var parts := [invite.button, invite.status]
	var others := []
	for name in [CoopSelection.SLOT_LABEL]:
		others.append(panel.get_node_or_null(name))
	others.append(panel.get("_coop_join_instructions"))
	others.append(panel.get("_coop_join_progress"))
	for part in parts:
		var rect: Rect2 = part.get_global_rect()
		if not panel.get_global_rect().encloses(rect):
			failures.append("%s: %s %s outside its slot %s" % [
				at, part.name, rect, panel.get_global_rect()
			])
		if on_screen and not scene.get_viewport().get_visible_rect().encloses(rect):
			failures.append("%s: %s %s off screen" % [at, part.name, rect])
		for other in others:
			if other is Control and other.is_visible_in_tree():
				if rect.intersects(other.get_global_rect()):
					failures.append("%s: %s %s over %s %s" % [
						at, part.name, rect, other.name, other.get_global_rect()
					])
	if invite.button.get_global_rect().intersects(invite.status.get_global_rect()):
		failures.append("%s: the button over the status" % at)
	return failures


# The game lays out a 1920 px wide screen and stretches it to any window (2d / keep). Narrower
# layouts (1280x720 here): its own row of panels (1859 px) runs off screen there.
static func _wide_enough(size: Vector2) -> bool:
	return size.x >= ProjectSettings.get_setting("display/window/size/width")


static func _cut(control: Control, text: String, room: Vector2) -> Array:
	var size: Vector2 = control.get_font("font").get_string_size(text)
	if size.x > room.x or size.y > room.y:
		return ["%s %s in %s" % [text, size, room]]
	return []


# The space a button's / label's text has: its size less the style's margins.
static func text_room(control: Control) -> Vector2:
	var style: StyleBox = control.get_stylebox("normal")
	return control.rect_size - style.get_minimum_size()


# An OptionButton's: less its arrow and the arrow's margin as well.
static func _option_room(button: OptionButton) -> Vector2:
	var room := text_room(button)
	room.x -= button.get_icon("arrow").get_width() + button.get_constant("arrow_margin")
	return room
