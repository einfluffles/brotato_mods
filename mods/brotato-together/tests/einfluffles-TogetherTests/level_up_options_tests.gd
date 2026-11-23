extends Reference
# Suite level_up_options: a client rebuilds every level-up option the host's panels show
# (sync/upgrade_options.gd). Baby gets only the weapon slot upgrade at each level-up
# (ItemService.weapon_slot_upgrade_data, not in ItemService.upgrades); a client showed Baby's
# panel empty, and Baby on a client could not choose, so the host waited for ever. Captain's
# level_upgrades_modifications scale the options' effects on the host, and so on a client. The
# run and battle are built as upgrades_change_tests.gd builds them; the client applies the host's
# states in the same process, as there.

const UpgradesChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/upgrades_change_tests.gd"
)
const UpgradeOptions := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/upgrade_options.gd"
)
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const BABY := "character_baby"
const SLOT := "upgrade_weapon_slot"
const SCALE := 100  # Captain's level_upgrades_modifications: +100%
# [Baby's player index, the client's player (-1: a spectator)]
const CASES := [[1, 1], [1, -1], [0, 1]]

var _t: Node = null
var _together: Node = null
var _sync: Node = null
var _ui: Node = null
var _built = UpgradesChangeTests.new()  # kept alive across its yields


func run(t: Node, together: Node):
	_t = t
	_together = together
	_sync = together.upgrades_sync
	_built._t = t
	_built._together = together
	_built._sync = _sync
	_built._cache = _sync.run_cache
	together.battle_host.set_process(false)  # driven by hand: no Steam session
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	_built._start_stream()
	_t._check(
		_t._find_by_id(ItemService.upgrades, SLOT) == null
		and ItemService.weapon_slot_upgrade_data.my_id == SLOT,
		"level-up options: (the weapon slot upgrade is not in ItemService.upgrades)"
	)
	_t._check(
		UpgradeOptions.resolve("upgrade_unknown_to_everyone", 0) == null,
		"level-up options: an unknown id resolves to nothing (and is logged)"
	)
	for case in CASES:
		yield(_level_ups(case[0], case[1]), "completed")
	_built._end_stream()
	CoopService.connected_players = saved_players
	together.battle_host.set_process(true)


# Baby (player b) and another character (Captain's scaling) both level up; the host takes Baby's
# first level-up; the client `you` gets the state before and after.
func _level_ups(b: int, you: int):
	var other := 1 - b
	var label := "level-up options (Baby player %d, client %s)" % [
		b, "player %d" % you if you >= 0 else "spectator"
	]
	_baby_run(b)
	RunData.get_player_effects(other)[Keys.level_upgrades_modifications_hash] = SCALE
	yield(_built._enter_battle(), "completed")
	_ui = _built._ui
	var levels := [[], []]
	levels[b] = [_built._level(b, 2), _built._level(b, 3)]
	levels[other] = [_built._level(other, 2)]
	_built._show([[], []], levels)
	yield(_t.get_tree(), "idle_frame")
	var baby_c = _ui._get_player_container(b)
	var other_c = _ui._get_player_container(other)
	var host_view: Array = _sync.capture(_ui)
	_t._check(
		host_view[b] == ["upgrades", [SLOT], 2, baby_c._reroll_price]
		and _shown(baby_c) == 1
		and not baby_c._reroll_button.visible,
		"%s: the host's panel offers the weapon slot alone, no reroll %s" % [label, [host_view[b]]]
	)
	var host_values := _values(other_c._old_upgrades)
	var base_values := []
	for upgrade in other_c._old_upgrades:
		base_values.append(_values([_t._find_by_id(ItemService.upgrades, upgrade.my_id)])[0])
	_t._check(
		not host_values.empty() and host_values != base_values,
		"%s: (the host scaled the other player's options)" % label
	)
	var body1 = bytes2var(var2bytes(_sync.state_body(StateStream.UPGRADES)))
	# the host takes Baby's choice: its own press, or the client's intent
	yield(_built._button_delay(), "completed")
	var slots: int = RunData.get_player_effect(Keys.weapon_slot_hash, b)
	var intent: Dictionary = _built._intent(b, "choose", SLOT)
	if b == 0:
		baby_c._on_choose_button_pressed(baby_c._old_upgrades[0])
	else:
		_t._check(
			_sync.host_apply_intent(_ui, b, intent),
			"%s: the host applies a choose intent for the weapon slot" % label
		)
	_t._check(
		RunData.get_player_effect(Keys.weapon_slot_hash, b) == slots + 1
		and _sync.capture(_ui)[b] == ["upgrades", [SLOT], 3, baby_c._reroll_price],
		"%s: the host gives Baby a weapon slot (%d) and offers the next level's" % [
			label, RunData.get_player_effect(Keys.weapon_slot_hash, b)
		]
	)
	var body2 = bytes2var(var2bytes(_sync.state_body(StateStream.UPGRADES)))
	# the client
	var client: Node = _together.battle_client
	var saved_you: int = client._you
	var saved_store = _sync.run_store
	client._you = you
	_sync.run_store = RunParts.Store.new()
	_sync._guarded_ui = null
	_sync._reported_popups = {}  # the host's, which would close the copy every frame here
	_unshow(baby_c)
	_unshow(other_c)
	yield(_built._client_apply(body1, 2), "completed")
	var focus = baby_c.get_focus_control()
	_t._check(
		_ids(baby_c) == [SLOT] and _shown(baby_c) == 1 and not baby_c._reroll_button.visible,
		"%s: the client's copy of Baby's panel shows the weapon slot (%d shown)" % [
			label, _shown(baby_c)
		]
	)
	_t._check(focus.is_visible_in_tree(), "%s: Baby's panel's focus control is visible" % label)
	_t._check(
		_values(other_c._old_upgrades) == host_values and _shown(other_c) == host_values.size(),
		"%s: the other player's options as the host scaled them %s" % [label, host_values]
	)
	if you == b:
		yield(_own_press(baby_c, intent, label), "completed")
	_unshow(baby_c)
	RunData.get_player_effects(b)[Keys.weapon_slot_hash] = slots
	var weapons_label: Label = baby_c.player_gear_container.weapons_container._label
	weapons_label.text = "-"
	yield(_built._client_apply(body2, 2), "completed")
	_t._check(
		_ids(baby_c) == [SLOT] and _shown(baby_c) == 1 and baby_c._level == 3,
		"%s: the next state shows the next level's weapon slot" % label
	)
	_t._check(
		RunData.get_player_effect(Keys.weapon_slot_hash, b) == slots + 1
		and weapons_label.text.ends_with("(1/%d)" % (slots + 1)),
		"%s: the client's weapon slots follow ('%s')" % [label, weapons_label.text]
	)
	_sync._on_battle_left()
	_sync.run_store = saved_store
	client._you = saved_you
	yield(_built._blank_scene(), "completed")
	_ui = null


# The client's own cursor starts on the option, and accept there sends what the host took.
func _own_press(baby_c: Node, taken: Dictionary, label: String):
	var emulator = baby_c.focus_emulator
	var option: Control = baby_c._get_upgrade_uis()[0].button
	_t._check(
		_sync._local_active and emulator.focused_control == option and option.is_visible_in_tree(),
		"%s: the own cursor is on the weapon slot option, shown" % label
	)
	yield(_built._button_delay(), "completed")  # the press delay of the host's choice
	_sync.last_intent = {}
	for pressed in [true, false]:
		var device: int = emulator._device
		VirtualDevices.press_button(VirtualDevices.action("ui_accept", device), device, pressed)
		yield(_t.get_tree(), "idle_frame")
	var sent: Dictionary = _sync.last_intent
	_t._check(
		(
			sent.get("kind") == "choose"
			and sent.get("id") == SLOT
			and sent.get("seq") == taken.seq
		),
		"%s: accept sends the choice the host took %s" % [label, [sent]]
	)


# Baby as player b next to the first character, a pistol each.
func _baby_run(b: int) -> void:
	CoopService.connected_players.clear()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(2)
	for p in 2:
		var character = ItemService.characters[0]
		if p == b:
			character = _t._find_by_id(ItemService.characters, BABY)
		RunData.add_character(character, p)
		RunData.add_weapon(_t._find_by_id(ItemService.weapons, UpgradesChangeTests.PISTOL), p)
		RunData.add_gold(500, p)
	RunData.current_wave = 3


# What a client's rebuild has to put back.
static func _unshow(container: Node) -> void:
	container._old_upgrades = []
	for upgrade_ui in container._get_upgrade_uis():
		upgrade_ui.visible = false
	container._reroll_button.visible = true


static func _shown(container: Node) -> int:
	var shown := 0
	for upgrade_ui in container._get_upgrade_uis():
		if upgrade_ui.visible:
			shown += 1
	return shown


static func _ids(container: Node) -> Array:
	var ids := []
	for upgrade in container._old_upgrades:
		ids.append(upgrade.my_id)
	return ids


# Per option: its id and its effects' values.
static func _values(upgrades: Array) -> Array:
	var values := []
	for upgrade in upgrades:
		var option := [upgrade.my_id]
		for effect in upgrade.effects:
			option.append(effect.value)
		values.append(option)
	return values
