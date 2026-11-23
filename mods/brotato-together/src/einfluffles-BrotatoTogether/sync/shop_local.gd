extends Reference
# Client: this client's own panel in its copy of the shop. guard() cuts every game handler that
# would change the run or roll something; take_over() sends the own panel's presses as
# SHOP_INTENT and its cursor and page as SHOP_FOCUS.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const LocalPanel := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/local_panel.gd")
const FocusTargets := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/focus_targets.gd"
)
const MecaChoice := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/meca_choice.gd")
const PopupView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/popup_view.gd")
# ShopItemsContainer.connect_shop_items: ShopItem signal -> container handler. The container
# mutates before BaseShop hears of it, so the cuts sit here. The lock has no signal at all:
# extensions/ui/shop_item.gd.
const ITEM_HANDLERS := {
	"buy_button_pressed": "on_shop_item_buy_button_pressed",
	"steal_button_pressed": "on_shop_item_steal_button_pressed",
	"ban_item_pressed": "on_shop_item_ban_button_pressed",
	"dismantle_button_pressed": "on_shop_item_dismantle_button_pressed",
}
# BaseShop._ready: item popup signal -> BaseShop handler (bound to the player index).
const POPUP_HANDLERS := {
	"item_combine_button_pressed": "_on_item_combine_button_pressed",
	"item_discard_button_pressed": "_on_item_discard_button_pressed",
	"item_meca_upgrade_selected": "_on_item_meca_upgrade_selected",
}
const LOCK_WAIT_MSEC := 1000  # how long an own lock press shows without the host's answer
const LOG_NAME := "einfluffles-BrotatoTogether:ShopLocal"
const DEVICE_OWNER := "shop"  # InputSync.set_local_device

var session: Node = null
var input_sync: Node = null
var focus_sync: Node = null
var last_intent := {}  # the last decision sent
var active := false  # the own panel runs locally
var you := -1
var seq := -1  # revision of the own panel, from the last state
var local_panel: Node = null  # LocalPanel in the puppet shop: device type and mouse, own panel
var meca = MecaChoice.new()  # the own item popup's meca upgrade

var _shop: Node = null  # the puppet shop whose handlers are cut
var _shop_id := 0
var _own := []  # [source, signal, method]: this file's handlers on the own panel
var _paused := false  # the host paused: the pause menu is the host's, nothing runs here
var _menu_open := false  # this client's own pause menu is open over the shop (PauseControl)
var _host_ready := false  # the own Go flag as the host has it
var _unready_sent := false
var _go_sent := false  # "go 1" left and the host's ready flag is not here yet
var _sent_focus := ""
var _panel_player := -1  # whose panel LocalPanel drives (-1: none)
# Own lock presses the host has not answered yet:
# slot node id -> [wanted, msec, the host's lock, item my_id].
var _locks := {}


func _init() -> void:
	meca.connect("roll_requested", self, "_on_own_meca_roll")
	meca.connect("picked", self, "_on_own_meca_picked")


func guard(shop: Node, shop_id: int) -> void:
	if shop == _shop:
		return
	stop("another shop")
	_shop = shop
	_shop_id = shop_id
	_own = []
	for p in RunData.get_player_count():
		var items = shop._get_shop_items_container(p)
		for node in items._shop_items:
			for signal_name in ITEM_HANDLERS:
				_disconnect(node, signal_name, items, ITEM_HANDLERS[signal_name])
		# Called by ShopSync only for a cursor on that item: see ShopSync._deactivate.
		_disconnect(items, "shop_item_deactivated", shop, "on_shop_item_deactivated")
		_disconnect(shop._get_reroll_button(p), "pressed", shop, "_on_RerollButton_pressed")
		_disconnect(shop._get_go_button(p), "pressed", shop, "_on_GoButton_pressed")
		var popup = shop._get_item_popup(p)
		for signal_name in POPUP_HANDLERS:
			_disconnect(popup, signal_name, shop, POPUP_HANDLERS[signal_name])
		MecaChoice.cut(popup)
		var panel = shop._get_coop_player_container(p)
		_disconnect(panel.get("_endless_button"), "toggled", panel, "_on_EndlessButton_toggled")
	_add_local_panel()


# Safe to call again; another slot releases the old one.
func take_over(player: int) -> void:
	if not is_instance_valid(_shop) or player < 0 or player >= RunData.get_player_count():
		stop("no own panel in the state")
		return
	if not active or player != you:
		ModLoaderLog.info(
			"Own shop panel runs here (player %d%s)" % [player, ", host paused" if _paused else ""],
			LOG_NAME
		)
	if player != you or _own.empty():
		_release_own()
		you = player
		_connect_own()
	active = true
	_apply_device("own panel in the host's state")
	if focus_sync != null:
		focus_sync.set_local_emulator(DEVICE_OWNER, Utils.get_focus_emulator(you, _shop))
	_apply_local_panel()


func stop(reason := "stopped") -> void:
	if active:
		ModLoaderLog.info("Own shop panel stops (%s)" % reason, LOG_NAME)
	_release_own()
	you = -1
	seq = -1
	_host_ready = false
	_unready_sent = false
	_go_sent = false
	_sent_focus = ""
	_locks = {}
	if not active:
		return
	active = false
	_apply_device(reason)
	if focus_sync != null:
		focus_sync.set_local_emulator(DEVICE_OWNER, null)
	_apply_local_panel()


func leave(shop: Node) -> void:
	if shop == _shop:
		_menu_open = false
		stop("shop left")
		_shop = null
		local_panel = null  # freed with the shop


func on_state(revision: int, ready: bool) -> void:
	seq = revision
	_host_ready = ready
	_unready_sent = false
	if ready:
		_go_sent = false


# The meca upgrade rolls the host remembers for the own player's weapons.
func on_mecas(rolls) -> void:
	meca.set_rolls(rolls)


func set_paused(paused: bool) -> void:
	if paused != _paused:
		ModLoaderLog.info("Host's shop pause: %s" % ("paused" if paused else "resumed"), LOG_NAME)
	_paused = paused
	if input_sync != null:
		input_sync.set_host_paused("shop", paused)
	_apply_device("host paused" if paused else "host resumed")
	_apply_local_panel()


# The own pause menu takes the local buttons and the mouse meanwhile.
func set_menu_open(open: bool) -> void:
	if open == _menu_open:
		return
	_menu_open = open
	_apply_device("own menu opened" if open else "own menu closed")
	_apply_local_panel()


func is_menu_open() -> bool:
	return _menu_open


func process() -> void:
	if is_instance_valid(local_panel):
		# Also while nothing is local: LocalPanel stops mouse events over the panels otherwise.
		local_panel.blocked = (
			_menu_open or input_sync != null and input_sync.local_input_blocked
		)
	if not active:
		return
	if not is_instance_valid(_shop) or not _shop.is_inside_tree():
		stop("shop gone")
		return
	_heal_device()
	_expire_locks()
	_report_focus()
	# Ready only lasts while the cursor rests on Go: the game clears the flag itself when the
	# cursor leaves, on cancel and on the triggers, and the host has to hear of it.
	var emulator = Utils.get_focus_emulator(you, _shop)
	var on_go: bool = emulator != null and emulator.focused_control == _shop._get_go_button(you)
	var ready: bool = _shop._player_pressed_go_button[you]
	if ready and emulator != null and not on_go:
		_shop._clear_go_button_pressed(you)
		ready = false
	if _host_ready and not ready and not _unready_sent:
		_unready_sent = true
		_send_intent("go", -1, "", 0)
	if not on_go:
		_go_sent = false
	if is_instance_valid(local_panel):
		# A mouse that drifts off Go would take the ready flag back (or the press on its way).
		local_panel.hold_cursor = on_go and (ready or _go_sent)


func _connect_own() -> void:
	var items = _shop._get_shop_items_container(you)
	for node in items._shop_items:
		_connect(node, "buy_button_pressed", "_on_own_buy")
		for kind in ["steal", "ban", "dismantle"]:
			var signal_name: String = "ban_item_pressed" if kind == "ban" else kind + "_button_pressed"
			_connect(node, signal_name, "_on_own_slot", [kind])
		if node.has_signal("lock_requested"):
			_connect(node, "lock_requested", "_on_own_lock")
	_connect(_shop._get_reroll_button(you), "pressed", "_on_own_reroll")
	_connect(_shop._get_go_button(you), "pressed", "_on_own_go")
	var popup = _shop._get_item_popup(you)
	for kind in ["combine", "discard"]:
		_connect(popup, "item_%s_button_pressed" % kind, "_on_own_weapon", [kind])
	meca.attach(popup, you)
	var endless = _shop._get_coop_player_container(you).get("_endless_button")
	if endless != null:
		_connect(endless, "toggled", "_on_own_endless")


func _connect(source: Object, signal_name: String, method: String, binds := []) -> void:
	if source.connect(signal_name, self, method, binds) == OK:
		_own.append([source, signal_name, method])


func _release_own() -> void:
	for entry in _own:
		if is_instance_valid(entry[0]):
			_disconnect(entry[0], entry[1], self, entry[2])
	_own = []
	meca.detach()


static func _disconnect(source: Object, signal_name: String, target: Object, method: String):
	if source != null and source.is_connected(signal_name, target, method):
		source.disconnect(signal_name, target, method)


func _wanted_device() -> int:
	return CoopService.get_remapped_player_device(you) if _runs_here() else -1


func _runs_here() -> bool:
	return active and not _paused and not _menu_open


func _apply_device(reason: String) -> void:
	if input_sync != null:
		input_sync.set_local_device(DEVICE_OWNER, _wanted_device(), reason)


# Whatever turned the own panel's device off, take it back and log what had done it.
func _heal_device() -> void:
	var device := _wanted_device()
	if input_sync == null or device < 0 or input_sync.local_device() == device:
		return
	ModLoaderLog.warning(
		(
			"Own shop panel had lost its device %d (live: %d, last change: %s); taken back"
			% [device, input_sync.local_device(), input_sync.last_local_change]
		),
		LOG_NAME
	)
	_apply_device("self-heal")


# As the shop's last child: after the FocusEmulators, so it gets every event before them.
func _add_local_panel() -> void:
	if is_instance_valid(local_panel):
		local_panel.queue_free()
	var containers := []
	for p in RunData.get_player_count():
		containers.append(_shop._get_coop_player_container(p))
	local_panel = LocalPanel.new()
	local_panel.panels = containers
	local_panel.connect("player_type_changed", self, "_on_own_type_changed")
	_shop.add_child(local_panel)
	_panel_player = -1


func _apply_local_panel() -> void:
	if not is_instance_valid(local_panel):
		return
	var player := you if _runs_here() else -1
	if player == _panel_player:
		return
	_panel_player = player
	if player < 0:
		local_panel.set_own(null, null, -1)
		local_panel.hold_cursor = false
		return
	local_panel.set_own(
		_shop._get_coop_player_container(player), Utils.get_focus_emulator(player, _shop), player
	)


# The own slot is typed as another device now (keyboard <-> pad). The way to the page arrows is
# the panel's own (CoopShopPlayerContainer._set_focus_neighbours, run by the game in _ready and
# on a page change only).
func _on_own_type_changed(_player_type: int, cursor_lost: bool) -> void:
	if not active or not is_instance_valid(_shop):
		return
	var container = _shop._get_coop_player_container(you)
	container._set_focus_neighbours()
	if not cursor_lost:
		return
	# The cursor sat on a page arrow that is a trigger glyph now. Like the game after a page change
	# (_set_focus_after_carousel_index_change): the shop's default on the shop page, else Go.
	var target: Control = _shop._get_go_button(you)
	if container.carousel.index == 0:
		var shop_default: Control = _shop._get_default_focus_control(you)
		if shop_default != null and shop_default.is_visible_in_tree():
			target = shop_default
	var emulator = Utils.get_focus_emulator(you, _shop)
	if emulator != null and target.is_visible_in_tree():
		emulator.focused_control = target


func _report_focus() -> void:
	var panel = _shop._get_coop_player_container(you)
	var emulator = Utils.get_focus_emulator(you, _shop)
	var control = emulator.focused_control if emulator != null else null
	var target := []
	if control != null and is_instance_valid(control):
		target = FocusTargets.describe(control, _shop, you)  # [] outside the own panel
	var popup := PopupView.describe(
		_shop, _shop._popup_manager, _shop._get_item_popup(you), panel, you
	)
	var message := {
		"shop_id": _shop_id, "page": panel.carousel.index, "target": target, "popup": popup
	}
	var key := var2str(message)
	if key != _sent_focus:
		_sent_focus = key
		_send(Protocol.Msg.SHOP_FOCUS, message)


func _on_own_buy(node: Node) -> void:
	if node.item_data == null:
		return
	if node.item_data.is_meca and node.effect_choice_selected < 0:
		# The view half of the container's handler: the cursor goes to the two effects first.
		_shop._get_shop_items_container(you).give_focus_to_mecha_choice(node)
		return
	_send_slot_intent("buy", node, node.effect_choice_selected)


func _on_own_slot(node: Node, kind: String) -> void:
	_send_slot_intent(kind, node)


# The lock shows at once (view only: the run is the host's) and the host's states are not
# allowed to take it back until one agrees or LOCK_WAIT_MSEC passed (a refused press).
func _on_own_lock(node: Node, locked: bool) -> void:
	var item = node.item_data
	if item == null or not node.active or not item.is_lockable:
		return
	# With a steal left the same press steals the item (BaseShop._input): nothing to lock.
	if _shop._item_steals[you] > 0:
		return
	if RunData.get_player_effect_bool(Keys.disable_item_locking_hash, you):
		return
	var id := node.get_instance_id()
	var host_locked: bool = _locks[id][2] if _locks.has(id) else node.locked
	_locks[id] = [locked, OS.get_ticks_msec(), host_locked, item.my_id]
	show_lock(node, locked)
	_send_slot_intent("lock", node, int(locked))


# What a slot shows: the host's lock, or the own press on it that the host has not answered.
func lock_shown(node: Node, host_locked: bool) -> bool:
	var pending = _locks.get(node.get_instance_id())
	if pending == null:
		return host_locked
	if pending[0] == host_locked or node.item_data.my_id != pending[3]:
		_locks.erase(node.get_instance_id())
		return host_locked
	pending[2] = host_locked
	return pending[0]


static func show_lock(node: Node, locked: bool) -> void:
	if locked:
		node.lock_visually()
	else:
		node.unlock_visually()


# A press the host did not apply (no state came, or none that agrees): back to the host's.
func _expire_locks() -> void:
	if _locks.empty():
		return
	var now := OS.get_ticks_msec()
	for id in _locks.keys():
		var pending: Array = _locks[id]
		if now - pending[1] < LOCK_WAIT_MSEC:
			continue
		_locks.erase(id)
		var node = instance_from_id(id)
		if not is_instance_valid(node) or not node.active or node.item_data == null:
			continue
		if node.item_data.my_id == pending[3] and node.locked != pending[2]:
			show_lock(node, pending[2])
			var popup = _shop._get_item_popup(you)
			if popup.shop_item == node:
				popup.show_shop_hints(node)


func _on_own_reroll() -> void:
	_send_intent("reroll")


# No local flag: the checkmark shows once the host has it.
func _on_own_go() -> void:
	var wanted := int(not _shop._player_pressed_go_button[you])
	_go_sent = wanted == 1
	_send_intent("go", -1, "", wanted)


func _on_own_endless(pressed: bool) -> void:
	_send_intent("endless", -1, "", int(pressed))


func _on_own_weapon(weapon, kind: String) -> void:
	if weapon == null:
		return
	_send_intent(kind, RunData.get_player_weapons(you).find(weapon), weapon.my_id)
	# The view half of the shop's handler: close the popup, cursor back on the weapon.
	_shop._on_item_cancel_button_pressed(weapon, you)


# The popup stays as it is, so Cancel still closes it; the options arrive with the next state.
func _on_own_meca_roll(weapon) -> void:
	_send_intent("meca_roll", RunData.get_player_weapons(you).find(weapon), weapon.my_id)


func _on_own_meca_picked(weapon, index: int) -> void:
	_send_intent("meca", RunData.get_player_weapons(you).find(weapon), weapon.my_id, index)
	_shop._on_item_cancel_button_pressed(weapon, you)


# Another mod's press on the own panel (ShopSync.send_intent). False: the panel is not local.
func send_mod_intent(kind: String, slot: int, id: String, arg: int) -> bool:
	if not active or _paused:
		return false
	_send_intent(kind, slot, id, arg)
	return true


func _send_slot_intent(kind: String, node: Node, arg := -1) -> void:
	if node.item_data == null:
		return
	var slot: int = _shop._get_shop_items_container(you)._shop_items.find(node)
	_send_intent(kind, slot, node.item_data.my_id, arg)


func _send_intent(kind: String, slot := -1, id := "", arg := -1) -> void:
	last_intent = {
		"shop_id": _shop_id, "seq": seq, "kind": kind, "slot": slot, "id": id, "arg": arg
	}
	_send(Protocol.Msg.SHOP_INTENT, last_intent)


func _send(msg_type: int, message: Dictionary) -> void:
	if session != null and session.is_client():
		session.send_reliable(session.transport.host_id, msg_type, message)
