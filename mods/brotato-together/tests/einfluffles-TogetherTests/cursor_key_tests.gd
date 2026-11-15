extends Reference
# Suite cursor_key: FocusSync.state_key does not describe the cursors (that costs about 0.4 ms
# in a two-player shop, 20 checks a second); it stands for them by identities and child indices.
# Pinned here as a property on the real screens: after a change, what a peer has (the body the
# stream sent when the key last changed) is what the host describes now, at the latest one
# check later (a sibling queued for deletion counts in the key until it is freed). A change of
# the description that the key cannot see is caught by FocusSync's safety net (a full
# description compared every SAFETY_NET_MSEC), checked here by backdating it.
# The shop runs in this suite (on mod_main's two-player run); run_upgrades and run_retry are
# called by the battle loopback (level-up / crate panels) and the menu suite (retry prompt) on
# the screens they build. Checks go through t._check.

const FocusSync := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/focus_sync.gd")
const ShopIntents := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/shop_intents.gd"
)
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const PISTOL := "weapon_pistol_1"

var t: Node  # the test mod: _check, helpers, scene tree
var _focus_sync: Node = null
# What a peer has: the key of the last send and the cursors described then (var2str).
var _sent_key := ""
var _sent := ""
var _sends := 0
var _extra := []  # labels of harmless extra sends (key changed, description did not)


func _init(test_mod: Node, together: Node) -> void:
	t = test_mod
	_focus_sync = together.focus_sync


# --- the property ---


# One check of the stream: the key every time, the body only when the key changed. True when
# the peer's cursors are stale (the description changed under an unchanged key).
func _check_now() -> bool:
	var key: String = _focus_sync.state_key(StateStream.CURSORS)
	if key != _sent_key:
		_sent_key = key
		_sent = _body()
		_sends += 1
		return false
	return key != "" and var2str(_focus_sync._cursors()) != _sent


func _body() -> String:
	if _sent_key == "":
		return ""
	return var2str(_focus_sync.state_body(StateStream.CURSORS).cursors)


# The peer is up to date before a mutation (sent twice: a body that finds a change under the
# same key moves the key); the safety net is not due (only backdated where a test means it).
func _baseline() -> void:
	for _i in 2:
		_sent_key = _focus_sync.state_key(StateStream.CURSORS)
		_sent = _body()
	_focus_sync._net_msec = OS.get_ticks_msec()


# What a peer sees through the mutation just made: checks right away (same frame) and after each
# of frames idle frames. "same": nothing changed, nothing sent; "sent": the change went out at
# the first check; "extra": sent though the description is the same (harmless); "late": stale at
# the first check, sent by a later one; "stale": still stale at the last check.
# With frames > 0 it yields (call it through yield(..., "completed")).
func _settle(frames: int):
	var before := _sent
	var sends := _sends
	var first := _check_now()
	var stale := first
	for _i in frames:
		yield(t.get_tree(), "idle_frame")
		stale = _check_now()
	if stale:
		return "stale"
	if first:
		return "late"
	if _sends == sends:
		return "same"
	return "sent" if _sent != before else "extra"


func _expect(label: String, verdict: String, allowed: Array) -> void:
	if verdict == "extra":
		_extra.append(label)
	t._check(
		verdict in allowed,
		"cursor key: %s -> %s (description change implies key change)" % [label, verdict]
	)


# A change only the description sees: stale under the key, then caught by the safety net.
func _expect_net(label: String, verdict: String) -> void:
	var missed: int = _focus_sync.missed
	_focus_sync._net_msec -= FocusSync.SAFETY_NET_MSEC
	var caught := not _check_now()
	t._check(
		verdict == "stale" and caught and _focus_sync.missed == missed + 1,
		"cursor key: %s -> %s under the key, sent by the safety net: %s" % [label, verdict, caught]
	)


# --- suite cursor_key: the co-op shop ---


func run_shop():
	CoopService.connected_players.clear()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	var pistol = t._find_by_id(ItemService.weapons, PISTOL)
	RunData.players_data[0].weapons.clear()
	for _i in 3:
		RunData.add_weapon(pistol, 0)
	for p in 2:
		RunData.add_gold(3000, p)
	t.get_tree().change_scene(RunData.get_shop_scene_path())
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var shop := t.get_tree().current_scene
	t._check(shop.has_method("_get_coop_player_container"), "cursor key: co-op shop loaded")
	var e0 = Utils.get_focus_emulator(0, shop)
	var e1 = Utils.get_focus_emulator(1, shop)
	var slots: Array = shop._get_shop_items_container(0)._shop_items
	e0.focused_control = slots[0]._button
	e1.focused_control = shop._get_reroll_button(1)
	_baseline()
	t._check(_sent_key != "" and _sent.find("shop_item") >= 0, "cursor key: shop cursors described")

	yield(_shop_cursor_moves(shop, e0, e1), "completed")
	yield(_shop_actions(shop, e0), "completed")
	_shop_player_count(shop, e1)
	yield(_shop_inventory(shop, e0), "completed")
	_shop_named_steps(shop, e0)
	_shop_anchors(shop, e0)
	yield(_shop_combine(shop, e0), "completed")
	yield(_shop_last(shop, e1), "completed")
	print("  info: cursor key: harmless extra sends: %s" % [_extra])


func _shop_cursor_moves(shop: Node, e0: Node, e1: Node):
	_baseline()
	e0.focused_control = shop._get_go_button(0)
	_expect("cursor moves to another control", _settle(0), ["sent"])
	e0.focused_control = shop._get_go_button(1)
	_expect("cursor moves into another player's panel", _settle(0), ["sent"])
	e1.focused_control = null
	_expect("an emulator loses its cursor", _settle(0), ["sent"])
	e1.focused_control = shop._get_reroll_button(1)
	_expect("an emulator takes a cursor", _settle(0), ["sent"])
	e0.focused_control = shop._get_go_button(0)
	yield(_settle(1), "completed")


# Real game actions under a resting cursor: buy (slot nodes stay, the bought one empties),
# reroll, the inventory popup opened by a press on a weapon and closed by its cancel button.
func _shop_actions(shop: Node, e0: Node):
	var container = shop._get_shop_items_container(0)
	e0.focused_control = container._shop_items[2]._button
	_baseline()
	var gold: int = RunData.get_player_gold(0)
	ShopIntents._press(container._shop_items[1]._button, 0)  # the buy runs deferred
	var verdict = yield(_settle(2), "completed")
	_expect("buy slot 1, cursor on slot 2", verdict, ["same", "sent", "extra"])
	t._check(RunData.get_player_gold(0) < gold, "cursor key: the buy went through")
	_baseline()
	var rerolls: int = shop._reroll_count[0]
	ShopIntents._press(shop._get_reroll_button(0), 0)
	verdict = yield(_settle(2), "completed")
	_expect("reroll, cursor on slot 2", verdict, ["same", "sent", "extra"])
	t._check(shop._reroll_count[0] == rerolls + 1, "cursor key: the reroll went through")

	var elements = shop._get_gear_container(0).weapons_container._elements
	var popup = shop._get_item_popup(0)
	e0.focused_control = elements.get_child(1)
	_baseline()
	FocusEmulatorSignal.emit(elements.get_child(1), "pressed", 0)
	verdict = yield(_settle(2), "completed")
	_expect("press a weapon: its popup opens", verdict, ["same", "sent", "extra"])
	if not popup.is_a_parent_of(e0.focused_control):
		e0.focused_control = popup._cancel_button  # the popup's own buttons, in any case
		yield(_settle(1), "completed")
	print("  info: cursor key: cursor in the open popup: %s" % [_sent])
	_baseline()
	ShopIntents._press(popup._cancel_button, 0)
	verdict = yield(_settle(2), "completed")
	_expect("popup closed by cancel", verdict, ["same", "sent", "extra"])


# The player count picks which anchors exist: player 1's go button is shop_go 1 with two
# players and a path from the scene with one. Same frame, put back before anything runs.
func _shop_player_count(shop: Node, e1: Node) -> void:
	e1.focused_control = shop._get_go_button(1)
	_settle(0)
	_baseline()
	var player = RunData.players_data.pop_back()
	var verdict = _settle(0)
	RunData.players_data.push_back(player)
	_expect("player count 2 -> 1", verdict, ["sent"])
	_expect("player count 1 -> 2", _settle(0), ["sent"])


# [type, k] steps in a list built by code (player 0's weapons, InventoryElement): siblings added
# by code before the cursor's element, removed, queued for deletion, of another kind, re-scripted,
# given an owner.
func _shop_inventory(shop: Node, e0: Node):
	var elements = shop._get_gear_container(0).weapons_container._elements
	var element: Node = elements.get_child(elements.get_child_count() - 1)
	e0.focused_control = element
	_settle(0)
	var added: Node = _add_element(elements)
	_expect("a like element added by code before it", _settle(0), ["sent"])
	elements.remove_child(added)
	added.free()
	_expect("that element removed (and freed)", _settle(0), ["sent"])

	var queued: Node = _add_element(elements)
	_baseline()
	queued.queue_free()
	var verdict = yield(_settle(1), "completed")
	_expect("a like element before it queued for deletion, freed next frame", verdict, ["late"])

	var button := Button.new()  # another mod's node: another kind
	elements.add_child(button)
	elements.move_child(button, 0)
	_expect("a node of another kind added before it", _settle(0), ["extra"])
	elements.remove_child(button)
	button.free()
	_settle(0)

	# Queued (late at the first check), freed at the end of the frame, and before the next check
	# a node of another kind takes its child index: the key is back where it was sent.
	queued = _add_element(elements)
	_baseline()
	queued.queue_free()
	var late := _check_now()
	yield(t.get_tree(), "idle_frame")
	button = Button.new()
	elements.add_child(button)
	elements.move_child(button, 0)
	verdict = _settle(0)
	t._check(late, "cursor key: the queued element: stale at the first check")
	_expect_net("a like element queued, freed, its index taken by another kind", verdict)
	elements.remove_child(button)
	button.free()
	_settle(0)
	# The same without a queue: one removed and one of another kind added in one check interval.
	var removed: Node = _add_element(elements)
	_baseline()
	elements.remove_child(removed)
	removed.free()
	button = Button.new()
	elements.add_child(button)
	elements.move_child(button, 0)
	_expect_net("a like element replaced by another kind at its index", _settle(0))
	elements.remove_child(button)
	button.free()
	_settle(0)

	var changed: Node = _add_element(elements)
	_baseline()
	changed.set_script(null)  # now a plain Button: not counted as an InventoryElement
	_expect_net("a like element before it loses its script", _settle(0))
	elements.remove_child(changed)
	changed.free()
	_settle(0)

	# An owner alone keeps a generated "@" name unnamed; with a plain name it is named, not counted.
	var owned: Node = _add_element(elements)
	_baseline()
	owned.owner = shop
	_expect("a like element (generated name) before it gets an owner", _settle(0), ["same"])
	owned.owner = null
	owned.name = "ModElement"
	_expect("that element gets a plain name, no owner", _settle(0), ["same"])
	_baseline()
	owned.owner = shop
	_expect_net("a like element with a plain name before it gets an owner", _settle(0))
	elements.remove_child(owned)
	owned.free()
	_settle(0)


# A like element (the game's own add_special_element, unsorted) as the first child.
func _add_element(elements: Node) -> Node:
	elements.add_special_element(elements.locked_icon, false, 1.0, null, false)
	var added: Node = elements.get_child(elements.get_child_count() - 1)
	elements.move_child(added, 0)
	return added


# Named steps: another mod's panel ("ModPanel" with "ModButton", both owned by the scene) with
# the cursor on its button: renamed, owner cleared, reparented at the same child indices,
# detached from the scene.
func _shop_named_steps(shop: Node, e0: Node) -> void:
	var panel := _named(Control.new(), "ModPanel", shop, shop)
	var button := _named(Button.new(), "ModButton", panel, shop)
	e0.focused_control = button
	_settle(0)
	t._check(_sent.find("ModButton") >= 0, "cursor key: a mod's button described by its names")
	_baseline()
	panel.name = "ModPanelRenamed"
	_expect_net("a named node on the path renamed", _settle(0))
	panel.name = "ModPanel"
	_settle(0)
	_baseline()
	panel.owner = null  # now a node added by code: [Control, k]
	_expect_net("a node on the path loses its owner", _settle(0))
	panel.owner = shop
	_settle(0)

	# The same child indices under another node: the indices and ids in the key stay the same.
	var other := Control.new()
	other.name = "OtherPanel"
	_baseline()
	var index := panel.get_index()
	shop.remove_child(panel)
	shop.add_child(other)
	shop.move_child(other, index)
	other.owner = shop
	panel.remove_child(button)
	other.add_child(button)
	button.owner = shop
	_expect_net("the control reparented at the same child indices", _settle(0))
	other.remove_child(button)
	panel.add_child(button)
	button.owner = shop
	shop.remove_child(other)
	other.free()
	shop.add_child(panel)
	shop.move_child(panel, index)
	panel.owner = shop
	_settle(0)

	_baseline()
	panel.remove_child(button)
	_expect("the control detached from the scene", _settle(0), ["sent"])
	panel.add_child(button)
	button.owner = shop
	_expect("and back", _settle(0), ["sent"])
	e0.focused_control = shop._get_go_button(0)
	shop.remove_child(panel)
	panel.free()
	_settle(0)


func _named(node: Node, name: String, parent: Node, owner: Node) -> Node:
	node.name = name
	parent.add_child(node)
	node.owner = owner
	return node


# The anchors are the game's fixed nodes (onready vars, ShopItemsContainer._shop_items built at
# _ready); if another mod swapped them, the key would not see it.
func _shop_anchors(shop: Node, e0: Node) -> void:
	var items: Array = shop._get_shop_items_container(0)._shop_items
	e0.focused_control = items[0]._button
	_settle(0)
	_baseline()
	var first = items[0]
	items[0] = items[1]
	items[1] = first
	_expect_net("the shop items list reordered (nodes reused)", _settle(0))
	items[1] = items[0]
	items[0] = first
	_settle(0)

	var panel = shop._get_coop_player_container(0)
	var popup = panel.item_popup
	e0.focused_control = popup._cancel_button
	_settle(0)
	_baseline()
	panel.item_popup = shop._get_go_button(0)  # the accessor hands out another node
	_expect_net("an accessor returns another node", _settle(0))
	panel.item_popup = popup
	_settle(0)


# Combine (the popup's own signal, as an intent applies it): the two combined elements are
# queued for deletion and the new weapon is added; the cursor rests on another weapon after them.
func _shop_combine(shop: Node, e0: Node):
	var elements = shop._get_gear_container(0).weapons_container._elements
	var weapons: Array = RunData.get_player_weapons(0).duplicate()
	var combined = weapons[0]
	var partner = shop._get_combine_partner(combined, 0)
	var rest: Node = null
	for element in elements.get_children():
		if not element.item in [combined, partner]:
			rest = element
	t._check(partner != null and rest != null, "cursor key: two pistols to combine and a third")
	if partner == null or rest == null:
		return
	e0.focused_control = rest
	_settle(0)
	_baseline()
	shop._get_item_popup(0).emit_signal("item_combine_button_pressed", combined)
	var verdict = yield(_settle(3), "completed")
	_expect("combine two pistols, cursor on another weapon", verdict, ["same", "sent", "late"])
	t._check(
		RunData.get_player_weapons(0).size() == weapons.size() - 1,
		"cursor key: the combine went through"
	)
	print("  info: cursor key: after the combine: %s" % [_sent])


# What ends the shop's run: an emulator freed while its scene stays, the scene replaced by
# another instance of itself (the cursors must go out again for the client's new scene).
func _shop_last(shop: Node, e1: Node):
	_baseline()
	e1.get_parent().remove_child(e1)
	e1.free()
	_expect("an emulator freed, its scene stays", _settle(0), ["sent"])
	_baseline()
	t.get_tree().change_scene(RunData.get_shop_scene_path())
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var reloaded := t.get_tree().current_scene
	t._check(reloaded != shop, "cursor key: the shop reloaded")
	var e0 = Utils.get_focus_emulator(0, reloaded)
	e0.focused_control = reloaded._get_go_button(0)
	_expect("the scene replaced by another instance of it", _settle(0), ["sent", "extra"])


# --- level-up / crate panels (battle loopback, after its host part) ---


# ui: main's UpgradesUI. Player 0 gets a new level-up (the game reuses the option nodes); the
# cursor rests on option 3 while the options are rolled and option 1 is taken, then moves into
# player 1's panel; the options list reordered by another mod is the safety net's.
func run_upgrades(ui: Node, level: int):
	var level_up = UpgradesUI.UpgradeToProcess.new()
	level_up.level = level
	level_up.player_index = 0
	var container = ui._get_player_container(0)
	var options: Array = container._get_upgrade_uis()
	var e0 = container.focus_emulator
	e0.focused_control = options[2].button
	_settle(0)
	_baseline()
	ui.show_options([[], [], [], []], [[level_up], [], [], []])
	var verdict = yield(_settle(1), "completed")
	_expect("level-up: options rolled, cursor on option 3", verdict, ["same", "sent", "extra"])
	e0.focused_control = options[2].button
	_settle(0)
	_baseline()
	ShopIntents._press(options[0].button, 0)  # the game's choose: the panel moves on
	verdict = yield(_settle(2), "completed")
	_expect("level-up: option 1 taken, cursor on option 3", verdict, ["same", "sent", "extra"])
	e0.focused_control = ui._get_player_container(1)._reroll_button
	_expect("level-up: cursor into player 1's panel", _settle(0), ["sent"])

	e0.focused_control = options[0].button
	_settle(0)
	_baseline()
	var first = container._upgrade_ui_1
	container._upgrade_ui_1 = container._upgrade_ui_2
	container._upgrade_ui_2 = first
	_expect_net("level-up: options list reordered (nodes reused)", _settle(0))
	container._upgrade_ui_2 = container._upgrade_ui_1
	container._upgrade_ui_1 = first
	_settle(0)
	_baseline()
	container._upgrade_ui_4 = null
	e0.focused_control = options[3].button
	_settle(0)
	container._upgrade_ui_4 = options[3]
	_expect_net("level-up: options list resized under the cursor", _settle(0))
	print("  info: cursor key (level-up): harmless extra sends: %s" % [_extra])


# --- retry prompt (menu suite, shown on the host's battle) ---


# The prompt's emulator moves between its buttons; the cursor goes back where it was.
func run_retry(retry: Node) -> void:
	var emulator = retry.get_node("FocusEmulator")
	var was = emulator.focused_control
	_baseline()
	for path in ["%ConfirmButton", "%OkButton"]:
		var button = retry.get_node_or_null(path)
		if button != null and button != emulator.focused_control:
			emulator.focused_control = button
			_expect("retry prompt: cursor on %s" % path, _settle(0), ["sent"])
	emulator.focused_control = was
	_expect("retry prompt: cursor back", _settle(0), ["sent", "same"])
