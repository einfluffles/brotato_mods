extends Reference
# The host's co-op resume screen (extensions/ui/coop_resume.gd): only a join steps to the next saved
# player; a player who leaves gives its saved player back, and the shop loads once every saved
# player has somebody, in the order of the saved players. Part of the selection suite; sets up its
# own run and screens and puts the players back.

const COOP_RESUME := "res://ui/menus/shop/coop_resume.tscn"
const COOP_SHOP := "res://ui/menus/shop/coop_shop.tscn"
const KEYBOARD := 7  # CoopService.KEYBOARD_REMAPPED_DEVICE_ID
const PEER_B_OFFSET := 1  # the second remote player's steam id: FAKE_PEER + this

var t: Node = null
var _input: Node = null
var _peer_a := 0
var _peer_b := 0
var _device_a := 0
var _device_b := 0


func run(test_mod: Node, together: Node):
	t = test_mod
	_input = together.input_sync
	_peer_a = t.FAKE_PEER
	_peer_b = t.FAKE_PEER + PEER_B_OFFSET
	_device_a = t.DEVICE
	_device_b = t.DEVICE + 1
	var players: Array = CoopService.connected_players.duplicate(true)
	var devices: Dictionary = _input.devices.duplicate()
	var listening: bool = CoopService.listening_for_inputs
	yield(_all_join(), "completed")
	yield(_leave_with_two(), "completed")
	yield(_leave_with_three(), "completed")
	CoopService.listening_for_inputs = false
	t.get_tree().change_scene(MenuData.character_selection_scene)
	yield(_frames(2), "completed")
	_input.devices = devices
	CoopService.listening_for_inputs = listening
	CoopService.connected_players = players
	CoopService.bt_apply_colors()
	RunData.reset()


func _frames(count: int):
	for _i in count:
		yield(t.get_tree(), "idle_frame")


# A saved run of `count` players on the host's resume screen, nobody in yet.
func _open(count: int):
	t.coop_run(1)
	RunData.set_player_count(count)
	for i in range(2, count):
		RunData.add_character(ItemService.characters[i], i)
	# No signal: the screen still open (character selection) would set the player count from it.
	CoopService.connected_players.clear()
	_input.devices[_peer_a] = _device_a
	_input.devices[_peer_b] = _device_b
	t.get_tree().change_scene(COOP_RESUME)
	yield(_frames(2), "completed")
	CoopService.bt_apply_colors()


func _join(device: int) -> void:
	var keyboard := device == KEYBOARD
	var type: int = CoopService.PlayerType.GAMEPAD_XBOX
	if keyboard:
		type = CoopService.PlayerType.KEYBOARD_AND_MOUSE
	CoopService._add_player(device, type)


# The remote player leaves the session (InputSync frees its slot while players can join).
func _leave(steam_id: int) -> void:
	_input._on_peer_removed(steam_id)


func _scene_file() -> String:
	var scene: Node = t.get_tree().current_scene
	return scene.filename if scene != null else ""


func _shown() -> int:
	var scene: Node = t.get_tree().current_scene
	if scene == null or scene.filename != COOP_RESUME:
		return -1
	return scene._player_label.player_index


func _order() -> Array:
	var devices := []
	for player in CoopService.connected_players:
		devices.append(player[0])
	return devices


func _all_join():
	yield(_open(2), "completed")
	t._check(_shown() == 0, "resume: the first saved player is shown first (%d)" % _shown())
	_join(KEYBOARD)
	yield(_frames(2), "completed")
	t._check(_shown() == 1, "resume: a join shows the next saved player (%d)" % _shown())
	_join(_device_a)
	yield(_frames(2), "completed")
	t._check(
		_scene_file() == COOP_SHOP and _order() == [KEYBOARD, _device_a],
		"resume: once all have joined the shop loads, in the order they joined (%s, %s)"
		% [_scene_file(), _order()]
	)


func _leave_with_two():
	yield(_open(2), "completed")
	_join(_device_a)
	yield(_frames(2), "completed")
	_leave(_peer_a)
	yield(_frames(2), "completed")
	var stays: bool = _scene_file() == COOP_RESUME and CoopService.connected_players.empty()
	t._check(
		stays and _shown() == 0,
		"resume: a player who leaves does not count as a join; its saved player is shown again (%s, %d)"
		% [_scene_file(), _shown()]
	)
	if not stays:
		return
	_join(KEYBOARD)
	yield(_frames(2), "completed")
	t._check(_shown() == 1, "resume: ... the next join takes it (%d)" % _shown())
	_join(_device_a)
	yield(_frames(2), "completed")
	t._check(
		_scene_file() == COOP_SHOP and _order() == [KEYBOARD, _device_a],
		"resume: ... and the shop loads with both saved players taken (%s, %s)"
		% [_scene_file(), _order()]
	)


# A and B take saved players 1 and 2, A leaves: saved player 1 is shown again, not skipped, and B
# keeps saved player 2 although it moved up in the connected players.
func _leave_with_three():
	yield(_open(3), "completed")
	_join(_device_a)
	_join(_device_b)
	yield(_frames(2), "completed")
	t._check(_shown() == 2, "resume, 3 players: two joins show saved player 3 (%d)" % _shown())
	_leave(_peer_a)
	yield(_frames(2), "completed")
	t._check(
		_scene_file() == COOP_RESUME and _shown() == 0,
		"resume, 3 players: a leave shows the leaver's saved player again (%s, %d)"
		% [_scene_file(), _shown()]
	)
	if _scene_file() != COOP_RESUME:
		return
	_join(KEYBOARD)
	yield(_frames(2), "completed")
	t._check(
		_scene_file() == COOP_RESUME and _shown() == 2,
		"resume, 3 players: ... the next join takes it, saved player 3 is still free (%s, %d)"
		% [_scene_file(), _shown()]
	)
	_join(_device_a)
	yield(_frames(2), "completed")
	t._check(
		_scene_file() == COOP_SHOP and _order() == [KEYBOARD, _device_b, _device_a],
		"resume, 3 players: ... the shop loads with each player on the saved player it took (%s, %s)"
		% [_scene_file(), _order()]
	)
