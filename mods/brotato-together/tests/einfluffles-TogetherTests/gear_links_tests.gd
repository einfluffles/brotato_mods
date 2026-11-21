extends Reference
# Suite gear_links: the host's level-up panel of a remote player. A switch of its client's input
# type while on the gear page links the gear rows to each other's elements (the panel's own
# _set_focus_neighbours with trigger glyphs); a gear rebuild after that (recycle or combine in the
# crate weapons list) must not leave the rows a neighbour that names a freed element. Past bug:
# "Node not found: .../Elements/@InventoryElement@..." and "Parameter p_node is null" on the host.

const PISTOL := "weapon_pistol_1"
const CRATE := "consumable_item_box"
const ITEMS := ["item_helmet", "item_hedgehog", "item_coupon"]
const REMOTE := 1
const KEYBOARD := 0  # CoopService.PlayerType
const XBOX := 1
const MARGINS := [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]

var _t: Node = null
var _together: Node = null
var _ui: Node = null


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	_together = together
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	together.battle_host.set_process(false)  # driven by hand: no Steam session
	_build_run()
	yield(_enter_battle(), "completed")
	var panel = _ui._get_player_container(REMOTE)
	var crate_weapons = panel.crate_weapons_container
	_t._check(
		crate_weapons.get_element_count() == 3, "gear links: the crate weapons list shows 3 pistols"
	)

	yield(_link_gear(panel), "completed")
	var weapon = RunData.get_player_weapons(REMOTE)[0]
	_ui._on_weapon_discard_button_pressed(weapon, REMOTE)  # as UpgradesSync applies the intent
	yield(_frames(2), "completed")
	_check_neighbours(panel, "after a recycle from the crate list")

	yield(_link_gear(panel), "completed")
	weapon = RunData.get_player_weapons(REMOTE)[0]
	_ui._on_weapon_combine_button_pressed(weapon, REMOTE)
	yield(_frames(2), "completed")
	_t._check(
		RunData.get_player_weapons(REMOTE).size() == 1, "gear links: (control) the pistols combined"
	)
	_check_neighbours(panel, "after a combine from the crate list")

	CoopService.bt_clear_input_types()
	yield(_blank_scene(), "completed")
	CoopService.connected_players = saved_players
	together.battle_host.set_process(true)


# The client on its gear page switches to its pad (the host links the rows to each other's
# elements), then goes back to the crate.
func _link_gear(panel: Node):
	var upgrades: Node = _together.upgrades_sync
	upgrades.host_apply_focus(_ui, REMOTE, 1, [])
	CoopService.bt_set_device_type(_t.DEVICE, KEYBOARD)
	CoopService.bt_set_device_type(_t.DEVICE, XBOX)
	var gear = panel.player_gear_container
	var elements = gear.items_container._elements
	var bottom = elements.get_node_or_null(elements.focus_neighbour_bottom)
	_t._check(
		bottom != null and bottom.get_parent() == gear.weapons_container._elements,
		"gear links: (control) the items row leads down to a weapon element"
	)
	yield(_frames(1), "completed")
	upgrades.host_apply_focus(_ui, REMOTE, 0, [])


func _build_run() -> void:
	CoopService.clear_coop_players()
	CoopService.connected_players.push_back([0, XBOX])
	CoopService.connected_players.push_back([_t.DEVICE, XBOX])
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(2)
	for p in 2:
		RunData.add_character(ItemService.characters[p], p)
	RunData.add_weapon(_t._find_by_id(ItemService.weapons, PISTOL), 0)
	RunData.get_player_effects(REMOTE)[Keys.effect_crate_give_weapon_hash] = 1
	RunData.players_data[REMOTE].weapons.clear()
	for _i in 3:
		RunData.add_weapon(_t._find_by_id(ItemService.weapons, PISTOL), REMOTE)
	for id in ITEMS:
		RunData.add_item(_t._find_by_id(ItemService.items, id), REMOTE)
	RunData.current_wave = 3


# The host's battle scene as the level-up panels find it (upgrades_change_tests.gd), a crate for
# the remote player.
func _enter_battle():
	var tree: SceneTree = _t.get_tree()
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main: Node = tree.current_scene
	_together.battle_host._start_battle(main)
	main._wave_timer.stop()
	main._entity_spawner.clean_up_room()
	main._wave_manager.clean_up_room()
	for player in main._players:
		if is_instance_valid(player):
			player.on_room_cleanup()
	yield(tree.create_timer(0.3), "timeout")
	_ui = main.get("_coop_upgrades_ui")
	var crate = UpgradesUI.ConsumableToProcess.new()
	crate.consumable_data = _t._find_by_id(ItemService.consumables, CRATE)
	crate.player_index = REMOTE
	var level = UpgradesUI.UpgradeToProcess.new()
	level.level = 2
	level.player_index = 0
	_ui.show_options([[], [crate], [], []], [[level], [], [], []])
	yield(_frames(2), "completed")


func _blank_scene():
	var tree: SceneTree = _t.get_tree()
	var blank := Node.new()
	blank.name = "GearLinksBlank"
	var packed := PackedScene.new()
	packed.pack(blank)
	blank.free()
	tree.change_scene_to(packed)
	for _i in 3:
		yield(tree, "idle_frame")


func _check_neighbours(panel: Node, label: String) -> void:
	var gear = panel.player_gear_container
	var nodes := []
	for inventory in [gear.weapons_container, gear.items_container]:
		nodes.append(inventory)
		nodes.append(inventory._elements)
		nodes.append_array(inventory._elements.get_children())
	var dead := []
	for node in nodes:
		for margin in MARGINS:
			var path: NodePath = node.get_focus_neighbour(margin)
			if not path.is_empty() and node.get_node_or_null(path) == null:
				dead.append("%s:%d" % [node.name, margin])
	_t._check(dead.empty(), "gear links: %s: no neighbour names a freed node %s" % [label, dead])


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")
