extends Reference
# Suite shop_loopback: the host opens the real co-op shop (rolls items) and buys slot 1; the
# client mirrors both states, the host's cursor and the shop's sounds. Plays on mod_main's
# two-player run (coop_run); checks go through its _check.

const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const ScenePaths := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/scene_paths.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const PerfTests := preload("res://mods-unpacked/einfluffles-TogetherTests/battle_perf_tests.gd")

var t: Node  # the test mod: _check, helpers, scene tree
var _perf = null


func _init(test_mod: Node) -> void:
	t = test_mod
	_perf = PerfTests.new(test_mod)


func run(together: Node):
	var shop_sync: Node = together.shop_sync
	shop_sync.set_process(false)  # driven by hand (no Steam session)
	CoopService.connected_players.clear()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	RunData.current_wave = 2
	RunData.add_gold(500, 0)
	t.get_tree().change_scene(RunData.get_shop_scene_path())
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var host_shop := t.get_tree().current_scene
	t._check(host_shop.filename == shop_sync.SHOP_SCENE, "host co-op shop loaded")
	shop_sync._host_shop = host_shop
	shop_sync._shop_id = 7
	_perf.test_shop_compare(shop_sync)
	var before: Dictionary = bytes2var(var2bytes(shop_sync._shop_body()), false)
	var host_before: Array = t._shop_slots(host_shop, 0)

	var container = host_shop._get_shop_items_container(0)
	var bought = container.get_shop_item_node(1)
	var bought_id: String = bought.item_data.my_id
	var gold_before: int = RunData.get_player_gold(0)
	var host_sounds: Dictionary = yield(_ui_sounds_host_buy(together, bought), "completed")
	var after: Dictionary = bytes2var(var2bytes(shop_sync._shop_body()), false)

	# Host cursor for player 0 on shop slot 2 (focus mirroring, another mod's nodes on the host).
	var focus_sync: Node = together.focus_sync
	var host_emulator = Utils.get_focus_emulator(0, host_shop)
	host_emulator.focused_control = container.get_shop_item_node(2)._button
	focus_sync._scene = host_shop
	focus_sync._emulators = ScenePaths.find_focus_emulators(host_shop)
	var cursors: Array = preload("cursor_target_tests.gd").host_cursors(focus_sync, host_shop)
	var focus_body := {"scene": host_shop.filename, "cursors": cursors}
	var host_after: Array = t._shop_slots(host_shop, 0)
	var host_gold_after: int = RunData.get_player_gold(0)
	t._check(host_gold_after < gold_before, "host bought %s" % bought_id)
	print("  info: shop state %d B on the wire" % var2bytes(after).size())

	# --- client ---
	shop_sync._client_shop_id = 0
	var state := RunStateCodec.decode(before.run)
	shop_sync._pending = {"state": state, "slots": before.slots, "go": before.go}
	shop_sync._client_shop_id = before.shop_id
	shop_sync._enter_shop(state)
	yield(shop_sync, "shop_entered")
	var client_shop: Node = shop_sync._client_shop
	t._check(client_shop != host_shop, "client loaded its own shop")
	t._check(not client_shop._pause_menu.enabled, "client shop can't pause locally")
	t._check(
		t._shop_slots(client_shop, 0) == host_before,
		"client shows host's items %s" % [t._shop_slots(client_shop, 0)]
	)

	var dropped_before: int = t._hold_sounds(true)
	shop_sync._pending = {
		"state": RunStateCodec.decode(after.run), "slots": after.slots, "go": after.go
	}
	shop_sync._apply_pending()
	t._check(
		t._shop_slots(client_shop, 0) == host_after,
		"client mirrors purchase %s == %s" % [t._shop_slots(client_shop, 0), host_after]
	)
	t._check(RunData.get_player_gold(0) == host_gold_after, "client gold matches host")
	yield(t.get_tree(), "idle_frame")
	focus_sync._apply(focus_body)
	var client_focus = Utils.get_focus_emulator(0, client_shop).focused_control
	t._check(
		client_focus == client_shop._get_shop_items_container(0).get_shop_item_node(2)._button,
		"client cursor mirrors host cursor (another mod's nodes on the host only)"
	)
	_test_ui_sounds_client(together, host_sounds, dropped_before)
	var owned := false
	for element in RunData.get_player_weapons(0) + RunData.get_player_items(0):
		owned = owned or element.my_id == bought_id
	t._check(owned, "client inventory has %s" % bought_id)
	Puppet.set_active(false)
	shop_sync._host_shop = null  # set by hand above: the host shop is gone with the next scene
	shop_sync.set_process(true)


# Host presses the shop item's real Buy button: its press sound plays through SoundManager, and
# everything the host plays outside battle is recorded for clients (UiSounds).
func _ui_sounds_host_buy(together: Node, shop_item: Node):
	var ui_sounds: Node = together.ui_sounds
	ui_sounds.set_process(false)  # driven by hand (no Steam session)
	SoundRelay.set_ui_sink(ui_sounds)
	t._hold_sounds(true)
	shop_item._button.emit_signal("pressed")  # the buy itself is a deferred connection
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var played := _queued_sound_paths()
	var body: Dictionary = bytes2var(var2bytes(ui_sounds.take_batch()), false)
	SoundRelay.set_ui_sink(null)
	t._hold_sounds(false)
	ui_sounds.set_process(true)
	var sent := _batch_paths(body)
	print("  info: host played %s, sent %s (%d B)" % [played, sent, var2bytes(body).size()])
	t._check("res://ui/sounds/button_press.wav" in sent, "host sends the purchase sound")
	t._check(sent == played, "host sends every sound it played in the shop")
	return body


# Client: mirroring the purchase and the cursor in the puppet shop plays nothing locally; the
# host's batch plays exactly once.
func _test_ui_sounds_client(together: Node, host_sounds: Dictionary, dropped_before: int) -> void:
	var local := _queued_sound_paths()
	var dropped: int = SoundRelay.dropped_count() - dropped_before
	print("  info: client mirroring muted %d local sounds" % dropped)
	t._check(local.empty() and dropped > 0, "mirrored shop plays no local sounds %s" % [local])
	var played: int = together.ui_sounds.play_batch(host_sounds)
	var heard := _queued_sound_paths()
	t._check(
		played > 0 and heard == _batch_paths(host_sounds),
		"client plays exactly the host's sounds %s" % [heard]
	)
	t._hold_sounds(false)
	_test_ui_sound_validation(together.ui_sounds)


# Sound paths come from the network: only existing res:// sound files are played.
func _test_ui_sound_validation(ui_sounds: Node) -> void:
	t._check(SoundRelay.is_sound_path("res://ui/sounds/buy.wav"), "UI sound path accepted")
	var rejected := true
	for path in ["user://a.wav", "res://../a.wav", "res://main.tscn", "res://a.wav::1", 42, null]:
		rejected = rejected and not SoundRelay.is_sound_path(path)
	t._check(rejected, "non-sound paths rejected")
	t._hold_sounds(true)
	var bad := {
		"sounds":
		[
			["res://ui/menus/shop/coop_shop.tscn", 0.0, 0.0, null],
			["res://../ui/sounds/buy.wav", 0.0, 0.0, null],
			["user://buy.wav", 0.0, 0.0, null],
			["res://ui/sounds/does_not_exist.wav", 0.0, 0.0, null],
			["res://ui/sounds/buy.wav", "loud", 0.0, null],
			["res://ui/sounds/buy.wav", 0.0, 0.0, "here"],
			["res://ui/sounds/buy.wav"],
			"res://ui/sounds/buy.wav",
		]
	}
	var played: int = ui_sounds.play_batch(bad)
	played += ui_sounds.play_batch("res://ui/sounds/buy.wav")
	played += ui_sounds.play_batch({"sounds": 3})
	t._check(played == 0 and _queued_sound_paths().empty(), "malformed UI sounds rejected")
	t._hold_sounds(false)


func _queued_sound_paths() -> Array:
	var paths := []
	for manager in [SoundManager, SoundManager2D]:
		for entry in manager.sounds_to_play:
			paths.append(entry[0].resource_path if entry[0] != null else "")
	paths.sort()
	return paths


func _batch_paths(body: Dictionary) -> Array:
	var paths := []
	if typeof(body.get("sounds")) == TYPE_ARRAY:
		for entry in body.sounds:
			paths.append(entry[0])
	paths.sort()
	return paths
