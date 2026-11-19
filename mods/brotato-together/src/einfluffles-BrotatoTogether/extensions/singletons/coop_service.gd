extends "res://singletons/coop_service.gd"
# Player colours: the game reads every colour from player_colors[slot], so that array is
# rewritten whenever the slots or the players' picks from the palette change. Nothing is saved.

signal bt_player_colors_changed

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
var _bt_picks := {}  # remapped device -> picked palette index
var _bt_remote := []  # client of a lobby: the host's slot colours (palette indices)


func _ready() -> void:
	_bt_init_colors()


# The game would type a remote player's virtual device as keyboard (no joypad name); as a
# gamepad, stick aim and gamepad UI hints apply.
func _add_player(device: int, player_type: int) -> void:
	if VirtualDevices.is_virtual(device):
		player_type = PlayerType.GAMEPAD_XBOX
	._add_player(device, player_type)


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
