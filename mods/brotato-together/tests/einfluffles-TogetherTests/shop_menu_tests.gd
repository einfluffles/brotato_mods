extends Reference
# The client's own pause menu in the shop. Part of the local shop suite (local_shop_tests.gd; s:
# that suite).

const LOBBY := 99

# Esc opens its own menu over its copy (sync/pause_control.gd): nothing pauses, and the own panel
# takes no buttons while it is open.
func client(s, together: Node, shop: Node, emulator: Node):
	var pause_control: Node = together.pause_control
	var menu: Node = shop._pause_menu
	var local = s._sync.local
	var you: int = local.you
	pause_control.set_process(false)  # no session here: its steps are called directly
	yield(s._t.get_tree().create_timer(0.25), "timeout")  # past the menu's back guard
	pause_control.client_shop_update(shop, you)
	s._t._check(menu.live and not menu.live_open, "client shop: the menu is its own")
	s._t._check(
		menu._main_menu.get_node("%RestartButton").disabled,
		"client shop: restart is the host's"
	)
	yield(_pause_tap(s, pause_control, shop, you), "completed")
	s._t._check(
		menu.live_open and menu.visible and menu._player_index == you and not s._t.get_tree().paused,
		"client's pause in the shop opens its own menu, nothing pauses"
	)
	s._t._check(
		s._input.menu_device() == s._t.DEVICE and s._input._local_buttons == null,
		"its buttons drive the menu, not the own panel"
	)
	s._t._check(
		not shop.is_processing_input() and not emulator.is_processing_input(),
		"the shop's own handlers take nothing meanwhile"
	)
	local.process()
	s._t._check(local.local_panel.blocked, "nor the mouse")
	local.set_paused(true)
	pause_control.client_shop_update(shop, you)
	s._t._check(not menu.live_open, "the host's pause closes the client's menu")
	s._t._check(
		s._input.menu_device() == -1 and s._input._local_buttons == null,
		"and the own panel stays off while the host is paused"
	)
	local.set_paused(false)
	pause_control.client_shop_update(shop, you)
	s._t._check(
		s._input._local_buttons != null and shop.is_processing_input()
		and emulator.is_processing_input() and local.local_panel.has_own(),
		"closed: the own panel takes the buttons and the mouse again"
	)
	yield(s._t.get_tree().create_timer(0.25), "timeout")
	yield(_pause_tap(s, pause_control, shop, you), "completed")
	s._t._check(menu.live_open, "the menu opens again")
	yield(s._t.get_tree().create_timer(0.25), "timeout")
	yield(_pause_tap(s, pause_control, shop, you), "completed")
	s._t._check(
		not menu.live_open and s._input._local_buttons != null and shop.is_processing_input(),
		"pause again closes it"
	)
	yield(_dispatch(s, together, shop, emulator), "completed")
	pause_control.set_process(true)


# The same through PauseControl's own dispatch (_update_live_menu), as a client's frame runs it.
func _dispatch(s, together: Node, shop: Node, emulator: Node):
	var pause_control: Node = together.pause_control
	var menu: Node = shop._pause_menu
	yield(s._t.get_tree().create_timer(0.25), "timeout")
	_client_step(s, together)
	s._t._check(
		menu.live and not menu.live_open, "dispatch: a client's shop goes to client_shop_update"
	)
	yield(_client_tap(s, together), "completed")
	s._t._check(
		menu.live_open and s._input.menu_device() == s._t.DEVICE and not shop.is_processing_input(),
		"dispatch: its pause opens its own menu, and the shop takes no input"
	)
	pause_control._update_live_menu()
	s._t._check(
		not menu.live_open and shop.is_processing_input() and emulator.is_processing_input()
		and s._input.menu_device() == -1 and s._input._local_buttons != null,
		"dispatch: no session any more, the menu closes and the shop takes its input again"
	)
	yield(s._t.get_tree().create_timer(0.25), "timeout")
	var saved := _fake_client(s, together)
	pause_control._update_live_menu()
	var asked = pause_control.open_menu()  # LobbyMenu.open: an invite or leave question
	pause_control._update_live_menu()
	var own: bool = asked == menu and menu.live_open and not shop.is_processing_input()
	menu.unpause()
	pause_control._update_live_menu()
	var closed: bool = not menu.live_open and shop.is_processing_input()
	_end_fake(together, saved)
	s._t._check(own, "a lobby question in the shop opens the client's own menu (open_menu)")
	s._t._check(closed, "and closing it gives the shop its input back")


# The host starts the wave while the client's menu is open with the codex up: the shop goes with
# the menu (extensions/ui/pause_menu.gd, _exit_tree) and leaves nothing of it behind. Frees the
# shop: last in the client part.
func client_leave(s, together: Node, shop: Node):
	var pause_control: Node = together.pause_control
	var local = s._sync.local
	var menu: Node = shop._pause_menu
	var tree: SceneTree = s._t.get_tree()
	pause_control.set_process(false)
	local.guard(shop, s._sync._client_shop_id)
	local.take_over(0)
	yield(tree.create_timer(0.25), "timeout")
	_client_step(s, together)
	yield(_client_tap(s, together), "completed")
	menu._main_menu.emit_signal("codex_button_pressed")
	s._t._check(
		menu.live_open and menu.codex_is_opened and Utils._popup == menu._menus._codex,
		"leaving: the client's menu is open over its shop, with the codex"
	)
	tree.change_scene_to(_empty_scene())
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	s._t._check(
		not is_instance_valid(shop) and typeof(Utils._popup) == TYPE_NIL,
		"the shop went with the menu open: the codex is not left as Utils._popup"
	)
	_client_step(s, together)
	s._t._check(
		s._input.menu_device() == -1 and pause_control._inert_shop_id == 0
		and not local.active and not local.is_menu_open(),
		"and in the next scene the menu's device is free, nothing of the shop is held"
	)
	pause_control.set_process(true)


# This machine as a client of FAKE_PEER. No frame passes until _end_fake: nothing else runs as a
# client meanwhile.
static func _fake_client(s, together: Node) -> Array:
	var transport: Node = together.transport
	var saved := [transport.lobby_id, transport.host_id]
	transport.lobby_id = LOBBY
	transport.host_id = s._t.FAKE_PEER
	return saved


static func _end_fake(together: Node, saved: Array) -> void:
	together.transport.lobby_id = saved[0]
	together.transport.host_id = saved[1]


# PauseControl's dispatch in one frame of this machine as a client.
static func _client_step(s, together: Node) -> void:
	var saved := _fake_client(s, together)
	together.pause_control._update_live_menu()
	_end_fake(together, saved)


# Esc down in one frame, up in the next (one frame would be a press, not a release).
static func _client_tap(s, together: Node):
	Input.action_press("ui_pause")
	_client_step(s, together)
	yield(s._t.get_tree(), "idle_frame")
	Input.action_release("ui_pause")
	_client_step(s, together)


static func _empty_scene() -> PackedScene:
	var node := Node.new()
	node.name = "AfterTheShop"
	var packed := PackedScene.new()
	packed.pack(node)
	node.free()
	return packed


func _pause_tap(s, pause_control: Node, shop: Node, you: int):
	for pressed in [true, false]:
		if pressed:
			Input.action_press("ui_pause")
		else:
			Input.action_release("ui_pause")
		pause_control.client_shop_update(shop, you)
		yield(s._t.get_tree(), "idle_frame")
