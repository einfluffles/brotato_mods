extends "res://ui/menus/shop/coop_resume.gd"
# The co-op resume screen shows one saved player at a time; whoever joins takes it. The game steps
# to the next saved player on every change of the connected players, a leave too (a remote player
# leaving the session, a pad unplugged): a saved player was skipped, and the last step loaded the
# shop with fewer players than the run has. Here only a join steps. A player who leaves gives its
# saved player back, and the lowest saved player nobody has is shown. The game gives saved player i
# to connected_players[i], so before the shop loads the players are put in the order of the saved
# players they took (after a leave, those who joined later moved up). A client's copy
# (sync/menu_puppet.gd) shows the host's saved player and decides nothing.

const PuppetMenu := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet_menu.gd"
)

var _bt_taken := {}  # device -> the saved player it took
var _bt_free := []  # saved players nobody has, lowest first; the first is the one shown
var _bt_done := false  # every saved player taken: the shop is loading


func _ready() -> void:
	_bt_free = range(RunData.get_player_count())


func _on_connected_players_updated(connected_players: Array) -> void:
	if _bt_done or PuppetMenu.Puppet.is_active():
		return
	var devices := []
	for player in connected_players:
		devices.append(player[0])
	for device in _bt_taken.keys():
		if not devices.has(device):
			_bt_free.append(_bt_taken[device])
			_bt_taken.erase(device)
	_bt_free.sort()
	for device in devices:
		if not _bt_taken.has(device) and not _bt_free.empty():
			_bt_taken[device] = _bt_free.pop_front()
	_players_to_join = _bt_free.duplicate()  # the game's list: those after the one shown
	if not _players_to_join.empty():
		_players_to_join.pop_front()
	if _bt_free.empty():
		_bt_done = true
		_bt_order_players()
		_setup_next_player()  # loads the shop
	elif _player_label.player_index != _bt_free[0]:
		_update_player_index(_bt_free[0])
		set_controller_colors()


# connected_players in the order of the saved players taken; devices that took none (none join
# once every saved player is taken) stay behind them.
func _bt_order_players() -> void:
	var players: Array = CoopService.connected_players
	var ordered := []
	for index in RunData.get_player_count():
		for player in players:
			if _bt_taken.get(player[0], -1) == index:
				ordered.append(player)
	for player in players:
		if not ordered.has(player):
			ordered.append(player)
	if ordered == players:
		return
	players.clear()
	players.append_array(ordered)
	CoopService.emit_signal("connected_players_updated", players)
