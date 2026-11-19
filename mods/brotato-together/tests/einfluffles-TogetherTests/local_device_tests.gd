extends Reference
# Suite local_device: which screen drives the client's own slot device when the level-up panels
# hand over to the shop, and the host's pause across that change. Past bug: a pick that ended the
# panels inside a pause loaded the shop paused with the pause menu gone.

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const ShopStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_stream_tests.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const BATTLE_SCENE := "res://main.tscn"
const REMOTE := 1  # the client's player
const SHOP_FRAMES := 30  # how long a shop may take to load
const BUTTON_DELAY_SEC := 0.15  # UpgradesUIPlayerContainer's ButtonDelayTimer: 0.1 s

var _t: Node = null
var _together: Node = null
var _shop_sync: Node = null
var _upgrades: Node = null
var _input: Node = null
var _run_shop := {}  # RUN_SHOP body for the client, from the host's shop
var _pause_shop := []  # PAUSE_SHOP body for the client, from the host's shop
var _shop: Node = null


func run(t: Node, together: Node):
	_t = t
	_together = together
	_shop_sync = together.shop_sync
	_upgrades = together.upgrades_sync
	_input = together.input_sync
	_shop_sync.set_process(false)  # driven by hand (no Steam session)
	together.battle_host.set_process(false)
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	var saved_devices: Dictionary = _input.devices.duplicate()
	yield(_host_pause_across_level_ups(), "completed")
	_input.devices = saved_devices
	yield(_client_shop(), "completed")
	_late_level_up_stops()
	_lost_device()
	yield(_pause_of_an_old_shop(), "completed")
	_stale_shop_pause()
	_shop_sync.local.leave(_shop)
	_upgrades._local_active = false
	Puppet.set_active(false)
	_shop_sync._host_shop = null
	_shop_sync.set_process(true)
	together.battle_host.set_process(true)
	CoopService.connected_players = saved_players
	_t.get_tree().paused = false


func _host_pause_across_level_ups():
	var tree: SceneTree = _t.get_tree()
	CoopService.connected_players.clear()
	CoopService.connected_players.push_back([0, CoopService.PlayerType.GAMEPAD_XBOX])
	CoopService.connected_players.push_back([_t.DEVICE, CoopService.PlayerType.GAMEPAD_XBOX])
	_input.devices[_t.FAKE_PEER] = _t.DEVICE
	var main: Node = yield(_enter_battle(), "completed")
	var ui: Node = main.get("_coop_upgrades_ui")
	# The tail of main._on_EndWaveTimer_timeout: the shop once every panel is done.
	ui.connect("options_processed", self, "_on_options_processed", [ui], CONNECT_ONESHOT)
	var level := UpgradesUI.UpgradeToProcess.new()
	level.level = 2
	level.player_index = REMOTE
	ui.show_options([[], [], [], []], [[], [level], [], []])
	ui.show()
	_t._check(
		ui._get_player_container(0)._checkmark_group.visible,
		"local device: the host's own panel is done, the remote player still picks"
	)
	_upgrades._update_seqs(ui, _upgrades.capture(ui))
	var container = ui._get_player_container(REMOTE)
	var intent := {
		"battle_id": _together.battle_host._battle_id,
		"seq": _upgrades._seqs[REMOTE],
		"kind": "choose",
		"id": container._old_upgrades[0].my_id,
	}

	yield(tree.create_timer(BUTTON_DELAY_SEC), "timeout")  # the panel takes presses now
	var menu: Node = main._pause_menu
	menu.pause(0)
	_t._check(tree.paused, "local device: the host paused during the level-ups")
	_upgrades.host_apply_intent(ui, REMOTE, intent)  # the remote player's pick arrives
	yield(_frames(3), "completed")
	var scene: Node = tree.current_scene
	_t._check(
		scene != null and scene.filename == BATTLE_SCENE,
		"local device: a pick made during the host's pause does not end the panels in it"
	)
	if is_instance_valid(menu) and menu.is_inside_tree():
		menu.unpause()  # the host resumes (gone if the shop came meanwhile)
	var shop: Node = yield(_scene(RunData.get_shop_scene_path()), "completed")
	_t._check(shop != null, "local device: the pick counted once the host resumed: the shop came")
	if shop == null:
		tree.paused = false
		return
	yield(_frames(2), "completed")
	_t._check(not tree.paused, "local device: the host's shop does not start paused")
	_shop_sync._host_shop = shop
	_shop_sync._shop_id = 31
	_run_shop = _shop_sync.state_body(StateStream.RUN_SHOP)
	_run_shop["you"] = REMOTE
	_pause_shop = _together.pause_control.state_body(StateStream.PAUSE_SHOP)
	_t._check(
		_pause_shop.size() == 3 and not _pause_shop[0],
		"local device: the shop's pause state says not paused (%s)" % [_pause_shop]
	)
	tree.paused = false


func _on_options_processed(ui: Node) -> void:
	ui.hide()
	_t.get_tree().change_scene(RunData.get_shop_scene_path())


# The host's battle scene, cleaned up the way main.clean_up_room leaves it for the panels.
func _enter_battle():
	var tree: SceneTree = _t.get_tree()
	tree.change_scene(BATTLE_SCENE)
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main: Node = tree.current_scene
	_together.battle_host._start_battle(main)
	main._wave_timer.stop()
	main._entity_spawner.clean_up_room()
	main._wave_manager.clean_up_room()
	for player in main._players:
		if is_instance_valid(player):
			player.on_room_cleanup()
	yield(tree.create_timer(0.3), "timeout")
	return main


func _client_shop():
	if _run_shop.empty():
		return yield(_frames(1), "completed")
	_shop_sync._client_shop_id = 0
	var stream: Node = _shop_sync.state_stream
	ShopStreamTests.deliver(stream, StateStream.RUN_SHOP, _run_shop)
	ShopStreamTests.deliver(stream, StateStream.PAUSE_SHOP, _pause_shop)
	yield(_shop_sync, "shop_entered")
	yield(_frames(2), "completed")
	_shop = _shop_sync._client_shop
	var local = _shop_sync.local
	_t._check(local.active and local.you == REMOTE, "local device: the own shop panel runs here")
	_t._check(
		_drives_own_device(),
		"local device: after a host pause across the level-ups the own shop panel drives its device"
	)


# The level-up panels still believe their own panel runs (a stop that comes after the shop took
# over): each late way they stop leaves the shop's device and cursor alone.
func _late_level_up_stops() -> void:
	if _shop == null:
		return
	var local = _shop_sync.local
	var emulator = Utils.get_focus_emulator(REMOTE, _shop)
	_resume()
	for stop in ["stop_local", "clear_state", "_on_battle_left", "_report_own_focus"]:
		local.take_over(REMOTE)  # what each state from the host does
		_t._check(_drives_own_device(), "local device: the shop panel drives (before %s)" % stop)
		_upgrades._local_active = true
		if stop == "clear_state":
			_upgrades.clear_state(StateStream.UPGRADES)
		else:
			_upgrades.call(stop)
		_t._check(
			not _upgrades._local_active and _drives_own_device(),
			"local device: the level-up panels' late %s leaves the shop its device" % stop
		)
		_t._check(
			emulator in _together.focus_sync.local_emulators,
			"local device: and its own cursor (%s)" % stop
		)


# Something this suite does not know turned the device off: the shop takes it back.
func _lost_device() -> void:
	if _shop == null:
		return
	_resume()
	_shop_sync.local.take_over(REMOTE)
	_t._check(_drives_own_device(), "local device: the shop panel drives (before the loss)")
	_input._local_buttons = null
	_shop_sync.local.process()
	_t._check(_drives_own_device(), "local device: the shop panel takes a lost device back")


# The host paused in this shop and left it from its pause menu: its pause section ends. The
# next shop's own panel runs before that shop's pause state arrives.
func _pause_of_an_old_shop():
	if _shop == null:
		return yield(_frames(1), "completed")
	var stream: Node = _shop_sync.state_stream
	ShopStreamTests.deliver(stream, StateStream.PAUSE_SHOP, [true, "", 0])
	_t._check(_input._local_buttons == null, "local device: off while the host is paused")
	ShopStreamTests.deliver(stream, StateStream.PAUSE_SHOP, null)
	var next := _run_shop.duplicate()
	next.shop_id = _run_shop.shop_id + 1
	ShopStreamTests.deliver(stream, StateStream.RUN_SHOP, next)
	yield(_shop_sync, "shop_entered")
	yield(_frames(2), "completed")
	_shop = _shop_sync._client_shop
	_t._check(
		_drives_own_device(),
		"local device: a pause that ended with its shop leaves the next shop's panel on"
	)


# Host safety net (PauseControl.release_stale_pause, run when the host's scene changes): a shop
# that starts paused with its pause menu closed is resumed; a shop whose menu shows stays paused.
func _stale_shop_pause() -> void:
	if _shop == null:
		return
	var tree: SceneTree = _t.get_tree()
	var control: Node = _together.pause_control
	tree.paused = true
	_t._check(
		control.release_stale_pause(_shop) and not tree.paused,
		"local device: a shop that starts paused with its pause menu closed is resumed"
	)
	tree.paused = true
	_shop._pause_menu.show()
	_t._check(
		not control.release_stale_pause(_shop) and tree.paused,
		"local device: not while its pause menu shows"
	)
	_shop._pause_menu.hide()
	tree.paused = false


# The host's shop pause state says not paused (whatever an earlier check left).
func _resume() -> void:
	ShopStreamTests.deliver(_shop_sync.state_stream, StateStream.PAUSE_SHOP, [false, "", 0])


func _drives_own_device() -> bool:
	var device: int = CoopService.get_remapped_player_device(REMOTE)
	return _input._local_buttons != null and _input._local_buttons.device == device


# The current scene once it is path (null if it does not come).
func _scene(path: String):
	var tree: SceneTree = _t.get_tree()
	for _i in SHOP_FRAMES:
		yield(tree, "idle_frame")
		var scene: Node = tree.current_scene
		if scene != null and scene.filename == path:
			return scene
	return null


func _frames(count: int):
	for _i in count:
		yield(_t.get_tree(), "idle_frame")
