extends "res://singletons/coop_service.gd"
# Player colours: the game reads every colour from player_colors[slot], so that array is
# rewritten whenever the slots or the players' picks from the palette change. Nothing is saved.

signal bt_player_colors_changed
signal bt_input_types_changed(player_index)  # the type that player's key hints show

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
# Same pastel style as the game's own four (get_player_color saturates them).
const BT_EXTRA_COLORS := [
	Color(0.98, 0.70, 0.90),  # pink
	Color(0.80, 0.72, 0.99),  # violet
	Color(0.66, 0.80, 0.99),  # blue
	Color(0.99, 0.64, 0.64),  # red
]

var bt_palette := []  # game defaults + BT_EXTRA_COLORS
var bt_slot_colors := []  # slot -> palette index currently in player_colors
# Client's copy of the host's character selection: the host's hold-to-join progress (null:
# this machine's own).
var bt_remote_progress = null
# The type a player's key hints show (get_player_input_type) where it is not the slot's own,
# which aim goes by (bt_slot_uses_gamepad). Host: remote device -> the type its client reports.
# Client: player slot -> the host's word for it; bt_own_slot shows this machine's device.
var bt_device_types := {}
var bt_slot_types := {}
var bt_own_slot := -1
var _bt_picks := {}  # remapped device -> picked palette index
var _bt_remote := []  # client of a lobby: the host's slot colours (palette indices)


func _ready() -> void:
	_bt_init_colors()


# The game would type a remote player's virtual device as keyboard (no joypad name); as a
# gamepad, stick aim applies. Its key hints follow bt_device_types.
func _add_player(device: int, player_type: int) -> void:
	if VirtualDevices.is_virtual(device):
		player_type = PlayerType.GAMEPAD_XBOX
	._add_player(device, player_type)


func get_player_input_type(player_index: int) -> int:
	if player_index == bt_own_slot:
		return VirtualDevices.local_player_type()
	if bt_slot_types.has(player_index):
		return bt_slot_types[player_index]
	var player: Array = connected_players[player_index]
	return bt_device_types.get(player[0], player[1])


# is_player_using_gamepad by the slot's own type, for Utils: aim and the right stick.
func bt_slot_uses_gamepad(player_index: int) -> bool:
	if force_gamepad:
		return true
	if player_index < 0 or player_index >= connected_players.size():
		return false
	return connected_players[player_index][1] != PlayerType.KEYBOARD_AND_MOUSE


# Host: the type a remote player's client says it uses (INPUT).
func bt_set_device_type(device: int, player_type: int) -> void:
	if bt_device_types.get(device, -1) == player_type:
		return
	bt_device_types[device] = player_type
	for p in connected_players.size():
		if connected_players[p][0] == device:
			emit_signal("bt_input_types_changed", p)


# Client: the host's types of the other slots (slot -> type) and the own slot (-1: none).
func bt_set_slot_types(types: Dictionary, own_slot: int) -> void:
	var before := _bt_hint_types()
	bt_slot_types = types
	bt_own_slot = own_slot
	var after := _bt_hint_types()
	for p in after.size():
		if before[p] != after[p]:
			emit_signal("bt_input_types_changed", p)


func bt_clear_input_types() -> void:
	bt_device_types.clear()
	bt_set_slot_types({}, -1)


func _bt_hint_types() -> Array:
	var types := []
	for p in connected_players.size():
		types.append(get_player_input_type(p))
	return types


func _update_connection_progress() -> void:
	if bt_remote_progress == null:
		._update_connection_progress()
		return
	connection_progress = bt_remote_progress.duplicate()
	emit_signal("connection_progress_updated", connection_progress)


func _bt_init_colors() -> void:
	if bt_palette.empty():
		bt_palette = player_colors.duplicate() + BT_EXTRA_COLORS
		bt_slot_colors = range(player_colors.size())
	if not is_connected("connected_players_updated", self, "_bt_on_players_updated"):
		connect("connected_players_updated", self, "_bt_on_players_updated")


func _bt_on_players_updated(_players) -> void:
	bt_apply_colors()


func bt_cycle_color(player_index: int, step := 1) -> bool:
	_bt_init_colors()
	if not _bt_remote.empty() or player_index < 0 or player_index >= connected_players.size():
		return false
	var taken := []
	for p in connected_players.size():
		if p != player_index:
			taken.append(bt_slot_colors[p])
	var index: int = bt_slot_colors[player_index]
	for _i in bt_palette.size():
		index = posmod(index + step, bt_palette.size())
		if not taken.has(index):
			break
	if index == bt_slot_colors[player_index]:
		return false
	_bt_picks[connected_players[player_index][0]] = index
	bt_apply_colors()
	return true


# Picks of connected players first (in slot order), then each remaining slot gets its default
# colour if free, else the first free one: no two slots share a colour.
func bt_apply_colors() -> void:
	_bt_init_colors()
	var slots := []
	if not _bt_remote.empty():
		slots = _bt_remote.duplicate()
	else:
		var devices := []
		for player in connected_players:
			devices.append(player[0])
		for device in _bt_picks.keys():
			if not devices.has(device):
				_bt_picks.erase(device)
		for p in player_colors.size():
			var pick = _bt_picks.get(devices[p], -1) if p < devices.size() else -1
			slots.append(pick if pick >= 0 and not slots.has(pick) else -1)
		for p in slots.size():
			if slots[p] < 0:
				slots[p] = p if not slots.has(p) else _bt_first_free(slots)
	var changed: bool = slots != bt_slot_colors
	bt_slot_colors = slots
	for p in slots.size():
		player_colors[p] = bt_palette[slots[p]]
	if changed:
		emit_signal("bt_player_colors_changed")


func _bt_first_free(slots: Array) -> int:
	for index in bt_palette.size():
		if not slots.has(index):
			return index
	return 0


# Ignored unless it is one distinct palette index per slot.
func bt_apply_remote_colors(value) -> void:
	_bt_init_colors()
	if typeof(value) != TYPE_ARRAY or value.size() != player_colors.size():
		return
	var slots := []
	for index in value:
		if typeof(index) != TYPE_INT or index < 0 or index >= bt_palette.size():
			return
		if slots.has(index):
			return
		slots.append(index)
	_bt_remote = slots
	bt_apply_colors()


func bt_clear_remote_colors() -> void:
	if _bt_remote.empty():
		return
	_bt_remote = []
	bt_apply_colors()
