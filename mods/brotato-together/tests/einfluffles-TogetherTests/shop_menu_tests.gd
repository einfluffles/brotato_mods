extends Reference
# The client's own pause menu in the shop. Part of the local shop suite (local_shop_tests.gd; s:
# that suite).

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
	pause_control.set_process(true)


func _pause_tap(s, pause_control: Node, shop: Node, you: int):
	for pressed in [true, false]:
		if pressed:
			Input.action_press("ui_pause")
		else:
			Input.action_release("ui_pause")
		pause_control.client_shop_update(shop, you)
		yield(s._t.get_tree(), "idle_frame")
