extends Reference
# The item popup's meca upgrade (DLC primal_dread). The game rolls the two stat options in the
# popup and keeps the roll per weapon object (_upgrade_preview_cache) while the popup lives.
# Here the host rolls (static functions); a client's popup asks for the roll and picks by index.

signal roll_requested(weapon)
signal picked(weapon, index)

const MECA_DLC := "primal_dread"
const ENTRY_SIZE := 6  # [slot, weapon my_id, stat 0 key hash, value 0, stat 1 key hash, value 1]

var popup: Node = null  # the own ItemPopup
var player := -1
var rolls := []  # the host's remembered rolls for this player (entries, checked)
var _connected := []  # [source, signal, method]
var _waiting = null  # the weapon whose roll was asked for
var _picked = null  # the weapon item_meca_upgrade_selected named
var _choice := -1  # the effect button pressed


static func dlc_data():
	return ItemService.get_dlc_data_by_id(MECA_DLC)


# ItemPopup.can_meca_upgrade for player p's weapon, whether or not the popup shows it.
static func can_upgrade(item_popup: Node, weapon, p: int) -> bool:
	var dlc = dlc_data()
	if dlc == null or not (MECA_DLC in ProgressData.active_update_data):
		return false
	if item_popup == null or item_popup.get("_upgrade_button") == null:
		return false  # ItemPopup.has_meca_upgrade_ui
	if not ItemService.can_weapon_be_mechanized(weapon):
		return false
	var cost: int = dlc.get_meca_upgrade_cost(weapon)
	return cost > 0 and RunData.get_player_meca_parts(p) >= cost


# ItemPopup._get_upgrade_preview for player p's weapon: the roll the popup already keeps for
# that weapon, else a new one (kept there). null when the weapon can't be upgraded now.
static func roll(item_popup: Node, weapon, p: int):
	if not can_upgrade(item_popup, weapon, p):
		return null
	var cache: Dictionary = item_popup._upgrade_preview_cache
	var key: int = weapon.get_instance_id()
	if cache.has(key):
		return cache[key]
	var preview = dlc_data().meca_item(weapon, p)
	if options(preview).size() < 2:
		return null
	cache[key] = preview
	return preview


# The remembered roll for player p's weapon with option index picked (ItemPopup.
# _select_upgrade_effect), forgotten from then on; null when there is none to pick from.
static func take(item_popup: Node, weapon, p: int, index):
	if typeof(index) != TYPE_INT or (index != 0 and index != 1):
		return null
	if not can_upgrade(item_popup, weapon, p):
		return null
	var cache: Dictionary = item_popup._upgrade_preview_cache
	var key: int = weapon.get_instance_id()
	var preview = cache.get(key)
	if preview == null or options(preview).size() != 2:
		return null
	cache.erase(key)
	return dlc_data().change_effect_option_to_modular_effect(preview, index)


static func entries(item_popup: Node, p: int) -> Array:
	var list := []
	if item_popup == null:
		return list
	var cache: Dictionary = item_popup._upgrade_preview_cache
	var weapons: Array = RunData.get_player_weapons(p)
	for slot in weapons.size():
		var preview = cache.get(weapons[slot].get_instance_id())
		var found: Array = options(preview) if preview != null else []
		if found.size() == 2:
			var entry := [slot, weapons[slot].my_id]
			for option in found:
				entry.append(option.key_hash)
				entry.append(option.value)
			list.append(entry)
	return list


# ItemPopup._get_effect_options.
static func options(item) -> Array:
	var found := []
	for effect in item.effects:
		if effect is EffectOption:
			found.append(effect)
	return found


static func parse(value) -> Array:
	var list := []
	if typeof(value) != TYPE_ARRAY:
		return list
	for entry in value:
		if typeof(entry) != TYPE_ARRAY or entry.size() != ENTRY_SIZE:
			continue
		if typeof(entry[0]) != TYPE_INT or entry[0] < 0 or typeof(entry[1]) != TYPE_STRING:
			continue
		var valid := true
		for i in [2, 4]:
			valid = valid and typeof(entry[i]) == TYPE_INT and Keys.hash_to_string.has(entry[i])
			valid = valid and typeof(entry[i + 1]) == TYPE_INT
		if valid:
			list.append(entry)
	return list


# Cuts the popup's own roll on press (a client's popup never rolls an option to pick from).
static func cut(item_popup: Node) -> void:
	var button = item_popup.get("_upgrade_button")
	if button != null and button.is_connected("pressed", item_popup, "_on_UpgradeButton_pressed"):
		button.disconnect("pressed", item_popup, "_on_UpgradeButton_pressed")


func attach(item_popup: Node, p: int) -> void:
	detach()
	popup = item_popup
	player = p
	cut(popup)
	var button = popup.get("_upgrade_button")
	if button != null:
		_connect(button, "pressed", "_on_upgrade_pressed")
	_connect(popup, "item_meca_upgrade_selected", "_on_selected")
	for index in 2:
		var effect_button = popup.get("_effect_button_%d" % index)
		if effect_button != null:
			_connect(effect_button, "pressed", "_on_choice", [index])


func detach() -> void:
	for entry in _connected:
		if is_instance_valid(entry[0]) and entry[0].is_connected(entry[1], self, entry[2]):
			entry[0].disconnect(entry[1], self, entry[2])
	_connected = []
	popup = null
	player = -1
	rolls = []
	_waiting = null
	_picked = null
	_choice = -1


# The roll asked for is shown if the popup still waits for it. If it was closed in the meantime,
# the roll stays on the host.
func set_rolls(value) -> void:
	rolls = parse(value)
	if _waiting == null or not is_instance_valid(popup):
		return
	var weapon = _waiting
	if not (popup.visible and popup._focused and popup._item_data == weapon):
		_waiting = null
		return
	var entry := _roll_of(weapon)
	if not entry.empty():
		_show(weapon, entry)


func _connect(source: Object, signal_name: String, method: String, binds := []) -> void:
	if source.connect(signal_name, self, method, binds) == OK:
		_connected.append([source, signal_name, method])


# Where ItemPopup._on_UpgradeButton_pressed would roll: the host's roll when it is known,
# else a request (the popup keeps its buttons meanwhile, so Cancel still closes it).
func _on_upgrade_pressed() -> void:
	if not is_instance_valid(popup) or not popup.can_meca_upgrade():
		return
	var weapon = popup._item_data
	_picked = null
	_choice = -1
	var entry := _roll_of(weapon)
	if not entry.empty():
		_show(weapon, entry)
		return
	_waiting = weapon
	emit_signal("roll_requested", weapon)


# The game's own choice UI with the host's two options: the preview is built like
# DLC2Data.meca_item builds it (without rolling: do_not_add_effect), plus the host's options.
func _show(weapon, entry: Array) -> void:
	_waiting = null
	var dlc = dlc_data()
	if dlc == null:
		return
	var preview = dlc.meca_item(weapon, player, true)
	for i in [2, 4]:
		var option := EffectOption.new()
		option.key = Keys.hash_to_string[entry[i]]
		option.key_hash = entry[i]
		option.value = entry[i + 1]
		preview.effects.append(option)
	popup._upgrade_preview_cache[weapon.get_instance_id()] = preview
	popup._on_UpgradeButton_pressed()


func _roll_of(weapon) -> Array:
	var weapons: Array = RunData.get_player_weapons(player)
	for entry in rolls:
		if entry[0] < weapons.size() and weapons[entry[0]] == weapon and weapon.my_id == entry[1]:
			return entry
	return []


# One pick raises two of the popup's signals (effect button, item_meca_upgrade_selected) in an
# order that is not fixed: sent once both are known.
func _on_choice(index: int) -> void:
	_choice = index
	_send_pick()


func _on_selected(weapon, _upgraded) -> void:
	_picked = weapon
	_send_pick()


func _send_pick() -> void:
	if _picked == null or _choice < 0:
		return
	var weapon = _picked
	var index := _choice
	_picked = null
	_choice = -1
	# The popup's roll is used up (_select_upgrade_effect turned an option into the effect);
	# the host forgets it too.
	popup._upgrade_preview_cache.erase(weapon.get_instance_id())
	var entry := _roll_of(weapon)
	if not entry.empty():
		rolls.erase(entry)
	emit_signal("picked", weapon, index)


# The popup's weapon is now the run's new object of it (a gear change kept the popup open).
func retarget(old, new) -> void:
	if _waiting != null and _waiting == old:
		_waiting = new
