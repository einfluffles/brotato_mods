extends Node
# Headless tests of brotato:trade, run by tools/check.sh inside the decompiled game.
# Suites (SUITES): MOD_TEST_SUITES picks some (comma-separated, empty: all that can run here),
# shards.txt groups them into processes. Each suite sets up its own run.
# Prints "MOD-TESTS: PASS" or "MOD-TESTS: FAIL" and quits.

const DIR := "res://mods-unpacked/einfluffles-TradeTests/"
const TOGETHER := "/root/ModLoader/einfluffles-BrotatoTogether"
const SUITES := ["rules", "shop", "together"]
const WATCHDOG_SEC := 120.0
const FIRST_DEVICE := 1  # device 0 is the keyboard to CoopService
const PISTOL := "weapon_pistol_1"

var _failures := []
var _suite = null  # the running suite's object, kept alive across its yields


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	call_deferred("_run")


# Desktop platforms flush parsed input events every frame; the headless platform never does.
func _process(_delta: float) -> void:
	Input.flush_buffered_events()


func _run() -> void:
	yield(get_tree().create_timer(1.0), "timeout")
	print("MOD-TESTS: START")
	get_tree().create_timer(WATCHDOG_SEC).connect("timeout", self, "_on_watchdog")
	for suite in _selected_suites():
		var started := OS.get_ticks_msec()
		_suite = load(DIR + suite + "_tests.gd").new()
		yield(_suite.run(self), "completed")
		_suite = null
		print("  info: suite %s took %.1f s" % [suite, (OS.get_ticks_msec() - started) / 1000.0])
	_finish()


func _selected_suites() -> Array:
	var wanted := []
	for entry in OS.get_environment("MOD_TEST_SUITES").split(",", false):
		wanted.append(entry.strip_edges())
	var selected := []
	for suite in SUITES:
		if wanted.empty() or suite in wanted:
			selected.append(suite)
	for suite in wanted:
		check(suite in SUITES, "suite %s exists" % suite)
	return selected


# A co-op run in its shop state: `count` players on pads, each with its character, nothing
# else. Players' devices are FIRST_DEVICE + index.
func coop_run(count: int) -> void:
	get_tree().paused = false
	CoopService.clear_coop_players()
	for i in count:
		CoopService.connected_players.push_back(
			[FIRST_DEVICE + i, CoopService.PlayerType.GAMEPAD_XBOX]
		)
	RunData.reset()
	RunData.set_coop_run(true)
	RunData.set_player_count(count)
	for i in count:
		RunData.add_character(ItemService.characters[i], i)
	RunData.current_wave = 2


func open_shop():
	get_tree().change_scene(RunData.get_shop_scene_path())
	yield(frames(3), "completed")
	return get_tree().current_scene


func weapon(my_id := PISTOL):
	return find(ItemService.weapons, my_id)


func find(elements: Array, my_id: String):
	for element in elements:
		if element.my_id == my_id:
			return element
	return null


# A lootable item with that limit (-1: none) whose effects come back when it is removed.
func item_with_limit(max_nb: int, skip := []):
	for item in ItemService.items:
		if item.max_nb != max_nb or not item.can_be_looted or item in skip:
			continue
		if item.replaced_by != null or item.effects.empty():
			continue
		var plain := true
		for effect in item.effects:
			plain = plain and effect.get_id() == "effect" and Utils.is_stat_key(effect.key_hash)
			plain = plain and effect.storage_method == Effect.StorageMethod.SUM and effect.value != 0
		if plain:
			return item
	return null


# Every weapon and item of every player, as sorted names: nothing may appear or vanish.
func ledger() -> String:
	var owned := []
	for p in RunData.get_player_count():
		owned += ids(RunData.get_player_weapons_ref(p)) + ids(RunData.get_player_items_ref(p))
	owned.sort()
	return str(owned)


func ids(owned: Array) -> Array:
	var names := []
	for entry in owned:
		names.append("%s%s" % [entry.my_id, "*" if entry.is_cursed else ""])
	return names


func tap(action: String, player: int):
	var device: int = CoopService.get_remapped_player_device(player)
	for pressed in [true, false]:
		var event := InputEventAction.new()
		event.action = "%s_%s" % [action, device]
		event.pressed = pressed
		event.strength = 1.0 if pressed else 0.0
		event.device = device
		Input.parse_input_event(event)
		yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")


func frames(count: int):
	for _i in count:
		yield(get_tree(), "idle_frame")


func check(condition: bool, label: String) -> void:
	print("  %s %s" % ["ok  " if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _on_watchdog() -> void:
	check(false, "watchdog: tests did not finish within %d s" % WATCHDOG_SEC)
	_finish()


func _finish() -> void:
	print("MOD-TESTS: %s" % ("PASS" if _failures.empty() else "FAIL %s" % [_failures]))
	get_tree().quit(0 if _failures.empty() else 1)
