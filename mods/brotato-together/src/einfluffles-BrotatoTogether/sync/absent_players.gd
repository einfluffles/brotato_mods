extends Node
# Host: a remote player who dropped mid-run keeps their co-op slot (input_sync.gd, for a rejoin),
# but the shop's Go and the level-up / crate panels wait for every player. Once a player has been
# silent (stale or gone) for ABSENT_MSEC, their pending choices are made the game's way:
# - level-up: the first offered upgrade (UpgradesUIPlayerContainer._on_choose_button_pressed)
# - crate: take the item, or recycle it when it can't be taken (no weapon slot, meca choice)
# - shop: Go (BaseShop._on_GoButton_pressed)
# A player who answers again is simply back: nothing else changes. Shown in the F9 menu / pill.

const LOG_NAME := "einfluffles-BrotatoTogether:AbsentPlayers"
const SHOP_SCENE := "res://ui/menus/shop/coop_shop.tscn"
const ABSENT_MSEC := 20000
const CHECK_INTERVAL := 0.5

var session: Node = null
var input_sync: Node = null
var battle_host: Node = null
var absent := {}  # steam_id -> msec silent (at least Session.PEER_STALE_MSEC)

var _names := {}  # steam_id -> name (kept after the peer is gone)
var _gone_since := {}  # steam_id -> msec when the peer left the lobby
var _check_left := 0.0


func setup(netplay_session: Node, remote_input: Node, host_battle: Node) -> void:
	session = netplay_session
	input_sync = remote_input
	battle_host = host_battle
	session.connect("peer_ready", self, "_on_peer_ready")
	session.connect("peer_removed", self, "_on_peer_removed")
	session.transport.connect("lobby_left", self, "_on_lobby_left")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func display_name(steam_id: int) -> String:
	return _names.get(steam_id, str(steam_id))


# "Name (away 12 s, auto in 8 s)" per absent player, for the F9 menu.
func describe() -> Array:
	var lines := []
	for steam_id in absent:
		var silent: int = absent[steam_id]
		var state := "choices made automatically"
		if silent < ABSENT_MSEC:
			state = "auto-continue in %d s" % ceil((ABSENT_MSEC - silent) / 1000.0)
		lines.append("%s away %d s · %s" % [display_name(steam_id), silent / 1000, state])
	return lines


func _on_peer_ready(steam_id: int) -> void:
	_names[steam_id] = session.peers[steam_id].name
	_gone_since.erase(steam_id)
	absent.erase(steam_id)


func _on_peer_removed(steam_id: int) -> void:
	_gone_since[steam_id] = OS.get_ticks_msec()


func _on_lobby_left() -> void:
	absent.clear()
	_gone_since.clear()


func _process(delta: float) -> void:
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = CHECK_INTERVAL
	if not session.is_host():
		absent.clear()
		return
	check(OS.get_ticks_msec())


func check(now: int) -> void:
	for steam_id in input_sync.devices:
		var index := _player_index(input_sync.devices[steam_id])
		var silent := _silent_msec(steam_id, now)
		if index < 0 or silent < session.PEER_STALE_MSEC:
			absent.erase(steam_id)
			continue
		absent[steam_id] = silent
		if silent >= ABSENT_MSEC:
			resolve(index)


func _silent_msec(steam_id: int, now: int) -> int:
	if session.peers.has(steam_id):
		return now - int(session.peers[steam_id].last_seen_msec)
	if not _gone_since.has(steam_id):
		_gone_since[steam_id] = now
	return now - int(_gone_since[steam_id])


func _player_index(device: int) -> int:
	for i in CoopService.connected_players.size():
		if CoopService.connected_players[i][0] == device:
			return i
	return -1


# Makes whatever choice player `index` is holding everyone up with. Safe to call repeatedly.
func resolve(index: int) -> void:
	if get_tree().paused:
		return
	var scene := get_tree().current_scene
	if scene != null and scene.filename == SHOP_SCENE:
		if index < scene._player_pressed_go_button.size():
			if not scene._player_pressed_go_button[index]:
				ModLoaderLog.info("Absent player %s: Go" % index, LOG_NAME)
				scene._on_GoButton_pressed(index)
		return
	if not battle_host.is_in_battle():
		return
	var ui = battle_host._main.get("_coop_upgrades_ui")
	if ui != null and ui.visible:
		resolve_panel(ui._get_player_container(index))


static func resolve_panel(container: Node) -> void:
	if container._checkmark_group.visible or container._button_pressed:
		return
	if container._upgrades_container.visible and not container._old_upgrades.empty():
		container._on_choose_button_pressed(container._old_upgrades[0])
	elif container._items_container.visible and container._item_data != null:
		if can_take(container):
			container._on_TakeButton_pressed()
		else:
			container._on_DiscardButton_pressed()


# The checks of UpgradesUIPlayerContainer._update_take_button / _on_TakeButton_pressed.
static func can_take(container: Node) -> bool:
	var item = container._item_data
	if item is WeaponData and not RunData.can_take_weapon(item, container.player_index):
		return false
	return not (container._needs_meca_effect_choice() and container._meca_effect_choice_selected < 0)
