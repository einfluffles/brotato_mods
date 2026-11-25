extends Reference
# A client that closes its game mid-wave: the tree lets go of the mod's nodes before their last
# handlers run (the battle scene's tree_exited, lobby_left), so get_tree() is null there. Each
# handler must end quietly: no script error (tools/check.sh fails on one in mod code) and the
# state it resets reset. The mod node leaves the tree for that, as in a closing game, and comes
# back at its place; the handlers run on the real nodes and connections.

const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const MAIN_ID := 4711  # the battle scene's instance id, as BattleClient keeps it

var _t: Node
var _battle_left := 0


func run(test_mod: Node, together: Node) -> void:
	_t = test_mod
	var parent := together.get_parent()
	var index := together.get_index()
	var client_active: bool = together._client_active
	parent.remove_child(together)
	# In a function of its own: a script error there returns to here, and the node goes back.
	_while_closing(together)
	together._client_active = client_active
	parent.add_child(together)
	parent.move_child(together, index)
	_t._check(
		together.is_inside_tree() and together.get_index() == index,
		"closing: the mod node is back at its place"
	)


func _while_closing(together: Node) -> void:
	_t._check(not together.is_inside_tree(), "closing: the mod node is out of the tree")
	_battle_scene_exited(together)
	_shop_lobby_left(together.shop_sync)
	_menu_lobby_left(together.menu_puppet, together.transport)


# BattleClient._on_battle_scene_exited -> _leave_battle -> battle_left -> mod_main's
# _on_client_battle_left, both out of the tree.
func _battle_scene_exited(together: Node) -> void:
	var client: Node = together.battle_client
	client._main_id = MAIN_ID
	client._loading = false  # else the reset leaves the scene watch to the loading scene
	client._you = 1
	client._has_clock = true
	together._client_active = true
	SoundRelay.set_muted(false)
	_battle_left = 0
	client.connect("battle_left", self, "_on_battle_left")
	client._on_battle_scene_exited(MAIN_ID)
	client.disconnect("battle_left", self, "_on_battle_left")
	_t._check(
		_battle_left == 1 and client._main_id == 0 and client._you == -1 and not client._has_clock,
		"closing: the battle client leaves the battle out of the tree, all of its state reset"
		+ " (battle_left %d, main id %d, you %d, clock %s)"
		% [_battle_left, client._main_id, client._you, client._has_clock]
	)
	_t._check(
		not SoundRelay.is_muted() and not client.is_in_battle(),
		"closing: the mod's battle-left handler does nothing out of the tree (no mute, no timer)"
	)


func _on_battle_left() -> void:
	_battle_left += 1


func _shop_lobby_left(shop_sync: Node) -> void:
	shop_sync._client_shop_id = MAIN_ID
	shop_sync._state = {"closing": true}
	shop_sync._on_lobby_left()
	_t._check(
		shop_sync._client_shop_id == 0 and shop_sync._state.empty(),
		"closing: the shop sync leaves the lobby out of the tree, its state reset"
	)


func _menu_lobby_left(menu_puppet: Node, transport: Node) -> void:
	menu_puppet._kind = "shop"
	menu_puppet._scene_id = MAIN_ID
	menu_puppet._on_lobby_left(transport)
	_t._check(
		menu_puppet._kind == "" and menu_puppet._scene_id == 0,
		"closing: the menu puppet leaves the lobby out of the tree, its state reset"
	)
