extends Reference
# Suite axolotl: the Axolotl's text (DLC 1) never calls a method on null
# (extensions/effects/swap_max_min_stat_effect.gd). In co-op the game empties the shared effect's
# stats_swapped while has_been_applied stays set: in a release build that killed the process.

const AXOLOTL := "item_axolotl"
const AXOLOTL_PATH := "res://dlcs/dlc_1/items/axolotl/axolotl_data.tres"
const DLC := "abyssal_terrors"  # DLC 1
const OWNER := 1  # bought the Axolotl
const VIEWER := 0  # gets one offered
const SLOT := 3  # the shop slot of the offer
const UNKNOWN_HASH := 12345

var _t: Node
var _script: Script = null  # the Axolotl effect's script (the mod's extension)


func _init(t: Node) -> void:
	_t = t


func run(_together: Node):
	var original = null
	if ResourceLoader.exists(AXOLOTL_PATH):
		original = load(AXOLOTL_PATH)  # the resource ItemService's item list holds
	if original == null or original.effects.empty():
		print("  info: no Axolotl in this game (DLC 1 missing): suite skipped")
		yield(_t.get_tree(), "idle_frame")
		return
	var shared = original.effects[0]
	_script = shared.get_script()
	_t._check(shared.has_method("bt_renderable"), "the Axolotl's effect has the mod's extension")
	if not shared.has_method("bt_renderable"):
		yield(_t.get_tree(), "idle_frame")
		return
	_broken_states()
	_normal_states()
	_deserialized(shared)
	yield(_coop_shop(original), "completed")
	shared.has_been_applied = false  # as the game loaded it, for the suites after this one
	shared.stats_swapped = []


func _broken_states() -> void:
	_t.coop_run(36)
	var expected := _own_text(VIEWER)
	var x: int = Keys.stat_engineering_hash
	var states := [[], [x], [x, null], [x, UNKNOWN_HASH], [x, "stat_range"], [x, float(x)]]
	for state in states:
		var effect = _script.new()
		effect.has_been_applied = true
		effect.stats_swapped = state.duplicate()
		var warned: int = _script.bt_warning_count()
		var args = effect.get_args(VIEWER)
		_t._check(
			typeof(args) == TYPE_ARRAY and args == expected,
			"applied with stats_swapped %s: the player's own stats %s (got %s)" % [state, expected, args]
		)
		_t._check(
			effect.stats_swapped == state and effect.has_been_applied,
			"and the effect is left as it was (%s)" % [effect.stats_swapped]
		)
		_t._check(_script.bt_warning_count() == warned + 1, "and one warning for it")


func _normal_states() -> void:
	var vanilla: Script = _script.get_base_script()
	var swapped := [Keys.stat_engineering_hash, Keys.stat_range_hash]
	var warned: int = _script.bt_warning_count()
	for applied in [true, false]:
		var effect = _script.new()
		var game = vanilla.new()
		for e in [effect, game]:
			e.has_been_applied = applied
			e.stats_swapped = swapped.duplicate() if applied else []
		var args = effect.get_args(VIEWER)
		var game_args = game.get_args(VIEWER)
		_t._check(
			args == game_args and effect.stats_swapped == game.stats_swapped,
			"applied %s: the game's own text %s (got %s)" % [applied, game_args, args]
		)
		if applied:
			_t._check(
				args == [tr("STAT_RANGE"), tr("STAT_ENGINEERING")],
				"applied: the swapped stats, highest first %s" % [args]
			)
	_t._check(_script.bt_warning_count() == warned, "no warning for a normal Axolotl")


func _deserialized(shared) -> void:
	var effect = shared.duplicate()  # its text key and custom args, not its run state
	effect.has_been_applied = true
	effect.stats_swapped = [Keys.stat_engineering_hash, Keys.stat_range_hash]
	var serialized: Dictionary = parse_json(to_json(effect.serialize()))  # floats, as a save
	var warned: int = _script.bt_warning_count()
	var copy = _script.new()
	copy.deserialize_and_merge(serialized.duplicate(true))
	_t._check(
		copy.stats_swapped == effect.stats_swapped and _script.bt_warning_count() == warned,
		"a saved Axolotl comes back as it was, no warning %s" % [copy.stats_swapped]
	)
	serialized.erase("stats_swapped")
	copy = _script.new()
	copy.deserialize_and_merge(serialized)
	_t._check(
		copy.stats_swapped == [] and _script.bt_warning_count() == warned + 1,
		"one without stats_swapped: applied with [] and a warning"
	)
	var item = ItemData.new()
	var effects: Array = item._deserialize_effect_array([effect.serialize()])
	_t._check(
		effects.size() == 1 and effects[0].has_method("bt_renderable"),
		"the game's deserializer makes the mod's Axolotl effect"
	)


# Player 1 bought an Axolotl in this session; the game rolls one for player 0 (DebugService's
# forced shop item) and its offer is shown in the co-op shop.
func _coop_shop(original):
	_t.coop_run(36)
	var shared = original.effects[0]
	shared.has_been_applied = false
	shared.stats_swapped = []
	RunData.add_item(original.duplicate(), OWNER)  # what buying the shop's offer does
	_t._check(
		shared.has_been_applied and _script.bt_renderable(shared.stats_swapped),
		"bought: the shared effect is applied with %s" % [shared.stats_swapped]
	)
	var offer = _roll(original)
	_t._check(
		offer != null and offer.my_id == AXOLOTL and shared in offer.effects,
		"the roll for player %d offers an Axolotl sharing that effect" % VIEWER
	)
	_t._check(
		shared.has_been_applied and shared.stats_swapped.empty(),
		"and the game emptied the shared stats_swapped (applied %s, %s)"
		% [shared.has_been_applied, shared.stats_swapped]
	)
	var tree: SceneTree = _t.get_tree()
	tree.change_scene(RunData.get_shop_scene_path())
	for _i in 3:
		yield(tree, "idle_frame")
	var shop: Node = tree.current_scene
	var warned: int = _script.bt_warning_count()
	var node = shop._get_shop_items_container(VIEWER).get_shop_item_node(SLOT)
	node.set_shop_item(offer, RunData.current_wave)
	var text := _effect_text(node)
	var expected := _own_text(VIEWER)
	_t._check(
		expected[0] in text and expected[1] in text,
		"the offer's description builds and names player %d's stats (%s)" % [VIEWER, text]
	)
	_t._check(_script.bt_warning_count() > warned, "with a warning")
	var own: String = shared.get_text(OWNER)
	var owner_text := _own_text(OWNER)
	_t._check(
		owner_text[0] in own and owner_text[1] in own,
		"player %d's own Axolotl still has a text (%s)" % [OWNER, own]
	)
	_t._check(shared.stats_swapped.empty(), "the shared effect is not repaired by a text")


# The game's roll of a shop item for the viewer until it is the Axolotl. Without DLC 1 here (the
# test game owns none) it is owned for the roll only: in the item list, nothing else of it.
func _roll(original):
	var owned: bool = DLC in ProgressData.available_dlc_ids
	if not owned:
		ProgressData.available_dlc_ids.append(DLC)
		ItemService.invalidate_items_cache()
	var offer = null
	if _t._find_by_id(ItemService.items, AXOLOTL) == original:
		var forced: String = DebugService.force_item_in_shop
		DebugService.force_item_in_shop = AXOLOTL
		for _i in 64:  # the forced item comes half of the time
			offer = ItemService.get_rand_item_of_tier(original.tier, VIEWER, true)
			if offer.my_id == AXOLOTL:
				break
		DebugService.force_item_in_shop = forced
	else:
		_t._check(false, "the Axolotl is in ItemService's items with DLC 1 owned")
	if not owned:
		ProgressData.available_dlc_ids.erase(DLC)
		ItemService.invalidate_items_cache()
	return offer


# [highest, lowest] primary stat of player p as get_args names them.
func _own_text(p: int) -> Array:
	var keys: Array = _script.new()._find_min_max_stat_keys(p)
	return [tr(Keys.hash_to_string[keys[1]].to_upper()), tr(Keys.hash_to_string[keys[0]].to_upper())]


# The text of the first effect line in a shop item's description.
static func _effect_text(node: Node) -> String:
	var lines: Node = node._item_description.get_effects()
	for line in lines.get_children():
		if not line.is_queued_for_deletion() and line.get("text_descr") != null:
			return line.text_descr.bbcode_text
	return ""
