extends Node
# The trade key: InputMap action "brotato_trade", keyboard T (physical, so it stays in place on
# other layouts) and the pad's Back / View / Share / Minus (JOY_SELECT), or what the mod's config
# names (manifest.json config_schema). An instance is the shop's listener: it must come after the
# FocusEmulators, which mark every key they do not know as handled (_input runs in reverse tree
# order).

const ACTION := "brotato_trade"
const MOD_ID := "einfluffles-BrotatoTrade"
const LOG_NAME := MOD_ID + ":Hotkey"
const KEY_PROP := "trade_key"
const BUTTON_PROP := "trade_joypad_button"
const DEFAULT_KEY := KEY_T
const DEFAULT_BUTTON := JOY_SELECT
const ICON_DIR := "res://mods-unpacked/einfluffles-BrotatoTrade/icons/"
const KEY_ICON := "key_t.png"
# By CoopService.PlayerType (a keyboard player has none).
const PAD_ICONS := [
	"pad_xbox_view.png", "pad_xbox_view.png", "pad_ps_share.png", "pad_switch_minus.png"
]
const ICONS_META := "brotato_trade_icons"

var shop: Node = null


func _input(event: InputEvent) -> void:
	if is_instance_valid(shop):
		shop.trade_hotkey_input(event)


# The base action. InputService._copy_device_actions makes the per-device copies from it, after
# every InputMap.load_from_globals.
static func register() -> void:
	if not InputMap.has_action(ACTION):
		InputMap.add_action(ACTION)
	InputMap.action_erase_events(ACTION)
	var binding := binding()
	var key := InputEventKey.new()
	key.physical_scancode = binding[0]
	InputMap.action_add_event(ACTION, key)
	var button := InputEventJoypadButton.new()
	button.device = -1
	button.button_index = binding[1]
	InputMap.action_add_event(ACTION, button)


# Outside InputService: the base action and its per-device copies, as _copy_device_actions makes
# them (a config chosen while the game runs, or an InputService that ran before this mod).
static func register_all() -> void:
	register()
	var events: Array = InputMap.get_action_list(ACTION)
	for remapped in range(0, CoopService.REMAP_END):
		var name := "%s_%d" % [ACTION, remapped]
		if InputMap.has_action(name):
			InputMap.action_erase_events(name)
		for event in events:
			if event is InputEventJoypadButton:
				var copy := InputEventJoypadButton.new()
				var pad: bool = remapped == CoopService.GAMEPAD_REMAPPED_DEVICE_ID
				copy.device = 0 if pad else remapped
				copy.button_index = event.button_index
				InputService.add_action(ACTION, remapped, 0.5, copy)
			elif event is InputEventKey:
				var keyboard: bool = remapped == CoopService.KEYBOARD_REMAPPED_DEVICE_ID
				InputService.add_key_action(ACTION, remapped, 0 if keyboard else remapped, event)


# [physical scancode, joypad button] from the config; a missing or unknown value is the default.
static func binding() -> Array:
	return parse_binding(_config_data())


static func parse_binding(data: Dictionary) -> Array:
	var key := DEFAULT_KEY
	var button := DEFAULT_BUTTON
	var name = data.get(KEY_PROP, null)
	if name is String and OS.find_scancode_from_string(name) != 0:
		key = OS.find_scancode_from_string(name)
	elif name != null:
		ModLoaderLog.warning(
			"Unknown %s %s in the config, using T" % [KEY_PROP, JSON.print(name)], LOG_NAME, true
		)
	var index = data.get(BUTTON_PROP, null)
	var number: bool = typeof(index) in [TYPE_INT, TYPE_REAL]
	if number and index == int(index) and int(index) >= 0 and int(index) < JOY_BUTTON_MAX:
		button = int(index)
	elif index != null:
		ModLoaderLog.warning(
			"Unknown %s %s in the config, using %d (Back / View / Share / Minus)"
			% [BUTTON_PROP, JSON.print(index), DEFAULT_BUTTON],
			LOG_NAME,
			true
		)
	return [key, button]


# The hint's glyph for the player's device: an icon, or the binding's name when it was rebound.
static func glyph(player_index: int):
	var device_type := player_type(player_index)
	for event in (InputMap.get_action_list(ACTION) if InputMap.has_action(ACTION) else []):
		var keyboard: bool = device_type == CoopService.PlayerType.KEYBOARD_AND_MOUSE
		if keyboard and event is InputEventKey:
			if event.physical_scancode == KEY_T:
				return _icon(KEY_ICON)
			return OS.get_scancode_string(event.physical_scancode)
		if not keyboard and event is InputEventJoypadButton:
			if event.button_index == JOY_SELECT:
				return _icon(PAD_ICONS[clamp(device_type, 0, PAD_ICONS.size() - 1)])
			return Input.get_joy_button_string(event.button_index)
	return ""


# What the Mod Loader chose (the profile's current_config), else the default config.
static func _config_data() -> Dictionary:
	var mod = ModLoaderStore.mod_data.get(MOD_ID) if ModLoaderStore != null else null
	if mod == null:
		return {}
	var config = mod.current_config
	if config == null:
		config = mod.configs.get("default")
	if config == null or not config.data is Dictionary:
		return {}
	return config.data


static func player_type(player_index: int) -> int:
	if RunData.is_coop_run and player_index >= 0:
		if player_index < CoopService.connected_players.size():
			return CoopService.get_player_input_type(player_index)
	if InputService.using_gamepad:
		return CoopService.PlayerType.GAMEPAD_XBOX
	return CoopService.PlayerType.KEYBOARD_AND_MOUSE


# Plain PNGs: a mod's zip has no imported resources, so they are read as images.
static func _icon(file: String) -> Texture:
	var icons: Dictionary = Engine.get_meta(ICONS_META) if Engine.has_meta(ICONS_META) else {}
	if not icons.has(file):
		var image := Image.new()
		var texture := ImageTexture.new()
		if image.load(ICON_DIR + file) == OK:
			texture.create_from_image(image, Texture.FLAG_FILTER | Texture.FLAG_MIPMAPS)
		icons[file] = texture
		Engine.set_meta(ICONS_META, icons)
	return icons[file]
