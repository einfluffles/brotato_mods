extends Reference
# Suite upgrades_popup: a remote player's open popup on the host's copy of the level-up / crate
# panels (UpgradesSync, sync/popup_view.gd). A client that leaves takes it off, and opening or
# closing it leaves Godot's focus where it was (the lobby popup's buttons). The run and battle are
# built as upgrades_change_tests.gd builds them.

const UpgradesChangeTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/upgrades_change_tests.gd"
)
const ShopPopupViewTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/shop_popup_view_tests.gd"
)
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const PEER := 4646
const REMOTE := 1

var _t: Node = null
var _sync: Node = null
var _ui: Node = null
var _built = UpgradesChangeTests.new()


func run(t: Node, together: Node):
	_t = t
	_sync = together.upgrades_sync
	_built._t = t
	_built._together = together
	_built._sync = _sync
	together.battle_host.set_process(false)  # driven by hand: no Steam session
	var saved_players: Array = CoopService.connected_players.duplicate(true)
	_built._build_run(2, 0)
	RunData.get_player_effects(REMOTE)[Keys.effect_crate_give_weapon_hash] = 1
	RunData.add_weapon(t._find_by_id(ItemService.weapons, UpgradesChangeTests.PISTOL), REMOTE)
	yield(_built._enter_battle(), "completed")
	_built._show([[_built._crate(0)], [_built._crate(REMOTE)]], [[], []])
	yield(t.get_tree(), "idle_frame")
	_ui = _built._ui
	var element = _crate_weapon()
	if element == null:
		t._check(false, "upgrades popup: (player 2 has crate weapons)")
	else:
		var view := [FocusTargets.describe(element, _ui, REMOTE), element.item.my_id, 0, [null, null]]
		_test_real_focus(view)
		_test_peer_removed(together, view)
	_sync._reported_popups = {}
	yield(_built._blank_scene(), "completed")
	CoopService.connected_players = saved_players
	together.battle_host.set_process(true)


# Godot's focus held outside every FocusEmulator stays there while the copy opens and closes.
func _test_real_focus(view: Array) -> void:
	var popup = _ui._get_player_container(REMOTE).item_popup
	var holder: Button = ShopPopupViewTests.focus_holder(_t)
	_sync._apply_popup(_ui, REMOTE, view, null)
	_t._check(
		popup._focused and holder.has_focus(),
		"upgrades popup: a remote player's copy opening keeps Godot's focus"
	)
	_sync._apply_popup(_ui, REMOTE, [], null)
	_t._check(not popup._focused and holder.has_focus(), "upgrades popup: and closing too")
	holder.get_parent().free()


# UpgradesSync._on_peer_removed: only the leaving client's popup closes on the host's copy.
func _test_peer_removed(together: Node, view: Array) -> void:
	var container = _ui._get_player_container(REMOTE)
	var popup = container.item_popup
	var cancel := FocusTargets.describe(popup._cancel_button, _ui, REMOTE)
	_sync.host_apply_focus(_ui, REMOTE, 0, cancel, view, PEER)
	_t._check(popup._focused, "upgrades popup: (player 2's crate weapon popup open on the host)")
	var transport: Node = together.session.transport
	var lobby: int = transport.lobby_id
	var host: int = transport.host_id
	transport.lobby_id = 99
	transport.host_id = transport.local_id  # this game is the host
	_sync._on_peer_removed(PEER + 1)
	_t._check(
		popup._focused and _sync._reported_popups.has(REMOTE),
		"upgrades popup: another client that leaves changes nothing"
	)
	_sync._on_peer_removed(PEER)
	transport.lobby_id = lobby
	transport.host_id = host
	_sync._keep_reported_popups(_ui)
	_t._check(
		(
			not popup._focused
			and _ui._popup_manager._elements_pressed[REMOTE] == null
			and not _sync._reported_popups.has(REMOTE)
		),
		"upgrades popup: a client that leaves takes its open popup off the host's copy"
	)


func _crate_weapon():
	var row: Node = _ui._get_player_container(REMOTE).crate_weapons_container._elements
	for child in row.get_children():
		if not child.is_queued_for_deletion():
			return child
	return null
