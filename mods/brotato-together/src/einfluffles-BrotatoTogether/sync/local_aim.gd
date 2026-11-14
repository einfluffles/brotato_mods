extends Reference
# Client: this player's own aim preference, sent with every INPUT. The host types remote players
# as gamepads, so without this its own manual-aim setting would decide for them, and keyboard
# players would aim at gamepad_attack_vector's default (1, 0).
# Mirrors Utils.is_manual_aim for a single local player (not co-op: that's what a client is):
# - "manual aim on mouse press" (or manual aim on consoles): manual while the left mouse button
#   is held, or for pad users while the right stick is pushed;
# - "manual aim": always manual.
# Pad users aim with the right stick; mouse users toward the mouse, like weapon.gd does in solo
# (get_global_mouse_position() - position), as a direction from the client's own player.

const FLAG_MANUAL := 1
const STICK_THRESHOLD := 0.05  # Utils.is_manual_aim: rjoy length_squared


# Returns [flags, aim vector]. own_player: the client's predicted player, or null outside the
# fight (then the mouse never turns into a stick: the host scrolls UI with the right stick).
static func sample(own_player: Node2D, using_gamepad: bool) -> Array:
	var stick := Input.get_vector("rjoy_left", "rjoy_right", "rjoy_up", "rjoy_down")
	var settings: Dictionary = ProgressData.settings
	var manual := false
	if settings.manual_aim_on_mouse_press or (Utils.on_console and settings.manual_aim):
		var mouse_pressed := not using_gamepad and Input.is_mouse_button_pressed(BUTTON_LEFT)
		manual = mouse_pressed or (using_gamepad and stick.length_squared() > STICK_THRESHOLD)
	elif settings.manual_aim:
		manual = true
	var aim := stick
	if manual and not using_gamepad:
		aim = Vector2.ZERO
		if own_player != null and is_instance_valid(own_player):
			aim = (own_player.get_global_mouse_position() - own_player.global_position).normalized()
	return [FLAG_MANUAL if manual else 0, aim]


# The client's own player while the wave is on (not during the level-up / crate panels).
static func own_player(battle_client: Node) -> Node2D:
	if battle_client == null or not battle_client.is_in_battle() or battle_client._you < 0:
		return null
	var main: Node = battle_client._main
	var ui = main.get("_coop_upgrades_ui")
	if ui != null and ui.visible:
		return null
	var players = main.get("_players")
	if players == null or battle_client._you >= players.size():
		return null
	return players[battle_client._you]
