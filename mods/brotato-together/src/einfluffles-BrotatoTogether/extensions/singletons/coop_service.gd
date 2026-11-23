extends "res://singletons/coop_service.gd"
# Player colours: the game reads every colour from player_colors[slot], so that array is
# rewritten whenever the slots or the players' picks from the palette change. A player in a slot
# keeps the colour it shows until it picks another. In a lobby a pick belongs to the player while
# it is in the lobby, whatever slot it takes. Nothing is saved.

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
# Host: who plays on a remapped device (InputSync: steam_id_of); null or -1: a local player.
var bt_players: Object = null
var _bt_lobby := false  # picks outlive the player's slot (bt_set_lobby)
var _bt_picks := {}  # player (_bt_slot_players) -> picked palette index
var _bt_local := []  # device of the i-th local player ("local:i"), kept across runs
var _bt_borrow := {}  # local device in a slot without an entry -> the waiting entry it borrows
var _bt_shown := {}  # device in a slot -> the palette index it shows
var _bt_remote := []  # client of a lobby: the host's slot colours (palette indices)


func _ready() -> void:
	_bt_init_colors()


# In character selection a remote player's hold to join counts only once a player of this machine
# is in, so the host's player joins first. Runs before the game's _process (both levels are
# called), which adds delta: from -delta even one long frame cannot reach HOLD_DURATION.
func _process(delta: float) -> void:
	if not bt_holds_wait(get_tree().current_scene):
		return
	for device in _hold_timers:
		if VirtualDevices.is_virtual(device):
			_hold_timers[device] = -delta


# Not on the co-op resume screen: its slot order decides who gets which saved character.
func bt_holds_wait(scene: Node) -> bool:
	return (
		scene != null
		and scene.filename == MenuData.character_selection_scene
		and not bt_local_joined()
	)


func bt_local_joined() -> bool:
	for player in connected_players:
		if not VirtualDevices.is_virtual(player[0]):
			return true
	return false


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


# Open: picks stay while the player is out of a slot (next run). Closed: the picks of players
# out of a slot go; the others go with their slot, as outside a lobby.
func bt_set_lobby(open: bool) -> void:
	_bt_lobby = open
	if not open:
		_bt_prune(_bt_slot_players())


# A remote player who is gone (no slot kept for a rejoin); a slot it still has keeps its colour.
func bt_forget_player(steam_id: int) -> void:
	_bt_picks.erase("steam:%d" % steam_id)


# Who plays in each slot: "steam:<id>" for a remote player, "local:<i>" for a local one. A local
# device has its own entry. One that joins without one takes the entry of a device that is gone (a
# replugged pad), else borrows the entry of one that has not joined (the host on another pad),
# else gets a new entry. A borrow lasts while the borrower stays in its slot and the lender has not
# joined; once the lender joins, the borrower gets a new entry.
func _bt_slot_players() -> Array:
	var players := []
	var unbound := []
	var spare := range(_bt_local.size())
	for player in connected_players:
		var device: int = player[0]
		var steam_id: int = bt_players.steam_id_of(device) if bt_players != null else -1
		var entry := _bt_local.find(device)
		if steam_id >= 0:
			players.append("steam:%d" % steam_id)
		elif VirtualDevices.is_virtual(device):
			players.append("device:%d" % device)  # no peer behind it (tests)
		elif entry >= 0:
			spare.erase(entry)
			players.append("local:%d" % entry)
		else:
			unbound.append(players.size())
			players.append("")
	var borrows := {}
	for p in unbound:
		var device: int = connected_players[p][0]
		var entry: int = _bt_borrow.get(device, -1)
		if spare.has(entry):
			spare.erase(entry)
			borrows[device] = entry
			players[p] = "local:%d" % entry
	_bt_borrow = borrows
	var gone := []
	var waiting := []
	for entry in spare:
		if _bt_device_present(_bt_local[entry]):
			waiting.append(entry)
		else:
			gone.append(entry)
	for p in unbound:
		if not players[p].empty():
			continue
		var device: int = connected_players[p][0]
		var entry: int
		if not gone.empty():
			entry = gone.pop_front()
			_bt_local[entry] = device
		elif not waiting.empty():
			entry = waiting.pop_front()
			_bt_borrow[device] = entry
		else:
			entry = _bt_local.size()
			_bt_local.append(device)
		players[p] = "local:%d" % entry
	return players


# Keyboards (also the debug ones) are always there; a pad while its joypad is connected.
func _bt_device_present(device: int) -> bool:
	if device == KEYBOARD_REMAPPED_DEVICE_ID or device >= FIRST_DEBUG_DEVICE_ID:
		return true
	var joypad := 0 if device == GAMEPAD_REMAPPED_DEVICE_ID else device
	return Input.get_connected_joypads().has(joypad)


func _bt_prune(players: Array) -> void:
	for player in _bt_picks.keys():
		if not players.has(player):
			_bt_picks.erase(player)


# Picks kept for players out of a slot: local players' (with local) and those of peers still in the
# session (a peer gone for good reserves nothing; a rejoin brings its pick back).
func _bt_reserved(players: Array, local := true) -> Array:
	var reserved := []
	for player in _bt_picks:
		if players.has(player):
			continue
		if player.begins_with("local:"):
			if local:
				reserved.append(_bt_picks[player])
		elif player.begins_with("steam:") and bt_players.has_peer(int(player.substr(6))):
			reserved.append(_bt_picks[player])
	return reserved


# The next colour no other slot shows and nobody out of a slot has reserved. A local player passes
# over local reservations: they may be its own pick from another device (the host on a pad).
func bt_cycle_color(player_index: int, step := 1) -> bool:
	_bt_init_colors()
	if not _bt_remote.empty() or player_index < 0 or player_index >= connected_players.size():
		return false
	var device: int = connected_players[player_index][0]
	var players := _bt_slot_players()
	var local: bool = players[player_index].begins_with("local:")
	if local and not _bt_local.has(device):
		_bt_local.append(device)  # a borrowed entry stays its device's
		players = _bt_slot_players()
	var taken := _bt_reserved(players, not local)
	for p in connected_players.size():
		if p != player_index:
			taken.append(bt_slot_colors[p])
	var index: int = bt_slot_colors[player_index]
	for _i in bt_palette.size():
		index = posmod(index + step, bt_palette.size())
		if not taken.has(index):
			break
	if index == bt_slot_colors[player_index] or taken.has(index):
		return false
	_bt_picks[players[player_index]] = index
	_bt_shown[device] = index
	bt_apply_colors()
	return true


# A device that stays in its slot keeps the colour it shows, whoever joins or leaves. One that
# comes into a slot gets its player's pick unless another slot has it (the pick is kept for later),
# then each remaining slot, empty ones too, its default colour if free and not reserved, else the
# first such one: no two slots share a colour.
func bt_apply_colors() -> void:
	_bt_init_colors()
	var slots := []
	if not _bt_remote.empty():
		slots = _bt_remote.duplicate()
		_bt_shown.clear()
	else:
		var players := _bt_slot_players()
		if not _bt_lobby:
			_bt_prune(players)
		slots = _bt_assign(players)
	var changed: bool = slots != bt_slot_colors
	bt_slot_colors = slots
	for p in slots.size():
		player_colors[p] = bt_palette[slots[p]]
	if changed:
		emit_signal("bt_player_colors_changed")


func _bt_assign(players: Array) -> Array:
	var slots := []
	for _p in player_colors.size():
		slots.append(-1)
	var count: int = int(min(players.size(), slots.size()))
	for p in count:
		var shown: int = _bt_shown.get(connected_players[p][0], -1)
		if shown >= 0 and not slots.has(shown):
			slots[p] = shown
	for p in count:
		var pick: int = _bt_picks.get(players[p], -1)
		if slots[p] < 0 and pick >= 0 and not slots.has(pick):
			slots[p] = pick
	var reserved := _bt_reserved(players)
	for p in slots.size():
		if slots[p] < 0:
			var vacant := not slots.has(p) and not reserved.has(p)
			slots[p] = p if vacant else _bt_first_free(slots, reserved)
	_bt_shown.clear()
	for p in count:
		_bt_shown[connected_players[p][0]] = slots[p]
	return slots


func _bt_first_free(slots: Array, reserved: Array) -> int:
	for skip in [reserved, []]:
		for index in bt_palette.size():
			if not slots.has(index) and not skip.has(index):
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
